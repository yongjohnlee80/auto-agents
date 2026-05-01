---Manager designation (M5.C). Records a directional relationship: the
---agent in slot `subordinate` is managed by the agent in slot `manager`.
---Stored on the bootstrap entry (e.g. `entry.manager = <slot-or-name>`)
---— piggybacks on the M3.4 persistence so it survives restart.
---
---Per-D17/D18 v0.1.0 scope: this is **metadata only**. Concrete
---behaviors that consult the relationship (manager-routed grant
---requests via inbox FIFO, Tier-2 message routing) are deferred. The
---admin can set/show the relationship now so the data model is in
---place when the runtime hooks land.
---@module 'auto-agents.resources.manager'

local M = {}

---Set slot `s` to be managed by slot `manager_slot`. Stores
---`entry.manager = <manager_slot>` on the bootstrap entry. Pass nil
---for manager_slot to clear the designation.
---@param subordinate integer
---@param manager_slot integer|nil
---@return boolean ok
---@return string|nil err
function M.set(subordinate, manager_slot)
  local aa = require("auto-agents")
  local cfg = aa.state.config
  if not cfg or not cfg.agents or not cfg.agents.bootstrap then
    return false, "auto-agents.setup() must be called first"
  end
  if subordinate == manager_slot then
    return false, "an agent cannot manage itself"
  end
  local entry
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == subordinate then entry = e; break end
  end
  if not entry then
    return false, "slot " .. subordinate .. " has no bootstrap entry"
  end
  if manager_slot then
    -- Verify manager exists.
    local has_manager = false
    for _, e in ipairs(cfg.agents.bootstrap) do
      if e.slot == manager_slot then has_manager = true; break end
    end
    if not has_manager then
      return false, "manager slot " .. manager_slot .. " has no bootstrap entry"
    end
  end
  entry.manager = manager_slot  -- nil clears
  pcall(function() require("auto-agents.agent.persist").save_current() end)
  return true, nil
end

---Get the manager slot for a given subordinate slot.
---@param subordinate integer
---@return integer|nil
function M.get(subordinate)
  local aa = require("auto-agents")
  local cfg = aa.state.config
  if not cfg or not cfg.agents or not cfg.agents.bootstrap then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == subordinate then
      local mgr = e.manager
      if type(mgr) == "number" then return mgr end
      -- Backward-compat: if a string was passed (from form), resolve by name.
      if type(mgr) == "string" then
        for _, candidate in ipairs(cfg.agents.bootstrap) do
          if candidate.name == mgr then return candidate.slot end
        end
      end
    end
  end
  return nil
end

---List all manager → subordinate(s) relationships.
---@return table<integer, integer[]>  -- { [manager_slot] = subordinate_slots[] }
function M.list_chains()
  local aa = require("auto-agents")
  local cfg = aa.state.config
  if not cfg or not cfg.agents or not cfg.agents.bootstrap then return {} end
  local chains = {}
  for _, e in ipairs(cfg.agents.bootstrap) do
    local mgr = M.get(e.slot)
    if mgr then
      chains[mgr] = chains[mgr] or {}
      table.insert(chains[mgr], e.slot)
    end
  end
  return chains
end

return M
