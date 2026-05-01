---Per-kind agent adapter dispatch (D3, M3). Each kind exports
---`cmd(spec)` and `env(spec)`. `generic` doubles as the shell-fallback
---adapter for unconfigured slots.
---@module 'auto-agents.agent'

local M = {}

local KIND_MODULE = {
  claude = "auto-agents.agent.adapters.claude",
  codex = "auto-agents.agent.adapters.codex",
  gemini = "auto-agents.agent.adapters.gemini",
  copilot = "auto-agents.agent.adapters.copilot",
  generic = "auto-agents.agent.adapters.generic",
}

---List of supported agent kinds (used by validators and tab completion).
---@return string[]
function M.kinds()
  return { "claude", "codex", "gemini", "copilot", "generic" }
end

---@param kind string|nil
---@return table  -- adapter module
function M.adapter_for(kind)
  local modname = KIND_MODULE[kind] or KIND_MODULE.generic
  return require(modname)
end

---Resolve the command argv for a kind+spec pair.
---@param kind string|nil
---@param spec table|nil
---@return string[]
function M.cmd_for(kind, spec)
  return M.adapter_for(kind).cmd(spec or {})
end

---Resolve env extras for a kind+spec pair.
---@param kind string|nil
---@param spec table|nil
---@return table<string,string>
function M.env_for(kind, spec)
  return M.adapter_for(kind).env(spec or {}) or {}
end

return M
