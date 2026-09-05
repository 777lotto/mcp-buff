-- The review panel: one window, one tab per broker.
--
-- Each tab owns everything about one provider -- its ticket queue and its
-- runtime permission subset -- because everything about one provider shares one
-- capability, one loopback socket, and one blast radius. Switching tabs is
-- therefore the only place a second credential is ever read, and the operator
-- can see which broker they are about to authorise from the tab bar alone.
--
-- Two brokers, two state machines, two digest domains. Nothing in this file
-- knows which is which: it asks the tab's source module. What it does enforce,
-- for every tab equally, is the review contract -- a fresh read before every
-- decision, a digest recomputed locally in that broker's own domain, and the
-- whole payload rendered on screen before anything is sent.
--
-- Those are the panel's checks to run, so the decision itself is one keystroke,
-- taken from the list or from inside the preview of the very payload it
-- decides. What a review contract cannot be built out of is the operator's
-- patience: a confirmation retyped on every ticket is one that gets typed
-- without being read.

local api, fn, uv = vim.api, vim.fn, (vim.uv or vim.loop)
local broker_module = require('mcp_buff.broker')
local canonical = require('mcp_buff.canonical')
local capability_module = require('mcp_buff.capability')
local client_module = require('mcp_buff.client')
local permissions = require('mcp_buff.permissions')
local render = require('mcp_buff.render')
local sources = require('mcp_buff.sources')

-- Keys that configure the Cloudflare broker without naming it. They predate
-- the second provider and are kept unprefixed so an existing setup() keeps
-- working unchanged.
local CLOUDFLARE_FLAT_KEYS = {
  endpoint = true,
  capability_cmd = true,
  tunnel = true,
  host_header = true,
}

-- Keys a provider inherits when it sets none of its own. Deliberately excludes
-- endpoint, capability_cmd, tunnel, and host_header: those identify one broker,
-- and inheriting any of them would point a provider at its sibling's socket or
-- send it its sibling's bearer.
local SHARED_KEYS = {
  curl_command = true,
  timeout = true,
  decision_timeout = true,
  poll_deadline = true,
  capability_ttl = true,
}

local PANEL_KEYS = {
  refresh_interval = true,
}

local DEFAULT_CONFIG = {
  endpoint = 'http://127.0.0.1:8792',
  curl_command = 'curl',
  -- Reads perform no execution, so they keep a short budget. A read that hangs
  -- for half an hour is a broken tunnel, not a long approval.
  timeout = 30000,
  -- decision_timeout and poll_deadline are deliberately absent. Their sensible
  -- values differ per broker -- Cloudflare's approval executes a chain of live
  -- mutations inside the POST, the GitHub broker's writes one small file -- so
  -- each source supplies its own default and an explicit setting here overrides
  -- both. Neither bounds the operator's review time, which is bounded only by
  -- ticket expiry.
  refresh_interval = 0,
  capability_cmd = nil,
  capability_ttl = capability_module.DEFAULT_TTL_SECONDS,
  host_header = nil,
  tunnel = false,
}

local M = {
  buf = nil,
  win = nil,
  line_map = {},
  tabs = {},
  active = nil,
  config = vim.deepcopy(DEFAULT_CONFIG),
}

local PANEL_WIDTH = 104
local namespace = api.nvim_create_namespace('mcp-buff')
local lifecycle_group = api.nvim_create_augroup('McpBuffLifecycle', { clear = true })
local timer
local end_session

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function define_highlights()
  local link = function(name, target)
    api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link('McpBuffHeader', 'Title')
  link('McpBuffHint', 'Comment')
  link('McpBuffTabActive', 'TabLineSel')
  link('McpBuffTabInactive', 'TabLine')
  link('McpBuffPending', 'DiagnosticWarn')
  link('McpBuffApproved', 'DiagnosticInfo')
  link('McpBuffExecuting', 'DiagnosticInfo')
  link('McpBuffExecuted', 'DiagnosticOk')
  link('McpBuffFailed', 'DiagnosticError')
  link('McpBuffIndeterminate', 'WarningMsg')
  link('McpBuffDenied', 'Comment')
  link('McpBuffExpired', 'DiagnosticDeprecated')
  link('McpBuffPermissionEnabled', 'DiagnosticOk')
  link('McpBuffPermissionDisabled', 'Comment')
end

local function find_window()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return nil end
  for _, window in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(window) == M.buf then return window end
  end
  return nil
end

local function with_writable(callback)
  api.nvim_set_option_value('modifiable', true, { buf = M.buf })
  local ok, err = pcall(callback)
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  if not ok then error(err) end
end

