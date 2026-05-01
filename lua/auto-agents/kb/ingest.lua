---Ingest tracking + edit detection (M6).
---
---Compares files in `raw/` (the immutable evidence layer) against
---`shared/sources/*.md` source pages (one summary per ingested file)
---using a `source_sha` recorded in each source page's frontmatter.
---
---No persisted index — frontmatter IS the persisted state. The agent
---adds `source_sha` + `ingested_at` when it writes a source page;
---`kb ingest` re-derives the diff on demand.
---
---Buckets:
---  new      — file in raw/, no source page references it
---  edited   — source page exists, sha mismatch (re-ingest needed)
---  current  — source page exists, sha matches (skip)
---  orphan   — source page references a raw path that no longer exists
---
---Source-page convention (added to seed AGENTS.md files):
---
---    ---
---    type: source
---    sources: [raw/path/to/foo.md]
---    source_sha: <sha256 of raw/path/to/foo.md at ingest>
---    ingested_at: 2026-05-01
---    ---
---
---Pages that aggregate multiple sources (entities, topics, syntheses)
---list `sources:` for citation but DON'T track sha — only the
---one-to-one source pages do.
---@module 'auto-agents.kb.ingest'

local M = {}

local fm = require("auto-agents.kb.frontmatter")

---@class AutoAgentsIngestRawEntry
---@field path string       -- kb-relative path (e.g. "raw/foo.md")
---@field abs string        -- absolute path
---@field sha string        -- sha256 of file content
---@field size integer
---@field mtime integer

---@class AutoAgentsIngestSourcePageEntry
---@field source_path string  -- raw path the page documents
---@field source_sha string|nil
---@field ingested_at string|nil
---@field source_page string  -- shared/sources/<slug>.md

---@class AutoAgentsIngestDiff
---@field new      AutoAgentsIngestRawEntry[]
---@field edited   { raw: AutoAgentsIngestRawEntry, source_page: string, recorded_sha: string|nil }[]
---@field current  AutoAgentsIngestRawEntry[]
---@field orphan   AutoAgentsIngestSourcePageEntry[]

