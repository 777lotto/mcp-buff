-- The ticket-source registry.
--
-- A source is one broker's review surface: its digest domain, its ticket state
-- machine, the words that describe what approving one of its tickets actually
-- does, and the renderers for its own request shapes. The panel, the client,
-- and the renderer know only this interface, so a third broker is a fourth
-- file here plus one configuration key -- not a change to the review flow.
--
-- Every source is required to answer the same three safety questions:
--
--   * which digest domain binds a decision (`digest_prefix`);
--   * which statuses may be decided (`decidable`), and which statuses mean the
--     decision has an outcome the operator can read (`settled`);
--   * what an approval licenses, in the operator's own terms (`approval_grant`).
--
-- The third exists because the two brokers already differ on it. Cloudflare
-- executes every stored mutation inside the approval POST; the git broker only
-- unlocks a token that some later push may spend. A panel that described both
-- as "approve" and stopped there would be hiding the difference that matters
-- most at the moment of the keystroke.

local M = {}

local ORDER = { 'cloudflare', 'github' }

local loaded = {}

--- Look one source up by id. Sources are loaded lazily so that requiring the
--- registry never pulls in a provider the operator has not configured.
function M.get(id)
  if loaded[id] == nil then
    loaded[id] = require('mcp_buff.sources.' .. id)
  end
  return loaded[id]
end

--- Every known source id, in panel tab order.
function M.ids()
  return vim.deepcopy(ORDER)
end

--- Structural matcher used by a source to recognise one of its own request
--- shapes.
---
--- The match is exact and total: every declared key must be present with the
--- declared type, and no key beyond the declaration may appear. That direction
--- is deliberate. When a broker release adds a field to a request, the shape
--- stops matching and the request falls through to the source's unknown-shape
--- renderer, which says so. The alternative -- a tolerant match -- would render
--- the new field's ticket under the old shape's description, so the operator
--- would approve a grant whose extra term was never shown. Failing to
--- recognise a request is recoverable; describing it wrongly is not.
---
--- Supported types: 'string', 'number', 'boolean', 'table', 'string[]', and
--- 'json' for a field the broker's own schema types as any JSON value; any of
--- them suffixed with '?' to mark the key optional.
function M.shape(value, spec)
  if type(value) ~= 'table' then return false end
  local declared = {}
  for key, kind in pairs(spec) do
    declared[key] = true
    local optional = kind:sub(-1) == '?'
    if optional then kind = kind:sub(1, -2) end
    local field = value[key]
    if field == nil then
      if not optional then return false end
    elseif kind == 'string[]' then
      if type(field) ~= 'table' then return false end
      local count = #field
      if count == 0 then return false end
      local total = 0
      for _ in pairs(field) do total = total + 1 end
      -- A decoded JSON array carries nothing but 1..#value. Anything else is
      -- an object, and an object is not the list this spec declared.
      if total ~= count then return false end
      for index = 1, count do
        if type(field[index]) ~= 'string' or field[index] == '' then return false end
      end
    elseif kind == 'string' then
      if type(field) ~= 'string' or field == '' then return false end
    elseif kind ~= 'json' and type(field) ~= kind then
      -- 'json' constrains nothing beyond presence: the broker's own schema
      -- types the field as any JSON value, so narrowing it here would refuse
      -- a request the broker considers ordinary.
      return false
    end
  end
  for key in pairs(value) do
    if not declared[key] then return false end
  end
  return true
end

--- Resolve one request against a source's scope registry.
---
--- Returns the matched scope, or the source's unknown scope. A source's
--- unknown scope is never omitted: a request this release cannot name is still
--- inside the digest, so it is still reviewable, and hiding it would be the one
--- presentation that could get an unexamined grant approved.
function M.match_scope(source, request)
  for _, scope in ipairs(source.scopes or {}) do
    if scope.matches(request) then return scope end
  end
  return source.unknown_scope
end

return M
