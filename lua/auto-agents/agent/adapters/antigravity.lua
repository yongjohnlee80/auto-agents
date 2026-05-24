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
---Model selection: v0.2.32 removes the spawn-time `--model <id>`
---injection — `agy --help` confirms no such flag exists. Agents
---pick their model interactively or via per-user config. A `model`
---field in the TOML spec is silently ignored for antigravity slots;
---spawn `cmd = ["agy", "-i", "...", ...]` if you need to pass
---specific flags manually.
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

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  -- agy has no --model flag (see `agy --help`); spec.model is
  -- silently ignored for antigravity slots.
  return { "agy" }
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M