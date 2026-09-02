if vim.g.loaded_mcp_buff then return end
vim.g.loaded_mcp_buff = true

vim.api.nvim_create_user_command('McpBuff', function()
  require('mcp_buff').open()
end, { desc = 'Review Cloudflare write tickets' })

vim.api.nvim_create_user_command('McpBuffPermissions', function()
  require('mcp_buff').open_permissions()
end, { desc = 'Manage broker runtime permission subsets' })
