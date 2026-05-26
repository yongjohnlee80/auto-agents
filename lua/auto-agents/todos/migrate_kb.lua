---One-shot migration helper: ingest KB-synthesis docs tagged
---`type:todo-list` into the active workspace's `.todo-list/`,
---then archive the originals to `shared/synthesis/archive/`.
---
---This is the Phase-4 step of ADR-0031 §6 — automated for any
---team member who needs to migrate their KB todos into the new
---per-project todo store.
---
---Invocation:
---
---    :AutoAgentsMigrateKbTodos          -- dry-run by default
---    :AutoAgentsMigrateKbTodos! --apply -- live, with archive
---
---The dry-run prints the candidate list + per-doc classification
---without writing anything. The `--apply` form runs
---`auto-core.todo.import` per doc and atomically moves the
---originals to `<kb-root>/shared/synthesis/archive/`.
---
---Both forms honor the active workspace_root (set via
---`auto-core.git.worktree.set_workspace_root` or via
---`auto-core.todo.set_todo_dir`) so the imported tasks land in
---whichever `.todo-list/` the user is currently pointed at.
---
---Soft dependency on auto-core.nvim (>= v0.1.42). Refuses to run
---without it loaded.
---
---@module 'auto-agents.todos.migrate_kb'

local M = {}

---Detect whether a given line is the doc's `**Tags:**` declaration
---AND contains the `type:todo-list` atom. The KB convention
---wraps each atom in backticks and puts them on a single line
---prefixed with literal `**Tags:**`. Scoping the match to that
---line avoids sweeping in unrelated docs that mention the tag
---scheme in prose or code blocks.
---@param line string
---@return boolean
local function is_todo_list_tag_line(line)
  return line:match("^%*%*Tags:%*%*") ~= nil
    and line:find("`type:todo-list`", 1, true) ~= nil
end

