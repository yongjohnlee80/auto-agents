# Knowledge Base — Research Notebook Contract

This knowledge base is a **research notebook**: a living record of
literature reviewed, hypotheses formed, experiments run, and findings
synthesized. The agent helps you read papers, track open questions,
and turn scattered investigation into a coherent thesis.

The pattern: **paper-driven** ingest, **hypothesis-driven** organization,
**experiment-anchored** evidence, **synthesis** at the end of each arc.

This file is the canonical schema. `CLAUDE.md` and `GEMINI.md` are
pointers to this file.

---

## Layout

```text
<kb-root>/
├── AGENTS.md                ← this file (canonical schema)
├── CLAUDE.md                ← pointer to AGENTS.md
├── GEMINI.md                ← pointer to AGENTS.md
├── log.md                   ← append-only chronology
├── index.md                 ← catalog: papers, hypotheses, experiments, theses
├── raw/                     ← IMMUTABLE source material (see below)
│   ├── papers/              ← PDFs, arXiv preprints, articles
│   ├── datasets/            ← raw data files (or pointers to large blobs)
│   ├── transcripts/         ← interviews, lab meetings, talks
│   └── correspondence/      ← email threads, reviewer comments
├── shared/                  ← agent-shared durable knowledge
│   ├── papers/              ← summary page per paper (one-shot read)
│   ├── lit-review/          ← topic-area literature reviews (cross-paper)
│   ├── hypotheses/          ← stated hypotheses, status, supporting/conflicting evidence
│   ├── experiments/         ← experiment plans + results + analyses
│   ├── methods/             ← reusable methodological notes
│   └── synthesis/           ← thesis fragments, framework drafts, write-ups
└── agents/<agent-name>/     ← per-agent scratch
    ├── reading/             ← active-read notes (raw-pass margins)
    └── scratch/             ← throwaway reasoning
```

---

## Hard Rules (Non-Negotiable)

1. **`raw/` is immutable.** Papers, datasets, and correspondence stay
   in their original form. Annotations go in `shared/papers/` and
   `agents/<name>/reading/`, not by editing the raw file.
2. **Every claim is traceable.** Every assertion in `shared/` cites a
   paper, an experiment, or another wiki page. Use `[[paper-slug]]`
   for paper citations and `raw/papers/<file>` for direct refs.
3. **Hypotheses are statements, not vibes.** A hypothesis page must say
   what would falsify it (or be marked exploratory). Track supporting
   and conflicting evidence side-by-side.
4. **Experiments record the failure too.** Every experiment page
   includes negative results — null findings, abandoned designs, dead
   ends. They're the most valuable thing the KB stores.
5. **Synthesis is dated.** Every synthesis page records the date of
   the snapshot. Earlier synthesis can be wrong; preserve the trail.
6. **No invented citations.** If a claim needs a source you don't have,
   mark it `> [unsourced]` rather than fabricating a reference.

---

## Operations

### Ingest a paper

**Before deciding what to ingest**, run `kb ingest` in the admin
panel (or have the user forward you the worklist via
`kb ingest --attach <slot>`). Every `raw/papers/<file>` is bucketed
as **new**, **edited** (annotated/replaced), **current**, or
**orphan** — only act on `new`/`edited`/`orphan`.

When ingesting a `new` or `edited` paper:

1. Drop the PDF/markdown into `raw/papers/` (if not already there).
2. Read it end-to-end (or admit you skimmed and mark the page as
   `status: skimmed`).
3. Write `shared/papers/<slug>.md`. **Always include `source_sha` +
   `ingested_at` in frontmatter** — that's how `kb ingest` knows
   when re-ingestion is needed (e.g., you replaced the PDF with an
   annotated version):

   ```yaml
   ---
   type: source
   sources: [raw/papers/<file>]
   source_sha: <sha256 of raw/papers/<file> at this ingest>
   ingested_at: 2026-05-01
   created: YYYY-MM-DD
   updated: YYYY-MM-DD
   authors: [<author-1>, <author-2>]
   year: 2026
   venue: <conference|journal|arXiv>
   doi: <doi-or-arxiv-id>
   status: read | skimmed | abandoned
   tags: [<tag>, …]
   ---

   ## TL;DR
   <2-3 sentences.>

   ## Claims
   - <Claim 1, in the paper's own framing.>
   - <Claim 2.>

   ## Methods
   <How they did it, what's defensible, what's hand-wavy.>

   ## Results
   <What they showed.>

   ## Critique
   <Where the paper is weak, what threats to validity it doesn't address.>

   ## Connections
   - Supports / extends / conflicts with `[[other-paper]]`
   - Relevant to hypothesis `[[hypothesis-slug]]`
   ```

