---Explicit migration helper for cleaning up stale command overrides in agent TOML configuration
---files: an agent kind change (e.g. from copilot or junie to claude) may leave behind stale commands.
---
---This migration scans TOML configuration files, previews proposed changes in dry-run mode,
---and applies them when requested.
---
---Invocation:
---
---    :AutoAgentsMigrateCmd          -- dry-run by default
---    :AutoAgentsMigrateCmd! --apply -- live, rewrites TOML
---
---@module 'auto-agents.config.migrate_cmd'

local M = {}

local store = require("auto-agents.config.store")
local agent = require("auto-agents.agent")
local toml = require("auto-agents.vendor.toml")

---Compute the migrated cmd for an agent entry:
---1. If mismatched cross-kind, clears to nil.
---2. If resulting cmd equals bare adapter default, clears to nil.
---@param kind string|nil
---@param cmd string[]|nil
---@param agent_name string|nil
---@return string[]|nil migrated_cmd
---@return boolean changed
function M.migrate_agent_cmd(kind, cmd, agent_name)
  if type(cmd) ~= "table" or #cmd == 0 then
    return nil, false
  end

  local sanitized = agent.sanitize_cmd(kind, cmd, agent_name)

  local changed = not vim.deep_equal(cmd, sanitized)
  return sanitized, changed
end

---Find all candidate TOML files to inspect.
---@param config_dir string|nil
---@return string[]
function M.find_config_files(config_dir)
  local dir = config_dir or store.config_dir()
  local set = {}
  local files = {}

  if vim.fn.isdirectory(dir) == 1 then
    local matches = vim.fn.glob(dir .. "/*.toml", false, true)
    for _, f in ipairs(matches) do
      if not set[f] then
        set[f] = true
        files[#files + 1] = f
      end
    end
  end

  local global_p = store.global_path()
  local stat = vim.uv and vim.uv.fs_stat(global_p) or vim.loop.fs_stat(global_p)
  if stat and stat.type == "file" and not set[global_p] then
    set[global_p] = true
    files[#files + 1] = global_p
  end

  table.sort(files)
  return files
end

---Run the migration. Defaults to dry-run; pass `apply = true` to write changes.
---@param opts table|nil  { apply?: boolean, config_path?: string, config_dir?: string }
---@return table summary
function M.migrate(opts)
  opts = opts or {}
  local apply = opts.apply == true

  local files = {}
  if opts.config_path and opts.config_path ~= "" then
    files = { opts.config_path }
  else
    files = M.find_config_files(opts.config_dir)
  end

  local summary = {
    dry_run = not apply,
    files = files,
    changes = {},
    errors = {},
  }

  for _, path in ipairs(files) do
    local f = io.open(path, "r")
    if not f then
      summary.errors[#summary.errors + 1] = { file = path, err = "failed to open file for reading" }
    else
      local content = f:read("*a")
      f:close()
      local ok_parse, data = pcall(toml.decode, content)
      if not ok_parse or type(data) ~= "table" then
        summary.errors[#summary.errors + 1] = { file = path, err = "failed to parse TOML: " .. tostring(data) }
      else
        local agents = data.agents or {}
        local file_has_changes = false

        for _, a in ipairs(agents) do
          if a.cmd ~= nil then
            local migrated, changed = M.migrate_agent_cmd(a.kind, a.cmd, a.name)
            if changed then
              file_has_changes = true
              summary.changes[#summary.changes + 1] = {
                file = path,
                slot = a.slot,
                name = a.name,
                kind = a.kind,
                before = a.cmd,
                after = migrated,
              }
              if apply then
                a.cmd = migrated
              end
            end
          end
        end

        if apply and file_has_changes then
          local ok_w, err_w = store.write(path, data)
          if not ok_w then
            summary.errors[#summary.errors + 1] = { file = path, err = "failed to write TOML: " .. tostring(err_w) }
          end
        end
      end
    end
  end

  -- If apply mode, also update in-memory bootstrap entries ONLY if the migrated file
  -- is the active project configuration file for the current session.
  if apply then
    local aa_ok, aa = pcall(require, "auto-agents")
    if aa_ok and aa.state and aa.state.config and aa.state.config.agents and aa.state.config.agents.bootstrap then
      local active_path = (aa.state.session_project_key and store.active_path(aa.state.session_project_key))
        or store.global_path()
      for _, change in ipairs(summary.changes) do
        if change.file == active_path then
          for _, live in ipairs(aa.state.config.agents.bootstrap) do
            if change.slot and live.slot == change.slot
              and (not change.name or live.name == change.name)
            then
              live.cmd = change.after
            end
          end
        end
      end
    end
  end

  return summary
end

---Pretty-print a migration summary.
---@param summary table
---@param emit function|nil  Optional callback to receive each line. Defaults to `print`.
---@return string[] lines
function M.format_summary(summary, emit)
  local lines = {}
  local function add(s)
    lines[#lines + 1] = s
    if emit then
      emit(s)
    else
      print(s)
    end
  end

  add("── AutoAgents cmd migration ──────────────────────────")
  add(string.format("  mode           : %s", summary.dry_run and "DRY-RUN" or "APPLY"))
  add(string.format("  files scanned  : %d", #summary.files))
  add(string.format("  agents changed : %d", #summary.changes))
  add(string.format("  errors         : %d", #summary.errors))
  add("")

  if #summary.changes > 0 then
    add("changes:")
    local current_file = nil
    for _, c in ipairs(summary.changes) do
      if c.file ~= current_file then
        current_file = c.file
        add("  " .. c.file .. ":")
      end
      local before_str = type(c.before) == "table" and ("[" .. table.concat(c.before, ", ") .. "]") or tostring(c.before)
      local after_str = type(c.after) == "table" and ("[" .. table.concat(c.after, ", ") .. "]")
        or (c.after == nil and "(cleared → adapter default)" or tostring(c.after))
      add(string.format("    slot %s (%s, kind=%s):", tostring(c.slot or "?"), tostring(c.name or "?"), tostring(c.kind or "?")))
      add(string.format("      before: %s", before_str))
      add(string.format("      after : %s", after_str))
    end
    add("")
  end

  if #summary.errors > 0 then
    add("errors:")
    for _, e in ipairs(summary.errors) do
      add(string.format("  [%s]: %s", tostring(e.file), tostring(e.err)))
    end
    add("")
  end

  if summary.dry_run then
    add("(dry-run — no files were written. Pass --apply or ! to commit.)")
  end

  return lines
end

return M
