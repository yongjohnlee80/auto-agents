---One-shot migration helper: ingest KB-synthesis docs tagged
---`type:todo-list` into the active workspace's `.todo-list/`,
---then archive the originals.
---
---KB-layout-agnostic (v0.3.0): it reads both layouts and archives each
---doc within its own layout, so it works before and after the KB v2
---migration (ADR 1791209946 §8):
---
---    KB v1  <kb>/shared/synthesis/*.md  →  <kb>/shared/synthesis/archive/
---    KB v2  <kb>/synthesis/*.md         →  <kb>/archive/synthesis/
---
---It never overwrites: an existing archive target is reported as an
---error and the original stays where it is. The todo store, its
---format and the `todos.*` verbs are untouched by KB v2; this helper
---stays because the managed block's todo protocol names it.
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
---originals to their layout's archive folder (above).
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

-- The synthesis folders a todo-list doc can sit in, per KB layout, and
-- where each layout archives it (relative to the KB root).
local LAYOUTS = {
  { synthesis = "synthesis",        archive = "archive/synthesis" },          -- KB v2
  { synthesis = "shared/synthesis", archive = "shared/synthesis/archive" },   -- KB v1
}

---Scan a KB root's synthesis folders — `synthesis/` (KB v2) and
---`shared/synthesis/` (KB v1), top level only — for files whose
---`**Tags:**` line declares `type:todo-list`. Returns absolute paths.
---@param kb_root string
---@return string[] candidate_paths
function M.scan(kb_root)
  local candidates = {}
  for _, layout in ipairs(LAYOUTS) do
    local synthesis_dir = kb_root .. "/" .. layout.synthesis
    if vim.fn.isdirectory(synthesis_dir) == 1 then
      for _, f in ipairs(vim.fn.glob(synthesis_dir .. "/*.md", false, true)) do
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
    end
  end
  table.sort(candidates)
  return candidates
end

---The archive folder for a candidate: its own layout's (see LAYOUTS).
---@param kb_root string
---@param src string  absolute path returned by `M.scan`
---@return string|nil
function M.archive_dir_for(kb_root, src)
  local parent = vim.fn.fnamemodify(src, ":h")
  for _, layout in ipairs(LAYOUTS) do
    if parent == kb_root .. "/" .. layout.synthesis then
      return kb_root .. "/" .. layout.archive
    end
  end
  return nil
end

---The KB root: `auto-agents.kb.root()` (a shim over auto-core.kb), else
---auto-core.kb directly, else `$AUTO_AGENTS_KB_ROOT`.
---@return string?
local function resolve_kb_root()
  for _, mod in ipairs({ "auto-agents.kb", "auto-core.kb" }) do
    local ok, kb = pcall(require, mod)
    if ok and type(kb) == "table" and type(kb.root) == "function" then
      local ok_r, r = pcall(kb.root)
      if ok_r and type(r) == "string" and r ~= "" then return r end
    end
  end
  local v = vim.env.AUTO_AGENTS_KB_ROOT
  if v and v ~= "" then return v end
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
      .. "the project has no primary KB (auto-core.kb); pass opts.kb_root")
  end

  kb_root = (kb_root:gsub("/+$", ""))

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
    for _, src in ipairs(summary.candidates) do
      local archive_dir = M.archive_dir_for(kb_root, src)
      local target = archive_dir and (archive_dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
      if not target then
        summary.errors[#summary.errors + 1] = { src = src, phase = "archive",
          err = "not under a known synthesis folder" }
      elseif vim.uv.fs_stat(target) then
        summary.errors[#summary.errors + 1] = { src = src, phase = "archive",
          err = "archive target exists, not overwritten: " .. target }
      else
        vim.fn.mkdir(archive_dir, "p")
        local ok_mv, err = vim.uv.fs_rename(src, target)
        if ok_mv then
          summary.archived[#summary.archived + 1] = target
        else
          summary.errors[#summary.errors + 1] = { src = src, phase = "archive", err = tostring(err) }
        end
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