---Generic adapter — used both for `kind = "generic"` and as the fallback
---for unconfigured slots. Defaults to spec.cmd if provided, else the
---user's shell (vim.o.shell), giving empty slots a usable interactive
---terminal.
---@module 'auto-agents.agent.adapters.generic'

local M = {}

---@param spec table
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  return { vim.o.shell }
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
