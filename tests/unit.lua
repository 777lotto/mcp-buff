local broker = require('mcp_buff.broker')
local canonical = require('mcp_buff.canonical')
local capability = require('mcp_buff.capability')
local client = require('mcp_buff.client')
local render = require('mcp_buff.render')
local source_registry = require('mcp_buff.sources')
local cloudflare = require('mcp_buff.sources.cloudflare')
local github = require('mcp_buff.sources.github')
local tunnel = require('mcp_buff.tunnel')

local CF = canonical.CLOUDFLARE_TICKET_PREFIX
local GIT = canonical.GIT_TICKET_PREFIX

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

-- The same five immutable fields under the git broker's domain separator.
-- Recomputed from the vector above rather than hardcoded, because the point
-- being proved is that the prefix is the only difference.
local GIT_CANONICAL_VECTOR = 'zemrip.git-ticket.v1'
  .. BROKER_CANONICAL_VECTOR:sub(#'zemrip.mcp-ticket.v1' + 1)

local function test_canonical_broker_vectors()
  -- "sorts object keys recursively without reordering arrays"
  equal(canonical.encode(vim.json.decode('{"z":1,"a":{"y":true,"x":null},"b":[3,2,1]}')),
    '{"a":{"x":null,"y":true},"b":[3,2,1],"z":1}')

  equal(canonical.ticket_preimage(BROKER_TICKET_VECTOR, CF), BROKER_CANONICAL_VECTOR)
  equal(canonical.ticket_digest(BROKER_TICKET_VECTOR, CF), BROKER_DIGEST_VECTOR)
  equal(select(1, canonical.verify(vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = BROKER_DIGEST_VECTOR,
  }), CF)), true)
end

--- Domain separation is the whole reason the prefix is a parameter.
---
--- The two brokers hold different powers and are reviewed in the same panel, so
--- a digest the operator typed for a Cloudflare ticket must not verify for a git
--- ticket carrying an identical immutable payload. These assertions are what
--- would fail if someone "simplified" the prefix back to a constant.
local function test_digest_domains_are_separate()
  equal(canonical.ticket_preimage(BROKER_TICKET_VECTOR, GIT), GIT_CANONICAL_VECTOR)
  local git_digest = canonical.ticket_digest(BROKER_TICKET_VECTOR, GIT)
  equal(git_digest, vim.fn.sha256(GIT_CANONICAL_VECTOR))
  assert(git_digest ~= BROKER_DIGEST_VECTOR,
    'the two digest domains produced the same digest for one payload')

  -- One payload, one served digest, two domains: exactly one may verify.
  local served = vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = BROKER_DIGEST_VECTOR,
  })
  equal(select(1, canonical.verify(served, CF)), true)
  equal(select(1, canonical.verify(served, GIT)), false,
    'a Cloudflare digest verified in the git domain')

  -- A caller that forgets the domain gets a refusal, never a default. A
  -- defaulted domain is the cross-broker replay this parameter exists to stop.
  local missing, reason = canonical.verify(served)
  equal(missing, false, 'verification without a digest domain was accepted')
  contains(reason, 'no known ticket digest domain')
  equal(select(1, canonical.verify(served, 'zemrip.invented.v1')), false)
  equal(canonical.ticket_digest(BROKER_TICKET_VECTOR, nil), nil)

  -- Each source names its own domain, and no two share one.
  equal(cloudflare.digest_prefix, CF)
  equal(github.digest_prefix, GIT)
  local seen = {}
  for _, id in ipairs(source_registry.ids()) do
    local prefix = source_registry.get(id).digest_prefix
    assert(not seen[prefix], 'two sources share a digest domain: ' .. prefix)
    seen[prefix] = true
  end
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
  local ok, reason = canonical.verify(drifted, CF)
  equal(ok, false, 'an uncanonicalisable ticket was accepted')
  contains(reason, 'cannot canonicalise')

  local tampered = vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = string.rep('a', 64),
  })
  local mismatched, mismatch_reason = canonical.verify(tampered, CF)
  equal(mismatched, false, 'a mismatched digest was accepted')
  contains(mismatch_reason, 'do not approve this ticket')

  equal(select(1, canonical.verify({ ticket_sha256 = 'nope' }, CF)), false)
  equal(select(1, canonical.verify(vim.tbl_extend('force', BROKER_TICKET_VECTOR, {
    ticket_sha256 = BROKER_DIGEST_VECTOR:upper(),
  }), CF)), false, 'an uppercase digest was accepted')
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

  local not_found = client.classify(404, '{"error":"ticket not found: t_1"}')
  equal(not_found.kind, 'not_found')
  contains(not_found.message, 'retention window')
