---KB sync — regenerates manifest.json across every namespace under
---kb_root (M4 chunk B + C). Two-pass:
---  1. Build vault-wide basename → kb-relative-path index for
---     wikilink resolution.
---  2. Per-namespace, call manifest.write(dir, index). Each entry
---     gets resolved/broken wikilinks annotated.
---@module 'auto-agents.kb.sync'

local M = {}

---Build a basename → kb-relative path index across every *.md file
---under kb_root. If two files share a basename (rare in well-curated
---vaults), both are recorded; the resolver picks the first match.
---@param kb_root string
---@return table<string, string[]>
local function build_index(kb_root)
  local index = {}
  local files = vim.fn.glob(kb_root .. "/**/*.md", false, true)
  for _, abs in ipairs(files) do
    -- Skip manifest files (they're .json but glob shouldn't pick them; defensive).
    local rel = abs:sub(#kb_root + 2)  -- strip prefix + '/'
    local base = abs:match("([^/]+)$")
    if base then
      index[base] = index[base] or {}
      table.insert(index[base], rel)
    end
  end
  return index
end

---@class AutoAgentsKbSyncSummary
---@field namespaces { name: string, count: integer, broken: integer, error: string|nil }[]
---@field kb_root string
---@field total_broken integer

---Walk shared/ and each agents/<name>/ under kb_root, write a manifest
---per namespace. Returns a summary table for display.
---@param kb_root string|nil
---@return AutoAgentsKbSyncSummary
function M.sync_all(kb_root)
  kb_root = kb_root or require("auto-agents.kb").root()
  local manifest = require("auto-agents.kb.manifest")
  local index = build_index(kb_root)

  ---@type AutoAgentsKbSyncSummary
  local summary = { kb_root = kb_root, namespaces = {}, total_broken = 0 }

  local function record(name, dir)
    if vim.fn.isdirectory(dir) ~= 1 then return end
    local err, broken = manifest.write(dir, index)
    local entries
    if err then
      entries = {}
    else
      entries = manifest.generate(dir, index).entries
    end
    summary.total_broken = summary.total_broken + (broken or 0)
    table.insert(summary.namespaces, {
      name = name,
      count = #entries,
      broken = broken or 0,
      error = err,
    })
  end

  record("shared", kb_root .. "/shared")

  local agents_dir = kb_root .. "/agents"
  if vim.fn.isdirectory(agents_dir) == 1 then
    local subdirs = vim.fn.readdir(agents_dir)
    table.sort(subdirs)
    for _, sub in ipairs(subdirs) do
      local d = agents_dir .. "/" .. sub
      if vim.fn.isdirectory(d) == 1 then
        record("agents/" .. sub, d)
      end
    end
  end

  return summary
end

return M
