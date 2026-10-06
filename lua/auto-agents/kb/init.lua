---The KB as auto-agents sees it from v0.3.0 (ADR 1791209946 §7):
---the project's primary KB, owned by `auto-core.kb`. auto-agents no
---longer scaffolds, syncs, ingests or logs a KB — that lives in AutoDoc.
---
---  M.root()                 shim over auto-core.kb.root() for this minor
---  M.legacy_root()          the pre-v0.3.0 resolution (its fallback)
---  M.primary()              { workspace, root } | nil
---  M.agent_env(primary)     the KB part of a spawned agent's env
---  M.sync_managed(primary)  bring the primary's managed documents up to date before a spawn
---  M.todo_convention_doc(root)  AUTO_AGENTS_TODOS_CONVENTION_DOC
---
---Legacy resolution (what auto-core.kb's first-run import records):
---  1. cfg.kb.root_override   — `[kb].root` in the TOML
---  2. cfg.kb.path            — legacy lua-spec override; expanded for ~
---  3. by config_source:
---     - "global" → <stdpath('config')>/.auto-agents-config/kb
---     - else     → <session_project_root>/.auto-agents/kb when that folder exists, else the global
---                  KB (v0.3.0 no longer creates a project KB, so a project with its own config and
---                  no KB folder gets the global one until a primary is chosen)
---     - fallback (no setup) → <cwd>/.auto-agents/kb, on the same terms
---@module 'auto-agents.kb'

local M = {}

---The pre-v0.3.0 resolution: `[kb].root`, the lua-spec `kb.path`, then
---the global KB for a global config or `<project>/.auto-agents/kb`.
---It answers whether or not that directory exists. auto-core.kb's
---first-run import records it as the project's primary once (only when
---it exists), and `M.root()` falls back to it while there is none.
---@return string
function M.legacy_root()
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local kb_cfg = cfg.kb or {}
  if kb_cfg.root_override and kb_cfg.root_override ~= "" then
    return vim.fn.expand(kb_cfg.root_override)
  end
  if kb_cfg.path and kb_cfg.path ~= "" then
    return vim.fn.expand(kb_cfg.path)
  end
  local global = require("auto-agents.config.store").config_dir() .. "/kb"
  if aa.state.config_source == "global" then
    return global
  end
  local base = aa.state.session_project_root
  if not base or base == "" then
    local cwd_mod = require("auto-agents.cwd")
    base = cwd_mod.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  end
  local project = base .. "/.auto-agents/kb"
  -- the project's own KB folder when it has one; else the global KB, as a project without its own
  -- config gets (the explicit overrides above are honoured as written, existing or not)
  if vim.fn.isdirectory(project) == 0 and vim.fn.isdirectory(global) == 1 then
    return global
  end
  return project
end

---auto-core.kb, or nil when the installed auto-core predates it.
---@return table|nil
local function core_kb()
  local ok, mod = pcall(require, "auto-core.kb")
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- Depth of `M.root()` calls in flight. auto-core.kb's first-run import
-- calls back into `M.root()`; a nested call answers from the legacy
-- resolution without asking auto-core again, so the shim terminates
-- even against an auto-core whose own re-entrancy guard is missing.
local _root_depth = 0

---The KB root: a shim over `auto-core.kb.root()` for the v0.3 minor
---(ADR 1791209946 §7). auto-core answers the project's primary, then
---`$AUTO_AGENTS_KB_ROOT`, then its first-run import of `legacy_root()`.
---When it answers nothing (or is absent), the legacy resolution answers.
---@return string
function M.root()
  if _root_depth == 0 then
    local kb = core_kb()
    if kb and type(kb.root) == "function" then
      _root_depth = _root_depth + 1
      local ok, r = pcall(kb.root)
      _root_depth = _root_depth - 1
      if ok and type(r) == "string" and r ~= "" then return r end
    end
  end
  return M.legacy_root()
end