end

--- The three wire facts that differ between the two brokers.
---
--- They are carried by the source rather than branched on at the call site, so
--- these assertions are what proves a message is accurate for the broker that
--- actually answered rather than for whichever one was written first.
local function test_provider_specific_wire_facts()
  local cf_wire = vim.tbl_extend('force', cloudflare.http, { port = 8792 })
  local git_wire = vim.tbl_extend('force', github.http, { port = 8793 })

  -- 1. A refused digest means different things were not done.
  local cf_digest = client.classify(409,
    '{"error":"ticket t_1 digest does not match the reviewed immutable payload"}',
    'decision', cf_wire)
  contains(cf_digest.message, 'No Cloudflare request was sent')
  local git_digest = client.classify(409,
    '{"error":"ticket t_1 digest does not match the reviewed immutable payload"}',
    'decision', git_wire)
  contains(git_digest.message, 'No token was minted')

  -- 2. An oversized body: the Cloudflare broker falls through to a bare 500,
  -- which its own spec records as a defect, so a 500 there is not known to be
  -- a broker fault. The GitHub broker says 413 and that is definitive.
  local cf_500 = client.classify(500, '{"error":"internal server error"}',
    'decision', cf_wire)
  equal(cf_500.definitive, false)
  contains(cf_500.message, 'oversized')
  local git_500 = client.classify(500, '{"error":"internal server error"}',
    'decision', git_wire)
  equal(git_500.definitive, false)
  excludes(git_500.message, 'oversized',
    'the GitHub broker was described as answering 500 for an oversized body')
  local too_large = client.classify(413, '{"error":"request body too large"}',
    'decision', git_wire)
  equal(too_large.kind, 'body_too_large')
  -- Definitive: the body was refused mid-read, so nothing was decided and
  -- there is nothing to poll for.
  equal(too_large.definitive, true)

  -- 3. The Host gate's remedy names the port the operator must forward, and
  -- each broker has its own.
  contains(client.classify(400, '{"error":"invalid host"}', nil, cf_wire).message,
    'ssh -L 8792:127.0.0.1:8792')
  contains(client.classify(400, '{"error":"invalid host"}', nil, git_wire).message,
    'ssh -L 8793:127.0.0.1:8793')
end

--- Build one rendered panel for a source, with everything else quiet.
local function panel_text(source, tickets, opts)
  opts = opts or {}
  local tab = {
    id = source.id,
    source = source,
    tickets = tickets,
    permissions = require('mcp_buff.permissions').new(),
    configured = true,
    shows_permissions = opts.shows_permissions == true,
  }
  local bar = {
    { id = source.id, label = source.tab_label,
      pending = render.pending_count(source, tickets) },
  }
  local output = render.panel(bar, tab, { width = 100, now = opts.now })
  return table.concat(output.lines, '\n'), output
end

local function test_indeterminate_is_its_own_state()
  assert(vim.tbl_contains(cloudflare.status_order, 'indeterminate'),
    'indeterminate is missing from the render order')
  local text = panel_text(cloudflare, {
    {
      id = 't_20260820T170000.000Z_00000000000a',
      created = '2026-08-20T17:00:00.000Z',
      status = 'indeterminate',
      reason = 'restart recovery left this outcome unknown',
    },
  }, { now = render.iso_epoch('2026-08-20T18:05:00Z') })
  contains(text, 'Indeterminate  (1)')
  contains(text, 'Failed  (0)', 'indeterminate was bucketed into failed')
  assert(text:find('Indeterminate', 1, true) < text:find('Failed', 1, true),
    'indeterminate did not sort ahead of failed')
end

local function test_list_rendering()
  local now = assert(render.iso_epoch('2026-08-20T18:05:00Z'))
  local tickets = {
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
  }
  local text = panel_text(cloudflare, tickets, { now = now })
  equal(render.pending_count(cloudflare, tickets), 1)
  contains(text, 'Pending  (1)')
  contains(text, '5m')
  contains(text, 'worker state was read immediately before submission')
  assert(text:find('Pending', 1, true) < text:find('Executed', 1, true),
    'pending group was not rendered first')
end

