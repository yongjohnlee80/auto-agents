---Codex CLI adapter (D3, M3).
---@module 'auto-agents.agent.adapters.codex'

local M = {}

---@param spec table
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  return { "codex" }
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
