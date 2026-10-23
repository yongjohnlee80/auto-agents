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
---Supported kinds (v0.2.32):
---
---  * `claude`      — `--add-dir <path>` (repeatable). Adds the
---    path to Claude Code's allowed-directories list for the
---    session.
---  * `codex`       — `--add-dir <path>` (repeatable) AND
---    `-s workspace-write`. The flag name matches Claude's, but on
---    its own it is silently discarded: codex honours extra
---    writable roots only under the `workspace-write` or
---    `danger-full-access` sandbox policy, and it defaults to
---    `read-only` for any project without a `trust_level` in
---    `~/.codex/config.toml`. Then the spawn prints
---
---        Error adding directories: Ignoring --add-dir (…) because
---        the effective permissions do not allow additional writable
---        roots. Switch to workspace-write or danger-full-access …
---
---    and the agent runs with no mailbox write access at all. So the
---    grant ships with the policy that enables it, unless the user's
---    `cmd` override already picks a sandbox (`-s` / `--sandbox` /
---    `--dangerously-bypass-approvals-and-sandbox` / `-c
---    sandbox_mode=…`), which wins — we never downgrade or duplicate
---    an explicit choice. (Note: `sandbox_workspace_write
---    .writable_roots` in `~/.codex/config.toml` is the TOML
---    config field — NOT a CLI flag. The CLI flag is `--add-dir`,
---    same as Claude's.)
---  * `antigravity` — `--add-dir <path>` (repeatable). Confirmed
---    in `agy --help` end-of-cycle 2026-05-24; antigravity uses
---    the same flag name as claude/codex.
---
---Kinds without a strategy (`junie`, `goose`, `opencode`,
---`copilot`, `generic`) get an empty result — the agent runs
---unchanged. Add a strategy entry once the equivalent of
---`--add-dir` is confirmed for those CLIs.
---
---@module 'auto-agents.permissions'

local M = {}

---@alias AutoAgentsPermissionStrategy fun(dirs: string[], cmd: string[]|nil): string[]

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

---Sandbox selectors a codex `cmd` override may already carry. Any of them
---means the user chose a policy, so we add none.
local CODEX_SANDBOX_FLAGS = {
  ["-s"] = true,
  ["--sandbox"] = true,
  ["--dangerously-bypass-approvals-and-sandbox"] = true,
}

---@param cmd string[]|nil
---@return boolean
local function codex_cmd_sets_sandbox(cmd)
  if type(cmd) ~= "table" then return false end
  for _, a in ipairs(cmd) do
    if type(a) == "string" then
      if CODEX_SANDBOX_FLAGS[a] then return true end
      -- `-c sandbox_mode=…` / `--config sandbox_mode=…`: the value is its own
      -- argv entry, so matching the entry is enough — no need to pair it with
      -- the flag before it.
      if a:match("^sandbox_mode=") or a:match("^sandbox_permissions=") then return true end
    end
  end
  return false
end

---`--add-dir` is inert on codex under its default read-only sandbox, so the
---grant carries `-s workspace-write` with it. No dirs to grant → no policy
---flag either: we are here to remove prompt friction for paths we grant, not
---to widen a spawn that was granted nothing.
---@type AutoAgentsPermissionStrategy
local function codex_strategy(dirs, cmd)
  local out = repeatable_flag("--add-dir")(dirs)
  if #out == 0 or codex_cmd_sets_sandbox(cmd) then return out end
  table.insert(out, 1, "-s")
  table.insert(out, 2, "workspace-write")
  return out
end

---@type table<string, AutoAgentsPermissionStrategy>
local STRATEGY = {
  claude      = repeatable_flag("--add-dir"),
  codex       = codex_strategy,
  antigravity = repeatable_flag("--add-dir"),
}

---Return the additional argv args to append to the spawn command
---for the given agent kind, pre-granting access to the listed
---directories.
---
---For unknown kinds returns `{}` (the agent runs unchanged).
---Empty or non-string entries in `dirs` are skipped.
---@param kind string|nil
---@param dirs string[]|nil
---@param cmd string[]|nil  -- the spawn argv so far: a strategy may need to
---                            see what the user already chose (codex's
---                            sandbox policy). Optional; omitting it only
---                            costs the deduplication.
---@return string[]
function M.argv_for_kind(kind, dirs, cmd)
  local strategy = STRATEGY[kind]
  if not strategy then return {} end
  return strategy(dirs or {}, cmd)
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