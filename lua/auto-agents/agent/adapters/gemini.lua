---Gemini CLI adapter (D3, M3).
---@module 'auto-agents.agent.adapters.gemini'

local M = {}

---@param spec table
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  return { "gemini" }
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
