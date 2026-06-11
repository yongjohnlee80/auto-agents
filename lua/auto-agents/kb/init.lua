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

---ADR-0039 Batch C: every scaffold write goes through auto-core's
---atomic primitive (auto-core >= 0.1.58) so a crash mid-write can't
---leave a truncated AGENTS.md / KB_RULES.md / index.md behind — these
---are user-facing persistence, not scratch. Failures are logged
---instead of silently swallowed (C5 spirit).
---@param path string
---@param text string
---@return boolean ok
local function atomic_write(path, text)
  local ok, err = require("auto-core.fs.atomic").write(path, text, { mkdir = true })
  if not ok then
    require("auto-agents.log").warn("kb",
      "write failed for " .. path .. ": " .. tostring(err))
  end
  return ok
end

---Read `src` fully and atomically write it to `dst`.
---@param src string
---@param dst string
---@return boolean ok
local function copy_file(src, dst)
  local f = io.open(src, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  return atomic_write(dst, content)
end

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
    atomic_write(raw_readme, table.concat({
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
  end

  -- AGENTS.md: copy from seed if absent (or forced). Serves as the
  -- canonical schema doc. CLAUDE.md and GEMINI.md sit alongside as
  -- thin pointers so each kind's auto-load picks up the same contract.
  local agents_md = root .. "/AGENTS.md"
  local seed_path = opts.seed_path or types.seed_path(type) or types.seed_path("general")
  if seed_path and (opts.force_schema or vim.fn.filereadable(agents_md) == 0) then
    copy_file(seed_path, agents_md)
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
    copy_file(kb_rules_seed, kb_rules_md)
  end

  -- RULES.md: per-type rules file (optional). When the seed bundle
  -- ships a `_<type>-rules.md` next to the per-type AGENTS.md seed,
  -- copy it to <kb_root>/RULES.md so the per-library partition /
  -- filename / hash spec lives in the KB tree itself. First-class
  -- consumer: the `library` type (auto-agents v0.2.24+). Future
  -- types can opt in by shipping their own `_<type>-rules.md`.
  -- Generic mechanism — no per-type branching here.
  local type_rules_seed = types.seeds_dir() .. "/_" .. type .. "-rules.md"
  local rules_md = root .. "/RULES.md"
  if vim.fn.filereadable(type_rules_seed) == 1
      and (opts.force_schema or vim.fn.filereadable(rules_md) == 0) then
    copy_file(type_rules_seed, rules_md)
  end

  -- v0.2.40: ship the todo-handling convention seed into every
  -- KB (regardless of type) so agents learn the per-project
  -- policy for `auto-core.todo` task handling. The seed lives at
  -- `<seeds>/_todo-handling.md` and copies to
  -- `<kb>/shared/conventions/todo-handling.md`.
  --
  -- Absent-only — per-project customizations survive plugin
  -- updates. To re-seed (overwrite local), the user passes
  -- `force_schema = true` or deletes the existing file. The
  -- seed's `revision:` bumps are tracked by the convention
  -- itself; agents store the last-ingested revision in their
  -- local memory and re-read on change (the doc explains the
  -- protocol). The host does not propagate seed revisions on
  -- its own.
  do
    local todo_seed = types.seeds_dir() .. "/_todo-handling.md"
    local todo_dest = root .. "/shared/conventions/todo-handling.md"
    if vim.fn.filereadable(todo_seed) == 1
        and (opts.force_schema or vim.fn.filereadable(todo_dest) == 0)
    then
      -- copy_file's atomic write mkdir-p's shared/conventions itself.
      copy_file(todo_seed, todo_dest)
    end
  end

  -- Per-type _templates/ bundle (optional). When the seed bundle
  -- ships a `<type>-templates/` directory alongside the seed, copy
  -- every file in it to <kb_root>/_templates/. Currently consumed
  -- only by the `library` type (which ships archive-entry.md,
  -- convention.md, and convention-manifest.yaml). Same
  -- absent-or-forced semantics as the other seed copies.
  local templates_seed_dir = types.seeds_dir() .. "/" .. type .. "-templates"
  if vim.fn.isdirectory(templates_seed_dir) == 1 then
    local templates_root = root .. "/_templates"
    vim.fn.mkdir(templates_root, "p")
    local sd = vim.uv.fs_scandir(templates_seed_dir)
    if sd then
      while true do
        local name, ftype = vim.uv.fs_scandir_next(sd)
        if not name then break end
        if ftype == "file" then
          local src = templates_seed_dir .. "/" .. name
          local dst = templates_root .. "/" .. name
          if opts.force_schema or vim.fn.filereadable(dst) == 0 then
            copy_file(src, dst)
          end
        end
      end
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
      atomic_write(path, string.format(pointer_body, p.name, p.name, p.name))
    end
  end

  -- log.md and index.md as append-only stubs. log.md is created with
  -- the rotation-pointer header per KB_RULES.md §R1 so fresh KBs start
  -- in the rotated shape from day one (no migration needed when log
  -- grows past the first ISO week).
  local log = root .. "/log.md"
  if vim.fn.filereadable(log) == 0 then
    atomic_write(log, table.concat({
      "# auto-agents knowledge-base log",
      "",
      "> **Current ISO week only.** Closed weeks live in `log/YYYY-W<NN>.md`;",
      "> weeks older than 3 months live in `archive/log/YYYY-W<NN>.md`.",
      "> See [`KB_RULES.md`](./KB_RULES.md) §R1 for the rotation procedure.",
      "",
    }, "\n"))
  end
  local index = root .. "/index.md"
  if vim.fn.filereadable(index) == 0 then
    atomic_write(index, table.concat({
      "# index",
      "",
      "Catalog of pages in this knowledge base. Agents update this on every",
      "new `shared/` page — one entry per page with a one-line summary.",
      "",
    }, "\n"))
  end

  return root
end

---Append a one-line entry to log.md (timestamp + message).
---Append stays `io.open("a")` — an atomic read-modify-rewrite would
---race concurrent appenders. ADR-0039 Batch C adds the flush so the
---entry reaches the OS before close (durability without atomicity is
---the right trade for an append-only audit log).
---@param msg string
function M.log(msg)
  local root = M.root()
  M.ensure_layout(root)
  local f = io.open(root .. "/log.md", "a")
  if not f then return end
  f:write(string.format("- %s — %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
  f:flush()
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
