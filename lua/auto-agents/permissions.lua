---auto-agents.permissions — per-kind spawn-time permission injection.
---
---Each agent CLI has its own model for "I trust this path; don't
---prompt me on every read/write". Rather than mutating the user's
---real settings files (`~/.claude/settings.json`,
---`~/.codex/config.toml`, etc.) — which races across multiple
---nvim instances, can leak state on crash, and pollutes user
---config — we just append the right CLI flag(s) at spawn time.
---
---Per-instance paths (mailbox dir, KB dirs) regenerate every nvim
---restart, so persistence isn't desirable: the next spawn rebuilds
---the argv from scratch.
---
---Supported kinds (v0.3.0):
---
---  * `claude` — `--add-dir <path>` (repeatable). Adds the path
---    to Claude Code's allowed-directories list for the session.
---  * `codex`  — `--sandbox-workspace-write-root <path>`
---    (repeatable). Adds the path to codex's writable-roots list
---    for the session.
---
---Kinds without a strategy (`gemini`, `junie`, `aider`, `goose`,
---`opencode`, `copilot`, `generic`) get an empty result — the
---agent runs unchanged. Add strategies here as flags are
---confirmed; track in
---`docs/todo-lists/mailbox-wake-and-permissions.md`.
---
---@module 'auto-agents.permissions'

local M = {}

---@alias AutoAgentsPermissionStrategy fun(dirs: string[]): string[]

---@param flag string  the repeatable CLI flag (e.g. "--add-dir")
---@return AutoAgentsPermissionStrategy
local function repeatable_flag(flag)
  return function(dirs)
    local out = {}
    for _, d in ipairs(dirs) do
      if type(d) == "string" and d ~= "" then
        out[#out + 1] = flag
        out[#out + 1] = d
      end
    end
    return out
  end
end

---@type table<string, AutoAgentsPermissionStrategy>
local STRATEGY = {
  claude = repeatable_flag("--add-dir"),
  codex  = repeatable_flag("--sandbox-workspace-write-root"),
}

---Return the additional argv args to append to the spawn command
---for the given agent kind, pre-granting access to the listed
---directories.
---
---For unknown kinds returns `{}` (the agent runs unchanged).
---Empty or non-string entries in `dirs` are skipped.
---@param kind string|nil
---@param dirs string[]|nil
---@return string[]
function M.argv_for_kind(kind, dirs)
  local strategy = STRATEGY[kind]
  if not strategy then return {} end
  return strategy(dirs or {})
end

---Returns true when the kind has a registered permission
---strategy. Useful for logging / health checks.
---@param kind string|nil
---@return boolean
function M.supported(kind)
  return STRATEGY[kind] ~= nil
end

---List of kinds that currently have a permission strategy.
---@return string[]
function M.supported_kinds()
  local out = {}
  for k in pairs(STRATEGY) do out[#out + 1] = k end
  table.sort(out)
  return out
end

return M