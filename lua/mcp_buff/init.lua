local api, fn, uv = vim.api, vim.fn, (vim.uv or vim.loop)
local client_module = require('mcp_buff.client')
local capability = require('mcp_buff.capability')
local canonical = require('mcp_buff.canonical')
local render = require('mcp_buff.render')
local tunnel_module = require('mcp_buff.tunnel')

local DEFAULT_CONFIG = {
  endpoint = 'http://127.0.0.1:8792',
  curl_command = 'curl',
  -- Reads perform no execution, so they keep a short budget. A read that hangs
  -- for half an hour is a broken tunnel, not a long approval.
  timeout = 30000,
  -- Approval executes every preflight and every mutation inside the POST, so
  -- its budget is sized against that execution window rather than against a
  -- conventional HTTP timeout. Neither of these bounds the operator's review
  -- time, which is bounded only by ticket expiry.
  decision_timeout = 1865,
  poll_deadline = 1865,
  refresh_interval = 0,
  capability_cmd = nil,
  capability_ttl = capability.DEFAULT_TTL_SECONDS,
  host_header = nil,
  tunnel = false,
}

local M = {
  buf = nil,
  win = nil,
  line_map = {},
  tickets = {},
  config = vim.deepcopy(DEFAULT_CONFIG),
}

local PANEL_WIDTH = 92
local namespace = api.nvim_create_namespace('mcp-buff')
local lifecycle_group = api.nvim_create_augroup('McpBuffLifecycle', { clear = true })
local request_generation = 0
local loading = false
local last_error
local pending = 0
local timer
local client
local tunnel
local decision_active = false
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
  link('McpBuffPending', 'DiagnosticWarn')
  link('McpBuffApproved', 'DiagnosticInfo')
  link('McpBuffExecuting', 'DiagnosticInfo')
  link('McpBuffExecuted', 'DiagnosticOk')
  link('McpBuffFailed', 'DiagnosticError')
  link('McpBuffIndeterminate', 'WarningMsg')
  link('McpBuffDenied', 'Comment')
  link('McpBuffExpired', 'DiagnosticDeprecated')
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

local function rerender()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return end
  local width = PANEL_WIDTH
  local window = find_window()
  if window then width = math.max(64, api.nvim_win_get_width(window) - 2) end
  local rendered = render.list(M.tickets, {
    width = width,
    loading = loading,
    error = last_error,
  })
  M.line_map = rendered.map
  pending = rendered.pending
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

local function update_pending()
  local count = 0
  for _, ticket in ipairs(M.tickets) do
    if ticket.status == 'pending' then count = count + 1 end
  end
  pending = count
end

local function summary_from_ticket(ticket)
  return {
    id = ticket.id,
    created = ticket.created,
    expires = ticket.expires,
    status = ticket.status,
    ticket_sha256 = ticket.ticket_sha256,
    reason = ticket.reason,
    request_count = #(ticket.requests or {}),
    result_count = #(ticket.results or {}),
  }
end

