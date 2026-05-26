---
type: kb-rules
created: 2026-05-18
updated: 2026-05-18
status: active
applies-to: [coding, wiki, research, ops, general, custom]
tags: [kb, meta, rules, log-rotation, frontmatter]
---

# KB Rules — Cross-Cutting Conventions for This Knowledge Base

**Tags:** `type:kb-rules` `living-doc` `owner:shared` `area:kb` `area:meta` `status:active` `applies-to:all-kb-types`

**Abstract:** Universal rules that apply to every knowledge base auto-agents creates, regardless of type (coding / wiki / research / ops / general / custom). Auto-installed alongside `AGENTS.md` on `kb init`; `AGENTS.md` cites it as a load-bearing companion. Edit here for KB-wide policy; edit `AGENTS.md` for type-specific schema.

---

## R1 — `log.md` weekly rotation

`log.md` is the KB's append-only operational chronicle. Without rotation it grows unbounded (the seed KB at the time this rule was written sat at ~46k tokens — 10% of the entire KB by token weight, almost none of it usefully retrieved). Rule:

1. **Live `log.md` retains only the current ISO week.** Format of each entry is unchanged: `## [YYYY-MM-DD HH:MM] op | actor | summary`.

2. **Closed weeks roll into `log/YYYY-W<NN>.md`.** One file per week. Filename uses ISO 8601 week numbering (`%G-W%V` in `date(1)`):
   - `%G` is the **ISO-year** — NOT the calendar year. Important: late December and early January can sit in different ISO-years depending on which week they fall into. Use `date -d "<entry-date>" '+%G-W%V'` to compute the bucket, never split the date string by hand.
   - Example: 2026-01-01 (Thursday) belongs to `2026-W01`; 2025-12-30 (Tuesday) belongs to `2026-W01` too. 2024-12-30 (Monday) belongs to `2025-W01`.

3. **Partitions older than 3 months from `today` move to `archive/log/YYYY-W<NN>.md`.** "3 months" = 12 weeks (84 days), rolling. The check is: `archive_cutoff = today - 84 days`; any `log/<year>-W<NN>.md` whose Monday-of-week is before that cutoff moves.

4. **Cadence is manual / on-demand.** Rotation runs as part of `/save-kb`-style maintenance ops or when a developer notices `log.md` getting heavy. No background daemon — the trigger is human judgment.

5. **Live `log.md` carries a short header pointing at the rotation tree.** The canonical shape is:
   ```markdown
   # auto-agents knowledge-base log

   > **Current ISO week only.** Closed weeks live in `log/YYYY-W<NN>.md`;
   > weeks older than 3 months live in `archive/log/YYYY-W<NN>.md`.
   ```

### Rotation procedure (for the agent performing it)

1. Compute `today_week = date '+%G-W%V'` and `archive_cutoff_date = date -d '12 weeks ago' '+%Y-%m-%d'`.
2. For every `## [YYYY-MM-DD …]` entry in `log.md`, compute its ISO week via `date -d "<entry-date>" '+%G-W%V'`. If the week ≠ `today_week`, the entry is rotation-eligible.
3. **Append** rotation-eligible entries to `log/<week>.md` (create the file with a one-line `# Log entries — <week>` header if absent). Preserve original ordering.
4. **Remove** rotated entries from `log.md`. Leave the header + the current-week entries.
5. Sweep `log/`: any `log/<year>-W<NN>.md` whose Monday is before `archive_cutoff_date` → `git mv` to `archive/log/<year>-W<NN>.md` (mkdir if needed).
6. Append a one-line log entry to the now-current `log.md` documenting the rotation (which weeks moved where).

---

## R2 — Frontmatter required for new docs under `shared/` and `agents/`

Every new `.md` file under `shared/` (any subdir) and `agents/<name>/` (any subdir) carries **both** YAML frontmatter AND inline preview lines. The two surfaces serve different consumers and are NOT redundant — keep both.

- **YAML frontmatter** (the `--- … ---` block at the top) — parsed by tools: `auto-agents.kb.frontmatter`, `auto-agents.kb.obsidian`, future RAG indexers, the `/document-it audit-cost` cost analyzer.
- **Inline `**Tags:**` + `**Abstract:**` lines** (right after the H1, in the body) — read by LLMs to skim-before-load. Without them, every retrieval pays the full body cost.

### Minimum required shape

