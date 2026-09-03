-- The git write-ticket source: apps/local/github-broker on 127.0.0.1:8793.
--
-- GitHub needs far fewer tickets than Cloudflare does, because pull requests
-- already provide a diff and a review surface. What it does need a ticket for
-- is the small set of scopes that reach past that surface. Today there is one:
-- a push that changes `.github/workflows/**`. A push to an agent branch runs
-- Actions on that branch before any pull request is read, so `workflows: write`
-- is gated on a human decision rather than on the ref filter that guards every
-- other push.
--
-- Two things differ from the Cloudflare source, and both are load-bearing.
--
-- The digest domain is `zemrip.git-ticket.v1`, not the Cloudflare prefix, so a
-- digest verified for one broker can never authorise the other.
--
-- Approval does not execute anything. It unlocks a token that a later push, on
-- a different connection, may spend -- or may never spend. So `approved` is not
-- terminal here, an approved-and-unspent ticket is an outstanding grant the
-- operator should be able to see, and the review surface has to say that the
-- effect happens later.

local canonical = require('mcp_buff.canonical')
local registry = require('mcp_buff.sources')

-- The id is the provider the broker names itself (`"provider":"github"` in its
-- permissions document, and the configuration key an operator sets). The tab
-- reads "Git" because what it reviews are git pushes, which is the operator's
-- word for the thing being decided.
local M = {
  id = 'github',
  title = 'GitHub broker',
  tab_label = 'Git',
  digest_prefix = canonical.GIT_TICKET_PREFIX,
  default_endpoint = 'http://127.0.0.1:8793',
  permissions_provider = 'github',
  capability_cmd_key = 'github.capability_cmd',
}

-- Attention order. `approved` sits directly under `pending` because an
-- approved ticket is a live grant with nothing yet spent against it, which is
-- the second most interesting thing on this surface and would be invisible if
-- it were filed with the finished work.
M.status_order = {
  'pending',
  'approved',
  'consumed',
  'denied',
  'expired',
}

M.status_labels = {
  pending = 'Pending',
  approved = 'Approved · unspent',
  consumed = 'Spent',
  denied = 'Denied',
  expired = 'Expired',
}

M.status_highlights = {
  pending = 'McpBuffPending',
  approved = 'McpBuffApproved',
  consumed = 'McpBuffExecuted',
  denied = 'McpBuffDenied',
  expired = 'McpBuffExpired',
}

M.decidable = { pending = true }

-- `approved` is absent on purpose: it still transitions, to `consumed` or to
-- `expired`.
M.terminal = {
  consumed = true,
  denied = true,
  expired = true,
}

-- The statuses that answer "what happened to my decision" -- which here is not
-- the terminal set. A successful approve leaves the ticket `approved`, and that
-- IS the outcome of the decision: the push it licenses may never happen. A
-- client that polled for a terminal state after approving would sit waiting out
-- its whole deadline on a ticket that was decided correctly and immediately.
M.settled = {
  approved = true,
  consumed = true,
  denied = true,
  expired = true,
}

-- A decision here writes one small file and renames it. Nothing executes
-- inside the POST, so the Cloudflare budget -- which is sized against a chain
-- of live Cloudflare mutations -- would only delay giving up on a broken
-- forward. These still bound the request, never the operator's review time.
M.default_decision_timeout = 120
M.default_poll_deadline = 300

M.http = {
  digest_conflict_note = 'No token was minted and no push is licensed.',
  -- This broker reports an oversized body as 413. Its sibling's fall-through to
  -- 500 is a defect that release documents; replicating it here would make an
  -- overlong denial note read as a broker fault.
  oversized_body_is_500 = false,
}

-- A decision here either granted or refused; nothing executed, so there is no
-- third outcome to warn about and nothing that can end up unknown.
M.decision_ok = { approved = true, denied = true }
M.decision_alarming = {}

M.approval_grant = 'no immediate action. It unlocks that scope for one '
  .. 'later push, which is spent before a byte is forwarded and cannot be '
  .. 'reused. Until that push happens the grant stays open.'

M.denial_grant = 'nothing. The ticket becomes terminal and no token is ever '
  .. 'minted for it.'

