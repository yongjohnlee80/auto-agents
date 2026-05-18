# Knowledge Base — General / Living Contract

This knowledge base is **general-purpose**: a minimal seed that lets
the agent and the human shape the structure as work proceeds. There's
no upfront opinion about what kind of project this is — coding,
research, ops, personal, hybrid. The KB grows what it needs.

The pattern: start tiny, **let the structure emerge from real work**,
promote successful patterns into conventions when they prove out.

This file is the canonical schema. `CLAUDE.md` and `GEMINI.md` are
pointers to this file.

**Read alongside this file:** [`KB_RULES.md`](./KB_RULES.md) carries
universal rules applying to every auto-agents KB (`log.md` weekly
rotation, mandatory dual-surface frontmatter on new docs under
`shared/` and `agents/`). `AGENTS.md` describes *what this KB type
looks like*; `KB_RULES.md` describes *how every KB is operated*. Both
are load-bearing.

When you're ready for opinions, you can switch to a specialized seed
(`coding`, `wiki`, `research`, `ops`) — re-run the wizard and pick a
type. Existing content stays; only the schema doc and any missing
directories change.

---

## Layout (minimal)

```text
<kb-root>/
├── AGENTS.md             ← this file (canonical schema)
├── CLAUDE.md             ← pointer to AGENTS.md
├── GEMINI.md             ← pointer to AGENTS.md
├── log.md                ← append-only chronology
├── index.md              ← catalog of pages (start empty, grow as you go)
├── raw/                  ← IMMUTABLE source material (see below)
├── shared/               ← agent-shared durable knowledge (free-form)
└── agents/<agent-name>/  ← per-agent scratch
```

That's it. No prescribed sub-categories. Folders inside `shared/` and
`raw/` get created on demand.

---

## Hard Rules (Non-Negotiable)

1. **`raw/` is immutable.** Whatever lands in `raw/` (drops, exports,
   clips, pastes) stays unedited. Synthesis goes in `shared/`.
2. **Cite, don't invent.** Claims in `shared/` should reference a
   `raw/` source or another wiki page. Mark unsourced-but-useful
   claims with `> [unsourced]`.
3. **Update before duplicating.** If a page already covers what you're
   about to write, extend it instead of forking a near-duplicate.
4. **Wikilinks build the graph.** `[[page-name]]` for intra-KB links.
5. **Promote when it proves out.** When a category is touched 5+ times
   (e.g. you keep filing things under `shared/notes/decisions/`),
   formalize it: add a small "what goes here" note in that folder, or
   propose switching to a specialized seed type.

---

## Operations

The general KB doesn't prescribe specific operations. Use whichever
fit your work; promote them into this contract as you discover them.

Common starter operations:

### Capture

When something is worth keeping (a link, a note, a decision):

1. Decide: is this **raw** evidence (URL, PDF, paste) or **synthesis**
   (your understanding)?
2. Raw → `raw/<sensible-subdir>/<slug>`. Don't edit it again.
3. Synthesis → `shared/<sensible-subdir>/<slug>.md`.
4. Append `log.md`: `## [YYYY-MM-DD HH:MM] capture | <one-liner>`.

### Ingest (when the general KB grows source pages)

If you've adopted a `shared/sources/` convention (one summary per raw
file), the plugin's `kb ingest` works for general KBs too. Run it in
the admin panel to see new/edited/current/orphan buckets. When
writing source pages, include `source_sha` + `ingested_at` in the
frontmatter so `kb ingest` can detect edits later:

```yaml
---
type: source
sources: [raw/<subdir>/<file>]
source_sha: <sha256 of raw/<subdir>/<file> at this ingest>
ingested_at: 2026-05-01
---
```

Pages aggregating from multiple sources don't track sha — only the
one-to-one source pages do.

### Recall

When asked a question:

1. Read `index.md` first.
2. Follow `[[wikilinks]]` as needed.
3. Cite: `[[page-name]]` for KB claims, `raw/<path>` for source claims.
4. If the answer is durable (would help future-you), file it as
   `shared/<sensible-subdir>/<slug>.md`.

### Reflect

Periodically:

- Tidy `index.md` — remove stale entries, add missed ones.
- Look at `shared/` — has a category accreted enough pages to deserve
  a hub page or a sub-folder?
- Look at `agents/<name>/` — anything in scratch that should be
  promoted to `shared/`? Anything that should be deleted?

---

## Page Conventions (light)

Frontmatter is **optional but encouraged** once you start filing
recurring page types. Minimum useful shape:

```yaml
---
type: <whatever-type-emerged>
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources: [raw/path/to/source]
tags: [<tag>, …]
---
```

Other rules:

- Filenames are **kebab-case**, descriptive.
- Pages are **dense and factual**, not essays. Split or trim long ones.
- Use `[[wikilinks]]` for intra-KB links.
- Append to `sources:` rather than dropping earlier sources.

---

## index.md and log.md

- **index.md**: a catalog of what's in the KB. Start empty; add
  entries as you create pages. Group by category as categories emerge.
- **log.md**: append-only chronology.
  Format: `## [YYYY-MM-DD HH:MM] <op> | <summary>`.
  Tail it with `grep "^## \[" log.md | tail -10`.

---

## Things To Avoid

- Editing or deleting `raw/` content.
- Building elaborate folder hierarchies before you have content to put
  in them. Let the structure emerge.
- Treating `agents/<name>/` content as durable — it's scratch.
- Letting `index.md` rot. If a page has no inbound links and isn't in
  the index, it's effectively lost.
- Pasting credentials, tokens, or private data anywhere.

---

## Graduating to a specialized type

When the KB has settled into a clear shape — most pages are coding
conventions, or paper summaries, or runbooks — you've outgrown the
general seed. Re-run the wizard and pick the matching specialized type
(`coding`, `wiki`, `research`, `ops`). The plugin updates this
schema doc and creates any missing standard directories. Your existing
content is left alone; you migrate (or not) at your own pace.

---

## Why This Style

Most KBs die from premature structure. Someone designs an elaborate
hierarchy, the work doesn't fit, the structure rots, the KB becomes
shelfware. The general seed inverts that: start with raw + shared +
agents and let the categories appear from real work. When a category
proves out, formalize it. When it doesn't, you don't have a folder
labeled `someday/maybe` haunting you.
