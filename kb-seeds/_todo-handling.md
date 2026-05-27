---
type: convention
revision: 4
status: active
sources:
  - shared/adrs/0031-auto-core-per-project-todo-task-system.md
tags: [todos, convention, todo-handling]
---

# Convention — Todo handling

**Tags:** `type:convention` `living-doc` `owner:shared` `repo:shared` `area:todos` `area:workflow`

**Revision**: 4 — compare against your stored value on every spawn; re-ingest on change.

**Abstract:** Per-project policy for how tasks are stored, edited, and moved
between buckets. Each KB MAY customize this file; agents treat it as
authoritative for THIS project.

---

## Where this lives

| Location                                   | Purpose                              |
|--------------------------------------------|--------------------------------------|
| `<workspace>/.todo-list/`                  | The actual task files (per-project)  |
| `<kb>/shared/conventions/todo-handling.md` | THIS doc — per-project policy        |
| `$AUTO_AGENTS_TODOS_BOOTSTRAP_DOC`         | Operational reference for `todos.*`  |
| `auto-agents.nvim/lua/auto-agents/todos/migrate_kb.lua` | Migration script source  |

Backed by `auto-core.todo` (ADR-0031). Three surfaces expose the
same data:

  - **Lua API**: `require("auto-core.todo")` — host code, source of truth.
  - **Mailbox**: `todos.*` verbs — see `$AUTO_AGENTS_TODOS_BOOTSTRAP_DOC`.
  - **User cmd**: `:AutoAgentsTodos <verb>` — humans, with tab-complete.

---

## Agent protocol — store this in GLOBAL memory

Mailbox actions are reliably second-nature to agents because the
protocol is **internalized once** and applied everywhere — not
re-derived on every spawn. Todo handling should work the same way.

Save the core protocol (the `todos.*` surface exists; status /
assign / create / archive go through verbs; doc refs are
absolute-in / `$VAR`-out) to your **global** memory — it applies
across every autovim project, so it should outlive any single
project's local memory. Record this convention's `revision:`
alongside it.

Per-project *customizations* (rules a specific KB adds below) are
project-scoped — key those by project so they don't bleed across
workspaces.

Suggested memory keys:

```
feedback_todo_handling          (GLOBAL) — the core protocol +
                                  the revision you last ingested.
feedback_todo_handling_<project> (per-project) — only when THIS
                                  KB customizes the rules below.
```

On every spawn (ingest gate):

  1. Read this file's `revision:` field.
  2. Compare against your stored value.
  3. If newer (or absent): re-read end-to-end, adopt directives,
     update your global memory (+ per-project entry if customized).
  4. If equal: nothing to do.

This mirrors the mailbox bootstrap-revision protocol (see
`$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC`) — same discipline, same
reliability.

---

## Editing rules

Tasks are `.md` files with YAML frontmatter under
`<workspace>/.todo-list/{open,deferred,completed,archived/YYYY/MM/}`.
Schema v1 in ADR-0031 §2.

| Action                            | Path                          | Why                                    |
|-----------------------------------|-------------------------------|----------------------------------------|
| Read a task                       | direct file read              | preferred — cheap                      |
| Edit `title` / `description`      | direct YAML edit              | preferred — fast, no ceremony          |
| Edit `priority` / `due` / `tags`  | direct YAML edit              | metadata-only; no events fire          |
| Edit `adr` / `review` / `blocked` | direct YAML edit              | metadata-only; no events fire          |
| Transition `status:`              | `todos.status`                | fires events → panel + auto-archive    |
| Create a task                     | `todos.add`                   | proper lifecycle timestamps + id       |
| Update arbitrary fields           | `todos.update`                | safer than YAML edit when in doubt     |
| Archive                           | `todos.archive`               | sets archived_at + preserves history   |
| Remove                            | `todos.remove`                | irreversible; auditable                |
| Assign + notify                   | `todos.assign`                | mailbox message to the recipient       |
| Reconcile a stale dir             | `todos.refresh`               | re-evaluates buckets + errors[]        |

**Encouraged**: direct YAML edits to non-managed hand-editable fields
(title, description, priority, due, assignee, tags, adr, review,
blocked). Faster than a verb round-trip, and the panel picks up the
change on next refresh.

**Required via verbs**: anything that needs cross-process side
effects — `status` (events), `assign` (mailbox notification),
`add`/`remove`/`archive` (lifecycle + bucket placement).

**Do NOT** edit by hand: `id`, `version`, lifecycle timestamps
(`created`, `updated`, `status_changed`, `completed_at`,
`archived_at`), `errors[]`. These are managed by the host;
manual edits silently break refresh + cross-references.

### Document references (`adr` / `review`)

