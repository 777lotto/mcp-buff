-- One broker connection: config, capability cache, optional SSH forward, client.
--
-- Before this existed, the Cloudflare connection lived in the panel while the
-- GitHub one lived in the permissions view, and the permissions view had to
-- borrow the panel's transport through a "shared session" indirection so the
-- two surfaces would not open two forwards to the same socket. With one panel
-- holding both providers, that indirection is gone: each provider has exactly
-- one Broker, both of that provider's surfaces use it, and the lifecycle rule
-- is a single sentence -- a broker is released when nothing it owns is in
-- flight and no window is showing the panel.
--
-- What a Broker must never do is share anything across providers. The two
-- sockets have different capabilities, different state, and different powers,
-- so each Broker owns its own capability cache instance. A GitHub bearer sent
-- to Cloudflare would be a 401 at best; the reason it is structurally
-- impossible here is that the caches are separate objects, not that the call
-- sites are careful.

local capability_module = require('mcp_buff.capability')
local client_module = require('mcp_buff.client')
local sources = require('mcp_buff.sources')
local tunnel_module = require('mcp_buff.tunnel')

local M = {}
local Broker = {}
Broker.__index = Broker

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

-- Every key an operator may set on one broker. Anything else is a typo, and a
-- silently ignored typo in a security surface is how an endpoint ends up
-- pointing somewhere nobody intended.
local ALLOWED_KEYS = {
  endpoint = true,
  curl_command = true,
  timeout = true,
  decision_timeout = true,
  poll_deadline = true,
  capability_cmd = true,
  capability_ttl = true,
  host_header = true,
  tunnel = true,
  permissions = true,
}

--- Validate and complete one broker's configuration.
--- Returns the normalized table, or nil plus a message naming the fault.
function M.normalize(raw, source, inherited)
  if raw ~= nil and type(raw) ~= 'table' then
    return nil, 'must be a table or false'
  end
  raw = raw or {}
  for key in pairs(raw) do
    if not ALLOWED_KEYS[key] then
      return nil, ('%s is not a supported option'):format(tostring(key))
    end
  end
  inherited = inherited or {}

  local config = {
    endpoint = raw.endpoint or source.default_endpoint,
    curl_command = raw.curl_command or inherited.curl_command or 'curl',
    timeout = raw.timeout or inherited.timeout,
    decision_timeout = raw.decision_timeout or inherited.decision_timeout,
    poll_deadline = raw.poll_deadline or inherited.poll_deadline,
    capability_cmd = raw.capability_cmd,
    capability_ttl = raw.capability_ttl or inherited.capability_ttl,
    host_header = raw.host_header,
    -- A tunnel is never inherited. Two brokers reachable through one SSH alias
    -- still need two forwards, and inheriting the flag would silently open a
    -- second one to a port the operator never named.
    tunnel = raw.tunnel,
    -- nil means "show the permissions section"; false hides it.
    permissions = raw.permissions ~= false,
  }

  local endpoint, endpoint_error = client_module.normalize_endpoint(config.endpoint)
  if not endpoint then return nil, endpoint_error end
  config.endpoint = endpoint

  if type(config.curl_command) ~= 'string' or trim(config.curl_command) == '' then
    return nil, 'curl_command must be a non-empty string'
  end
  config.timeout = math.max(1000, math.floor(tonumber(config.timeout) or 30000))
  config.decision_timeout = client_module.clamp_decision_seconds(
    config.decision_timeout, source.default_decision_timeout)
  config.poll_deadline = client_module.clamp_decision_seconds(
    config.poll_deadline, source.default_poll_deadline)

  -- The broker compares the request Host against its own bound socket port, so
  -- an asymmetric forward is rejected. Overriding Host is the alternative to
  -- making the forward symmetric.
  if config.host_header ~= nil then
    if type(config.host_header) ~= 'string'
      or config.host_header:match('^127%.0%.0%.1:%d+$') == nil then
      return nil, 'host_header must look like 127.0.0.1:PORT'
    end
  end

  local capability_cmd, capability_error = capability_module.normalize_cmd(config.capability_cmd)
  if capability_error then return nil, capability_error end
  config.capability_cmd = capability_cmd
  config.capability_ttl = math.floor(tonumber(config.capability_ttl)
    or capability_module.DEFAULT_TTL_SECONDS)
  if config.capability_ttl < 0 then
    return nil, 'capability_ttl must be zero or a positive number'
  end

  local tunnel_config, tunnel_error = tunnel_module.normalize(config.tunnel, config.endpoint)
  if tunnel_error then return nil, tunnel_error end
  config.tunnel = tunnel_config or false

  return config
