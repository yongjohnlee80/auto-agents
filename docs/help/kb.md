# kb — knowledge base

Where the KB lives depends on **which TOML the active agents came from**,
because agent identities are persistent — jarvis defined in `global.toml`
should perform identically regardless of which directory you opened nvim
in. Default resolution:

| Active config source | Default `kb_root`                               |
|----------------------|-------------------------------------------------|
| `global` (global.toml)  | `<stdpath('config')>/.auto-agents-config/kb` (one shared KB) |
| `project` (per-project)  | `<project-root>/.auto-agents/kb` (project-local) |

Set `[kb].root = "/abs/path"` in any TOML to override. `project import`
freezes the source's effective KB path into the destination so an
imported agent keeps reading the same KB.

The KB has a **type** (`coding`, `wiki`, `research`, `ops`, `general`,
or `custom`) — pick at init.

The KB type drives the layout, the conventions, and the agent contract
(`<kb_root>/AGENTS.md`). Switch types with `kb init <new-type>` —
existing files are preserved, only the schema doc is refreshed.

## init

```
kb init                            # list available types
kb init <type>                     # seed with a built-in type
kb init custom <path-to-seed.md>   # bring your own seed
```

Available types (`kb init` with no arg shows them with one-liners):

- **coding** — codebase conventions, ADRs, review playbooks (default
  for nvim users).
- **wiki** — Zettelkasten-flavored, durable interlinked knowledge.
- **research** — papers, hypotheses, experiments, synthesis.
- **ops** — runbooks, alerts, incidents, postmortems.
- **general** — minimal living seed; structure emerges from work.
- **custom** — your own `.md` is copied to `<kb_root>/AGENTS.md`.

**Affects:**
- Creates `<kb_root>/{raw,shared,agents}/` plus type-specific subdirs.
- Drops `raw/README.md` declaring immutability.
- Copies the seed to `<kb_root>/AGENTS.md` (canonical contract).
- Drops `CLAUDE.md` and `GEMINI.md` pointers next to `AGENTS.md`.
- Creates empty `log.md` and `index.md` if missing.
- Writes `[kb].type` (and `[kb].seed` for custom) into the active TOML.

Idempotent on reruns: existing user content is preserved; only the
schema doc rewrites with `force_schema = true` (which `kb init` always
sets).

## ingest

```
kb ingest                       # show worklist
kb ingest --attach <N>          # show + dispatch worklist to slot N
```

`kb ingest` itself **performs no ingestion** — it produces a diff
report. The actual reading + synthesis is the agent's job (which is
the part that needs LLM reasoning). With `--attach <N>`, the worklist
is sent via stdin to slot N so the agent can act on it directly.

Compares files in `raw/` against `shared/sources/*.md` source pages
(one summary page per ingested raw file) using a `source_sha`
recorded in each source page's frontmatter. Reports four buckets:

- **new**     — file in `raw/`, no source page references it (never ingested).
- **edited**  — source page exists, sha mismatch (re-ingest needed).
  This is the case for mutable raw docs like code reviews.
- **current** — source page sha matches the raw file (skip).
- **orphan**  — source page references a raw path that no longer exists.

No persisted index — frontmatter IS the persisted state. The agent
re-runs `kb ingest` on demand to know what work is left.

**Source-page convention** (taught to agents via the seed `AGENTS.md`):

```yaml
---
type: source
sources: [raw/path/to/foo.md]
source_sha: <sha256 of raw/path/to/foo.md at ingest>
ingested_at: 2026-05-01
---
```

Pages that aggregate multiple sources (entities, topic hubs,
syntheses) list `sources:` for citation but DON'T track sha — only
the one-to-one source pages do. The diff tool only inspects pages
under `shared/sources/`.

**Skipped during scan**: `raw/README.md` (our scaffolded immutability
note), dotfiles, and the `raw/archive/` subtree.

## path

```
kb path
```

Prints the resolved KB root and ensures the layout exists (creates
missing dirs/files as needed). Useful for confirming where things
landed and triggering a layout repair.

## scope

```
kb scope <N>                  # opens a wizard pre-filled with current
```

Wizard: pick a slot, then pick `shared | private | isolated`. The
scope controls the env vars an agent sees at spawn:

| Scope     | Reads                                  | Writes                |
|-----------|----------------------------------------|-----------------------|
| shared    | `kb/shared` + `kb/agents/*`            | `kb/shared`           |
| private   | `kb/shared` + `kb/agents/<name>`       | `kb/agents/<name>`    |
| isolated  | `kb/agents/<name>`                     | `kb/agents/<name>`    |

**Affects:** TOML is saved. Runtime change applies on next spawn —
restart the slot to apply immediately.

## sync

```
kb sync
```

Regenerates `manifest.json` per namespace (one in `shared/` and one in
each `agents/<name>/`). Each manifest tracks every `.md` file's
sha256, mtime, size, and outbound wikilinks. Reports broken
`[[wikilinks]]` (links pointing at pages that don't exist).

**Affects:** writes manifests; never edits source pages. Run after
bulk imports or before publishing — it's the closest thing to a lint.

## new

```
kb new                             # wizard
kb new <relative-path>             # power-user shortcut, bypasses wizard
```

Creates an empty `.md` at `<kb_root>/<relative-path>` and opens it in
a non-panel editor window. With no args, the wizard prompts for the
relative path. Appends a `log.md` line.

**Affects:** filesystem (creates the dir + file); editor (opens it).

## open

```
kb open <relative-path>
```

Opens an existing KB file in the editor. No file creation; just nav.

## attach

```
kb attach <N> <relative-path>
```

Sends the absolute path of `<kb_root>/<relative-path>` to slot `N`'s
stdin. Convenience for handing the agent a specific KB page to read.

**Affects:** runtime stdin only.

## tail

```
kb tail
```

Opens `log.md` in the editor with `autoread = true` so new appends
show up live. Cursor jumps to the end.

## log

```
kb log
```

Prints the path of `log.md` without opening it.

## obsidian-init

```
kb obsidian-init
```

Scaffolds an Obsidian vault config (`<kb_root>/.obsidian/`) with sane
defaults: graph view enabled, daily-notes off, source mode default,
markdown-only file types. Open `<kb_root>` in Obsidian as a vault to
get the graph view, search, and Dataview queries over your frontmatter.

**Affects:** writes `app.json` and `graph.json` under `.obsidian/`;
skips files that already exist.

## How KB operations interact with the rest of the system

- **Project**: `[kb].root` is part of the project (or global) TOML.
  `project import` shares the source's KB root verbatim — the same KB
  is used by mirrored project paths. `project remove` does **not**
  touch the KB on disk.
- **Agents**: Each spawn writes/refreshes `<agent-cwd>/<KIND>.md`
  (CLAUDE.md / AGENTS.md / GEMINI.md, per kind) with an
  auto-agents-marked block that points at `<kb_root>/AGENTS.md`. The
  user's hand-written content above/below the block is preserved.
- **Scope env vars**: `$AUTO_AGENTS_KB_ROOT`, `$AUTO_AGENTS_KB_READ`
  (colon-separated), `$AUTO_AGENTS_KB_WRITE`, `$AUTO_AGENTS_KB_SCOPE`
  are exported to every spawned agent.
- **Resources**: independent of KB; `resource grant` adds paths
  outside the KB tree. Agents see both `$AUTO_AGENTS_KB_*` and
  `$AUTO_AGENTS_ALLOWED_PATHS` in their environment.
