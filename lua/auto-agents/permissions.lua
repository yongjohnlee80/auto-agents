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

---True when a codex `cmd` override already decides the sandbox policy.
---
---Every spelling clap accepts has to be recognised, because a miss is not a
---missed optimisation — appending a second `-s` makes codex exit 2 ("the
---argument --sandbox <SANDBOX_MODE> cannot be used multiple times"), so the
---slot would not start at all. Verified against codex-cli 0.155.1:
---
---    -s read-only                  ok      -s read-only -s workspace-write   exit 2
---    -sread-only                   ok      --sandbox=read-only --sandbox …   exit 2
---    --sandbox=read-only           ok
---    -c sandbox_mode=read-only     ok      -csandbox_mode=…  --config=…      ok
---
---`-p/--profile` counts too: a profile layers `$CODEX_HOME/<name>.config.toml`
---over the user config and may set `sandbox_mode` there, and a CLI `-s` would
---override that choice. We cannot resolve the profile's effective policy from
---here without reimplementing codex's config layering, so a profile is read as
---"the user chose" and the grant goes in bare — see M.argv_for_kind's note.
---
---`sandbox_permissions=…` is deliberately NOT in here: it is a permissions
---list, not a mode selector, so suppressing on it left the spawn on the
---default read-only policy and the grant inert — the very bug this strategy
---exists to fix. It also coexists with an explicit `-s` (exit 0), so pairing
---the two is safe.
---@param cmd string[]|nil
---@return boolean
local function codex_cmd_sets_sandbox(cmd)
  if type(cmd) ~= "table" then return false end
  for _, a in ipairs(cmd) do
    if type(a) == "string" then
      if a == "--dangerously-bypass-approvals-and-sandbox" then return true end
      -- `-s <mode>` / `-s<mode>` / `--sandbox <mode>` / `--sandbox=<mode>`,
      -- and the same four shapes for `-p`/`--profile`.
      if a == "-s" or a == "--sandbox" or a == "-p" or a == "--profile" then return true end
      if a:match("^%-s.") or a:match("^%-%-sandbox=") then return true end
      if a:match("^%-p.") or a:match("^%-%-profile=") then return true end
      -- A `sandbox_mode` config override, whether it rides on the flag
      -- (`-csandbox_mode=…`, `-c=sandbox_mode=…`, `--config=sandbox_mode=…`)
      -- or is the next argv entry after a bare `-c` / `--config`.
      local cfg = a:match("^%-c=?(.*)$") or a:match("^%-%-config=(.*)$") or a
      if cfg:match("^sandbox_mode%s*=") then return true end
    end
  end
  return false
end

---`--add-dir` is inert on codex under its default read-only sandbox, so the
---grant carries `-s workspace-write` with it. No dirs to grant → no policy
---flag either: we are here to remove prompt friction for paths we grant, not
---to widen a spawn that was granted nothing.
---
---A cmd that already decides the policy gets the grants bare. For `-s` /
---`--sandbox` / the bypass flag that is exactly right. For `-p/--profile` it
---is the safe reading rather than the complete one: if that profile does not
---select `workspace-write` (or wider), codex will discard the `--add-dir`
---entries as it did before this strategy existed. Overriding a profile from
---here would be worse — we would silently widen a policy the user wrote down
---— so the spawn log records the grant and the user pairs the profile with a
---sandbox mode if they want the paths writable.
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