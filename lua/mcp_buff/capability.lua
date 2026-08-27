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

local config = {
  cmd = nil,
  ttl = DEFAULT_TTL_SECONDS,
  fetch_timeout = DEFAULT_FETCH_TIMEOUT_MS,
  spawn = nil,
}

-- Held in memory only. Lua strings are immutable and interned, so clear() drops
-- the reference rather than wiping bytes; the value never leaves this process.
local cached_value
local cached_until

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

function M.configure(opts)
  opts = opts or {}
  M.clear()
  config.cmd = opts.cmd
  config.ttl = opts.ttl or DEFAULT_TTL_SECONDS
  config.fetch_timeout = opts.fetch_timeout or DEFAULT_FETCH_TIMEOUT_MS
  config.spawn = opts.spawn
end

function M.clear()
  cached_value = nil
  cached_until = nil
end

function M.configured()
  return config.cmd ~= nil
end

--- True when a live cached value would satisfy the next request without a fetch.
function M.cached()
  return cached_value ~= nil and cached_until ~= nil and monotonic_seconds() < cached_until
end

--- Resolve the capability.
---
--- opts.allow_fetch  when false, never run capability_cmd; a cold or expired
---                   cache fails instead. The background refresh timer uses this
---                   so a timer tick can never raise a credential prompt.
--- opts.force        drop any cached value and fetch again. Used once after a
---                   401, in case the capability was rotated mid-session.
function M.get(opts, callback)
  opts = opts or {}

  if not config.cmd then
    return callback({
      kind = 'capability',
      message = 'no admin capability is configured; set capability_cmd to an argv '
        .. 'list that prints the 64-hex broker admin capability',
    })
  end

  if not opts.force and M.cached() then
    return callback(nil, cached_value)
  end

  M.clear()

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

M.DEFAULT_TTL_SECONDS = DEFAULT_TTL_SECONDS
M.is_capability = is_capability

return M
