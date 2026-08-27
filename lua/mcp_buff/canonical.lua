-- Canonical JSON and the broker's immutable ticket digest, recomputed locally.
--
-- The broker binds every decision to sha256 over a versioned preimage. A client
-- that cannot reproduce that digest byte-for-byte must refuse to submit, so this
-- encoder is deliberately narrow: it emits only what it can prove matches
-- JavaScript's JSON.stringify, and returns nil for everything else.

local M = {}

M.TICKET_DIGEST_VERSION = 'zemrip.mcp-ticket.v1'

-- vim.json.decode marks a decoded `{}` with the vim.empty_dict metatable and
-- leaves a decoded `[]` as a bare table, which is the only way to tell the two
-- apart once they are Lua values.
local EMPTY_DICT_METATABLE = getmetatable(vim.empty_dict())

-- Beyond this magnitude JavaScript numbers stop being exact integers and
-- JSON.stringify output is no longer predictable from the Lua double.
local MAX_SAFE_INTEGER = 9007199254740991

local SHORT_ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

-- JSON.stringify uses the seven short escapes, spells the remaining C0 control
-- characters as \u00xx, and leaves every other byte alone so valid UTF-8 passes
-- through unchanged. It does not escape the forward slash.
local function encode_string(value)
  local escaped = value:gsub('[%z\1-\31"\\]', function(char)
    return SHORT_ESCAPES[char] or ('\\u%04x'):format(char:byte())
  end)
  return '"' .. escaped .. '"'
end

-- Only integers are encodable. A non-integer Lua double has no provably
-- identical JSON.stringify spelling, and guessing one would let a client approve
-- a payload it did not actually verify.
local function encode_number(value)
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  if value % 1 ~= 0 then return nil end
  if value > MAX_SAFE_INTEGER or value < -MAX_SAFE_INTEGER then return nil end
  -- JSON.stringify(-0) is "0"; formatting -0 with %d would emit "-0".
  if value == 0 then return '0' end
  return ('%d'):format(value)
end

-- Object keys are sorted with table.sort, which orders by byte. JavaScript sorts
-- by UTF-16 code unit. The two agree for ASCII and can disagree above it, so a
-- non-ASCII key is treated as unencodable rather than sorted on a guess.
local function encodable_key(key)
  return type(key) == 'string' and key:match('^[\32-\126]*$') ~= nil
end

local encode

local function encode_array(value, count)
  local parts = {}
  for index = 1, count do
    local encoded = encode(value[index])
    if not encoded then return nil end
    parts[index] = encoded
  end
  return '[' .. table.concat(parts, ',') .. ']'
end

local function encode_object(value)
  local keys = {}
  for key in pairs(value) do
    if not encodable_key(key) then return nil end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = {}
  for index, key in ipairs(keys) do
    local encoded = encode(value[key])
    if not encoded then return nil end
    parts[index] = encode_string(key) .. ':' .. encoded
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

encode = function(value)
  if value == nil or value == vim.NIL then return 'null' end
  local kind = type(value)
  if kind == 'boolean' then return tostring(value) end
  if kind == 'number' then return encode_number(value) end
  if kind == 'string' then return encode_string(value) end
  if kind ~= 'table' then return nil end

  if getmetatable(value) == EMPTY_DICT_METATABLE then return '{}' end

  local count = #value
  if count > 0 then
    -- A decoded JSON array carries nothing but 1..#value; anything else is a
    -- Lua table this encoder has no defined output for.
    local total = 0
    for _ in pairs(value) do total = total + 1 end
    if total ~= count then return nil end
    return encode_array(value, count)
  end
  if next(value) == nil then return '[]' end
  return encode_object(value)
end

--- Encode a decoded JSON value as the broker's canonical JSON.
--- Returns nil when the value contains anything this encoder cannot prove
--- matches JSON.stringify byte-for-byte.
function M.encode(value)
  return encode(value)
end

local IMMUTABLE_STRINGS = { 'id', 'created', 'expires', 'reason' }

--- Build the exact digest preimage: version prefix, one newline, canonical JSON
--- of the five immutable fields. Returns nil when the ticket is unusable.
function M.ticket_preimage(ticket)
  if type(ticket) ~= 'table' then return nil end
  for _, field in ipairs(IMMUTABLE_STRINGS) do
    if type(ticket[field]) ~= 'string' then return nil end
  end
  if type(ticket.requests) ~= 'table' then return nil end

  local encoded = encode({
    id = ticket.id,
    created = ticket.created,
    expires = ticket.expires,
    reason = ticket.reason,
    requests = ticket.requests,
  })
  if not encoded then return nil end
  return M.TICKET_DIGEST_VERSION .. '\n' .. encoded
end

--- Recompute ticket_sha256 from the ticket's own immutable fields.
function M.ticket_digest(ticket)
  local preimage = M.ticket_preimage(ticket)
  if not preimage then return nil end
  return vim.fn.sha256(preimage)
end

--- Compare the served digest with a local recomputation.
--- Returns true only when both exist and agree; the second value explains a
--- refusal so the panel can tell the operator which half went wrong.
function M.verify(ticket)
  local served = type(ticket) == 'table' and ticket.ticket_sha256 or nil
  if type(served) ~= 'string' or not served:match('^[a-f0-9]+$') or #served ~= 64 then
    return false, 'the broker did not serve a well-formed ticket_sha256'
  end
  local recomputed = M.ticket_digest(ticket)
  if not recomputed then
    return false, 'this ticket contains a value mcp-buff cannot canonicalise, '
      .. 'so its digest cannot be verified; review it with mcp-broker-admin'
  end
  if recomputed ~= served then
    return false, 'recomputed digest ' .. recomputed .. ' does not match the served '
      .. served .. '; do not approve this ticket'
  end
  return true
end

return M
