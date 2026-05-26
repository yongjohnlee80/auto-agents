---
revision: 1
title: auto-agents todos command surface — bootstrap guide
---

# auto-agents todos command surface

This document is the canonical agent-facing reference for the
`todos.*` mailbox command verbs registered by
**auto-agents v0.2.37+**. The verbs expose `auto-core.todo`
(the per-project task store from ADR-0031) to peer agents
without granting raw filesystem write access to the workspace's
`.todo-list/` directory.

The verbs share the `todos.` namespace prefix so they appear
together in `commands_list` output, distinct from the existing
`wake` / `say` / `addressbook` / `diff_queue` etc. surface.

---

## TL;DR

| Verb              | Effect                                                                |
|-------------------|-----------------------------------------------------------------------|
| `todos.list`      | List tasks in the active workspace (optional `status` filter)          |
| `todos.show`      | Fetch one task by id                                                   |
| `todos.list_dirs` | Show every `.todo-list/` directory the host has touched                |
| `todos.get_dir`   | Return the absolute path of the active `.todo-list/`                   |
| `todos.add`       | Create a new open task                                                 |
| `todos.update`    | Patch a task's hand-editable fields                                    |
| `todos.status`    | Transition open / completed / deferred / archived (fires event)        |
| `todos.assign`    | Set assignee + **notify recipient via mailbox**                        |
| `todos.archive`   | Convenience alias for `status=archived`                                |
| `todos.remove`    | Hard-delete a task file (irreversible)                                 |
| `todos.refresh`   | Reconcile the dir (move misplaced files, run validation, auto-archive) |
| `todos.set_dir`   | Point this workspace at a different `.todo-list/`                      |
| `todos.import`    | Bulk import from KB / legacy / Asana sources                           |

---

## Calling convention

All verbs are mailbox `kind="command"` messages. Example invocation:

```jsonc
{
  "kind": "command",
  "command": "todos.add",
  "args": {
    "title": "Fix the kb-token-cost audit feedback",
    "priority": "high",
    "due": "2026-06-15",
    "tags": ["audit", "kb"]
  }
}
```

Responses follow the standard `{ ok, value | error, code }` envelope:

```jsonc
// ok
{ "ok": true, "value": { "id": "2026-05-26-fix-the-kb-token-cost-audit-feedback" } }

// error
{ "ok": false, "code": "invalid_args", "error": "args.id must be a non-empty string" }
```

---

## When to use a verb vs. edit the file directly

The `.todo-list/` directory lives inside the agent's working
scope (cwd-based access), so an agent CAN open and edit task
files directly. **Whether you should depends on whether the
mutation needs side effects.**

| Mutation                              | Path                | Side effects                              |
|---------------------------------------|---------------------|-------------------------------------------|
| Read anything                         | direct file read    | none — preferred                          |
| Edit `title` / `description` / `tags` | direct YAML edit    | none — preferred                          |
| Edit `priority` / `due` / `assignee:` | direct YAML edit    | **no event fires** — silent              |
| Transition `status:`                  | `todos.status`      | fires `core.todo.status:changed`         |
| Notify someone of an assignment       | `todos.assign`      | mailbox message to recipient's inbox     |
| Add / remove a task                   | `todos.add` / `.remove` | events + auditable log line          |
| Reconcile a stale dir                 | `todos.refresh`     | re-evaluates buckets, errors[], archive  |

**Rule of thumb**: if you want the panel UI to refresh or
another agent to wake about your change, use a verb. If you're
just hand-editing metadata for your own bookkeeping, edit the
file. Both paths produce schema-valid files; only verbs fan out
events.

---

## Per-verb reference

### `todos.list`

Filter to one bucket via `args.status` ∈ `{open, deferred,
completed, archived}`. Without a filter, returns every task
visible in the active workspace.

```jsonc
{ "kind": "command", "command": "todos.list", "args": { "status": "open" } }
→ { "ok": true, "value": { "count": 5, "tasks": [...] } }
```

### `todos.show`

```jsonc
{ "kind": "command", "command": "todos.show", "args": { "id": "2026-05-26-foo" } }
→ { "ok": true, "value": { /* full schema-v1 frontmatter */ } }
```

### `todos.list_dirs` / `todos.get_dir`

