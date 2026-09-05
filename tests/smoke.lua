-- Real curl, real vim.system, real HTTP against the hardened stub admin server.
--
-- Everything in the protocol's v2 acceptance criteria that can be observed on
-- the wire is observed here rather than asserted against a fake.

local uv = vim.uv or vim.loop
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local canonical = require('mcp_buff.canonical')
local capability_module = require('mcp_buff.capability')
local client_module = require('mcp_buff.client')
local cloudflare_source = require('mcp_buff.sources.cloudflare')
local github_source = require('mcp_buff.sources.github')

local stub
local git_stub
local panel
local endpoint
local git_endpoint
local ids
local git_ids
local workspace
local capability_counter
local git_capability_counter
local capability_cmd
local git_capability_cmd
-- Separate capability instances for the suite's own ad-hoc clients, reading the
-- same secrets through their own counters. The panel's counters then measure
-- only what the panel did, which is what every "read exactly once" assertion
-- below is about.
local probe_capability
local git_probe_capability

local CAPABILITY = string.rep('a1b2c3d4', 8)
-- A different capability for the different socket. Reusing one would let a bug
-- that crossed the two brokers' bearers pass this suite.
local GIT_CAPABILITY = string.rep('9f8e7d6c', 8)

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

local function git_stats()
  local status, body = raw({ git_endpoint .. '/__stats' })
  equal(status, 200)
  return vim.json.decode(body)
end

local function count_reads(path)
  local handle = io.open(path, 'r')
  if not handle then return 0 end
  local text = handle:read('*a')
  handle:close()
  return #text
end

local function capability_reads()
  return count_reads(capability_counter)
end

local function git_capability_reads()
  return count_reads(git_capability_counter)
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
    capability = probe_capability,
  }, overrides or {}))
end

--- A client for the GitHub broker, with its own source and its own capability.
local function git_client(overrides)
  return client_module.new(vim.tbl_extend('force', {
    source = github_source,
    endpoint = git_endpoint,
    timeout = 5000,
    decision_timeout = 65,
    poll_deadline = 65,
    capability = git_probe_capability,
  }, overrides or {}))
end

local function tab(id)
  for _, entry in ipairs(panel.tabs) do
    if entry.id == id then return entry end
  end
  error('no such panel tab: ' .. tostring(id))
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

local function point_at(ticket_id)
  local line = assert(find_line(ticket_id), 'ticket row was not mapped: ' .. ticket_id)
  vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
end

local function focus(ticket_id)
  vim.api.nvim_set_current_win(panel.win)
  point_at(ticket_id)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

--- Run a body with every typed-input path booby-trapped.
---
--- A decision must not ask for anything: no digest to retype, no prompt of any
--- other shape. A prompt raised here fails the test rather than hanging the
--- suite behind a stub that silently answers it.
local function without_prompts(body)
  local real_input, real_ui_input = vim.fn.input, vim.ui.input
  local prompted
  vim.fn.input = function(...)
    prompted = tostring((select(1, ...)))
    error('the panel asked for typed input: ' .. prompted)
  end
  vim.ui.input = function(opts)
    prompted = tostring(opts and opts.prompt)
    error('the panel asked for typed input: ' .. prompted)
  end
  local ok, err = pcall(body)
  vim.fn.input, vim.ui.input = real_input, real_ui_input
  if not ok then error(err) end
  assert(prompted == nil, 'a decision prompted for ' .. tostring(prompted))
end

-- ---------------------------------------------------------------------------

local function wait_ready(base, what)
  wait_for(function()
    local result = vim.system({
      'curl', '--disable', '--silent', '--fail', '--noproxy', '*',
      '--max-time', '1', base .. '/health',
    }, { text = true }):wait()
    return result.code == 0
  end, what .. ' did not become ready')
end

--- Two stubs on two ports with two capabilities, because two brokers is the
--- thing under test. A single stub could not catch a client that reused one
--- socket's bearer on the other.
local function start_stubs()
  assert(vim.fn.executable('node') == 1, 'node is required for the stub admin servers')
  assert(vim.fn.executable('curl') == 1, 'curl is required for the client smoke test')
  local port = unused_port()
  endpoint = 'http://127.0.0.1:' .. port
  stub = vim.system({
    'node', root .. '/scripts/stub-admin-server.js', tostring(port), CAPABILITY,
  }, { text = true })
  wait_ready(endpoint, 'stub admin server')
  ids = stats().ids

  local git_port = unused_port()
  git_endpoint = 'http://127.0.0.1:' .. git_port
  git_stub = vim.system({
    'node', root .. '/scripts/stub-git-admin-server.js', tostring(git_port), GIT_CAPABILITY,
  }, { text = true })
  wait_ready(git_endpoint, 'stub git admin server')
  git_ids = git_stats().ids
