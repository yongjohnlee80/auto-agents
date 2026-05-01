# Knowledge Base — Coding Project Contract

This knowledge base is a **coding-project KB**. It exists to make every
agent (Claude, Codex, Gemini, Copilot, …) a disciplined contributor on
this codebase: planning code changes, implementing them, reviewing PRs,
debugging incidents, and explaining systems to humans.

The KB is **the contract** — conventions in here are followed
**rigorously**. If you (the agent) disagree with a rule, surface the
disagreement explicitly *before* writing code that violates it. Do not
silently ignore a convention.

This file is the canonical schema. `CLAUDE.md` and `GEMINI.md` (if
present) are thin pointers to this file.

---

## Layout

```text
<kb-root>/
├── AGENTS.md                 ← this file (canonical schema)
├── CLAUDE.md                 ← pointer to AGENTS.md
├── GEMINI.md                 ← pointer to AGENTS.md
├── log.md                    ← append-only chronology
├── index.md                  ← catalog of pages, ADRs, playbooks
├── raw/                      ← IMMUTABLE — agents do not edit (see below)
│   ├── specs/                ← product specs, RFCs, design docs
│   ├── issues/               ← bug reports, incident reports
│   └── transcripts/          ← meeting notes, customer calls
├── shared/                   ← agent-shared durable knowledge
│   ├── conventions/          ← coding conventions per language/area
│   ├── adrs/                 ← Architecture Decision Records
│   ├── playbooks/            ← reusable runbooks (review-pr, debug-X, …)
│   ├── glossary/             ← project-specific terminology
│   └── synthesis/            ← cross-cutting analyses worth keeping
└── agents/<agent-name>/      ← agent-private operational scratch
    ├── tasks/                ← in-flight task notes
    ├── reviews/              ← per-PR review drafts
    └── scratch/              ← throwaway reasoning
```

---

## Hard Rules (Non-Negotiable)

1. **`raw/` is immutable.** Agents read from it but never edit, rename,
   or delete. To retire a raw doc, move it to `archive/raw/` (create if
   missing) and update citations. Outright deletion only for wrong,
   private/sensitive, or accidentally-clipped sources.
2. **Conventions in `shared/conventions/` are binding.** When planning
   or implementing code in a covered area, read the convention file
   first. If the convention is wrong, surface the conflict — don't
   silently bypass.
3. **ADRs are the source of truth for architectural decisions.** If the
   work conflicts with an ADR in `shared/adrs/`, you must either
   (a) follow the ADR, or (b) propose a new ADR that supersedes it.
4. **Detail is load-bearing — DO NOT condense rules.** Conventions,
   ADRs, and playbooks are **rules**, not summaries. Every clause,
   exception, code example, and edge case from the raw source carries
   enforcement weight. When a reviewer or implementer reads
   `shared/conventions/<area>.md`, they need the *exact* wording — a
   "high-level direction" cannot be cited, cannot resolve disputes,
   and cannot be enforced.

   **Therefore, on ingest:** copy convention / ADR / playbook content
   **verbatim** from `raw/`. A short TL;DR at the top is fine, but the
   body must preserve full detail. Strip nothing. Compress nothing.
   Paraphrase nothing. If a 400-line convention doc lands in `raw/`,
   the corresponding `shared/conventions/<area>.md` page is roughly
   400 lines too — plus frontmatter, plus optionally a TL;DR.

   This rule explicitly **inverts** the wiki-style "synthesize once at
   ingest" pattern for the rule-bearing categories. Synthesize freely
   for `shared/synthesis/` (cross-cutting analyses) and `shared/glossary/`
   (term definitions); do NOT synthesize for `shared/conventions/`,
   `shared/adrs/`, or `shared/playbooks/`. When in doubt: keep the
   detail.
5. **Cite, don't fabricate.** Every non-obvious claim about the codebase
   ("this function returns X", "the migration runs at startup") must be
   verifiable — link to the file/line/PR/commit, or grep first.
6. **Update before duplicating.** Extend an existing convention or
   playbook before creating a near-duplicate. The KB is small on
   purpose.
