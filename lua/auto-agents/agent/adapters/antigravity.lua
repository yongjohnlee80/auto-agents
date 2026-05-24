---Antigravity CLI adapter (v0.2.30 — replaces deprecated gemini).
---Antigravity is Google's agentic CLI, invoked as `agy`. v0.2.30
---moves all agent mailboxes to a workspace-scoped root
---(`<workspace>/.auto-agents/mailbox/`), so antigravity no longer
---needs a per-CLI config-dir mailbox path.
---
---Instruction file: antigravity auto-loads `AGENTS.md` at its cwd —
---no per-kind override needed; falls through to the AGENTS.md default
---in `auto-agents.kb.instruct.filename_for`.
---
---Diff review: antigravity has no built-in WebSocket diff bridge
---(unlike claude). Antigravity slots therefore can't currently opt
---into native MCP `openDiff` review. If/when antigravity grows that
---capability, the wizard's `diff_review` default-rules in
---`panel/wizard_specs.lua` and the per-kind branches in
---`init.lua:build_agent_env` are the integration points.
---
---@module 'auto-agents.agent.adapters.antigravity'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  local argv = { "agy" }
  if spec and spec.model and spec.model ~= "" then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = spec.model
  end
  return argv
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M