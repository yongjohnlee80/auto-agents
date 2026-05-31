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

---Validator for `assign slot:<N>` (Lector F4): called from
---`auto-core.todo.automation.validate(task)`. Pure syntax check —
---roster lookup is deferred to fire-time (a slot that's currently
---empty is a runtime issue, not a malformed-template issue, and we
---don't want refresh-side validation to flap with slot state).
---@param step string
---@return string? err
local function _slot_validate(step)
  if not step:match("^assign slot:%d+$") then
    return "malformed `assign slot:<N>` step (expected `assign slot:<integer>`): '" .. step .. "'"
  end
  return nil
end

---Resolve `assign slot:N` to `assign agent:<live-agent-name>`.
---Returns `(rewritten_step, err)`. Empty slot / out-of-range / no
---roster → err with a code prefix matching the validator hints in
---auto-core.todo.automation.validate.
---@param step string
---@return string?, string?
local function _slot_resolver(step)
  -- Run the validator first so syntax errors produce the same
  -- message at fire-time as at validate-time.
  local verr = _slot_validate(step)
  if verr then return nil, verr end
  local n = step:match("^assign slot:(%d+)$")
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

---Validator for `bash -t=<N> <cmd>` (Lector F4): called from
---`auto-core.todo.automation.validate(task)` at refresh / live-edit
---time. Returns an error string on syntax / range failure, nil on
---success. Surfaces malformed forms (`bash -t=abc echo`, out-of-
---range slot) at validate time instead of fire time.
---@param step string
---@return string? err
---Parse `bash -t=<N> <cmd>` step into `(slot, cmd, err)`.
---
---Quoting convention (ADR-0035 post-ship UX amendment 2026-05-31):
---  - `bash -t=1 echo hello world` — bare; sent verbatim to T1.
---    Typical when `<cmd>` is a file path (`./script.sh`) or a
---    single-token / shell-safe form.
---  - `bash -t=1 "echo hello world"` — quoted; outer quotes
---    SIGNAL "inline bash command, treat as a literal command to
---    execute." Stripped before sending so bash doesn't try to
---    execute the quoted string as a single-token command name.
---  - `bash -t=1 'echo hello world'` — same, single-quote form.
---
---Internal quotes are preserved (e.g. `bash -t=1 grep "foo bar"
---/tmp/log` keeps `"foo bar"` as the quoted arg). The strip only
---applies when the ENTIRE `<cmd>` portion is wrapped in matched
---outer quotes.
---@param step string
---@return integer? slot, string? cmd, string? err
local function _parse_bash_t(step)
  local n_str, raw_cmd = step:match("^bash %-t=(%d+)%s+(.+)$")
  if not n_str or not raw_cmd or raw_cmd == "" then
    return nil, nil, "malformed `bash -t=<N> <cmd>` step: '" .. step .. "'"
  end
  -- Strip a single layer of outer quotes if the WHOLE cmd is
  -- wrapped (matching open/close pair, non-empty inside).
  local stripped = raw_cmd:match("^\"(.+)\"$") or raw_cmd:match("^'(.+)'$")
  local cmd = stripped or raw_cmd
  if cmd == "" then
    return nil, nil, "empty cmd after `bash -t=<N>`"
  end
  return tonumber(n_str), cmd, nil
end

local function _bash_t_validate(step)
  local slot, _cmd, perr = _parse_bash_t(step)
  if perr then return perr end
  -- Auto-agents.term may not be loaded during refresh-side
  -- validation (headless smoke without the full plugin), so fall
  -- back to the canonical 1..4 range when we can't read it.
  local max = 4
  local ok_term, term = pcall(require, "auto-agents.term")
  if ok_term and term and type(term.MAX_SLOTS) == "number" then
    max = term.MAX_SLOTS
  end
  if slot < 1 or slot > max then
    return "N=" .. tostring(slot) .. " out of range 1.." .. tostring(max)
      .. " (`bash -t=<N>` targets floating terminal T<N>)"
  end
  return nil
end

---Executor for `bash -t=<N> <cmd>` — send text to floating terminal
---T<N> via auto-agents.term.send. ADR-0035 §4 / §5: delivery success
---means "accepted and submitted", NOT "shell command exited 0". The
---clone stays in-progress after a successful -t= step; only another
---step or explicit `todo.status` advances it.
---
---Lector F3 amendment: `ctx` (3rd arg) carries the host-side bypass
---flags from `M.fire(id, opts)`. Without this, the documented Lua
---bypass for admins (`automation.fire(id, {bypass_bash_disabled=true})`)
---wouldn't reach the terminal-routed form — the mailbox correctly
---refuses bypass either way per ADR §10.
---
---@param step string
---@param _clone table  -- unused; the term send doesn't need clone context
---@param ctx { bypass_bash_disabled: boolean?, bypass_allowlist: boolean? }?
---@return table?, string?
local function _bash_t_executor(step, _clone, ctx)
  ctx = ctx or {}
  -- Use the validator first so syntax / range errors surface with
  -- the same message refresh-side validation would have produced —
  -- keeps fire-time and validate-time errors consistent.
  local verr = _bash_t_validate(step)
  if verr then return nil, verr end

  -- Re-parse via the shared helper so the cmd has any outer
  -- quotes stripped (inline-bash semantic from the 2026-05-31 UX
  -- amendment). Without this, sending `"echo hello world"` to the
  -- terminal would have bash try to execute the quoted string as
  -- a single-token command name and fail.
  local slot, cmd, _perr = _parse_bash_t(step)
  if not slot then return nil, _perr end

  local ok_term, term = pcall(require, "auto-agents.term")
  if not (ok_term and term) then
    return nil, "auto-agents.term module not available"
  end

  -- ADR §4.5 trust gate. The executor bypasses auto-core's built-in
  -- `bash ` / `bash:` trust check (those gates only fire for the
  -- auto-core-direct primitives), so enforce uniformly here.
  -- Lector F3: ctx flags let the host Lua API supply bypass; mailbox
  -- callers can't reach this path with bypass set (todos.fire rejects
  -- the flag at the mailbox boundary, never passes it through).
  local ts = _automation().trust_state()
  if not ts.bash_enabled and not ctx.bypass_bash_disabled then
    return nil, "[automation-bash-disabled] bash steps are disabled "
      .. "for this workspace (run :AutoAgentsTodosAutomationEnable to enable)"
  end
  if type(ts.bash_allowlist) == "table" and #ts.bash_allowlist > 0
      and not ctx.bypass_allowlist
  then
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

  -- Lector F4: register validators alongside the resolver/executor
  -- so refresh-side `errors[]` population AND auto-finder's live
  -- `vim.diagnostic` surface catch malformed plugin-owned forms
  -- (`assign slot:abc`, `bash -t=99 echo`) at validate-time instead
  -- of fire-time.
  automation.register_hook("assign slot:", {
    resolve  = _slot_resolver,
    validate = _slot_validate,
  })
  automation.register_executor("bash -t=", {
    execute  = _bash_t_executor,
    validate = _bash_t_validate,
  })

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