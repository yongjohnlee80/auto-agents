if vim.g.loaded_auto_agents then
  return
end
vim.g.loaded_auto_agents = true

local teardown_group = vim.api.nvim_create_augroup("AutoAgentsTeardown", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = teardown_group,
  callback = function()
    pcall(function() require("auto-agents").teardown() end)
  end,
  desc = "Release auto-agents runtime resources before Neovim exits",
})

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

vim.keymap.set("n", "<F11>", function()
  local ok, ui = pcall(require, "auto-agents.diff.ui")
  if ok and ui then
    ui.toggle()
  else
    vim.notify("AutoAgentsDiffQueue: diff UI not available", vim.log.levels.ERROR)
  end
end, { desc = "Toggle unified diff queue" })

-- :AutoAgentsAdoptResumedAgent <slot>
--
-- ADR 0023 §3.3 Track C — host-side adopt-on-resume bridge. The
-- manual recovery path for the case where a resumed agent hasn't
-- detected its own identity drift (Track A/B mechanisms) yet, but
-- the USER realizes they just ran `/resume` and wants to reconcile
-- the slot's runtime identity with the live host.
--
-- Behavior:
--   1. Resolve `state.slot_terminals[<slot>]:pid()` → agent_pid.
--   2. Look up the slot's bootstrap agent name from
--      `state.config.agents.bootstrap`.
--   3. Register the mailbox at the live instance if not already
--      present (bare-id registration auto-resolves to the live
--      instance suffix per v0.1.8 path semantics).
--   4. Build the canonical sidecar identity record via
--      `auto-agents.runtime_identity.build_record`.
--   5. Atomic-write the sidecar to its canonical path
--      (`<stdpath('data')>/auto-agents/runtime-identity-<slot>.json`).
--   6. Inject a wake message into the agent's inbox containing the
--      preamble + sidecar path so the agent re-reads on next wake.
--
-- Counterpart to the agent-initiated `refresh_agent_id` mailbox
-- verb. Both end up writing the same sidecar; only the trigger
-- differs.
vim.api.nvim_create_user_command("AutoAgentsAdoptResumedAgent", function(opts)
  local raw_slot = opts.fargs[1]
  if not raw_slot or raw_slot == "" then
    vim.notify("AutoAgentsAdoptResumedAgent: <slot> required (e.g. `:AutoAgentsAdoptResumedAgent 5`)",
      vim.log.levels.ERROR)
    return
  end
  local slot = tonumber(raw_slot)
  if not slot then
    vim.notify("AutoAgentsAdoptResumedAgent: <slot> must be an integer (got '"
        .. tostring(raw_slot) .. "')", vim.log.levels.ERROR)
    return
  end

  local aa_ok, aa = pcall(require, "auto-agents")
  if not aa_ok then
    vim.notify("AutoAgentsAdoptResumedAgent: require('auto-agents') failed",
      vim.log.levels.ERROR)
    return
  end

  -- Resolve the slot's terminal + PID. The terminal must expose
  -- a `pid()` method per the AutoAgentsTerminalInstance contract.
  local term = aa.state and aa.state.slot_terminals
                  and aa.state.slot_terminals[slot]
  if not term then
    vim.notify(("AutoAgentsAdoptResumedAgent: slot %d has no live terminal"):format(slot),
      vim.log.levels.ERROR)
    return
  end
  local agent_pid
  if type(term.pid) == "function" then
    local pok, p = pcall(term.pid, term)
    if pok and type(p) == "number" then agent_pid = p end
  end
  -- agent_pid can be nil for terminals that haven't started or
  -- that don't expose .pid(). Sidecar still lands; pid field stays
  -- nil. Surface as a warning, don't abort.
  if not agent_pid then
    vim.notify(("AutoAgentsAdoptResumedAgent: slot %d terminal didn't report a PID; "
      .. "writing sidecar without it"):format(slot), vim.log.levels.WARN)
  end

  -- Look up the slot's bootstrap spec (need name + kind +
  -- diff_review for the identity reconcile call below).
  local agents_cfg = aa.state.config and aa.state.config.agents
                       and aa.state.config.agents.bootstrap or {}
  local matched_spec
  for _, a in ipairs(agents_cfg) do
    if tonumber(a.slot) == slot then
      matched_spec = a
      break
    end
  end
  if not matched_spec or not matched_spec.name then
    vim.notify(("AutoAgentsAdoptResumedAgent: slot %d has no registered agent name "
      .. "in state.config.agents.bootstrap"):format(slot), vim.log.levels.ERROR)
    return
  end
  local agent_name = matched_spec.name

  -- ADR 0029 Decision #3 — reconcile() owns per-kind mailbox root
  -- resolution, mailbox registration, and sidecar write. The
  -- pre-fix adopt path called mailbox.register without per-kind
  -- root and built the sidecar without the spec's diff_review flag,
  -- producing two off-by-one defects on resume:
  --   1. wake-message landed under host_fallback_root() instead of
  --      ~/.claude or ~/.codex etc.
  --   2. sidecar.diff_review was false even when the bootstrap row
  --      had diff_review = true.
  -- Both fixed by routing through the single seam.
  local identity_ok, identity = pcall(require, "auto-agents.runtime.identity")
  if not identity_ok then
    vim.notify("AutoAgentsAdoptResumedAgent: require('auto-agents.runtime.identity') failed",
      vim.log.levels.ERROR)
    return
  end
  local result = identity.reconcile({
    slot        = slot,
    agent_name  = agent_name,
    kind        = matched_spec.kind,
    diff_review = matched_spec.diff_review,
    agent_pid   = agent_pid,
    stamped_by  = "auto-agents:AutoAgentsAdoptResumedAgent",
    wake        = { command = "wake", args = { slot = agent_name } },
  })
  if not result.ok then
    vim.notify(("AutoAgentsAdoptResumedAgent: identity reconcile failed: %s"):format(
      tostring(result.detail or result.error or "unknown")),
      vim.log.levels.ERROR)
    return
  end
  local record = result.sidecar_record
  local sidecar_path = result.sidecar_path

  -- Inject a wake message into the agent's inbox so it sees the
  -- reconciliation preamble on next interaction. We write directly
  -- to the live inbox (bypassing the agent's outbox) because the
  -- whole point of adopt is that the agent's outbox may be stale.
  local inbox_dir = result.mailbox_record.dir .. "/inbox"
  vim.fn.mkdir(inbox_dir, "p")

  local mid = tostring(os.time()) .. "-adopt-resumed-" .. tostring(slot)
  local wake_msg = {
    id      = mid,
    kind    = "message",
    from    = "nvim",
    to      = "agent:" .. agent_name,
    subject = "[adopt-resumed-agent] runtime identity reconciled by host",
    body    = "Your runtime identity was reconciled by the host via "
      .. ":AutoAgentsAdoptResumedAgent. REPLACE every cached AUTO_AGENTS_* "
      .. "reference in your in-context memory with the values in the "
      .. "sidecar file at `" .. sidecar_path .. "`. See bootstrap-mailbox.md "
      .. "§Resumed-agent identity reconciliation for the protocol.",
    runtime_identity = record,
    runtime_identity_path = sidecar_path,
  }
  local tmp = inbox_dir .. "/" .. mid .. ".tmp"
  local final = inbox_dir .. "/" .. mid .. ".json"
  local f, ferr = io.open(tmp, "w")
  if not f then
    vim.notify(("AutoAgentsAdoptResumedAgent: wake-message open failed: %s")
        :format(tostring(ferr)), vim.log.levels.WARN)
  else
    f:write(vim.fn.json_encode(wake_msg))
    f:close()
    local rok = os.rename(tmp, final)
    if not rok then
      pcall(os.remove, tmp)
      vim.notify("AutoAgentsAdoptResumedAgent: wake-message rename failed",
        vim.log.levels.WARN)
    end
  end

  -- Surface success via the family logger so the entry lands in
  -- the auto-core ring alongside the audit trail.
  local log_ok, log = pcall(require, "auto-agents.log")
  if log_ok then
    log.notify(
      ("slot %d (%s) adopted — runtime identity reconciled. Sidecar: %s")
        :format(slot, agent_name, sidecar_path),
      { component = "adopt-resumed", level = "info",
        title = "auto-agents" })
  else
    vim.notify(("AutoAgentsAdoptResumedAgent: slot %d (%s) adopted; sidecar at %s")
        :format(slot, agent_name, sidecar_path), vim.log.levels.INFO)
  end
end, {
  nargs = "?",
  complete = function()
    -- Suggest live slot numbers from the current state.
    local aa_ok, aa = pcall(require, "auto-agents")
    if not aa_ok then return {} end
    local out = {}
    local slot_term = aa.state and aa.state.slot_terminals or {}
    for slot, _ in pairs(slot_term) do
      out[#out + 1] = tostring(slot)
    end
    table.sort(out, function(a, b) return tonumber(a) < tonumber(b) end)
    return out
  end,
  desc = "ADR 0023 §3.3 — host-side adopt-on-resume for a slot whose agent's "
    .. "AUTO_AGENTS_* env is fork-frozen (typically post-/resume). Writes the "
    .. "canonical sidecar identity file and injects a wake message into the "
    .. "agent's inbox so it re-reads on next wake. Use when the agent itself "
    .. "hasn't detected the drift yet.",
})
