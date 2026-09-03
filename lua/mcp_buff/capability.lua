-- Admin capability acquisition.
--
-- The capability is a 64-hex bearer secret. It is fetched by running an operator
-- supplied argv list (no shell), kept only in Lua memory for the life of one
-- operator decision, and never written to argv, the environment, disk, or a log.
--
-- The single most dangerous failure here is a fetch that fails quietly: the
-- request then goes out with no Authorization header and the operator sees an
-- opaque 401 instead of "your card is not available". Every path in this module
-- therefore turns a failed fetch into an error that aborts the request.

local M = {}

local uv = vim.uv or vim.loop

local DEFAULT_TTL_SECONDS = 300
local DEFAULT_FETCH_TIMEOUT_MS = 120000

local function monotonic_seconds()
  return uv.now() / 1000
end

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function one_line(value)
  local text = trim(tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '))
  if #text > 300 then text = text:sub(1, 299) .. '…' end
  return text
end

local function is_capability(value)
  return type(value) == 'string' and #value == 64 and value:match('^[a-f0-9]+$') ~= nil
end

--- Validate an argv list without running it.
function M.normalize_cmd(value)
  if value == nil then return nil, nil end
  if type(value) ~= 'table' or vim.tbl_isempty(value) then
    return nil, 'capability_cmd must be a non-empty argv list, for example '
      .. '{ "pass", "show", "your/entry" }'
  end
  local argv = {}
  for index, argument in ipairs(value) do
    if type(argument) ~= 'string' or argument == '' then
      return nil, 'capability_cmd entries must be non-empty strings'
    end
    argv[index] = argument
  end
  if #argv ~= #value then
    return nil, 'capability_cmd must be a plain array of strings'
  end
  return argv
end

--- Create an isolated capability cache. Provider-aware views use one instance
--- per broker, so a GitHub bearer can never be reused for Cloudflare or vice
--- versa. Module-level methods below retain the original single-provider API.
function M.new(initial)
  local instance = {}
  local config = {
    cmd = nil,
    ttl = DEFAULT_TTL_SECONDS,
    fetch_timeout = DEFAULT_FETCH_TIMEOUT_MS,
    spawn = nil,
  }
  -- Held in memory only. Lua strings are immutable and interned, so clear()
  -- drops the reference rather than pretending to overwrite the bytes.
  local cached_value
  local cached_until

  function instance.clear()
    cached_value = nil
    cached_until = nil
  end

  function instance.configure(opts)
    opts = opts or {}
    instance.clear()
    config.cmd = opts.cmd
    config.ttl = opts.ttl or DEFAULT_TTL_SECONDS
    config.fetch_timeout = opts.fetch_timeout or DEFAULT_FETCH_TIMEOUT_MS
    config.spawn = opts.spawn
  end

  function instance.configured()
    return config.cmd ~= nil
  end

  function instance.cached()
    return cached_value ~= nil and cached_until ~= nil
      and monotonic_seconds() < cached_until
  end

  --- Resolve the capability.
  --- opts.allow_fetch=false never runs capability_cmd; opts.force drops a
  --- cached value for the one safe retry after a bearer rejection.
  function instance.get(opts, callback)
    opts = opts or {}

    if not config.cmd then
      return callback({
        kind = 'capability',
        message = 'no admin capability is configured; set capability_cmd to an argv '
          .. 'list that prints the 64-hex broker admin capability',
      })
    end

    if not opts.force and instance.cached() then
      return callback(nil, cached_value)
    end

    instance.clear()

    if opts.allow_fetch == false then
      return callback({
        kind = 'capability',
        cold = true,
        message = 'the admin capability is not cached and this request may not '
          .. 'prompt for it; refresh the panel manually',
      })
    end

    local spawn = config.spawn or vim.system
    local ok, job_or_error = pcall(spawn, config.cmd, {
      text = true,
      timeout = config.fetch_timeout,
    }, function(result)
      vim.schedule(function()
        -- The command's stdout may carry the secret, so only stderr is ever
        -- quoted back to the operator.
        if result.code ~= 0 then
          local detail = one_line(result.stderr)
          if detail == '' then
            detail = 'capability_cmd exited with code ' .. tostring(result.code)
          end
          return callback({
            kind = 'capability',
            message = 'the admin capability could not be read: ' .. detail,
          })
        end

        local value = trim((result.stdout or ''):match('^[^\r\n]*') or '')
        if not is_capability(value) then
          return callback({
            kind = 'capability',
            message = 'capability_cmd did not print 64 lowercase hex characters',
          })
        end

        cached_value = value
        cached_until = monotonic_seconds() + config.ttl
        callback(nil, cached_value)
      end)
    end)

    if not ok then
      vim.schedule(function()
        callback({
          kind = 'capability',
          message = 'capability_cmd could not be started: ' .. one_line(job_or_error),
        })
      end)
      return nil
    end
    return job_or_error
  end

  instance.configure(initial)
  return instance
end

local default = M.new()
function M.configure(opts) return default.configure(opts) end
function M.clear() return default.clear() end
function M.configured() return default.configured() end
function M.cached() return default.cached() end
function M.get(opts, callback) return default.get(opts, callback) end

M.DEFAULT_TTL_SECONDS = DEFAULT_TTL_SECONDS
M.is_capability = is_capability

return M
