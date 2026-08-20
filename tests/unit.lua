local client = require('mcp_buff.client')
local render = require('mcp_buff.render')

local function equal(actual, expected, message)
  assert(actual == expected, (message or 'values differ') ..
    ('\nexpected: %s\nactual:   %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function contains(text, needle, message)
  assert(text:find(needle, 1, true), message or ('expected text to contain %q'):format(needle))
end

local function test_endpoint_boundary()
  equal(client.normalize_endpoint('http://127.0.0.1:8792'), 'http://127.0.0.1:8792')
  assert(client.normalize_endpoint('http://10.77.0.1:8792') == nil,
    'non-loopback endpoint was accepted')
  assert(client.normalize_endpoint('https://127.0.0.1:8792') == nil,
    'unexpected HTTPS endpoint was accepted')
  assert(client.normalize_endpoint('http://user@127.0.0.1:8792') == nil,
    'credential-bearing endpoint was accepted')
  assert(client.normalize_endpoint('http://127.0.0.1:8792/admin') == nil,
    'path-bearing endpoint was accepted')
  assert(client.normalize_endpoint('http://127.0.0.1:70000') == nil,
    'invalid port was accepted')
end

local function test_list_rendering()
  local now = assert(render.iso_epoch('2026-08-20T18:05:00Z'))
  local output = render.list({
    {
      id = 't_20260820T170000.000Z_000000000002',
      created = '2026-08-20T17:00:00.000Z',
      status = 'executed',
      reason = 'finished fixture',
    },
    {
      id = 't_20260820T180000.000Z_000000000001',
      created = '2026-08-20T18:00:00.000Z',
      status = 'pending',
      reason = 'worker state was read immediately before submission',
    },
  }, { width = 100, now = now })
  local text = table.concat(output.lines, '\n')
  equal(output.pending, 1)
  contains(text, 'Pending  (1)')
  contains(text, '5m')
  contains(text, 'worker state was read immediately before submission')
  assert(text:find('Pending', 1, true) < text:find('Executed', 1, true),
    'pending group was not rendered first')
end

local function test_json_and_detail_rendering()
  local pretty = render.pretty_json({
    bindings = { { type = 'kv_namespace', name = 'CACHE' } },
    enabled = true,
  })
  contains(pretty, '\n  "bindings": [')
  contains(pretty, '"enabled": true')

  local ticket = {
    id = 't_20260820T180000.000Z_000000000001',
    created = '2026-08-20T18:00:00.000Z',
    expires = '2026-08-21T18:00:00.000Z',
    status = 'failed',
    reason = 'full precondition: binding was absent after a fresh read',
    requests = {
      {
        method = 'PATCH',
        path = '/zones/example-zone/dns_records/example-record',
        body = { comment = 'reviewed no-op' },
      },
    },
    results = {
      {
        index = 0,
        method = 'PATCH',
        path = '/zones/example-zone/dns_records/example-record',
        status = 409,
        ok = false,
        response = { success = false },
        error = 'stub precondition rejected',
      },
    },
  }
  local detail = render.detail(ticket)
  contains(detail, ticket.reason)
  contains(detail, 'Step 0 · FAILED · HTTP 409')
  contains(detail, '`PATCH /zones/example-zone/dns_records/example-record`')
  contains(detail, '**Error:** stub precondition rejected')

  local approval = render.approval(ticket)
  contains(approval, 'Approve and execute this stored ticket exactly as shown?')
  contains(approval, 'Step 0: PATCH /zones/example-zone/dns_records/example-record')
  contains(approval, '"comment": "reviewed no-op"')
end

local function test_curl_transport()
  local captured
  local listed
  local api = client.new({
    endpoint = 'http://127.0.0.1:8792',
    executable = function(command) return command == 'curl' end,
    schedule = function(callback) callback() end,
    spawn = function(command, opts, callback)
      captured = { command = command, opts = opts }
      local rendered = table.concat(command, ' ')
      local output = rendered:find('/deny', 1, true) and '\n200'
        or (rendered:find('/approve', 1, true) and '{}\n200' or '{"tickets":[]}\n200')
      callback({ code = 0, stdout = output, stderr = '' })
      return {}
    end,
  })
  api:list(nil, function(err, tickets)
    assert(not err, vim.inspect(err))
    listed = tickets
  end)
  equal(#listed, 0)
  equal(captured.command[2], '--disable')
  assert(not vim.tbl_contains(captured.command, '--location'), 'curl follows redirects')
  contains(table.concat(captured.command, ' '), 'http://127.0.0.1:8792/tickets')

  api:approve('t_20260820T180000.000Z_000000000001', function(err)
    assert(not err, vim.inspect(err))
  end)
  assert(captured.opts.stdin == nil, 'approval unexpectedly sent a request body')
  assert(not vim.tbl_contains(captured.command, '--data-binary'),
    'approval command accepts replacement request data')

  local denied
  api:deny('t_20260820T180000.000Z_000000000001', 'state changed', function(err, ticket)
    assert(not err, vim.inspect(err))
    denied = ticket
  end)
  captured.opts = captured.opts or {}
  contains(captured.opts.stdin, 'state changed')
  assert(not table.concat(captured.command, ' '):find('state changed', 1, true),
    'denial note leaked into curl argv')
  assert(denied == nil, 'empty successful response should decode to nil')
end

test_endpoint_boundary()
test_list_rendering()
test_json_and_detail_rendering()
test_curl_transport()

print('McpBuff unit tests passed')