local function test_ticket_categories_follow_the_visible_list()
  local categories = render.ticket_categories(github, {
    {
      id = 'pending-older',
      created = '2026-09-03T09:00:00Z',
      status = 'pending',
    },
    {
      id = 'unknown-older',
      created = '2026-09-03T08:00:00Z',
      status = 'quarantined',
    },
    {
      id = 'approved',
      created = '2026-09-03T07:00:00Z',
      status = 'approved',
    },
    {
      id = 'pending-newer',
      created = '2026-09-03T10:00:00Z',
      status = 'pending',
    },
    {
      id = 'unknown-newer',
      created = '2026-09-03T11:00:00Z',
      status = 'held-for-review',
    },
  })

  equal(#categories, 3, 'empty status headings became preview destinations')
  equal(categories[1].id, 'pending')
  equal(categories[1].tickets[1].id, 'pending-newer',
    'ticket navigation disagrees with the list\'s newest-first order')
  equal(categories[1].tickets[2].id, 'pending-older')
  equal(categories[2].id, 'approved')
  equal(categories[3].id, 'unknown')
  equal(categories[3].label, render.UNKNOWN_STATUS_LABEL)
  equal(categories[3].tickets[1].id, 'unknown-newer',
    'unrecognised statuses did not remain one visible category')
end

--- A status the broker served that this release has no entry for.
---
--- The safe presentation is its own bucket with its own warning. Folding it
--- into `failed` would assert the request definitely did not happen, and
--- folding it into `pending` would offer a decision -- both are claims about a
--- word this client does not know.
local function test_unknown_status_is_not_folded()
  local text = panel_text(github, {
    {
      id = 't_20260903T090000.000Z_0000000000c1',
      created = '2026-09-03T09:00:00.000Z',
      status = 'quarantined',
      reason = 'a status from a newer broker release',
    },
  }, { now = render.iso_epoch('2026-09-03T09:05:00Z') })
  contains(text, render.UNKNOWN_STATUS_LABEL .. '  (1)')
  contains(text, 'Neither decidable')
  contains(text, 'Pending  (0)', 'an unknown status was counted as pending')
  contains(text, 'Denied  (0)', 'an unknown status was bucketed into denied')
end

--- The tab bar is how an inactive provider asks for attention.
local function test_tab_bar_marks_state()
  local bar = {
    { id = 'cloudflare', label = 'Cloudflare', pending = 2 },
    { id = 'github', label = 'Git', pending = 0, dirty = true },
  }
  local tab = {
    id = 'github',
    source = github,
    tickets = {},
    permissions = require('mcp_buff.permissions').new(),
    configured = true,
  }
  local output = render.panel(bar, tab, { width = 100 })
  local text = table.concat(output.lines, '\n')
  -- The active marker, the pending count on the tab nobody is looking at, and
  -- the unapplied-edit mark.
  contains(text, '1 Cloudflare 2')
  contains(text, '▸ 2 Git*')
  local active, inactive = false, false
  for _, highlight in ipairs(output.highlights) do
    if highlight.group == 'McpBuffTabActive' then active = true end
    if highlight.group == 'McpBuffTabInactive' then inactive = true end
  end
  assert(active and inactive, 'the tab bar did not distinguish the active tab')
end

--- An unconfigured provider still gets a tab that says what is missing, rather
--- than a surface the operator cannot find or an opaque 401.
local function test_unconfigured_tab_explains_itself()
  local tab = {
    id = 'github',
    source = github,
    tickets = {},
    permissions = require('mcp_buff.permissions').new(),
    configured = false,
  }
  local text = table.concat(render.panel(
    { { id = 'github', label = 'Git' } }, tab, { width = 100 }).lines, '\n')
  contains(text, 'has no capability_cmd')
  contains(text, 'github.capability_cmd')
  excludes(text, 'Tickets ·', 'an unauthenticated tab rendered a ticket queue')
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

local GIT_TICKET = {
  ticket_version = 1,
  id = 't_20260903T090000.000Z_0000000000b1',
  created = '2026-09-03T09:00:00.000Z',
  expires = '2026-09-03T11:00:00.000Z',
  status = 'pending',
  ticket_sha256 = string.rep('7', 56) .. 'd00dfeed',
  reason = 'add a nightly Actions workflow',
  requests = {
    {
      repo = '777lotto/zemrip',
      refs = { 'refs/heads/agent/ci-nightly', 'refs/heads/agent/ci-weekly' },
    },
  },
}

local function test_detail_rendering()
  local detail = render.detail(cloudflare, DETAIL_TICKET)
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
  -- This ticket is terminal, so there is no approval left to describe.
  excludes(detail, '## What approval does')

  local rejected = vim.deepcopy(DETAIL_TICKET)
  rejected.status = 'failed'
  rejected.results[1].status = 400
  rejected.results[1].outcome = 'rejected'
  rejected.results[1].response = {
    success = false,
    errors = {
      { code = 10021, message = 'synthetic Cloudflare validation detail' },
    },
  }
  local rejected_detail = render.detail(cloudflare, rejected)
  contains(rejected_detail, '"code": 10021')
  contains(rejected_detail, '"message": "synthetic Cloudflare validation detail"')
end

local function test_git_detail_rendering()
  local detail = render.detail(github, GIT_TICKET)
  contains(detail, 'GitHub broker')
  contains(detail, GIT_TICKET.ticket_sha256)
  contains(detail, 'Workflow-changing push')
  contains(detail, '**Repository:** `777lotto/zemrip`')
  -- Every ref, never a count and an ellipsis: the ref set IS the grant, and a
  -- ref the operator did not see is a ref they did not approve.
  contains(detail, '`refs/heads/agent/ci-nightly`')
  contains(detail, '`refs/heads/agent/ci-weekly`')
  contains(detail, '**Refs (2):**')
  -- Approval here unlocks a later push rather than executing anything, and the
  -- detail has to say so.
  contains(detail, '## What approval does')
  contains(detail, 'no immediate action')
  contains(detail, 'spent before a byte is forwarded')
  -- Cloudflare's evidence sections have no meaning on this broker.
  excludes(detail, '## Preflight observations')
  excludes(detail, '## Results')

  -- An approved-and-unspent grant is a live capability, and is labelled as one.
  local granted = render.detail(github,
    vim.tbl_extend('force', GIT_TICKET, { status = 'approved' }))
  contains(granted, '## This grant is open')
  contains(granted, 'no transition back to pending')

  -- A spent grant records that the token was claimed, not that the push landed.
  local spent = render.detail(github, vim.tbl_extend('force', GIT_TICKET, {
    status = 'consumed',
    consumed = '2026-09-03T09:30:00.000Z',
  }))
  contains(spent, '## Spent')
  contains(spent, '**Consumed:** 2026-09-03T09:30:00.000Z')
  contains(spent, 'still burns its approval')
end

--- The shape matcher is exact and total, and that direction is the safety
--- property: a broker that adds a term to a request must stop matching, so the
--- request falls through to the unknown renderer instead of being described by
--- the shape it nearly fits.
local function test_scope_matching_is_total()
  local shape = source_registry.shape
  assert(shape({ repo = 'a/b', refs = { 'refs/heads/agent/x' } },
    { repo = 'string', refs = 'string[]' }))
  assert(not shape({ repo = 'a/b', refs = { 'r' }, extra = 1 },
    { repo = 'string', refs = 'string[]' }), 'an undeclared key still matched')
  assert(not shape({ repo = 'a/b' }, { repo = 'string', refs = 'string[]' }),
    'a missing required key still matched')
  assert(not shape({ repo = '', refs = { 'r' } }, { repo = 'string', refs = 'string[]' }),
    'an empty string satisfied a string field')
  assert(not shape({ repo = 'a/b', refs = {} }, { repo = 'string', refs = 'string[]' }),
    'an empty list satisfied a string[] field')
  assert(not shape({ repo = 'a/b', refs = { 1 } }, { repo = 'string', refs = 'string[]' }),
    'a non-string entry satisfied a string[] field')
  assert(shape({ repo = 'a/b' }, { repo = 'string', note = 'string?' }),
    'an absent optional key was rejected')
  -- 'json' constrains nothing beyond presence, for a field the broker's own
  -- schema types as any JSON value.
  for _, body in ipairs({ 'text', 7, true, {}, { 1, 2 } }) do
    assert(shape({ body = body }, { body = 'json?' }),
      'a JSON value was refused by a json field: ' .. vim.inspect(body))
  end

  -- The Cloudflare request shape mirrors the broker's own strict schema, and a
  -- body it types as any JSON value must not be narrowed here.
  local mutation = source_registry.match_scope(cloudflare, {
    method = 'PATCH',
    path = '/zones/z/dns_records/r',
    body = 'a bare JSON string is a legal body',
    precondition = { method = 'GET', path = '/zones/z/dns_records/r',
      expect = { status = 200 } },
  })
  equal(mutation.id, 'api-mutation', 'a non-object body was called unrecognised')
  -- A request with no precondition still renders as itself: the broker requires
  -- one today, but a ticket stored by an older release should not read as a
  -- shape this panel cannot name.
  equal(source_registry.match_scope(cloudflare, {
    method = 'DELETE', path = '/zones/z/dns_records/r',
  }).id, 'api-mutation')
  -- An undeclared key still falls through, on this source too.
  equal(source_registry.match_scope(cloudflare, {
    method = 'PATCH', path = '/zones/z/dns_records/r', retries = 3,
  }).id, 'unknown')

  -- End to end: the real registry, and a request one key away from the real
  -- workflow-push shape.
  local known = source_registry.match_scope(github, GIT_TICKET.requests[1])
  equal(known.id, 'workflow-push')
  local newer = source_registry.match_scope(github, {
    repo = '777lotto/zemrip',
    refs = { 'refs/heads/agent/settings' },
    branch_protection = 'disable',
  })
  equal(newer.id, 'unknown', 'a request with an extra term matched a known scope')

  -- And the unknown renderer shows the extra term rather than hiding it.
  local detail = render.detail(github, vim.tbl_extend('force', GIT_TICKET, {
    requests = { {
      repo = '777lotto/zemrip',
      refs = { 'refs/heads/agent/settings' },
      branch_protection = 'disable',
    } },
  }))
  contains(detail, 'Unrecognised scope')
  contains(detail, 'does not recognise this request shape')
  contains(detail, '"branch_protection": "disable"')
end

--- The extension point, exercised.
---
--- More GitHub scopes are expected, so this adds one the way a future release
--- would -- a shape, a summary, a renderer -- and asserts that nothing else has
--- to change for it to be listed, described, and confirmed. If adding a scope
--- ever needs an edit outside the source module, this test is where that shows
--- up.
local function test_a_new_scope_needs_only_its_own_entry()
  local seen = {}
  for _, scope in ipairs(github.scopes) do
    assert(not seen[scope.id], 'two scopes share an id: ' .. scope.id)
    seen[scope.id] = true
  end

  local repo_settings = {
    id = 'repo-settings',
    title = 'Repository settings change',
    matches = function(request)
      return source_registry.shape(request, {
        repo = 'string',
        setting = 'string',
        value = 'string',
      })
    end,
    summary = function(request)
      return ('%s · %s → %s'):format(request.repo, request.setting, request.value)
    end,
    render = function(lines, request)
      lines[#lines + 1] = ('- **Repository:** `%s`'):format(request.repo)
      lines[#lines + 1] = ('- **%s:** `%s`'):format(request.setting, request.value)
    end,
  }
  github.scopes[#github.scopes + 1] = repo_settings

  local ok, err = pcall(function()
    local ticket = vim.tbl_extend('force', GIT_TICKET, {
      requests = { {
        repo = '777lotto/zemrip',
        setting = 'allow_squash_merge',
        value = 'false',
      } },
    })
    -- Recognised, described, and digest-verifiable, with no change anywhere
    -- else: the panel, the client, and the renderer never learned its name.
    equal(source_registry.match_scope(github, ticket.requests[1]).id, 'repo-settings')
    local detail = render.detail(github, ticket)
    contains(detail, 'Repository settings change')
    contains(detail, '**allow_squash_merge:** `false`')
    excludes(detail, 'Unrecognised scope')
    contains(detail,
      'Step 0 · Repository settings change · 777lotto/zemrip · allow_squash_merge → false')
    assert(canonical.ticket_digest(ticket, GIT) ~= nil,
      'a new scope broke digest recomputation')

    -- And the workflow-push shape is untouched by the addition.
    equal(source_registry.match_scope(github, GIT_TICKET.requests[1]).id, 'workflow-push')
  end)

  github.scopes[#github.scopes] = nil
  if not ok then error(err) end
  equal(source_registry.match_scope(github, {
    repo = 'a/b', setting = 's', value = 'v',
  }).id, 'unknown', 'the added scope outlived the test')
end

--- A settled decision is not automatically a successful one, and which
--- settled statuses are good news is the source's to say.
local function test_decision_reporting_levels()
  -- Cloudflare: the mutation ran and was rejected, or nobody knows. Neither is
  -- a routine confirmation, and only one of them is an error.
  equal(cloudflare.decision_ok.executed, true)
  equal(cloudflare.decision_ok.denied, true)
  equal(cloudflare.decision_ok.failed, nil,
    'a failed Cloudflare mutation was reported as good news')
  equal(cloudflare.decision_ok.indeterminate, nil)
  contains(cloudflare.decision_alarming.indeterminate, 'never replay this ticket')

  -- Git: the decision either granted or refused. Nothing executed, so there is
  -- no third outcome and nothing that can end up unknown.
  equal(github.decision_ok.approved, true)
  equal(github.decision_ok.denied, true)
  equal(next(github.decision_alarming), nil)

  -- Every status a source calls good news must be one it also calls settled.
  for _, id in ipairs(source_registry.ids()) do
    local source = source_registry.get(id)
    for status in pairs(source.decision_ok) do
      assert(source.settled[status],
        ('%s reports %s as a decided outcome but does not call it settled')
          :format(id, status))
    end
    for status in pairs(source.decision_alarming) do
      assert(source.settled[status], id .. ' warns about an unsettled status')
    end
  end
end

--- The decision is a keystroke, so the detail window is the whole of the
--- confirmation surface. Everything the old typed prompt carried has to be in
--- it: which broker, what the word "approve" means on that broker, one line per
--- step naming the grant, and the complete digest.
local function test_the_detail_is_the_confirmation_surface()
  local pending = vim.tbl_extend('force', DETAIL_TICKET, { status = 'pending' })
  local detail = render.detail(cloudflare, pending)
  contains(detail, 'Cloudflare broker')
  -- The complete digest, never an abbreviation of it. Nothing asks the operator
  -- to reproduce it, and a truncated one could not be compared against the
  -- broker's own record either.
  contains(detail, pending.ticket_sha256)
  contains(detail, 'executed inside the approval POST itself')
  contains(detail, 'Step 0 · Cloudflare API mutation · PATCH /zones/example-zone')
  -- The keys that decide, on the window that shows the terms.
  contains(detail, '`y` approves and `n` denies')
  contains(detail, 'y` approve · `n` deny')

  local git_detail = render.detail(github, GIT_TICKET)
  contains(git_detail, 'GitHub broker')
  contains(git_detail, 'no immediate action')
  contains(git_detail, 'Step 0 · Workflow-changing push · 777lotto/zemrip · 2 refs')

  -- Denial says what it does not do, on both brokers.
  contains(render.detail(cloudflare, pending), 'no mutation is sent')
  contains(git_detail, 'no token is ever minted')

  -- A scope this release cannot name says so in the heading of its own step,
  -- not only in the body underneath it.
  local unknown = render.detail(github,
    vim.tbl_extend('force', GIT_TICKET, {
      requests = { { repo = 'a/b', refs = { 'r' }, branch_protection = 'disable' } },
    }))
  contains(unknown, 'Step 0 · Unrecognised scope · scope not recognised by this release')

  -- A decided ticket offers no decision, so it must not advertise the keys that
  -- would take one.
  local decided = render.detail(cloudflare, DETAIL_TICKET)
  excludes(decided, '`y` approves and `n` denies')
  excludes(decided, '`y` approve')
  contains(decided, '`>`/`<` ticket')
  contains(decided, '`c` clear')
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

--- One broker's configuration, validated without contacting anything.
local function test_broker_normalization()
  local config = assert(broker.normalize({
    endpoint = 'http://127.0.0.1:8793',
    capability_cmd = { 'pass', 'show', 'github/admin' },
  }, github, { curl_command = 'curl', timeout = 9000, capability_ttl = 120 }))
  equal(config.endpoint, 'http://127.0.0.1:8793')
  equal(config.timeout, 9000, 'a shared timeout was not inherited')
  equal(config.capability_ttl, 120)
  -- Each source brings its own decision budget: nothing executes inside the
  -- GitHub broker's POST, so it does not need Cloudflare's execution window.
  equal(config.decision_timeout, github.default_decision_timeout)
  equal(config.poll_deadline, github.default_poll_deadline)
  assert(config.decision_timeout ~= cloudflare.default_decision_timeout,
    'both brokers ended up with one decision budget')
  -- A tunnel is never inherited: two brokers reachable through one SSH alias
  -- still need two forwards, and inheriting the flag would open one to a port
  -- the operator never named.
  equal(config.tunnel, false)
  local tunnelled = assert(broker.normalize(
    { tunnel = { host = 'zemrip-server' } }, github, {}))
  equal(tunnelled.tunnel.port, 8793, 'the forward did not follow the broker endpoint')

  -- The endpoint stays loopback-only, per source, with no exception.
  equal(select(1, broker.normalize({ endpoint = 'http://10.77.0.1:8793' }, github, {})), nil)
  equal(select(1, broker.normalize({ endpoint = 'https://127.0.0.1:8793' }, github, {})), nil)

  -- A silently ignored typo in a security surface is how an endpoint ends up
  -- somewhere nobody intended.
  local _, unknown = broker.normalize({ endpint = 'http://127.0.0.1:8793' }, github, {})
  contains(unknown, 'endpint is not a supported option')
  local _, bad_host = broker.normalize({ host_header = 'example.invalid' }, github, {})
  contains(bad_host, 'host_header must look like 127.0.0.1:PORT')
  local _, bad_cmd = broker.normalize({ capability_cmd = 'pass show x' }, github, {})
  contains(bad_cmd, 'capability_cmd must be a non-empty argv list')

  -- An endpoint alone is not enough to authenticate, and the panel says so
  -- rather than serving an opaque 401.
  local live = broker.new(github, assert(broker.normalize(nil, github, {})), {})
  equal(live.config.endpoint, github.default_endpoint)
  equal(live:configured(), false)
  equal(live:shows_permissions(), true)
  equal(broker.new(github, assert(broker.normalize(
    { permissions = false }, github, {})), {}):shows_permissions(), false)
end

--- Every provider gets its own capability cache object, so a bearer minted for
--- one broker cannot be sent to the other. The isolation is structural, not a
--- matter of the call sites being careful.
local function test_brokers_never_share_a_capability()
  local built = broker.build({
    cloudflare = { capability_cmd = { 'true' } },
    github = { capability_cmd = { 'true' } },
  }, {}, {})
  equal(#built, 2)
  equal(built[1].id, 'cloudflare')
  equal(built[2].id, 'github')
  assert(built[1].capability ~= built[2].capability,
    'two brokers shared one capability cache')
  assert(built[1].client ~= built[2].client)
  equal(built[1].client.source.id, 'cloudflare')
  equal(built[2].client.source.id, 'github')
  equal(built[1].client.endpoint, 'http://127.0.0.1:8792')
  equal(built[2].client.endpoint, 'http://127.0.0.1:8793')

  -- Releasing one leaves the other alone, and neither is released while it has
  -- a write in flight.
  built[1]:hold()
  equal(built[1]:release(), false, 'a broker with a write in flight was released')
  equal(built[2]:release(), true)
  built[1]:done()
  equal(built[1]:release(), true)

  -- A provider set to false is absent: no tab, no client, no capability cache.
  local only = broker.build({ github = false }, {}, {})
  equal(#only, 1)
  equal(only[1].id, 'cloudflare')
end

--- setup() accepts the configuration shape it always had, plus the new one, and
--- refuses anything ambiguous rather than guessing which broker was meant.
local function test_setup_configuration_shapes()
  local panel = require('mcp_buff')

  -- The unprefixed keys still configure Cloudflare, and `github` configures the
  -- GitHub broker.
  panel.setup({
    endpoint = 'http://127.0.0.1:8792',
    capability_cmd = { 'true' },
    github = { endpoint = 'http://127.0.0.1:8793', capability_cmd = { 'true' } },
  })
  equal(#panel.tabs, 2)
  equal(panel.tabs[1].id, 'cloudflare')
  equal(panel.tabs[2].id, 'github')
  equal(panel.tabs[2].label, 'Git')
  equal(panel.tabs[2].broker.config.endpoint, 'http://127.0.0.1:8793')
  -- The argv naming a secret's location is used, never republished.
  equal(panel.config.brokers.github.capability_cmd, nil)

  -- permissions.github was this option's previous spelling, from when the
  -- permission panel was the only place a second broker appeared. It configured
  -- that broker's connection, so that is what it still configures.
  panel.setup({
    capability_cmd = { 'true' },
    permissions = {
      cloudflare = false,
      github = { endpoint = 'http://127.0.0.1:9793', capability_cmd = { 'true' } },
    },
  })
  equal(panel.tabs[2].broker.config.endpoint, 'http://127.0.0.1:9793')
  equal(panel.tabs[2].broker:shows_permissions(), true)
  equal(panel.tabs[1].broker:shows_permissions(), false,
    'permissions.cloudflare = false did not hide the Cloudflare section')

  -- Two spellings of one broker's connection, and no way to tell which endpoint
  -- the operator meant. Refuse rather than pick.
  local both = pcall(panel.setup, {
    capability_cmd = { 'true' },
    github = { endpoint = 'http://127.0.0.1:8793' },
    permissions = { github = { endpoint = 'http://127.0.0.1:9793' } },
  })
  equal(both, false, 'two spellings of the GitHub broker were silently merged')

  local typo = pcall(panel.setup, { endpoint_ = 'http://127.0.0.1:8792' })
  equal(typo, false, 'an unknown top-level option was accepted')
  local bad_provider = pcall(panel.setup, { permissions = { gitlab = {} } })
  equal(bad_provider, false)
  local empty = pcall(panel.setup, { cloudflare = false, github = false })
  equal(empty, false, 'a panel with no broker at all was accepted')

  -- pending_count sums every broker, because a statusline asking "is there work
  -- waiting" does not care which tab happens to be open.
  panel.setup({
    capability_cmd = { 'true' },
    github = { capability_cmd = { 'true' } },
  })
  panel.tabs[1].pending = 2
  panel.tabs[2].pending = 3
  equal(panel.pending_count(), 5)
  equal(panel.pending_count('cloudflare'), 2)
  equal(panel.pending_count('github'), 3)
  equal(panel.pending_count('gitlab'), 0)

  -- Leave the module in the state the rest of the suite expects.
  panel.setup({})
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
  equal(resolved.outcome, 'settled')
end

--- The reason `settled` is not `terminal`.
---
--- The git broker's approve unlocks a token; the push that spends it happens
--- later, on another connection, and may never come. So a successful approval
--- leaves the ticket `approved`, which still has a transition left. A client
--- that polled for a terminal state here would sit out its whole deadline on a
--- decision that landed correctly and immediately, and would then report an
--- unknown outcome for a ticket it had just successfully approved.
local function test_a_non_terminal_approval_is_still_an_answer()
  local posts, gets = 0, 0
  local fake = recorder(function(call)
    if call.argv:find('/approve', 1, true) then
      posts = posts + 1
      return { code = 0, stdout = '{"id":"t_1","status":"approved"}\n200', stderr = '' }
    end
    gets = gets + 1
    return { code = 0, stdout = '{"id":"t_1","status":"approved"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}), {
    source = github,
    endpoint = 'http://127.0.0.1:8793',
  })

  local outcome, info
  api:decide('t_20260903T090000.000Z_0000000000b1', 'approve',
    { ticket_sha256 = string.rep('7', 64) }, {
      callback = function(err, ticket, extra)
        assert(not err, vim.inspect(err))
        outcome, info = ticket, extra
      end,
    })
  equal(posts, 1)
  equal(outcome.status, 'approved')
  equal(info.polled, false, 'a settled approval was needlessly polled')
  equal(gets, 0, 'a settled approval was polled for a terminal state it never reaches')

  -- The two predicates disagree here, and both are right.
  assert(api:is_settled('approved'), 'a decided git ticket was not settled')
  assert(not api:is_terminal('approved'),
    'an unspent grant was reported as having no transitions left')
  assert(api:is_terminal('consumed') and api:is_settled('consumed'))

  -- Each broker knows only its own statuses. Cloudflare's `executed` is not a
  -- git status, and git's `consumed` is not a Cloudflare one.
  local cf_api = new_client(fake, fake_capability({}))
  assert(cf_api:is_terminal('executed') and not api:is_terminal('executed'))
  assert(not cf_api:is_settled('consumed'))
  local rejected
  api:list('executed', function(err) rejected = err end)
  equal(rejected.kind, 'configuration')
  contains(rejected.message, 'GitHub broker has no ticket status executed')
end

--- A 200 carrying a status this release has never heard of is not an answer.
--- Polling is the only safe response: a client that cannot name a status cannot
--- claim to know what it means.
local function test_an_unknown_decision_status_is_polled()
  local gets = 0
  local fake = recorder(function(call)
    if call.argv:find('/approve', 1, true) then
      return { code = 0, stdout = '{"id":"t_1","status":"quarantined"}\n200', stderr = '' }
    end
    gets = gets + 1
    return { code = 0, stdout = '{"id":"t_1","status":"denied"}\n200', stderr = '' }
  end)
  local api = new_client(fake, fake_capability({}), {
    source = github,
    endpoint = 'http://127.0.0.1:8793',
  })

  local outcome, info
  api:decide('t_20260903T090000.000Z_0000000000b1', 'approve',
    { ticket_sha256 = string.rep('7', 64) }, {
      callback = function(err, ticket, extra) outcome, info = ticket, extra end,
    })
  assert(gets > 0, 'an unrecognised decision status was believed')
  equal(outcome.status, 'denied')
  equal(info.polled, true)
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
test_provider_specific_wire_facts()
test_digest_domains_are_separate()
test_indeterminate_is_its_own_state()
test_list_rendering()
test_ticket_categories_follow_the_visible_list()
test_unknown_status_is_not_folded()
test_tab_bar_marks_state()
test_unconfigured_tab_explains_itself()
test_detail_rendering()
test_git_detail_rendering()
test_scope_matching_is_total()
test_a_new_scope_needs_only_its_own_entry()
test_decision_reporting_levels()
test_the_detail_is_the_confirmation_surface()
test_decision_timeout_bounds()
test_broker_normalization()
test_brokers_never_share_a_capability()
test_setup_configuration_shapes()
test_capability_never_reaches_argv()
test_every_post_carries_a_content_type()
test_reads_and_decisions_keep_separate_budgets()
test_deny_sends_nothing_the_schema_forbids()
test_failed_capability_fetch_aborts_the_request()
test_one_forced_refetch_after_401()
test_a_decision_is_never_resubmitted()
test_a_non_terminal_approval_is_still_an_answer()
test_an_unknown_decision_status_is_polled()
test_definitive_refusals_are_not_polled()
test_poll_deadline_reports_unknown_and_stops()
test_capability_cache_and_prompt_containment()
test_provider_capabilities_are_isolated()
test_permissions_contract_and_provider_binding()
test_permissions_conflict_is_definitive()

print('McpBuff unit tests passed')
