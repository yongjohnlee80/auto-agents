---TOML config store for auto-agents.nvim.
---
---Resolution order at setup():
---  1. `<config_dir>/<session-project-key>.toml`  (project-specific)
---  2. `<config_dir>/global.toml`                 (default, shared across projects)
---  3. nothing                                    (admin auto-engages add wizard)
---
---`<config_dir>` defaults to `<stdpath('config')>/.auto-agents-config/`.
---
---File schema (subset of TOML — see vendor/toml.lua):
---
---    [project]
---    cwd        = "/abs/path"          # informational; original cwd at init
---    created_at = "2026-05-01T12:34Z"  # informational
---
---    [kb]
---    root = "/abs/path/to/kb"          # absolute; sharable across projects
---
---    [[agents]]
---    slot          = 1
---    kind          = "claude"          # claude|codex|gemini|copilot|generic
---    name          = "main"
---    title         = "Claude"
---    role          = "..."             # optional
---    cwd           = "..."             # optional override
---    cmd           = ["bin", "--flag"] # optional override
---    allowed_paths = ["src/", "tests/"]
---    manager       = 2                 # optional: managing slot
---    kb_scope      = "shared"          # shared|private|isolated
---    bottom_margin = 1                 # optional
---
---@module 'auto-agents.config.store'

local toml = require("auto-agents.vendor.toml")

local M = {}

local SECTION_ORDER = { "project", "kb", "agents" }
local AGENT_KEY_ORDER = {
  "slot", "kind", "name", "title", "role", "cwd", "cmd",
  "allowed_paths", "manager", "kb_scope", "bottom_margin",
}
local PROJECT_KEY_ORDER = { "cwd", "created_at" }
local KB_KEY_ORDER = { "root", "type", "seed" }

---Directory holding project + global TOML files. Dot-prefixed so it
---doesn't visually collide with project KB dirs that happen to live
---in the same parent (e.g. when the nvim config dir is itself a
---project, you'd otherwise see `auto-agents/` and `.auto-agents/`
---side-by-side).
---@return string
function M.config_dir()
  return vim.fn.stdpath("config") .. "/.auto-agents-config"
end

---Path to the global default TOML.
---@return string
function M.global_path()
  return M.config_dir() .. "/global.toml"
end

---Path to the per-project TOML for `key`.
---@param key string  -- 16-char project key (sha16 of root)
---@return string
function M.project_path(key)
  return M.config_dir() .. "/" .. key .. ".toml"
end

---@return boolean
local function file_exists(path)
  local stat = vim.uv and vim.uv.fs_stat(path) or vim.loop.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---@param path string
---@return string|nil content
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

---@param path string
---@param content string
---@return boolean ok
---@return string|nil err
local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true, nil
end

---Parse a TOML file's content into the canonical { project, kb, agents } shape.
---Missing sections become nil/empty so callers don't have to guard.
---@param content string
---@return { project: table?, kb: table?, agents: table[] }
local function normalize(content)
  local ok, data = pcall(toml.decode, content)
  if not ok then
    require("auto-agents.logger").warn("config.store",
      "failed to parse TOML: " .. tostring(data))
    return { project = nil, kb = nil, agents = {} }
  end
  return {
    project = data.project,
    kb = data.kb,
    agents = data.agents or {},
  }
end

---Load the active config for the session. Tries project file first,
---then global, then returns nil.
---
---@param project_key string
---@return { project: table?, kb: table?, agents: table[] }|nil loaded
---@return "project"|"global"|"none" source
function M.load(project_key)
  local proj_path = M.project_path(project_key)
  if file_exists(proj_path) then
    local content = read_file(proj_path) or ""
    return normalize(content), "project"
  end
  local global_path = M.global_path()
  if file_exists(global_path) then
    local content = read_file(global_path) or ""
    return normalize(content), "global"
  end
  return nil, "none"
end

---Determine which file the current session writes to. Project file if it
---exists; else the global file. Mutations always land where the user is
---reading from. Use M.init_project() to create a project-specific file.
---@param project_key string
---@return string path
---@return "project"|"global" target
function M.active_path(project_key)
  local proj_path = M.project_path(project_key)
  if file_exists(proj_path) then return proj_path, "project" end
  return M.global_path(), "global"
end

---Write the canonical shape to a specific path (creates parent dir).
---@param path string
---@param data { project: table?, kb: table?, agents: table[]? }
---@return boolean ok
---@return string|nil err
function M.write(path, data)
  local payload = {
    project = data.project,
    kb = data.kb,
    agents = data.agents or {},
  }
  local encoded = toml.encode(payload, {
    section_order = SECTION_ORDER,
    key_order = {
      project = PROJECT_KEY_ORDER,
      kb = KB_KEY_ORDER,
      agents = AGENT_KEY_ORDER,
    },
  })
  return write_file(path, encoded .. "\n")
