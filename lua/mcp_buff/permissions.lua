-- Provider-aware runtime permissions panel.
--
-- This edits only the effective subset exposed by each broker's reviewed
-- release. It cannot alter GitHub App permissions, Cloudflare API-token scopes,
-- credentials, routes, or firewall policy. Each provider owns a distinct
-- capability cache, client, and optional SSH tunnel.

local api, fn = vim.api, vim.fn
local capability_module = require('mcp_buff.capability')
local client_module = require('mcp_buff.client')
local tunnel_module = require('mcp_buff.tunnel')

local M = {
  buf = nil,
  win = nil,
  line_map = {},
  providers = {},
}

local PANEL_WIDTH = 104
local namespace = api.nvim_create_namespace('mcp-buff-permissions')
local lifecycle_group = api.nvim_create_augroup('McpBuffPermissionsLifecycle', { clear = true })
local request_generation = 0
local close_provider_session

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function find_window()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return nil end
  for _, window in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(window) == M.buf then return window end
  end
  return nil
end

local function with_writable(callback)
  api.nvim_set_option_value('modifiable', true, { buf = M.buf })
  local ok, err = pcall(callback)
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  if not ok then error(err) end
end

local function baseline(snapshot)
  local enabled = {}
  for _, permission in ipairs(snapshot.permissions or {}) do
    enabled[permission.id] = permission.enabled == true
  end
  return enabled
end

local function is_dirty(provider)
  if not provider.snapshot then return false end
  for _, permission in ipairs(provider.snapshot.permissions) do
    if permission.enabled ~= provider.baseline[permission.id] then return true end
  end
  return false
end

local function changed_count(provider)
  local count = 0
  if not provider.snapshot then return count end
  for _, permission in ipairs(provider.snapshot.permissions) do
    if permission.enabled ~= provider.baseline[permission.id] then count = count + 1 end
  end
  return count
end

