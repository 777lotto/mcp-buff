if vim.g.loaded_mcp_buff then return end
vim.g.loaded_mcp_buff = true

vim.api.nvim_create_user_command('McpBuff', function(opts)
  require('mcp_buff').open(opts.args ~= '' and opts.args or nil)
end, {
  desc = 'Review broker write tickets',
  nargs = '?',
  complete = function()
    return require('mcp_buff.sources').ids()
  end,
})

vim.api.nvim_create_user_command('McpBuffPermissions', function(opts)
  require('mcp_buff').open_permissions(opts.args ~= '' and opts.args or nil)
end, {
  desc = 'Manage broker runtime permission subsets',
  nargs = '?',
  complete = function()
    return require('mcp_buff.sources').ids()
  end,
})