Discovery surface — useful when an agent isn't sure which
`.todo-list/` is currently active. `get_dir` returns the
absolute path; `list_dirs` returns every directory the host has
touched (so you can spot "this task list is shared across N
workspace roots" cases).

### `todos.add`

`title` is required; everything else is optional and limited to
the hand-editable surface (`description`, `priority`, `due`,
`assignee`, `tags`, `adr`, `review`, `blocked`). Managed fields
(id, lifecycle timestamps, errors) are owned by the host.

```jsonc
{
  "kind": "command", "command": "todos.add",
  "args": {
    "title": "Verify v0.1.43 assign event payload shape",
    "priority": "normal",
    "tags": ["test", "ad-hoc"],
    "adr": ["$KB_ROOT/shared/adrs/0031-auto-core-per-project-todo-task-system.md"]
  }
}
→ { "ok": true, "value": { "id": "2026-05-26-verify-v0143-assign-event-payload-shape" } }
```

### `todos.update`

Patch any hand-editable field. The patch table is shallow-
merged; pass a key with `nil` to unset (where allowed).

```jsonc
{
  "kind": "command", "command": "todos.update",
  "args": {
    "id":    "2026-05-26-foo",
    "patch": { "due": "2026-06-30", "priority": "high" }
  }
}
```

### `todos.status` / `todos.archive`

Status transitions fire `core.todo.status:changed` so the
auto-finder panel + other subscribers can react. `archive` is a
convenience for `status=archived` with proper `archived_at`
timestamping (and `completed_at` preservation when coming from
completed).

### `todos.assign`

Sets `assignee:` AND fires `core.todo.assignee:changed`. The
auto-agents host subscribes to that event and delivers a
**one-shot mailbox message** to the recipient agent's inbox:

```
Subject: [todos] task assigned to you: <title>

You have been assigned a task.

  id        : 2026-05-26-foo
  title     : Verify v0.1.43 assign event payload shape
  file_path : /Users/.../.todo-list/open/2026-05-26-foo.md
  from      : <previous assignee or absent>

Reason: <optional one-liner from args.reason>
```

The recipient mailbox is the same form you'd use anywhere in
the auto-agents protocol (e.g. `agent:lector` or the full
`agent:lector:<instance>` form — both resolve via the router).

Pass `args.assignee = null` to **clear** the assignee. Clearing
does NOT emit a message (no one to notify).

### `todos.remove`

Irreversible — no undo, no archive bucket. Use this for
genuinely-wrong tasks (typo'd duplicates, accidental imports);
prefer `todos.archive` for completed work you want to keep on
record.

### `todos.refresh`

Run after bulk file mutations (e.g. you direct-edited several
files) so the host re-evaluates bucket placement, runs
reference validation, and applies the 28-day auto-archive rule.
Returns a summary table: `{scanned, moved, archived, skipped,
errors_set, rewritten}`.

### `todos.set_dir`

Re-point the active workspace at a different `.todo-list/`.
Useful when migrating to a shared parent dir (e.g.
`~/Source/<repo-family>/.todo-list/` across multiple plugin
worktrees). Pass `args.path = null` or empty string to clear
the override and resume `<workspace_root>/.todo-list/`.

### `todos.import`

Bulk ingestion. `args.kind` ∈ `{kb-todo-list, legacy-todos-md,
asana-json}`. See ADR-0031 §3.4 for the format expectations.
Pass `dry_run = true` to preview classification without
writing.

---

## Reading the directory directly

Agents have read access to the active workspace, including
`.todo-list/`. The on-disk layout is:

```
.todo-list/
├── open/<id>.md
├── deferred/<id>.md
├── completed/<id>.md
└── archived/YYYY/MM/<id>.md
```

Each file is markdown with YAML frontmatter; schema v1 is
documented in ADR-0031 §2. You can `grep` or directly read
files for context; **avoid writing to these files directly
unless you're confident the change doesn't need side effects**
(see the table above).

---

## Reading the panel listing

When the user has the auto-finder todos panel open, OPEN tasks
are rendered with a 1-based ephemeral index (`1.`, `2.`, `3.`).
**Treat that index as ephemeral — refer to a task by its `id`
for anything persistent.** The index reorders on every refresh
(errors-to-top, then chronological); ids never change.

---

## See also

- ADR-0031 — the canonical design document for the per-project
  todo system.
- `auto-core.todo` — the underlying Lua API. Every `todos.*`
  verb is a thin wrapper around it.
- `commands_list` — call with `args.owner = "auto-agents"` to
  see this surface alongside the rest of the auto-agents
  command verbs.