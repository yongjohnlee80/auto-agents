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
---@field shared_subdirs string[]       -- subdirs under shared/
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
    description = "Coding project — conventions, ADRs, review playbooks (default for nvim users)",
    raw_subdirs = { "specs", "issues", "transcripts" },
    shared_subdirs = {
      "conventions",
      "adrs",
      "playbooks",
      "glossary",
      "synthesis",
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
---@param type string|nil
---@return AutoAgentsKbLayout
function M.layout(type)
  local key = type or "general"
  local layout = LAYOUTS[key] or LAYOUTS.general
  return {
    description = layout.description,
    raw_subdirs = layout.raw_subdirs,
    shared_subdirs = layout.shared_subdirs,
    dirs = vim.list_extend(
      vim.list_extend({ "raw", "shared", "agents" },
        vim.tbl_map(function(d) return "raw/" .. d end, layout.raw_subdirs)),
      vim.tbl_map(function(d) return "shared/" .. d end, layout.shared_subdirs)
    ),
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
