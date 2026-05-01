# Knowledge Base — LLM-Wiki Contract

This knowledge base is an **LLM-wiki**: a persistent, compounding
artifact that the agent builds and maintains across sessions, sitting
between the human and a curated collection of source material.

The pattern: the human curates **sources**, the agent maintains the
**wiki** (summaries, entity pages, concept pages, topic hubs, syntheses).
On every ingest the agent updates 5–15 interlinked pages so that the
synthesis happens once, not on every query.

This file is the canonical schema. `CLAUDE.md` and `GEMINI.md` are
pointers to this file.

Inspired by [`raw/llm-wiki.md`](./raw/llm-wiki.md) (drop the original
pattern doc into `raw/` if you want context).

---

## Layout

```text
<kb-root>/
├── AGENTS.md             ← this file (canonical schema)
├── CLAUDE.md             ← pointer to AGENTS.md
├── GEMINI.md             ← pointer to AGENTS.md
├── log.md                ← append-only chronology
├── index.md              ← catalog of every wiki page + sources register
├── raw/                  ← IMMUTABLE source material (see below)
├── shared/               ← THE WIKI — agent-owned, durable, interlinked
│   ├── sources/          ← summary page per ingested source
│   ├── entities/         ← people, orgs, products, places, codebases
│   ├── concepts/         ← ideas, methods, recurring themes
│   ├── topics/           ← hubs that cluster entities + concepts
│   └── synthesis/        ← filed-back analyses, comparisons, query answers
└── agents/<agent-name>/  ← per-agent scratch (not durable)
```

---

## Hard Rules (Non-Negotiable)

1. **`raw/` is immutable.** Agents read from it but never edit, rename,
   or delete. To retire a source, move it to `archive/raw/` (create if
   missing) and update citations in the same change.
2. **Synthesis happens at ingest, not at query.** When the human drops a
   source into `raw/`, the agent does the work *then* — summarizing,
   cross-referencing, integrating — so future queries are cheap.
3. **Cite, don't invent.** Every claim in `shared/` must be traceable to
   a `raw/` source or an upstream wiki page. Mark unsourced-but-useful
   claims explicitly with `> [unsourced]`.
4. **Update before duplicating.** Extend an existing entity, concept, or
   topic page before creating a near-duplicate. Cross-link generously;
   trim during lint passes.
5. **Wikilinks build the graph.** Use `[[page-name]]` for intra-wiki
   links. The graph is the value — Obsidian's graph view is how you see
   what you've built.
6. **Filed answers compound.** When the human asks a substantive
   question, file the answer back as `shared/synthesis/<slug>.md` so
   the exploration doesn't die in chat history.

---

## Operations

### Ingest

When the human drops a source into `raw/`:

1. Read `index.md` first, especially the sources register, to avoid
   re-processing.
2. Read the source end-to-end. No skimming.
3. Decide whether the source is **durable** ("if the original incident
   closed, would this still teach me something?"). If not, it's
   raw-only — don't synthesize.
4. Write or update `shared/sources/<slug>.md` (one summary page per
   source). Apply the durability test before creating it.
5. Update **5–15 wiki pages** the source touches: entities, concepts,
   topics, syntheses. Append to `sources:` frontmatter — don't silently
   drop earlier sources.
6. Update `index.md` with any new pages.
7. Append to `log.md`: `## [YYYY-MM-DD HH:MM] ingest | <source title>`.

A typical ingest touches 5–15 pages. Light-touch single-source ingests
are fine; broad re-syntheses are also fine. Match the source's reach.

### Query

When the human asks a question:

1. Start at `index.md` — find candidate pages.
2. Follow `[[wikilinks]]` only as needed.
3. Answer with citations: `[[page-name]]` for wiki claims, `raw/<path>`
   for raw claims.
4. If the answer is **durable** (not just operational chatter), propose
   filing it as `shared/synthesis/<slug>.md`.
5. Append a `log.md` entry for substantive queries.

### Lint

Periodically (or on request), sweep for:

- contradictions between pages
- stale claims that newer sources superseded
- orphan pages with no inbound links
- concepts referenced but lacking pages
- index entries that drifted from page content
- oversized synthesized pages (>2,500 words → review; >3,000 → split)

**Report findings first.** Don't make large structural fixes without
confirmation unless the human explicitly asked for cleanup.

---

## Page Conventions

Every `shared/` page has YAML frontmatter:

```yaml
---
type: source | entity | concept | topic | synthesis
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [raw/path/to/source.md, …]
tags: [tag1, tag2]
aliases: [alternate-phrasing, abbreviation]   # for sub-types that need it
---
```

Other rules:

- Filenames are **kebab-case**, descriptive.
- Pages are **dense and factual** — no essays. 300–1,500 words is the
  sweet spot. Split past ~3,000.
- Use `[[wikilinks]]` for intra-wiki references.
- `sources:` lists every raw doc that contributed claims. Append on
  update; do not silently remove.
- Mark unsourced-but-useful claims with `> [unsourced]`.

### Sub-type guide

| Type        | What goes here                                                     |
|-------------|--------------------------------------------------------------------|
| `source`    | One page per ingested source — abstract, key claims, entities surfaced |
| `entity`    | A person, org, product, place, codebase — the "noun" pages         |
| `concept`   | An idea, method, recurring theme — definition + examples + lineage |
| `topic`     | A hub clustering related entities/concepts — thin, mostly links    |
| `synthesis` | Filed-back analysis, comparison, answer worth keeping              |

---

## index.md and log.md

- **index.md** is content-oriented: a catalog of every wiki page, with
  a one-line summary, plus a sources-ingested register. Updated on
  every ingest.
- **log.md** is chronological: append-only, one line per operation.
  Format: `## [YYYY-MM-DD HH:MM] <op> | <summary>`.
  Tail it with `grep "^## \[" log.md | tail -10`.

---

## Things To Avoid

- Editing, renaming, or deleting `raw/` during normal ingest.
- Synthesizing into `shared/` from sources that fail the durability
  test (those stay raw-only).
- Generating essay-length pages — split or trim instead.
- Letting `shared/` drift away from its sources — every claim should
  trace back.
- Writing the wiki yourself instead of having the agent do it. The
  human curates sources; the agent maintains the wiki.
- Treating chat as the durable artifact. The wiki is.

---

## Why This Style

The tedious part of maintaining a knowledge base isn't reading or
thinking — it's the bookkeeping (cross-references, summaries,
contradictions, consistency). Humans abandon wikis because the
maintenance burden grows faster than the value. LLMs don't get bored,
don't forget to update a cross-reference, and can touch 15 files in
one pass. The wiki stays maintained because the cost of maintenance is
near zero — and the synthesis compounds.
