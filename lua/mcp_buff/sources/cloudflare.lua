-- The Cloudflare write-ticket source: apps/local/mcp-broker on 127.0.0.1:8792.
--
-- Cloudflare has no native proposal object for a DNS or Worker mutation, so
-- this broker manufactures one per mutation and executes it inside the
-- approval POST. That single fact drives everything below: approval is
-- terminal, the interesting evidence is the preflight observation and the
-- result, and `indeterminate` is a first-class state because a mutation that
-- may or may not have reached Cloudflare is neither a success nor a failure.

local canonical = require('mcp_buff.canonical')
local registry = require('mcp_buff.sources')

local M = {
  id = 'cloudflare',
  title = 'Cloudflare broker',
  tab_label = 'Cloudflare',
  ticket_noun = 'write ticket',
  digest_prefix = canonical.CLOUDFLARE_TICKET_PREFIX,
  default_endpoint = 'http://127.0.0.1:8792',
  permissions_provider = 'cloudflare',
  -- The unprefixed setup() key, kept from before there was a second provider.
  capability_cmd_key = 'capability_cmd',
}

-- Attention order, not lifecycle order. `indeterminate` sits above `failed`
-- because bucketing an unknown outcome below a known one is the presentation
-- it must never be given, and `executed` sits last because a finished mutation
-- is the least urgent thing on the surface.
M.status_order = {
  'pending',
  'approved',
  'executing',
  'indeterminate',
  'failed',
  'denied',
  'expired',
  'executed',
}

M.status_labels = {
  pending = 'Pending',
  approved = 'Approved',
  executing = 'Executing',
  executed = 'Executed',
  failed = 'Failed',
  indeterminate = 'Indeterminate',
  denied = 'Denied',
  expired = 'Expired',
}

M.status_highlights = {
  pending = 'McpBuffPending',
  approved = 'McpBuffApproved',
  executing = 'McpBuffExecuting',
  executed = 'McpBuffExecuted',
  failed = 'McpBuffFailed',
  indeterminate = 'McpBuffIndeterminate',
  denied = 'McpBuffDenied',
  expired = 'McpBuffExpired',
}

M.decidable = { pending = true }

-- Nothing transitions out of these.
M.terminal = {
  executed = true,
  failed = true,
  indeterminate = true,
  denied = true,
  expired = true,
}

-- The statuses that answer "what happened to my decision". Approval executes
-- synchronously here, so this is exactly the terminal set: a 200 from approve
-- is always terminal, and a non-terminal 200 is a response to resolve by
-- polling rather than to believe.
M.settled = M.terminal

-- Approval executes every preflight and every mutation inside the POST, so its
-- budget is sized against that execution window rather than against a
-- conventional HTTP timeout. Neither bound limits the operator's review time,
-- which is bounded only by ticket expiry.
M.default_decision_timeout = 1865
M.default_poll_deadline = 1865

-- The two wire facts that differ between brokers.
M.http = {
  digest_conflict_note = 'No Cloudflare request was sent.',
  -- A body over the 32kb express.json cap matches no branch of this broker's
  -- error handler, so it falls through to a bare 500 rather than the 413 a
  -- reader would assume. Its sibling answers 413.
  oversized_body_is_500 = true,
}

-- Statuses where the decision did what was asked. `failed` is settled and is
-- not one of them: a mutation that ran and was rejected is not routine news.
M.decision_ok = { executed = true, denied = true }

-- Settled statuses that deserve an error and a second sentence explaining why.
M.decision_alarming = {
  indeterminate = 'this outcome is unknown, not failed. Inspect it upstream '
    .. 'and never replay this ticket.',
}

M.approval_grant = 'every stored mutation below, executed inside the approval '
  .. 'POST itself. There is no later step to reconsider at.'

M.denial_grant = 'nothing. The ticket becomes terminal and no mutation is sent.'

-- ---------------------------------------------------------------------------
-- Request shapes
-- ---------------------------------------------------------------------------

