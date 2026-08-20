local fn = vim.fn

local M = {}
local Client = {}
Client.__index = Client

local STATUSES = {
  pending = true,
  approved = true,
  executing = true,
  executed = true,
  failed = true,
  denied = true,
  expired = true,
}

local TICKET_ID = '^t_%d%d%d%d%d%d%d%dT%d%d%d%d%d%d%.%d%d%dZ_[a-f0-9]+$'

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function one_line(value)
  local text = trim(tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '))
  if #text > 500 then text = text:sub(1, 499) .. '…' end
  return text
end

local function decode_json(text)
  local ok, decoded = pcall(vim.json.decode, text or '')
  if not ok then
    return nil, {
      kind = 'decode',
      message = 'mcp-broker returned invalid JSON: ' .. one_line(decoded),
    }
  end
  return decoded
end

local function response_error(status, body)
  local decoded = decode_json(body)
  local message
  if type(decoded) == 'table' and type(decoded.error) == 'string' then
    message = decoded.error
  elseif status == 404 then
    message = 'Ticket not found.'
  elseif status == 409 then
    message = 'Ticket state changed; refresh before acting.'
  else
    message = one_line(body)
  end
  if trim(message) == '' then message = 'mcp-broker request failed without an error message.' end
  return { kind = 'http', status = status, message = one_line(message) }
end

function M.normalize_endpoint(value)
  if type(value) ~= 'string' then
    return nil, 'endpoint must be loopback HTTP in the form http://127.0.0.1:PORT'
  end
  value = trim(value):gsub('/+$', '')
  local port = value:match('^http://127%.0%.0%.1:(%d+)$')
  port = tonumber(port)
  if not port or port < 1 or port > 65535 or port ~= math.floor(port) then
    return nil, 'endpoint must be loopback HTTP in the form http://127.0.0.1:PORT'
  end
  return value
end

local function valid_ticket_id(ticket_id)
  return type(ticket_id) == 'string' and ticket_id:match(TICKET_ID) ~= nil
end

local function default_spawn(command, opts, callback)
  return vim.system(command, opts, callback)
end

function Client.new(opts)
  opts = opts or {}
  local endpoint, endpoint_error = M.normalize_endpoint(opts.endpoint or 'http://127.0.0.1:8792')
  if not endpoint then error('mcp_buff client: ' .. endpoint_error) end

  return setmetatable({
    endpoint = endpoint,
    curl_command = opts.curl_command or 'curl',
    timeout = math.max(1000, math.floor(tonumber(opts.timeout) or 300000)),
    spawn = opts.spawn or default_spawn,
    executable = opts.executable or function(command) return fn.executable(command) == 1 end,
    schedule = opts.schedule or vim.schedule,
  }, Client)
end

function Client:_request(method, path, body, callback)
  if not self.executable(self.curl_command) then
    return callback({ kind = 'transport', message = 'mcp-buff requires curl on PATH.' })
  end

  local timeout_seconds = math.max(1, math.ceil(self.timeout / 1000))
  local command = {
    self.curl_command,
    '--disable',
    '--silent',
    '--show-error',
    '--max-time',
    tostring(timeout_seconds),
    '--write-out',
    '\n%{http_code}',
    '--header',
    'Accept: application/json',
    '--url',
    self.endpoint .. path,
  }
  local stdin
  if method ~= 'GET' then
    command[#command + 1] = '--request'
    command[#command + 1] = method
  end
  if body ~= nil then
    command[#command + 1] = '--header'
    command[#command + 1] = 'Content-Type: application/json'
    command[#command + 1] = '--data-binary'
    command[#command + 1] = '@-'
    stdin = vim.json.encode(body)
  end

  local ok, job_or_error = pcall(self.spawn, command, {
    text = true,
    stdin = stdin,
    timeout = self.timeout,
  }, function(result)
    self.schedule(function()
      if result.code ~= 0 then
        local detail = one_line(result.stderr)
        if detail == '' then detail = 'curl exited with code ' .. tostring(result.code) end
        return callback({ kind = 'network', message = detail })
      end

      local response_body, status_text = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
      local status = tonumber(status_text)
      if response_body == nil or status == nil then
        return callback({ kind = 'decode', message = 'curl returned an invalid HTTP response.' })
      end
      if status < 200 or status >= 300 then
        return callback(response_error(status, response_body))
      end
      if trim(response_body) == '' then return callback(nil, nil) end
      local decoded, decode_error = decode_json(response_body)
      callback(decode_error, decoded)
    end)
  end)
  if not ok then
    self.schedule(function()
      callback({ kind = 'transport', message = one_line(job_or_error) })
    end)
    return nil
  end
  return job_or_error
end

function Client:list(status, callback)
  if status ~= nil and not STATUSES[status] then
    return callback({ kind = 'configuration', message = 'unknown ticket status: ' .. tostring(status) })
  end
  local path = '/tickets' .. (status and ('?status=' .. status) or '')
  return self:_request('GET', path, nil, function(err, payload)
    if err then return callback(err) end
    if type(payload) ~= 'table' or type(payload.tickets) ~= 'table' then
      return callback({ kind = 'decode', message = 'ticket list response has no tickets array.' })
    end
    callback(nil, payload.tickets)
  end)
end

function Client:get(ticket_id, callback)
  if not valid_ticket_id(ticket_id) then
    return callback({ kind = 'configuration', message = 'invalid ticket id.' })
  end
  return self:_request('GET', '/tickets/' .. ticket_id, nil, callback)
end

function Client:approve(ticket_id, callback)
  if not valid_ticket_id(ticket_id) then
    return callback({ kind = 'configuration', message = 'invalid ticket id.' })
  end
  return self:_request('POST', '/tickets/' .. ticket_id .. '/approve', nil, callback)
end

function Client:deny(ticket_id, note, callback)
  if not valid_ticket_id(ticket_id) then
    return callback({ kind = 'configuration', message = 'invalid ticket id.' })
  end
  note = note and trim(note) or nil
  if note == '' then note = nil end
  return self:_request('POST', '/tickets/' .. ticket_id .. '/deny',
    note and { note = note } or {}, callback)
end

M.Client = Client
M.new = Client.new
M.statuses = STATUSES

return M