Give the **absolute path** to the document. You reliably know
where it lives on disk — you do NOT need to guess a `$KB_ROOT`
or `$WORKSPACE` prefix. The host normalizes any absolute (or
bare KB-relative) ref to the portable `$VAR/...` symbolic form
on write (auto-core v0.1.46+), picking the most specific known
root: `$KB_ROOT` → `$WORKSPACE` → user-defined vars → `$HOME`.
An absolute path is kept absolute ONLY when no known root
contains it (last resort — see
[[cross-machine-symbolic-refs]]).

```yaml
# you write (absolute):
adr:
  - /Users/you/.config/nvim/.auto-agents-config/kb/shared/adrs/0031-foo.md
# the host stores (portable):
adr:
  - $KB_ROOT/shared/adrs/0031-foo.md
```

`blocked:` is different — it holds todo task **ids**, not paths,
so keep those as bare filename stems:

```yaml
blocked:
  - 2026-05-26-some-other-task
```

This normalization is what lets the panel open an attachment
from any workspace. A bare relative like `shared/adrs/foo.md`
that the host can't resolve is left as-is and flagged
not-found — so prefer the absolute path.

---

## On first ingest — legacy detection

When you read this file for the first time (or after a revision bump),
scan the KB for **legacy `type:todo-list`-tagged docs OUTSIDE the
active `.todo-list/` directory** — typically `shared/synthesis/*-todos.md`
under the old convention, but any doc whose `**Tags:**` line contains
`type:todo-list` qualifies.

If you find any, **prompt the user** with three options:

**(a) Migrate to `$KB_ROOT/.todo-list/`**

KB-rooted task store. Shared across every workspace that opens this KB.

```vim
:AutoAgentsTodos set_dir path=$KB_ROOT/.todo-list
:AutoAgentsMigrateKbTodos --apply
```

**(b) Migrate to `$WORKSPACE/.todo-list/`**

Workspace-local task store. Travels with the project's git repo
but not with the KB.

```vim
:AutoAgentsTodos set_dir path=$WORKSPACE/.todo-list
:AutoAgentsMigrateKbTodos --apply
```

**(c) Leave as-is**

Keep the legacy docs in `shared/synthesis/` as historical reference.
Don't write new ones in that format. New tasks go through the
`todos.*` verbs.

### Migration entry points

| Surface     | Invocation                                                                |
|-------------|---------------------------------------------------------------------------|
| User cmd    | `:AutoAgentsMigrateKbTodos [--apply]`                                     |
| Lua API     | `require("auto-agents.todos.migrate_kb").migrate({ apply = true })`       |
| Source      | `auto-agents.nvim/lua/auto-agents/todos/migrate_kb.lua`                   |

Dry-run by default — `--apply` (or pass `apply=true`) to commit
the migration. Originals archive to `<kb>/shared/synthesis/archive/`.

---

## Per-project customization

Edit THIS file in your KB to encode project-specific rules
(e.g. "every task needs an `adr:` link before completion",
"prefix tags with `repo:<name>`"). When you change the policy,
**bump the `revision:` field** so agents notice on next spawn
and re-ingest into memory.

`auto-agents.kb.ensure_layout` only writes the seed when the file
is **absent** — your customizations survive plugin updates and
`force_schema` re-seeds (unless you opt in by deleting the file
first or passing `force_schema = true`).

---

## Spawned outside autovim?

If you are running **without** the autovim host — no
`$AUTO_AGENTS_MAILBOX_DIR`, no `$AUTO_AGENTS_TODOS_*` env vars,
`commands_list` doesn't list `todos.*` — then the mailbox verb
surface is **unavailable**. Detect this up front:

```sh
[ -n "$AUTO_AGENTS_MAILBOX_DIR" ] && echo "in autovim" || echo "standalone"
```

In standalone mode:

- You can still **read** any `<workspace>/.todo-list/` that
  exists, and **hand-edit** task files — but status / lifecycle
  side effects (events, bucket reconciliation, mailbox
  notifications) will NOT fire, because nothing is listening.
- Do **not** silently invent a task store in a random location.
  **Ask the user** where todos should live and how to manage
  them: (a) point you at an existing `.todo-list/` to hand-edit,
  (b) defer todo work until you're spawned inside autovim, or
  (c) use a project-local fallback they specify.
- Never fall back to the legacy `*-todos.md` convention as a
  "standalone" workaround — that's the thing we migrated away
  from.

---

## DO NOT

- Write new `*-todos.md` files in `shared/synthesis/` — that's the
  legacy convention. The migration above is one-way; once
  migrated, don't fall back.
- Skip a verb for status changes — the panel + auto-archive rely
  on the events firing.
- Edit managed frontmatter fields by hand (`id`, `version`,
  timestamps, `errors[]`).
- Treat the 1-based panel index as persistent — it's listing-only.
  Refer to a task by its `id` for anything durable.