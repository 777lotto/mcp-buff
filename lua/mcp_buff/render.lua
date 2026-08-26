local fn = vim.fn

local M = {}

M.status_order = {
  'pending',
  'approved',
  'executing',
  -- indeterminate is a state of its own. Bucketing an unknown outcome with
  -- failed is the one presentation it must never be given.
  'indeterminate',
  'failed',
  'denied',
  'expired',
  'executed',
}

local STATUS_LABELS = {
  pending = 'Pending',
  approved = 'Approved',
  executing = 'Executing',
  executed = 'Executed',
  failed = 'Failed',
  indeterminate = 'Indeterminate',
  denied = 'Denied',
  expired = 'Expired',
}

local STATUS_HIGHLIGHTS = {
  pending = 'McpBuffPending',
  approved = 'McpBuffApproved',
  executing = 'McpBuffExecuting',
  executed = 'McpBuffExecuted',
  failed = 'McpBuffFailed',
  indeterminate = 'McpBuffIndeterminate',
  denied = 'McpBuffDenied',
  expired = 'McpBuffExpired',
}

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function one_line(value)
  return trim(tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '))
end

local function shorten(text, limit)
  text = tostring(text or '')
  if limit <= 1 then return '…' end
  if fn.strdisplaywidth(text) <= limit then return text end
  local chars = fn.strchars(text)
  while chars > 1 do
    local candidate = fn.strcharpart(text, 0, chars - 1) .. '…'
    if fn.strdisplaywidth(candidate) <= limit then return candidate end
    chars = chars - 1
  end
  return '…'
end

-- Gregorian civil date to Unix days, independent of the workstation timezone.
local function days_from_civil(year, month, day)
  year = year - (month <= 2 and 1 or 0)
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local adjusted_month = month + (month > 2 and -3 or 9)
  local day_of_year = math.floor((153 * adjusted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100) + day_of_year
  return era * 146097 + day_of_era - 719468
end

function M.iso_epoch(value)
  if type(value) ~= 'string' then return nil end
  local year, month, day, hour, minute, second = value:match(
    '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)')
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if not (year and month and day and hour and minute and second) then return nil end
  return days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

function M.age(created, now)
  local epoch = M.iso_epoch(created)
  if not epoch then return '?' end
  local seconds = math.max(0, math.floor((now or os.time()) - epoch))
  if seconds < 60 then return seconds .. 's' end
  if seconds < 3600 then return math.floor(seconds / 60) .. 'm' end
  if seconds < 86400 then return math.floor(seconds / 3600) .. 'h' end
  if seconds < 604800 then return math.floor(seconds / 86400) .. 'd' end
  return math.floor(seconds / 604800) .. 'w'
end

function M.pretty_json(value)
  if value == nil then return 'null' end
  local encoded = vim.json.encode(value)
  local out, depth = {}, 0
  local in_string, escaped = false, false
  local previous_nonspace

  local function append(text) out[#out + 1] = text end
  local function newline()
    append('\n' .. string.rep('  ', depth))
  end

  for index = 1, #encoded do
    local char = encoded:sub(index, index)
    if in_string then
      append(char)
      if escaped then
        escaped = false
      elseif char == '\\' then
        escaped = true
      elseif char == '"' then
        in_string = false
      end
    elseif char == '"' then
      in_string = true
      append(char)
      previous_nonspace = char
    elseif char == '{' or char == '[' then
      append(char)
      depth = depth + 1
      local next_char = encoded:sub(index + 1, index + 1)
      if not ((char == '{' and next_char == '}') or (char == '[' and next_char == ']')) then
        newline()
      end
      previous_nonspace = char
    elseif char == '}' or char == ']' then
      depth = math.max(0, depth - 1)
      local empty = (char == '}' and previous_nonspace == '{')
        or (char == ']' and previous_nonspace == '[')
      if not empty then newline() end
      append(char)
      previous_nonspace = char
    elseif char == ',' then
      append(char)
      newline()
      previous_nonspace = char
    elseif char == ':' then
      append(': ')
      previous_nonspace = char
    elseif not char:match('%s') then
      append(char)
      previous_nonspace = char
    end
  end
  return table.concat(out)
end

function M.list(tickets, opts)
  opts = opts or {}
  local width = math.max(64, opts.width or 92)
  local grouped = {}
  for _, status in ipairs(M.status_order) do grouped[status] = {} end
  for _, ticket in ipairs(tickets or {}) do
    local status = grouped[ticket.status] and ticket.status or 'failed'
    grouped[status][#grouped[status] + 1] = ticket
  end
  for _, status in ipairs(M.status_order) do
    table.sort(grouped[status], function(left, right)
      return tostring(left.created or '') > tostring(right.created or '')
    end)
  end

  local lines, map, highlights = {}, {}, {}
  local function emit(text, item, highlight)
    lines[#lines + 1] = text
    local line = #lines
    if item then map[line] = item end
    if highlight then
      highlights[#highlights + 1] = {
        line = line - 1,
        start_col = 0,
        end_col = #text,
        group = highlight,
      }
    end
  end

  local pending = #(grouped.pending or {})
  emit(('  MCP Buff  ·  %d pending'):format(pending), nil, 'McpBuffHeader')
  emit('  <CR> detail · a approve · d deny · r refresh · q close', nil, 'McpBuffHint')
  if opts.loading then emit('  ◌ Refreshing tickets…', nil, 'McpBuffExecuting') end
  if opts.error then emit('  ⚠ ' .. shorten(one_line(opts.error), width - 4), nil, 'McpBuffFailed') end
  emit('')

  for status_index, status in ipairs(M.status_order) do
    local group = grouped[status]
    emit((' ▾ %s  (%d)'):format(STATUS_LABELS[status], #group), nil,
      STATUS_HIGHLIGHTS[status])
    if #group == 0 then
      emit('     (none)', nil, 'McpBuffHint')
    else
      for _, ticket in ipairs(group) do
        local age = M.age(ticket.created, opts.now)
        local prefix = ('     %-3s  %s  '):format(age, tostring(ticket.id or '?'))
        local reason = shorten(one_line(ticket.reason), math.max(8, width - fn.strdisplaywidth(prefix)))
        emit(prefix .. reason, { kind = 'ticket', ticket = ticket }, STATUS_HIGHLIGHTS[status])
      end
    end
    if status_index < #M.status_order then emit('') end
  end

  return { lines = lines, map = map, highlights = highlights, pending = pending }
end

local function json_block(lines, value)
  lines[#lines + 1] = '```json'
  vim.list_extend(lines, vim.split(M.pretty_json(value), '\n', { plain = true }))
  lines[#lines + 1] = '```'
end

local function bullet(label, value)
  return ('- **%s:** %s'):format(label, tostring(value))
end

local function request_lines(lines, ticket)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Stored requests'
  for index, request in ipairs(ticket.requests or {}) do
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('### Step %d'):format(index - 1)
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('`%s %s`'):format(tostring(request.method or '?'), tostring(request.path or '?'))
    lines[#lines + 1] = ''
    if request.body == nil then
      lines[#lines + 1] = '_No request body._'
    else
      json_block(lines, request.body)
    end

    -- The structured precondition is part of what the operator reviews: it is
    -- inside the digest, and it is the evidence the broker will re-check.
    local precondition = request.precondition
    lines[#lines + 1] = ''
    if type(precondition) ~= 'table' then
      lines[#lines + 1] = '_No stored precondition._'
    else
      lines[#lines + 1] = ('**Precondition:** `%s %s`'):format(
        tostring(precondition.method or '?'), tostring(precondition.path or '?'))
      local expect = precondition.expect
      if type(expect) == 'table' then
        lines[#lines + 1] = ''
        lines[#lines + 1] = bullet('Expected status', expect.status or '?')
        if expect.result_sha256 then
          lines[#lines + 1] = bullet('Expected result_sha256', expect.result_sha256)
        end
        if expect.etag then
          lines[#lines + 1] = bullet('Expected ETag', expect.etag)
        end
      end
    end
  end
end

local function preflight_lines(lines, ticket)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Preflight observations'
  local observations = ticket.preflight_results or {}
  if #observations == 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '_No precondition has been checked._'
    return
  end
  for _, observation in ipairs(observations) do
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('### Step %s · %s · %s'):format(
      tostring(observation.index or '?'),
      tostring(observation.phase or '?'),
      observation.matched and 'matched' or 'DID NOT MATCH')
    lines[#lines + 1] = ''
    lines[#lines + 1] = bullet('Checked', observation.checked or '?')
    lines[#lines + 1] = ('- **Status:** expected %s, observed %s'):format(
      tostring(observation.expected_status or '?'),
      tostring(observation.observed_status or 'none'))
    if observation.expected_result_sha256 or observation.observed_result_sha256 then
      lines[#lines + 1] = ('- **result_sha256:** expected %s, observed %s'):format(
        tostring(observation.expected_result_sha256 or 'none'),
        tostring(observation.observed_result_sha256 or 'none'))
    end
    if observation.expected_etag or observation.observed_etag then
      lines[#lines + 1] = ('- **ETag:** expected %s, observed %s'):format(
        tostring(observation.expected_etag or 'none'),
        tostring(observation.observed_etag or 'none'))
    end
    if observation.error_id then
      lines[#lines + 1] = bullet('Error id', observation.error_id)
    end
  end
end

local function result_lines(lines, ticket)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Results'
  if #(ticket.results or {}) == 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '_No request has executed._'
    return
  end
  for _, result in ipairs(ticket.results) do
    lines[#lines + 1] = ''
    -- outcome is the broker's own word for what happened. "indeterminate" here
    -- means the mutation may or may not have reached Cloudflare.
    local outcome = tostring(result.outcome or (result.ok and 'succeeded' or 'rejected'))
    local status = result.status and ('HTTP ' .. tostring(result.status)) or 'no HTTP response'
    lines[#lines + 1] = ('### Step %s · %s · %s'):format(
      tostring(result.index or '?'), outcome, status)
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('`%s %s`'):format(tostring(result.method or '?'), tostring(result.path or '?'))
    if result.error then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '**Error:** ' .. tostring(result.error)
    end
    lines[#lines + 1] = ''
    json_block(lines, result.response)
  end
end

function M.detail(ticket)
  local lines = {
    '# Ticket `' .. tostring(ticket.id or '?') .. '`',
    '',
    bullet('Status', ticket.status or '?'),
    bullet('Created', ticket.created or '?'),
    -- expires is rendered on every path: a ticket can expire between the read
    -- and the decision, and the operator has to be able to see that coming.
    bullet('Expires', ticket.expires or '?'),
    bullet('Requests', #(ticket.requests or {})),
    '',
    '- **ticket_sha256:**',
    '  `' .. tostring(ticket.ticket_sha256 or 'missing') .. '`',
    '',
    '## Reason',
    '',
    tostring(ticket.reason or ''),
  }

  request_lines(lines, ticket)
  preflight_lines(lines, ticket)
  result_lines(lines, ticket)

  if ticket.status == 'indeterminate' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Indeterminate'
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'The outcome of this ticket is genuinely unknown: a mutation '
      .. 'may or may not have reached Cloudflare. Inspect it upstream. This is not '
      .. 'a retry signal, and this ticket must never be replayed.'
  end

  -- The broker returns the denial reason as denial_note, not note.
  if ticket.denial_note then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Denial note'
    lines[#lines + 1] = ''
    lines[#lines + 1] = tostring(ticket.denial_note)
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '_Press `q` or `<Esc>` to close._'
  return table.concat(lines, '\n')
end

--- The typed-confirmation prompt.
---
--- The contract requires the operator to type the digest's final eight
--- characters. A single keypress bound to "approve" does not satisfy it, and
--- neither does a yes/no prompt.
function M.confirm_prompt(ticket, action)
  local digest = tostring(ticket.ticket_sha256 or '')
  local suffix = digest:sub(-8)
  return ('ticket_sha256: %s\nType the final digest bytes %s to %s: '):format(
    digest, suffix, action)
end

function M.digest_suffix(ticket)
  return tostring(ticket.ticket_sha256 or ''):sub(-8)
end

return M