end

--- A capability_cmd that behaves like the real thing: an external command,
--- run with no shell, whose output never touches argv, the environment, or a
--- file the plugin writes. Each read is counted, so the suite can prove that a
--- credential is decrypted once per operator decision and not once per request.
local function install_capability_cmd(name, secret)
  local counter = workspace .. '/' .. name .. '-reads'
  local secret_path = workspace .. '/' .. name .. '-capability'
  write_file(secret_path, secret .. '\n')
  local script = workspace .. '/fetch-' .. name .. '.sh'
  write_file(script, table.concat({
    '#!/bin/sh',
    'printf x >> "' .. counter .. '"',
    'cat "' .. secret_path .. '"',
    '',
  }, '\n'))
  return { 'sh', script }, counter
end

local function test_panel_lists_every_state()
  wait_for(function()
    return panel_text():find(ids.approve, 1, true) ~= nil
  end, 'ticket list did not render the stub response')
  local text = panel_text()
  contains(text, 'Tickets · Pending  (2)')
  -- indeterminate is surfaced as its own state, never bucketed with failed.
  contains(text, 'Tickets · Indeterminate  (1)')
  contains(text, 'Tickets · Failed  (0)')
  contains(text, 'Tickets · Executed  (1)')
  -- The overdue pending ticket was expired lazily by the read itself.
  contains(text, 'Tickets · Expired  (1)')
  equal(panel.pending_count('cloudflare'), 2,
    'pending_count did not use the refreshed cache')
  -- One capability read has served the whole session so far, and it served the
  -- ticket list and the permission document both.
  equal(capability_reads(), 1, 'the capability was read more than once')

  -- The Git tab exists and is on the bar, but nothing has been read from it:
  -- opening the panel must not reach a second broker or read a second
  -- credential.
  contains(text, '▸ 1 Cloudflare 2')
  contains(text, '2 Git')
  equal(tab('github').visited, false, 'opening the panel visited both brokers')
  equal(git_capability_reads(), 0, 'opening the panel read the GitHub capability')
  equal(git_stats().ticket_list_requests, 0,
    'opening the panel listed tickets on a broker the operator was not looking at')
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
  local detail_name = 'mcpbuff://cloudflare/ticket/' .. ids.approve
  wait_for(function() return find_buffer(detail_name) ~= nil end,
    'ticket detail buffer did not open')
  local buffer = assert(find_buffer(detail_name))
  local float = vim.api.nvim_get_current_win()
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
  equal(vim.api.nvim_get_option_value('filetype', { buf = buffer }), 'mcpbuffdetail')
  equal(vim.api.nvim_get_option_value('syntax', { buf = buffer }), 'markdown')
  equal(vim.api.nvim_get_option_value('wrap', { win = float }), true)
  equal(vim.api.nvim_get_option_value('linebreak', { win = float }), true)
  equal(vim.api.nvim_get_option_value('breakindent', { win = float }), true)
  equal(vim.api.nvim_get_option_value('breakindentopt', { win = float }),
    'shift:2,min:20')

  -- Prove display behavior, not only the option values. This path is longer
  -- than the float, so it must consume multiple screen rows while leftcol
  -- stays at zero even with the cursor at the end.
  local wrapped_row
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:find('**Precondition:**', 1, true) then
      wrapped_row = index
      vim.api.nvim_win_set_cursor(float, { index, #line })
      break
    end
  end
  assert(wrapped_row, 'the long detail line was not rendered')
  local height = vim.api.nvim_win_text_height(float, {
    start_row = wrapped_row - 1,
    end_row = wrapped_row - 1,
  })
  assert(height.all > 1, 'the long ticket line did not wrap inside the float')
  equal(vim.api.nvim_win_call(float, function() return vim.fn.winsaveview().leftcol end), 0,
    'viewing the end of a long ticket line introduced horizontal scrolling')
  vim.api.nvim_buf_delete(buffer, { force = true })
end

--- The preview follows the same status groups and ticket ordering as the list.
--- Every move is a detail GET only: the float and provider stay put, and no
--- decision endpoint is touched.
local function test_preview_navigation_stays_in_the_float()
  local before = stats().decision_posts
  focus(ids.deny) -- newest/top Pending ticket
  panel.primary()
  local first_name = 'mcpbuff://cloudflare/ticket/' .. ids.deny
  wait_for(function() return find_buffer(first_name) ~= nil end,
    'the starting preview did not open')
  local float = vim.api.nvim_get_current_win()

  local function showing(ticket_id)
    if not vim.api.nvim_win_is_valid(float) then return false end
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(float))
    return name == 'mcpbuff://cloudflare/ticket/' .. ticket_id
  end
  assert(showing(ids.deny), 'the starting preview did not take focus')

  press('>')
  wait_for(function() return showing(ids.approve) end,
    '> did not open the next ticket in Pending')
  equal(vim.api.nvim_get_current_win(), float, '> replaced the preview window')
  local panel_line = vim.api.nvim_win_get_cursor(panel.win)[1]
  contains(vim.api.nvim_buf_get_lines(panel.buf, panel_line - 1, panel_line, false)[1],
    ids.approve, 'the list cursor did not follow preview navigation')

  press('<lt>')
  wait_for(function() return showing(ids.deny) end,
    '< did not open the previous ticket in Pending')

  -- Empty Approved/Executing groups are headings, not destinations. The next
  -- non-empty category after Pending is Indeterminate, whose top ticket opens.
  press('<Tab>')
  wait_for(function() return showing(ids.indeterminate) end,
    '<Tab> did not open the next non-empty ticket category')
  equal(panel.active, 'cloudflare', '<Tab> left the preview\'s broker tab')
  equal(vim.api.nvim_get_current_win(), float, '<Tab> closed the preview window')

  press('<S-Tab>')
  wait_for(function() return showing(ids.deny) end,
    '<S-Tab> did not return to the previous ticket category\'s top row')
  equal(stats().decision_posts, before,
    'preview navigation submitted a ticket decision')

  press('q')
  assert(not vim.api.nvim_win_is_valid(float), 'q did not close the navigated preview')
end

local function test_recomputed_digest_matches_the_served_one()
  local err, ticket = async(function(done) admin_client():get(ids.approve, done) end)
  assert(not err, vim.inspect(err))
  -- The stub computes ticket_sha256 with the broker's own canonicalJson; this
  -- proves the Lua encoder agrees with it over a live payload.
  local verified, reason = canonical.verify(ticket, cloudflare_source.digest_prefix)
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
  -- Missing, malformed, and merely wrong capabilities are indistinguishable
  -- here, by design.
  local err = async(function(done)
    admin_client({
      capability = capability_module.new({ cmd = { 'sh', wrong }, ttl = 300 }),
    }):get(ids.approve, done)
  end)
  equal(err.kind, 'gate_bearer')
  equal(err.status, 401)
end

local function test_only_pending_tickets_are_decidable()
  local before = stats().decision_posts
  local real_notify = vim.notify

  local ok, err = pcall(function()
    without_prompts(function()
      for _, action in ipairs({ panel.approve, panel.deny }) do
        local notices = {}
        vim.notify = function(message) notices[#notices + 1] = tostring(message) end
        focus(ids.indeterminate)
        action()
        vim.wait(800, function() return #notices > 0 end, 20)
        vim.notify = real_notify
        -- Assert the refusal came from the pending check, not from an empty
        -- cursor position, so the test cannot pass vacuously.
        contains(table.concat(notices, '\n'),
          'ticket is indeterminate, which Cloudflare broker cannot decide')
        equal(stats().decision_posts, before, 'a non-pending ticket was submitted')
      end
    end)
  end)

  vim.notify = real_notify
  if not ok then error(err) end
end

--- One keystroke decides, and it asks for nothing.
---
--- What authorises the submission is the panel's own work -- a fresh read, the
--- decidability check, and a digest recomputed locally in this broker's domain
--- -- not a suffix retyped by the operator. The checks that a typed digest was
--- a proxy for are asserted directly elsewhere in this suite; what is asserted
--- here is that nothing is asked for and that the payload is on screen.
local function test_one_keystroke_decides_without_a_prompt()
  local before = stats().decision_posts

  without_prompts(function()
    panel.refresh()
    wait_for(function() return find_line(ids.approve) ~= nil end, 'panel did not refresh')
    focus(ids.approve)
    panel.approve()
    wait_for(function()
      local _, current = async(function(done) admin_client():get(ids.approve, done) end)
      return current and current.status == 'executed'
    end, 'the approval did not reach a terminal state')
  end)

  -- The ticket that was submitted is left on screen, settled, rather than the
  -- operator being returned to a list row that says only how it ended.
  local settled = assert(find_buffer('mcpbuff://cloudflare/ticket/' .. ids.approve),
    'the decided ticket was not left in the preview')
  contains(table.concat(vim.api.nvim_buf_get_lines(settled, 0, -1, false), '\n'),
    '**Status:** executed')

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
  contains(require('mcp_buff.render').detail(cloudflare_source, denied),
    'a fresh read changed the record')
end

local function configure_panel(overrides)
  panel.setup(vim.tbl_extend('force', {
    endpoint = endpoint,
    capability_cmd = capability_cmd,
    refresh_interval = 0,
    timeout = 5000,
    decision_timeout = 65,
    poll_deadline = 65,
    github = {
      endpoint = git_endpoint,
      capability_cmd = git_capability_cmd,
    },
  }, overrides or {}))
  -- setup() drops every cached capability and then refreshes the visible tab,
  -- so wait for that read to land. Otherwise it arrives in the middle of the
  -- next test and shows up as a spurious extra credential read.
  if panel.win then
    wait_for(function()
      local current = tab('cloudflare')
      return not current.loading and not current.permissions.loading
    end, 'the panel did not settle after setup()')
  end
end

local function test_background_refresh_never_prompts()
  configure_panel({ refresh_interval = 1 })
  -- setup() performs one ordinary refresh of its own, which may legitimately
  -- acquire a capability. The timer is what must not.
  vim.wait(1000)

  -- A cold cache plus a running timer is exactly the situation that could turn
  -- into a credential prompt storm. The cache is this broker's own instance,
  -- not a module-wide one, so that is what has to go cold.
  tab('cloudflare').broker.capability.clear()
  local before_reads = capability_reads()
  local before_lists = stats().ticket_list_requests
  vim.wait(3500)

  equal(capability_reads(), before_reads,
    'a background refresh tick ran capability_cmd')
  equal(stats().ticket_list_requests, before_lists,
    'a background tick reached the broker without a capability')
  -- And no tick touched the provider the operator is not looking at.
  equal(git_stats().ticket_list_requests, 0,
    'a background tick read a broker whose tab was never opened')

  -- A manual refresh is still allowed to acquire one.
  panel.refresh()
  wait_for(function() return capability_reads() > before_reads end,
    'a manual refresh did not acquire the capability')
  configure_panel()
end

--- Permissions live inside the provider tab now, so the apply target is the
--- tab rather than whatever row the cursor happened to be on.
local function test_permissions_section_narrows_cloudflare_runtime_scope()
  local before = stats().permission_posts
  local cloudflare = tab('cloudflare')
  wait_for(function() return cloudflare.permissions.snapshot ~= nil end,
    'the permissions section did not render the broker response')
  local before_reads = capability_reads()
  contains(panel_text(), 'Runtime permissions')
  contains(panel_text(), 'cf.dns.record.create.v1')

  local first = cloudflare.permissions.snapshot.permissions[1]
  equal(first.enabled, true)
  local row
  for line, mapped in pairs(panel.line_map) do
    if mapped.kind == 'permission' and mapped.tab == cloudflare and mapped.index == 1 then
      row = line
    end
  end
  assert(row, 'the first Cloudflare permission was not mapped')
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  -- <CR> on a permission row is a local toggle: nothing is sent.
  panel.primary()
  equal(cloudflare.permissions.snapshot.permissions[1].enabled, false)
  equal(stats().permission_posts, before, 'a toggle reached the broker')
  -- An unapplied edit is marked on the tab bar, where the operator can see it
  -- from the other tab.
  local bar_line = vim.api.nvim_buf_get_lines(panel.buf, 1, 2, false)[1]
  equal(bar_line:match('Cloudflare ?%d*(%*?)'), '*',
    'an unapplied permission edit was not marked on the tab bar')

  local real_input = vim.fn.input
  vim.fn.input = function()
    return cloudflare.permissions.snapshot.permissions_sha256:sub(-8)
  end
  local ok, err = pcall(panel.apply_permissions)
  vim.fn.input = real_input
  if not ok then error(err) end

  wait_for(function() return stats().permission_posts == before + 1 end,
    'permission update did not reach the stub')
  wait_for(function() return not cloudflare.permissions.applying end,
    'permission update did not settle')
  equal(cloudflare.permissions.snapshot.permissions[1].enabled, false)
  equal(cloudflare.permissions.must_refresh, false)
  equal(capability_reads(), before_reads,
    'the permissions section did not share the tab broker capability cache')

  local request_error, snapshot = async(function(done)
    admin_client():get_permissions(done)
  end)
  assert(not request_error, vim.inspect(request_error))
  equal(snapshot.permissions[1].enabled, false)
  equal(snapshot.provider, 'cloudflare')

  -- Put it back so the tab is clean for the remaining tests.
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  panel.primary()
  vim.fn.input = function()
    return cloudflare.permissions.snapshot.permissions_sha256:sub(-8)
  end
  pcall(panel.apply_permissions)
  vim.fn.input = real_input
  wait_for(function() return not cloudflare.permissions.applying end,
    'the restoring permission update did not settle')
end

--- Switching tabs is the only place a second credential is read, and it happens
--- because the operator asked for it.
local function test_switching_to_the_git_tab_reads_only_its_own_broker()
  local cloudflare_reads = capability_reads()
  panel.select_tab('github')
  wait_for(function()
    return panel_text():find(git_ids.approve, 1, true) ~= nil
      and tab('github').permissions.snapshot ~= nil
  end, 'the Git tab did not render the git broker response')

  -- One read served both of this tab's surfaces. The ticket list and the
  -- permission document go out together, and a capability_cmd that needs a
  -- pinentry must not be asked twice for one keystroke.
  equal(git_capability_reads(), 1, 'the GitHub capability was not read exactly once')
  equal(capability_reads(), cloudflare_reads,
    'switching tabs re-read the Cloudflare capability')

  local text = panel_text()
  contains(text, '▸ 2 Git 4')
  -- This broker's own state names, not Cloudflare's.
  contains(text, 'Tickets · Pending  (4)')
  contains(text, 'Tickets · Approved · unspent  (1)')
  contains(text, 'Tickets · Spent  (1)')
  contains(text, 'Tickets · Expired  (1)')
  excludes(text, 'Executed', 'a Cloudflare status appeared on the Git tab')
  excludes(text, 'Indeterminate', 'a Cloudflare status appeared on the Git tab')
  -- Its own permission registry, on the same tab.
  contains(text, 'github.workflow.write')
  excludes(text, 'cf.dns.record.create.v1',
    'the Cloudflare registry leaked into the Git tab')

  -- pending_count with no argument is the total across brokers, which is what
  -- a statusline wants: work waiting does not depend on which tab is open.
  equal(panel.pending_count('github'), 4)
  equal(panel.pending_count(),
    panel.pending_count('cloudflare') + panel.pending_count('github'))

  -- The list is the sweep here too: the terminal ticket past retention is gone.
  excludes(text, git_ids.prunable, 'a pruned git ticket is still listed')

  -- Returning to a visited tab renders what is held; it does not re-read.
  panel.select_tab('cloudflare')
  panel.select_tab('github')
  equal(git_capability_reads(), 1, 'cycling tabs re-read a capability')
end

local function test_git_digest_is_recomputed_in_its_own_domain()
  local err, ticket = async(function(done) git_client():get(git_ids.approve, done) end)
  assert(not err, vim.inspect(err))
  -- The stub computes ticket_sha256 with the broker's own canonicalJson and the
  -- git domain separator; this proves the Lua encoder agrees over a live payload.
  local verified, reason = canonical.verify(ticket, github_source.digest_prefix)
  equal(verified, true, 'git digest recomputation disagreed: ' .. tostring(reason))

  -- And that the domains are genuinely separate on the wire, not only in the
  -- unit vectors: the same served digest must not verify as a Cloudflare one.
  equal(select(1, canonical.verify(ticket, cloudflare_source.digest_prefix)), false,
    'a git digest verified in the Cloudflare domain')
end

--- The GitHub broker diverges from its sibling in four observable places. Each
--- one is a thing a client author would otherwise carry over and get wrong.
local function test_git_broker_divergences()
  local function git_bearer()
    return { '--header', 'Authorization: Bearer ' .. GIT_CAPABILITY }
  end

  -- 1. The capabilities are not interchangeable. The Cloudflare bearer on this
  -- socket is an ordinary 401.
  local crossed = raw(vim.list_extend(bearer(), { git_endpoint .. '/tickets' }))
  equal(crossed, 401, 'the Cloudflare capability authenticated the GitHub broker')

  -- 2. An off-route request answers JSON here. The sibling has no catch-all and
  -- falls through to Express's HTML finalhandler, so a client must not assume
  -- either shape.
  local off_status, off_body = raw(vim.list_extend(git_bearer(),
    { git_endpoint .. '/nope' }))
  equal(off_status, 404)
  equal(select(2, client_module.decode_body(off_body)), 'json')
  contains(off_body, 'no such route')

  -- 3. An oversized body is 413 here and 500 on the sibling, and only one of
  -- those is definitive.
  local oversize = vim.json.encode({
    ticket_sha256 = string.rep('0', 64),
    note = string.rep('z', 40000),
  })
  local big_status, big_body = raw(vim.list_extend(git_bearer(), {
    '--request', 'POST',
    '--header', 'Content-Type: application/json',
    '--data-raw', oversize,
    git_endpoint .. '/tickets/' .. git_ids.deny .. '/deny',
  }))
  equal(big_status, 413, 'an oversized body did not answer 413')
  contains(big_body, 'request body too large')
  equal(client_module.classify(413, big_body, 'decision', github_source.http).kind,
    'body_too_large')

  -- 4. The gates and their precedence are unchanged, and that is worth proving
  -- rather than assuming: the second socket is a second implementation.
  local origin_status = raw(vim.list_extend(
    { '--header', 'Origin: http://example.invalid' },
    vim.list_extend(git_bearer(), { git_endpoint .. '/tickets' })))
  equal(origin_status, 403)
  local host_status = raw({ '--header', 'Host: 127.0.0.1:9999', git_endpoint .. '/tickets' })
  equal(host_status, 400, 'the Host gate did not take precedence over the bearer gate')
  local ct_status = raw(vim.list_extend(git_bearer(), {
    '--request', 'POST', git_endpoint .. '/tickets/' .. git_ids.deny .. '/approve',
  }))
  equal(ct_status, 415)
end

--- The property the whole `settled` distinction exists for, proved on the wire.
local function test_git_approval_is_settled_without_being_terminal()
  local before = git_stats().decision_posts
  local api = git_client()
  local _, ticket = async(function(done) api:get(git_ids.approve, done) end)

  local err, approved, info = async(function(done)
    api:decide(git_ids.approve, 'approve',
      { ticket_sha256 = ticket.ticket_sha256 }, { callback = done })
  end)
  assert(not err, vim.inspect(err))
  -- Approval unlocked a token. Nothing executed, and the ticket still has a
  -- transition left -- but the decision is answered, so it was not polled.
  equal(approved.status, 'approved')
  equal(info.polled, false, 'a settled git approval was needlessly polled')
  equal(api:is_settled('approved'), true)
  equal(api:is_terminal('approved'), false)
  equal(git_stats().decision_posts, before + 1,
    'the git decision was submitted more than once')

  -- The state machine has no way back: approved cannot be denied, and the
  -- panel must not offer it.
  local reversal = async(function(done)
    api:decide(git_ids.approve, 'deny',
      { ticket_sha256 = ticket.ticket_sha256, note = 'changed my mind' },
      { callback = done })
  end)
  equal(reversal.kind, 'state_conflict')
  equal(api:is_decidable('approved'), false)
end

local function test_git_deny_and_digest_conflicts()
  local api = git_client()
  local _, deny_ticket = async(function(done) api:get(git_ids.deny, done) end)
  local _, other = async(function(done) api:get(git_ids.future, done) end)

  -- A digest copied from another ticket on the same broker is a cross-ticket
  -- replay, and the refusal says what was not done here rather than repeating
  -- Cloudflare's sentence.
  local replay = async(function(done)
    api:decide(git_ids.deny, 'approve', { ticket_sha256 = other.ticket_sha256 },
      { callback = done })
  end)
  equal(replay.kind, 'digest_conflict')
  contains(replay.message, 'No token was minted')
  excludes(replay.message, 'Cloudflare',
    'the git broker refusal named the wrong provider')

  local err, denied = async(function(done)
    api:decide(git_ids.deny, 'deny', {
      ticket_sha256 = deny_ticket.ticket_sha256,
      note = '  three release workflows is not one reviewable change  ',
    }, { callback = done })
  end)
  assert(not err, vim.inspect(err))
  equal(denied.status, 'denied')
  equal(denied.denial_note, 'three release workflows is not one reviewable change')
  contains(require('mcp_buff.render').detail(github_source, denied),
    'three release workflows is not one reviewable change')
end

--- A decision through the panel reaches exactly one broker, and the ticket is
--- verified against that broker's own digest domain on the way.
---
--- The ticket decided here is deliberately the unrecognised-scope one. Refusing
--- to decide a scope this release cannot name would leave the operator with no
--- review surface at all for a broker newer than the panel, which is worse than
--- deciding one whose whole request record was shown and whose digest verified.
local function test_a_decision_reaches_only_its_own_broker()
  panel.select_tab('github')
  panel.refresh()
  wait_for(function() return find_line(git_ids.future) ~= nil end,
    'the Git tab did not refresh')
  local before = git_stats().decision_posts
  local cloudflare_before = stats().decision_posts

  without_prompts(function()
    focus(git_ids.future)
    panel.approve()
    wait_for(function()
      local _, current = async(function(done) git_client():get(git_ids.future, done) end)
      return current and current.status == 'approved'
    end, 'the approval did not settle')
  end)

  equal(git_stats().decision_posts, before + 1,
    'the decision was submitted more than once')
  -- The Cloudflare broker saw none of this. One panel, two sockets, and a
  -- decision only ever reaches the broker whose tab it was taken on.
  equal(stats().decision_posts, cloudflare_before,
    'a Git tab decision reached the Cloudflare broker')
end

--- The preview is a decision surface, and it decides the ticket it is showing.
---
--- Both halves matter. `a` pressed inside the float has to reach the panel at
--- all -- an unmapped key there used to start an insert into a read-only buffer
--- -- and it has to act on the payload on screen rather than on whichever row
--- the cursor was left on underneath it.
local function test_the_preview_decides_the_ticket_it_shows()
  panel.select_tab('github')
  panel.refresh()
  wait_for(function() return find_line(git_ids.preview) ~= nil end,
    'the Git tab did not refresh')
  local before = git_stats().decision_posts

  local detail_name = 'mcpbuff://github/ticket/' .. git_ids.preview
  focus(git_ids.preview)
  panel.primary()
  wait_for(function() return find_buffer(detail_name) ~= nil end,
    'the preview did not open')
  local float = vim.api.nvim_get_current_win()
  equal(vim.api.nvim_win_get_buf(float), find_buffer(detail_name),
    'the preview did not take the cursor')
  assert(vim.api.nvim_win_get_config(float).relative ~= '',
    'the ticket detail is not a float')

  -- The same navigation contract applies to the Git source. Its next
  -- non-empty category is Approved, and Shift-Tab returns to Pending without
  -- changing broker tabs or submitting either ticket.
  press('<Tab>')
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(float))
      == 'mcpbuff://github/ticket/' .. git_ids.approve
  end, 'Git preview <Tab> did not open the next ticket category')
  equal(vim.api.nvim_get_current_win(), float, 'Git preview navigation replaced the float')
  press('<S-Tab>')
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(float)) == detail_name
  end, 'Git preview <S-Tab> did not return to Pending')
  equal(git_stats().decision_posts, before,
    'Git preview category navigation submitted a decision')

  -- The row behind the float is an expired ticket, which the broker cannot
  -- decide. If the keystroke read the cursor instead of the preview, the
  -- approval below would be refused rather than submitted.
  point_at(git_ids.overdue)

  without_prompts(function()
    vim.api.nvim_feedkeys('a', 'x', false)
    wait_for(function()
      local _, current = async(function(done) git_client():get(git_ids.preview, done) end)
      return current and current.status == 'approved'
    end, 'a decided the ticket the preview was not showing')
  end)
  equal(git_stats().decision_posts, before + 1,
    'the decision taken in the preview was submitted more than once')

  -- Still one float, showing the settled ticket: a decision replaces the
  -- preview rather than stacking another window on top of it.
  equal(vim.api.nvim_get_current_win(), float,
    'the decision opened a second preview window')
  contains(table.concat(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), '\n'),
    '**Status:** approved')

  -- q closes the preview and leaves the panel behind, decided row and all.
  vim.api.nvim_feedkeys('q', 'x', false)
  assert(not vim.api.nvim_win_is_valid(float), 'q did not close the preview')
  assert(panel.win and vim.api.nvim_win_is_valid(panel.win), 'q closed the panel')