local function compact(value, width)
  value = trim(tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '))
  if #value <= width then return value end
  return value:sub(1, math.max(1, width - 1)) .. '…'
end

local function render()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return end
  local width = PANEL_WIDTH
  local window = find_window()
  if window then width = math.max(72, api.nvim_win_get_width(window) - 2) end

  local lines = {
    'MCP Buff · Broker Permissions',
    'Runtime subset only — provider credentials and reviewed ceilings are never changed.',
    'Space/Enter toggle  ·  a apply with typed digest  ·  r refresh  ·  q close',
    '',
  }
  local map, highlights = {}, {}
  for _, provider in ipairs(M.providers) do
    local state = provider.applying and 'applying…'
      or provider.loading and 'loading…'
      or provider.outcome_unknown and 'apply outcome unknown'
      or provider.error and 'unavailable'
      or provider.snapshot and (is_dirty(provider) and ('%d unsaved change(s)'):format(
        changed_count(provider)) or 'saved')
      or 'not loaded'
    local header_line = #lines + 1
    lines[header_line] = ('%s  [%s]'):format(provider.title, state)
    highlights[#highlights + 1] = { line = header_line - 1, group = 'McpBuffHeader' }
    if not provider.configured then
      lines[#lines + 1] = '  Configure a separate capability_cmd for this provider in setup().'
    else
      if provider.error then
        lines[#lines + 1] = '  ' .. compact(provider.error, width - 4)
      end
    end
    if provider.configured and provider.snapshot then
      lines[#lines + 1] = ('  state %s…%s'):format(
        provider.snapshot.permissions_sha256:sub(1, 8),
        provider.snapshot.permissions_sha256:sub(-8))
      if provider.outcome_unknown then
        lines[#lines + 1] = '  APPLY OUTCOME UNKNOWN — refresh before making another change.'
      elseif provider.must_refresh then
        lines[#lines + 1] = '  STATE MAY BE STALE — refresh before changing or applying.'
      end
      for index, permission in ipairs(provider.snapshot.permissions) do
        local line = #lines + 1
        local marker = permission.enabled and '[x]' or '[ ]'
        lines[line] = ('  %s %-32s %s'):format(
          marker, compact(permission.title, 32),
          compact(permission.description, math.max(18, width - 42)))
        map[line] = { provider = provider, index = index }
        highlights[#highlights + 1] = {
          line = line - 1,
          group = permission.enabled and 'McpBuffPermissionEnabled'
            or 'McpBuffPermissionDisabled',
        }
        lines[#lines + 1] = '      ' .. permission.id
      end
    end
    lines[#lines + 1] = ''
  end

  M.line_map = map
  with_writable(function()
    api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  end)
  api.nvim_buf_clear_namespace(M.buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    api.nvim_buf_set_extmark(M.buf, namespace, highlight.line, 0, {
      end_col = #(lines[highlight.line + 1] or ''),
      hl_group = highlight.group,
    })
  end
end

local function ensure_transport(provider, callback)
  if provider.ensure_transport then return provider.ensure_transport(callback) end
  if not provider.tunnel then return callback(nil) end
  provider.tunnel:ensure(callback)
end

local function refresh_provider(provider, generation, allow_fetch)
  if not provider.configured then
    provider.loading = false
    provider.error = nil
    render()
    return
  end
  provider.loading = true
  provider.error = nil
  render()
  ensure_transport(provider, function(transport_error)
    if generation ~= request_generation then return end
    if transport_error then
      provider.loading = false
      provider.error = transport_error.message
      render()
      return
    end
    provider.client:get_permissions({ allow_capability_fetch = allow_fetch }, function(err, snapshot)
      if generation ~= request_generation then return end
      provider.loading = false
      if err then
        provider.error = err.message
        provider.must_refresh = provider.snapshot ~= nil
      else
        provider.snapshot = snapshot
        provider.baseline = baseline(snapshot)
        provider.outcome_unknown = false
        provider.must_refresh = false
        provider.error = nil
      end
      render()
    end)
  end)
end

function M.refresh(opts)
  opts = opts or {}
  for _, provider in ipairs(M.providers) do
    if provider.applying then
      vim.notify('McpBuff: wait for the permission update before refreshing',
        vim.log.levels.WARN)
      return
    end
  end
  request_generation = request_generation + 1
  local generation = request_generation
  for _, provider in ipairs(M.providers) do
    refresh_provider(provider, generation, opts.allow_capability_fetch)
  end
end

local function current_permission()
  local window = find_window()
  if not window then return nil end
  return M.line_map[api.nvim_win_get_cursor(window)[1]]
end

function M.toggle()
  local current = current_permission()
  if not current then
    vim.notify('McpBuff: move the cursor onto a permission', vim.log.levels.INFO)
    return
  end
  local provider = current.provider
  if provider.loading or provider.applying then return end
  if provider.must_refresh then
    vim.notify('McpBuff: refresh this provider before making another change',
      vim.log.levels.ERROR)
    return
  end
  local permission = provider.snapshot.permissions[current.index]
  permission.enabled = not permission.enabled
  render()
end

local function desired_enabled(provider)
  local enabled = {}
  for _, permission in ipairs(provider.snapshot.permissions) do
    if permission.enabled then enabled[#enabled + 1] = permission.id end
  end
  return enabled
end

local function confirm_apply(provider)
  local suffix = provider.snapshot.permissions_sha256:sub(-8)
  fn.inputsave()
  local ok, answer = pcall(fn.input,
    ('Type current state digest %s to apply %d %s change(s): '):format(
      suffix, changed_count(provider), provider.title))
  fn.inputrestore()
  vim.cmd('redraw')
  return ok and trim(answer) == suffix
end

function M.apply()
  local current = current_permission()
  if not current then
    vim.notify('McpBuff: move the cursor onto the provider permission set to apply',
      vim.log.levels.INFO)
    return
  end
  local provider = current.provider
  if provider.applying then return end
  if provider.must_refresh then
    vim.notify('McpBuff: refresh this provider before applying', vim.log.levels.ERROR)
    return
  end
  if not is_dirty(provider) then
    vim.notify('McpBuff: this provider has no permission changes', vim.log.levels.INFO)
    return
  end
  if not confirm_apply(provider) then
    vim.notify('McpBuff: permission update cancelled; the typed digest did not match',
      vim.log.levels.WARN)
    return
  end

  provider.applying = true
  render()
  ensure_transport(provider, function(transport_error)
    if transport_error then
      provider.applying = false
      provider.error = transport_error.message
      render()
      if provider.close_when_settled or not find_window() then
        provider.close_when_settled = false
        close_provider_session(provider)
      end
      return
    end
    provider.client:update_permissions(provider.snapshot, desired_enabled(provider),
      function(err, snapshot)
        provider.applying = false
        if err then
          provider.error = err.message
          provider.outcome_unknown = err.definitive ~= true
          provider.must_refresh = true
          vim.notify('McpBuff: permission update failed — ' .. err.message,
            vim.log.levels.ERROR)
        else
          provider.snapshot = snapshot
          provider.baseline = baseline(snapshot)
          provider.outcome_unknown = false
          provider.must_refresh = false
          provider.error = nil
          vim.notify(('McpBuff: %s runtime permissions updated'):format(provider.title),
            vim.log.levels.INFO)
        end
        render()
        if provider.close_when_settled or not find_window() then
          provider.close_when_settled = false
          close_provider_session(provider)
        end
      end)
  end)
end

close_provider_session = function(provider)
  if not provider.shared then provider.capability.clear() end
  if provider.tunnel then provider.tunnel:stop() end
  if provider.release_transport then provider.release_transport() end
end

local function stop_sessions(force)
  request_generation = request_generation + 1
  for _, provider in ipairs(M.providers) do
    if provider.applying and not force then
      provider.close_when_settled = true
    else
      close_provider_session(provider)
    end
  end
end

function M.close()
  local window = find_window()
  if window then pcall(api.nvim_win_close, window, true) end
  M.win = nil
  stop_sessions()
end

local function attach_keys()
  local function map(lhs, callback, description)
    vim.keymap.set('n', lhs, callback, {
      buffer = M.buf,
      nowait = true,
      silent = true,
      desc = 'McpBuff permissions: ' .. description,
    })
  end
  for _, key in ipairs({ '<Space>', '<CR>', '<NL>', '<kEnter>' }) do
    map(key, M.toggle, 'toggle permission')
  end
  map('a', M.apply, 'apply provider permissions')
  map('r', M.refresh, 'refresh providers')
  map('q', M.close, 'close panel')
end

local function ensure_buffer()
  if M.buf and api.nvim_buf_is_valid(M.buf) then return M.buf end
  M.buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value('buftype', 'nofile', { buf = M.buf })
  api.nvim_set_option_value('bufhidden', 'hide', { buf = M.buf })
  api.nvim_set_option_value('swapfile', false, { buf = M.buf })
  api.nvim_set_option_value('undofile', false, { buf = M.buf })
  api.nvim_set_option_value('buflisted', false, { buf = M.buf })
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  api.nvim_set_option_value('filetype', 'mcpbuff-permissions', { buf = M.buf })
  pcall(api.nvim_buf_set_name, M.buf, 'mcpbuff://permissions')
  api.nvim_create_autocmd({ 'BufHidden', 'BufWipeout' }, {
    group = lifecycle_group,
    buffer = M.buf,
    callback = function()
      vim.schedule(function()
        if not find_window() then stop_sessions() end
      end)
    end,
  })
  attach_keys()
  return M.buf
end

function M.open()
  ensure_buffer()
  local existing = find_window()
  if existing then
    M.win = existing
    api.nvim_set_current_win(existing)
    M.refresh()
    return
  end
  vim.cmd('topleft vsplit')
  M.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.win, M.buf)
  api.nvim_win_set_width(M.win, math.min(PANEL_WIDTH, math.max(40, vim.o.columns - 8)))
  api.nvim_set_option_value('number', false, { win = M.win })
  api.nvim_set_option_value('relativenumber', false, { win = M.win })
  api.nvim_set_option_value('signcolumn', 'no', { win = M.win })
  api.nvim_set_option_value('cursorline', true, { win = M.win })
  api.nvim_set_option_value('wrap', false, { win = M.win })
  api.nvim_set_option_value('winfixwidth', true, { win = M.win })
  render()
  M.refresh()
end

local function normalize_provider(id, title, raw, shared)
  local endpoint, endpoint_error = client_module.normalize_endpoint(raw.endpoint)
  if not endpoint then return nil, endpoint_error end
  local capability_cmd, capability_error = capability_module.normalize_cmd(raw.capability_cmd)
  if capability_error then return nil, capability_error end
  if type(raw.curl_command) ~= 'string' or trim(raw.curl_command) == '' then
    return nil, 'curl_command must be a non-empty string'
  end
  if raw.host_header ~= nil and (type(raw.host_header) ~= 'string'
      or raw.host_header:match('^127%.0%.0%.1:%d+$') == nil) then
    return nil, 'host_header must look like 127.0.0.1:PORT'
  end
  local ttl = math.floor(tonumber(raw.capability_ttl) or capability_module.DEFAULT_TTL_SECONDS)
  if ttl < 0 then return nil, 'capability_ttl must be zero or positive' end
  local tunnel_config, tunnel_error = tunnel_module.normalize(raw.tunnel, endpoint)
  if tunnel_error then return nil, tunnel_error end
  local provider_capability = shared and shared.capability
    or capability_module.new({ cmd = capability_cmd, ttl = ttl })
  local provider = {
    id = id,
    title = title,
    configured = capability_cmd ~= nil,
    capability = provider_capability,
    client = client_module.new({
      endpoint = endpoint,
      curl_command = raw.curl_command,
      timeout = raw.timeout,
      host_header = raw.host_header,
      capability = provider_capability,
      permission_provider = id,
    }),
    baseline = {},
    shared = shared ~= nil,
    ensure_transport = shared and shared.ensure_transport or nil,
    release_transport = shared and shared.release_transport or nil,
  }
  if tunnel_config and not shared then
    provider.tunnel = tunnel_module.new(tunnel_config, {
      on_exit = function(err)
        provider_capability.clear()
        provider.error = err.message
        render()
      end,
    })
  end
  return provider
end

function M.configure(raw, inherited, shared)
  raw = raw or {}
  if type(raw) ~= 'table' then error('mcp_buff.setup(): permissions must be a table') end
  for key in pairs(raw) do
    if key ~= 'cloudflare' and key ~= 'github' then
      error(('mcp_buff.setup(): permissions.%s is not supported'):format(tostring(key)))
    end
  end
  for _, provider in ipairs(M.providers) do
    if provider.applying then
      error('mcp_buff.setup(): cannot reconfigure while a permission update is in progress')
    end
  end
  local providers = {}

  if raw.cloudflare ~= false then
    if raw.cloudflare ~= nil and type(raw.cloudflare) ~= 'table' then
      error('mcp_buff.setup(): permissions.cloudflare must be a table or false')
    end
    if raw.cloudflare ~= nil and next(raw.cloudflare) ~= nil then
      error('mcp_buff.setup(): permissions.cloudflare inherits the main broker '
        .. 'configuration and accepts only {} or false')
    end
    local config = vim.deepcopy(inherited)
    local provider, err = normalize_provider(
      'cloudflare', 'Cloudflare broker', config, shared)
    if not provider then error('mcp_buff.setup(): permissions.cloudflare: ' .. err) end
    providers[#providers + 1] = provider
  end

  local github = raw.github
  if github ~= false then
    if github ~= nil and type(github) ~= 'table' then
      error('mcp_buff.setup(): permissions.github must be a table or false')
    end
    local allowed = {
      endpoint = true,
      curl_command = true,
      timeout = true,
      capability_ttl = true,
      capability_cmd = true,
      host_header = true,
      tunnel = true,
    }
    for key in pairs(github or {}) do
      if not allowed[key] then
        error(('mcp_buff.setup(): permissions.github.%s is not supported')
          :format(tostring(key)))
      end
    end
    local defaults = {
      endpoint = 'http://127.0.0.1:8793',
      curl_command = inherited.curl_command,
      timeout = inherited.timeout,
      capability_ttl = inherited.capability_ttl,
      capability_cmd = nil,
      host_header = nil,
      tunnel = false,
    }
    local provider, err = normalize_provider('github', 'GitHub broker',
      vim.tbl_deep_extend('force', defaults, github or {}))
    if not provider then error('mcp_buff.setup(): permissions.github: ' .. err) end
    providers[#providers + 1] = provider
  end
  stop_sessions()
  M.providers = providers
  render()
end

function M.uses_shared_session()
  for _, provider in ipairs(M.providers) do
    if provider.shared and provider.configured
      and (find_window() ~= nil or provider.applying) then return true end
  end
  return false
end

function M.define_highlights()
  api.nvim_set_hl(0, 'McpBuffPermissionEnabled', { link = 'DiagnosticOk', default = true })
  api.nvim_set_hl(0, 'McpBuffPermissionDisabled', { link = 'Comment', default = true })
end

M.define_highlights()
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('McpBuffPermissionHighlights', { clear = true }),
  callback = M.define_highlights,
})
api.nvim_create_autocmd('VimLeavePre', {
  group = lifecycle_group,
  callback = function() stop_sessions(true) end,
})

return M
