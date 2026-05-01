---Per-project persistence of agents.bootstrap mutations (M3.4).
---
---User edits via the form / agent rename / agent move are durable —
---they're written to a project-keyed JSON file under `<stdpath('data')>
----/auto-agents/<project-key>.json`. On the next setup() the file is
---loaded and the lazy-spec bootstrap is replaced with the persisted
---version (so user mutations win across restarts).
---
---This is the JSON state sink described in D12 (vs. TOML for the
---human-edited source-of-truth schema). When the TOML loader lands
---in M3+/M4, the JSON keeps the runtime additions while the TOML
---remains hand-edited.
---@module 'auto-agents.agent.persist'

local M = {}

---@return string  -- absolute directory path
local function data_dir()
  return vim.fn.stdpath("data") .. "/auto-agents"
end

---Project key: the git root (or cwd if not in a git repo) hashed to a
---stable directory-friendly slug. Keeps state per-project.
---@return string
local function project_key()
  local cwd_mod = require("auto-agents.cwd")
  local root = cwd_mod.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  -- sha256 returns a 64-char hex; trim to 16 for filesystem readability.
  return vim.fn.sha256(root):sub(1, 16)
end

---@return string  -- absolute path of this project's persistence file
function M.file_path()
  return data_dir() .. "/" .. project_key() .. ".json"
end

---Write the current bootstrap to JSON. Idempotent; no-op if encoding
---fails. Returns false on error.
---@param bootstrap table[]
---@return boolean ok
function M.save(bootstrap)
  local logger = require("auto-agents.logger")
  vim.fn.mkdir(data_dir(), "p")
  local path = M.file_path()
  local ok, encoded = pcall(vim.json.encode, { bootstrap = bootstrap })
  if not ok then
    logger.error("persist", "failed to encode bootstrap: " .. tostring(encoded))
    return false
  end
  local f = io.open(path, "w")
  if not f then
    logger.error("persist", "failed to open " .. path .. " for writing")
    return false
  end
  f:write(encoded)
  f:close()
  logger.debug("persist", "wrote " .. #bootstrap .. " entries to " .. path)
  return true
end

---Load the persisted bootstrap, if any.
---@return table[]|nil bootstrap
function M.load()
  local logger = require("auto-agents.logger")
  local path = M.file_path()
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return nil end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or type(data.bootstrap) ~= "table" then
    logger.warn("persist", "invalid JSON at " .. path .. "; ignoring")
    return nil
  end
  return data.bootstrap
end

---Delete the persisted file (revert to lazy-spec bootstrap on next setup).
---@return boolean ok
function M.reset()
  local path = M.file_path()
  local ok, _ = pcall(vim.fn.delete, path)
  return ok
end

---Convenience: save the current in-memory state.config.agents.bootstrap.
---@return boolean ok
function M.save_current()
  local cfg = require("auto-agents").state.config
  if not cfg or not cfg.agents or not cfg.agents.bootstrap then return false end
  return M.save(cfg.agents.bootstrap)
end

return M
