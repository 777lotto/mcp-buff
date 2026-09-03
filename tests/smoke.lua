-- Real curl, real vim.system, real HTTP against the hardened stub admin server.
--
-- Everything in the protocol's v2 acceptance criteria that can be observed on
-- the wire is observed here rather than asserted against a fake.

local uv = vim.uv or vim.loop
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local canonical = require('mcp_buff.canonical')
local capability_module = require('mcp_buff.capability')
local client_module = require('mcp_buff.client')

local stub
local panel
local permissions_panel
local endpoint
local ids
local workspace
local capability_counter
local capability_cmd

local CAPABILITY = string.rep('a1b2c3d4', 8)

local function contains(text, needle, message)
  assert(text:find(needle, 1, true), message or ('expected text to contain %q'):format(needle))
end

local function excludes(text, needle, message)
  assert(not text:find(needle, 1, true), message or ('expected text to omit %q'):format(needle))
end

local function equal(actual, expected, message)
  assert(actual == expected, (message or 'values differ') ..
    ('\nexpected: %s\nactual:   %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function unused_port()
  local socket = assert(uv.new_tcp())
  assert(socket:bind('127.0.0.1', 0) == 0)
  local address = assert(socket:getsockname())
  socket:close()
  return address.port
end

local function wait_for(callback, message)
  assert(vim.wait(10000, callback, 20), message)
end

local function write_file(path, contents)
  local handle = assert(io.open(path, 'w'))
  handle:write(contents)
  handle:close()
end

--- Drive curl directly, for the gate behaviour the client is built never to
--- provoke (it must not send Origin, and it always sends a content type).
local function raw(args)
  local command = {
    'curl', '--disable', '--silent', '--noproxy', '*',
    '--max-time', '10', '--write-out', '\n%{http_code}',
  }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, 'curl failed: ' .. tostring(result.stderr))
  local body, status = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
  return tonumber(status), body or ''
end

local function bearer()
  return { '--header', 'Authorization: Bearer ' .. CAPABILITY }
end

local function stats()
  local status, body = raw({ endpoint .. '/__stats' })
  equal(status, 200)
  return vim.json.decode(body)
end

local function capability_reads()
  local handle = io.open(capability_counter, 'r')
  if not handle then return 0 end
  local text = handle:read('*a')
  handle:close()
  return #text
end

local function async(call)
  local settled, err, value, info = false, nil, nil, nil
  call(function(request_error, result, extra)
    err, value, info, settled = request_error, result, extra, true
  end)
  wait_for(function() return settled end, 'async admin request timed out')
  return err, value, info
end

local function admin_client(overrides)
  return client_module.new(vim.tbl_extend('force', {
    endpoint = endpoint,
    timeout = 5000,
    decision_timeout = 65,
    poll_deadline = 65,
  }, overrides or {}))
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

local function focus(ticket_id)
  local line = assert(find_line(ticket_id), 'ticket row was not mapped: ' .. ticket_id)
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
end

-- ---------------------------------------------------------------------------

local function start_stub()
  assert(vim.fn.executable('node') == 1, 'node is required for the stub admin server')
  assert(vim.fn.executable('curl') == 1, 'curl is required for the client smoke test')
  local port = unused_port()
  endpoint = 'http://127.0.0.1:' .. port
  stub = vim.system({
    'node', root .. '/scripts/stub-admin-server.js', tostring(port), CAPABILITY,
  }, { text = true })

  wait_for(function()
    local result = vim.system({
      'curl', '--disable', '--silent', '--fail', '--noproxy', '*',
      '--max-time', '1', endpoint .. '/health',
    }, { text = true }):wait()
    return result.code == 0
  end, 'stub admin server did not become ready')
  ids = stats().ids
end

--- A capability_cmd that behaves like the real thing: an external command,
--- run with no shell, whose output never touches argv, the environment, or a
--- file the plugin writes.
local function install_capability_cmd()
  workspace = vim.fn.tempname()
  vim.fn.mkdir(workspace, 'p')
  capability_counter = workspace .. '/reads'
  local secret_path = workspace .. '/capability'
  write_file(secret_path, CAPABILITY .. '\n')
  local script = workspace .. '/fetch-capability.sh'
  write_file(script, table.concat({
    '#!/bin/sh',
    'printf x >> "' .. capability_counter .. '"',
    'cat "' .. secret_path .. '"',
    '',
  }, '\n'))
  return { 'sh', script }
end

local function test_panel_lists_every_state()
  wait_for(function()
    return panel_text():find(ids.approve, 1, true) ~= nil
  end, 'ticket list did not render the stub response')
  local text = panel_text()
  contains(text, 'Pending  (2)')
  -- indeterminate is surfaced as its own state, never bucketed with failed.
  contains(text, 'Indeterminate  (1)')
  contains(text, 'Failed  (0)')
  contains(text, 'Executed  (1)')
  -- The overdue pending ticket was expired lazily by the read itself.
  contains(text, 'Expired  (1)')
  equal(panel.pending_count(), 2, 'pending_count did not use the refreshed cache')
  -- One capability read has served the whole session so far.
  equal(capability_reads(), 1, 'the capability was read more than once')
end

local function test_listing_prunes_past_retention()
  -- GET /tickets is not a pure read: it unlinks terminal tickets past the
  -- retention window, after which the ticket itself 404s.
  excludes(panel_text(), ids.prunable, 'a pruned ticket is still listed')
  local err = async(function(done) admin_client():get(ids.prunable, done) end)
  equal(err.kind, 'not_found')
  contains(err.message, 'retention window')
end

local function test_detail_renders_the_reviewable_payload()
  focus(ids.approve)
  panel.primary()
  local detail_name = 'mcpbuff://ticket/' .. ids.approve
  wait_for(function() return find_buffer(detail_name) ~= nil end,
    'ticket detail buffer did not open')
  local buffer = assert(find_buffer(detail_name))
  local detail = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n')

  contains(detail, 'full approval reason from the stub admin server')
  contains(detail, '**Expires:**')
  contains(detail, '"reviewed": true')
  contains(detail, '**Precondition:** `GET /zones/')
  contains(detail, '**Expected status:** 200')
  contains(detail, '## Preflight observations')

  -- Ticket bodies must not reach a swap file, an undo file, or a log.
  equal(vim.api.nvim_get_option_value('buftype', { buf = buffer }), 'nofile')
  equal(vim.api.nvim_get_option_value('swapfile', { buf = buffer }), false)
  equal(vim.api.nvim_get_option_value('undofile', { buf = buffer }), false)
  equal(vim.api.nvim_get_option_value('buftype', { buf = panel.buf }), 'nofile')
  equal(vim.api.nvim_get_option_value('swapfile', { buf = panel.buf }), false)
  equal(vim.api.nvim_get_option_value('undofile', { buf = panel.buf }), false)
  vim.api.nvim_buf_delete(buffer, { force = true })
end

local function test_recomputed_digest_matches_the_served_one()
  local err, ticket = async(function(done) admin_client():get(ids.approve, done) end)
  assert(not err, vim.inspect(err))
  -- The stub computes ticket_sha256 with the broker's own canonicalJson; this
  -- proves the Lua encoder agrees with it over a live payload.
  local verified, reason = canonical.verify(ticket)
  equal(verified, true, 'digest recomputation disagreed: ' .. tostring(reason))
  equal(#ticket.ticket_sha256, 64)
end

local function test_transport_gates_and_precedence()
  -- A browser can never be a client: Origin must be absent entirely.
  local origin_status, origin_body = raw(vim.list_extend(
    { '--header', 'Origin: http://example.invalid' },
    vim.list_extend(bearer(), { endpoint .. '/tickets' })))
  equal(origin_status, 403)
  contains(origin_body, 'origin not allowed')

  -- A wrong Host masks a missing capability: the answer is 400, not 401.
  local host_status, host_body = raw({
    '--header', 'Host: 127.0.0.1:9999', endpoint .. '/tickets',
  })
  equal(host_status, 400, 'the Host gate did not take precedence over the bearer gate')
  contains(host_body, 'invalid host')

  -- A bodyless POST from an unauthenticated client is 401, not 415.
  local bearer_status = raw({ '--request', 'POST',
    endpoint .. '/tickets/' .. ids.deny .. '/approve' })
  equal(bearer_status, 401, 'the bearer gate did not take precedence over content type')

  -- With a capability but no content type, the same POST reaches 415.
  local ct_status, ct_body = raw(vim.list_extend(bearer(), {
    '--request', 'POST', endpoint .. '/tickets/' .. ids.deny .. '/approve',
  }))
  equal(ct_status, 415)
  contains(ct_body, 'application/json required')

  -- Off-route requests do not return JSON.
  local off_status, off_body = raw(vim.list_extend(bearer(), { endpoint .. '/nope' }))
  equal(off_status, 404)
  contains(off_body, '<!DOCTYPE html>')
  equal(select(2, client_module.decode_body(off_body)), 'html')

  -- A body over the 32kb cap is 500, not the 413 a reader would assume.
  local oversize = vim.json.encode({
    ticket_sha256 = string.rep('0', 64),
    note = string.rep('z', 40000),
  })
  local big_status, big_body = raw(vim.list_extend(bearer(), {
    '--request', 'POST',
    '--header', 'Content-Type: application/json',
    '--data-raw', oversize,
    endpoint .. '/tickets/' .. ids.deny .. '/deny',
  }))
  equal(big_status, 500, 'an oversized body did not answer 500')
  contains(big_body, 'internal server error')
end

local function test_wrong_capability_is_a_bearer_failure()
  local wrong = workspace .. '/wrong-capability.sh'
  write_file(wrong, '#!/bin/sh\nprintf %s ' .. string.rep('f', 64) .. '\n')
  capability_module.configure({ cmd = { 'sh', wrong }, ttl = 300 })
  local err = async(function(done) admin_client():get(ids.approve, done) end)
  equal(err.kind, 'gate_bearer')
  equal(err.status, 401)
  -- Restore the working capability for the remaining tests.
  capability_module.configure({ cmd = capability_cmd, ttl = 300 })
end

local function test_only_pending_tickets_are_decidable()
  local before = stats().decision_posts
  local real_input = vim.fn.input
  local real_notify = vim.notify
  -- Set up so that a correct suffix would be typed: the refusal must come from
  -- the pending check, before the confirmation is ever reached.
  local _, ticket = async(function(done) admin_client():get(ids.indeterminate, done) end)
  vim.fn.input = function() return ticket.ticket_sha256:sub(-8) end

  local ok, err = pcall(function()
    for _, action in ipairs({ panel.approve, panel.deny }) do
      local notices = {}
      vim.notify = function(message) notices[#notices + 1] = tostring(message) end
      focus(ids.indeterminate)
      action()
      vim.wait(800, function() return #notices > 0 end, 20)
      vim.notify = real_notify
      -- Assert the refusal came from the pending check, not from an empty
      -- cursor position, so the test cannot pass vacuously.
      contains(table.concat(notices, '\n'), 'ticket is indeterminate, not pending')
      equal(stats().decision_posts, before, 'a non-pending ticket was submitted')
    end
  end)

  vim.fn.input = real_input
  vim.notify = real_notify
  if not ok then error(err) end
end

local function test_typed_confirmation_gates_the_decision()
  local before = stats().decision_posts
  local answer

  local real_input = vim.fn.input
  vim.fn.input = function() return answer end

  local ok, err = pcall(function()
    panel.refresh()
    wait_for(function() return find_line(ids.approve) ~= nil end, 'panel did not refresh')
    focus(ids.approve)

    -- A wrong suffix must submit nothing at all.
    answer = 'deadbeef'
    panel.approve()
    wait_for(function() return true end)
    vim.wait(300)
    equal(stats().decision_posts, before, 'a mistyped digest still submitted a decision')

    -- The real suffix, typed in full, is what authorises the submission.
    local _, ticket = async(function(done) admin_client():get(ids.approve, done) end)
    answer = ticket.ticket_sha256:sub(-8)
    focus(ids.approve)
    panel.approve()
    wait_for(function()
      local _, current = async(function(done) admin_client():get(ids.approve, done) end)
      return current and current.status == 'executed'
    end, 'the approval did not reach a terminal state')
  end)

  vim.fn.input = real_input
  if not ok then error(err) end

  -- Exactly one decision reached the broker: a decision is never resubmitted.
  equal(stats().decision_posts, before + 1, 'the decision was submitted more than once')
end

local function test_approve_returns_a_terminal_ticket()
  local err, ticket = async(function(done) admin_client():get(ids.approve, done) end)
  assert(not err, vim.inspect(err))
  -- Approval executes synchronously, so a 200 from approve is always terminal.
  equal(ticket.status, 'executed')
  equal(#ticket.results, 1)
  equal(ticket.results[1].outcome, 'succeeded')
  assert(#ticket.preflight_results >= 2, 'both preflight phases were not recorded')
end

local function test_digest_and_state_conflicts_are_distinguished()
  local api = admin_client()

  -- A digest copied from another ticket is a cross-ticket replay.
  local _, other = async(function(done) api:get(ids.deny, done) end)
  local _, approved = async(function(done) api:get(ids.approve, done) end)
  local replay = async(function(done)
    api:decide(ids.deny, 'approve', { ticket_sha256 = approved.ticket_sha256 },
      { callback = done })
  end)
  equal(replay.kind, 'digest_conflict')
  contains(replay.message, 'No Cloudflare request was sent')

  -- The same status, a different meaning: this one is the state machine.
  local decided = async(function(done)
    api:decide(ids.approve, 'approve', { ticket_sha256 = approved.ticket_sha256 },
      { callback = done })
  end)
  equal(decided.kind, 'state_conflict')
  contains(decided.message, 'while you were reviewing')

  -- An already-expired ticket refuses at the state machine too, even though its
  -- digest is still correct.
  local _, overdue = async(function(done) api:get(ids.overdue, done) end)
  equal(overdue.status, 'expired')
  local expired = async(function(done)
    api:decide(ids.overdue, 'deny', { ticket_sha256 = overdue.ticket_sha256 },
      { callback = done })
  end)
  equal(expired.kind, 'state_conflict')

  return other
end

local function test_deny_reads_denial_note()
  local api = admin_client()
  local _, ticket = async(function(done) api:get(ids.deny, done) end)
  local err, denied, info = async(function(done)
    api:decide(ids.deny, 'deny', {
      ticket_sha256 = ticket.ticket_sha256,
      note = '  a fresh read changed the record  ',
    }, { callback = done })
  end)
  assert(not err, vim.inspect(err))
  equal(denied.status, 'denied')
  equal(info.polled, false, 'a successful decision was needlessly polled')
  -- The note comes back under a different name.
  equal(denied.denial_note, 'a fresh read changed the record')
  contains(require('mcp_buff.render').detail(denied), 'a fresh read changed the record')
end

local function test_background_refresh_never_prompts()
  panel.setup({
    endpoint = endpoint,
    capability_cmd = capability_cmd,
    refresh_interval = 1,
    timeout = 5000,
  })
  -- setup() performs one ordinary refresh of its own, which may legitimately
  -- acquire a capability. The timer is what must not.
  vim.wait(1000)

  -- A cold cache plus a running timer is exactly the situation that could turn
  -- into a credential prompt storm.
  capability_module.clear()
  local before_reads = capability_reads()
  local before_lists = stats().ticket_list_requests
  vim.wait(3500)

  equal(capability_reads(), before_reads,
    'a background refresh tick ran capability_cmd')
  equal(stats().ticket_list_requests, before_lists,
    'a background tick reached the broker without a capability')

  -- A manual refresh is still allowed to acquire one.
  panel.refresh()
  wait_for(function() return capability_reads() > before_reads end,
    'a manual refresh did not acquire the capability')
  panel.setup({
    endpoint = endpoint,
    capability_cmd = capability_cmd,
    refresh_interval = 0,
    timeout = 5000,
  })
end

local function test_permissions_panel_narrows_cloudflare_runtime_scope()
  local before = stats().permission_posts
  panel.open_permissions()
  permissions_panel = require('mcp_buff.permissions')
  wait_for(function()
    local provider = permissions_panel.providers[1]
    return provider and provider.snapshot ~= nil
  end, 'permissions panel did not render the broker response')

  local cloudflare = permissions_panel.providers[1]
  local before_reads = capability_reads()
  equal(cloudflare.id, 'cloudflare')
  equal(permissions_panel.providers[2].id, 'github')
  equal(permissions_panel.providers[2].configured, false)
  local first = cloudflare.snapshot.permissions[1]
  equal(first.enabled, true)

  local row
  for line, mapped in pairs(permissions_panel.line_map) do
    if mapped.provider == cloudflare and mapped.index == 1 then row = line end
  end
  assert(row, 'the first Cloudflare permission was not mapped')
  vim.api.nvim_set_current_win(permissions_panel.win)
  vim.api.nvim_win_set_cursor(permissions_panel.win, { row, 0 })
  permissions_panel.toggle()
  equal(cloudflare.snapshot.permissions[1].enabled, false)

  local real_input = vim.fn.input
  vim.fn.input = function()
    return cloudflare.snapshot.permissions_sha256:sub(-8)
  end
  local ok, err = pcall(permissions_panel.apply)
  vim.fn.input = real_input
  if not ok then error(err) end

  wait_for(function() return stats().permission_posts == before + 1 end,
    'permission update did not reach the stub')
  wait_for(function() return not cloudflare.applying end,
    'permission update did not settle')
  equal(cloudflare.snapshot.permissions[1].enabled, false)
  equal(cloudflare.must_refresh, false)
  equal(capability_reads(), before_reads,
    'the permissions view did not share the Cloudflare provider capability cache')

  local request_error, snapshot = async(function(done)
    admin_client({ permission_provider = 'cloudflare' }):get_permissions(done)
  end)
  assert(not request_error, vim.inspect(request_error))
  equal(snapshot.permissions[1].enabled, false)
  permissions_panel.close()
end

local function run()
  start_stub()
  capability_cmd = install_capability_cmd()

  assert(vim.fn.exists(':McpBuff') == 2, ':McpBuff command was not registered')
  assert(vim.fn.exists(':McpBuffPermissions') == 2,
    ':McpBuffPermissions command was not registered')
  panel = require('mcp_buff')
  panel.setup({
    endpoint = endpoint,
    capability_cmd = capability_cmd,
    refresh_interval = 0,
    timeout = 5000,
    decision_timeout = 65,
    poll_deadline = 65,
  })
  panel.open()

  test_panel_lists_every_state()
  test_listing_prunes_past_retention()
  test_detail_renders_the_reviewable_payload()
  test_recomputed_digest_matches_the_served_one()
  test_transport_gates_and_precedence()
  test_wrong_capability_is_a_bearer_failure()
  test_only_pending_tickets_are_decidable()
  test_typed_confirmation_gates_the_decision()
  test_approve_returns_a_terminal_ticket()
  test_digest_and_state_conflicts_are_distinguished()
  test_deny_reads_denial_note()
  test_background_refresh_never_prompts()
  test_permissions_panel_narrows_cloudflare_runtime_scope()
end

local ok, message = xpcall(run, debug.traceback)
if panel then pcall(panel.close) end
if permissions_panel then pcall(permissions_panel.close) end
if stub then
  pcall(function() stub:kill(15) end)
  pcall(function() stub:wait(1000) end)
end
if workspace then pcall(vim.fn.delete, workspace, 'rf') end
if not ok then error(message) end

print('McpBuff stub-admin smoke test passed')
