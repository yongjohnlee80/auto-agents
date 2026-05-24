---auto-agents.runtime.identity — single source of truth for agent
---identity reconciliation: mailbox root resolution, mailbox
---registration, and sidecar identity record write. ADR 0029 Decision #3.
---
---Three call paths share the same facts (slot, agent name, kind,
---mailbox root, mailbox record, sidecar path, diff_review):
---
---  1. spawn               — `auto-agents.init.build_agent_env`
---  2. refresh_agent_id    — `auto-agents.mailbox.commands`
---  3. adopt-resumed-agent — `plugin/auto-agents.lua :AutoAgentsAdoptResumedAgent`
---
---Pre-extraction, these three call paths each rebuilt the identity
---independently; the adopt path lost `diff_review` and used the
---host-fallback mailbox root instead of the per-kind root (lector
---audit, 2026-05-24). This module collapses them into one
---`reconcile` entry point so the bug class is no longer possible.
---
---### Mailbox-location policy (v0.2.30)
---
---All agent mailboxes live under the **workspace** rather than
---per-CLI config dirs (`~/.claude/mailbox`, `~/.codex/mailbox`, etc).
---The new layout, owned by `auto-core.mailbox.path` v0.1.33+:
---
---  <workspace_root>/.auto-agents/mailbox/<instance>/<agent_name>/...
---
---Rationale: visibility (the user sees mailbox files next to their
---code), prunability (one tree per workspace; nuke when done),
---accessibility (agents whose cwd is at or under the workspace root
---get native filesystem access without per-kind sandbox grants).
---
---`mailbox_root()` resolves the workspace mailbox root via
---`auto-core.mailbox.path.workspace_mailbox_root`, which walks up
---via `auto-core.fs.path.workspace_root` (bare-repo-aware) and
---appends `.auto-agents/mailbox`. The single
---`AUTO_AGENTS_MAILBOX_ROOT` env var override remains for tests.
---
---Sidecar I/O primitives (build_record / path_for / read / write)
---live one layer down in `auto-agents.runtime_identity`. This
---module composes them.
---
---@module 'auto-agents.runtime.identity'

local M = {}

---Resolve the workspace mailbox root. Delegates to auto-core's
---`mailbox.path.workspace_mailbox_root` so the layout knowledge
---stays in exactly one place. `opts.cwd` defaults to
---`vim.fn.getcwd()`; pass an explicit cwd when reconciling for an
---agent whose effective workspace differs from the host's.
---@param opts { cwd: string? }?
---@return string
function M.mailbox_root(opts)
  local mb_path = require("auto-core.mailbox.path")
  return mb_path.workspace_mailbox_root(opts)
end

---Reconcile a slot's identity. Registers the agent's mailbox under
---the workspace mailbox root (idempotent re-registration is safe
---per ADR 0013 §1), builds and atomic-writes the sidecar identity
---record, and returns the resolved facts so callers can wire env
---vars / wake messages / responses without re-deriving them.
---
---On any step failure returns `{ ok = false, error, detail }`; the
---caller decides UX (notify / response / log). This module never
---surfaces to the user directly.
---
---@param opts { slot: integer, agent_name: string, kind: string?, diff_review: boolean?, agent_pid: integer?, stamped_by: string, wake: table?, cwd: string? }
---@return { ok: boolean, mailbox_root: string?, mailbox_record: table?, sidecar_path: string?, sidecar_record: table?, error: string?, detail: string? }
function M.reconcile(opts)
  opts = opts or {}
  if type(opts.slot) ~= "number" then
    return { ok = false, error = "missing_slot",
             detail = "opts.slot (integer) required" }
  end
  if type(opts.agent_name) ~= "string" or opts.agent_name == "" then
    return { ok = false, error = "missing_agent_name",
             detail = "opts.agent_name (non-empty string) required" }
  end
  if type(opts.stamped_by) ~= "string" or opts.stamped_by == "" then
    return { ok = false, error = "missing_stamped_by",
             detail = "opts.stamped_by (non-empty string) required" }
  end

  local core_ok, core = pcall(require, "auto-core")
  if not core_ok then
    return { ok = false, error = "auto_core_unavailable",
             detail = "require('auto-core') failed" }
  end

  local ri_ok, ri = pcall(require, "auto-agents.runtime_identity")
  if not ri_ok then
    return { ok = false, error = "runtime_identity_unavailable",
             detail = "require('auto-agents.runtime_identity') failed" }
  end

  local mailbox_root = M.mailbox_root({ cwd = opts.cwd })

  local register_opts = { root = mailbox_root }
  if type(opts.wake) == "table" then register_opts.wake = opts.wake end

  local reg_ok, mailbox_record = pcall(
    core.mailbox.register, "agent:" .. opts.agent_name, register_opts)
  if not reg_ok or type(mailbox_record) ~= "table" then
    return { ok = false, error = "mailbox_register_failed",
             detail = "auto-core mailbox.register failed: "
                      .. tostring(mailbox_record),
             mailbox_root = mailbox_root }
  end

  local sidecar_record = ri.build_record(
    opts.slot, opts.agent_name, mailbox_record.root, mailbox_record.dir,
    opts.stamped_by, opts.agent_pid, opts.diff_review)

  local sidecar_path = ri.path_for(opts.slot)
  local wok, werr = ri.write(sidecar_path, sidecar_record)
  if not wok then
    return { ok = false, error = "sidecar_write_failed",
             detail = "atomic-write at " .. sidecar_path
                      .. " failed: " .. tostring(werr),
             mailbox_root = mailbox_root,
             mailbox_record = mailbox_record,
             sidecar_path = sidecar_path }
  end

  return {
    ok = true,
    mailbox_root = mailbox_root,
    mailbox_record = mailbox_record,
    sidecar_path = sidecar_path,
    sidecar_record = sidecar_record,
  }
end

return M