local uv = vim.uv or vim.loop
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local stub
local panel

local APPROVE_ID = 't_20260820T180000.000Z_000000000001'
local DENY_ID = 't_20260820T180100.000Z_000000000002'

local function contains(text, needle, message)
  assert(text:find(needle, 1, true), message or ('expected text to contain %q'):format(needle))
end

local function unused_port()
  local socket = assert(uv.new_tcp())
  assert(socket:bind('127.0.0.1', 0) == 0)
  local address = assert(socket:getsockname())
  socket:close()
  return address.port
end

local function wait_for(callback, message)
  assert(vim.wait(5000, callback, 20), message)
end

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), '\n')
end

local function find_line(needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
    if line:find(needle, 1, true) then return index end
  end
  return nil
end

local function find_buffer(prefix)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer)
        and vim.api.nvim_buf_get_name(buffer):find(prefix, 1, true) == 1 then
      return buffer
    end
  end
  return nil
end

local function async(call)
  local settled, err, value = false, nil, nil
  call(function(request_error, result)
    err, value, settled = request_error, result, true
  end)
  wait_for(function() return settled end, 'async admin request timed out')
  assert(not err, vim.inspect(err))
  return value
end

local function list_request_count(endpoint)
  local result = vim.system({
    'curl', '--disable', '--silent', '--fail', '--max-time', '1', endpoint .. '/__stats',
  }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.json.decode(result.stdout).ticket_list_requests
end

local function run()
  assert(vim.fn.executable('node') == 1, 'node is required for the stub admin server')
  assert(vim.fn.executable('curl') == 1, 'curl is required for the client smoke test')
  local port = unused_port()
  local endpoint = 'http://127.0.0.1:' .. port
  stub = vim.system({ 'node', root .. '/scripts/stub-admin-server.js', tostring(port) }, {
    text = true,
  })

  wait_for(function()
    local result = vim.system({
      'curl', '--disable', '--silent', '--fail', '--max-time', '1', endpoint .. '/health',
    }, { text = true }):wait()
    return result.code == 0
  end, 'stub admin server did not become ready')

  assert(vim.fn.exists(':McpBuff') == 2, ':McpBuff command was not registered')
  panel = require('mcp_buff')
  panel.setup({ endpoint = endpoint, refresh_interval = 0, timeout = 5000 })
  panel.open()
  wait_for(function()
    return panel_text():find(APPROVE_ID, 1, true) ~= nil
  end, 'ticket list did not render the stub response')
  contains(panel_text(), 'Pending  (2)')
  contains(panel_text(), 'Executed  (1)')
  assert(panel.pending_count() == 2, 'pending_count did not use the refreshed cache')

  local line = assert(find_line(APPROVE_ID), 'approval ticket row was not mapped')
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
  panel.primary()
  local detail_name = 'mcpbuff://ticket/' .. APPROVE_ID
  wait_for(function() return find_buffer(detail_name) ~= nil end,
    'ticket detail buffer did not open')
  local detail_buffer = assert(find_buffer(detail_name))
  local detail = table.concat(vim.api.nvim_buf_get_lines(detail_buffer, 0, -1, false), '\n')
  contains(detail, 'full approval reason from the stub admin server')
  contains(detail, '`PATCH /zones/example-zone/dns_records/example-record`')
  contains(detail, '"reviewed": true')
  vim.api.nvim_buf_delete(detail_buffer, { force = true })

  local admin = require('mcp_buff.client').new({ endpoint = endpoint, timeout = 5000 })
  local executed = async(function(done) admin:approve(APPROVE_ID, done) end)
  assert(executed.status == 'executed', 'approve did not return the final ticket')
  assert(#executed.results == 1 and executed.results[1].ok,
    'approve response did not contain successful results')

  local denied = async(function(done) admin:deny(DENY_ID, 'fresh read changed', done) end)
  assert(denied.status == 'denied', 'deny did not return a denied ticket')
  assert(denied.denial_note == 'fresh read changed', 'deny note was not preserved')

  panel.refresh()
  wait_for(function() return panel.pending_count() == 0 end,
    'manual refresh did not update pending_count')
  contains(panel_text(), 'Pending  (0)')
  contains(panel_text(), 'Denied  (1)')

  local before_timer = list_request_count(endpoint)
  panel.setup({ endpoint = endpoint, refresh_interval = 1, timeout = 5000 })
  wait_for(function() return list_request_count(endpoint) > before_timer end,
    'setup refresh did not run before the timer')
  local after_setup = list_request_count(endpoint)
  wait_for(function() return list_request_count(endpoint) > after_setup end,
    'optional refresh timer did not request a new ticket list')
  panel.setup({ endpoint = endpoint, refresh_interval = 0, timeout = 5000 })
end

local ok, message = xpcall(run, debug.traceback)
if panel then pcall(panel.close) end
if stub then
  pcall(function() stub:kill(15) end)
  pcall(function() stub:wait(1000) end)
end
if not ok then error(message) end

print('McpBuff stub-admin smoke test passed')
