---Project lifecycle commands (M6).
---
---Backs the `:AutoAgentsProject` user command and the admin `project ...`
---verb. All operations are scoped to the session-cached project key —
---`:cd` does not move the project boundary mid-session.
---
---  init    — create a new per-project TOML for the cached cwd
---  import  — duplicate another project's [[agents]] (KB shared)
---  remove  — delete the per-project TOML (KB survives)
---  list    — list all known TOMLs in the config dir
---  show    — print active resolution (project|global|none) + paths
---
---@module 'auto-agents.project'

local store = require("auto-agents.config.store")

local M = {}

---Reload setup() against the current TOML so the in-memory config picks
---up changes after init/import/remove. Avoids a full nvim restart.
local function reload_config()
  local aa = require("auto-agents")
  if not aa.state.session_project_key then return end
  local loaded, source = store.load(aa.state.session_project_key)
  aa.state.config_source = source
  aa.state.config = aa.state.config or {}
  aa.state.config.agents = aa.state.config.agents or {}
  aa.state.config.agents.bootstrap = (loaded and loaded.agents) or {}
  if loaded and loaded.kb and loaded.kb.root then
    aa.state.config.kb = aa.state.config.kb or {}
    aa.state.config.kb.root_override = loaded.kb.root
  else
    if aa.state.config.kb then aa.state.config.kb.root_override = nil end
  end
  pcall(aa.refresh_keymaps)
end

---@param emit fun(lines: string[])  -- admin emitter (or print fallback)
---@return boolean ok
function M.init(emit)
  emit = emit or function(lines) for _, l in ipairs(lines) do print(l) end end
  local aa = require("auto-agents")
  local key = aa.state.session_project_key
  local cwd = aa.state.session_project_root or aa.state.session_cwd
  if not key then
    emit({ "project init: session not initialized" })
    return false
  end
  local ok, err, path = store.init_project(key, cwd, nil)
  if not ok then
    emit({ "project init failed: " .. (err or "unknown") })
    return false
  end
  reload_config()
  emit({
    "Initialized project config:",
    "  " .. path,
    "",
    "No agents yet. Run 'agent add' (wizard) to create one.",
    "Open the panel with :AutoAgents — slot 0 admin will engage the wizard.",
  })
  return true
end