end

--- Build a live connection from a normalized configuration.
--- `on_tunnel_exit` is called when a ready forward dies underneath the panel.
function M.new(source, config, handlers)
  handlers = handlers or {}
  local capability = capability_module.new({
    cmd = config.capability_cmd,
    ttl = config.capability_ttl,
  })
  local broker = setmetatable({
    source = source,
    id = source.id,
    config = config,
    capability = capability,
    -- Surfaces that must finish before the capability and the forward may be
    -- revoked. Counted rather than flagged because one provider has two
    -- surfaces that can each be mid-write.
    in_flight = 0,
    client = client_module.new({
      source = source,
      endpoint = config.endpoint,
      curl_command = config.curl_command,
      timeout = config.timeout,
      decision_timeout = config.decision_timeout,
      poll_deadline = config.poll_deadline,
      host_header = config.host_header,
      capability = capability,
    }),
  }, Broker)

  if config.tunnel then
    broker.tunnel = tunnel_module.new(config.tunnel, {
      on_exit = function(err)
        -- A dead forward invalidates nothing about the capability itself, but
        -- holding it while the route is gone serves no purpose and widens the
        -- window in which it exists.
        capability.clear()
        if handlers.on_tunnel_exit then handlers.on_tunnel_exit(broker, err) end
      end,
    })
  end
  return broker
end

--- Is this broker usable at all? A broker with no capability_cmd is configured
--- as far as its endpoint goes but can never authenticate, and saying so is
--- more useful than serving it an opaque 401.
function Broker:configured()
  return self.config.capability_cmd ~= nil
end

function Broker:shows_permissions()
  return self.config.permissions == true
end

--- Bring the transport up, coalescing concurrent callers.
---
--- `opts.start` may be false to mean "use the forward if it is already up, but
--- do not open one". Background refresh passes that, which is what makes
--- "a timer never opens an SSH route" a property of the code rather than a
--- promise in a comment.
function Broker:ensure(opts, callback)
  if type(opts) == 'function' then callback, opts = opts, {} end
  opts = opts or {}
  if not self.tunnel then return callback(nil) end
  if opts.start == false and not self.tunnel:is_ready() then
    return callback({
      kind = 'tunnel',
      cold = true,
      message = ('the %s forward is not open and this refresh may not open one; '
        .. 'refresh the tab manually'):format(self.source.tab_label),
    })
  end
  return self.tunnel:ensure(callback)
end

function Broker:hold()
  self.in_flight = self.in_flight + 1
end

function Broker:done()
  self.in_flight = math.max(0, self.in_flight - 1)
end

function Broker:busy()
  return self.in_flight > 0
end

--- Revoke everything this broker holds. `force` ignores in-flight work and is
--- only for VimLeavePre, where there is no later moment to close in.
function Broker:release(force)
  if self:busy() and not force then return false end
  self.capability.clear()
  if self.tunnel then self.tunnel:stop() end
  return true
end

--- The panel's provider list, in tab order.
---
--- @param raw table per-provider configuration keyed by source id
--- @param shared table values a provider may inherit when it sets none
---
--- A provider set to false is absent rather than disabled: there is no tab, no
--- client, and no capability cache for it. A provider left unset still gets a
--- tab, because an unconfigured broker that says what it is missing is more
--- useful than a surface the operator cannot find.
function M.build(raw, shared, handlers)
  local brokers = {}
  for _, id in ipairs(sources.ids()) do
    local source = sources.get(id)
    if raw[id] ~= false then
      local normalized, err = M.normalize(raw[id], source, shared)
      if not normalized then
        error(('mcp_buff.setup(): %s: %s'):format(id, err))
      end
      brokers[#brokers + 1] = M.new(source, normalized, handlers)
    end
  end
  if #brokers == 0 then
    error('mcp_buff.setup(): every broker is disabled, so there is nothing to review')
  end
  return brokers
end

M.Broker = Broker

return M
