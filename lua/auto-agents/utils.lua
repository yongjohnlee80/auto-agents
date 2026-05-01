-- Adapted from coder/claudecode.nvim lua/claudecode/utils.lua (MIT, 2025 Coder Technologies Inc.)

---Shared utility functions for auto-agents.nvim
---@module 'auto-agents.utils'

local M = {}

---@param focus boolean?
---@return boolean
function M.normalize_focus(focus)
  if focus == nil then
    return true
  else
    return focus
  end
end

return M
