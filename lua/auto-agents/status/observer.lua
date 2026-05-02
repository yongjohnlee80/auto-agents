---Passive per-slot status observer.
---
---Each agent is a Neovim terminal buffer. We attach a buffer change
---watcher (`nvim_buf_attach`'s `on_lines`) that bumps a `last_activity`
---timestamp every time the TUI prints output, plus a libuv timer that
---ticks every `TICK_MS` and reduces the timestamps + visible-buffer
---patterns to a state in {idle, working, waiting}. The state is pushed
---through the existing `M.set_status()` API so winbar/dock refresh
---paths are unchanged.
---
---Why passive: agent self-reports via `:AutoAgentsStatus` are unreliable
---— the agent has to remember, and exit-states like a crashed REPL or a
---blocked permission prompt don't get reported at all. Observation is
---reality; self-reports become an optional override (a "sticky waiting"
---pin survives until the next user-driven activity).
---
---Lifecycle:
---  attach(slot, bufnr, kind) — called once per spawn from
---  ensure_main_slot_terminal / sub-slot float spawn. Idempotent: a
---  second attach on the same slot detaches the old observer first.
---
---  detach(slot) — called from the spawn paths' on_exit. Stops the
---  timer and clears state.
---
---@module 'auto-agents.status.observer'

local M = {}

-- Tunables.
local TICK_MS = 250            -- timer cadence
local IDLE_AFTER_MS = 1500     -- output silence threshold → drop to idle
local WAITING_QUIET_MS = 600   -- waiting-pattern only counts after this much silence
local MODEL_CHECK_TICKS = 30   -- check for model drift every N ticks (~7.5s)

---@class AutoAgentsStatusObserver
---@field slot integer
---@field bufnr integer
---@field kind string
---@field last_activity number  -- vim.uv.now() ms
---@field detached boolean
---@field timer userdata|nil    -- uv timer handle
---@field user_pin "waiting"|nil  -- explicit override from :AutoAgentsStatus waiting
---@field last_emitted "idle"|"working"|"waiting"|nil
---@field tick_count integer         -- incremented each timer tick
---@field last_synced_model string|nil  -- last model we confirmed matches TOML

---@type table<integer, AutoAgentsStatusObserver>
M._by_slot = {}

-- ── model drift detection ─────────────────────────────────────────────────

---Resolve the agent name for a slot (needed by agent.set_model).
---@param slot integer
---@return string|nil
local function name_for_slot(slot)
  local cfg = (require("auto-agents").state or {}).config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == slot then return e.name end
  end
  return nil
end

---Return the TOML-configured model API ID for a slot, or nil (CLI default).
---@param slot integer
---@return string|nil
local function toml_model_for_slot(slot)
  local cfg = (require("auto-agents").state or {}).config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == slot then return e.model or nil end
  end
  return nil
end

---Check whether the running model differs from the TOML config and,
---if so, sync the TOML and notify the user.
---@param obs AutoAgentsStatusObserver
local function check_model_drift(obs)
  local ok, reader = pcall(require, "auto-agents.status.model_reader")
  if not ok then return end

  local info = reader.read(obs.bufnr, obs.kind)
  if not info then return end  -- status line not parseable yet

  local running = info.api_id
  if running == obs.last_synced_model then return end  -- no change since last check

  local toml_model = toml_model_for_slot(obs.slot)
  if running == toml_model then
    -- Already in sync (e.g. first tick after spawn with correct model).
    obs.last_synced_model = running
    return
  end

  -- Drift detected — running model ≠ TOML. Auto-sync.
  local name = name_for_slot(obs.slot)
  if not name then return end

  local agent = require("auto-agents.agent")
  local synced_ok, msg = agent.set_model(name, running)
  if synced_ok then
    obs.last_synced_model = running
    local prev = toml_model or "(CLI default)"
    vim.notify(
      string.format("auto-agents: %s model synced  %s → %s", name, prev, running),
      vim.log.levels.INFO,
      { title = "auto-agents" }
    )
  else
    vim.notify(
      string.format("auto-agents: model sync failed for %s — %s", name, msg),
      vim.log.levels.WARN,
      { title = "auto-agents" }
    )
  end
end

local function now_ms()
  return vim.uv and vim.uv.now() or vim.loop.now()
end

---Resolve the current "ground truth" state for an observer.
---@param obs AutoAgentsStatusObserver
---@return "idle"|"working"|"waiting"
local function classify(obs)
  local elapsed = now_ms() - obs.last_activity

  -- Sticky user pin (explicit `:AutoAgentsStatus N waiting`) survives
  -- until output resumes, then auto-clears. Lets agents who need to
  -- explicitly flag user-input-required do so even if our regex misses.
  if obs.user_pin == "waiting" and elapsed > 200 then
    return "waiting"
  end

  if elapsed < IDLE_AFTER_MS then
    -- Output is currently flowing → working. Don't bother pattern-
    -- matching for waiting; the prompt isn't stable yet.
    return "working"
  end

  -- Quiet long enough to inspect the rendered prompt.
  if elapsed >= WAITING_QUIET_MS then
    local ok, patterns = pcall(require, "auto-agents.status.patterns")
    if ok then
      local inferred = patterns.classify(obs.bufnr, obs.kind)
      if inferred == "waiting" then return "waiting" end
      -- Working from pattern only fires if activity is also recent;
      -- a stale "esc to interrupt" line shouldn't keep us pinned to
      -- working forever after the agent finished.
    end
  end

  return "idle"
end

---Push the classified state into auto-agents' shared store, but only
---on transitions — avoids a refresh storm.
---@param obs AutoAgentsStatusObserver
local function emit_if_changed(obs)
  local state = classify(obs)
  if state == obs.last_emitted then return end
  obs.last_emitted = state
  -- Avoid pulling auto-agents at module load to dodge cycles. Inline
  -- the slot store update + UI refresh.
  local aa = require("auto-agents")
  aa.state.agent_status = aa.state.agent_status or {}
  if state == "idle" then
    aa.state.agent_status[obs.slot] = nil
  else
    aa.state.agent_status[obs.slot] = state
  end
  if aa.refresh_winbar then pcall(aa.refresh_winbar) end
  if aa.refresh_dock then pcall(aa.refresh_dock) end
end

---Detach the observer for a slot, freeing its timer + buffer watcher.
---Idempotent.
---@param slot integer
function M.detach(slot)
  local obs = M._by_slot[slot]
  if not obs then return end
  obs.detached = true
  if obs.timer then
    pcall(obs.timer.stop, obs.timer)
    pcall(obs.timer.close, obs.timer)
    obs.timer = nil
  end
  M._by_slot[slot] = nil
  -- Don't clear agent_status here — the spawn-path's own on_exit
  -- already does that, and clearing here would race with re-attaches
  -- on slot recovery.
end

---Attach an observer to a slot's terminal buffer.
---@param slot integer
---@param bufnr integer
---@param kind string  -- "claude"|"codex"|"gemini"|"copilot"|"generic"
---@return boolean attached
function M.attach(slot, bufnr, kind)
  if not (slot and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return false end

  -- Skip kinds where a TUI prompt-pattern doesn't exist; activity-
  -- detection alone for these is no better than the cooperative path,
  -- and may flicker for plain shells. Keep generic out of scope.
  if kind == "generic" or kind == "copilot" then return false end

  -- Re-attach: detach old first.
  if M._by_slot[slot] then M.detach(slot) end

  ---@type AutoAgentsStatusObserver
  local obs = {
    slot = slot,
    bufnr = bufnr,
    kind = kind,
    last_activity = now_ms(),
    detached = false,
    timer = nil,
    user_pin = nil,
    last_emitted = nil,
    tick_count = 0,
    last_synced_model = nil,
  }
  M._by_slot[slot] = obs

  -- Buffer watcher: every chunk of TUI output bumps the timestamp.
  -- on_lines fires on TextChangedT-equivalent events including from
  -- the terminal job itself (Neovim's terminal writer uses the same
  -- buffer-modify path).
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      local cur = M._by_slot[slot]
      if not cur or cur.detached or cur.bufnr ~= bufnr then
        return true  -- detach this watcher
      end
      cur.last_activity = now_ms()
      -- Activity clears a sticky waiting pin (the user obviously got
      -- past it — a permission was answered, etc.).
      if cur.user_pin then cur.user_pin = nil end
      return false
    end,
    on_detach = function()
      local cur = M._by_slot[slot]
      if cur and cur.bufnr == bufnr then M.detach(slot) end
    end,
  })

  -- Periodic re-classify. Cheap: a few timestamp comparisons + a
  -- bounded buf_get_lines on quiet ticks.
  local timer = (vim.uv or vim.loop).new_timer()
  obs.timer = timer
  timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(function()
    local cur = M._by_slot[slot]
    if not cur or cur.detached then
      pcall(timer.stop, timer); pcall(timer.close, timer)
      return
    end
    if not vim.api.nvim_buf_is_valid(cur.bufnr) then
      M.detach(slot)
      return
    end
    cur.tick_count = cur.tick_count + 1
    emit_if_changed(cur)
    -- Model drift check at a slower cadence to avoid hammering buf_get_lines.
    if cur.tick_count % MODEL_CHECK_TICKS == 0 then
      pcall(check_model_drift, cur)
    end
  end))

  return true
end

---Pin a slot's status as `waiting` from an explicit user/agent
---report. Sticky until the next observed output. No-op if the slot
---has no observer (cooperative-only path still goes through
---M.set_status normally).
---@param slot integer
function M.pin_waiting(slot)
  local obs = M._by_slot[slot]
  if not obs then return end
  obs.user_pin = "waiting"
  obs.last_emitted = nil  -- force a re-emit on next tick
end

---Drop any user pin on a slot.
---@param slot integer
function M.clear_pin(slot)
  local obs = M._by_slot[slot]
  if not obs then return end
  obs.user_pin = nil
  obs.last_emitted = nil
end

---Snapshot of all currently-observed slots and their last-emitted
---state. Useful for `:AutoAgentsStatusReport` and for a future
---manager agent that wants to inspect the panel.
---@return { slot: integer, kind: string, state: "idle"|"working"|"waiting" }[]
function M.list()
  local out = {}
  for slot, obs in pairs(M._by_slot) do
    table.insert(out, {
      slot = slot,
      kind = obs.kind,
      state = obs.last_emitted or "idle",
    })
  end
  table.sort(out, function(a, b) return a.slot < b.slot end)
  return out
end

return M