-- ---------------------------------------------------------------------------
-- Scopes
-- ---------------------------------------------------------------------------
--
-- One entry per ticketed GitHub scope. To add the next one:
--
--   1. declare its exact request shape in `matches`, listing every key the
--      broker sends -- the matcher is total, so an omitted key means real
--      tickets fall through to `unknown_scope` and say so rather than being
--      described by the wrong entry;
--   2. write `render` to put every reviewable term of the grant on screen. The
--      digest covers the whole request record, so anything left out is
--      something the operator approved without reading;
--   3. write `summary` for the one line that heads the step in the detail
--      window, which is where the operator decides from. It names the grant,
--      not the shape.
--
-- Nothing else in the panel needs to change.

local function bullet(label, value)
  return ('- **%s:** %s'):format(label, tostring(value))
end

M.scopes = {
  {
    id = 'workflow-push',
    title = 'Workflow-changing push',
    matches = function(request)
      return registry.shape(request, {
        repo = 'string',
        refs = 'string[]',
      })
    end,
    summary = function(request)
      return ('%s · %d ref%s'):format(
        request.repo, #request.refs, #request.refs == 1 and '' or 's')
    end,
    render = function(lines, request)
      lines[#lines + 1] = bullet('Repository', ('`%s`'):format(request.repo))
      lines[#lines + 1] = ('- **Refs (%d):**'):format(#request.refs)
      -- Every ref, never a count and an ellipsis. The ref set is the grant:
      -- the push is matched against it as a set, and a ref the operator did
      -- not see is a ref they did not approve.
      for _, ref in ipairs(request.refs) do
        lines[#lines + 1] = ('  - `%s`'):format(ref)
      end
      lines[#lines + 1] = ''
      lines[#lines + 1] = 'A push is accepted only if its ref set equals this '
        .. 'one exactly. The broker cannot see which paths the packfile '
        .. 'touches, so this ref set and the repository are the whole of what '
        .. 'is being licensed.'
    end,
  },
}

M.unknown_scope = {
  id = 'unknown',
  title = 'Unrecognised scope',
  summary = function() return 'scope not recognised by this release' end,
  render = function(lines, request, render)
    lines[#lines + 1] = 'This release of mcp-buff does not recognise this '
      .. 'request shape, so it has no description of what approving it would '
      .. 'license. That usually means the broker gained a ticketed scope newer '
      .. 'than this panel.'
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'The complete record is below and is covered by the '
      .. 'digest, so it is reviewable — but review it against the broker '
      .. 'release that issued it, not against this panel\'s vocabulary.'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '```json'
    vim.list_extend(lines, vim.split(render.pretty_json(request), '\n', { plain = true }))
    lines[#lines + 1] = '```'
  end,
}

-- ---------------------------------------------------------------------------
-- Detail sections
-- ---------------------------------------------------------------------------

function M.detail_sections(lines, ticket)
  if ticket.status == 'approved' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## This grant is open'
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'The ticket is approved and nothing has been spent '
      .. 'against it. It still licenses one push of the ref set above until it '
      .. 'is used or it expires. Approval cannot be withdrawn through this '
      .. 'protocol: the state machine has no transition back to pending, and '
      .. 'no deny transition from approved.'
    return
  end

  if ticket.status == 'consumed' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Spent'
    lines[#lines + 1] = ''
    lines[#lines + 1] = bullet('Consumed', ticket.consumed or 'time not recorded')
    lines[#lines + 1] = ''
    -- The distinction matters for the next decision: a burned approval whose
    -- push failed is not a reason to re-approve without asking why.
    lines[#lines + 1] = 'The transition to spent is written before the push is '
      .. 'forwarded, so this records that the grant was claimed — not that the '
      .. 'push reached GitHub. A push that failed at GitHub still burns its '
      .. 'approval. GitHub\'s own log is the record of what actually landed.'
  end
end

function M.detail_facts(ticket)
  local facts = { bullet('Scopes requested', #(ticket.requests or {})) }
  if ticket.consumed then
    facts[#facts + 1] = bullet('Consumed', ticket.consumed)
  end
  return facts
end

return M
