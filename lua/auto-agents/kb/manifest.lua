---Per-namespace manifest generation (M4 chunk B + C). Walks a namespace
---directory (shared/ or agents/<name>/), enumerates `*.md` files, and
---writes `manifest.json` with sha + mtime + size + wikilinks per
---entry. The manifest is the agent-readable summary of "what's
---available here"; `kb sync` regenerates it after writes.
---
---Wikilink format: `[[Page Name]]` or `[[path/to/page]]` or
---`[[Page|alias]]`. Matches Obsidian's syntax. Resolution is done by
---the caller (sync.lua) using a vault-wide basename index.
---@module 'auto-agents.kb.manifest'

local M = {}

---@param path string
---@return string|nil sha, string|nil content
local function read_and_hash(path)
  local f = io.open(path, "rb")
  if not f then return nil, nil end
  local content = f:read("*a") or ""
  f:close()
  return vim.fn.sha256(content), content
end

---@param path string
---@return integer size, integer mtime
local function stat_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return 0, 0 end
  return stat.size or 0, (stat.mtime and stat.mtime.sec) or 0
end

---Extract every `[[wikilink]]` from markdown content. Strips an
---optional `|alias` suffix and trims whitespace. Order-preserving;
---duplicates kept (so the manifest reflects actual occurrences).
---@param content string
---@return string[]
local function extract_wikilinks(content)
  local links = {}
  for raw in content:gmatch("%[%[([^%[%]]+)%]%]") do
    -- strip alias: "Page|alias" → "Page"
    local target = raw:match("^([^|]+)") or raw
    target = target:gsub("^%s+", ""):gsub("%s+$", "")
    if target ~= "" then table.insert(links, target) end
  end
  return links
end

---Build the manifest table for a namespace directory. Wikilink
---resolution is *not* done here — `resolve_index` (a basename → paths
---map) is optional; if supplied, each wikilink is annotated with a
---`resolved` field pointing at the matching kb-relative path (or nil).
M._generate_count = 0  -- test hook (ADR-0039 D/P2: one generate per namespace per sync)

---@param namespace_dir string  -- absolute
---@param resolve_index table|nil  -- { [basename]: kb_relative_path[] }
---@return table
function M.generate(namespace_dir, resolve_index)
  M._generate_count = M._generate_count + 1
  local entries = {}
  local broken_count = 0
  local files = vim.fn.glob(namespace_dir .. "/**/*.md", false, true)
  table.sort(files)
  for _, f in ipairs(files) do
    if f ~= namespace_dir .. "/manifest.json" then
      local rel = f:sub(#namespace_dir + 2)
      local sha, content = read_and_hash(f)
      local size, mtime = stat_file(f)
      local raw_links = content and extract_wikilinks(content) or {}
      local link_records = {}
      for _, raw in ipairs(raw_links) do
        local resolved
        if resolve_index then
          -- Try the link as a path first, then as a basename.
          local basename = raw:match("([^/]+)$") or raw
          if basename:sub(-3) ~= ".md" then basename = basename .. ".md" end
          local hits = resolve_index[basename]
          if hits and #hits > 0 then resolved = hits[1] end
        end
        if not resolved then broken_count = broken_count + 1 end
        table.insert(link_records, { raw = raw, resolved = resolved })
      end
      table.insert(entries, {
        path = rel,
        sha256 = sha,
        mtime = mtime,
        size = size,
        wikilinks = link_records,
      })
    end
  end
  return {
    namespace_dir = namespace_dir,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    entries = entries,
    broken_link_count = broken_count,
  }
end

---Write `<namespace_dir>/manifest.json`. Returns nil on success, an
---error string on failure. ADR-0039 Batch D (P2): the generated
---manifest is returned as the third value so callers (kb/sync.lua)
---can reuse it instead of paying a second full `generate()` — each
---generate is a recursive glob + read+hash of every page in the
---namespace, so the double call doubled sync cost for nothing.
---@param namespace_dir string
---@param resolve_index table|nil
---@return string|nil err
---@return integer|nil broken_count
---@return table|nil manifest  -- the generated manifest (nil on error)
function M.write(namespace_dir, resolve_index)
  vim.fn.mkdir(namespace_dir, "p")
  local manifest = M.generate(namespace_dir, resolve_index)
  local ok, encoded = pcall(vim.json.encode, manifest)
  if not ok then
    -- ADR-0039 C5: errors were previously returned-but-unlogged; the
    -- caller chain (sync → admin) only displayed counts, leaving a
    -- stale manifest invisible. Log at the failure site.
    local err = "json encode failed: " .. tostring(encoded)
    require("auto-agents.log").warn("kb.manifest",
      namespace_dir .. ": " .. err)
    return err, nil
  end
  -- ADR-0039 Batch C: atomic write (auto-core >= 0.1.58) — readers
  -- (agents resolving wikilinks) must never see a half-written JSON.
  local wok, werr = require("auto-core.fs.atomic").write(
    namespace_dir .. "/manifest.json", encoded)
  if not wok then
    local err = "write failed: " .. tostring(werr)
    require("auto-agents.log").warn("kb.manifest",
      namespace_dir .. ": " .. err)
    return err, nil
  end
  return nil, manifest.broken_link_count, manifest
end

return M
