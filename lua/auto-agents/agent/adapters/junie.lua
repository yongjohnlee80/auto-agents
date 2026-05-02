---JetBrains Junie CLI adapter (D3, M3).
---
---Upstream docs: https://junie.jetbrains.com/docs/junie-cli.html
---Parameters:    https://junie.jetbrains.com/docs/parameters.html
---
---Install: `npm install -g @jetbrains/junie-cli`. Verify with
---`junie --version`. Default invocation is plain `junie` from the
---project root — drops into an interactive TUI session. `--model <id>`
---is supported and gets appended automatically when `spec.model` is set.
---
---@module 'auto-agents.agent.adapters.junie'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  local argv = { "junie" }
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