4. Update relevant `shared/lit-review/` and `shared/hypotheses/` pages.
5. Append `log.md` line: `## [YYYY-MM-DD] paper | <slug> — <one-line note>`.

### State a hypothesis

`shared/hypotheses/<slug>.md`:

```yaml
---
type: hypothesis
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: open | supported | refuted | abandoned
tags: [<tag>, …]
---

# H: <statement, in one sentence>

## What would falsify it
<Concrete experiment, observation, or evidence that would refute.>

## Why it matters
<What this would change if true.>

## Supporting evidence
- `[[paper-slug]]` — <how it supports>
- `[[experiment-slug]]` — <result>

## Conflicting evidence
- `[[paper-slug]]` — <how it conflicts>

## Open questions
- <Question 1>
```

When new evidence arrives, update the hypothesis. Mark its `status`
honestly — refuted hypotheses stay in the KB.

### Run an experiment

`shared/experiments/<slug>.md`:

```yaml
---
type: experiment
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: planned | running | done | abandoned
hypothesis: <hypothesis-slug>
tags: [<tag>, …]
---

# Experiment: <title>

## Question
<What this experiment is supposed to settle.>

## Method
<Setup, sample, controls, instruments, code refs.>

## Pre-registration
<What you committed to before looking at data, if applicable.>

## Results
<Numbers, plots, links to runs. Include negatives.>

## Interpretation
<What the result actually tells you. Distinguish from what it doesn't.>

## Limitations
<Honest catalog: confounds, sample-size issues, instrument noise.>

## Implications
- For `[[hypothesis-slug]]`: <supports|refutes|inconclusive>
- For `[[lit-review-slug]]`: <how this updates the picture>
```

### Synthesize

Periodic synthesis pages distill what we now believe across multiple
papers and experiments. Format:

```yaml
---
type: synthesis
created: YYYY-MM-DD
updated: YYYY-MM-DD
snapshot: YYYY-MM-DD     # when this synthesis was current
sources: [<page>, …]
---
```

Body: a tight argument that cites every claim. Synthesis pages can be
wrong — that's fine — but they must be **dated** so we can see how the
view evolved.

### Lint

Periodic sweep — run on demand or after big batches:

- hypotheses with no recent activity (>3 months without new evidence)
- conflicting evidence in `shared/papers/` not reflected in `hypotheses/`
- orphan papers (read but no `connections` block)
- experiments still marked `running` past a sensible date
- contradictions between synthesis pages

Report findings; don't restructure without approval.

---

## index.md and log.md

- **index.md**: catalog of papers (with status), hypotheses (with
  status), experiments (with status), and synthesis pages. Plus a
  one-line summary per entry.
- **log.md**: chronological append-only log. Format
  `## [YYYY-MM-DD] <op> | <summary>`.

---

## Things To Avoid

- Editing or deleting raw papers/datasets.
- Mixing draft writing into `shared/synthesis/` — drafts go in
  `agents/<name>/scratch/`, only filed back when done.
- Hypotheses with no falsification criterion (mark them `exploratory`
  if so).
- Experiments without a `Limitations` block.
- Citing papers you haven't actually read (use `status: skimmed` if
  honest; don't pretend).
- Quietly deleting refuted hypotheses — keep the trail.

---

## Why This Style

Research compounds when you can see, weeks later, *why* you believed
something — what evidence supported it, what argued against it, what
you'd need to learn to change your mind. A scattered set of paper
notes can't do that. A hypothesis-anchored, experiment-grounded,
dated-synthesis KB can. The agent's job is to keep the threads connected
so you don't have to.
