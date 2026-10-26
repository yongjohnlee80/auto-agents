---
revision: 6
title: auto-agents todos command surface — bootstrap guide
---

# auto-agents todos command surface

This document is the canonical agent-facing reference for the
`todos.*` mailbox command verbs registered by
**auto-agents v0.2.37+**. The verbs expose the per-project task
store (ADR-0031) to peer agents without granting raw filesystem
write access to the workspace's `.todo-list/` directory.

**AutoDoc owns the store** (ADR 1791532020): its daemon holds the
task format, the rules and every write. From **auto-agents v0.3.6**
each verb calls the daemon's `todos.*` verbs itself and answers once
the daemon has. Without AutoDoc every verb answers
`code = "dependency_unavailable"` ("AutoDoc required"); there is no
fallback. The same verbs are on the daemon directly:
`autodoc --call todos.<verb>`, described by `autodoc --contracts 'todos.*'`.

The verbs share the `todos.` namespace prefix so they appear
together in `commands_list` output, distinct from the existing
`wake` / `say` / `addressbook` / `diff_queue` etc. surface.

---

## TL;DR

| Verb              | Effect                                                                 |
|-------------------|------------------------------------------------------------------------|
| `todos.list`      | List tasks in the active workspace (`status` filter, default `open`)   |
| `todos.show`      | Fetch one task by id                                                   |
| `todos.list_dirs` | Show every store AutoDoc's daemon knows                                |
| `todos.get_dir`   | Return the absolute path of the active `.todo-list/`                   |
| `todos.add`       | Create a new task                                                      |
| `todos.update`    | Patch a task's hand-editable fields (not `status`, not `assignee`)     |
| `todos.status`    | Transition open / in-progress / completed / deferred / archived        |
| `todos.assign`    | Set assignee; an `open` task becomes `in-progress`; **recipient notified** |
| `todos.archive`   | Convenience alias for `status=archived`                                |
| `todos.remove`    | Hard-delete a task file (irreversible)                                 |
| `todos.refresh`   | AutoDoc reconciles the active buckets (placement, errors[], 28-day archive) |
| `todos.set_dir`   | Point this workspace at a different, existing `.todo-list/`            |

These twelve are the whole surface. A call to a removed verb is
rejected with `code = "unknown_command"`:

- `todos.fire` and `todos.automation_set` went with automation (the
  `automated` status, `condition` / `execute`, firing): ADR 1791532020
  §3 step 3.
- `todos.import` went with D3: the KB migration it served finished on
  2026-05-26.

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

