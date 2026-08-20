local api, fn, uv = vim.api, vim.fn, (vim.uv or vim.loop)
local client_module = require('mcp_buff.client')
local render = require('mcp_buff.render')

local DEFAULT_CONFIG = {
  endpoint = 'http://127.0.0.1:8792',
  curl_command = 'curl',
  timeout = 300000,
  refresh_interval = 0,
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
local request_generation = 0
local loading = false
local last_error
local pending = 0
local timer
local client

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

local function fetch_current(callback)
  local summary = current_ticket()
  if not summary then
    vim.notify('McpBuff: move the cursor onto a ticket', vim.log.levels.INFO)
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
end

function M.refresh(opts)
  opts = opts or {}
  if loading then return end
  loading = true
  last_error = nil
  request_generation = request_generation + 1
  local generation = request_generation
  rerender()
  client:list(nil, function(err, tickets)
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
end

function M.primary()
  fetch_current(function(ticket) show_detail(ticket) end)
end

function M.approve()
  fetch_current(function(ticket)
    if ticket.status ~= 'pending' then
      vim.notify('McpBuff: only pending tickets can be approved', vim.log.levels.WARN)
      return
    end
    local choice = fn.confirm(render.approval(ticket), '&Cancel\n&Approve', 1)
    if choice ~= 2 then return end
    vim.notify('McpBuff: executing ' .. ticket.id .. '…', vim.log.levels.INFO)
    client:approve(ticket.id, function(err, executed)
      if err then
        vim.notify('McpBuff: approval failed\n' .. err.message, vim.log.levels.ERROR)
        M.refresh({ silent = true })
        return
      end
      upsert_ticket(executed)
      show_detail(executed)
      local level = executed.status == 'executed' and vim.log.levels.INFO or vim.log.levels.ERROR
      vim.notify('McpBuff: ticket ' .. executed.status, level)
    end)
  end)
end

function M.deny()
  fetch_current(function(ticket)
    if ticket.status ~= 'pending' then
      vim.notify('McpBuff: only pending tickets can be denied', vim.log.levels.WARN)
      return
    end
    vim.ui.input({ prompt = 'Denial note (optional; Esc cancels): ' }, function(note)
      if note == nil then return end
      note = trim(note)
      local message = 'Deny ticket ' .. ticket.id .. '?'
      if note ~= '' then message = message .. '\n\nNote: ' .. note end
      if fn.confirm(message, '&Cancel\n&Deny', 1) ~= 2 then return end
      client:deny(ticket.id, note ~= '' and note or nil, function(err, denied)
        if err then
          vim.notify('McpBuff: denial failed\n' .. err.message, vim.log.levels.ERROR)
          M.refresh({ silent = true })
          return
        end
        upsert_ticket(denied)
        show_detail(denied)
        vim.notify('McpBuff: ticket denied', vim.log.levels.INFO)
      end)
    end)
  end)
end

function M.pending_count()
  return pending
end

function M.close()
  local window = find_window()
  if not window then return end
  local last_window = #api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(window)) == 1
  local last_tab = fn.tabpagenr('$') == 1
  if last_window and last_tab then
    api.nvim_set_current_win(window)
    vim.cmd('enew')
  else
    pcall(api.nvim_win_close, window, true)
  end
  M.win = nil
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
  api.nvim_set_option_value('buflisted', false, { buf = M.buf })
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  api.nvim_set_option_value('filetype', 'mcpbuff', { buf = M.buf })
  pcall(api.nvim_buf_set_name, M.buf, 'mcpbuff://tickets')
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
    M.refresh({ silent = true })
  end))
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('mcp_buff.setup() expects a table')
  end
  local config = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULT_CONFIG), opts or {})
  local endpoint, endpoint_error = client_module.normalize_endpoint(config.endpoint)
  if not endpoint then error('mcp_buff.setup(): ' .. endpoint_error) end
  config.endpoint = endpoint
  config.timeout = math.max(1000, math.floor(tonumber(config.timeout) or DEFAULT_CONFIG.timeout))
  config.refresh_interval = math.floor(
    tonumber(config.refresh_interval) or DEFAULT_CONFIG.refresh_interval)
  if config.refresh_interval < 0 then
    error('mcp_buff.setup(): refresh_interval must be zero or a positive number')
  end
  if type(config.curl_command) ~= 'string' or trim(config.curl_command) == '' then
    error('mcp_buff.setup(): curl_command must be a non-empty string')
  end
  M.config = config
  client = client_module.new(config)
  request_generation = request_generation + 1
  loading = false
  last_error = nil
  configure_timer()
  if M.buf and api.nvim_buf_is_valid(M.buf) then M.refresh() end
  return M
end

define_highlights()
client = client_module.new(M.config)
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('McpBuffHighlights', { clear = true }),
  callback = define_highlights,
})
api.nvim_create_autocmd('VimLeavePre', {
  group = api.nvim_create_augroup('McpBuffLifecycle', { clear = true }),
  callback = function()
    if timer then timer:stop(); timer:close(); timer = nil end
  end,
})

return M