7. **No secrets, ever.** Describe where a credential lives ("set
   `FOO_TOKEN` in `~/.config/foo.toml`"), never copy the value.

---

## Operations

### Ingest a raw doc (spec / issue / code-review)

`raw/specs/`, `raw/issues/`, `raw/transcripts/` accumulate evidence —
specs you're working from, bug reports, code-review docs, meeting
notes. Code-review docs in particular get **edited** as the review
progresses, so you may need to re-ingest them.

**Before deciding what to ingest**, ask the plugin for a worklist:
run `kb ingest` in the admin panel (or the user will forward it via
`kb ingest --attach <slot>`). The worklist buckets every `raw/` file
as **new**, **edited**, **current**, or **orphan** — only act on
`new`/`edited`/`orphan`, skip `current`.

When ingesting a `new` or `edited` raw file:

1. Read it end-to-end.
2. Write or update a summary page at `shared/sources/<slug>.md`.
   **Always include `source_sha` + `ingested_at` in frontmatter** —
   that's how `kb ingest` knows when re-ingestion is needed:

   ```yaml
   ---
   type: source
   sources: [raw/specs/<slug>.md]
   source_sha: <sha256 of raw/specs/<slug>.md at this ingest>
   ingested_at: 2026-05-01
   ---
   ```

   On re-ingest of an edited doc, **update `source_sha` to the new
   value** and bump `ingested_at`.
3. From the source page, propagate findings into:
   - `shared/conventions/` if the doc defines or refines a convention.
   - `shared/adrs/` if it implies an architectural decision (or write
     a new ADR superseding an old one).
   - `shared/playbooks/` if it documents a procedure worth reusing.
4. Append a `log.md` line: `## [YYYY-MM-DD HH:MM] ingest | <slug>`.

### Plan code changes

Before writing code:

1. Read `index.md` → find the relevant convention(s), ADR(s),
   playbook(s).
2. Read each one end-to-end. Don't skim.
3. Read the current code (use ripgrep / file reads) to confirm
   assumptions.
4. Propose the plan to the human in 3–5 bullets:
   - what changes, where, and which conventions/ADRs apply
   - explicit callout of any rule the work would bend or break
5. Wait for approval before editing. (Exception: trivial fixes the
   human explicitly delegated.)

### Implement

While editing:

1. Honor the conventions you flagged in the plan.
2. Keep diffs minimal — no drive-by reformats, no out-of-scope refactors.
3. Run the project's lint/typecheck/test suite (or call it out if you
   can't).
4. Append a one-liner to `log.md`:
   `## [YYYY-MM-DD HH:MM] impl | <one-line summary>`
5. If the work surfaced a missing or wrong convention, propose an
   update — don't silently fix it elsewhere.

### Review a PR

When reviewing code (yours or someone else's):

1. Read `shared/playbooks/review-pr.md` first (create one if missing).
2. Cross-check against `shared/conventions/*` and `shared/adrs/*`.
3. Draft the review in `agents/<your-name>/reviews/<pr-id>.md`.
4. Surface findings as: **must-fix**, **should-fix**, **nit**,
   **question**. No vague "consider X" — be concrete.
5. Append a `log.md` entry: `## [YYYY-MM-DD HH:MM] review | <pr-id>`.

### Debug

When investigating a bug:

1. Reproduce first. If you can't, say so explicitly.
2. Hypothesize → instrument → test → narrow. Document the trail in
   `agents/<your-name>/scratch/<slug>.md`.
3. When you find the cause, write a `shared/synthesis/<slug>.md` if the
   pattern is likely to recur. Otherwise just fix and move on.
4. If the fix touches a convention or ADR, update both in the same change.

### Onboard a new convention

New conventions land in `shared/conventions/`. **The convention page
mirrors the raw rule document — preserve every clause, every example,
every exception, verbatim.** A condensed paraphrase is not a
convention; it's an opinion. See Hard Rule #4.

Frontmatter:

```yaml
---
type: convention
area: <language|framework|module>     # e.g. go, react, db-migrations
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active | superseded | proposal
sources: [<raw/path/to/source>, …]    # required when imported from raw/
source_sha: <sha256 of raw source at this ingest>   # required for re-ingest detection
ingested_at: YYYY-MM-DD
---
```

Suggested structure (keep all four; do NOT collapse into prose):

- **TL;DR** — optional, 1–3 lines. Does not replace the body.
- **What** — the rule, with every sub-clause preserved.
- **Why** — the reason behind it (incident, principle, taste, etc.).
- **How to apply** — when this kicks in, with **concrete code examples
  carried over verbatim** from the source.
- **Exceptions** — listed explicitly, with examples.

If the raw doc has 12 numbered rules, the shared convention page has
12 numbered rules. If the raw doc has 30 code examples, the shared
page has 30 code examples. Importing from raw/ is **mirroring**, not
synthesizing — a reviewer must be able to cite the shared page word-
for-word against the same wording in raw/.

Reviewers and implementers read this first.

### File an ADR

ADRs are immutable once accepted. **Preserve the full text** — Context,
Decision, Consequences, alternatives considered, and any
implementation notes from the raw source carry weight when a future
disagreement re-litigates the decision. A condensed ADR cannot
adjudicate a tie. See Hard Rule #4.

Format (`shared/adrs/NNNN-slug.md`):

```yaml
---
type: adr
number: 0042
status: proposed | accepted | superseded
date: YYYY-MM-DD
supersedes: [0017]      # optional
superseded-by: [0099]   # optional
---

# ADR 0042 — <title>

## Context
<the forces in tension>

## Decision
<what we chose>

## Consequences
<what becomes easier / harder>
```

To change a decision: write a new ADR that supersedes the old one.
Never edit an accepted ADR's substance.

---

## Conventions for Wiki Pages

All `shared/` pages have YAML frontmatter:

```yaml
---
type: convention | adr | playbook | glossary | synthesis
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active | draft | superseded
sources: [<raw/path/to/source>, …]
tags: [<tag>, …]
---
```

Other rules:

- Filenames are **kebab-case**, descriptive. `react-hooks-rules.md`,
  not `RH.md` or `react_hooks_rules.md`.
- Pages are **dense and factual**, not essays. 200–800 words is the
  sweet spot. Split anything past ~1,500.
- Cross-link with `[[wikilinks]]` for intra-KB references.
- Append to `sources:`, never silently drop.
- Mark unsourced-but-useful claims with `> [unsourced]`.

---

## index.md and log.md

- **index.md** is content-oriented: every convention, ADR, playbook
  listed with a one-line summary. Updated after every new shared/ page.
- **log.md** is chronological: append-only, one line per operation.
  Format: `## [YYYY-MM-DD HH:MM] <op> | <summary>`.
  Tail it with `grep "^## \[" log.md | tail -10`.

---

## Things To Avoid

- Editing or deleting `raw/` content.
- **Condensing convention / ADR / playbook content during ingest.**
  Detail is the value; strip it and the rule becomes advisory. If a
  raw convention has 200 lines of numbered rules with code examples,
  the shared page is **not** a 30-line summary — it carries the same
  rules with the same examples. (See Hard Rule #4.)
- Silently bypassing a convention because "it's just one line."
- Writing essays for `shared/synthesis/` is fine — but never as a
  *substitute* for a faithful convention page in `shared/conventions/`.
- Putting in-flight task state in `shared/` (it belongs in `agents/<name>/`).
- Inventing ADR numbers — always check `shared/adrs/` for the next free
  number first.
- Pasting credentials, API keys, tokens, or private data anywhere.
- Touching another agent's `agents/<name>/` directory without permission.
- Skipping `log.md` entries — they're how we audit each other.

---

## Why This Style

A coding KB only earns its keep if it makes the **next** PR better. The
structure above is biased toward decisions you'll reuse (conventions,
ADRs, playbooks) and against scratch state that decays. The KB doesn't
need to know what every commit did; `git log` already does that. It
needs to know what we'd *do differently* next time.