end

--- An unrecognised scope is still decidable -- refusing would leave the
--- operator with no surface at all for a scope newer than the panel -- but the
--- panel must never describe it as a scope it knows.
local function test_unrecognised_scope_is_shown_not_guessed()
  panel.select_tab('github')
  panel.refresh()
  wait_for(function() return find_line(git_ids.approve) ~= nil end,
    'the Git tab did not refresh')
  local err, ticket = async(function(done) git_client():get(git_ids.future, done) end)
  assert(not err, vim.inspect(err))
  local detail = require('mcp_buff.render').detail(github_source, ticket)
  contains(detail, 'Unrecognised scope')
  contains(detail, 'does not recognise this request shape')
  -- The extra term is on screen, not folded into the shape it nearly matched.
  contains(detail, '"branch_protection": "disable"')
  excludes(detail, 'Workflow-changing push',
    'a request with an unreviewed term was described as an ordinary push')
end

--- The preview belongs to the panel, so closing the panel takes it along.
---
--- Left behind, it would be a decidable payload floating over whatever the
--- operator moved on to, with no tab bar behind it and no list to return to.
--- The float also counts as a window, so the panel's own close arithmetic has
--- to account for it before it decides whether it is closing the last one.
local function test_closing_the_panel_takes_the_preview_with_it()
  panel.select_tab('github')
  panel.refresh()
  wait_for(function() return find_line(git_ids.granted) ~= nil end,
    'the Git tab did not refresh')
  focus(git_ids.granted)
  panel.primary()
  local detail_name = 'mcpbuff://github/ticket/' .. git_ids.granted
  wait_for(function() return find_buffer(detail_name) ~= nil end,
    'the preview did not open')
  local float = vim.api.nvim_get_current_win()

  -- Closed from the panel, not from the float, which is the case that leaves a
  -- float as the only window if the panel closes first.
  vim.api.nvim_set_current_win(panel.win)
  panel.close()
  assert(not vim.api.nvim_win_is_valid(float),
    'the preview outlived the panel it belongs to')
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    assert(vim.api.nvim_win_get_buf(window) ~= panel.buf,
      'the panel window is still open')
  end
