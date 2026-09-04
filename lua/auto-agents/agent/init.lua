---Per-kind agent adapter dispatch (D3, M3). Each kind exports
---`cmd(spec)` and `env(spec)`. `generic` doubles as the shell-fallback
---adapter for unconfigured slots.
---@module 'auto-agents.agent'

local M = {}

local KIND_MODULE = {
  claude = "auto-agents.agent.adapters.claude",
  codex = "auto-agents.agent.adapters.codex",
  antigravity = "auto-agents.agent.adapters.antigravity",
  junie = "auto-agents.agent.adapters.junie",
  goose = "auto-agents.agent.adapters.goose",
  opencode = "auto-agents.agent.adapters.opencode",
  copilot = "auto-agents.agent.adapters.copilot",
  generic = "auto-agents.agent.adapters.generic",
}

---List of supported agent kinds (used by validators and tab completion).
---@return string[]
function M.kinds()
  return { "claude", "codex", "antigravity", "junie", "goose", "opencode", "copilot", "generic" }
end

---@param kind string|nil
---@return table  -- adapter module
function M.adapter_for(kind)
  local modname = KIND_MODULE[kind] or KIND_MODULE.generic
  return require(modname)
end

local CANONICAL_BIN = {
  claude      = "claude",
  codex       = "codex",
  antigravity = "agy",
  junie       = "junie",
  goose       = "goose",
  opencode    = "opencode",
  copilot     = "copilot",
}

---Canonical binary name for an agent kind, if one is fixed.
---@param kind string|nil
---@return string|nil
function M.canonical_bin(kind)
  return CANONICAL_BIN[kind]
end

---Check whether a cmd override matches a different known agent kind than `kind`.
---Detects stale cmd overrides left behind when an agent's kind changed
---(e.g. Wanda kind=antigravity with cmd=["junie"]).
---@param kind string|nil
---@param cmd string[]|nil
---@return boolean is_mismatched
---@return string|nil other_kind
function M.is_mismatched_cmd(kind, cmd)
  if not kind or kind == "generic" or type(cmd) ~= "table" or #cmd == 0 then
    return false, nil
  end
  local bin = cmd[1]
  if type(bin) ~= "string" or bin == "" then return false, nil end
  local b = vim.fn.fnamemodify(bin, ":t")
  for other_kind, canon in pairs(CANONICAL_BIN) do
    if other_kind ~= kind and b == canon then
      return true, other_kind
    end
  end
  return false, nil
end

---Strip leaked runtime permission flags (e.g. `--add-dir <path>`) from a cmd table.
---Returns a new list without those flag pairs, or nil if the resulting list is empty.
---@param cmd string[]|nil
---@return string[]|nil
function M.strip_permission_flags(cmd)
  if type(cmd) ~= "table" then return cmd end
  local out = {}
  local i = 1
  local changed = false
  while i <= #cmd do
    local arg = cmd[i]
    if arg == "--add-dir" then
      changed = true
      i = i + 2
    else
      out[#out + 1] = arg
      i = i + 1
    end
  end
  if not changed then return vim.list_slice(cmd) end
  if #out == 0 then return nil end
  return out
end

---Sanitize an agent's cmd override:
---1. Strips leaked runtime permission flags (`--add-dir <dir>`).
---2. If `cmd` is mismatched cross-kind (e.g. kind=antigravity with cmd=[junie]),
---   clears it to nil and logs a warning.
---3. If `cmd` after stripping matches the adapter's bare default (e.g. ["claude"] for claude),
---   clears it to nil so the adapter generates argv cleanly.
---@param kind string|nil
---@param cmd string[]|nil
---@param agent_name string|nil
---@return string[]|nil sanitized_cmd
function M.sanitize_cmd(kind, cmd, agent_name)
  if type(cmd) ~= "table" or #cmd == 0 then return nil end
  local cleaned = M.strip_permission_flags(cmd)
  if not cleaned then return nil end

  local mismatched, other_kind = M.is_mismatched_cmd(kind, cleaned)
  if mismatched then
    require("auto-agents.log").warn("agent",
      string.format("clearing stale cmd override '%s' for agent '%s' (kind=%s != %s)",
        cleaned[1] or "?", agent_name or "?", tostring(kind), tostring(other_kind)))
    return nil
  end

  if #cleaned == 1 and kind and CANONICAL_BIN[kind] then
    local b = vim.fn.fnamemodify(cleaned[1], ":t")
    if b == CANONICAL_BIN[kind] then
      return nil
    end
  end

  return cleaned
end

---Resolve the command argv for a kind+spec pair. Always returns a shallow copy
---so callers and adapters cannot mutate the config-owned spec.
---@param kind string|nil
---@param spec table|nil
---@return string[]
function M.cmd_for(kind, spec)
  local argv = M.adapter_for(kind).cmd(spec or {})
  if type(argv) == "table" then
    return vim.list_slice(argv)
  end
  return argv
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