local function json_block(lines, value, render)
  lines[#lines + 1] = '```json'
  vim.list_extend(lines, vim.split(render.pretty_json(value), '\n', { plain = true }))
  lines[#lines + 1] = '```'
end

local function bullet(label, value)
  return ('- **%s:** %s'):format(label, tostring(value))
end

local function render_mutation(lines, request, render)
  lines[#lines + 1] = ('`%s %s`'):format(
    tostring(request.method or '?'), tostring(request.path or '?'))
  lines[#lines + 1] = ''
  if request.body == nil then
    lines[#lines + 1] = '_No request body._'
  else
    json_block(lines, request.body, render)
  end

  -- The structured precondition is part of what the operator reviews: it is
  -- inside the digest, and it is the evidence the broker will re-check.
  local precondition = request.precondition
  lines[#lines + 1] = ''
  if type(precondition) ~= 'table' then
    lines[#lines + 1] = '_No stored precondition._'
    return
  end
  lines[#lines + 1] = ('**Precondition:** `%s %s`'):format(
    tostring(precondition.method or '?'), tostring(precondition.path or '?'))
  local expect = precondition.expect
  if type(expect) == 'table' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = bullet('Expected status', expect.status or '?')
    if expect.result_sha256 then
      lines[#lines + 1] = bullet('Expected result_sha256', expect.result_sha256)
    end
    if expect.etag then
      lines[#lines + 1] = bullet('Expected ETag', expect.etag)
    end
  end
end

M.scopes = {
  {
    id = 'api-mutation',
    title = 'Cloudflare API mutation',
    -- The Cloudflare broker composes every operation from the same request
    -- record, so this source has one shape rather than a growing registry.
    -- It mirrors the broker's own strict schema, with two deliberate
    -- relaxations: `body` is typed there as any JSON value, so it is not
    -- narrowed to an object here; and `precondition`, which that schema
    -- requires, is optional so that a stored ticket from an older release
    -- renders as itself rather than as an unrecognised shape.
    matches = function(request)
      return registry.shape(request, {
        method = 'string',
        path = 'string',
        body = 'json?',
        precondition = 'table?',
      })
    end,
    summary = function(request)
      return ('%s %s'):format(tostring(request.method), tostring(request.path))
    end,
    render = render_mutation,
  },
}

M.unknown_scope = {
  id = 'unknown',
  title = 'Unrecognised request shape',
  summary = function() return 'shape not recognised by this release' end,
  render = function(lines, request, render)
    lines[#lines + 1] = 'This release does not recognise this request shape, so '
      .. 'it has no description for what approving it would do. The whole record '
      .. 'is below and is covered by the digest; read it against the broker '
      .. 'release before deciding.'
    lines[#lines + 1] = ''
    json_block(lines, request, render)
  end,
}

-- ---------------------------------------------------------------------------
-- Detail sections
-- ---------------------------------------------------------------------------

local function preflight_lines(lines, ticket)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Preflight observations'
  local observations = ticket.preflight_results or {}
  if #observations == 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '_No precondition has been checked._'
    return
  end
  for _, observation in ipairs(observations) do
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('### Step %s · %s · %s'):format(
      tostring(observation.index or '?'),
      tostring(observation.phase or '?'),
      observation.matched and 'matched' or 'DID NOT MATCH')
    lines[#lines + 1] = ''
    lines[#lines + 1] = bullet('Checked', observation.checked or '?')
    lines[#lines + 1] = ('- **Status:** expected %s, observed %s'):format(
      tostring(observation.expected_status or '?'),
      tostring(observation.observed_status or 'none'))
    if observation.expected_result_sha256 or observation.observed_result_sha256 then
      lines[#lines + 1] = ('- **result_sha256:** expected %s, observed %s'):format(
        tostring(observation.expected_result_sha256 or 'none'),
        tostring(observation.observed_result_sha256 or 'none'))
    end
    if observation.expected_etag or observation.observed_etag then
      lines[#lines + 1] = ('- **ETag:** expected %s, observed %s'):format(
        tostring(observation.expected_etag or 'none'),
        tostring(observation.observed_etag or 'none'))
    end
    if observation.error_id then
      lines[#lines + 1] = bullet('Error id', observation.error_id)
    end
  end
end

local function result_lines(lines, ticket, render)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Results'
  if #(ticket.results or {}) == 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '_No request has executed._'
    return
  end
  for _, result in ipairs(ticket.results) do
    lines[#lines + 1] = ''
    -- outcome is the broker's own word for what happened. "indeterminate" here
    -- means the mutation may or may not have reached Cloudflare.
    local outcome = tostring(result.outcome or (result.ok and 'succeeded' or 'rejected'))
    local status = result.status and ('HTTP ' .. tostring(result.status)) or 'no HTTP response'
    lines[#lines + 1] = ('### Step %s · %s · %s'):format(
      tostring(result.index or '?'), outcome, status)
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('`%s %s`'):format(tostring(result.method or '?'), tostring(result.path or '?'))
    if result.error then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '**Error:** ' .. tostring(result.error)
    end
    lines[#lines + 1] = ''
    json_block(lines, result.response, render)
  end
end

--- Everything after the stored requests: the evidence the broker gathered and
--- what it did with it.
function M.detail_sections(lines, ticket, render)
  preflight_lines(lines, ticket)
  result_lines(lines, ticket, render)

  if ticket.status == 'indeterminate' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Indeterminate'
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'The outcome of this ticket is genuinely unknown: a mutation '
      .. 'may or may not have reached Cloudflare. Inspect it upstream. This is not '
      .. 'a retry signal, and this ticket must never be replayed.'
  end
end

--- Extra bullets for the detail header.
function M.detail_facts(ticket)
  return { bullet('Requests', #(ticket.requests or {})) }
end

return M
