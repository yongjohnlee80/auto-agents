---Claude CLI adapter (D3, M3). Per-kind override of cmd/env. The MCP
---server reintroduction (per-Claude-agent port + lockfile) is M7+ —
---see open question #5 in PLAN.md and LAYERED-ARCHITECTURE.md.
---@module 'auto-agents.agent.adapters.claude'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  local argv = { "claude" }
  if spec and spec.model and spec.model ~= "" then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = spec.model
  end
  return argv
end

---@param spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
