if vim.g.loaded_auto_agents then
  return
end
vim.g.loaded_auto_agents = true

vim.api.nvim_create_user_command("AutoAgents", function(opts)
  require("auto-agents").toggle(opts.bang)
end, {
  bang = true,
  desc = "Toggle the auto-agents main window (! to bypass host-width guard)",
})

vim.api.nvim_create_user_command("AutoAgentsSub", function(opts)
  local slot = tonumber(opts.fargs[1])
  if not slot then
    vim.notify("AutoAgentsSub: argument must be a slot number 5..9", vim.log.levels.ERROR)
    return
  end
  require("auto-agents").toggle_sub(slot)
end, {
  nargs = 1,
  desc = "Toggle a sub-agent float (slots 5..9)",
})

vim.api.nvim_create_user_command("AutoAgentsFocus", function(opts)
  local slot = tonumber(opts.fargs[1])
  if not slot then
    vim.notify("AutoAgentsFocus: argument must be a slot number 0..9", vim.log.levels.ERROR)
    return
  end
  require("auto-agents").focus_slot(slot)
end, {
  nargs = 1,
  desc = "Focus a slot — 0..4 main window, 5..9 sub-agent floats (D17)",
})

vim.api.nvim_create_user_command("AutoAgentsDock", function()
  require("auto-agents").dock_toggle()
end, {
  desc = "Toggle the auto-agents navigation dock (rightmost float, single-key dispatch)",
})

vim.api.nvim_create_user_command("AutoAgentsProject", function(opts)
  local sub = opts.fargs[1]
  local args = {}
  for i = 2, #opts.fargs do args[#args + 1] = opts.fargs[i] end
  require("auto-agents.project").dispatch(sub, args, nil)
end, {
  nargs = "*",
  complete = function(_, line)
    local subs = { "init", "import", "remove", "list", "show", "help" }
    local n_words = #vim.split(line, "%s+", { trimempty = true })
    if n_words <= 2 then return subs end
    return {}
  end,
  desc = "Manage auto-agents project config (init|import|remove|list|show)",
})
