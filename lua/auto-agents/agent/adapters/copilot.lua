---GitHub Copilot CLI adapter (D3, M3). Defaults to `gh copilot` — users
---can override the precise subcommand (e.g. `gh copilot suggest`) via
---`spec.cmd` in their bootstrap entry.
---@module 'auto-agents.agent.adapters.copilot'

local M = {}

---@param spec table
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return vim.list_slice(spec.cmd) end
  return { "gh", "copilot" }
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
