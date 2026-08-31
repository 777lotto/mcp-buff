-- Optional, session-scoped SSH forwarding for the broker admin listener.
--
-- Managed mode owns one foreground ssh process and only trusts the listener
-- created by that process. An already-open local port is refused rather than
-- reused: otherwise the admin capability could be sent to an unrelated local
-- service whose ownership McpBuff cannot prove.

local fn, uv = vim.fn, (vim.uv or vim.loop)

local M = {}
local Tunnel = {}
Tunnel.__index = Tunnel

local DEFAULT_STARTUP_TIMEOUT_MS = 30000
local CHECK_INTERVAL_MS = 50
local ALLOWED_KEYS = {
  host = true,
  ssh_command = true,
  startup_timeout = true,
}

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function one_line(value)
  local text = trim(tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '))
  if #text > 300 then text = text:sub(1, 299) .. '…' end
  return text
end

local function endpoint_port(endpoint)
  return tonumber(tostring(endpoint or ''):match('^http://127%.0%.0%.1:(%d+)$'))
end

--- Validate and complete an optional managed-tunnel configuration.
--- false or nil preserves the external-tunnel behavior.
function M.normalize(config, endpoint)
  if config == nil or config == false then return nil end
  if type(config) ~= 'table' then
    return nil, 'tunnel must be false or a table'
  end
  for key in pairs(config) do
    if not ALLOWED_KEYS[key] then
      return nil, ('tunnel.%s is not a supported option'):format(tostring(key))
    end
  end

  local host = type(config.host) == 'string' and trim(config.host) or ''
  -- A direct argv invocation has no shell interpolation. Restricting the host
  -- further also prevents it from being parsed as an ssh option and makes this
  -- setting clearly an alias/hostname rather than a command fragment.
  if host == '' or host:match('^[%w][%w%._@-]*$') == nil then
    return nil, 'tunnel.host must be an SSH alias or hostname without whitespace'
  end

  local ssh_command = config.ssh_command or 'ssh'
  if type(ssh_command) ~= 'string' or trim(ssh_command) == ''
    or ssh_command:find('\0', 1, true) then
    return nil, 'tunnel.ssh_command must be a non-empty executable name'
  end

  local startup_timeout = tonumber(config.startup_timeout or DEFAULT_STARTUP_TIMEOUT_MS)
  if not startup_timeout or startup_timeout ~= math.floor(startup_timeout)
    or startup_timeout < 1000 or startup_timeout > 120000 then
    return nil, 'tunnel.startup_timeout must be an integer from 1000 to 120000 milliseconds'
  end

  local port = endpoint_port(endpoint)
  if not port or port < 1 or port > 65535 then
    return nil, 'managed tunnel requires a loopback endpoint with an explicit port'
  end

  return {
    host = host,
    ssh_command = ssh_command,
    startup_timeout = startup_timeout,
    port = port,
  }
end

--- Return the exact no-shell ssh argv used by managed mode.
function M.argv(config)
  local forward = ('127.0.0.1:%d:127.0.0.1:%d'):format(config.port, config.port)
  return {
    config.ssh_command,
    '-N',
    '-T',
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=3',
    -- A distinct connection gives this plugin an exact process to revoke. It
    -- must not silently attach the forward to a pre-existing control master.
    '-o', 'ControlMaster=no',
    '-o', 'ControlPath=none',
    '-L', forward,
    config.host,
  }
end

local function default_probe(port, callback)
  local socket, create_error = uv.new_tcp()
  if not socket then
    vim.schedule(function()
      callback(nil, 'could not create a loopback probe: ' .. one_line(create_error))
    end)
    return
  end

  local completed = false
  local function finish(listening, probe_error)
    if completed then return end
    completed = true
    if not socket:is_closing() then socket:close() end
    vim.schedule(function() callback(listening, probe_error) end)
  end

  local ok, connect_error = pcall(socket.connect, socket, '127.0.0.1', port, function(err)
    -- ECONNREFUSED means the port is available. Other asynchronous errors are
    -- surfaced because treating an unknown probe result as "free" is unsafe.
    if err == nil then
      finish(true)
    elseif tostring(err):find('ECONNREFUSED', 1, true) then
      finish(false)
    else
      finish(nil, 'could not probe the loopback port: ' .. one_line(err))
    end
  end)
  if not ok then
    finish(nil, 'could not probe the loopback port: ' .. one_line(connect_error))
  end
end

local function default_spawn(command, opts, callback)
  return vim.system(command, opts, callback)
end

local function tunnel_error(message)
  return { kind = 'tunnel', message = message }
end

function Tunnel:_drain(error)
  local waiters = self.waiters
  self.waiters = {}
  for _, callback in ipairs(waiters) do callback(error) end
end

function Tunnel:_fail(generation, message, terminate)
  if generation ~= self.generation then return end
  local job = self.job
  self.job = nil
  self.state = 'stopped'
  if terminate and job then
    pcall(function() job:kill(15) end)
  end
  self:_drain(tunnel_error(message))
end

function Tunnel:_exit_message(result, phase)
  local detail = one_line(result and result.stderr)
  local status = result and tonumber(result.code)
  if detail == '' then
    detail = status and ('ssh exited with code ' .. status) or 'ssh exited'
  end
  return ('the managed SSH tunnel %s: %s'):format(phase, detail)
end

function Tunnel:_on_process_exit(generation, job, result)
  if generation ~= self.generation or job ~= self.job then return end
  local was_ready = self.state == 'ready'
  self.job = nil
  self.state = 'stopped'
  local error = tunnel_error(self:_exit_message(
    result, was_ready and 'closed unexpectedly' or 'could not start'))
  if was_ready then
    self.on_exit(error)
  else
    self:_drain(error)
  end
end

function Tunnel:_poll(generation, elapsed)
  if generation ~= self.generation or self.state ~= 'starting' then return end
  self.probe(self.config.port, function(listening, probe_error)
    if generation ~= self.generation or self.state ~= 'starting' then return end
    if probe_error then
      self:_fail(generation, probe_error, true)
      return
    end
    if listening then
      self.state = 'ready'
      self:_drain(nil)
      return
    end
    if elapsed >= self.config.startup_timeout then
      self:_fail(generation,
        ('managed SSH tunnel did not listen on 127.0.0.1:%d within %d ms')
          :format(self.config.port, self.config.startup_timeout), true)
      return
    end
    self.defer(function()
      self:_poll(generation, elapsed + CHECK_INTERVAL_MS)
    end, CHECK_INTERVAL_MS)
  end)
end

function Tunnel:_spawn(generation)
  local command = M.argv(self.config)
  local job
  local exit_result
  local dispatched = false
  local function dispatch_exit()
    if dispatched or not job or not exit_result then return end
    dispatched = true
    self.schedule(function()
      self:_on_process_exit(generation, job, exit_result)
    end)
  end

  local ok, job_or_error = pcall(self.spawn, command, { text = true }, function(result)
    exit_result = result or {}
    dispatch_exit()
  end)
  if not ok or not job_or_error then
    self:_fail(generation,
      'the managed SSH tunnel could not be launched: ' .. one_line(job_or_error), false)
    return
  end
  job = job_or_error
  self.job = job
  dispatch_exit()
  self.defer(function() self:_poll(generation, CHECK_INTERVAL_MS) end, CHECK_INTERVAL_MS)
end

--- Ensure that the plugin-owned listener is ready, coalescing concurrent calls.
function Tunnel:ensure(callback)
  assert(type(callback) == 'function', 'mcp_buff tunnel: callback is required')
  if self.state == 'ready' and self.job then
    callback(nil)
    return
  end
  self.waiters[#self.waiters + 1] = callback
  if self.state == 'starting' then return end

  if not self.executable(self.config.ssh_command) then
    self:_drain(tunnel_error(
      ('SSH executable is not available: %s'):format(self.config.ssh_command)))
    return
  end

  self.generation = self.generation + 1
  local generation = self.generation
  self.state = 'starting'
  self.probe(self.config.port, function(listening, probe_error)
    if generation ~= self.generation or self.state ~= 'starting' then return end
    if probe_error then
      self:_fail(generation, probe_error, false)
    elseif listening then
      self:_fail(generation,
        ('127.0.0.1:%d already has a listener; managed mode refuses to send the '
          .. 'admin capability through a process it does not own. Stop that listener '
          .. 'or disable the tunnel option.'):format(self.config.port), false)
    else
      self:_spawn(generation)
    end
  end)
end

--- Revoke only the SSH process created by this instance.
function Tunnel:stop()
  self.generation = self.generation + 1
  local job = self.job
  self.job = nil
  self.state = 'stopped'
  if job then pcall(function() job:kill(15) end) end
  self:_drain(tunnel_error('the managed SSH tunnel was stopped'))
end

function Tunnel:is_ready()
  return self.state == 'ready' and self.job ~= nil
end

function M.new(config, dependencies)
  dependencies = dependencies or {}
  return setmetatable({
    config = assert(config, 'mcp_buff tunnel: normalized config is required'),
    state = 'stopped',
    generation = 0,
    job = nil,
    waiters = {},
    spawn = dependencies.spawn or default_spawn,
    probe = dependencies.probe or default_probe,
    defer = dependencies.defer or function(callback, ms) vim.defer_fn(callback, ms) end,
    schedule = dependencies.schedule or vim.schedule,
    executable = dependencies.executable
      or function(command) return fn.executable(command) == 1 end,
    on_exit = dependencies.on_exit or function() end,
  }, Tunnel)
end

M.DEFAULT_STARTUP_TIMEOUT_MS = DEFAULT_STARTUP_TIMEOUT_MS

return M
