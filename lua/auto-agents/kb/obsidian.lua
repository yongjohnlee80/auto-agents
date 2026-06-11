---Obsidian scaffold (D16, M4 chunk C). `kb obsidian-init` writes a
---minimal `.obsidian/` to the KB root so opening the directory in
---Obsidian "just works" — vault recognized, graph view pre-configured
---with shared vs per-agent color buckets.
---
---We deliberately write only the bare minimum (app.json + graph.json).
---Obsidian creates workspace.json, plugin state, and other files on
---first open. Idempotent: existing files are not overwritten so the
---user's customizations survive a re-init.
---@module 'auto-agents.kb.obsidian'

local M = {}

-- Graph defaults: separate color groups for shared/ vs agents/* so the
-- user can visually distinguish team-wide synthesis from per-agent
-- experimentation.
local DEFAULT_GRAPH = {
  collapse_filter = false,
  search = "",
  showTags = true,
  showAttachments = false,
  hideUnresolved = false,
  showOrphans = true,
  collapse_color_groups = false,
  colorGroups = {
    { query = "path:shared/", color = { a = 1, rgb = 0x4488ff } },  -- blue
    { query = "path:agents/", color = { a = 1, rgb = 0xff8844 } },  -- orange
  },
  collapse_display = false,
  showArrow = true,
  textFadeMultiplier = 0,
  nodeSizeMultiplier = 1,
  lineSizeMultiplier = 1,
  collapse_forces = false,
  centerStrength = 0.5,
  repelStrength = 10,
  linkStrength = 1,
  linkDistance = 250,
  scale = 1,
  close = true,
}

local function write_if_missing(path, data)
  if vim.fn.filereadable(path) == 1 then return false end
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return false end
  -- ADR-0039 Batch C: atomic write via the canonical primitive.
  local wok = require("auto-core.fs.atomic").write(path, encoded, { mkdir = true })
  return wok == true
end

---@param kb_root string
---@return table summary  { dir, written_files: string[], skipped_files: string[] }
function M.init(kb_root)
  local dir = kb_root .. "/.obsidian"
  vim.fn.mkdir(dir, "p")

  local files = {
    { path = dir .. "/app.json",   data = {} },
    { path = dir .. "/graph.json", data = DEFAULT_GRAPH },
  }

  local written, skipped = {}, {}
  for _, e in ipairs(files) do
    if write_if_missing(e.path, e.data) then
      table.insert(written, e.path)
    else
      table.insert(skipped, e.path)
    end
  end

  return { dir = dir, written_files = written, skipped_files = skipped }
end

return M
