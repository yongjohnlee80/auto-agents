---Resources / permissions module entry point. Re-exports the grants
---API and the env helpers that propagate grants to spawn time.
---@module 'auto-agents.resources'

local M = {}

local grants = require("auto-agents.resources.grants")
local manager = require("auto-agents.resources.manager")

M.grants = grants
M.manager = manager

---Compute env vars for a slot's grants. Path grants surface as
---AUTO_AGENTS_ALLOWED_PATHS (colon-separated). Currently just the
---path-allowlist; env/cmd grants land in M5.C.
---@param slot integer
---@return table<string,string>
function M.env_for(slot)
  local paths = grants.paths_for(slot)
  if #paths == 0 then return {} end
  return { AUTO_AGENTS_ALLOWED_PATHS = table.concat(paths, ":") }
end

---Resolve the effective cwd for a slot given the existing cwd resolver
---chain. Order: explicit `resource cwd` grant > first path grant >
---caller-supplied default (cwd.resolve return value).
---@param slot integer
---@param fallback string|nil
---@return string|nil
function M.cwd_for(slot, fallback)
  local explicit = grants.cwd_for(slot)
  if explicit then return explicit end
  local paths = grants.paths_for(slot)
  if #paths > 0 then return paths[1] end
  return fallback
end

return M
