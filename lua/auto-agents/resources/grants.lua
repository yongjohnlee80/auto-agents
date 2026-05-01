---Resource grants — coordination metadata that propagates to agent
---spawn time as env vars (D6: best-effort, not OS-level sandboxing).
---
---Grant kinds (M5.A/B):
---  path    A directory the agent is permitted to touch. Multiple per
---          slot, surface as AUTO_AGENTS_ALLOWED_PATHS=p1:p2:...
---  cwd     Single working directory for the agent's spawn (replaces
---          the cwd.resolve default). At most one per slot.
---  env     (M5.C) An env var name to pass through.
---  cmd     (M5.C) Whitelisted command for manager-routed dispatch.
---
---Persistence: per-project JSON keyed by sha256(git_root || cwd) under
---`<stdpath('data')>/auto-agents/<key>-grants.json`. Bootstrap lives in
---a TOML in `<stdpath('config')>/.auto-agents-config/<key>.toml` (see
---`auto-agents.config.store`); grants stay JSON for now since they're
---internal coordination state, not human-edited.
---@module 'auto-agents.resources.grants'

local M = {}

---@class AutoAgentsResourceGrant
---@field slot integer
---@field kind "path"|"cwd"|"env"|"cmd"
---@field value string
---@field granted_at integer
---@field note string|nil

---In-memory store: list of grants. Loaded on setup, mutated by add/
---revoke, persisted after each mutation.
M._grants = {}

---@return string  -- absolute file path
function M.file_path()
  -- Prefer the session-cached project key so :cd doesn't move our state.
  -- Falls back to live resolution if setup() hasn't run yet (e.g. tests).
  local key = (require("auto-agents").state or {}).session_project_key
  if not key then
    local cwd_mod = require("auto-agents.cwd")
    local root = cwd_mod.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
    key = vim.fn.sha256(root):sub(1, 16)
  end
  local dir = vim.fn.stdpath("data") .. "/auto-agents"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. key .. "-grants.json"
end

---Load persisted grants into M._grants. Idempotent — safe to call from
---setup() multiple times.
function M.load()
  local path = M.file_path()
  local f = io.open(path, "r")
  if not f then M._grants = {}; return end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content or "")
  if ok and type(data) == "table" and type(data.grants) == "table" then
    M._grants = data.grants
  else
    M._grants = {}
  end
end

---Persist M._grants to disk.
---@return boolean ok
function M.save()
  local logger = require("auto-agents.logger")
  local path = M.file_path()
  local ok, encoded = pcall(vim.json.encode, { grants = M._grants })
  if not ok then
    logger.error("grants", "encode failed: " .. tostring(encoded))
    return false
  end
  local f = io.open(path, "w")
  if not f then logger.error("grants", "open failed: " .. path); return false end
  f:write(encoded)
  f:close()
  return true
end

---Add a grant. For 'cwd' kind, replaces any existing cwd grant for
---the slot. For 'path' kind, deduplicates against existing.
---@param slot integer
---@param kind "path"|"cwd"|"env"|"cmd"
---@param value string
---@param note string|nil
---@return boolean added
function M.add(slot, kind, value, note)
  if not value or value == "" then return false end
  if kind == "cwd" then
    for i = #M._grants, 1, -1 do
      local g = M._grants[i]
      if g.slot == slot and g.kind == "cwd" then table.remove(M._grants, i) end
    end
  else
    -- Dedup
    for _, g in ipairs(M._grants) do
      if g.slot == slot and g.kind == kind and g.value == value then
        return false
      end
    end
  end
  table.insert(M._grants, {
    slot = slot,
    kind = kind,
    value = value,
    granted_at = os.time(),
    note = note,
  })
  M.save()
  return true
end

---Remove the first grant matching (slot, kind, value). For 'cwd' or
---'env'/'cmd', value can be nil to remove any of that kind for the
---slot.
---@param slot integer
---@param kind string
---@param value string|nil
---@return boolean removed
function M.remove(slot, kind, value)
  for i = #M._grants, 1, -1 do
    local g = M._grants[i]
    if g.slot == slot and g.kind == kind
      and (value == nil or g.value == value) then
      table.remove(M._grants, i)
      M.save()
      return true
    end
  end
  return false
end

---Return all grants matching the filter (any field nil = wildcard).
---@param filter { slot?: integer, kind?: string }|nil
---@return AutoAgentsResourceGrant[]
function M.list(filter)
  filter = filter or {}
  local out = {}
  for _, g in ipairs(M._grants) do
    if (filter.slot == nil or g.slot == filter.slot)
      and (filter.kind == nil or g.kind == filter.kind) then
      table.insert(out, g)
    end
  end
  return out
end

---Convenience: paths granted to a slot.
---@param slot integer
---@return string[]
function M.paths_for(slot)
  local out = {}
  for _, g in ipairs(M._grants) do
    if g.slot == slot and g.kind == "path" then
      table.insert(out, g.value)
    end
  end
  return out
end

---Convenience: explicit cwd for a slot, if granted.
---@param slot integer
---@return string|nil
function M.cwd_for(slot)
  for _, g in ipairs(M._grants) do
    if g.slot == slot and g.kind == "cwd" then return g.value end
  end
  return nil
end

return M
