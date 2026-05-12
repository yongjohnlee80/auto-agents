# Knowledge Base — Coding Project Contract

This knowledge base is a **coding-project KB** shared between every
agent (Claude, Codex, Gemini, Copilot, …) and the user. It exists to
make every agent a disciplined contributor on this codebase: planning
code changes, implementing them, reviewing PRs, debugging incidents,
and explaining systems to humans.

The KB is **the contract** — conventions in here are followed
**rigorously**. If you (the agent) disagree with a rule, surface the
disagreement explicitly *before* writing code that violates it. Do not
silently ignore a convention.

`AGENTS.md` is the always-loaded contract. Keep it compact. Expanded
rules live under `docs/agent-schema/` and are part of the schema:

- [`docs/agent-schema/page-conventions.md`](./docs/agent-schema/page-conventions.md)
  — wiki kinds, project pages, ADR format, code-review catalog,
  Obsidian compatibility, frontmatter shapes
- [`docs/agent-schema/operations.md`](./docs/agent-schema/operations.md)
  — ingest, plan, implement, review, debug, query, lint, index/log
  workflows
- [`docs/agent-schema/source-intake-growth.md`](./docs/agent-schema/source-intake-growth.md)
  — durability test, source quality, raw immutability, growth policy

Read the relevant detail file before non-trivial edits. If this file
conflicts with a detail file, pause and reconcile both in the same
change.

`CLAUDE.md` and `GEMINI.md` are compatibility pointers to this file.
Do not duplicate schema content there.

---

## Core Model

The KB has four top-level knowledge areas:

- `raw/` — immutable source material and evidence
- `wiki/` — durable synthesized knowledge (work, technology, ops)
- `projects/` — mutable operational state for projects under
  active work
- `agents/<name>/` — per-agent private scratch (working notes, draft
  reviews, throwaway reasoning)

Supporting files:

- `adr/` — Architecture Decision Records (top-level, immutable once
  accepted)
- `index.md` — catalog of wiki/project pages plus the source-ingest
  register
- `log.md` — append-only chronological trail of ingests, impls,
  reviews, schema changes
- `_templates/` — concrete page templates per kind
- `docs/agent-schema/` — this contract's detail files
- `archive/` — retirement area for raw/wiki/project material that
  must remain traceable

The user curates sources and direction. Agents own synthesis,
cross-linking, project state, index updates, and log entries.

---

## Hard Rules (Non-Negotiable)

1. **`raw/` is immutable.** Read from it but never edit, rename, or
   delete its contents during normal ingest. To retire a raw doc,
   move it to `archive/raw/<original-path>` and update citations.
   Outright deletion only for wrong, private/sensitive, or
   accidentally-clipped sources — citing pages must be scrubbed in
   the same change.

2. **Conventions in `projects/coding-rules/` are binding.** When
   planning or implementing in a covered area, read the convention
   file first. If the convention is wrong, surface the conflict —
   don't silently bypass.

3. **ADRs are the source of truth for architectural decisions.** If
   work conflicts with an ADR in `adr/`, you must either (a) follow
   the ADR, or (b) propose a new ADR that supersedes it.

4. **Detail is load-bearing — DO NOT condense rules.** Conventions,
   ADRs, and operation playbooks are **rules**, not summaries. When a
   reviewer or implementer reads `projects/coding-rules/<area>.md`,
   they need the *exact* wording — a "high-level direction" cannot
   resolve disputes.

   **On ingest:** copy convention / ADR / operation content
   **verbatim** from `raw/`. A short TL;DR at the top is fine, but
   the body must preserve full detail. Strip nothing. Compress
   nothing. Paraphrase nothing.

   This rule explicitly **inverts** the wiki-style "synthesize once
   at ingest" pattern for the rule-bearing categories. Synthesize
   freely for `wiki/synthesis/` (cross-cutting analyses) and
   `wiki/concepts/`/`wiki/topics/` (definitions and hubs); do NOT
   synthesize for `projects/coding-rules/`, `adr/`, or
   `wiki/operations/`. When in doubt: keep the detail.

5. **Reviews are durable, append-only, and live in
   `wiki/code-review/`.** Published code reviews land there with the
   filename pattern `YYYY-MM-DD-<repo>-<worktree>-<description>.md`
   and follow the give/take/update/end cycle. See
   `wiki/code-review/about.md`. Working notes / pre-draft scratch may
   live under `agents/<your-name>/reviews/`, but the published review
   is shared knowledge.

