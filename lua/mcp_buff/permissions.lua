-- Runtime permissions for one broker: state, compare-and-swap, typed apply.
--
-- This edits only the effective subset exposed by a broker's reviewed release.
-- It cannot alter GitHub App permissions, Cloudflare API-token scopes,
-- credentials, routes, or firewall policy. The authorization that can actually
-- execute is the intersection
--
--   upstream credential ceiling ∩ compiled route policy ∩ this enabled set
--
-- and this API can only remove ids from the innermost term.
--
-- The module owns state and requests, not a buffer. It used to own a panel of
-- its own, which is why the providers were stacked into one window and `apply`
-- had to work out its target from the cursor row. Now the panel has a tab per
-- provider, the active tab is the target, and the ambiguity is gone.
--
-- One rule is different from a ticket decision and is the reason the two are
-- not shared code: a permission update has no operation id to poll. An
-- interrupted POST may have committed, so the outcome is unknown and the only
-- recovery is a fresh GET. It is never retried automatically.

local fn = vim.fn

local M = {}

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

--- A fresh, empty state for one provider tab.
function M.new()
  return {
    snapshot = nil,
    -- What the broker last told us was enabled. The diff against the live
    -- snapshot is the operator's unapplied edit.
    baseline = {},
    changed = 0,
    loading = false,
    applying = false,
    error = nil,
    -- Set after any failed apply: the panel must not stack a second change on
    -- top of state it is no longer sure about.
    must_refresh = false,
    outcome_unknown = false,
  }
end

local function baseline_of(snapshot)
  local enabled = {}
  for _, permission in ipairs(snapshot.permissions or {}) do
    enabled[permission.id] = permission.enabled == true
  end
  return enabled
end

local function recount(state)
  local count = 0
  if state.snapshot then
    for _, permission in ipairs(state.snapshot.permissions) do
      if permission.enabled ~= state.baseline[permission.id] then count = count + 1 end
    end
  end
  state.changed = count
end

M.recount = recount

function M.dirty(state)
  return (state.changed or 0) > 0
end

local function adopt(state, snapshot)
  state.snapshot = snapshot
  state.baseline = baseline_of(snapshot)
  state.outcome_unknown = false
  state.must_refresh = false
  state.error = nil
  recount(state)
end

--- Read the provider's permission document.
---
--- `opts.stale` lets the caller abandon a reply that a newer refresh has
--- already superseded, and `opts.allow_capability_fetch` carries the rule that
--- a background tick may not prompt for a credential.
function M.fetch(broker, state, opts, on_change)
  opts = opts or {}
  local stale = opts.stale or function() return false end
  if not broker:configured() then
    state.loading = false
    state.error = nil
    return on_change()
  end
  state.loading = true
  state.error = nil
  on_change()
  broker:ensure({ start = opts.allow_transport_start }, function(transport_error)
    if stale() then return end
    if transport_error then
      state.loading = false
      state.error = transport_error.message
      return on_change()
    end
    broker.client:get_permissions({
      allow_capability_fetch = opts.allow_capability_fetch,
    }, function(err, snapshot)
      if stale() then return end
      state.loading = false
      if err then
        state.error = err.message
        -- Only a state we already showed can go stale. A first read that fails
        -- has nothing to invalidate.
        state.must_refresh = state.snapshot ~= nil
      else
        adopt(state, snapshot)
      end
      on_change()
    end)
  end)
end

--- Flip one permission locally. Nothing is sent until apply().
function M.toggle(state, index)
  if state.loading or state.applying then return false end
  if state.must_refresh then
    return false, 'refresh this tab before making another change'
  end
  local permission = state.snapshot and state.snapshot.permissions[index]
  if not permission then return false, 'that row is not a permission' end
  permission.enabled = not permission.enabled
  recount(state)
  return true
end

local function desired_enabled(state)
  local enabled = {}
  for _, permission in ipairs(state.snapshot.permissions) do
    if permission.enabled then enabled[#enabled + 1] = permission.id end
  end
  return enabled
end

--- Typed confirmation of the current state digest's final eight characters.
--- The same contract as a ticket decision, for the same reason: a keystroke
--- bound to "apply" is not a review.
function M.confirm_prompt(broker, state)
  local suffix = state.snapshot.permissions_sha256:sub(-8)
  return ('%s runtime permissions\nstate digest: %s\nType the final digest bytes %s to apply %d change(s): ')
    :format(broker.source.title, state.snapshot.permissions_sha256, suffix, state.changed)
end

function M.confirmed(broker, state)
  fn.inputsave()
  local ok, answer = pcall(fn.input, M.confirm_prompt(broker, state))
  fn.inputrestore()
  vim.cmd('redraw')
  return ok and trim(answer) == state.snapshot.permissions_sha256:sub(-8)
end

--- Send the replacement set. One POST, ever.
---
--- handlers.on_change re-renders; handlers.on_notify reports; handlers.on_settle
--- runs once the broker has nothing left in flight, so the caller can close a
--- transport it was only holding open for this write.
function M.apply(broker, state, handlers)
  local on_change = handlers.on_change or function() end
  local on_notify = handlers.on_notify or function() end
  local on_settle = handlers.on_settle or function() end

  state.applying = true
  broker:hold()
  on_change()

  local function finish()
    state.applying = false
    broker:done()
    on_change()
    on_settle()
  end

  broker:ensure(function(transport_error)
    if transport_error then
      state.error = transport_error.message
      on_notify(transport_error.message, vim.log.levels.ERROR)
      return finish()
    end
    broker.client:update_permissions(state.snapshot, desired_enabled(state),
      function(err, snapshot)
        if err then
          state.error = err.message
          -- A definitive refusal (409, 400, a bearer failure) changed nothing.
          -- Anything else -- a timeout, a dead forward, an undecodable body --
          -- may have committed the write, and there is no id to poll.
          state.outcome_unknown = err.definitive ~= true
          state.must_refresh = true
          on_notify('permission update failed — ' .. err.message, vim.log.levels.ERROR)
        else
          adopt(state, snapshot)
          on_notify(('%s runtime permissions updated'):format(broker.source.title),
            vim.log.levels.INFO)
        end
        finish()
      end)
  end)
end

return M
