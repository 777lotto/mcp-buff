local canonical = require('mcp_buff.canonical')
local capability = require('mcp_buff.capability')
local client = require('mcp_buff.client')
local render = require('mcp_buff.render')
local tunnel = require('mcp_buff.tunnel')

local function equal(actual, expected, message)
  assert(actual == expected, (message or 'values differ') ..
    ('\nexpected: %s\nactual:   %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function contains(text, needle, message)
  assert(text:find(needle, 1, true), message or ('expected text to contain %q'):format(needle))
end

local function excludes(text, needle, message)
  assert(not text:find(needle, 1, true), message or ('expected text to omit %q'):format(needle))
end

local function settle(predicate, message)
  assert(vim.wait(2000, predicate, 5), message or 'operation did not settle')
end

local function test_tunnel_configuration_and_argv()
  equal(tunnel.normalize(false, 'http://127.0.0.1:8792'), nil)

  local config = assert(tunnel.normalize({
    host = 'zemrip-server',
  }, 'http://127.0.0.1:8792'))
  equal(config.host, 'zemrip-server')
  equal(config.port, 8792)
  equal(config.startup_timeout, tunnel.DEFAULT_STARTUP_TIMEOUT_MS)

  local argv = tunnel.argv(config)
  local command = table.concat(argv, ' ')
  equal(argv[1], 'ssh')
  equal(argv[#argv], 'zemrip-server')
  contains(command, '-L 127.0.0.1:8792:127.0.0.1:8792')
  contains(command, 'BatchMode=yes')
  contains(command, 'ExitOnForwardFailure=yes')
  contains(command, 'ControlMaster=no')
  contains(command, 'ControlPath=none')
  excludes(command, '0.0.0.0', 'the managed listener was exposed beyond loopback')
  excludes(command, ' -g', 'ssh gateway forwarding was enabled')

  assert(select(2, tunnel.normalize({ host = '-oProxyCommand=bad' },
    'http://127.0.0.1:8792')) ~= nil, 'an ssh option was accepted as a host')
  assert(select(2, tunnel.normalize({ host = 'host with spaces' },
    'http://127.0.0.1:8792')) ~= nil, 'a command fragment was accepted as a host')
  assert(select(2, tunnel.normalize({ host = 'safe', extra = true },
    'http://127.0.0.1:8792')) ~= nil, 'an unknown tunnel option was ignored')
  assert(select(2, tunnel.normalize({ host = 'safe', startup_timeout = 999 },
    'http://127.0.0.1:8792')) ~= nil, 'an unsafe startup timeout was accepted')
end

local function tunnel_harness(probe_results, overrides)
  local record = {
    probes = 0,
    spawns = {},
    deferred = {},
    kills = {},
    exit_callback = nil,
    unexpected = nil,
  }
  local probe_index = 0
  local function probe(port, callback)
    record.probes = record.probes + 1
    equal(port, 8792)
    probe_index = probe_index + 1
    local result = probe_results[probe_index]
    if result == nil then result = probe_results[#probe_results] end
    if type(result) == 'table' then
      callback(result.listening, result.error)
    else
      callback(result)
    end
  end
  local function spawn(command, opts, callback)
    local job = {
      kill = function(_, signal)
        record.kills[#record.kills + 1] = signal
      end,
    }
    record.spawns[#record.spawns + 1] = {
      command = command,
      opts = opts,
      job = job,
    }
    record.exit_callback = callback
    return job
  end

  local config = assert(tunnel.normalize({
    host = 'zemrip-server',
    startup_timeout = overrides and overrides.startup_timeout or 30000,
  }, 'http://127.0.0.1:8792'))
  local manager = tunnel.new(config, {
    probe = probe,
    spawn = spawn,
    executable = overrides and overrides.executable or function() return true end,
    schedule = function(callback) callback() end,
    defer = function(callback, ms)
      record.deferred[#record.deferred + 1] = { callback = callback, ms = ms }
    end,
    on_exit = function(err) record.unexpected = err end,
  })
  record.run_next = function()
    local deferred = table.remove(record.deferred, 1)
    assert(deferred, 'no deferred tunnel callback is available')
    deferred.callback()
  end
  return manager, record
end

local function test_tunnel_owned_lifecycle()
  local manager, record = tunnel_harness({ false, true })
  local callbacks = {}
  manager:ensure(function(err) callbacks[#callbacks + 1] = err or true end)
  manager:ensure(function(err) callbacks[#callbacks + 1] = err or true end)
  equal(#record.spawns, 1, 'concurrent ensure calls spawned more than one ssh process')
  equal(#callbacks, 0, 'the tunnel was reported ready before its listener opened')
  equal(record.spawns[1].opts.text, true)

  record.run_next()
  equal(#callbacks, 2)
  equal(callbacks[1], true)
  assert(manager:is_ready())

  manager:ensure(function(err) callbacks[#callbacks + 1] = err or true end)
  equal(#record.spawns, 1)
  equal(#callbacks, 3)

  manager:stop()
  equal(record.kills[1], 15, 'the owned ssh process was not terminated with SIGTERM')
  assert(not manager:is_ready())
  -- A late exit callback from the process just stopped is expected and silent.
  record.exit_callback({ code = 143, signal = 15, stderr = '' })
  equal(record.unexpected, nil)
end

local function test_tunnel_refuses_unowned_listener()
  local manager, record = tunnel_harness({ true })
  local failure
  manager:ensure(function(err) failure = err end)
  equal(failure.kind, 'tunnel')
  contains(failure.message, 'already has a listener')
  contains(failure.message, 'does not own')
  equal(#record.spawns, 0, 'ssh was launched despite an occupied local port')
  equal(#record.kills, 0, 'an unowned listener was terminated')
end

local function test_tunnel_failures_are_bounded()
  local early, early_record = tunnel_harness({ false })
  local early_failure
  early:ensure(function(err) early_failure = err end)
  early_record.exit_callback({
    code = 255,
    stderr = 'ssh: connect to host 10.24.0.1 port 22: Network is unreachable\n',
  })
  equal(early_failure.kind, 'tunnel')
  contains(early_failure.message, 'Network is unreachable')
  assert(not early:is_ready())

  local timed, timed_record = tunnel_harness({ false }, { startup_timeout = 1000 })
  local timeout_failure
  timed:ensure(function(err) timeout_failure = err end)
  local iterations = 0
  while not timeout_failure and #timed_record.deferred > 0 do
    timed_record.run_next()
    iterations = iterations + 1
    assert(iterations < 30, 'managed tunnel startup did not honor its timeout')
  end
  equal(timeout_failure.kind, 'tunnel')
  contains(timeout_failure.message, 'within 1000 ms')
  equal(timed_record.kills[1], 15, 'timed-out ssh process was left running')

  local missing, missing_record = tunnel_harness({ false }, {
    executable = function() return false end,
  })
  local missing_failure
  missing:ensure(function(err) missing_failure = err end)
  contains(missing_failure.message, 'SSH executable is not available')
  equal(missing_record.probes, 0)
  equal(#missing_record.spawns, 0)
end

local function test_tunnel_unexpected_exit_is_reported()
  local manager, record = tunnel_harness({ false, true })
  manager:ensure(function(err) assert(not err, vim.inspect(err)) end)
  record.run_next()
  record.exit_callback({ code = 255, stderr = 'client_loop: send disconnect: Broken pipe\n' })
  equal(record.unexpected.kind, 'tunnel')
  contains(record.unexpected.message, 'closed unexpectedly')
  contains(record.unexpected.message, 'Broken pipe')
  assert(not manager:is_ready())
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

local function test_ticket_id_boundary()
  assert(client.valid_ticket_id('t_20260821T120000.000Z_0123456789ab'))
  assert(not client.valid_ticket_id('t_20260821T120000.000Z_0123456789'),
    'a short ticket suffix was accepted')
  assert(not client.valid_ticket_id('t_20260821T120000.000Z_0123456789abc'),
    'a long ticket suffix was accepted')
  assert(not client.valid_ticket_id('t_20260821T120000.000Z_0123456789aG'),
    'a non-hex ticket suffix was accepted')
  assert(not client.valid_ticket_id('../etc/passwd'), 'a traversal id was accepted')
end

-- The two vectors below are copied verbatim from the broker's own
-- tests/canonical.test.ts. If mcp-buff and the broker ever disagree about
-- canonical JSON, these fail before anything can be submitted.
local BROKER_TICKET_VECTOR = {
  id = 't_20260821T120000.000Z_0123456789ab',
  created = '2026-08-21T12:00:00.000Z',
  expires = '2026-08-21T12:15:00.000Z',
  reason = 'reviewed fixture',
  requests = {
    {
      method = 'DELETE',
      path = '/zones/0123456789abcdef0123456789abcdef/dns_records/abcdefabcdefabcdefabcdefabcdefab',
      precondition = {
        method = 'GET',
        path = '/zones/0123456789abcdef0123456789abcdef/dns_records/abcdefabcdefabcdefabcdefabcdefab',
        expect = {
          status = 200,
          result_sha256 = string.rep('0', 64),
        },
      },
    },
  },
}

local BROKER_CANONICAL_VECTOR =
  'zemrip.mcp-ticket.v1\n{"created":"2026-08-21T12:00:00.000Z",'
  .. '"expires":"2026-08-21T12:15:00.000Z","id":"t_20260821T120000.000Z_0123456789ab",'
  .. '"reason":"reviewed fixture","requests":[{"method":"DELETE",'
  .. '"path":"/zones/0123456789abcdef0123456789abcdef/dns_records/abcdefabcdefabcdefabcdefabcdefab",'
  .. '"precondition":{"expect":{"result_sha256":'
  .. '"0000000000000000000000000000000000000000000000000000000000000000","status":200},'
  .. '"method":"GET",'
  .. '"path":"/zones/0123456789abcdef0123456789abcdef/dns_records/abcdefabcdefabcdefabcdefabcdefab"}}]}'

local BROKER_DIGEST_VECTOR =
  '5961f70b919841fd796c667e73c148a9894e29d4361d9b905f185f27e51ba84c'

local function test_canonical_broker_vectors()
  -- "sorts object keys recursively without reordering arrays"
  equal(canonical.encode(vim.json.decode('{"z":1,"a":{"y":true,"x":null},"b":[3,2,1]}')),
    '{"a":{"x":null,"y":true},"b":[3,2,1],"z":1}')

  equal(canonical.ticket_preimage(BROKER_TICKET_VECTOR), BROKER_CANONICAL_VECTOR)
  equal(canonical.ticket_digest(BROKER_TICKET_VECTOR), BROKER_DIGEST_VECTOR)
  equal(select(1, canonical.verify(vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = BROKER_DIGEST_VECTOR,
  }))), true)
end

local function test_canonical_encoding_rules()
  -- vim.json.decode is the only thing that can tell {} from [] once the value
  -- is a Lua table, so the distinction has to survive a real decode.
  equal(canonical.encode(vim.json.decode('{"a":{},"b":[]}')), '{"a":{},"b":[]}')
  equal(canonical.encode(vim.json.decode('[]')), '[]')
  equal(canonical.encode(vim.json.decode('{}')), '{}')

  -- JSON.stringify escaping: seven short escapes, other C0 as \u00xx, UTF-8
  -- and the forward slash left alone.
  equal(canonical.encode('a"b\\c\nd\te\r\bf\ff'), '"a\\"b\\\\c\\nd\\te\\r\\bf\\ff"')
  equal(canonical.encode('\1\31'), '"\\u0001\\u001f"')
  equal(canonical.encode('a/b'), '"a/b"')
  equal(canonical.encode('h\195\169llo'), '"h\195\169llo"')

  equal(canonical.encode(vim.json.decode('{"n":0}')), '{"n":0}')
  equal(canonical.encode(vim.json.decode('{"n":-7}')), '{"n":-7}')
  equal(canonical.encode(true), 'true')
  equal(canonical.encode(vim.NIL), 'null')

  -- Keys sort by byte, which only provably matches JavaScript for ASCII.
  equal(canonical.encode(vim.json.decode('{"b":1,"A":2,"a":3}')), '{"A":2,"a":3,"b":1}')
end

local function test_canonical_fail_safe()
  -- Anything this encoder cannot prove matches JSON.stringify is a refusal, not
  -- a guess. A guessed digest would let the operator approve a payload they did
  -- not actually verify.
  equal(canonical.encode(vim.json.decode('{"ttl":1.5}')), nil,
    'a non-integer number was canonicalised')
  equal(canonical.encode(vim.json.decode('{"n":1e300}')), nil,
    'an unsafe integer was canonicalised')
  equal(canonical.encode(vim.json.decode('{"k\195\169y":1}')), nil,
    'a non-ASCII key was canonicalised')

  local drifted = vim.deepcopy(BROKER_TICKET_VECTOR)
  drifted.requests[1].body = vim.json.decode('{"ttl":1.5}')
  drifted.ticket_sha256 = BROKER_DIGEST_VECTOR
  local ok, reason = canonical.verify(drifted)
  equal(ok, false, 'an uncanonicalisable ticket was accepted')
  contains(reason, 'cannot canonicalise')

  local tampered = vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = string.rep('a', 64),
  })
  local mismatched, mismatch_reason = canonical.verify(tampered)
  equal(mismatched, false, 'a mismatched digest was accepted')
  contains(mismatch_reason, 'do not approve this ticket')

  equal(select(1, canonical.verify({ ticket_sha256 = 'nope' })), false)
  equal(select(1, canonical.verify(vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = BROKER_DIGEST_VECTOR:upper(),
  }))), false, 'an uppercase digest was accepted')
end

local function test_gate_classification()
  -- Each gate has a distinct status and a client must not collapse them.
  local origin = client.classify(403, '{"error":"origin not allowed"}')
  equal(origin.kind, 'gate_origin')
  equal(origin.definitive, true)

  local host = client.classify(400, '{"error":"invalid host"}', 'decision')
  equal(host.kind, 'gate_host')
  equal(host.retryable, false)
  contains(host.message, 'do not resubmit')

  local bearer = client.classify(401, '{"error":"unauthorized"}')
  equal(bearer.kind, 'gate_bearer')

  local content_type = client.classify(415, '{"error":"application/json required"}')
  equal(content_type.kind, 'gate_content_type')

  -- A schema 400 and a host 400 share a status and must not share a meaning.
  local schema = client.classify(400,
    '{"error":"invalid request","issues":[{"code":"invalid_type"}]}', 'decision')
  equal(schema.kind, 'schema')
  local bad_json = client.classify(400, '{"error":"invalid JSON body"}', 'decision')
  equal(bad_json.kind, 'invalid_json')
end

local function test_conflict_and_error_body_decoding()
  -- Status alone cannot separate the two 409s; only the message text can.
  local digest_conflict = client.classify(409,
    '{"error":"ticket t_1 digest does not match the reviewed immutable payload"}')
  equal(digest_conflict.kind, 'digest_conflict')
  local state_conflict = client.classify(409,
    '{"error":"ticket t_1 cannot transition from expired to approved"}')
  equal(state_conflict.kind, 'state_conflict')
  contains(state_conflict.message, 'while you were reviewing')

  -- An off-route request comes back as HTML, not JSON.
  local html = '<!DOCTYPE html>\n<html><body><pre>Cannot GET /nope</pre></body></html>'
  equal(select(2, client.decode_body(html)), 'html')
  local off_route = client.classify(418, html)
  contains(off_route.message, 'route it does not serve')

  -- A 500 on a decision may be nothing worse than an oversized note, so the
  -- outcome is not known from the status alone.
  local server_error = client.classify(500, '{"error":"internal server error"}', 'decision')
  equal(server_error.kind, 'server')
  equal(server_error.definitive, false)
  contains(server_error.message, 'oversized')

  local not_found = client.classify(404, '{"error":"ticket not found: t_1"}')
  equal(not_found.kind, 'not_found')
  contains(not_found.message, 'retention window')
end

local function test_indeterminate_is_its_own_state()
  assert(vim.tbl_contains(render.status_order, 'indeterminate'),
    'indeterminate is missing from the render order')
  local output = render.list({
    {
      id = 't_20260820T170000.000Z_00000000000a',
      created = '2026-08-20T17:00:00.000Z',
      status = 'indeterminate',
      reason = 'restart recovery left this outcome unknown',
    },
  }, { width = 100, now = render.iso_epoch('2026-08-20T18:05:00Z') })
  local text = table.concat(output.lines, '\n')
  contains(text, 'Indeterminate  (1)')
  contains(text, 'Failed  (0)', 'indeterminate was bucketed into failed')
  assert(text:find('Indeterminate', 1, true) < text:find('Failed', 1, true),
    'indeterminate did not sort ahead of failed')
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

local DETAIL_TICKET = {
  ticket_version = 1,
  id = 't_20260820T180000.000Z_000000000001',
  created = '2026-08-20T18:00:00.000Z',
  expires = '2026-08-21T18:00:00.000Z',
  status = 'indeterminate',
  ticket_sha256 = string.rep('9', 56) .. 'a41b7e3d',
  reason = 'full precondition: binding was absent after a fresh read',
  requests = {
    {
      method = 'PATCH',
      path = '/zones/example-zone/dns_records/example-record',
      body = { comment = 'reviewed no-op' },
      precondition = {
        method = 'GET',
        path = '/zones/example-zone/dns_records/example-record',
        expect = { status = 200, result_sha256 = string.rep('c', 64) },
      },
    },
  },
  preflight_results = {
    {
      index = 0,
      phase = 'immediate',
      checked = '2026-08-20T18:04:00.000Z',
      matched = false,
      expected_status = 200,
      observed_status = 404,
      error_id = 'precondition.target-absent',
    },
  },
  results = {
    {
      index = 0,
      method = 'PATCH',
      path = '/zones/example-zone/dns_records/example-record',
      ok = false,
      outcome = 'indeterminate',
      response = vim.NIL,
      error = 'no authoritative response was read',
    },
  },
  denial_note = 'superseded by a fresh ticket',
}

local function test_detail_rendering()
  local detail = render.detail(DETAIL_TICKET)
  contains(detail, DETAIL_TICKET.reason)
  -- expires must be rendered before any decision: a ticket can expire between
  -- the read and the POST.
  contains(detail, '**Expires:** 2026-08-21T18:00:00.000Z')
  -- The full digest, not an abbreviation.
  contains(detail, DETAIL_TICKET.ticket_sha256)
  contains(detail, '`PATCH /zones/example-zone/dns_records/example-record`')
  contains(detail, '"comment": "reviewed no-op"')
  -- The structured precondition is inside the digest, so it is part of the
  -- review.
  contains(detail, '**Precondition:** `GET /zones/example-zone/dns_records/example-record`')
  contains(detail, '**Expected status:** 200')
  contains(detail, '**Expected result_sha256:** ' .. string.rep('c', 64))
  contains(detail, '## Preflight observations')
  contains(detail, 'Step 0 · immediate · DID NOT MATCH')
  contains(detail, 'expected 200, observed 404')
  contains(detail, '**Error id:** precondition.target-absent')
  -- The broker's own word for the outcome, not a derived ok/FAILED.
  contains(detail, 'Step 0 · indeterminate · no HTTP response')
  contains(detail, 'must never be replayed')
  -- The denial reason comes back as denial_note, not note.
  contains(detail, 'superseded by a fresh ticket')
end

local function test_typed_confirmation()
  equal(render.digest_suffix(DETAIL_TICKET), 'a41b7e3d')
  local prompt = render.confirm_prompt(DETAIL_TICKET, 'approve')
  contains(prompt, 'ticket_sha256: ' .. DETAIL_TICKET.ticket_sha256)
  contains(prompt, 'Type the final digest bytes a41b7e3d to approve: ')
  -- A yes/no prompt does not satisfy the contract, so no affirmative default
  -- may appear anywhere in the confirmation surface.
  excludes(prompt, '&Approve')
  excludes(prompt, '(y/n)')
end

local function test_decision_timeout_bounds()
  equal(client.clamp_decision_seconds(nil, 1865), 1865)
  equal(client.clamp_decision_seconds(10, 1865), 65, 'a short decision budget was accepted')
  equal(client.clamp_decision_seconds(999999, 1865), 86400)
  equal(client.clamp_decision_seconds(120, 1865), 120)
end

-- A scriptable curl stand-in. Each call records the argv and stdin it was given
-- and replies with whatever the current script says.
local function recorder(responder)
  local calls = {}
  local fake = {
    calls = calls,
    spawn = function(command, opts, callback)
      local call = {
        command = command,
        argv = table.concat(command, ' '),
        stdin = opts.stdin,
        timeout = opts.timeout,
      }
      calls[#calls + 1] = call
      callback(responder(call, #calls))
      return {}
    end,
  }
  return fake
end

local FAKE_CAPABILITY = string.rep('ab', 32)

local function fake_capability(log)
  return {
    get = function(opts, callback)
      log[#log + 1] = opts or {}
      callback(nil, FAKE_CAPABILITY)
    end,
    clear = function() end,
  }
end

local function new_client(fake, capability_stub, overrides)
  return client.new(vim.tbl_extend('force', {
    endpoint = 'http://127.0.0.1:8792',
    executable = function(command) return command == 'curl' end,
    schedule = function(callback) callback() end,
    defer = function(callback) callback() end,
    spawn = fake.spawn,
    capability = capability_stub,
  }, overrides or {}))
end

local function test_capability_never_reaches_argv()
  local fake = recorder(function() return { code = 0, stdout = '{"tickets":[]}\n200', stderr = '' } end)
  local log = {}
  local api = new_client(fake, fake_capability(log))

  local listed
  api:list(nil, function(err, tickets)
    assert(not err, vim.inspect(err))
    listed = tickets
  end)
  equal(#listed, 0)

  local call = fake.calls[1]
  -- The capability is the only secret, so it travels on the private channel.
  contains(call.stdin, 'header = "Authorization: Bearer ' .. FAKE_CAPABILITY .. '"')
  excludes(call.argv, FAKE_CAPABILITY, 'the capability leaked into curl argv')
  contains(call.argv, '--config -')
  contains(call.argv, '--disable')
  contains(call.argv, '--noproxy *')
  contains(call.argv, '--max-redirs 0')
  contains(call.argv, '--proto =http')
  excludes(call.argv, '--location', 'curl follows redirects')
  -- A browser can never be a client, because browsers always attach Origin.
  -- Sending one is an unconditional 403 at the first gate.
  excludes(call.argv, 'Origin', 'the client sent an Origin header')
  contains(call.argv, 'http://127.0.0.1:8792/tickets')
end

local function test_every_post_carries_a_content_type()
  local fake = recorder(function(call)
    if call.argv:find('/approve', 1, true) then
      return { code = 0, stdout = '{"id":"x","status":"executed"}\n200', stderr = '' }
    end
    return { code = 0, stdout = '{"tickets":[]}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}))

  local digest = string.rep('7', 64)
  api:decide('t_20260820T180000.000Z_000000000001', 'approve', { ticket_sha256 = digest }, {
    callback = function(err) assert(not err, vim.inspect(err)) end,
  })

  local call = fake.calls[1]
  -- A bodyless approve is refused at the 415 gate, never at the schema, so the
  -- header and the body must both be present on approve as well as deny.
  contains(call.argv, 'Content-Type: application/json')
  contains(call.argv, '--data-raw {"ticket_sha256":"' .. digest .. '"}')
  -- --data-raw, not --data-binary: a body starting with @ must never be read
  -- as a filename.
  excludes(call.argv, '--data-binary')
  -- The decision body is not secret, but the capability still is.
  excludes(call.argv, FAKE_CAPABILITY)
  -- The decision POST is sized against the synchronous execution budget, not
  -- against a conventional HTTP timeout.
  contains(call.argv, '--max-time 1865')
end

local function test_reads_and_decisions_keep_separate_budgets()
  local fake = recorder(function(call)
    if call.argv:find('/deny', 1, true) then
      return { code = 0, stdout = '{"id":"x","status":"denied"}\n200', stderr = '' }
    end
    return { code = 0, stdout = '{"id":"x","status":"pending"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}), { timeout = 30000, decision_timeout = 900 })

  api:get('t_20260820T180000.000Z_000000000001', function() end)
  -- A read performs no execution: a read that hangs for half an hour is a
  -- broken tunnel, not a long approval.
  contains(fake.calls[1].argv, '--max-time 30')

  api:decide('t_20260820T180000.000Z_000000000001', 'deny',
    { ticket_sha256 = string.rep('7', 64), note = '  spaced  ' }, {
      callback = function(err) assert(not err, vim.inspect(err)) end,
    })
  contains(fake.calls[2].argv, '--max-time 900')
  contains(fake.calls[2].argv, '"note":"spaced"')
end

local function test_deny_sends_nothing_the_schema_forbids()
  local fake = recorder(function()
    return { code = 0, stdout = '{"id":"x","status":"denied"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}))
  api:decide('t_20260820T180000.000Z_000000000001', 'deny',
    { ticket_sha256 = string.rep('7', 64) }, {
      callback = function(err) assert(not err, vim.inspect(err)) end,
    })
  -- An absent note must be absent, not an empty string the strict schema
  -- rejects.
  excludes(fake.calls[1].argv, '"note"')

  local refused
  api:decide('t_20260820T180000.000Z_000000000001', 'deny',
    { ticket_sha256 = string.rep('7', 64), note = string.rep('x', 4001) }, {
      callback = function(err) refused = err end,
    })
  equal(refused.kind, 'configuration')
  equal(#fake.calls, 1, 'an over-long note was sent to the broker')

  local no_digest
  api:decide('t_20260820T180000.000Z_000000000001', 'approve', {}, {
    callback = function(err) no_digest = err end,
  })
  equal(no_digest.kind, 'configuration')
  equal(#fake.calls, 1, 'a decision was sent without a digest')
end

local function test_failed_capability_fetch_aborts_the_request()
  local fake = recorder(function()
    return { code = 0, stdout = '{"tickets":[]}\n200', stderr = '' }
  end)
  -- The dangerous failure is a fetch that fails quietly: the request then goes
  -- out unauthenticated and the operator sees an opaque 401 instead of the real
  -- cause.
  local api = new_client(fake, {
    get = function(_, callback)
      callback({ kind = 'capability', message = 'the card is not available' })
    end,
    clear = function() end,
  })

  local failure
  api:list(nil, function(err) failure = err end)
  equal(failure.kind, 'capability')
  contains(failure.message, 'card is not available')
  equal(#fake.calls, 0, 'a request was sent without a capability')
end

local function test_one_forced_refetch_after_401()
  local fake = recorder(function()
    return { code = 0, stdout = '{"error":"unauthorized"}\n401', stderr = '' }
  end)
  local log = {}
  local api = new_client(fake, fake_capability(log))

  local failure
  api:list(nil, function(err) failure = err end)
  -- One refetch covers a capability rotated mid-session; after that the failure
  -- is surfaced rather than retried forever.
  equal(#fake.calls, 2, 'the 401 was not retried exactly once')
  equal(log[2].force, true, 'the retry did not force a fresh capability read')
  equal(failure.kind, 'gate_bearer')
end

local function test_a_decision_is_never_resubmitted()
  local posts, gets = 0, 0
  local fake = recorder(function(call)
    if call.argv:find('/approve', 1, true) then
      posts = posts + 1
      -- curl exit 28: the transfer timed out. The broker may well still be
      -- executing.
      return { code = 28, stdout = '', stderr = 'curl: (28) Operation timed out' }
    end
    gets = gets + 1
    if gets < 3 then
      return { code = 0, stdout = '{"id":"t_1","status":"executing"}\n200', stderr = '' }
    end
    return { code = 0, stdout = '{"id":"t_1","status":"executed"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}))

  local outcome, resolved
  api:decide('t_20260820T180000.000Z_000000000001', 'approve',
    { ticket_sha256 = string.rep('7', 64) }, {
      callback = function(err, ticket, info)
        assert(not err, vim.inspect(err))
        outcome, resolved = ticket, info
      end,
    })

  -- A resubmit costs the account of what happened; it does not execute twice.
  -- The outcome is resolved by polling the same ticket.
  equal(posts, 1, 'the decision was resubmitted')
  equal(outcome.status, 'executed')
  equal(resolved.polled, true)
  equal(resolved.outcome, 'terminal')
end

local function test_definitive_refusals_are_not_polled()
  local posts, gets = 0, 0
  local fake = recorder(function(call)
    if call.argv:find('/approve', 1, true) then
      posts = posts + 1
      return {
        code = 0,
        stdout = '{"error":"ticket t_1 cannot transition from expired to approved"}\n409',
        stderr = '',
      }
    end
    gets = gets + 1
    return { code = 0, stdout = '{"id":"t_1","status":"expired"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}))

  local failure
  api:decide('t_20260820T180000.000Z_000000000001', 'approve',
    { ticket_sha256 = string.rep('7', 64) }, {
      callback = function(err) failure = err end,
    })
  -- The broker refused before touching the ticket, so there is nothing to poll
  -- for: reporting it directly is the whole account of what happened.
  equal(failure.kind, 'state_conflict')
  equal(posts, 1)
  equal(gets, 0, 'a definitive refusal was polled')
end

local function test_poll_deadline_reports_unknown_and_stops()
  local fake = recorder(function(call)
    if call.argv:find('/approve', 1, true) then
      return { code = 28, stdout = '', stderr = 'timed out' }
    end
    return { code = 0, stdout = '{"id":"t_1","status":"executing"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}), { poll_deadline = 65 })

  local failure
  api:decide('t_20260820T180000.000Z_000000000001', 'approve',
    { ticket_sha256 = string.rep('7', 64) }, {
      callback = function(err) failure = err end,
    })
  equal(failure.kind, 'unknown_outcome')
  contains(failure.message, 'never resubmit')
end

local function test_capability_cache_and_prompt_containment()
  local runs = 0
  capability.configure({
    cmd = { 'fake-capability' },
    ttl = 300,
    spawn = function(_, _, callback)
      runs = runs + 1
      callback({ code = 0, stdout = FAKE_CAPABILITY .. '\n', stderr = '' })
      return {}
    end,
  })

  local first
  capability.get({}, function(err, value)
    assert(not err, vim.inspect(err))
    first = value
  end)
  settle(function() return first ~= nil end, 'the capability fetch did not settle')
  equal(first, FAKE_CAPABILITY)
  equal(runs, 1)

  -- One decryption per operator decision, reused for every request that
  -- decision makes: a poll every 2s must not become hundreds of card reads.
  local second
  capability.get({}, function(_, value) second = value end)
  settle(function() return second ~= nil end)
  equal(runs, 1, 'the cached capability was re-read')

  -- A background refresh may never raise a credential prompt.
  capability.clear()
  local blocked
  capability.get({ allow_fetch = false }, function(err) blocked = err end)
  settle(function() return blocked ~= nil end)
  equal(blocked.cold, true)
  equal(runs, 1, 'a background tick ran capability_cmd')

  -- A failed fetch is an error, never a silently unauthenticated request.
  capability.configure({
    cmd = { 'fake-capability' },
    spawn = function(_, _, callback)
      callback({ code = 2, stdout = '', stderr = 'card not present' })
      return {}
    end,
  })
  local failure
  capability.get({}, function(err) failure = err end)
  settle(function() return failure ~= nil end)
  contains(failure.message, 'card not present')

  -- A command that prints something other than a capability is refused, and its
  -- stdout is never quoted back.
  capability.configure({
    cmd = { 'fake-capability' },
    spawn = function(_, _, callback)
      callback({ code = 0, stdout = 'gpg: decryption failed\n', stderr = '' })
      return {}
    end,
  })
  local malformed
  capability.get({}, function(err) malformed = err end)
  settle(function() return malformed ~= nil end)
  contains(malformed.message, '64 lowercase hex')
  excludes(malformed.message, 'decryption failed')

  capability.configure({})
  local unconfigured
  capability.get({}, function(err) unconfigured = err end)
  equal(unconfigured.kind, 'capability')
  contains(unconfigured.message, 'capability_cmd')

  assert(select(2, capability.normalize_cmd('pass show x')) ~= nil,
    'a string capability_cmd was accepted')
  assert(select(2, capability.normalize_cmd({})) ~= nil,
    'an empty capability_cmd was accepted')
  equal(select(1, capability.normalize_cmd({ 'pass', 'show', 'x' }))[2], 'show')
end

local function test_provider_capabilities_are_isolated()
  local first_runs, second_runs = 0, 0
  local first = capability.new({
    cmd = { 'first-capability' },
    ttl = 300,
    spawn = function(_, _, callback)
      first_runs = first_runs + 1
      callback({ code = 0, stdout = string.rep('1a', 32) .. '\n', stderr = '' })
      return {}
    end,
  })
  local second = capability.new({
    cmd = { 'second-capability' },
    ttl = 300,
    spawn = function(_, _, callback)
      second_runs = second_runs + 1
      callback({ code = 0, stdout = string.rep('2b', 32) .. '\n', stderr = '' })
      return {}
    end,
  })

  local first_value, second_value
  first.get({}, function(err, value)
    assert(not err, vim.inspect(err))
    first_value = value
  end)
  second.get({}, function(err, value)
    assert(not err, vim.inspect(err))
    second_value = value
  end)
  settle(function() return first_value ~= nil and second_value ~= nil end)
  excludes(first_value, second_value, 'two providers shared one capability value')
  equal(first_runs, 1)
  equal(second_runs, 1)

  first.clear()
  assert(second.cached(), 'clearing one provider cleared the other provider cache')
  second.get({}, function() end)
  equal(second_runs, 1, 'the other provider capability was re-read')
end

local function permission_snapshot(provider)
  return {
    provider = provider,
    permissions_sha256 = string.rep('7', 64),
    permissions = {
      {
        id = provider .. '.read',
        title = 'Read',
        description = 'Read through the broker.',
        enabled = true,
        ceiling = true,
      },
      {
        id = provider .. '.write',
        title = 'Write',
        description = 'Write through the broker.',
        enabled = false,
        ceiling = true,
      },
    },
  }
end

local function test_permissions_contract_and_provider_binding()
  local current = permission_snapshot('github')
  local fake = recorder(function(call)
    if call.argv:find('--request POST', 1, true) then
      local updated = vim.deepcopy(current)
      updated.permissions_sha256 = string.rep('8', 64)
      updated.permissions[1].enabled = false
      return { code = 0, stdout = vim.json.encode(updated) .. '\n200', stderr = '' }
    end
    return { code = 0, stdout = vim.json.encode(current) .. '\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}), { permission_provider = 'github' })

  local fetched
  api:get_permissions(function(err, snapshot)
    assert(not err, vim.inspect(err))
    fetched = snapshot
  end)
  equal(fetched.provider, 'github')
  contains(fake.calls[1].argv, 'http://127.0.0.1:8792/permissions')

  local updated
  api:update_permissions(fetched, {}, function(err, snapshot)
    assert(not err, vim.inspect(err))
    updated = snapshot
  end)
  equal(updated.permissions_sha256, string.rep('8', 64))
  local body = fake.calls[2].command[vim.tbl_contains(fake.calls[2].command, '--data-raw')
      and vim.fn.index(fake.calls[2].command, '--data-raw') + 2 or 0]
  local decoded = vim.json.decode(body)
  equal(decoded.permissions_sha256, string.rep('7', 64))
  equal(#decoded.enabled, 0)
  equal(vim.tbl_count(decoded), 2, 'the strict update body gained an extra field')

  local wrong = permission_snapshot('cloudflare')
  local mismatch
  api:update_permissions(wrong, {}, function(err) mismatch = err end)
  equal(mismatch.kind, 'configuration')
  equal(#fake.calls, 2, 'a snapshot from another provider reached the broker')

  local duplicate
  api:update_permissions(fetched, { 'github.read', 'github.read' }, function(err)
    duplicate = err
  end)
  equal(duplicate.kind, 'configuration')
  equal(#fake.calls, 2, 'duplicate enabled permissions reached the broker')
end

local function test_permissions_conflict_is_definitive()
  local fake = recorder(function()
    return {
      code = 0,
      stdout = '{"error":"permissions changed since they were read"}\n409',
      stderr = '',
    }
  end)
  local api = new_client(fake, fake_capability({}), { permission_provider = 'github' })
  local failure
  api:update_permissions(permission_snapshot('github'), { 'github.read' }, function(err)
    failure = err
  end)
  equal(failure.kind, 'permissions_conflict')
  equal(failure.definitive, true)
  equal(#fake.calls, 1, 'a permission update conflict was retried')
end

test_endpoint_boundary()
test_ticket_id_boundary()
test_tunnel_configuration_and_argv()
test_tunnel_owned_lifecycle()
test_tunnel_refuses_unowned_listener()
test_tunnel_failures_are_bounded()
test_tunnel_unexpected_exit_is_reported()
test_canonical_broker_vectors()
test_canonical_encoding_rules()
test_canonical_fail_safe()
test_gate_classification()
test_conflict_and_error_body_decoding()
test_indeterminate_is_its_own_state()
test_list_rendering()
test_detail_rendering()
test_typed_confirmation()
test_decision_timeout_bounds()
test_capability_never_reaches_argv()
test_every_post_carries_a_content_type()
test_reads_and_decisions_keep_separate_budgets()
test_deny_sends_nothing_the_schema_forbids()
test_failed_capability_fetch_aborts_the_request()
test_one_forced_refetch_after_401()
test_a_decision_is_never_resubmitted()
test_definitive_refusals_are_not_polled()
test_poll_deadline_reports_unknown_and_stops()
test_capability_cache_and_prompt_containment()
test_provider_capabilities_are_isolated()
test_permissions_contract_and_provider_binding()
test_permissions_conflict_is_definitive()

print('McpBuff unit tests passed')