local function notify(message, level)
  vim.notify('McpBuff: ' .. message, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- The preview float
-- ---------------------------------------------------------------------------

-- One preview window, reused for every ticket the panel opens.
--
-- It is not a passive viewer. A decision is taken from inside it -- `a` and
-- `d` are mapped there too, because reading the payload and deciding it are
-- one act, and a review surface the operator has to leave before they can act
-- is a review surface they stop opening.
--
-- Reused rather than stacked for the same reason: a decision opens the payload
-- it is about to submit and then the settled ticket, so one keystroke would
-- otherwise bury the panel under a pile of floats, and a decision taken in a
-- float would be ambiguous about which of the visible tickets it meant.
local preview = { win = nil, buf = nil, tab = nil, ticket = nil, request = 0 }
local navigate_preview_ticket
local navigate_preview_category
local point_panel_at_ticket

local function preview_visible()
  return preview.win ~= nil and api.nvim_win_is_valid(preview.win)
end

--- Whether the cursor is in the preview, which is what makes the ticket it
--- shows -- and not the row behind it -- the target of a decision.
local function preview_focused()
  return preview_visible() and api.nvim_get_current_win() == preview.win
end

local function close_preview()
  preview.request = preview.request + 1
  if preview_visible() then pcall(api.nvim_win_close, preview.win, true) end
  preview.win, preview.buf, preview.tab, preview.ticket = nil, nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------

local function active_tab()
  for _, tab in ipairs(M.tabs) do
    if tab.id == M.active then return tab end
  end
  return M.tabs[1]
end

local function rerender()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return end
  local tab = active_tab()
  if not tab then return end
  local width = PANEL_WIDTH
  local window = find_window()
  if window then width = math.max(64, api.nvim_win_get_width(window) - 2) end

  local bar = {}
  for _, entry in ipairs(M.tabs) do
    bar[#bar + 1] = {
      id = entry.id,
      label = entry.label,
      pending = entry.pending,
      dirty = permissions.dirty(entry.permissions),
    }
  end

  -- The renderer is given the tab itself rather than a copy of its fields, so
  -- a row in the line map points at the tab that owns it. A copy would leave
  -- every keystroke acting on a table with no broker behind it.
  tab.configured = tab.broker:configured()
  tab.shows_permissions = tab.broker:shows_permissions()
  local rendered = render.panel(bar, tab, { width = width })

  M.line_map = rendered.map
  with_writable(function()
    api.nvim_buf_set_lines(M.buf, 0, -1, false, rendered.lines)
  end)
  api.nvim_buf_clear_namespace(M.buf, namespace, 0, -1)
  for _, highlight in ipairs(rendered.highlights) do
    api.nvim_buf_set_extmark(M.buf, namespace, highlight.line, highlight.start_col, {
      end_col = highlight.end_col,
      hl_group = highlight.group,
    })
  end
end

local function recount_pending(tab)
  tab.pending = render.pending_count(tab.source, tab.tickets)
end

--- Replace one row after a decision, so the list reflects the outcome without
--- a second listing call.
local function upsert_ticket(tab, ticket)
  local summary = {
    id = ticket.id,
    created = ticket.created,
    expires = ticket.expires,
    status = ticket.status,
    ticket_sha256 = ticket.ticket_sha256,
    reason = ticket.reason,
    request_count = #(ticket.requests or {}),
  }
  for index, existing in ipairs(tab.tickets) do
    if existing.id == ticket.id then
      tab.tickets[index] = summary
      recount_pending(tab)
      return rerender()
    end
  end
  tab.tickets[#tab.tickets + 1] = summary
  recount_pending(tab)
  rerender()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function refresh_tab(tab, opts)
  opts = opts or {}
  if tab.loading then return end
  if not tab.broker:configured() then
    tab.visited = true
    return rerender()
  end
  tab.loading = true
  tab.error = nil
  tab.generation = tab.generation + 1
  local generation = tab.generation
  local function stale() return generation ~= tab.generation end
  tab.visited = true
  rerender()

  tab.broker:ensure({ start = opts.allow_transport_start }, function(transport_error)
    if stale() then return end
    if transport_error then
      tab.loading = false
      tab.error = transport_error.message
      if not opts.silent then notify(transport_error.message, vim.log.levels.ERROR) end
      return rerender()
    end
    tab.broker.client:list(nil, {
      allow_capability_fetch = opts.allow_capability_fetch,
    }, function(err, tickets)
      if stale() then return end
      tab.loading = false
      if err then
        tab.error = err.message
        if not opts.silent then notify(err.message, vim.log.levels.ERROR) end
      else
        tab.tickets = tickets or {}
        tab.error = nil
        recount_pending(tab)
      end
      rerender()
    end)

    if tab.broker:shows_permissions() then
      permissions.fetch(tab.broker, tab.permissions, {
        stale = stale,
        allow_capability_fetch = opts.allow_capability_fetch,
        allow_transport_start = opts.allow_transport_start,
      }, rerender)
    end
  end)
end

--- Refresh the tab the operator is looking at.
---
--- Only that one. Refreshing every tab would read every provider's capability
--- and open every provider's forward on a keystroke the operator aimed at one
--- broker, which is the opposite of what a tab is for.
function M.refresh(opts)
  local tab = active_tab()
  if tab then refresh_tab(tab, opts) end
end

function M.select_tab(target)
  local index = type(target) == 'number' and target or nil
  if not index then
    for position, tab in ipairs(M.tabs) do
      if tab.id == target then index = position end
    end
  end
  local tab = index and M.tabs[index]
  if not tab then return end
  -- The preview belongs to the tab it was opened from. Leaving one broker's
  -- ticket floating over another broker's tab would put a decidable payload in
  -- front of the operator with the wrong tab bar behind it.
  if tab.id ~= M.active then close_preview() end
  M.active = tab.id
  -- A first visit fetches; a return visit renders what is already held. Cycling
  -- tabs must not re-read a credential each time round.
  if tab.visited then rerender() else refresh_tab(tab) end
end

function M.cycle_tab(direction)
  if #M.tabs < 2 then return end
  local current = 1
  for index, tab in ipairs(M.tabs) do
    if tab.id == M.active then current = index end
  end
  local step = direction == -1 and -1 or 1
  M.select_tab(((current - 1 + step) % #M.tabs) + 1)
end

function M.previous_tab() M.cycle_tab(-1) end

-- ---------------------------------------------------------------------------
-- Ticket detail
-- ---------------------------------------------------------------------------

local function float_config(tab, ticket, height)
  local width = math.max(20, math.min(110, vim.o.columns - 4))
  height = math.max(4, math.min(height, vim.o.lines - 4))
  return {
    relative = 'editor',
    border = 'rounded',
    title = (' %s · %s '):format(tab.source.title, tostring(ticket.id)),
    title_pos = 'center',
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  }
end

--- The keys the preview answers to.
---
--- Deliberately the ticket half of the panel's map, not all of it: a decision
--- and a refresh act on something the float is showing or on the tab behind it,
--- while the permission keys act on a row the float has none of. `q` closes the
--- preview here; the panel's `q` closes the panel.
local function attach_preview_keys(buf)
  local function map(lhs, callback, description)
    vim.keymap.set('n', lhs, callback, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = 'McpBuff: ' .. description,
    })
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    map(key, function() close_preview() end, 'close ticket detail')
  end
  map('a', function() M.approve() end, 'approve the previewed ticket')
  map('d', function() M.deny() end, 'deny the previewed ticket')
  for _, key in ipairs({ '<CR>', '<NL>', '<kEnter>' }) do
    map(key, function() M.primary() end, 're-read the previewed ticket')
  end
  map('r', function() M.refresh() end, 'refresh this tab')
  map('>', function() navigate_preview_ticket(1) end,
    'next ticket in this category')
  map('<lt>', function() navigate_preview_ticket(-1) end,
    'previous ticket in this category')
  map('<Tab>', function() navigate_preview_category(1) end,
    'first ticket in the next category')
  map('<S-Tab>', function() navigate_preview_category(-1) end,
    'first ticket in the previous category')
  for index = 1, #M.tabs do
    local target = index
    map(tostring(target), function() M.select_tab(target) end,
      'open the ' .. M.tabs[target].label .. ' tab')
  end
end

local function show_detail(tab, ticket)
  -- Replacing the visible detail invalidates any older navigation GET that is
  -- still in flight. Its cache update is harmless; reclaiming the float is not.
  preview.request = preview.request + 1
  local text = render.detail(tab.source, ticket)
  local lines = vim.split(text, '\n', { plain = true })
  local outgoing = preview.buf
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  api.nvim_set_option_value('swapfile', false, { buf = buf })
  api.nvim_set_option_value('undofile', false, { buf = buf })
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  -- A plugin-owned filetype keeps generic Markdown integrations from changing
  -- window-local behavior (or attaching an LSP) to this nofile review surface.
  -- The syntax stays Markdown so the payload remains just as readable.
  api.nvim_set_option_value('filetype', 'mcpbuffdetail', { buf = buf })
  api.nvim_set_option_value('syntax', 'markdown', { buf = buf })
  attach_preview_keys(buf)

  local config = float_config(tab, ticket, #lines)
  if preview_visible() then
    -- Into the window that is already open, so the ticket the operator can see
    -- and the ticket their next keystroke decides are always the same one. The
    -- cursor follows it there, exactly as it follows a newly opened float: a
    -- ticket put on screen for review is one the operator is meant to be in.
    api.nvim_win_set_buf(preview.win, buf)
    api.nvim_win_set_config(preview.win, config)
    api.nvim_set_current_win(preview.win)
  else
    config.style = 'minimal'
    preview.win = api.nvim_open_win(buf, true, config)
  end
  api.nvim_set_option_value('wrap', true, { win = preview.win })
  api.nvim_set_option_value('linebreak', true, { win = preview.win })
  api.nvim_set_option_value('breakindent', true, { win = preview.win })
  api.nvim_set_option_value('breakindentopt', 'shift:2,min:20', { win = preview.win })
  api.nvim_set_option_value('sidescrolloff', 0, { win = preview.win })

  -- A reused window may have been scrolled in either direction. Every newly
  -- selected ticket starts at its beginning, with no inherited horizontal
  -- offset, and the float is sized from wrapped screen rows rather than raw
  -- buffer lines.
  api.nvim_win_set_cursor(preview.win, { 1, 0 })
  api.nvim_win_call(preview.win, function()
    fn.winrestview({ lnum = 1, col = 0, topline = 1, leftcol = 0, skipcol = 0 })
  end)
  local display_height = api.nvim_win_text_height(preview.win, {}).all
  api.nvim_win_set_config(preview.win, float_config(tab, ticket, display_height))

  -- Naming comes last, after the buffer this one replaced is gone. The two are
  -- the same ticket whenever a decision re-renders one, and a name still held
  -- by the outgoing buffer would leave this one anonymous.
  if outgoing and outgoing ~= buf and api.nvim_buf_is_valid(outgoing) then
    pcall(api.nvim_buf_delete, outgoing, { force = true })
  end
  -- Namespaced by provider: two brokers mint ids from the same pattern, and a
  -- buffer name that could collide would show one broker's ticket under the
  -- other's heading.
  pcall(api.nvim_buf_set_name, buf,
    ('mcpbuff://%s/ticket/%s'):format(tab.id, tostring(ticket.id)))
  preview.buf = buf
  preview.tab = tab
  preview.ticket = ticket
  point_panel_at_ticket(tab, ticket.id)
  return buf, preview.win
end

local function current_item()
  local window = find_window()
  if not window then return nil end
  return M.line_map[api.nvim_win_get_cursor(window)[1]]
end

--- The ticket a keystroke acts on.
---
--- The preview wins whenever the cursor is inside it, because a ticket the
--- operator is reading is the one they mean, and the panel row behind the float
--- is not something they can see. Everywhere else the cursor row is the target,
--- exactly as before.
local function current_ticket()
  if preview_focused() and preview.tab then
    return preview.tab, preview.ticket
  end
  local item = current_item()
  if item and item.kind == 'ticket' then return item.tab, item.ticket end
  return nil
end

local function fetch_ticket(tab, summary, callback)
  tab.broker:ensure(function(transport_error)
    if transport_error then
      return notify(transport_error.message, vim.log.levels.ERROR)
    end
    tab.broker.client:get(summary.id, function(err, ticket)
      if err then return notify(err.message, vim.log.levels.ERROR) end
      upsert_ticket(tab, ticket)
      callback(tab, ticket)
    end)
  end)
end

local function fetch_current(callback)
  local tab, summary = current_ticket()
  if not tab then
    notify('move the cursor onto a ticket')
    return
  end
  fetch_ticket(tab, summary, callback)
end

--- Keep the row behind the float aligned with the ticket on screen. Closing
--- the preview therefore returns to the place the operator navigated to, not
--- the row where they happened to open it.
point_panel_at_ticket = function(tab, ticket_id)
  local window = find_window()
  if not window then return end
  for line, item in pairs(M.line_map) do
    if item.kind == 'ticket' and item.tab == tab and item.ticket.id == ticket_id then
      api.nvim_win_set_cursor(window, { line, 0 })
      return
    end
  end
end

local function preview_position()
  if not (preview_focused() and preview.tab and preview.ticket) then return nil end
  local categories = render.ticket_categories(preview.tab.source, preview.tab.tickets)
  for category_index, category in ipairs(categories) do
    for ticket_index, ticket in ipairs(category.tickets) do
      if ticket.id == preview.ticket.id then
        return categories, category_index, ticket_index
      end
    end
  end
  notify('the previewed ticket is no longer in this tab; reopen it from the list',
    vim.log.levels.WARN)
  return nil
end

local function open_preview_ticket(tab, summary)
  -- Requests are asynchronous. If another keystroke replaces or closes this
  -- preview first, the older response may update the list cache but must not
  -- take the window back from the newer selection.
  preview.request = preview.request + 1
  local request = preview.request
  fetch_ticket(tab, summary, function(target, ticket)
    if not preview_visible() or preview.request ~= request then return end
    show_detail(target, ticket)
  end)
end

navigate_preview_ticket = function(direction)
  local categories, category_index, ticket_index = preview_position()
  if not categories then return end
  local category = categories[category_index]
  local next_index = ticket_index + (direction == -1 and -1 or 1)
  local target = category.tickets[next_index]
  if not target then
    notify(('already at the %s ticket in %s'):format(
      direction == -1 and 'first' or 'last', category.label))
    return
  end
  open_preview_ticket(preview.tab, target)
end

navigate_preview_category = function(direction)
  local categories, category_index = preview_position()
  if not categories then return end
  if #categories < 2 then
    notify('this tab has no other non-empty ticket category')
    return
  end
  local step = direction == -1 and -1 or 1
  local next_index = ((category_index - 1 + step) % #categories) + 1
  open_preview_ticket(preview.tab, categories[next_index].tickets[1])
end

-- ---------------------------------------------------------------------------
-- Decisions
-- ---------------------------------------------------------------------------

local function report_decision(tab, action, decided, info, show)
  upsert_ticket(tab, decided)
  if show ~= false then show_detail(tab, decided) end

  -- Which settled statuses are good news is the source's to say. A settled
  -- decision is not automatically a successful one: Cloudflare's `failed` means
  -- the mutation ran and was rejected, and its `indeterminate` means nobody
  -- knows -- neither of which should read like a routine confirmation.
  local source = tab.source
  local alarm = source.decision_alarming[decided.status]
  local level = vim.log.levels.WARN
  if alarm then
    level = vim.log.levels.ERROR
  elseif source.decision_ok[decided.status] then
    level = vim.log.levels.INFO
  end

  local suffix = info and info.polled
    and ' (resolved by polling; the decision was not resent)' or ''
  notify(('%s → %s ticket %s%s'):format(
    action, tab.label, tostring(decided.status), suffix), level)
  if alarm then notify(alarm, vim.log.levels.ERROR) end
end

local function submit_decision(tab, ticket, action, note)
  if tab.decision_active then
    return notify('a decision is already in progress for this tab', vim.log.levels.WARN)
  end
  tab.broker:ensure(function(transport_error)
    if transport_error then
      return notify(transport_error.message, vim.log.levels.ERROR)
    end
    if tab.decision_active then
      return notify('a decision is already in progress for this tab', vim.log.levels.WARN)
    end
    tab.decision_active = true
    tab.broker:hold()
    notify(('submitting %s for %s…'):format(action, ticket.id))
    tab.broker.client:decide(ticket.id, action, {
      ticket_sha256 = ticket.ticket_sha256,
      note = note,
    }, {
      on_progress = function(message) notify(message) end,
      callback = function(err, decided, info)
        tab.decision_active = false
        tab.broker:done()
        local visible = find_window() ~= nil
        if err then
          notify(('%s — %s'):format(action, err.message), vim.log.levels.ERROR)
          if visible then
            refresh_tab(tab, { silent = true })
          else
            end_session()
          end
          return
        end
        report_decision(tab, action, decided, info, visible)
        if not visible then end_session() end
      end,
    })
  end)
end

-- Both decisions take the same route, and every step of it is the panel's own
-- work rather than the operator's: a fresh read of the ticket, a decidability
-- check, a local digest recomputation in this broker's own digest domain, and
-- the full payload rendered into the preview -- which is left on screen, so the
-- ticket that was submitted is the one still in front of the operator.
--
-- The keystroke itself is the confirmation. There is no digest to retype: the
-- panel verifies the digest it recomputed against the one the broker served,
-- which is the check a typed suffix was only ever an unreliable proxy for.
local function decide(action)
  local tab = current_ticket()
  if tab and tab.decision_active then
    return notify('a decision is already in progress for this tab', vim.log.levels.WARN)
  end
  fetch_current(function(target, ticket)
    if not target.broker.client:is_decidable(ticket.status) then
      return notify(('ticket is %s, which %s cannot decide'):format(
        tostring(ticket.status), target.source.title), vim.log.levels.WARN)
    end

    -- Recomputing the digest guards a cross-ticket replay, a client-side digest
    -- bug, and direct tampering with the stored ticket. Passing this broker's
    -- own prefix is what also guards a cross-BROKER replay: the same immutable
    -- payload hashes differently under the two domains, so a digest reviewed
    -- for one provider can never verify for the other.
    local verified, reason = canonical.verify(ticket, target.source.digest_prefix)
    if not verified then
      return notify('refusing to submit — ' .. reason, vim.log.levels.ERROR)
    end

    show_detail(target, ticket)

    if action == 'deny' then
      vim.ui.input({ prompt = 'Denial note (optional; Esc cancels): ' }, function(note)
        if note == nil then return end
        note = trim(note)
        submit_decision(target, ticket, action, note ~= '' and note or nil)
      end)
    else
      submit_decision(target, ticket, action, nil)
    end
  end)
end

function M.approve() decide('approve') end
function M.deny() decide('deny') end

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------

function M.toggle_permission()
  local item = current_item()
  if not item or item.kind ~= 'permission' then
    return notify('move the cursor onto a permission')
  end
  local ok, message = permissions.toggle(item.tab.permissions, item.index)
  if not ok and message then return notify(message, vim.log.levels.ERROR) end
  if ok then rerender() end
end

--- Apply the active tab's permission edits. The tab is the target; there is
--- nothing to infer from the cursor.
function M.apply_permissions()
  local tab = active_tab()
  if not tab then return end
  local state = tab.permissions
  if not tab.broker:shows_permissions() then
    return notify(('%s has its permissions section disabled'):format(tab.source.title))
  end
  if state.applying then return end
  if not state.snapshot then
    return notify('this tab has no permission document loaded', vim.log.levels.WARN)
  end
  if state.must_refresh then
    return notify('refresh this tab before applying', vim.log.levels.ERROR)
  end
  if not permissions.dirty(state) then
    return notify(('%s has no permission changes'):format(tab.source.title))
  end
  if not permissions.confirmed(tab.broker, state) then
    return notify('permission update cancelled; the typed digest did not match',
      vim.log.levels.WARN)
  end
  permissions.apply(tab.broker, state, {
    on_change = rerender,
    on_notify = notify,
    on_settle = function()
      if not find_window() then end_session() end
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Primary action
-- ---------------------------------------------------------------------------

--- <CR> means "do the obvious thing to the row under the cursor": read a
--- ticket, or flip a permission. Neither is destructive, and both are the only
--- sensible reading of their own row.
---
--- Inside the preview it re-reads the ticket on screen. The permission branch
--- is skipped there on purpose: the float shows a ticket, and a keystroke that
--- silently toggled a permission row hidden behind it would be acting on
--- something the operator cannot see.
function M.primary()
  if not preview_focused() then
    local item = current_item()
    if item and item.kind == 'permission' then return M.toggle_permission() end
  end
  fetch_current(function(tab, ticket) show_detail(tab, ticket) end)
end

-- ---------------------------------------------------------------------------
-- Counts and lifecycle
-- ---------------------------------------------------------------------------

--- Pending tickets awaiting a decision, for a statusline.
---
--- With no argument this is the total across every broker, which is what a
--- statusline wants: "there is work waiting" does not depend on which tab
--- happens to be open. Pass a provider id for one of them.
function M.pending_count(provider)
  local total = 0
  for _, tab in ipairs(M.tabs) do
    if provider == nil or tab.id == provider then total = total + (tab.pending or 0) end
  end
  return total
end

local function busy()
  for _, tab in ipairs(M.tabs) do
    if tab.decision_active or tab.broker:busy() then return true end
  end
  return false
end

end_session = function(force)
  local released = true
  close_preview()
  for _, tab in ipairs(M.tabs) do
    tab.generation = tab.generation + 1
    tab.loading = false
    tab.visited = false
    if not tab.broker:release(force) then released = false end
  end
  return released
end

function M.close()
  local deferred = busy()
  -- Before the window arithmetic below, not after: a float left open would
  -- both count as a window and be the only one left if the panel closed first.
  close_preview()
  local window = find_window()
  if window then
    local last_window = #api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(window)) == 1
    local last_tab = fn.tabpagenr('$') == 1
    if last_window and last_tab then
      api.nvim_set_current_win(window)
      vim.cmd('enew')
    else
      pcall(api.nvim_win_close, window, true)
    end
  end
  M.win = nil
  end_session()
  if deferred then
    notify('review panel closed; each broker\'s route will close after its '
      .. 'in-flight write reaches an outcome', vim.log.levels.WARN)
  end
end

function M.attach_keys()
  local function map(lhs, callback, description)
    vim.keymap.set('n', lhs, callback, {
      buffer = M.buf,
      nowait = true,
      silent = true,
      desc = 'McpBuff: ' .. description,
    })
  end
  -- Some terminals and SSH paths encode Enter as LF or keypad Enter.
  for _, key in ipairs({ '<CR>', '<NL>', '<kEnter>' }) do
    map(key, M.primary, 'open ticket detail or toggle permission')
  end
  map('a', M.approve, 'approve pending ticket')
  map('d', M.deny, 'deny pending ticket')
  map('<Space>', M.toggle_permission, 'toggle runtime permission')
  map('A', M.apply_permissions, 'apply this tab\'s permission changes')
  map('r', function() M.refresh() end, 'refresh this tab')
  map('<Tab>', function() M.cycle_tab(1) end, 'next broker tab')
  map('<S-Tab>', M.previous_tab, 'previous broker tab')
  for index = 1, #M.tabs do
    local target = index
    map(tostring(target), function() M.select_tab(target) end,
      'open the ' .. M.tabs[target].label .. ' tab')
  end
  map('q', M.close, 'close panel')
end

local function ensure_buffer()
  if M.buf and api.nvim_buf_is_valid(M.buf) then return M.buf end
  M.buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value('buftype', 'nofile', { buf = M.buf })
  api.nvim_set_option_value('bufhidden', 'hide', { buf = M.buf })
  api.nvim_set_option_value('swapfile', false, { buf = M.buf })
  api.nvim_set_option_value('undofile', false, { buf = M.buf })
  api.nvim_set_option_value('buflisted', false, { buf = M.buf })
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  api.nvim_set_option_value('filetype', 'mcpbuff', { buf = M.buf })
  pcall(api.nvim_buf_set_name, M.buf, 'mcpbuff://review')
  api.nvim_create_autocmd({ 'BufHidden', 'BufWipeout' }, {
    group = lifecycle_group,
    buffer = M.buf,
    callback = function()
      -- :close and window-manager mappings do not call M.close(). Delay the
      -- check until Neovim has removed the window, then revoke every session.
      vim.schedule(function()
        if not find_window() then end_session() end
      end)
    end,
  })
  M.attach_keys()
  return M.buf
end

--- @param provider string|nil open straight to this broker's tab.
---
--- The tab is chosen before the first refresh, so `:McpBuff github` never reads
--- the Cloudflare capability on its way to the Git tab.
function M.open(provider)
  ensure_buffer()
  if provider then
    for _, tab in ipairs(M.tabs) do
      if tab.id == provider then M.active = tab.id end
    end
  end
  local existing = find_window()
  if existing then
    M.win = existing
    api.nvim_set_current_win(existing)
    M.refresh()
    return
  end
  vim.cmd('topleft vsplit')
  M.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.win, M.buf)
  api.nvim_win_set_width(M.win, math.min(PANEL_WIDTH, math.max(40, vim.o.columns - 8)))
  api.nvim_set_option_value('number', false, { win = M.win })
  api.nvim_set_option_value('relativenumber', false, { win = M.win })
  api.nvim_set_option_value('signcolumn', 'no', { win = M.win })
  api.nvim_set_option_value('cursorline', true, { win = M.win })
  api.nvim_set_option_value('wrap', false, { win = M.win })
  api.nvim_set_option_value('winfixwidth', true, { win = M.win })
  rerender()
  M.refresh()
end

--- Open the panel with the cursor on the active tab's permission section.
---
--- Kept as its own entry point because it is a distinct intent -- narrow a
--- running broker, not review a ticket -- and because :McpBuffPermissions is an
--- existing command an operator has in their keymap.
local function jump_to_permissions(tab, attempts)
  local window = find_window()
  if not window then return end
  for line, item in pairs(M.line_map) do
    if item.kind == 'permission' and item.index == 1 and item.tab == tab then
      api.nvim_set_current_win(window)
      api.nvim_win_set_cursor(window, { line, 0 })
      return
    end
  end
  -- On a cold panel the document is still in flight. Wait for the render that
  -- has rows rather than telling the operator to try again.
  if attempts > 0 and (tab.loading or tab.permissions.loading) then
    return vim.defer_fn(function() jump_to_permissions(tab, attempts - 1) end, 100)
  end
  if tab.permissions.error then
    return notify(('%s permissions are unavailable — %s'):format(
      tab.source.title, tab.permissions.error), vim.log.levels.ERROR)
  end
  if not tab.permissions.snapshot then
    notify(('%s permissions are not loaded'):format(tab.source.title),
      vim.log.levels.WARN)
  end
end

function M.open_permissions(provider)
  M.open(provider)
  local tab = active_tab()
  if not tab then return end
  if not tab.broker:shows_permissions() then
    return notify(('%s has its permissions section disabled'):format(tab.source.title))
  end
  jump_to_permissions(tab, 100)
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local function configure_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  local seconds = M.config.refresh_interval
  if seconds <= 0 then return end
  timer = uv.new_timer()
  timer:start(seconds * 1000, seconds * 1000, vim.schedule_wrap(function()
    -- The panel is attended. A timer must never reopen a route, read a
    -- credential, or touch a broker the operator is not looking at, so it
    -- refreshes the visible tab only and is refused by both gates below when
    -- either would be needed:
    --   allow_capability_fetch = false  -- a cold cache skips the tick rather
    --                                      than running capability_cmd
    --   allow_transport_start  = false  -- a closed forward skips the tick
    --                                      rather than launching ssh
    if not find_window() then return end
    M.refresh({
      silent = true,
      allow_capability_fetch = false,
      allow_transport_start = false,
    })
  end))
end

--- Split one setup() table into shared defaults and per-provider config.
---
--- The Cloudflare broker's keys stay unprefixed, `github` names the GitHub
--- broker, and `permissions.*` is the shape this option had before the panel
--- gained a second ticket source.
local function split_config(opts)
  local shared, brokers, panel = {}, {}, {}
  local known_providers = {}
  for _, id in ipairs(sources.ids()) do known_providers[id] = true end

  local cloudflare = {}
  for key, value in pairs(opts) do
    if CLOUDFLARE_FLAT_KEYS[key] then
      cloudflare[key] = value
      if SHARED_KEYS[key] then shared[key] = value end
    elseif SHARED_KEYS[key] then
      shared[key] = value
    elseif PANEL_KEYS[key] then
      panel[key] = value
    elseif known_providers[key] or key == 'permissions' then
      brokers[key] = value
    else
      error(('mcp_buff.setup(): %s is not a supported option'):format(tostring(key)))
    end
  end

  -- permissions.* is the previous spelling of this configuration, from when the
  -- permission panel was the only place a second broker appeared. Accepted, and
  -- mapped rather than reinterpreted: permissions.github WAS the GitHub broker
  -- connection, so that is what it still configures.
  local legacy = brokers.permissions
  brokers.permissions = nil
  if legacy == false then
    for id in pairs(known_providers) do
      brokers[id] = vim.tbl_extend('force', brokers[id] or {}, { permissions = false })
    end
  elseif legacy ~= nil then
    if type(legacy) ~= 'table' then
      error('mcp_buff.setup(): permissions must be a table or false')
    end
    for key, value in pairs(legacy) do
      if not known_providers[key] then
        error(('mcp_buff.setup(): permissions.%s is not supported'):format(tostring(key)))
      end
      if key == 'cloudflare' then
        -- It only ever accepted {} or false, because it inherited the main
        -- broker configuration.
        if value == false then
          cloudflare.permissions = false
        elseif type(value) ~= 'table' or next(value) ~= nil then
          error('mcp_buff.setup(): permissions.cloudflare inherits the main broker '
            .. 'configuration and accepts only {} or false')
        end
      elseif brokers[key] ~= nil then
        -- Two spellings of one broker's connection, and no way to tell which
        -- endpoint or capability the operator meant. Refuse rather than pick.
        error(('mcp_buff.setup(): configure the %s broker as %s = { … } or as the '
          .. 'deprecated permissions.%s = { … }, not both'):format(key, key, key))
      else
        brokers[key] = value
      end
    end
  end

  if next(cloudflare) ~= nil then
    if brokers.cloudflare ~= nil then
      error('mcp_buff.setup(): the Cloudflare broker is configured both by the '
        .. 'unprefixed keys and by cloudflare = { … }; keep one')
    end
    brokers.cloudflare = cloudflare
  end
  return shared, brokers, panel
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('mcp_buff.setup() expects a table')
  end
  if busy() then
    error('mcp_buff.setup(): cannot reconfigure while a decision or permission '
      .. 'update is in progress')
  end

  local shared, raw_brokers, panel = split_config(vim.deepcopy(opts or {}))
  shared = vim.tbl_extend('keep', shared, {
    curl_command = DEFAULT_CONFIG.curl_command,
    timeout = DEFAULT_CONFIG.timeout,
    capability_ttl = DEFAULT_CONFIG.capability_ttl,
  })

  local refresh_interval = math.floor(
    tonumber(panel.refresh_interval) or DEFAULT_CONFIG.refresh_interval)
  if refresh_interval < 0 then
    error('mcp_buff.setup(): refresh_interval must be zero or a positive number')
  end

  -- Reconfiguring drops every capability and every forward held for the
  -- previous configuration before the new brokers exist.
  end_session(true)

  local brokers = broker_module.build(raw_brokers, shared, {
    on_tunnel_exit = function(broker, err)
      for _, tab in ipairs(M.tabs) do
        if tab.broker == broker then
          tab.error = err.message
          tab.visited = false
        end
      end
      if find_window() then
        rerender()
        notify(err.message, vim.log.levels.ERROR)
      end
    end,
  })

  M.tabs = {}
  for _, broker in ipairs(brokers) do
    M.tabs[#M.tabs + 1] = {
      id = broker.id,
      source = broker.source,
      label = broker.source.tab_label,
      broker = broker,
      tickets = {},
      pending = 0,
      permissions = permissions.new(),
      loading = false,
      error = nil,
      visited = false,
      generation = 0,
      decision_active = false,
    }
  end
  -- active_tab() falls back to the first tab, so a stale id would render
  -- correctly while M.active still named a broker that no longer has one.
  local still_present = false
  for _, tab in ipairs(M.tabs) do
    if tab.id == M.active then still_present = true end
  end
  if not still_present then M.active = M.tabs[1].id end

  M.config = {
    refresh_interval = refresh_interval,
    brokers = {},
  }
  for _, tab in ipairs(M.tabs) do
    M.config.brokers[tab.id] = vim.deepcopy(tab.broker.config)
    -- The capability argv is the one thing here that names a secret's location.
    -- It is validated and used, never republished on the public config table.
    M.config.brokers[tab.id].capability_cmd = nil
  end

  configure_timer()
  if M.buf and api.nvim_buf_is_valid(M.buf) then
    M.attach_keys()
    if find_window() then M.refresh() else rerender() end
  end
  return M
end

define_highlights()
-- A panel that has not been configured still has tabs, so :McpBuff explains
-- what is missing instead of failing to open.
M.setup({})
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('McpBuffHighlights', { clear = true }),
  callback = define_highlights,
})
api.nvim_create_autocmd('VimLeavePre', {
  group = lifecycle_group,
  callback = function()
    if timer then timer:stop(); timer:close(); timer = nil end
    end_session(true)
  end,
})

return M
