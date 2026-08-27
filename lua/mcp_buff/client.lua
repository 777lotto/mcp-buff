-- Loopback curl transport for the hardened mcp-broker admin API.
--
-- Two rules shape this file. The capability is the only secret, so it travels on
-- a private channel (a curl config file on stdin) while the non-secret decision
-- body travels through ordinary argv. And a decision is never resubmitted: if a
-- decision POST fails, times out, or comes back undecodable, the outcome is
-- resolved by polling the same ticket, never by sending it again.

local fn = vim.fn
local capability_module = require('mcp_buff.capability')

local M = {}
local Client = {}
Client.__index = Client

local STATUSES = {
  pending = true,
  approved = true,
  executing = true,
  executed = true,
  failed = true,
  indeterminate = true,
  denied = true,
  expired = true,
}

local TERMINAL_STATUSES = {
  executed = true,
  failed = true,
  indeterminate = true,
  denied = true,
  expired = true,
}

local TICKET_ID = '^t_%d%d%d%d%d%d%d%dT%d%d%d%d%d%d%.%d%d%dZ_[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]$'

local DEFAULT_READ_TIMEOUT_MS = 30000
local DEFAULT_DECISION_TIMEOUT_S = 1865
local DEFAULT_POLL_DEADLINE_S = 1865
local POLL_INTERVAL_MS = 2000
local MIN_DECISION_SECONDS = 65
local MAX_DECISION_SECONDS = 86400
-- curl must be the component that gives up, not vim.system, so the process
-- budget sits above the transfer budget.
local SPAWN_GRACE_MS = 15000

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function one_line(value)
  local text = trim(tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '))
  if #text > 500 then text = text:sub(1, 499) .. '…' end
  return text
end

function M.clamp_decision_seconds(value, fallback)
  local seconds = math.floor(tonumber(value) or fallback)
  if seconds < MIN_DECISION_SECONDS then return MIN_DECISION_SECONDS end
  if seconds > MAX_DECISION_SECONDS then return MAX_DECISION_SECONDS end
  return seconds
end

function M.is_terminal(status)
  return TERMINAL_STATUSES[status] == true
end

--- Decode an admin response body without assuming it is JSON.
--- Off-route requests reach Express's finalhandler and come back as HTML, and an
--- oversized body produces a bare 500, so "every error carries {"error":...}" is
--- not a safe assumption.
function M.decode_body(body)
  local text = trim(body or '')
  if text == '' then return nil, 'empty' end
  if text:sub(1, 1) == '<' then return nil, 'html' end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= 'table' then return nil, 'opaque' end
  return decoded, 'json'
end

local function body_error_message(decoded)
  if type(decoded) == 'table' and type(decoded.error) == 'string' then
    return decoded.error
  end
  return nil
end

--- Map an HTTP failure onto a named gate or handler outcome.
---
--- The four transport gates share one middleware chain in a fixed order, so a
--- status names the first gate that failed rather than the worst thing wrong
--- with the request. `definitive` marks the failures where the broker refused
--- before touching the ticket, which are the only ones safe to report without
--- polling.
function M.classify(status, body, context)
  local decoded, shape = M.decode_body(body)
  local reported = body_error_message(decoded)

  if status == 403 then
    return {
      kind = 'gate_origin', status = status, gate = 'origin', definitive = true,
      message = 'the broker refused an Origin header (403). mcp-buff must never '
        .. 'send one; a proxy in front of the tunnel is adding it.',
    }
  end

  if status == 400 and reported == 'invalid host' then
    return {
      kind = 'gate_host', status = status, gate = 'host', definitive = true,
      retryable = false,
      message = 'the broker rejected the request Host (400). The local forward '
        .. 'port must equal the broker admin port, as in '
        .. 'ssh -L 8792:127.0.0.1:8792, or the Host header must be overridden to '
        .. 'the broker port. This is a configuration fault, not a body error: do '
        .. 'not resubmit a decision to "fix" it.',
    }
  end

  if status == 401 then
    return {
      kind = 'gate_bearer', status = status, gate = 'bearer', definitive = true,
      message = 'the broker rejected the admin capability (401). Missing, '
        .. 'malformed, and wrong capabilities are indistinguishable here.',
    }
  end

  if status == 415 then
    return {
      kind = 'gate_content_type', status = status, gate = 'content_type',
      definitive = true,
      message = 'the broker required application/json on this POST (415). The '
        .. 'request was refused at the gate, before any schema ran.',
    }
  end

  if status == 400 and reported == 'invalid JSON body' then
    return {
      kind = 'invalid_json', status = status, definitive = true,
      message = 'the broker could not parse the decision body (400).',
    }
  end

  if status == 400 then
    local detail = reported or 'invalid request'
    return {
      kind = 'schema', status = status, definitive = true,
      message = 'the broker rejected the decision body against its strict schema '
        .. '(400): ' .. one_line(detail),
    }
  end

  if status == 404 then
    return {
      kind = 'not_found', status = status, definitive = true,
      message = 'the broker has no such ticket (404). A terminal ticket is '
        .. 'unlinked once it is past the retention window, and a listing call is '
        .. 'what prunes it.',
    }
  end

  if status == 409 then
    local text = reported or ''
    -- Status alone cannot separate the two 409s; only the message text can.
    if text:find('digest does not match', 1, true) then
      return {
        kind = 'digest_conflict', status = status, definitive = true,
        message = 'the broker refused the digest (409): it does not match the '
          .. 'reviewed immutable payload. No Cloudflare request was sent.',
      }
    end
    if text:find('cannot transition', 1, true) then
      return {
        kind = 'state_conflict', status = status, definitive = true,
        message = 'the ticket expired or was decided while you were reviewing '
          .. '(409): ' .. one_line(text),
      }
    end
    return {
      kind = 'conflict', status = status, definitive = true,
      message = 'the broker reported a conflict (409): ' .. one_line(text),
    }
  end

  if status == 500 then
    local hint = 'the broker returned 500.'
    if context == 'decision' then
      -- A body over the 32kb express.json cap is neither a Zod error nor a
      -- 400-tagged SyntaxError, so it falls through to a bare 500.
      hint = hint .. ' On a decision this may be nothing worse than an oversized '
        .. 'note, but the outcome is not known from the status alone.'
    end
    return { kind = 'server', status = status, definitive = false, message = hint }
  end

  local detail
  if shape == 'html' then
    detail = 'the broker returned an HTML body, which means the request went to a '
      .. 'route it does not serve'
  elseif reported then
    detail = one_line(reported)
  elseif shape == 'empty' then
    detail = 'the broker returned no body'
  else
    detail = one_line(body)
  end
  return {
    kind = 'http', status = status, definitive = false,
    message = ('the broker returned HTTP %s: %s'):format(tostring(status), detail),
  }
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

M.valid_ticket_id = valid_ticket_id

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
    timeout = math.max(1000, math.floor(tonumber(opts.timeout) or DEFAULT_READ_TIMEOUT_MS)),
    decision_timeout = M.clamp_decision_seconds(opts.decision_timeout, DEFAULT_DECISION_TIMEOUT_S),
    poll_deadline = M.clamp_decision_seconds(opts.poll_deadline, DEFAULT_POLL_DEADLINE_S),
    host_header = opts.host_header,
    spawn = opts.spawn or default_spawn,
    executable = opts.executable or function(command) return fn.executable(command) == 1 end,
    schedule = opts.schedule or vim.schedule,
    defer = opts.defer or function(callback, ms) vim.defer_fn(callback, ms) end,
    capability = opts.capability or capability_module,
  }, Client)