| `code`                   | Means                                                                  |
|--------------------------|------------------------------------------------------------------------|
| `invalid_args`           | a field is wrong; the message names it (AutoDoc's `todos.invalid` too) |
| `not_found`              | no such task: list again                                               |
| `stale`                  | the task changed since the `rev` you passed (or between the verb's read and its write): show it again, and retry if your change still applies |
| `unclaimed`              | the store is not AutoDoc's yet (a rollback released it): tell the user |
| `not_writable`           | the directory is not a store AutoDoc may write                          |
| `exists`                 | an id or a target that is already taken                                |
| `dependency_unavailable` | AutoDoc is missing ("AutoDoc required"), or auto-core is too old       |
| `timeout`                | the daemon did not answer in time                                      |
| `internal_error`         | anything else; the message says what                                   |

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
| Edit `priority` / `due`               | direct YAML edit    | **no event fires** — silent              |
| Edit `assignee:` by hand              | direct YAML edit    | metadata only: **nobody is notified**, and the scope is dropped |
| Transition `status:`                  | `todos.status`      | fires `core.todo.status:changed`         |
| Notify someone of an assignment       | `todos.assign`      | mailbox message to recipient's inbox     |
| Add / remove a task                   | `todos.add` / `.remove` | events; AutoDoc journals it          |
| Reconcile a stale dir                 | `todos.refresh`     | re-evaluates buckets, errors[], archive  |

**Rule of thumb**: if you want the panel UI to refresh or
another agent to wake about your change, use a verb. If you're
just hand-editing metadata for your own bookkeeping, edit the
file. AutoDoc reads a hand-edited file as it is, and its change log
records the edit (as an `update`, never as an assignment).

---

## Per-verb reference

### `todos.list`

`args.status` ∈ `{open, in-progress, deferred, completed,
archived, all}`; the default is `open`. `all` spans every bucket,
the archive included. The answer is a slim projection, `{id,
title, file_path}` per task; pass `full = true` for the whole task.

```jsonc
{ "kind": "command", "command": "todos.list", "args": { "status": "open" } }
→ { "ok": true, "value": { "count": 5, "status": "open", "tasks": [...] } }
```

### `todos.show`

```jsonc
{ "kind": "command", "command": "todos.show", "args": { "id": "2026-05-26-foo" } }
→ { "ok": true, "value": { /* the frontmatter, plus rev, path, file_path, description */ } }
```

`rev` is the SHA-256 of the task file's bytes, `path` is
store-relative, `file_path` absolute and `description` the body.

### `todos.list_dirs` / `todos.get_dir`

Discovery surface — useful when an agent isn't sure which
`.todo-list/` is currently active. `get_dir` returns the
absolute path; `list_dirs` returns every store AutoDoc's daemon
knows, `{todo_dir, workspace_roots, last_touched, claimed,
store_id}` (so you can spot "this task list is shared across N
workspace roots" cases).

### `todos.add`

`title` is required; everything else is optional and limited to
the hand-editable surface (`description`, `priority`, `due`,
`assignee`, `tags`, `adr`, `review`, `blocked`). Managed fields
(id, lifecycle timestamps, errors) are AutoDoc's. **With an
`assignee`, the add is an assignment**: an open task starts
`in-progress`, and the assignee is notified as for `todos.assign`.

**Document refs (`adr`, `review`): give the ABSOLUTE path.**
You reliably know where a doc lives on disk; you do NOT need to
guess the right `$KB_ROOT` / `$WORKSPACE` prefix. AutoDoc
normalizes any absolute ref to the portable `$VAR/...` symbolic
form on write, choosing the most specific known root
(`$KB_ROOT` → `$WORKSPACE` → user vars → `$HOME`; absolute kept
only when no root contains it). This is what lets the panel open
the attachment from any workspace. A bare relative ref resolves
against the KB root only. Pass the absolute path.

```jsonc
{
  "kind": "command", "command": "todos.add",
  "args": {
    "title": "Verify v0.1.43 assign event payload shape",
    "priority": "normal",
    "tags": ["test", "ad-hoc"],
    "adr": ["/Users/you/.config/nvim/.auto-agents-config/kb/adrs/0031-auto-core-per-project-todo-task-system.md"]
  }
}
→ { "ok": true, "value": { "id": "2026-05-26-verify-v0143-assign-event-payload-shape" } }
// the stored task records adr[0] as
//   $KB_ROOT/adrs/0031-auto-core-per-project-todo-task-system.md
```

The panel auto-refreshes: `todos.add` (and `update` / `remove`)
fire `core.todo:changed`, so a created task appears without a
manual refresh.

### Writing at the rev you read

`todos.update`, `todos.status`, `todos.assign`, `todos.archive` and
`todos.remove` take an optional `rev`: the one `todos.show` (or
`todos.list` with `full = true`) gave you. With it, a task someone else
changed since you read it is refused as `stale` instead of overwritten —
pass it whenever your change was decided from what you read (a whole
`review` / `tags` list, say). Without it the verb reads the task and
writes at that rev.

### `todos.update`

Patch any hand-editable field: `title`, `description`,
`priority`, `due`, `tags`, `adr`, `review`, `blocked`. A patch
naming `status` or `assignee` is refused (`invalid_args`): those
go through `todos.status` and `todos.assign`.

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
auto-finder panel + other subscribers can react. The same status
is a no-op. `archive` is a convenience for `status=archived` with
proper `archived_at` timestamping (and `completed_at`
preservation when coming from completed).

### `todos.assign`

Sets `assignee:`. **Assigning an `open` task makes it
`in-progress` in the same write** (D1, ADR 1791532020 §2.3);
re-assigning never moves a task backwards. auto-core's notifier
reads AutoDoc's change log and delivers a **one-shot mailbox
message** to the recipient agent's inbox:

```
Subject: [todos] task assigned to you: <title>

You have been assigned a task.

  id        : 2026-05-26-foo
  title     : Verify v0.1.43 assign event payload shape
  file_path : /Users/.../.todo-list/in-progress/2026-05-26-foo.md

Reason: <optional one-liner from args.reason>
```

The message's id is derived from the change (`todo-<store>-<seq>`),
so delivery is at-least-once: **an assignment message whose id you
have already seen is a duplicate.** The recipient must be registered
in the same Neovim (its addressbook); a recipient that registers
within a grace window still gets it.

**A bare name is this project's agent** (ADR 1791532020 §2.5a). Several
Neovims, of several projects, can share one store (the global KB's). An
assignment made through this verb carries this project's scope, so a
bare `agent:lector` (or `lector`) is delivered only by a Neovim of the
project that made it, and survives its restarts. Two ways reach an agent:

- **This verb, with a bare name**, for this project's agents. Prefer it:
  the task file keeps the bare name, never an instance id.
- **A full id**, `agent:lector:<instance>`, for one exact instance (another
  project's agent, say). It is delivered by that instance alone.

A bare assignee with no scope reaches **no one**, never everyone: a hand
edit of `assignee:`, an assignment made before AutoDoc protocol 30, or a
raw `autodoc --call todos.assign` that passes no scope. Re-assign through
this verb to deliver it.

Pass `args.assignee = null` to **clear** the assignee. Clearing
does NOT emit a message (no one to notify).

### `todos.remove`

Irreversible — no undo, no archive bucket. Use this for
genuinely-wrong tasks (typo'd duplicates, accidental imports);
prefer `todos.archive` for completed work you want to keep on
record.

### `todos.refresh`

Run after bulk file mutations (e.g. you direct-edited several
files) so AutoDoc re-evaluates bucket placement, runs reference
validation, and applies the 28-day auto-archive rule. It never
reads the archive. Returns AutoDoc's summary: `{scanned, moved,
archived, errors_set, rewritten, malformed}`.

### `todos.set_dir`

Re-point the active workspace at a different, **existing**
`.todo-list/`. Useful when sharing one store across a family of
worktrees (e.g. `~/Source/<repo-family>/.todo-list/`). Pass
`args.path = null` or empty string to clear the override and
resume `<workspace_root>/.todo-list/`.

---

## Reading the directory directly

Agents have read access to the active workspace, including
`.todo-list/`. The on-disk layout is:

```
.todo-list/
├── open/<id>.md
├── in-progress/<id>.md
├── deferred/<id>.md
├── completed/<id>.md
└── archived/YYYY/MM/<id>.md
```

Each file is markdown with YAML frontmatter; schema v1 is
documented in ADR-0031 §2 (minus automation, ADR 1791532020 §2.2).
You can `grep` or directly read files for context; **avoid writing
to these files directly unless you're confident the change doesn't
need side effects** (see the table above).

---

## Reading the panel listing

When the user has the auto-finder todos panel open, tasks are
rendered with a 1-based ephemeral index per bucket (`1.`, `2.`,
`3.`). **Treat that index as ephemeral — refer to a task by its
`id` for anything persistent.** The index reorders on every
refresh (errors-to-top, then chronological); ids never change.

---

## See also

- ADR-0031 — the original design of the per-project todo system.
- ADR 1791532020 — AutoDoc owns the todo system: the format, the
  rules, the change log and the notifications.
- `autodoc --contracts 'todos.*'` — the daemon's verbs, their
  params, answers and error codes.
- `commands_list` — call with `args.owner = "auto-agents"` to
  see this surface alongside the rest of the auto-agents
  command verbs.
