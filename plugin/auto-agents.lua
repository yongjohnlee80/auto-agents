if vim.g.loaded_auto_agents then
  return
end
vim.g.loaded_auto_agents = true

vim.api.nvim_create_user_command("AutoAgents", function(opts)
  require("auto-agents").toggle(opts.bang)
end, {
  bang = true,
  desc = "Toggle the auto-agents panel (! to bypass host-width guard)",
})
