---auto-agents.log — single-file logging surface for the plugin.
---
---Per ADR 0021 §6 (the "wrapper rule"), every auto-family plugin
---owns exactly one `lua/<plugin>/log.lua` that delegates to
---`auto-core.log`. Feature code in auto-agents calls THIS module;
---feature code MUST NOT `require("auto-core").log` directly.
---
---Renamed from `auto-agents.logger` in this commit. The previous
---module was a name-prefixing shim that only covered the level
---functions; this version adds:
---
---  - M.notify / M.notifyIf    — single-emission toast sugar
---                                that also writes the ring
---  - M.register_events        — declares this plugin's event-type
---                                catalog at setup time
---
---Log lines render as
---
---    [AutoCore] [auto-agents.spawn] [INFO] message…
---
---Originally adapted from coder/claudecode.nvim's logger (MIT).
---The auto-core.log surface itself is also signature-compatible
---with that ancestry.
---
---@module 'auto-agents.log'

local core_log = require("auto-core").log

local NS = "auto-agents"

local M = {}

-- Re-export the level table so any caller doing
-- `if log.levels.DEBUG <= … then` keeps working.
M.levels = core_log.levels

---Prefix `component` with `auto-agents.` so logs are namespaced
---under the family root. Idempotent — already-prefixed strings
---pass through unchanged.
---@param component any
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then
    return NS
  end
  if component == NS or component:sub(1, #NS + 1) == (NS .. ".") then
    return component
  end
  return NS .. "." .. component
end

---When the first arg isn't a string, treat it as the first
---message part and emit with the bare auto-agents namespace.
---@param level_fn fun(component: string?, ...)
---@param component any
---@param ... any
local function level_call(level_fn, component, ...)
  if type(component) ~= "string" then
    level_fn(NS, component, ...)
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

---Throttled level emissions (ADR-0039 Batch A, additive). Thin
---namespacing passthroughs to `auto-core.log.<level>_throttled` for
---call sites that can fire per-tick/per-transition — the hot-loop
---guard from auto-family-logging. Soft-dep: no-op level fallback
---when auto-core predates the throttled surface.
---@param key string        -- stable throttle key
---@param every_ms number   -- minimum interval between emissions
---@param component string|any
function M.warn_throttled(key, every_ms, component, ...)
  if type(core_log.warn_throttled) ~= "function" then
    return M.warn(component, ...)
  end
  core_log.warn_throttled(key, every_ms, ns(component), ...)
end

function M.error_throttled(key, every_ms, component, ...)
  if type(core_log.error_throttled) ~= "function" then
    return M.error(component, ...)
  end
  core_log.error_throttled(key, every_ms, ns(component), ...)
end

---Force-toast single emission. Writes ring + fires vim.notify
---(subject to the global level filter). Use this instead of bare
---`vim.notify(...)` so every toast lands in the auto-core ring for
---`:AutoCoreLog` triage. Default level INFO; override via
---`opts.level = "warn"` etc.
---
---ADR 0021 §6 soft-dep: when running against an auto-core older
---than the Phase 1 surface (no `core_log.notify`), fall back to a
---ring-only level emission so callers don't crash.
---@param msg any
---@param opts table?
function M.notify(msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  if type(core_log.notify) ~= "function" then
    local level_name = "info"
    if type(opts.level) == "string" then level_name = opts.level end
    local fn = M[level_name] or M.info
    return fn(opts.component, msg)
  end
  return core_log.notify(msg, opts)
end

---Ring write + conditional toast. The toast fires iff `event` is
---in the user's subscribed set (toggled via `:AutoCoreLogEvent
---notify <event>`). Bare event names auto-prefix with the plugin
---namespace.
---@param event string
---@param msg any
---@param opts table?
function M.notifyIf(event, msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  local fq_event = event
  if type(event) == "string"
      and event ~= NS
      and event:sub(1, #NS + 1) ~= (NS .. ".") then
    fq_event = NS .. "." .. event
  end
  if type(core_log.notifyIf) ~= "function" then
    return M.info(opts.component, msg)
  end
  return core_log.notifyIf(fq_event, msg, opts)
end

---Declare the events this plugin emits. Bare names auto-prefix
---via `auto-core.log.events.register`. Idempotent.
---@param events string|string[]
function M.register_events(events)
  if type(core_log.events) ~= "table"
      or type(core_log.events.register) ~= "function" then
    return
  end
  return core_log.events.register(NS, events)
end

---Mirror upstream's `is_level_enabled` predicate via auto-core.
---@param level_name string
---@return boolean
function M.is_level_enabled(level_name)
  return core_log.is_level_enabled(level_name)
end

---auto-agents calls this from setup() with the resolved config.
---Reads `conf.log_level` ("error"|"warn"|"info"|"debug"|"trace")
---and forwards it to `auto-core.log.configure`. Invalid values
---fall back to INFO with a one-time warn entry in the ring.
---@param plugin_config table?
function M.setup(plugin_config)
  local level = plugin_config and plugin_config.log_level
  if type(level) == "string" and core_log.levels[level:upper()] then
    core_log.configure({ level = level })
  elseif level == nil then
    core_log.configure({ level = "info" })
  else
    M.warn("log",
      "invalid log_level '" .. tostring(level) .. "' — defaulting to INFO")
    core_log.configure({ level = "info" })
  end
end

return M