6. **Cite, don't fabricate.** Every non-obvious claim about the
   codebase ("this function returns X", "the migration runs at
   startup") must be verifiable — link to the file/line/PR/commit,
   or grep first.

7. **Update before duplicating.** Extend an existing convention,
   operation, entity, or concept page before creating a near-duplicate.

8. **No secrets, ever.** Describe where a credential lives ("set
   `FOO_TOKEN` in `~/.config/foo.toml`"), never copy the value.

---

## Layout

```text
<kb-root>/
├── AGENTS.md                    ← this file (canonical schema)
├── CLAUDE.md / GEMINI.md        ← compatibility pointers
├── index.md                     ← catalog of wiki/project pages
├── log.md                       ← append-only chronology
├── adr/                         ← Architecture Decision Records
├── raw/                         ← IMMUTABLE evidence
│   ├── specs/                   ← product specs, RFCs, design docs
│   ├── issues/                  ← bug reports, incident reports
│   └── transcripts/             ← meeting notes, customer calls
├── wiki/                        ← durable synthesized knowledge
│   ├── sources/                 ← summaries of raw docs
│   ├── entities/                ← people, products, providers, repos
│   ├── concepts/                ← technical concepts & patterns
│   ├── topics/                  ← hub pages routing to many wiki pages
│   ├── operations/              ← repeatable task playbooks
│   ├── synthesis/               ← cross-cutting analyses
│   └── code-review/             ← durable code-review records
├── projects/                    ← mutable operational state
│   ├── coding-rules/            ← first-read convention catalog
│   └── <project-slug>/          ← per-project: about/reference/tasks/report
├── agents/<agent-name>/         ← agent-private scratch
│   ├── tasks/                   ← in-flight task notes
│   ├── reviews/                 ← per-PR working notes (NOT published)
│   └── scratch/                 ← throwaway reasoning
├── _templates/                  ← copy when creating a new page
├── docs/agent-schema/           ← this contract's detail files
└── archive/                     ← retirement area
```

---

## Common Workflows (Quick Reference)

Detailed procedures in
[`docs/agent-schema/operations.md`](./docs/agent-schema/operations.md).

- **Ingest** — read source, write `wiki/sources/<slug>.md` with
  `source_sha` + `ingested_at`, propagate into conventions / ADRs /
  operations / concepts, log the op.
- **Plan code changes** — read `projects/coding-rules/index.md`, the
  matching `wiki/operations/<work-on-X>.md`, and any relevant ADR
  before proposing.
- **Implement** — honor flagged conventions, minimal diffs, run
  tests, log the op. Update the convention if you found it wrong;
  don't silently fix elsewhere.
- **Review a PR** — search prior reviews in `wiki/code-review/`,
  cross-check against `projects/coding-rules/*` and `adr/*`, publish
  to `wiki/code-review/` (findings first, append-only), log the op.
- **Debug** — reproduce first, document the trail in
  `agents/<name>/scratch/`, write `wiki/synthesis/<slug>.md` if the
  pattern is likely to recur.
- **Query** — start at `index.md`, follow `[[wikilinks]]`, answer
  with citations.
- **Lint** — report findings first; don't make large structural
  fixes without confirmation.

---

## Page & Project Rules (Quick Reference)

Full detail in
[`docs/agent-schema/page-conventions.md`](./docs/agent-schema/page-conventions.md).

Wiki pages require YAML frontmatter:

```yaml
---
type: source | entity | concept | topic | operation | synthesis
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [raw/path/to/source.md]
tags: [tag1, tag2]
---
```

Project pages:

```yaml
---
type: project | project-todo
project: <project-slug>
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [raw/path/to/supporting.md]
status: active | blocked | done
tags: [tag1, tag2]
---
```

Conventions: kebab-case filenames; dense, factual style; 300–1,500
words sweet spot (3,000 is a refactor signal); `[[wikilinks]]` for
intra-vault references; `sources:` is append-only; mark unsourced
claims with `> [unsourced]`.

---

## Growth Policy (Quick Reference)

Full detail in
[`docs/agent-schema/source-intake-growth.md`](./docs/agent-schema/source-intake-growth.md).

Don't split the KB just because document counts are rising. Split by
lifecycle, not volume. Preferred scaling moves in order: update
`index.md`, add a topic hub, split an oversized page, promote a
recurring answer to `wiki/synthesis/`, tag with `realm:` before
adding a new top-level directory.

---

## Things To Avoid

- Editing or deleting `raw/` content during normal ingest.
- **Condensing** convention / ADR / operation content on ingest —
  detail is the value (Hard Rule #4).
- Publishing code reviews to `agents/<name>/reviews/` — that's
  working-notes only; published reviews go to `wiki/code-review/`.
- Treating `projects/` as durable knowledge — it's mutable state.
- Treating `wiki/` as scratch space — that's `agents/<name>/scratch/`.
- Silently bypassing a convention because "it's just one line."
- Inventing ADR numbers — check `adr/` for the next free number.
- Pasting credentials, API keys, tokens, or private data anywhere.
- Touching another agent's `agents/<name>/` without permission.
- Skipping `log.md` entries — they're how we audit each other.
- Over-engineering tooling before the KB has outgrown `grep`, `rg`,
  and `index.md`.

---

## Why This Style

A coding KB only earns its keep if it makes the **next** PR better.
The structure above is biased toward decisions you'll reuse
(conventions, ADRs, operations) and against scratch state that
decays. The KB doesn't need to know what every commit did; `git log`
already does that. It needs to know what we'd *do differently* next
time.