---Resolve a user-supplied selector (path, sha-prefix, or session_cwd) to a
---known TOML file path. Returns nil + listing when ambiguous/missing.
---@param selector string|nil
---@return string|nil resolved_path
---@return string|nil err
local function resolve_source(selector)
  if not selector or selector == "" then
    return nil, "no selector supplied"
  end
  -- Special-case "global" so users can import from the global TOML
  -- by name without typing the full path.
  if selector == "global" then
    return store.global_path(), nil
  end
  -- Absolute or relative path?
  local expanded = vim.fn.expand(selector)
  if vim.fn.filereadable(expanded) == 1 then
    return expanded, nil
  end
  -- sha-prefix or full key match?
  local known = store.list_known()
  local matches = {}
  for _, e in ipairs(known) do
    if not e.is_global and (e.key == selector or e.key:sub(1, #selector) == selector
        or (e.cwd and (e.cwd == expanded or e.cwd:find(selector, 1, true)))) then
      table.insert(matches, e)
    end
  end
  if #matches == 0 then
    return nil, "no project matches '" .. selector .. "'"
  end
  if #matches > 1 then
    local names = {}
    for _, m in ipairs(matches) do table.insert(names, m.key) end
    return nil, "ambiguous selector — matched: " .. table.concat(names, ", ")
  end
  return matches[1].path, nil
end

---@param emit fun(lines: string[])
---@param selector string|nil
function M.import(emit, selector)
  emit = emit or function(lines) for _, l in ipairs(lines) do print(l) end end
  local aa = require("auto-agents")
  local key = aa.state.session_project_key
  local cwd = aa.state.session_project_root or aa.state.session_cwd
  if not key then
    emit({ "project import: session not initialized" }); return false
  end

  if not selector or selector == "" then
    -- No arg: list candidates and ask user to re-run with one.
    local known = store.list_known()
    local lines = { "project import: pick a source and re-run as 'project import <key|path|cwd>'", "" }
    local any = false
    for _, e in ipairs(known) do
      if not e.is_global and e.key ~= key then
        any = true
        table.insert(lines, string.format("  %s   %s", e.key, e.cwd or "(unknown cwd)"))
      end
    end
    if not any then
      table.insert(lines, "  (no other projects found)")
    end
    table.insert(lines, "")
    emit(lines)
    return false
  end

  local source, err = resolve_source(selector)
  if not source then
    emit({ "project import failed: " .. (err or "unknown") }); return false
  end
  local ok, ierr, path = store.import_from(key, cwd, source)
  if not ok then
    emit({ "project import failed: " .. (ierr or "unknown") })
    return false
  end
  reload_config()
  emit({
    "Imported agents from " .. source,
    "  → " .. path,
    "  KB shared with the source project (no copy made).",
  })
  return true
end

---@param emit fun(lines: string[])
function M.remove(emit)
  emit = emit or function(lines) for _, l in ipairs(lines) do print(l) end end
  local aa = require("auto-agents")
  local key = aa.state.session_project_key
  if not key then
    emit({ "project remove: session not initialized" }); return false
  end
  local removed, path = store.remove_project(key)
  if not removed then
    emit({ "project remove: nothing to remove (" .. path .. " did not exist)" })
    return false
  end
  reload_config()
  emit({
    "Removed " .. path,
    "  Falling back to " .. (aa.state.config_source == "global" and "global config" or "no config"),
    "  KB on disk untouched — remove manually if desired.",
  })
  return true
end

---@param emit fun(lines: string[])
function M.list(emit)
  emit = emit or function(lines) for _, l in ipairs(lines) do print(l) end end
  local aa = require("auto-agents")
  local active_key = aa.state.session_project_key
  local known = store.list_known()
  local lines = { "Known config files:" }
  if #known == 0 then
    table.insert(lines, "  (none in " .. store.config_dir() .. ")")
  else
    for _, e in ipairs(known) do
      local marker = (e.key == active_key) and " ← active" or ""
      local label = e.is_global and "global" or e.key
      table.insert(lines, string.format("  %-18s  %s%s", label, e.cwd or "(no cwd recorded)", marker))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "Active session: " .. tostring(aa.state.session_project_root))
  emit(lines)
  return true
end

---@param emit fun(lines: string[])
function M.show(emit)
  emit = emit or function(lines) for _, l in ipairs(lines) do print(l) end end
  local aa = require("auto-agents")
  local key = aa.state.session_project_key or "?"
  local active_path, target = store.active_path(key)
  emit({
    "Project resolution:",
    "  source         = " .. tostring(aa.state.config_source),
    "  session_cwd    = " .. tostring(aa.state.session_cwd),
    "  session_project= " .. tostring(aa.state.session_project_root),
    "  project_key    = " .. key,
    "  active path    = " .. active_path .. "  (" .. target .. ")",
    "  project_file   = " .. store.project_path(key),
    "  global_file    = " .. store.global_path(),
  })
  return true
end

---Top-level dispatch from `:AutoAgentsProject <sub> [args]` / admin verb.
---@param sub string|nil
---@param args string[]
---@param emit fun(lines: string[])|nil
function M.dispatch(sub, args, emit)
  emit = emit or function(lines) for _, l in ipairs(lines) do print(l) end end
  args = args or {}
  if not sub or sub == "" or sub == "help" then
    emit({
      "project commands:",
      "  init                     create a new per-project TOML for the cached cwd",
      "  import [<key|path|cwd>]  duplicate agents from another project (shares KB)",
      "  remove                   delete the per-project TOML (KB survives)",
      "  list                     list known config files",
      "  show                     print active resolution",
    })
    return
  end
  if sub == "init"   then return M.init(emit) end
  if sub == "import" then return M.import(emit, args[1]) end
  if sub == "remove" then return M.remove(emit) end
  if sub == "list"   then return M.list(emit) end
  if sub == "show"   then return M.show(emit) end
  emit({ "project: unknown subcommand '" .. sub .. "' — try init|import|remove|list|show" })
end

return M
