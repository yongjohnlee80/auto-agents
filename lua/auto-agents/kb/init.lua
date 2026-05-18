---Knowledge-base path resolution + scaffolding (D4/D16, M4 chunk A).
---
---Layout is type-specific (see `auto-agents.kb.types`). Every type
---uses the same skeleton — `raw/`, `shared/<subdirs>/`, `agents/` —
---and may declare additional top-level `extra_dirs` (e.g. coding's
---`_templates/`, `archive/`).
---
---Common to every type:
---  <kb_root>/
---  ├── AGENTS.md / CLAUDE.md / GEMINI.md
---  ├── index.md, log.md
---  ├── raw/
---  ├── shared/<type-specific subdirs>/
---  └── agents/<agent-name>/
---
---kb_root resolution.
---
---Agent identities are persistent: jarvis defined in `global.toml`
---should perform identically regardless of which directory the user
---opened nvim in. So default KB path follows where the *config* came
---from, not where the cwd happens to be:
---
---  global agents  → <stdpath('config')>/.auto-agents-config/kb
---                    (one shared KB across all sessions)
---  project agents → <session_project_root>/.auto-agents/kb
---                    (project-local — travels with the repo)
---
---Resolution (in order):
---  1. cfg.kb.root_override   — explicit `[kb].root` in the TOML
---  2. cfg.kb.path            — legacy lua-spec override; expanded for ~
---  3. branch by config_source:
---     - "global" → <stdpath('config')>/.auto-agents-config/kb
---     - else     → <session_project_root>/.auto-agents/kb
---     - fallback (no setup) → <cwd>/.auto-agents/kb
---@module 'auto-agents.kb'

local M = {}

---@return string
function M.root()
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local kb_cfg = cfg.kb or {}
  if kb_cfg.root_override and kb_cfg.root_override ~= "" then
    return vim.fn.expand(kb_cfg.root_override)
  end
  if kb_cfg.path and kb_cfg.path ~= "" then
    return vim.fn.expand(kb_cfg.path)
  end
  if aa.state.config_source == "global" then
    local store = require("auto-agents.config.store")
    return store.config_dir() .. "/kb"
  end
  local base = aa.state.session_project_root
  if not base or base == "" then
    local cwd_mod = require("auto-agents.cwd")
    base = cwd_mod.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  end
  return base .. "/.auto-agents/kb"
end

