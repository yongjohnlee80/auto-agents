---auto-agents.logger — thin compatibility shim over `auto-core.log`.
---
---Migration step (auto-agents v0.2.0 → auto-core consumer): the
---structured-logger surface moved into auto-core. This module
---preserves the existing `M.error/warn/info/debug/trace/setup`
---signature so the 26+ call sites scattered across `init.lua`,
---`config/store.lua`, `kb/instruct.lua`, `integrations/*`, etc.
---don't have to change. Each call delegates to
---`auto-core.log` with the component prepended by `auto-agents.`
---— so log lines render as
---
---    [AutoCore] [auto-agents.spawn] [INFO] message…
---
---which keeps the "auto-agents" namespace visible in the unified
---log stream.
---
---Phase 8 (family-wide cleanup) sweeps the call sites to
---`require("auto-core").log.namespace("auto-agents.<component>")`
---directly and deletes this shim. Until then, this file is the
---single insertion point.
---
---Originally adapted from coder/claudecode.nvim's logger (MIT).
---The auto-core.log surface itself is also signature-compatible
---with that ancestry.
---@module 'auto-agents.logger'

local core_log = require("auto-core").log

local M = {}

-- Re-export the level table so any caller doing
-- `if logger.levels.DEBUG <= … then` stays working.
M.levels = core_log.levels

---Prefix `component` with `auto-agents.` so logs are namespaced
---under the family root. Idempotent — already-prefixed strings
---pass through unchanged.
---@param component any
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then
    return "auto-agents"
  end
  if component:sub(1, #"auto-agents.") == "auto-agents."
      or component == "auto-agents" then
    return component
  end
  return "auto-agents." .. component
end

---Apply the auto-core.log convention: when first arg isn't a
---string, treat it as a message part with no explicit component.
---@param level_fn fun(component: string?, ...)
---@param component any
---@param ... any
local function level_call(level_fn, component, ...)
  if type(component) ~= "string" then
    -- No explicit component — fall back to the default namespace.
    level_fn("auto-agents", component, ...)
  else
    level_fn(ns(component), ...)
  end
end

---@param component string|any   -- component name OR first message part
function M.error(component, ...) level_call(core_log.error, component, ...) end
function M.warn(component, ...)  level_call(core_log.warn,  component, ...) end
function M.info(component, ...)  level_call(core_log.info,  component, ...) end
function M.debug(component, ...) level_call(core_log.debug, component, ...) end
function M.trace(component, ...) level_call(core_log.trace, component, ...) end

---Mirror the upstream `is_level_enabled` predicate via auto-core.
---@param level_name string
---@return boolean
function M.is_level_enabled(level_name)
  return core_log.is_level_enabled(level_name)
end

---auto-agents calls this from setup() with the resolved config.
---Reads `conf.log_level` ("error"|"warn"|"info"|"debug"|"trace")
---and forwards it to `auto-core.log.configure`. Invalid values
---fall back to INFO with a one-time notify, matching the prior
---behavior.
---@param plugin_config table?
function M.setup(plugin_config)
  local level = plugin_config and plugin_config.log_level
  if type(level) == "string" and core_log.levels[level:upper()] then
    core_log.configure({ level = level })
  elseif level == nil then
    core_log.configure({ level = "info" })
  else
    pcall(vim.notify,
      "auto-agents.logger: invalid log_level '" .. tostring(level)
        .. "' — defaulting to INFO",
      vim.log.levels.WARN)
    core_log.configure({ level = "info" })
  end
end

return M
