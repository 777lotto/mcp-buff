-- Panel rendering: the tab bar, one provider's tab body, and ticket detail.
--
-- Everything here is provider-agnostic scaffolding. Which statuses exist, what
-- they are called, how a stored request reads, and what an approval licenses
-- are all answered by the tab's source module (`mcp_buff.sources.*`), so this
-- file never grows a branch per broker.

local fn = vim.fn
local sources = require('mcp_buff.sources')

local M = {}

-- A status the broker served that this release has no entry for. It is given
-- its own bucket and its own warning, and it is never folded into a status
-- that happens to be nearby: `failed` would claim the request definitely did
-- not happen and `pending` would offer a decision, and both would be a guess
-- about a word this client does not know.
M.UNKNOWN_STATUS_LABEL = 'Unrecognised status'

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

M.shorten = shorten
M.one_line = one_line

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

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

--- Accumulate lines, cursor targets, and highlight spans together.
---
--- The line map is what makes a keystroke unambiguous: a row is a ticket row, a
--- permission row, or nothing, and an action that lands on nothing says so
--- rather than acting on whatever was nearby.
local function new_buffer(width)
  return {
    width = width,
    lines = {},
    map = {},
    highlights = {},
    emit = function(self, text, item, highlight)
      self.lines[#self.lines + 1] = text
      local line = #self.lines
      if item then self.map[line] = item end
      if highlight then
        self.highlights[#self.highlights + 1] = {
          line = line - 1,
          start_col = 0,
          end_col = #text,
          group = highlight,
        }
      end
      return line
    end,
    span = function(self, line, start_col, end_col, group)
      self.highlights[#self.highlights + 1] = {
        line = line - 1,
        start_col = start_col,
        end_col = end_col,
        group = group,
      }
    end,
  }
end

--- The tab bar: `▸ 1 Cloudflare 2   2 Git*`.
---
--- The number after a label is that provider's pending ticket count, and `*`
--- marks unapplied permission edits. Both are counts of work waiting on the
--- operator, and putting them on the bar is what lets the inactive tab ask for
--- attention -- a pending ticket the operator never switched to is exactly the
--- thing this panel exists to surface.
local function tab_bar(out, tabs, active_id)
  local text, spans = '  ', {}
  for index, tab in ipairs(tabs) do
    local badge = ''
    if tab.pending and tab.pending > 0 then badge = ' ' .. tab.pending end
    if tab.dirty then badge = badge .. '*' end
    local label = (tab.id == active_id and '▸ ' or '  ')
      .. index .. ' ' .. tab.label .. badge
    if index > 1 then text = text .. '   ' end
    local start_col = #text
    text = text .. label
    spans[#spans + 1] = { id = tab.id, start_col = start_col, end_col = #text }
  end
  local line = out:emit(text)
  for _, span in ipairs(spans) do
    out:span(line, span.start_col, span.end_col,
      span.id == active_id and 'McpBuffTabActive' or 'McpBuffTabInactive')
  end
end

--- Group one provider's ticket summaries by status, newest first within a
--- group, with anything unrecognised collected separately.
function M.group_tickets(source, tickets)
  local grouped, unknown = {}, {}
  for _, status in ipairs(source.status_order) do grouped[status] = {} end
  for _, ticket in ipairs(tickets or {}) do
    local bucket = grouped[ticket.status] or unknown
    bucket[#bucket + 1] = ticket
  end
  local function newest_first(left, right)
    local left_created = tostring(left.created or '')
    local right_created = tostring(right.created or '')
    if left_created ~= right_created then return left_created > right_created end
    -- Millisecond timestamps can still tie. A deterministic id tie-break keeps
    -- a preview move aligned with a separately rendered copy of the same list.
    return tostring(left.id or '') < tostring(right.id or '')
  end
  for _, status in ipairs(source.status_order) do
    table.sort(grouped[status], newest_first)
  end
  table.sort(unknown, newest_first)
  return grouped, unknown
end

--- The non-empty categories in exactly the order the panel displays them.
---
--- Preview navigation consumes this rather than rebuilding status order from
--- the ticket under the cursor. That keeps `>`/`<` on the visible list order
--- and lets `<Tab>` skip the empty headings the panel renders for orientation.
--- All statuses unknown to this release remain one category, just as they are
--- in the panel; guessing an order between unknown state names would invent a
--- state machine the source has not declared.
function M.ticket_categories(source, tickets)
  local grouped, unknown = M.group_tickets(source, tickets)
  local categories = {}
  for _, status in ipairs(source.status_order) do
    local group = grouped[status]
    if #group > 0 then
      categories[#categories + 1] = {
        id = status,
        label = source.status_labels[status],
        tickets = group,
      }
    end
  end
  if #unknown > 0 then
    categories[#categories + 1] = {
      id = 'unknown',
      label = M.UNKNOWN_STATUS_LABEL,
      tickets = unknown,
    }
  end
  return categories
end

function M.pending_count(source, tickets)
  local count = 0
  for _, ticket in ipairs(tickets or {}) do
    if source.decidable[ticket.status] then count = count + 1 end
  end
  return count
end

local function ticket_row(out, tab, ticket, highlight, now)
  local age = M.age(ticket.created, now)
  local prefix = ('     %-3s  %s  '):format(age, tostring(ticket.id or '?'))
  local room = math.max(8, out.width - fn.strdisplaywidth(prefix))
  local reason = shorten(one_line(ticket.reason), room)
  out:emit(prefix .. reason, { kind = 'ticket', tab = tab, ticket = ticket }, highlight)
end

local function ticket_section(out, tab, now)
  local source = tab.source
  local grouped, unknown = M.group_tickets(source, tab.tickets)

  for _, status in ipairs(source.status_order) do
    local group = grouped[status]
    out:emit((' ▾ Tickets · %s  (%d)'):format(source.status_labels[status], #group),
      nil, source.status_highlights[status])
    if #group == 0 then
      out:emit('     (none)', nil, 'McpBuffHint')
    else
      for _, ticket in ipairs(group) do
        ticket_row(out, tab, ticket, source.status_highlights[status], now)
      end
    end
    out:emit('')
  end

  if #unknown > 0 then
    out:emit((' ▾ Tickets · %s  (%d)'):format(M.UNKNOWN_STATUS_LABEL, #unknown),
      nil, 'McpBuffIndeterminate')
    out:emit('     A status this release has no entry for. Neither decidable',
      nil, 'McpBuffHint')
    out:emit('     nor known to be finished.', nil, 'McpBuffHint')
    for _, ticket in ipairs(unknown) do
      ticket_row(out, tab, ticket, 'McpBuffIndeterminate', now)
    end
    out:emit('')
  end
end

local function permission_state(tab)
  if tab.permissions.applying then return 'applying…' end
  if tab.permissions.loading then return 'loading…' end
  if tab.permissions.outcome_unknown then return 'apply outcome unknown' end
  if tab.permissions.error then return 'unavailable' end
  if not tab.permissions.snapshot then return 'not loaded' end
  local changed = tab.permissions.changed or 0
  if changed > 0 then return ('%d unsaved change%s'):format(changed, changed == 1 and '' or 's') end
  return 'saved'
end

local function permission_section(out, tab)
  local state = tab.permissions
  out:emit((' ▾ Runtime permissions   [%s]'):format(permission_state(tab)),
    nil, 'McpBuffHeader')
  out:emit('     Narrows this broker below its compiled ceiling. Never a',
    nil, 'McpBuffHint')
  out:emit('     credential or app-permission editor.', nil, 'McpBuffHint')

  if state.error then
    out:emit('     ⚠ ' .. shorten(one_line(state.error), math.max(8, out.width - 8)),
      nil, 'McpBuffFailed')
  end
  if not state.snapshot then
    out:emit('')
    return
  end

  local digest = state.snapshot.permissions_sha256
  out:emit(('     state %s…%s'):format(digest:sub(1, 8), digest:sub(-8)), nil, 'McpBuffHint')
  if state.outcome_unknown then
    out:emit('     APPLY OUTCOME UNKNOWN — refresh before making another change.',
      nil, 'McpBuffFailed')
  elseif state.must_refresh then
    out:emit('     STATE MAY BE STALE — refresh before changing or applying.',
      nil, 'McpBuffIndeterminate')
  end

  for index, permission in ipairs(state.snapshot.permissions) do
    local marker = permission.enabled and '[x]' or '[ ]'
    local edited = permission.enabled ~= state.baseline[permission.id]
    local title = shorten(one_line(permission.title), 30)
    local room = math.max(18, out.width - 41)
    out:emit(('   %s %s %-30s %s'):format(
      marker, edited and '·' or ' ', title,
      shorten(one_line(permission.description), room)),
      { kind = 'permission', tab = tab, index = index },
      permission.enabled and 'McpBuffPermissionEnabled' or 'McpBuffPermissionDisabled')
    out:emit('           ' .. permission.id, nil, 'McpBuffHint')
  end
  out:emit('')
end

--- Render the whole panel for one active tab.
---
--- @param tabs table each entry: id, label, pending, dirty
--- @param tab table the active tab: source, tickets, permissions, broker state
function M.panel(tabs, tab, opts)
  opts = opts or {}
  local out = new_buffer(math.max(64, opts.width or 92))

  out:emit('  MCP Buff · Broker Review', nil, 'McpBuffHeader')
  tab_bar(out, tabs, tab.id)
  out:emit('  <CR> detail/toggle · a approve · d deny · A apply permissions', nil, 'McpBuffHint')
  out:emit('  <Tab> next tab · 1-' .. #tabs .. ' jump · r refresh · q close', nil, 'McpBuffHint')

  if not tab.configured then
    out:emit('')
    out:emit(('  %s has no capability_cmd, so this tab cannot authenticate.')
      :format(tab.source.title), nil, 'McpBuffFailed')
    out:emit(('  Set %s in setup() to an argv list that prints its 64-hex '
      .. 'admin capability.'):format(tab.source.capability_cmd_key),
      nil, 'McpBuffHint')
    out:emit('')
    return { lines = out.lines, map = out.map, highlights = out.highlights }
  end

  if tab.loading then out:emit('  ◌ Refreshing…', nil, 'McpBuffExecuting') end
  if tab.error then
    out:emit('  ⚠ ' .. shorten(one_line(tab.error), out.width - 4), nil, 'McpBuffFailed')
  end
  out:emit('')

  ticket_section(out, tab, opts.now)
  if tab.shows_permissions then permission_section(out, tab) end

  return { lines = out.lines, map = out.map, highlights = out.highlights }
end

-- ---------------------------------------------------------------------------
-- Ticket detail
-- ---------------------------------------------------------------------------

local function bullet(label, value)
  return ('- **%s:** %s'):format(label, tostring(value))
end

local function request_lines(lines, source, ticket)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Stored requests'
  local requests = ticket.requests or {}
  if #requests == 0 then
    lines[#lines + 1] = ''
    -- Both brokers reject a ticket with no request, so this is a served
    -- document that should not exist rather than an empty-but-fine ticket.
    lines[#lines + 1] = '_This ticket carries no request. It licenses nothing '
      .. 'that mcp-buff can show; do not approve it._'
    return
  end
  for index, request in ipairs(requests) do
    local scope = sources.match_scope(source, request)
    lines[#lines + 1] = ''
    -- Scope, then the one line that names the grant rather than the shape. A
    -- scope this release cannot name says so right here, in the heading of the
    -- step it belongs to.
    lines[#lines + 1] = ('### Step %d · %s · %s'):format(
      index - 1, scope.title, one_line(scope.summary(request)))
    lines[#lines + 1] = ''
    scope.render(lines, request, M)
  end
end

function M.detail(source, ticket)
  local lines = {
    ('# %s `%s`'):format(source.tab_label, tostring(ticket.id or '?')),
    '',
    bullet('Broker', source.title),
    bullet('Status', ticket.status or '?'),
    bullet('Created', ticket.created or '?'),
    -- expires is rendered on every path: a ticket can expire between the read
    -- and the decision, and the operator has to be able to see that coming.
    bullet('Expires', ticket.expires or '?'),
  }
  vim.list_extend(lines, source.detail_facts(ticket))
  vim.list_extend(lines, {
    '',
    '- **ticket_sha256:**',
    '  `' .. tostring(ticket.ticket_sha256 or 'missing') .. '`',
    '',
    '## Reason',
    '',
    tostring(ticket.reason or ''),
  })

  -- Only on a ticket that can still be decided. On a decided one the sentence
  -- would describe an offer that is no longer open, and the status sections
  -- below already say what happened instead.
  if source.decidable[ticket.status] then
    vim.list_extend(lines, {
      '',
      '## What approval does',
      '',
      'Approving this ticket authorises ' .. source.approval_grant,
      '',
      'Denying it authorises ' .. source.denial_grant,
      '',
      -- The decision is a keystroke, so this window is the last thing read
      -- before it. Say so here rather than leaving the operator to discover
      -- that `a` in a detail float is not inert.
      '`a` approves and `d` denies, here or in the list. The panel re-reads the '
        .. 'ticket and re-verifies this digest first, and asks for nothing '
        .. 'else — so the terms above are what you are agreeing to.',
    })
  end

  request_lines(lines, source, ticket)
  source.detail_sections(lines, ticket, M)

  -- The broker returns the denial reason as denial_note, not note.
  if ticket.denial_note then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Denial note'
    lines[#lines + 1] = ''
    lines[#lines + 1] = tostring(ticket.denial_note)
  end
  lines[#lines + 1] = ''
  if source.decidable[ticket.status] then
    lines[#lines + 1] = '_`a` approve · `d` deny · `>`/`<` ticket · '
      .. '`<Tab>`/`<S-Tab>` category · `r` refresh · `q` or `<Esc>` close._'
  else
    lines[#lines + 1] = '_`>`/`<` ticket · `<Tab>`/`<S-Tab>` category · '
      .. '`r` refresh · `q` or `<Esc>` close._'
  end
  return table.concat(lines, '\n')
end

return M