local function upsert_ticket(ticket)
  local replacement = summary_from_ticket(ticket)
  for index, existing in ipairs(M.tickets) do
    if existing.id == ticket.id then
      M.tickets[index] = replacement
      update_pending()
      rerender()
      return
    end
  end
  M.tickets[#M.tickets + 1] = replacement
  update_pending()
  rerender()
end

local function show_detail(ticket)
  local text = render.detail(ticket)
  local lines = vim.split(text, '\n', { plain = true })
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  api.nvim_set_option_value('swapfile', false, { buf = buf })
  api.nvim_set_option_value('undofile', false, { buf = buf })
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  api.nvim_set_option_value('filetype', 'markdown', { buf = buf })
  pcall(api.nvim_buf_set_name, buf, 'mcpbuff://ticket/' .. tostring(ticket.id))

  local width = math.max(20, math.min(110, vim.o.columns - 4))
  local height = math.max(4, math.min(#lines, vim.o.lines - 4))
  local window = api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = 'rounded',
    title = ' MCP Buff · ' .. tostring(ticket.id) .. ' ',
    title_pos = 'center',
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  api.nvim_set_option_value('wrap', false, { win = window })
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, '<cmd>close<cr>', {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = 'Close MCP ticket detail',
    })
  end
  return buf, window
end

local function current_ticket()
  local window = find_window()
  if not window then return nil end
  local item = M.line_map[api.nvim_win_get_cursor(window)[1]]
  return item and item.kind == 'ticket' and item.ticket or nil
end

local function ensure_transport(callback)
  if not tunnel then
    callback(nil)
    return
  end
  tunnel:ensure(callback)
end

local function fetch_current(callback)
  local summary = current_ticket()
  if not summary then
    vim.notify('McpBuff: move the cursor onto a ticket', vim.log.levels.INFO)
    return
  end
  ensure_transport(function(transport_error)
    if transport_error then
      vim.notify('McpBuff: ' .. transport_error.message, vim.log.levels.ERROR)
      return
    end
    client:get(summary.id, function(err, ticket)
      if err then
        vim.notify('McpBuff: ' .. err.message, vim.log.levels.ERROR)
        return
      end
      upsert_ticket(ticket)
      callback(ticket)
    end)
  end)
end

function M.refresh(opts)
  opts = opts or {}
  if loading then return end
  loading = true
  last_error = nil
  request_generation = request_generation + 1
  local generation = request_generation
  rerender()
  ensure_transport(function(transport_error)
    if generation ~= request_generation then return end
    if transport_error then
      loading = false
      last_error = transport_error.message
      if not opts.silent then
        vim.notify('McpBuff: ' .. transport_error.message, vim.log.levels.ERROR)
      end
      rerender()
      return
    end
    client:list(nil, {
      allow_capability_fetch = opts.allow_capability_fetch,
    }, function(err, tickets)
      if generation ~= request_generation then return end
      loading = false
      if err then
        last_error = err.message
        if not opts.silent then
          vim.notify('McpBuff: ' .. err.message, vim.log.levels.ERROR)
        end
      else
        M.tickets = tickets or {}
        last_error = nil
        update_pending()
      end
      rerender()
    end)
  end)
end

function M.primary()
  fetch_current(function(ticket) show_detail(ticket) end)
end

-- Typed confirmation of the digest's final eight characters. A yes/no prompt
-- does not satisfy the contract, so this deliberately has no default answer and
-- no single-keypress path.
local function typed_confirmation(ticket, action)
  fn.inputsave()
  local ok, answer = pcall(fn.input, render.confirm_prompt(ticket, action))
  fn.inputrestore()
  vim.cmd('redraw')
  if not ok then return false end
  return trim(answer) == render.digest_suffix(ticket)
end

local function report_decision(action, decided, info, show)
  upsert_ticket(decided)
  if show ~= false then show_detail(decided) end
  local level = vim.log.levels.WARN
  if decided.status == 'executed' or decided.status == 'denied' then
    level = vim.log.levels.INFO
  elseif decided.status == 'indeterminate' then
    level = vim.log.levels.ERROR
  end
  local suffix = info and info.polled and ' (resolved by polling; the decision was not resent)' or ''
  vim.notify(('McpBuff: %s → ticket %s%s'):format(action, tostring(decided.status), suffix), level)
  if decided.status == 'indeterminate' then
    vim.notify('McpBuff: this outcome is unknown, not failed. Inspect it upstream '
      .. 'and never replay this ticket.', vim.log.levels.ERROR)
  end
end

local function submit_decision(ticket, action, note)
  if decision_active then
    vim.notify('McpBuff: a decision is already in progress', vim.log.levels.WARN)
    return
  end
  if not typed_confirmation(ticket, action) then
    vim.notify(('McpBuff: %s cancelled; the typed digest did not match'):format(action),
      vim.log.levels.WARN)
    return
  end
  ensure_transport(function(transport_error)
    if transport_error then
      vim.notify('McpBuff: ' .. transport_error.message, vim.log.levels.ERROR)
      return
    end
    if decision_active then
      vim.notify('McpBuff: a decision is already in progress', vim.log.levels.WARN)
      return
    end
    decision_active = true
    vim.notify(('McpBuff: submitting %s for %s…'):format(action, ticket.id),
      vim.log.levels.INFO)
    client:decide(ticket.id, action, {
      ticket_sha256 = ticket.ticket_sha256,
      note = note,
    }, {
      on_progress = function(message)
        vim.notify('McpBuff: ' .. message, vim.log.levels.INFO)
      end,
      callback = function(err, decided, info)
        decision_active = false
        local visible = find_window() ~= nil
        if err then
          vim.notify(('McpBuff: %s — %s'):format(action, err.message), vim.log.levels.ERROR)
          if visible then
            M.refresh({ silent = true })
          else
            end_session()
          end
          return
        end
        report_decision(action, decided, info, visible)
        if not visible then end_session() end
      end,
    })
  end)
end

-- Both decisions take the same route: a fresh read, a pending check, a local
-- digest recomputation, a full render, then a typed confirmation.
local function decide(action)
  if decision_active then
    vim.notify('McpBuff: a decision is already in progress', vim.log.levels.WARN)
    return
  end
  fetch_current(function(ticket)
    if ticket.status ~= 'pending' then
      vim.notify(('McpBuff: ticket is %s, not pending'):format(tostring(ticket.status)),
        vim.log.levels.WARN)
      return
    end

    -- Recomputing the digest guards a cross-ticket replay, a client-side digest
    -- bug, and direct tampering with the stored ticket. It does not detect a
    -- concurrent decision; the state machine does that.
    local verified, reason = canonical.verify(ticket)
    if not verified then
      vim.notify('McpBuff: refusing to submit — ' .. reason, vim.log.levels.ERROR)
      return
    end

    show_detail(ticket)

    if action == 'deny' then
      vim.ui.input({ prompt = 'Denial note (optional; Esc cancels): ' }, function(note)
        if note == nil then return end
        note = trim(note)
        submit_decision(ticket, action, note ~= '' and note or nil)
      end)
    else
      submit_decision(ticket, action, nil)
    end
  end)
end

function M.approve()
  decide('approve')
end

function M.deny()
  decide('deny')
end

function M.pending_count()
  return pending
end

end_session = function(force)
  if decision_active and not force then return false end
  request_generation = request_generation + 1
  loading = false
  capability.clear()
  if tunnel then tunnel:stop() end
  return true
end

function M.close()
  local deferred = decision_active
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
    vim.notify('McpBuff: review panel closed; the tunnel will close after the '
      .. 'in-flight decision reaches an outcome', vim.log.levels.WARN)
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
  for _, key in ipairs({ '<CR>', '<NL>', '<kEnter>' }) do
    map(key, M.primary, 'open ticket detail')
  end
  map('a', M.approve, 'approve pending ticket')
  map('d', M.deny, 'deny pending ticket')
  map('r', M.refresh, 'refresh tickets')
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
  pcall(api.nvim_buf_set_name, M.buf, 'mcpbuff://tickets')
  api.nvim_create_autocmd({ 'BufHidden', 'BufWipeout' }, {
    group = lifecycle_group,
    buffer = M.buf,
    callback = function()
      -- :close and window-manager mappings do not call M.close(). Delay the
      -- check until Neovim has removed the window, then revoke the session.
      vim.schedule(function()
        if not find_window() then end_session() end
      end)
    end,
  })
  M.attach_keys()
  return M.buf
end

function M.open()
  ensure_buffer()
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
    -- Managed mode is attended and panel-scoped. A timer must never reopen the
    -- SSH route after the operator closes the review surface.
    if tunnel and not find_window() then return end
    -- allow_capability_fetch = false makes a credential prompt structurally
    -- impossible on a timer tick: a cold or expired cache skips the tick
    -- instead of running capability_cmd in the background.
    M.refresh({ silent = true, allow_capability_fetch = false })
  end))
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('mcp_buff.setup() expects a table')
  end
  if decision_active then
    error('mcp_buff.setup(): cannot reconfigure while a decision is in progress')
  end
  local config = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULT_CONFIG), opts or {})
  local endpoint, endpoint_error = client_module.normalize_endpoint(config.endpoint)
  if not endpoint then error('mcp_buff.setup(): ' .. endpoint_error) end
  config.endpoint = endpoint
  config.timeout = math.max(1000, math.floor(tonumber(config.timeout) or DEFAULT_CONFIG.timeout))
  config.decision_timeout = client_module.clamp_decision_seconds(
    config.decision_timeout, DEFAULT_CONFIG.decision_timeout)
  config.poll_deadline = client_module.clamp_decision_seconds(
    config.poll_deadline, DEFAULT_CONFIG.poll_deadline)
  config.refresh_interval = math.floor(
    tonumber(config.refresh_interval) or DEFAULT_CONFIG.refresh_interval)
  if config.refresh_interval < 0 then
    error('mcp_buff.setup(): refresh_interval must be zero or a positive number')
  end
  if type(config.curl_command) ~= 'string' or trim(config.curl_command) == '' then
    error('mcp_buff.setup(): curl_command must be a non-empty string')
  end

  -- The broker compares the request Host against its own bound socket port, so
  -- an asymmetric forward is rejected. Overriding Host is the alternative to
  -- making the forward symmetric.
  if config.host_header ~= nil then
    if type(config.host_header) ~= 'string'
      or config.host_header:match('^127%.0%.0%.1:%d+$') == nil then
      error('mcp_buff.setup(): host_header must look like 127.0.0.1:PORT')
    end
  end

  local capability_cmd, capability_error = capability.normalize_cmd(config.capability_cmd)
  if capability_error then error('mcp_buff.setup(): ' .. capability_error) end
  config.capability_cmd = capability_cmd
  config.capability_ttl = math.floor(tonumber(config.capability_ttl)
    or DEFAULT_CONFIG.capability_ttl)
  if config.capability_ttl < 0 then
    error('mcp_buff.setup(): capability_ttl must be zero or a positive number')
  end
  local tunnel_config, tunnel_error = tunnel_module.normalize(config.tunnel, config.endpoint)
  if tunnel_error then error('mcp_buff.setup(): ' .. tunnel_error) end
  config.tunnel = tunnel_config or false

  request_generation = request_generation + 1
  loading = false
  if tunnel then tunnel:stop() end
  M.config = config
  -- Reconfiguring drops any capability held for the previous configuration.
  capability.configure({
    cmd = capability_cmd,
    ttl = config.capability_ttl,
  })
  client = client_module.new(config)
  if tunnel_config then
    tunnel = tunnel_module.new(tunnel_config, {
      on_exit = function(err)
        capability.clear()
        last_error = err.message
        if find_window() then
          rerender()
          vim.notify('McpBuff: ' .. err.message, vim.log.levels.ERROR)
        end
      end,
    })
  else
    tunnel = nil
  end
  last_error = nil
  configure_timer()
  if M.buf and api.nvim_buf_is_valid(M.buf) and (not tunnel or find_window()) then
    M.refresh()
  end
  return M
end

define_highlights()
client = client_module.new(M.config)
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
