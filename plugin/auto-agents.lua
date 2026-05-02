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

vim.api.nvim_create_user_command("AutoAgentsTerm", function(opts)
  local sub = opts.fargs[1] or "list"
  local term = require("auto-agents.term")
  local focus = require("auto-agents.term.focus")
  if sub == "focus" then
    local slot = tonumber(opts.fargs[2])
    if not slot then vim.notify("AutoAgentsTerm focus: needs slot 1..4", vim.log.levels.ERROR); return end
    focus.focus_or_hide(slot)
  elseif sub == "send" then
    local slot = tonumber(opts.fargs[2])
    if not slot then vim.notify("AutoAgentsTerm send: needs slot 1..4", vim.log.levels.ERROR); return end
    local text = table.concat(vim.list_slice(opts.fargs, 3), " ")
    term.send(slot, text)
  elseif sub == "list" then
    for _, e in ipairs(term.list()) do
      print(string.format("  T%d  alive=%s visible=%s focused=%s buf=%s",
        e.slot, tostring(e.alive), tostring(e.visible), tostring(e.focused), tostring(e.bufnr)))
    end
  elseif sub == "kill" then
    local slot = tonumber(opts.fargs[2])
    if not slot then vim.notify("AutoAgentsTerm kill: needs slot 1..4", vim.log.levels.ERROR); return end
    print(term.kill(slot) and ("killed T" .. slot) or ("T" .. slot .. " has no terminal"))
  elseif sub == "hide" then
    term.hide_all()
  else
    vim.notify("AutoAgentsTerm: unknown subcommand '" .. sub
      .. "' — try focus|send|list|kill|hide", vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  complete = function(_, line)
    local n = #vim.split(line, "%s+", { trimempty = true })
    if n <= 2 then return { "focus", "send", "list", "kill", "hide" } end
    if n == 3 then return { "1", "2", "3", "4" } end
    return {}
  end,
  desc = "Auto-agents playground terminals (T1..T4)",
})

vim.api.nvim_create_user_command("AutoAgentsTermSend", function(opts)
  local slot = tonumber(opts.fargs[1])
  if not slot then vim.notify("AutoAgentsTermSend: needs slot 1..4", vim.log.levels.ERROR); return end
  local text = table.concat(vim.list_slice(opts.fargs, 2), " ")
  if text == "" then vim.notify("AutoAgentsTermSend: empty text", vim.log.levels.ERROR); return end
  require("auto-agents.term").send(slot, text)
end, {
  nargs = "+",
  desc = "Paste-safe send to a playground terminal (slot 1..4)",
})

vim.api.nvim_create_user_command("AutoAgentsStatus", function(opts)
  local target = opts.fargs[1]
  local state = opts.fargs[2]
  if not target or not state then
    vim.notify(
      "AutoAgentsStatus: usage — :AutoAgentsStatus <slot|name> <idle|waiting|working>",
      vim.log.levels.ERROR)
    return
  end
  local slot_or_name = tonumber(target) or target
  local ok, msg = require("auto-agents").set_status(slot_or_name, state)
  -- Status pings fire often (working → idle on every tool round-trip);
  -- keep success quiet, surface only failures.
  if not ok then
    vim.notify("AutoAgentsStatus: " .. msg, vim.log.levels.ERROR)
  end
end, {
  nargs = "+",
  complete = function(_, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    -- words = { "AutoAgentsStatus", <target?>, <state?> }
    if #words <= 2 then
      local out = require("auto-agents.agent").names()
      for n = 0, 9 do out[#out + 1] = tostring(n) end
      return out
    end
    if #words == 3 then
      return { "idle", "waiting", "working" }
    end
    return {}
  end,
  desc = "Set an agent slot's runtime status (idle|waiting|working) — "
    .. "agents typically self-report via remote-expr",
})

vim.api.nvim_create_user_command("AutoAgentsModel", function(opts)
  local name = opts.fargs[1]
  local model = opts.fargs[2]
  if not name then
    vim.notify(
      "AutoAgentsModel: usage — :AutoAgentsModel <name> [<model>|-]",
      vim.log.levels.ERROR)
    return
  end
  local ok, msg = require("auto-agents.agent").set_model(name, model)
  vim.notify("AutoAgentsModel: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end, {
  nargs = "+",
  complete = function(_, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    -- words = { "AutoAgentsModel", <name?>, <model?> }
    if #words <= 2 then
      return require("auto-agents.agent").names()
    end
    return {}
  end,
  desc = "Set, show, or clear an agent's preferred model "
    .. "(writes to TOML config; effective next restart)",
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