---The project's primary KB `{ workspace, root }`, or nil.
---
---A project that has no primary yet gets auto-core's first-run import
---once (`auto-core.kb.root()` records the legacy root when it exists),
---so an existing KB carries over to v0.3.0 without a manual step.
---@return { workspace: string|nil, root: string }|nil
function M.primary()
  local kb = core_kb()
  if not kb or type(kb.primary) ~= "function" then return nil end
  local ok, p = pcall(kb.primary)
  if ok and type(p) == "table" and type(p.root) == "string" and p.root ~= "" then
    return p
  end
  if type(kb.root) == "function" then pcall(kb.root) end
  ok, p = pcall(kb.primary)
  if ok and type(p) == "table" and type(p.root) == "string" and p.root ~= "" then
    return p
  end
  return nil
end

---Before a spawn, ask auto-core to bring the primary KB's managed documents
---(AutoDoc's `KB_OPERATIONS.md` and schema) up to the newest copies AutoDoc
---provided (`auto-core.kb.sync_managed`, auto-core v0.3.1+). The agent then
---starts on the installed AutoDoc's operations document, and its revision gate
---re-reads it when the revision moved. auto-core is the only writer: this asks,
---it never writes. Soft: no primary, or an auto-core without the API, does
---nothing and answers nil.
---@param primary { workspace: string|nil, root: string }|nil
---@return table|nil report  auto-core's report, when it ran
function M.sync_managed(primary)
  if type(primary) ~= "table" or type(primary.root) ~= "string" or primary.root == "" then return nil end
  local kb = core_kb()
  if not kb or type(kb.sync_managed) ~= "function" then return nil end
  local log = require("auto-agents.log")
  local ok, sok, err, rep = pcall(kb.sync_managed, primary.root)
  if not ok or not sok then
    log.warn("kb", "syncing the managed KB documents in " .. primary.root .. " failed: " .. tostring(ok and err or sok))
    return nil
  end
  if rep and #rep.updated > 0 then
    log.info("kb", "updated " .. table.concat(rep.updated, ", ") .. " in " .. primary.root .. " before the spawn")
  end
  return rep
end

---The KB part of a spawned agent's environment (ADR 1791209946 §7):
---`AUTO_AGENTS_KB_ROOT`, `AUTODOC_WORKSPACE` when the primary names one,
---and `AUTODOC_KB_OPERATIONS_DOC` when `<root>/KB_OPERATIONS.md` exists.
---No primary, no KB environment.
---@param primary { workspace: string|nil, root: string }|nil
---@return table<string,string>
function M.agent_env(primary)
  local env = {}
  if type(primary) ~= "table" or type(primary.root) ~= "string" or primary.root == "" then
    return env
  end
  env.AUTO_AGENTS_KB_ROOT = primary.root
  if type(primary.workspace) == "string" and primary.workspace ~= "" then
    env.AUTODOC_WORKSPACE = primary.workspace
  end
  local ops = primary.root .. "/KB_OPERATIONS.md"
  if vim.fn.filereadable(ops) == 1 then
    env.AUTODOC_KB_OPERATIONS_DOC = ops
  end
  return env
end

---The bundled todo-handling convention (`kb-seeds/_todo-handling.md`).
---@return string|nil
function M.todo_convention_seed()
  local src = debug.getinfo(1, "S").source
  if type(src) ~= "string" or src:sub(1, 1) ~= "@" then return nil end
  local root = src:sub(2):match("^(.*)/lua/auto%-agents/kb/init%.lua$")
  if not root then return nil end
  local seed = root .. "/kb-seeds/_todo-handling.md"
  if vim.fn.filereadable(seed) == 1 then return seed end
  return nil
end

---The todo-handling convention for `AUTO_AGENTS_TODOS_CONVENTION_DOC`.
---The document is unchanged; only its folder follows the KB layout:
---`<root>/conventions/` (KB v2), then `<root>/shared/conventions/`
---(before the migration), then the bundled seed, so an agent always
---gets a convention even when the project has no primary KB.
---@param root string|nil
---@return string|nil
function M.todo_convention_doc(root)
  if type(root) == "string" and root ~= "" then
    for _, rel in ipairs({ "/conventions/todo-handling.md",
                           "/shared/conventions/todo-handling.md" }) do
      if vim.fn.filereadable(root .. rel) == 1 then return root .. rel end
    end
  end
  return M.todo_convention_seed()
end

return M