end

---Save the live in-memory config back to whichever file the session is
---reading from (project or global). Used after agent add/edit/rename/move.
---@return boolean ok
---@return string path
function M.save_current()
  local aa = require("auto-agents")
  local cfg = aa.state.config
  local key = aa.state.session_project_key
  if not cfg or not key then return false, "" end
  local path, target = M.active_path(key)

  local existing = file_exists(path) and normalize(read_file(path) or "") or { agents = {} }
  local payload = {
    project = existing.project,
    kb = existing.kb,
    agents = (cfg.agents and cfg.agents.bootstrap) or {},
  }
  -- Carry over the live KB settings → [kb] so wizard mutations stick.
  if cfg.kb then
    if cfg.kb.root_override then
      payload.kb = payload.kb or {}
      payload.kb.root = cfg.kb.root_override
    end
    if cfg.kb.type then
      payload.kb = payload.kb or {}
      payload.kb.type = cfg.kb.type
    end
    if cfg.kb.seed_path then
      payload.kb = payload.kb or {}
      payload.kb.seed = cfg.kb.seed_path
    end
  end

  local ok = M.write(path, payload)
  if ok then
    -- Reflect the just-written file in the live state. If we previously
    -- resolved to 'none' and just created global.toml, source flips to
    -- 'global'; same for project. Matters for `config show` output.
    aa.state.config_source = target
    require("auto-agents.logger").debug("config.store", "saved → " .. path)
  end
  return ok, path
end

---Create a fresh per-project file from scratch (refuses if one exists).
---Used by `:AutoAgentsProject init`.
---@param project_key string
---@param session_cwd string
---@param kb_root string|nil  -- nil = no [kb].root yet
---@return boolean ok
---@return string|nil err
---@return string|nil path
function M.init_project(project_key, session_cwd, kb_root)
  local path = M.project_path(project_key)
  if file_exists(path) then
    return false, "already exists: " .. path, path
  end
  local payload = {
    project = {
      cwd = session_cwd,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
    kb = kb_root and { root = kb_root } or nil,
    agents = {},
  }
  local ok, err = M.write(path, payload)
  if not ok then return false, err, path end
  return true, nil, path
end

---Duplicate another project's config into the current session's project
---file. Copies [[agents]] and [kb].root verbatim — agents live separately,
---KB is shared.
---@param current_key string
---@param current_cwd string
---@param source_path string  -- absolute path to source TOML file
---@return boolean ok
---@return string|nil err
---@return string|nil path
function M.import_from(current_key, current_cwd, source_path)
  if not file_exists(source_path) then
    return false, "source not found: " .. source_path
  end
  local src = normalize(read_file(source_path) or "")
  local target_path = M.project_path(current_key)
  if file_exists(target_path) then
    return false, "current project already has a config: " .. target_path, target_path
  end

  -- Freeze the source's effective KB path into [kb].root so imported
  -- agents keep reading the same KB they had at the source. Without
  -- this, an import from global → project would silently switch the
  -- agent's KB from the global path to a fresh per-project default,
  -- breaking the "agent is persistent" model.
  local kb = src.kb and vim.deepcopy(src.kb) or {}
  if not kb.root then
    if source_path == M.global_path() then
      kb.root = M.config_dir() .. "/kb"
    else
      -- Source is another project. The source TOML had no explicit
      -- [kb].root, so it was using its own project's default
      -- (<source-project-cwd>/.auto-agents/kb). Bake that in.
      local src_cwd = (src.project and src.project.cwd) or current_cwd
      kb.root = src_cwd .. "/.auto-agents/kb"
    end
  end

  local payload = {
    project = {
      cwd = current_cwd,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
    kb = kb,
    agents = src.agents,
  }
  local ok, err = M.write(target_path, payload)
  if not ok then return false, err, target_path end
  return true, nil, target_path
end

---Delete the per-project file. KB dir on disk is untouched. After this
---the session falls back to global on next read.
---@param project_key string
---@return boolean removed
---@return string path
function M.remove_project(project_key)
  local path = M.project_path(project_key)
  if not file_exists(path) then return false, path end
  local ok = pcall(vim.fn.delete, path)
  return ok, path
end

---List every TOML file in the config dir, with a parsed `[project].cwd`
---when present so the user can pick one for `project import`.
---@return { key: string, path: string, cwd: string|nil, is_global: boolean }[]
function M.list_known()
  local dir = M.config_dir()
  local out = {}
  if vim.fn.isdirectory(dir) == 0 then return out end
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if name:match("%.toml$") then
      local path = dir .. "/" .. name
      local key = name:gsub("%.toml$", "")
      local data = normalize(read_file(path) or "")
      table.insert(out, {
        key = key,
        path = path,
        cwd = data.project and data.project.cwd or nil,
        is_global = (key == "global"),
      })
    end
  end
  return out
end

return M