end

function Client:_curl_argv(method, path, body, timeout_seconds)
  local command = {
    self.curl_command,
    '--disable',
    '--silent',
    '--show-error',
    '--noproxy', '*',
    '--proto', '=http',
    '--max-redirs', '0',
    '--connect-timeout', '5',
    '--max-time', tostring(timeout_seconds),
    '--write-out', '\n%{http_code}',
    '--header', 'Accept: application/json',
    -- The capability arrives here, from stdin, and never from argv.
    '--config', '-',
  }
  if self.host_header then
    command[#command + 1] = '--header'
    command[#command + 1] = 'Host: ' .. self.host_header
  end
  if method ~= 'GET' then
    command[#command + 1] = '--request'
    command[#command + 1] = method
  end
  if body ~= nil then
    -- Every POST carries a content type. A bodyless approve is refused at the
    -- 415 gate, never at the schema.
    command[#command + 1] = '--header'
    command[#command + 1] = 'Content-Type: application/json'
    -- The decision body is not secret, so it goes through ordinary arguments.
    -- --data-raw, not --data-binary, so a leading @ is never read as a file.
    command[#command + 1] = '--data-raw'
    command[#command + 1] = body
  end
  command[#command + 1] = '--url'
  command[#command + 1] = self.endpoint .. path
  return command
end

function Client:_request(method, path, options, callback)
  options = options or {}
  if not self.executable(self.curl_command) then
    return callback({ kind = 'transport', message = 'mcp-buff requires curl on PATH.' })
  end

  local timeout_seconds = options.timeout_seconds
    or math.max(1, math.ceil(self.timeout / 1000))
  local spawn_timeout = timeout_seconds * 1000 + SPAWN_GRACE_MS

  -- A failed capability fetch must abort the request. It must never fall through
  -- to an unauthenticated send, which would surface as an opaque 401 instead of
  -- the real cause.
  self.capability.get({
    allow_fetch = options.allow_capability_fetch,
    force = options.force_capability,
  }, function(capability_error, capability)
    if capability_error then return callback(capability_error) end

    local command = self:_curl_argv(method, path, options.body, timeout_seconds)
    local stdin = ('header = "Authorization: Bearer %s"\n'):format(capability)

    local ok, job_or_error = pcall(self.spawn, command, {
      text = true,
      stdin = stdin,
      timeout = spawn_timeout,
    }, function(result)
      self.schedule(function()
        if result.code ~= 0 then
          local detail = one_line(result.stderr)
          if detail == '' then
            detail = 'curl exited with code ' .. tostring(result.code)
          end
          return callback({
            kind = 'network',
            definitive = false,
            message = detail,
          })
        end

        local response_body, status_text = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
        local status = tonumber(status_text)
        if response_body == nil or status == nil then
          return callback({
            kind = 'decode',
            definitive = false,
            message = 'curl returned an invalid HTTP response.',
          })
        end

        if status == 401 and not options.force_capability
          and options.allow_capability_fetch ~= false then
          -- The bearer gate runs before routing, so nothing was touched. One
          -- forced refetch covers a capability rotated mid-session; after that
          -- the failure is surfaced rather than retried.
          local retry = vim.deepcopy(options)
          retry.force_capability = true
          return self:_request(method, path, retry, callback)
        end

        if status < 200 or status >= 300 then
          return callback(M.classify(status, response_body, options.context))
        end

        if trim(response_body) == '' then return callback(nil, nil) end
        local decoded, shape = M.decode_body(response_body)
        if shape ~= 'json' then
          return callback({
            kind = 'decode',
            definitive = false,
            message = 'the broker returned a 2xx body that is not JSON.',
          })
        end
        callback(nil, decoded)
      end)
    end)

    if not ok then
      self.schedule(function()
        callback({ kind = 'transport', definitive = false, message = one_line(job_or_error) })
      end)
    end
  end)
end

function Client:list(status, opts, callback)
  if type(opts) == 'function' then
    callback, opts = opts, {}
  end
  opts = opts or {}
  if status ~= nil and not STATUSES[status] then
    return callback({ kind = 'configuration', message = 'unknown ticket status: ' .. tostring(status) })
  end
  local path = '/tickets' .. (status and ('?status=' .. status) or '')
  return self:_request('GET', path, {
    allow_capability_fetch = opts.allow_capability_fetch,
  }, function(err, payload)
    if err then return callback(err) end
    if type(payload) ~= 'table' or type(payload.tickets) ~= 'table' then
      return callback({ kind = 'decode', message = 'ticket list response has no tickets array.' })
    end
    callback(nil, payload.tickets)
  end)
end

function Client:get(ticket_id, opts, callback)
  if type(opts) == 'function' then
    callback, opts = opts, {}
  end
  opts = opts or {}
  if not valid_ticket_id(ticket_id) then
    return callback({ kind = 'configuration', message = 'invalid ticket id.' })
  end
  return self:_request('GET', '/tickets/' .. ticket_id, {
    allow_capability_fetch = opts.allow_capability_fetch,
  }, callback)
end

--- Poll one ticket until it reaches a terminal state.
---
--- This is the only thing a client may do after a decision POST it cannot
--- account for. It never sends the decision again.
function Client:poll_until_terminal(ticket_id, handlers)
  handlers = handlers or {}
  local on_progress = handlers.on_progress or function() end
  local callback = handlers.callback
  local deadline_ms = self.poll_deadline * 1000
  local waited = 0

  local function attempt()
    self:get(ticket_id, { allow_capability_fetch = false }, function(err, ticket)
      if err then
        return callback({
          kind = 'unknown_outcome',
          definitive = false,
          message = 'the decision outcome is unknown because the ticket could not '
            .. 'be fetched: ' .. one_line(err.message) .. '. Restore the tunnel and '
            .. 'inspect the ticket. Never resubmit the decision.',
        })
      end
      if type(ticket) == 'table' and M.is_terminal(ticket.status) then
        return callback(nil, ticket, { outcome = 'terminal', polled = true })
      end
      if waited >= deadline_ms then
        return callback({
          kind = 'unknown_outcome',
          definitive = false,
          ticket = ticket,
          message = 'the decision did not reach a terminal state within the poll '
            .. 'deadline. The outcome is unknown; inspect the ticket and never '
            .. 'resubmit the decision.',
        })
      end
      waited = waited + POLL_INTERVAL_MS
      on_progress(('waiting for a terminal state (%ds)…'):format(math.floor(waited / 1000)))
      self.defer(attempt, POLL_INTERVAL_MS)
    end)
  end

  attempt()
end

--- Submit one decision and account for its outcome.
---
--- action is "approve" or "deny". The digest is required by both strict schemas;
--- deny additionally accepts a trimmed 1..4000 character note.
function Client:decide(ticket_id, action, decision, handlers)
  handlers = handlers or {}
  local callback = handlers.callback
  local on_progress = handlers.on_progress or function() end

  if action ~= 'approve' and action ~= 'deny' then
    return callback({ kind = 'configuration', message = 'unknown decision: ' .. tostring(action) })
  end
  if not valid_ticket_id(ticket_id) then
    return callback({ kind = 'configuration', message = 'invalid ticket id.' })
  end

  local digest = decision and decision.ticket_sha256
  if type(digest) ~= 'string' or #digest ~= 64 or not digest:match('^[a-f0-9]+$') then
    return callback({ kind = 'configuration', message = 'a 64-hex ticket_sha256 is required.' })
  end

  -- Strict schemas: nothing beyond these keys may be sent.
  local payload = { ticket_sha256 = digest }
  if action == 'deny' then
    local note = decision.note and trim(decision.note) or nil
    if note == '' then note = nil end
    if note ~= nil then
      if #note > 4000 then
        return callback({
          kind = 'configuration',
          message = 'the denial note must be 4000 characters or fewer.',
        })
      end
      payload.note = note
    end
  end

  local function resolve_by_polling(reason)
    on_progress(reason .. ' Polling the same ticket; the decision is not resent.')
    self:poll_until_terminal(ticket_id, { on_progress = on_progress, callback = callback })
  end

  self:_request('POST', '/tickets/' .. ticket_id .. '/' .. action, {
    body = vim.json.encode(payload),
    timeout_seconds = self.decision_timeout,
    context = 'decision',
  }, function(err, ticket)
    if err then
      if err.definitive then return callback(err) end
      return resolve_by_polling(one_line(err.message))
    end
    if type(ticket) ~= 'table' or type(ticket.status) ~= 'string' then
      return resolve_by_polling('The broker returned a decision body mcp-buff could not read.')
    end
    -- Approval executes synchronously, so a 200 is always terminal. A
    -- non-terminal 200 cannot occur; if one ever does, resolve it by polling
    -- rather than by guessing.
    if not M.is_terminal(ticket.status) then
      return resolve_by_polling(('The broker returned a non-terminal %s.'):format(ticket.status))
    end
    callback(nil, ticket, { outcome = 'terminal', polled = false })
  end)
end

M.Client = Client
M.new = Client.new
M.statuses = STATUSES
M.terminal_statuses = TERMINAL_STATUSES

return M
