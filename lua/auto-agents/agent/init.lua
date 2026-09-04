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

local CANONICAL_COMMANDS = {
  claude      = { { "claude" } },
  codex       = { { "codex" } },
  antigravity = { { "agy" } },
  junie       = { { "junie" } },
  goose       = { { "goose", "session" }, { "goose" } },
  opencode    = { { "opencode" } },
  copilot     = { { "gh", "copilot" }, { "copilot" } },
}

local CANONICAL_BIN = {
  claude      = "claude",
  codex       = "codex",
  antigravity = "agy",
  junie       = "junie",
  goose       = "goose",
  opencode    = "opencode",
  copilot     = "copilot",
}

---Primary canonical command argv for an agent kind.
---@param kind string|nil
---@return string[]|nil
function M.canonical_cmd(kind)
  local seqs = CANONICAL_COMMANDS[kind]
  if seqs and seqs[1] then
    return vim.list_slice(seqs[1])
  end
  return nil
end

---Canonical binary name for an agent kind, if one is fixed.
---Retained for backward compatibility; prefer canonical_cmd.
---@param kind string|nil
---@return string|nil
function M.canonical_bin(kind)
  return CANONICAL_BIN[kind]
end

---Check if `cmd` matches a canonical command candidate sequence.
---Token 1 matches by basename (:t); subsequent tokens match exact equality.
---@param candidate string[]
---@param cmd string[]
---@return boolean
local function matches_candidate(candidate, cmd)
  if #cmd < #candidate then return false end
  local b = vim.fn.fnamemodify(cmd[1], ":t")
  if b ~= candidate[1] then return false end
  for i = 2, #candidate do
    if cmd[i] ~= candidate[i] then
      return false
    end
  end
  return true
end

---Check whether `cmd` matches any of the canonical command sequences for `kind`.
---@param kind string|nil
---@param cmd string[]|nil
---@return boolean
local function matches_kind_default(kind, cmd)
  if not kind or type(cmd) ~= "table" or #cmd == 0 then return false end
  local seqs = CANONICAL_COMMANDS[kind]
  if not seqs then return false end
  for _, candidate in ipairs(seqs) do
    if matches_candidate(candidate, cmd) then
      return true
    end
  end
  return false
end

---Check whether a `cmd` is exactly equal to one of the bare adapter defaults for `kind`
---(i.e. matches candidate sequence length exactly, with no additional flags or args).
---@param kind string|nil
---@param cmd string[]|nil
---@return boolean
local function is_bare_adapter_default(kind, cmd)
  if not kind or type(cmd) ~= "table" or #cmd == 0 then return false end
  local seqs = CANONICAL_COMMANDS[kind]
  if not seqs then return false end
  for _, candidate in ipairs(seqs) do
    if #cmd == #candidate and matches_candidate(candidate, cmd) then
      return true
    end
  end
  return false
end

---Check whether a cmd override matches a different known agent kind than `kind`.
---Detects stale cmd overrides left behind when an agent's kind changed
---(e.g. Wanda kind=antigravity with cmd=["junie"], or kind=claude with cmd=["gh", "copilot"]).
---@param kind string|nil
---@param cmd string[]|nil
---@return boolean is_mismatched
---@return string|nil other_kind
function M.is_mismatched_cmd(kind, cmd)
  if not kind or kind == "generic" or type(cmd) ~= "table" or #cmd == 0 then
    return false, nil
  end
  if matches_kind_default(kind, cmd) then
    return false, nil
  end
  for other_kind, _ in pairs(CANONICAL_COMMANDS) do
    if other_kind ~= kind and matches_kind_default(other_kind, cmd) then
      return true, other_kind
    end
  end
  return false, nil
end

---Check whether a path argument is an auto-agents generated runtime per-instance mailbox path
---(e.g. `<workspace>/.auto-agents/mailbox/<timestamp>-<instance>/<agent>`).
---User-configured paths (including user-authored mailbox-shaped paths or active KB) return false.
---@param path string|nil
---@return boolean
function M.is_leaked_runtime_grant_path(path)
  if type(path) ~= "string" or path == "" then return false end
  local seg = path:match("%.auto%-agents/mailbox/([^/]+)")
    or path:match("%.auto%-agents%-config/mailbox/([^/]+)")
  if seg and seg:match("^%d+%-%d+$") then
    return true
  end
  return false
end

---Strip leaked runtime permission flags (e.g. `--add-dir <path>` where `<path>` is an
---auto-agents generated runtime instance mailbox path) from a cmd table.
---User-configured `--add-dir` arguments (including active KB and user mailbox paths) are preserved.
---Returns a new list without leaked flag pairs, or nil if the resulting list is empty.
---@param cmd string[]|nil
---@return string[]|nil
function M.strip_permission_flags(cmd)
  if type(cmd) ~= "table" then return cmd end
  local out = {}
  local i = 1
  local changed = false
  while i <= #cmd do
    local arg = cmd[i]
    if arg == "--add-dir" and i < #cmd and M.is_leaked_runtime_grant_path(cmd[i + 1]) then
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

---Sanitize an agent's cmd override on config load or write:
---1. If `cmd` is mismatched cross-kind (e.g. kind=antigravity with cmd=[junie],
---   or kind=claude with cmd=[gh, copilot]), clears it to nil and logs a warning.
---2. If `cmd` matches the adapter's bare default (e.g. ["claude"] for claude,
---   ["gh", "copilot"] for copilot, ["agy"] for antigravity), clears it to nil
---   so the adapter generates argv cleanly.
---3. Preserves all other user overrides verbatim (including user-configured --add-dir).
---@param kind string|nil
---@param cmd string[]|nil
---@param agent_name string|nil
---@return string[]|nil sanitized_cmd
function M.sanitize_cmd(kind, cmd, agent_name)
  if type(cmd) ~= "table" or #cmd == 0 then return nil end

  local mismatched, other_kind = M.is_mismatched_cmd(kind, cmd)
  if mismatched then
    require("auto-agents.log").warn("agent",
      string.format("clearing stale cmd override '%s' for agent '%s' (kind=%s != %s)",
        table.concat(cmd, " "), agent_name or "?", tostring(kind), tostring(other_kind)))
    return nil
  end

  if is_bare_adapter_default(kind, cmd) then
    return nil
  end

  return vim.list_slice(cmd)
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
