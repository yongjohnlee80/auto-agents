---KB type registry — maps a KB type to its layout (subdirectories)
---and seed schema file.
---
---When a KB is created (`kb init <type>` or wizard), the plugin:
---  1. Creates the type-specific subdirectory layout under <kb_root>.
---  2. Creates `<kb_root>/raw/` (immutable; with a README explaining).
---  3. Copies the seed `.md` to `<kb_root>/AGENTS.md` as the canonical
---     schema doc.
---  4. Drops `CLAUDE.md` and `GEMINI.md` pointers next to it for
---     compatibility with kind-specific auto-loading.
---  5. Creates empty `log.md` and `index.md` if missing.
---
---The seed types are defined under the plugin's `kb-seeds/` directory
---and shipped with the plugin. Users can also pass `type = "custom"`
---and supply their own seed file path via `[kb].seed` in TOML.
---@module 'auto-agents.kb.types'

local M = {}

---@class AutoAgentsKbLayout
---@field dirs string[]                 -- subdirs to mkdir under kb_root
---@field raw_subdirs string[]          -- subdirs under raw/ (also mkdir'd)
---@field shared_subdirs string[]|nil   -- subdirs under shared/ (legacy; non-coding types only)
---@field wiki_subdirs string[]|nil     -- subdirs under wiki/ (coding type)
---@field project_subdirs string[]|nil  -- subdirs under projects/ (coding type)
---@field extra_dirs string[]|nil       -- additional top-level dirs (e.g. adr, _templates)
---@field description string            -- one-line type purpose

---Built-in types. Order matters — used as the default presentation
---order in the wizard picker.
M.BUILTIN = { "coding", "wiki", "research", "ops", "general" }

---Resolve the seeds directory shipped with the plugin.
---@return string
function M.seeds_dir()
  local source = debug.getinfo(1, "S").source:sub(2)  -- this file's path
  -- .../lua/auto-agents/kb/types.lua → .../kb-seeds/
  local plugin_root = source:gsub("/lua/auto%-agents/kb/types%.lua$", "")
  return plugin_root .. "/kb-seeds"
end

---Path to a built-in type's seed `.md` file.
---@param type string
---@return string|nil path  nil if `type` is not a built-in
function M.seed_path(type)
  for _, t in ipairs(M.BUILTIN) do
    if t == type then
      return M.seeds_dir() .. "/" .. type .. ".md"
    end
  end
  return nil
end

---Layouts per type. Every type has an immutable `raw/` and a
---`shared/` for durable agent-shared work, plus an `agents/` for
---per-agent scratch (created lazily by `kb.scope`). Differences are
---in the per-type subdirectories.
local LAYOUTS = {
  coding = {
    description = "Coding project — wiki/ + projects/ + ADRs + code-reviews (default for nvim users)",
    raw_subdirs = { "specs", "issues", "transcripts" },
    -- No shared/. Durable knowledge lives in wiki/; operational state in projects/.
    wiki_subdirs = {
      "sources",
      "entities",
      "concepts",
      "topics",
      "operations",
      "synthesis",
      "code-review",
    },
    project_subdirs = {
      "coding-rules",
    },
    extra_dirs = {
      "adr",
      "_templates",
      "archive",
      "docs/agent-schema",
    },
  },
  wiki = {
    description = "LLM-wiki — Zettelkasten-flavored, durable interlinked knowledge",
    raw_subdirs = {},  -- raw/ is freeform under wiki style
    shared_subdirs = {
      "sources",
      "entities",
      "concepts",
      "topics",
      "synthesis",
    },
  },
  research = {
    description = "Research notebook — papers, hypotheses, experiments, synthesis",
    raw_subdirs = { "papers", "datasets", "transcripts", "correspondence" },
    shared_subdirs = {
      "papers",
      "lit-review",
      "hypotheses",
      "experiments",
      "methods",
      "synthesis",
    },
  },
  ops = {
    description = "Operations / runbook — alerts, runbooks, incidents, postmortems",
    raw_subdirs = { "alerts", "chatops", "tickets", "dashboards" },
    shared_subdirs = {
      "services",
      "runbooks",
      "alerts",
      "incidents",
      "postmortems",
      "playbooks",
    },
  },
  general = {
    description = "General / living — minimal seed, structure emerges from work",
    raw_subdirs = {},
    shared_subdirs = {},
  },
}

---Layout for a given type. Falls back to "general" if unknown.
---
---Coding type uses the new wiki/ + projects/ layout. Other types
---retain the legacy shared/ tree for backward compat.
---@param type string|nil
---@return AutoAgentsKbLayout
function M.layout(type)
  local key = type or "general"
  local layout = LAYOUTS[key] or LAYOUTS.general

  local dirs = { "raw", "agents" }
  for _, d in ipairs(layout.raw_subdirs or {}) do
    table.insert(dirs, "raw/" .. d)
  end
  if layout.shared_subdirs then
    table.insert(dirs, "shared")
    for _, d in ipairs(layout.shared_subdirs) do
      table.insert(dirs, "shared/" .. d)
    end
  end
  if layout.wiki_subdirs then
    table.insert(dirs, "wiki")
    for _, d in ipairs(layout.wiki_subdirs) do
      table.insert(dirs, "wiki/" .. d)
    end
  end
  if layout.project_subdirs then
    table.insert(dirs, "projects")
    for _, d in ipairs(layout.project_subdirs) do
      table.insert(dirs, "projects/" .. d)
    end
  end
  for _, d in ipairs(layout.extra_dirs or {}) do
    table.insert(dirs, d)
  end

  return {
    description = layout.description,
    raw_subdirs = layout.raw_subdirs,
    shared_subdirs = layout.shared_subdirs,
    wiki_subdirs = layout.wiki_subdirs,
    project_subdirs = layout.project_subdirs,
    extra_dirs = layout.extra_dirs,
    dirs = dirs,
  }
end

---List built-in types with descriptions, suitable for wizard display.
---@return { name: string, description: string }[]
function M.list()
  local out = {}
  for _, name in ipairs(M.BUILTIN) do
    table.insert(out, {
      name = name,
      description = LAYOUTS[name].description,
    })
  end
  return out
end

return M
