---auto-agents.state — auto-core.state namespace wrapper.
---
---v0.2.0 migration step: panel slot_count + width_override + focused_slot
---move out of TOML and into auto-core.state.namespace("auto-agents")
---with the json backend. Existing TOML keeps the agent bootstrap rows
---and kb config; this module owns the runtime / panel ambient state.
---
---Why a wrapper rather than direct namespace access at every call site:
---  - **validation** lives here (slot_count range, integer-only
---    width_override) instead of being duplicated at every setter
---  - **mirror sync**: a single watch in setup() keeps `cfg.panel.*`
---    and `aa.state.focused_slot` consistent with the namespace, so
---    reader sites that walk `cfg.panel.slot_count` / `aa.state.
---    focused_slot` keep working unchanged
---  - **migration shim**: the one-shot TOML→namespace seed runs
---    here (called from init.lua's setup once after the TOML load)
---
---Public surface:
---
---  state.setup()                  -- claim namespace; idempotent
---  state.namespace()              -- raw handle (for advanced use)
---  state.get_slot_count()         → integer
---  state.set_slot_count(n)        → ok, err?
---  state.get_width_override()     → integer?
---  state.set_width_override(n?)   → ok, err?
---  state.get_focused_slot()       → integer
---  state.set_focused_slot(slot)
---
---  state.watch_slot_count(cb)     → handle
---  state.watch_width_override(cb) → handle
---  state.watch_focused_slot(cb)   → handle
---
---Each watch_* helper subscribes the callback to
---`state.auto-agents:<key>:changed`. callbacks receive the auto-core
---state-change payload `{ namespace, key, new, old }`.
---@module 'auto-agents.state'

local core = require("auto-core")

local M = {}

local NS_NAME = "auto-agents"

local DEFAULTS = {
  panel = {
    slot_count     = 5,    -- valid range cfg.SLOT_COUNT_MIN..MAX
    width_override = nil,  -- nil = use percentage; integer = pinned cols
  },
  focused_slot = 1,
}

local _ns = nil

---Idempotent claim of the auto-core namespace. Safe to call from
---setup() multiple times — auto-core's namespace registry is
---singleton-per-name.
---@return any  AutoCoreStateNamespace
function M.setup()
  if _ns then return _ns end
  _ns = core.state.namespace(NS_NAME, {
    defaults = DEFAULTS,
    persist  = "json",
  })
  return _ns
end

---Raw namespace handle. Use this for `:get_all()` snapshots, custom
---watches outside the helpers below, or `:persist_now()` flushes.
---@return any
function M.namespace()
  if not _ns then M.setup() end
  return _ns
end

-- ── slot_count ───────────────────────────────────────────────

---@return integer
function M.get_slot_count()
  return M.namespace():get("panel.slot_count")
end

---Set the slot count. Range-validated against the auto-agents
---config module. Returns `(false, err_string)` on invalid input;
---otherwise `(true, nil)` and the namespace fires the change watch.
---@param n integer
---@return boolean ok, string? err
function M.set_slot_count(n)
  local cfg_mod = require("auto-agents.config")
  if type(n) ~= "number" or n ~= math.floor(n)
      or n < cfg_mod.SLOT_COUNT_MIN or n > cfg_mod.SLOT_COUNT_MAX then
    return false, string.format(
      "slot_count must be an integer in [%d..%d]; got %s",
      cfg_mod.SLOT_COUNT_MIN, cfg_mod.SLOT_COUNT_MAX, tostring(n))
  end
  M.namespace():set("panel.slot_count", n)
  return true
end

---@param cb fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any  -- subscribe handle
function M.watch_slot_count(cb)
  return M.namespace():watch("panel.slot_count", cb)
end

-- ── width_override ───────────────────────────────────────────

---@return integer?
function M.get_width_override()
  return M.namespace():get("panel.width_override")
end

---Set or clear the panel width override. `nil` clears (panel falls
---back to the percentage-based resolver). Range-validated against
---the auto-agents config module.
---@param n integer?
---@return boolean ok, string? err
function M.set_width_override(n)
  if n == nil then
    M.namespace():set("panel.width_override", nil)
    return true
  end
  local cfg_mod = require("auto-agents.config")
  if type(n) ~= "number" or n ~= math.floor(n)
      or n < cfg_mod.PANEL_OVERRIDE_MIN or n > cfg_mod.PANEL_OVERRIDE_MAX then
    return false, string.format(
      "width_override must be nil or an integer in [%d..%d]; got %s",
      cfg_mod.PANEL_OVERRIDE_MIN, cfg_mod.PANEL_OVERRIDE_MAX, tostring(n))
  end
  M.namespace():set("panel.width_override", n)
  return true
end

---@param cb fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any
function M.watch_width_override(cb)
  return M.namespace():watch("panel.width_override", cb)
end

-- ── focused_slot ─────────────────────────────────────────────

---@return integer
function M.get_focused_slot()
  return M.namespace():get("focused_slot")
end

---Update the last-focused slot. No range validation here — the
---caller is the focus dispatcher, which has already vetted the
---slot. Persists across nvim restarts (new in v0.2.0; previously
---reset to 1 on every load).
---@param slot integer
function M.set_focused_slot(slot)
  M.namespace():set("focused_slot", slot)
end

---@param cb fun(payload: { namespace: string, key: string, new: any, old: any })
---@return any
function M.watch_focused_slot(cb)
  return M.namespace():watch("focused_slot", cb)
end

-- ── test-only ────────────────────────────────────────────────

---Test-only: clear the namespace cache + every key. Production
---code never calls this.
function M._reset_for_tests()
  if _ns then
    pcall(function()
      _ns:set("panel.slot_count",     DEFAULTS.panel.slot_count)
      _ns:set("panel.width_override", nil)
      _ns:set("focused_slot",         DEFAULTS.focused_slot)
    end)
  end
  _ns = nil
end

return M
