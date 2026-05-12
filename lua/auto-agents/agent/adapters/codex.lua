---Codex CLI adapter (D3, M3).
---@module 'auto-agents.agent.adapters.codex'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  local argv = { "codex" }
  if spec and spec.model and spec.model ~= "" then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = spec.model
  end

  -- M6: IDE integration bridge. Codex supports config overrides via -c.
  if spec.diff_review then
    local aa = require("auto-agents")
    local port = aa.state and aa.state.diff_review_port
    if port then
      local url = string.format("http://127.0.0.1:%d/mcp", port)
      argv[#argv + 1] = "-c"
      argv[#argv + 1] = string.format('mcp_servers.auto-agents={ url="%s" }', url)
    end
  end

  return argv
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
