---Per-kind agent adapter dispatch (D3, M3). Each kind exports
---`cmd(spec)` and `env(spec)`. `generic` doubles as the shell-fallback
---adapter for unconfigured slots.
---@module 'auto-agents.agent'

local M = {}

local KIND_MODULE = {
  claude = "auto-agents.agent.adapters.claude",
  codex = "auto-agents.agent.adapters.codex",
  gemini = "auto-agents.agent.adapters.gemini",
  junie = "auto-agents.agent.adapters.junie",
  aider = "auto-agents.agent.adapters.aider",
  goose = "auto-agents.agent.adapters.goose",
  opencode = "auto-agents.agent.adapters.opencode",
  copilot = "auto-agents.agent.adapters.copilot",
  generic = "auto-agents.agent.adapters.generic",
}

---List of supported agent kinds (used by validators and tab completion).
---@return string[]
function M.kinds()
  return { "claude", "codex", "gemini", "junie", "aider", "goose", "opencode", "copilot", "generic" }
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

---List configured agent names from the live bootstrap. Used by
---:AutoAgentsModel tab-completion and lookup.
---@return string[]
function M.names()
  local cfg = (require("auto-agents").state or {}).config
  local out = {}
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return out end
  for _, entry in ipairs(cfg.agents.bootstrap) do
    if entry.name and entry.name ~= "" then
      out[#out + 1] = entry.name
    end
  end
  return out
end

---Set, show, or clear the preferred model for an agent. Mutates the
---live in-memory bootstrap entry and persists to the active TOML
---(project file if present, else global) via config.store.save_current().
---
---  set_model("jarvis", "claude-opus-4-7")  → set
---  set_model("jarvis", nil)                → show (no mutation)
---  set_model("jarvis", "-")                → clear (back to CLI default)
---
---Effect on running session: none. The new value is read by adapters on
---the next spawn (M.cmd_for builds argv from the bootstrap entry).
---
---@param name string
---@param model string|nil   nil = show, "-" = clear, anything else = set
---@return boolean ok
---@return string message
function M.set_model(name, model)
  local cfg = (require("auto-agents").state or {}).config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then
    return false, "auto-agents.setup() has not run yet"
  end
  local entry
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.name == name then entry = e; break end
  end
  if not entry then
    return false, "no agent named '" .. tostring(name) .. "'"
  end

  if model == nil then
    return true, name .. " → " .. (entry.model or "(none — CLI default)")
  end

  if model == "-" or model == "" then
    entry.model = nil
  else
    entry.model = model
  end

  local ok, _path = require("auto-agents.config.store").save_current()
  if not ok then
    return false, "failed to write config TOML"
  end
  return true, name .. " → " .. (entry.model or "(none — CLI default)")
    .. " (effective on next " .. name .. " restart)"
end

return M
