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

vim.api.nvim_create_user_command("AutoAgentsFocus", function(opts)
  local slot = tonumber(opts.fargs[1])
  if not slot then
    vim.notify("AutoAgentsFocus: argument must be a slot number 0..9", vim.log.levels.ERROR)
    return
  end
  require("auto-agents").focus_slot(slot)
end, {
  nargs = 1,
  desc = "Focus a slot — 0 admin, 1..N main agents (N = cfg.panel.slot_count)",
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

-- Snapshot of every observed slot's status. Plain-text, one slot per
-- line: "slot <N> <name> (<kind>) — <state>". Designed to be easy for
-- a manager agent to parse via :execute("AutoAgentsStatusReport") +
-- a redir capture, or for the user to glance at.
vim.api.nvim_create_user_command("AutoAgentsStatusReport", function()
  local report = require("auto-agents").status_report()
  if #report == 0 then
    print("(no agents running)")
    return
  end
  for _, line in ipairs(report) do print(line) end
end, {
  desc = "Print a snapshot of every running agent's status",
})

-- Manually sync the running model of one slot (or the focused slot)
-- to its TOML config. Reads the model from the terminal buffer via the
-- status/model_reader, then calls agent.set_model. Useful when
-- auto-sync hasn't fired yet or the user wants an immediate write.
vim.api.nvim_create_user_command("AutoAgentsModelSync", function(opts)
  local aa = require("auto-agents")
  local obs_mod = require("auto-agents.status.observer")
  local reader = require("auto-agents.status.model_reader")
  local agent = require("auto-agents.agent")

  -- Resolve slot: explicit arg, or focused slot.
  local slot
  if opts.fargs[1] then
    slot = tonumber(opts.fargs[1])
    if not slot then
      vim.notify("AutoAgentsModelSync: slot must be a number", vim.log.levels.ERROR)
      return
    end
  else
    slot = aa.state.focused_slot or 1
  end

  -- Get the terminal buf for this slot.
  local term = aa.state.slot_terminals and aa.state.slot_terminals[slot]
  local bufnr = term and term.get_bufnr and term:get_bufnr()
  if not bufnr then
    -- Fallback: check observer.
    local obs = obs_mod._by_slot[slot]
    bufnr = obs and obs.bufnr
  end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    vim.notify("AutoAgentsModelSync: no live terminal for slot " .. slot, vim.log.levels.WARN)
    return
  end

  -- Resolve kind from bootstrap.
  local kind
  local cfg = aa.state.config
  for _, e in ipairs((cfg and cfg.agents and cfg.agents.bootstrap) or {}) do
    if e.slot == slot then kind = e.kind; break end
  end
  if not kind then
    vim.notify("AutoAgentsModelSync: slot " .. slot .. " not in bootstrap config", vim.log.levels.WARN)
    return
  end

  local info = reader.read(bufnr, kind)
  if not info then
    vim.notify("AutoAgentsModelSync: could not read model from terminal (status line not visible?)", vim.log.levels.WARN)
    return
  end

  -- Find agent name for this slot.
  local name
  for _, e in ipairs((cfg and cfg.agents and cfg.agents.bootstrap) or {}) do
    if e.slot == slot then name = e.name; break end
  end
  if not name then
    vim.notify("AutoAgentsModelSync: no agent name for slot " .. slot, vim.log.levels.WARN)
    return
  end

  local ok, msg = agent.set_model(name, info.api_id)
  if ok then
    -- Also update the observer's last_synced_model so auto-sync
    -- doesn't immediately re-fire.
    local obs = obs_mod._by_slot[slot]
    if obs then obs.last_synced_model = info.api_id end
    vim.notify("AutoAgentsModelSync: " .. msg, vim.log.levels.INFO)
  else
    vim.notify("AutoAgentsModelSync: " .. msg, vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  complete = function()
    local out = {}
    for n = 1, 9 do out[#out + 1] = tostring(n) end
    return out
  end,
  desc = "Sync the focused slot's running model to its TOML config entry",
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

vim.api.nvim_create_user_command("AutoAgentsDiffQueue", function()
  local ok, ui = pcall(require, "auto-agents.diff.ui")
  if ok and ui then
    ui.toggle()
  else
    vim.notify("AutoAgentsDiffQueue: diff UI not available", vim.log.levels.ERROR)
  end
end, {
  desc = "Toggle the unified diff queue for reviewing agent proposals",
})

vim.api.nvim_create_user_command("AutoAgentsDiffSubmit", function(opts)
  local agent_name = opts.fargs[1]
  local file_path = opts.fargs[2]
  local proposal_path = opts.fargs[3]
  local tab_name = opts.fargs[4]

  if not agent_name or not file_path or not proposal_path then
    vim.notify(
      "AutoAgentsDiffSubmit: usage: :AutoAgentsDiffSubmit[!] <agent> <target-file> <proposal-file> [tab-name]",
      vim.log.levels.ERROR
    )
    return
  end

  if opts.bang then
    local result = require("auto-agents.diff.submit").submit_file_and_wait({
      agent_name = agent_name,
      file_path = file_path,
      proposal_path = proposal_path,
      tab_name = tab_name,
    })
    local encode = (vim.json and vim.json.encode) or vim.fn.json_encode
    print(encode(result))
    return
  end

  local id, err = require("auto-agents.diff.submit").enqueue_file({
    agent_name = agent_name,
    file_path = file_path,
    proposal_path = proposal_path,
    tab_name = tab_name,
  })

  if not id then
    vim.notify("AutoAgentsDiffSubmit: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.notify("Queued diff " .. id .. " from " .. agent_name, vim.log.levels.INFO)
end, {
  nargs = "+",
  bang = true,
  complete = "file",
  desc = "Submit a proposed file image into the unified diff queue",
})

vim.keymap.set("n", "<F11>", function()
  local ok, ui = pcall(require, "auto-agents.diff.ui")
  if ok and ui then
    ui.toggle()
  else
    vim.notify("AutoAgentsDiffQueue: diff UI not available", vim.log.levels.ERROR)
  end
end, { desc = "Toggle unified diff queue" })