---Scan a KB root's `shared/synthesis/*.md` directory for files
---whose top-level `**Tags:**` line declares `type:todo-list`.
---Returns a list of absolute paths.
---@param kb_root string
---@return string[] candidate_paths
function M.scan(kb_root)
  local synthesis_dir = kb_root .. "/shared/synthesis"
  if vim.fn.isdirectory(synthesis_dir) == 0 then return {} end
  local files = vim.fn.glob(synthesis_dir .. "/*.md", false, true)
  local candidates = {}
  for _, f in ipairs(files) do
    local fh = io.open(f, "r")
    if fh then
      local content = fh:read("*a") or ""
      fh:close()
      for line in content:gmatch("[^\n]+") do
        if is_todo_list_tag_line(line) then
          candidates[#candidates + 1] = f
          break
        end
      end
    end
  end
  table.sort(candidates)
  return candidates
end

---Resolve the KB root via the auto-agents.kb.root() API. Falls
---back to env vars if auto-agents isn't loaded for any reason.
---@return string?
local function resolve_kb_root()
  local ok, kb = pcall(require, "auto-agents.kb")
  if ok and type(kb.root) == "function" then
    local ok_r, r = pcall(kb.root)
    if ok_r and type(r) == "string" and r ~= "" then return r end
  end
  -- Env-var fallback chain (matches auto-core.todo.vars' built-in)
  for _, var in ipairs({ "AUTO_AGENTS_KB_ROOT", "AUTO_AGENTS_KB_READ", "AUTO_AGENTS_KB_WRITE" }) do
    local v = vim.env[var]
    if v and v ~= "" then
      if var == "AUTO_AGENTS_KB_READ" then v = v:match("^([^:]+)") end
      return v
    end
  end
  return nil
end

---Run the migration. Defaults to dry-run; pass `apply = true` to
---actually import + archive. Returns a summary table:
---
---    { dry_run, kb_root, todo_dir, candidates = [], imported = [], archived = [], errors = [] }
---
---Each `imported[]` entry: `{ src = <abs>, id, status }`.
---Each `errors[]` entry: `{ src = <abs>, phase = "import"|"archive", err }`.
---
---@param opts table?  { apply?: boolean, kb_root?: string, ws_root?: string }
---@return table summary
function M.migrate(opts)
  opts = opts or {}
  local apply = opts.apply == true

  local ok_core = pcall(require, "auto-core.todo")
  if not ok_core then
    error("auto-agents.todos.migrate_kb: requires auto-core.nvim (>= v0.1.42) loaded")
  end
  local todo = require("auto-core.todo")

  -- Optional workspace pin so the caller can route imported tasks
  -- to a specific `.todo-list/` without touching their global
  -- worktree state.
  if opts.ws_root and opts.ws_root ~= "" then
    require("auto-core.git.worktree").set_workspace_root(opts.ws_root)
  end

  local kb_root = opts.kb_root or resolve_kb_root()
  if not kb_root then
    error("auto-agents.todos.migrate_kb: could not resolve KB root — "
      .. "set AUTO_AGENTS_KB_ROOT or configure auto-agents.nvim")
  end

  local summary = {
    dry_run    = not apply,
    kb_root    = kb_root,
    todo_dir   = todo.get_todo_dir(),
    candidates = M.scan(kb_root),
    imported   = {},
    archived   = {},
    errors     = {},
  }

  for _, src in ipairs(summary.candidates) do
    if apply then
      local ok, result = pcall(todo.import, src, { kind = "kb-todo-list" })
      if not ok then
        summary.errors[#summary.errors + 1] = { src = src, phase = "import", err = tostring(result) }
      else
        for _, spec in ipairs(result) do
          summary.imported[#summary.imported + 1] = { src = src, id = spec.id, status = spec.status }
        end
      end
    else
      local ok, result = pcall(todo.import, src, { kind = "kb-todo-list", dry_run = true })
      if not ok then
        summary.errors[#summary.errors + 1] = { src = src, phase = "import", err = tostring(result) }
      else
        for _, spec in ipairs(result) do
          summary.imported[#summary.imported + 1] = { src = src, id = spec.id, status = spec.status }
        end
      end
    end
  end

  if apply then
    local archive_dir = kb_root .. "/shared/synthesis/archive"
    vim.fn.mkdir(archive_dir, "p")
    for _, src in ipairs(summary.candidates) do
      local base = vim.fn.fnamemodify(src, ":t")
      local target = archive_dir .. "/" .. base
      local ok_mv, err = vim.uv.fs_rename(src, target)
      if ok_mv then
        summary.archived[#summary.archived + 1] = target
      else
        summary.errors[#summary.errors + 1] = { src = src, phase = "archive", err = tostring(err) }
      end
    end
  end

  return summary
end

---Pretty-print a migration summary to a buffer/stdout. Used by
---the `:AutoAgentsMigrateKbTodos` user command.
---@param summary table
---@return string[]  lines (also written via print() so headless
---                  runs see them)
function M.format_summary(summary)
  local lines = {}
  local function add(s) lines[#lines + 1] = s; print(s) end

  add("── KB todos migration ──────────────────────────")
  add(string.format("  mode       : %s", summary.dry_run and "DRY-RUN" or "APPLY"))
  add(string.format("  kb_root    : %s", tostring(summary.kb_root)))
  add(string.format("  todo_dir   : %s", tostring(summary.todo_dir)))
  add(string.format("  candidates : %d", #summary.candidates))
  add(string.format("  imported   : %d", #summary.imported))
  add(string.format("  archived   : %d", #summary.archived))
  add(string.format("  errors     : %d", #summary.errors))
  add("")

  if #summary.imported > 0 then
    add("imported tasks:")
    for _, e in ipairs(summary.imported) do
      add(string.format("  %s  [%s]  ← %s",
        tostring(e.id), tostring(e.status), vim.fn.fnamemodify(e.src, ":t")))
    end
    add("")
  end

  if #summary.errors > 0 then
    add("errors:")
    for _, e in ipairs(summary.errors) do
      add(string.format("  [%s] %s: %s",
        e.phase, vim.fn.fnamemodify(e.src, ":t"), e.err))
    end
    add("")
  end

  if summary.dry_run then
    add("(dry-run — no files were written or moved. Pass --apply to commit.)")
  end

  return lines
end

return M