end

--- :McpBuffPermissions is an existing command in operators' keymaps. It now
--- lands on the permissions section of a provider tab.
local function test_permissions_command_jumps_into_a_tab()
  panel.open_permissions('cloudflare')
  equal(panel.active, 'cloudflare')
  local item = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
  assert(item and item.kind == 'permission' and item.index == 1,
    'the permissions command did not land on a permission row')
  equal(item.tab.id, 'cloudflare')

  panel.open_permissions('github')
  equal(panel.active, 'github')
  local git_item = panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
  assert(git_item and git_item.kind == 'permission', 'no GitHub permission row')
  equal(git_item.tab.id, 'github')
end

local function run()
  workspace = vim.fn.tempname()
  vim.fn.mkdir(workspace, 'p')
  start_stubs()
  capability_cmd, capability_counter = install_capability_cmd('cloudflare', CAPABILITY)
  git_capability_cmd, git_capability_counter =
    install_capability_cmd('github', GIT_CAPABILITY)
  probe_capability = capability_module.new({
    cmd = (install_capability_cmd('cloudflare-probe', CAPABILITY)), ttl = 300 })
  git_probe_capability = capability_module.new({
    cmd = (install_capability_cmd('github-probe', GIT_CAPABILITY)), ttl = 300 })

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
    github = {
      endpoint = git_endpoint,
      capability_cmd = git_capability_cmd,
    },
  })
  panel.open()

  test_panel_lists_every_state()
  test_listing_prunes_past_retention()
  test_detail_renders_the_reviewable_payload()
  test_preview_navigation_stays_in_the_float()
  test_recomputed_digest_matches_the_served_one()
  test_transport_gates_and_precedence()
  test_wrong_capability_is_a_bearer_failure()
  test_only_pending_tickets_are_decidable()
  test_one_keystroke_decides_without_a_prompt()
  test_approve_returns_a_terminal_ticket()
  test_digest_and_state_conflicts_are_distinguished()
  test_deny_reads_denial_note()
  test_permissions_section_narrows_cloudflare_runtime_scope()
  test_background_refresh_never_prompts()

  test_switching_to_the_git_tab_reads_only_its_own_broker()
  test_git_digest_is_recomputed_in_its_own_domain()
  test_git_broker_divergences()
  test_git_approval_is_settled_without_being_terminal()
  test_git_deny_and_digest_conflicts()
  test_unrecognised_scope_is_shown_not_guessed()
  test_a_decision_reaches_only_its_own_broker()
  test_the_preview_decides_the_ticket_it_shows()
  test_closing_the_panel_takes_the_preview_with_it()
  test_permissions_command_jumps_into_a_tab()
end

local ok, message = xpcall(run, debug.traceback)
if panel then pcall(panel.close) end
for _, process in ipairs({ stub, git_stub }) do
  if process then
    pcall(function() process:kill(15) end)
    pcall(function() process:wait(1000) end)
  end
end
if workspace then pcall(vim.fn.delete, workspace, 'rf') end
if not ok then error(message) end

print('McpBuff stub-admin smoke test passed')