```markdown
---
type: <synthesis | adr | convention | playbook | glossary | source | review | task | scratch | incident | kb-rules>
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: <active | open | completed | closed | blocked | draft | superseded>
tags: [<tag>, <tag>, ...]
---

# <Title>

**Tags:** `type:<x>` `status:<y>` [other structured tags …]

**Abstract:** One-sentence summary so a reader can decide whether to load the body.

(body — the actual content)
```

### Inline tag taxonomy (existing practice, codified)

Inline `**Tags:**` uses backtick-quoted `key:value` atoms. Common keys:

- **`type:`** — `convention`, `adr`, `playbook`, `synthesis`, `glossary`, `source`, `todo-list`, `review`, `incident`, `task`, `scratch`, `kb-rules`.
- **`status:`** — `active`, `open`, `completed`, `closed`, `blocked`, `draft`, `superseded`.
- **`living-doc`** / **`one-shot`** — mutability hint. `living-doc` mutates over time (e.g. todo lists); `one-shot` is finalized on publish (e.g. a session-lessons doc).
- **`owner:`** — `shared` for joint work; an agent slug (`jarvis`, `lector`, `ultron-prime`, …) when one agent owns the doc; `johno` for user-authored canon.
- **`repo:`** — plugin name when relevant; `repo:shared` for cross-cutting concerns spanning multiple repos.
- **`area:`** — subsystem within the plugin (`mailbox`, `panel`, `logging`, `diff-queue`, `dbase`, …).
- **`kind:`** — `bug`, `feature`, `cleanup`, `convention-compliance`, …

Type-specific docs (e.g. `shared/conventions/todo-handling.md`) may layer additional tags (e.g. `closed-reason:scope-resolved`). The taxonomy is open — add tags when retrieval needs them.

### YAML frontmatter notes

- `tags:` is a YAML array. Use **free-form lowercased identifiers** (e.g. `[auto-agents, logging, family-wide, hard-rule]`) — these flow into tool-readable indexes like Obsidian's graph. Don't try to mirror the inline `key:value` shape inside the YAML array; the two systems serve different consumers.
- `sources:` is an array of `raw/<path>` references for docs ingested from raw. Required when mirroring raw content (per AGENTS.md Hard Rule #4). Optional for purely synthetic content.
- `source_sha:` + `ingested_at:` are required when a `shared/conventions/` page mirrors a raw doc — they enable re-ingest drift detection.

### Exceptions

- **`raw/`** — IMMUTABLE. Whatever frontmatter the original source carried is preserved verbatim. No enforcement.
- **`archive/`** — frozen historical state. Frontmatter is whatever it was when the doc was archived.
- **`_templates/`** — template files demonstrating the shape; frontmatter intentionally illustrative.
- **Top-level files** (`README.md`, `index.md`, `log.md`, `AGENTS.md`, this file) — exempt; their roles are structural and they aren't part of any retrieval surface.

### When the inline shape conflicts with the YAML shape

The inline `**Tags:**` line carries the load-bearing semantic state — `status:open` vs `status:completed` flips happen on the inline line first because LLMs read it. The YAML `tags:` array is best-effort echo for tooling that can't parse the inline form. **Inline is source of truth; YAML is convenience.** When the two drift, fix the YAML to match the inline.

---

## R3 — `shared/conventions/` is the source of truth for binding behavior

(Restates a principle that already lives in `AGENTS.md` Hard Rule #2 / Hard Rule #4; surfaced here so the KB seed across every type carries the same expectation.)

Convention docs under `shared/conventions/` are **binding** — they constrain agent behavior. Hard Rule #4 of `AGENTS.md` requires preserving every clause verbatim from the originating raw source. When a convention conflicts with code or an in-flight task, the convention wins or a new ADR overrides it. Agents do not silently ignore.

Periodic audit of `shared/conventions/` (for accuracy, currency, mutual consistency) is healthy — schedule it as a task in the active `.todo-list/` (see `shared/conventions/todo-handling.md`) when drift becomes likely. The legacy `type:todo-list`-tagged synthesis docs are no longer the canonical surface; tasks live in `auto-core.todo`'s per-project task store.

---

## Cross-references

- `AGENTS.md` — KB-type-specific schema, layout, hard rules. **Read alongside this file.**
- This KB's `shared/conventions/` (or equivalent binding-rules dir per the KB type) — type-specific conventions that layer on top of these universal rules.
- `KB_MIGRATION_V2.md` in the auto-agents.nvim source tree — playbook for retrofitting a legacy KB created before these rules existed.