---auto-agents.todo_automation — ADR-0035 Phase 2 adapter that wires
---auto-agents-owned execute primitives into auto-core's automation
---engine. Lives in auto-agents because auto-core must NOT name
---auto-agents (boundary invariant per ADR §"Plugin boundaries").
---
---Surface:
---  • `install()` — idempotent. Registers:
---      - rewrite hook `"assign slot:"` → resolves N to live agent
---        name via `auto-agents.spawned_agents()`, returns the
---        rewritten `assign agent:<name>` step. Auto-core's
---        normal assign primitive then runs.
---      - executor `"bash -t="` → parses N (1..MAX_SLOTS), calls
---        `auto-agents.term.send(N, cmd, {submit=true})`. Success
---        means the text was delivered to T<N>, NOT that the
---        shell command exited 0 (per Lector A3); clone stays
---        in-progress after delivery.
---      - subscriber on `core.todo.automation:fired` → writes a
---        one-line audit entry into `$AUTO_AGENTS_KB_ROOT/log.md`
---        when that env is set. No-op otherwise.
---  • `uninstall()` — symmetric teardown for tests / re-arm.
---@module 'auto-agents.todo_automation'

local M = {}

local _installed = false
local _audit_handle = nil

local function _automation()
  return require("auto-core.todo.automation")
end

local function _log()
  local ok, log = pcall(require, "auto-agents.log")
  return ok and log or nil
end

---Resolve `assign slot:N` to `assign agent:<live-agent-name>`.
---Returns `(rewritten_step, err)`. Empty slot / out-of-range / no
---roster → err with a code prefix matching the validator hints in
---auto-core.todo.automation.validate.
---@param step string
---@return string?, string?
local function _slot_resolver(step)
  local n = step:match("^assign slot:(%d+)$")
  if not n then
    return nil, "malformed `assign slot:<N>` step: '" .. step .. "'"
  end
  local slot = tonumber(n)

  local ok_aa, aa = pcall(require, "auto-agents")
  if not (ok_aa and aa and type(aa.spawned_agents) == "function") then
    return nil, "auto-agents.spawned_agents() not available"
  end
  local roster = aa.spawned_agents() or {}
  -- `spawned_agents()` returns a list of `{slot, name, kind, …}`
  -- entries. Resolve by slot match.
  for _, entry in ipairs(roster) do
    if type(entry) == "table" and entry.slot == slot and type(entry.name) == "string" then
      return "assign agent:" .. entry.name, nil
    end
  end
  return nil, "no live agent in slot " .. tostring(slot)
end

---Executor for `bash -t=<N> <cmd>` — send text to floating terminal
---T<N> via auto-agents.term.send. ADR-0035 §4 / §5: delivery success
---means "accepted and submitted", NOT "shell command exited 0". The
---clone stays in-progress after a successful -t= step; only another
---step or explicit `todo.status` advances it.
---
---@param step string
---@param _clone table  -- unused; the term send doesn't need clone context
---@return table?, string?
local function _bash_t_executor(step, _clone)
  local n_str, cmd = step:match("^bash %-t=(%d+)%s+(.+)$")
  if not n_str or not cmd or cmd == "" then
    return nil, "malformed `bash -t=<N> <cmd>` step: '" .. step .. "'"
  end
  local slot = tonumber(n_str)

  local ok_term, term = pcall(require, "auto-agents.term")
  if not (ok_term and term) then
    return nil, "auto-agents.term module not available"
  end

  local max = type(term.MAX_SLOTS) == "number" and term.MAX_SLOTS or 4
  if slot < 1 or slot > max then
    -- Distinct error code so `automation-bash-t-range` can be
    -- recognized via the step-failed message at the consumer side.
    return nil, "[automation-bash-t-range] N=" .. tostring(slot)
      .. " out of range 1.." .. tostring(max)
  end

  -- ADR §4.5 trust gate also applies to `bash -t=` — both forms
  -- gated uniformly. We re-check here even though the executor is
  -- invoked through automation.fire's step loop, because
  -- automation.fire's built-in `bash` trust check only fires for
  -- the `bash ` / `bash:` prefixes — `bash -t=` goes through the
  -- executor registry, bypassing that gate. So enforce it here.
  local ts = _automation().trust_state()
  if not ts.bash_enabled then
    return nil, "[automation-bash-disabled] bash steps are disabled "
      .. "for this workspace (run :AutoAgentsTodosAutomationEnable to enable)"
  end
  if type(ts.bash_allowlist) == "table" and #ts.bash_allowlist > 0 then
    local matched = false
    for _, pat in ipairs(ts.bash_allowlist) do
      if cmd:match(pat) then matched = true; break end
    end
    if not matched then
      return nil, "[automation-bash-not-allowlisted] '" .. cmd
        .. "' does not match any allowlist prefix"
    end
  end

  local ok = term.send(slot, cmd, { submit = true, show = false })
  if not ok then
    return nil, "auto-agents.term.send returned false for slot " .. slot
  end

  -- Per ADR §5: delivery ≠ exit. `completed_clone = false` so the
  -- clone stays in-progress.
  return {
    ok              = true,
    message         = "delivered to T" .. slot,
    completed_clone = false,
  }, nil
end

---Subscribe to `core.todo.automation:fired` and write an audit line
---to `$AUTO_AGENTS_KB_ROOT/log.md` per ADR-0035 §12. No-op when the
---env var is unset (auto-core stays KB-neutral; this is the auto-
---agents-side adapter that adds KB persistence when a KB is
---configured).
local function _install_kb_audit()
  if _audit_handle then return end
  local kb_root = vim.env.AUTO_AGENTS_KB_ROOT
  if not kb_root or kb_root == "" then return end

  local events = require("auto-core.events")
  _audit_handle = events.subscribe("core.todo.automation:fired", function(payload)
    if type(payload) ~= "table" then return end
    local line = string.format(
      "## [%s] automation-fire | origin=%s clone=%s outcome=%s\n",
      tostring(payload.fired_at),
      tostring(payload.origin_id),
      tostring(payload.clone_id),
      tostring(payload.outcome))
    local path = kb_root .. "/log.md"
    local f = io.open(path, "a")
    if f then f:write(line); f:close() end
  end)
end

local function _uninstall_kb_audit()
  if not _audit_handle then return end
  pcall(function()
    require("auto-core.events").unsubscribe(_audit_handle)
  end)
  _audit_handle = nil
end

---Idempotent install. Safe to call from auto-agents setup AND from
---smoke tests; second call is a no-op.
function M.install()
  if _installed then return end
  local automation = _automation()

  automation.register_hook("assign slot:", _slot_resolver)
  automation.register_executor("bash -t=", _bash_t_executor)

  _install_kb_audit()

  -- Start the engine so the scheduler tick + event router fire.
  -- Idempotent on the automation side.
  pcall(automation.start)

  _installed = true
  local log = _log()
  if log and log.debug then
    pcall(log.debug, "todo_automation", "installed hook + executor + KB audit")
  end
end

---Symmetric teardown. Used by smoke to re-arm between assertions.
function M.uninstall()
  if not _installed then return end
  local ok_a, automation = pcall(_automation)
  if ok_a then
    pcall(automation.unregister_hook, "assign slot:")
    pcall(automation.unregister_executor, "bash -t=")
    pcall(automation.stop)
  end
  _uninstall_kb_audit()
  _installed = false
end

---Diagnostic snapshot — used by smoke + admin debugging.
function M.is_installed() return _installed end

return M