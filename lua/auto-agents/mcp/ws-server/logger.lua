---@brief Centralized logger for the vendored Claude Code Neovim
---server. Bridges every emit through `auto-agents.log` so the
---auto-core ring captures ws-server activity alongside the rest
---of the family.
---
---**ADR 0021 §10.2 — bridge resolution.** The 2026-05-16 audit
---decided to PRESERVE the module shape (file path, function
---signatures, levels table) instead of deleting the file outright:
---
---1. No code outside `auto-agents/mcp/ws-server/` requires this
---   module — but the vendored tree may be re-synced from upstream
---   `coder/claudecode.nvim` per the
---   `vendoring-third-party-protocol-clients` playbook, and keeping
---   the shape minimizes per-resync diff friction.
---2. The vendored ws-server's 6 internal consumers (init, tcp,
---   client, diff, tools/init, tools/close_tab) `require` this
---   module by path. Keeping the shape means those internal
---   consumers stay byte-identical with their upstream
---   counterparts.
---
---**What changed in the bridge:** every emit now ALSO calls the
---corresponding `auto-agents.log.<level>` so the entry lands in
---the auto-core ring (component prefix `ws-server.<component>`).
---The local prefix "[ClaudeCode]" + level filter and the
---`vim.schedule`-wrapped vim.notify / nvim_echo behavior remain
---intact — backward-compatible with the upstream contract any
---future resync brings.
---
---@module 'claudecode.logger'
local M = {}

M.levels = {
  ERROR = 1,
  WARN = 2,
  INFO = 3,
  DEBUG = 4,
  TRACE = 5,
}

local level_values = {
  error = M.levels.ERROR,
  warn = M.levels.WARN,
  info = M.levels.INFO,
  debug = M.levels.DEBUG,
  trace = M.levels.TRACE,
}

local current_log_level_value = M.levels.INFO

-- Lazy handle to the family wrapper. Resolved on first use so
-- that loading this vendored module during auto-agents bootstrap
-- (potentially before `auto-agents.log` itself is required) never
-- crashes on an out-of-order init.
local _af_log
local function af_log()
  if _af_log ~= nil then return _af_log end
  local ok, mod = pcall(require, "auto-agents.log")
  if ok and type(mod) == "table" then
    _af_log = mod
  else
    _af_log = false
  end
  return _af_log
end

---Setup the logger module
---@param plugin_config table The configuration table (e.g., from claudecode.init.state.config).
function M.setup(plugin_config)
  local conf = plugin_config

  if conf and conf.log_level and level_values[conf.log_level] then
    current_log_level_value = level_values[conf.log_level]
  else
    -- Route via the family wrapper so the warning lands in the
    -- auto-core ring (don't bypass the bridge for this case).
    local fl = af_log()
    if fl then
      fl.warn("ws-server.logger",
        "Invalid or missing log_level in configuration (received: "
          .. tostring(conf and conf.log_level)
          .. "). Defaulting to INFO.")
    else
      vim.notify(
        "ClaudeCode Logger: Invalid or missing log_level in configuration (received: "
          .. tostring(conf and conf.log_level)
          .. "). Defaulting to INFO.",
        vim.log.levels.WARN
      )
    end
    current_log_level_value = M.levels.INFO
  end
end

-- Bridge: forward every accepted emission into auto-agents.log so
-- the auto-core ring sees ws-server activity. Component is
-- prefixed with `ws-server.` (and further by `auto-agents.` inside
-- the wrapper) so the ring entry reads
-- `auto-agents.ws-server.<component>`.
local function bridge_to_family(level, component, message_parts)
  local fl = af_log()
  if not fl then return end
  local prefixed = component and ("ws-server." .. component) or "ws-server"
  local fn
  if level == M.levels.ERROR then fn = fl.error
  elseif level == M.levels.WARN then fn = fl.warn
  elseif level == M.levels.INFO then fn = fl.info
  elseif level == M.levels.DEBUG then fn = fl.debug
  else fn = fl.trace
  end
  -- LuaJIT (Neovim's Lua) has no `table.unpack` — it's the 5.1
  -- global `unpack`. Calling table.unpack here crashed the bridge
  -- (and the WS read loop above it) on the first WARN-level
  -- emission. ADR-0039 Batch A bonus fix; the bridge is a local
  -- modification, not vendored-verbatim (ADR-0021 §10.2).
  local unpack_fn = table.unpack or unpack
  fn(prefixed, unpack_fn(message_parts))
end

local function log(level, component, message_parts)
  if level > current_log_level_value then
    return
  end

  -- Bridge first — the family ring captures the entry whether or
  -- not the local vim.notify / nvim_echo path fires.
  bridge_to_family(level, component, message_parts)

  local prefix = "[ClaudeCode]"
  if component then
    prefix = prefix .. " [" .. component .. "]"
  end

  local level_name = "UNKNOWN"
  for name, val in pairs(M.levels) do
    if val == level then
      level_name = name
      break
    end
  end
  prefix = prefix .. " [" .. level_name .. "]"

  local message = ""
  for i, part in ipairs(message_parts) do
    if i > 1 then
      message = message .. " "
    end
    if type(part) == "table" or type(part) == "boolean" then
      message = message .. vim.inspect(part)
    else
      message = message .. tostring(part)
    end
  end

  -- Wrap all vim.notify and nvim_echo calls in vim.schedule to avoid
  -- "nvim_echo must not be called in a fast event context" errors
  vim.schedule(function()
    if level == M.levels.ERROR then
      vim.notify(prefix .. " " .. message, vim.log.levels.ERROR, { title = "ClaudeCode Error" })
    elseif level == M.levels.WARN then
      vim.notify(prefix .. " " .. message, vim.log.levels.WARN, { title = "ClaudeCode Warning" })
    else
      -- For INFO, DEBUG, TRACE, use nvim_echo to avoid flooding notifications,
      -- to make them appear in :messages
      vim.api.nvim_echo({ { prefix .. " " .. message, "Normal" } }, true, {})
    end
  end)
end

---Error level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.error(component, ...)
  if type(component) ~= "string" then
    log(M.levels.ERROR, nil, { component, ... })
  else
    log(M.levels.ERROR, component, { ... })
  end
end

---Warn level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.warn(component, ...)
  if type(component) ~= "string" then
    log(M.levels.WARN, nil, { component, ... })
  else
    log(M.levels.WARN, component, { ... })
  end
end

---Info level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.info(component, ...)
  if type(component) ~= "string" then
    log(M.levels.INFO, nil, { component, ... })
  else
    log(M.levels.INFO, component, { ... })
  end
end

---Check if a specific log level is enabled
---@param level_name string The level name ("error", "warn", "info", "debug", "trace")
---@return boolean enabled Whether the level is enabled
function M.is_level_enabled(level_name)
  local level_value = level_values[level_name]
  if not level_value then
    return false
  end
  return level_value <= current_log_level_value
end

---Debug level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.debug(component, ...)
  if type(component) ~= "string" then
    log(M.levels.DEBUG, nil, { component, ... })
  else
    log(M.levels.DEBUG, component, { ... })
  end
end

---Trace level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.trace(component, ...)
  if type(component) ~= "string" then
    log(M.levels.TRACE, nil, { component, ... })
  else
    log(M.levels.TRACE, component, { ... })
  end
end

return M