---@param path string
---@return string|nil sha
local function file_sha(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  return vim.fn.sha256(content)
end

---@param path string
---@return integer size, integer mtime
local function stat_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return 0, 0 end
  return stat.size or 0, (stat.mtime and stat.mtime.sec) or 0
end

---True if a kb-relative path under raw/ should be skipped during scan
---(scaffolded files, dotfiles, archived sources).
---@param rel string
---@return boolean
local function should_skip(rel)
  if rel == "raw/README.md" then return true end
  if rel:match("/%.[^/]+$") or rel:match("^raw/%.[^/]+") then return true end
  if rel:match("^raw/archive/") then return true end
  return false
end

---Walk every regular file under <kb_root>/raw/ (recursively) and
---return content-hashed entries. Skips raw/README.md, dotfiles, and
---raw/archive/ subtree.
---@param kb_root string
---@return AutoAgentsIngestRawEntry[]
function M.scan_raw(kb_root)
  local raw_dir = kb_root .. "/raw"
  if vim.fn.isdirectory(raw_dir) ~= 1 then return {} end
  local files = vim.fn.glob(raw_dir .. "/**/*", false, true)
  table.sort(files)

  local out = {}
  for _, abs in ipairs(files) do
    if vim.fn.isdirectory(abs) ~= 1 then
      local rel = abs:sub(#kb_root + 2)
      if not should_skip(rel) then
        local sha = file_sha(abs)
        if sha then
          local size, mtime = stat_file(abs)
          table.insert(out, {
            path = rel, abs = abs, sha = sha, size = size, mtime = mtime,
          })
        end
      end
    end
  end
  return out
end

---Read every shared/sources/*.md page and extract the
---{source_path → page_record} mapping based on frontmatter. Pages
---without `source_sha` are still recorded (so we can flag them for
---first ingest tracking).
---@param kb_root string
---@return AutoAgentsIngestSourcePageEntry[]
function M.scan_ingested(kb_root)
  local sources_dir = kb_root .. "/shared/sources"
  if vim.fn.isdirectory(sources_dir) ~= 1 then return {} end

  local files = vim.fn.glob(sources_dir .. "/**/*.md", false, true)
  table.sort(files)

  local out = {}
  for _, abs in ipairs(files) do
    local rel = abs:sub(#kb_root + 2)
    local meta = fm.parse_file(abs)
    local sources = meta.sources or {}
    if type(sources) == "string" then sources = { sources } end
    for _, src in ipairs(sources) do
      if type(src) == "string" and src ~= "" then
        table.insert(out, {
          source_path = src,
          source_sha = (type(meta.source_sha) == "string") and meta.source_sha or nil,
          ingested_at = (type(meta.ingested_at) == "string") and meta.ingested_at or nil,
          source_page = rel,
        })
      end
    end
  end
  return out
end

---Compute the diff for a KB. Returns four buckets.
---@param kb_root string|nil  -- defaults to kb.root()
---@return AutoAgentsIngestDiff
function M.diff(kb_root)
  kb_root = kb_root or require("auto-agents.kb").root()

  local raw_entries = M.scan_raw(kb_root)
  local ingested = M.scan_ingested(kb_root)

  -- Index ingested by source_path. If multiple source pages claim the
  -- same raw file (rare but possible), keep the first; the rest are
  -- still listed as duplicates by the orphan-or-not logic below.
  local ingested_by_path = {}
  for _, e in ipairs(ingested) do
    if not ingested_by_path[e.source_path] then
      ingested_by_path[e.source_path] = e
    end
  end

  local raw_by_path = {}
  for _, e in ipairs(raw_entries) do raw_by_path[e.path] = e end

  local diff = { new = {}, edited = {}, current = {}, orphan = {} }

  -- Walk raw → bucket each file as new, edited, or current.
  for _, raw in ipairs(raw_entries) do
    local rec = ingested_by_path[raw.path]
    if not rec then
      table.insert(diff.new, raw)
    elseif rec.source_sha and rec.source_sha == raw.sha then
      table.insert(diff.current, raw)
    else
      table.insert(diff.edited, {
        raw = raw,
        source_page = rec.source_page,
        recorded_sha = rec.source_sha,
      })
    end
  end

  -- Walk ingested → any source page that points at a missing raw file.
  for _, e in ipairs(ingested) do
    if not raw_by_path[e.source_path] then
      table.insert(diff.orphan, e)
    end
  end

  return diff
end

local function short_sha(s)
  if type(s) ~= "string" or s == "" then return "<none>" end
  if #s <= 12 then return s end
  return s:sub(1, 12)
end

---Format the diff as a list of lines suitable for emit().
---@param diff AutoAgentsIngestDiff
---@return string[]
function M.format_report(diff)
  local lines = { "" }
  local total = #diff.new + #diff.edited + #diff.current + #diff.orphan
  table.insert(lines, string.format(
    "kb ingest: %d raw file(s) tracked  (%d new, %d edited, %d current, %d orphan)",
    total, #diff.new, #diff.edited, #diff.current, #diff.orphan))
  table.insert(lines, "")

  if #diff.new > 0 then
    table.insert(lines, "NEW — never ingested:")
    for _, e in ipairs(diff.new) do
      table.insert(lines, string.format("  + %s  (%s)", e.path, short_sha(e.sha)))
    end
    table.insert(lines, "")
  end

  if #diff.edited > 0 then
    table.insert(lines, "EDITED — sha mismatch, re-ingest:")
    for _, e in ipairs(diff.edited) do
      table.insert(lines, string.format("  ~ %s", e.raw.path))
      table.insert(lines, string.format("      page=%s", e.source_page))
      table.insert(lines, string.format("      recorded=%s  current=%s",
        short_sha(e.recorded_sha), short_sha(e.raw.sha)))
    end
    table.insert(lines, "")
  end

  if #diff.orphan > 0 then
    table.insert(lines, "ORPHAN — source page references a missing raw file:")
    for _, e in ipairs(diff.orphan) do
      table.insert(lines, string.format("  ! %s  (page=%s)", e.source_path, e.source_page))
    end
    table.insert(lines, "")
  end

  if #diff.current > 0 and #diff.new == 0 and #diff.edited == 0 and #diff.orphan == 0 then
    table.insert(lines, "All raw sources up to date.")
    table.insert(lines, "")
  elseif #diff.current > 0 then
    table.insert(lines, string.format("(%d already-current source%s elided.)",
      #diff.current, #diff.current == 1 and "" or "s"))
    table.insert(lines, "")
  end

  if total == 0 then
    table.insert(lines, "(raw/ is empty and no source pages exist yet)")
    table.insert(lines, "")
  end

  return lines
end

return M