---Type-aware KB initialization. Idempotent — running it again on an
---existing KB only fills in missing directories and missing files
---(it does NOT overwrite AGENTS.md if the user has edited it).
---
---  1. Creates the type's subdirectories (raw/, shared/, agents/, plus
---     type-specific sub-dirs from `auto-agents.kb.types`).
---  2. Drops a `raw/README.md` declaring immutability.
---  3. Copies the seed `.md` to `<root>/AGENTS.md` if absent (or if
---     `opts.force_schema` is true).
---  4. Drops `CLAUDE.md` and `GEMINI.md` pointers next to AGENTS.md.
---  5. Creates empty `log.md` and `index.md` if absent.
---
---@param root string|nil           -- defaults to M.root()
---@param opts table|nil            -- { type, seed_path, force_schema }
---@return string root
function M.ensure_layout(root, opts)
  root = root or M.root()
  opts = opts or {}
  local aa = require("auto-agents")
  local cfg_kb = (aa.state.config or {}).kb or {}
  local type = opts.type or cfg_kb.type or "general"
  local types = require("auto-agents.kb.types")
  local layout = types.layout(type)

  vim.fn.mkdir(root, "p")
  for _, d in ipairs(layout.dirs) do vim.fn.mkdir(root .. "/" .. d, "p") end

  -- raw/README.md: immutability declaration. Only written once; the
  -- user can edit it freely after that.
  local raw_readme = root .. "/raw/README.md"
  if vim.fn.filereadable(raw_readme) == 0 then
    local f = io.open(raw_readme, "w")
    if f then
      f:write(table.concat({
        "# raw/ — immutable source material",
        "",
        "Files in this directory are **evidence**: original sources, exports,",
        "transcripts, datasets. Agents read from here but do not edit, rename,",
        "or delete content.",
        "",
        "To retire a source, move it to `archive/raw/<original-path>` (creating",
        "the dir if needed) and update citations in the same change. Outright",
        "deletion is reserved for accidentally-clipped, wrong, or sensitive",
        "material — and citing pages must be scrubbed at the same time.",
        "",
        "Synthesis goes in `shared/`, not here.",
        "",
      }, "\n"))
      f:close()
    end
  end

  -- AGENTS.md: copy from seed if absent (or forced). Serves as the
  -- canonical schema doc. CLAUDE.md and GEMINI.md sit alongside as
  -- thin pointers so each kind's auto-load picks up the same contract.
  local agents_md = root .. "/AGENTS.md"
  local seed_path = opts.seed_path or types.seed_path(type) or types.seed_path("general")
  if seed_path and (opts.force_schema or vim.fn.filereadable(agents_md) == 0) then
    local f = io.open(seed_path, "r")
    if f then
      local content = f:read("*a"); f:close()
      local out = io.open(agents_md, "w")
      if out then out:write(content); out:close() end
    end
  end

  -- KB_RULES.md: universal cross-KB-type rules (log.md weekly rotation,
  -- mandatory dual-surface frontmatter). Shipped as `_kb-rules.md`
  -- alongside the per-type seeds; copied into every new KB so the rules
  -- live in the KB tree itself, not implicitly in the plugin. Same
  -- absent-or-forced semantics as AGENTS.md.
  local kb_rules_md = root .. "/KB_RULES.md"
  local kb_rules_seed = types.seeds_dir() .. "/_kb-rules.md"
  if vim.fn.filereadable(kb_rules_seed) == 1
      and (opts.force_schema or vim.fn.filereadable(kb_rules_md) == 0) then
    local f = io.open(kb_rules_seed, "r")
    if f then
      local content = f:read("*a"); f:close()
      local out = io.open(kb_rules_md, "w")
      if out then out:write(content); out:close() end
    end
  end

  local pointer_body = table.concat({
    "# %s",
    "",
    "Canonical operating instructions live in [AGENTS.md](./AGENTS.md).",
    "",
    "%s should treat `AGENTS.md` as the single source of truth for this",
    "knowledge base's schema, layout, and operations.",
    "",
    "This file exists only as a compatibility entry point for tools that",
    "auto-load `%s.md`.",
    "",
  }, "\n")
  local pointers = {
    { name = "CLAUDE", file = "CLAUDE.md" },
    { name = "GEMINI", file = "GEMINI.md" },
  }
  for _, p in ipairs(pointers) do
    local path = root .. "/" .. p.file
    if vim.fn.filereadable(path) == 0 then
      local f = io.open(path, "w")
      if f then
        f:write(string.format(pointer_body, p.name, p.name, p.name))
        f:close()
      end
    end
  end

  -- log.md and index.md as append-only stubs. log.md is created with
  -- the rotation-pointer header per KB_RULES.md §R1 so fresh KBs start
  -- in the rotated shape from day one (no migration needed when log
  -- grows past the first ISO week).
  local log = root .. "/log.md"
  if vim.fn.filereadable(log) == 0 then
    local f = io.open(log, "w")
    if f then
      f:write(table.concat({
        "# auto-agents knowledge-base log",
        "",
        "> **Current ISO week only.** Closed weeks live in `log/YYYY-W<NN>.md`;",
        "> weeks older than 3 months live in `archive/log/YYYY-W<NN>.md`.",
        "> See [`KB_RULES.md`](./KB_RULES.md) §R1 for the rotation procedure.",
        "",
      }, "\n"))
      f:close()
    end
  end
  local index = root .. "/index.md"
  if vim.fn.filereadable(index) == 0 then
    local f = io.open(index, "w")
    if f then
      f:write(table.concat({
        "# index",
        "",
        "Catalog of pages in this knowledge base. Agents update this on every",
        "new `shared/` page — one entry per page with a one-line summary.",
        "",
      }, "\n"))
      f:close()
    end
  end

  return root
end

---Append a one-line entry to log.md (timestamp + message).
---@param msg string
function M.log(msg)
  local root = M.root()
  M.ensure_layout(root)
  local f = io.open(root .. "/log.md", "a")
  if not f then return end
  f:write(string.format("- %s — %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
  f:close()
end

---Resolve a relative path against the KB root.
---@param relative string
---@return string
function M.resolve(relative)
  local root = M.root()
  -- Strip a leading slash so users can write either "shared/foo" or "/shared/foo".
  relative = relative:gsub("^/+", "")
  return root .. "/" .. relative
end

return M
