---Codex CLI adapter (D3, M3).
---@module 'auto-agents.agent.adapters.codex'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return vim.list_slice(spec.cmd) end
  local argv = { "codex" }
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
