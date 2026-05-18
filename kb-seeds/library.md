# Knowledge Base — Document Library Contract

This knowledge base is a **document library**: a content-addressed
archive optimized for hundreds of thousands of immutable records,
convention-driven ingestion from a mutable draft zone, and a layout
that pre-anticipates a future SQL/RAG retrieval layer without
locking the design to one.

The pattern: **raw binary blobs land in a content-addressed `raw/`
tree**, **markdown wrappers describing each blob land in a
human-navigable partitioned `archive/` tree**, and the **partition
scheme + filename template + hash spec live in `RULES.md`** so the
KB's identity stays declarative — readable by humans, executable by
agents, migrate-able to SQL/RAG later without rewriting on-disk
state.

This file is the canonical schema. `CLAUDE.md` and `GEMINI.md` are
pointers to this file.

**Read alongside this file:**
- [`KB_RULES.md`](./KB_RULES.md) — universal rules applying to every
  auto-agents KB (log.md weekly rotation, mandatory dual-surface
  frontmatter on new docs under `shared/` and `agents/`).
- [`RULES.md`](./RULES.md) — **library-specific rules** for THIS KB:
  partition scheme, filename template, hash spec, versioning rules,
  retrieval surface, redaction policy. `KB_RULES.md` is the
  universal floor; `RULES.md` is the per-library ceiling.

All three are load-bearing. AGENTS.md describes *what a library KB
is*; KB_RULES.md describes *how every auto-agents KB is operated*;
RULES.md describes *how THIS library's archive is partitioned and
addressed*.

---

## Layout

```text
<kb-root>/
├── AGENTS.md                 ← this file (canonical schema)
├── CLAUDE.md / GEMINI.md     ← pointers to AGENTS.md
├── KB_RULES.md               ← universal cross-KB-type rules
├── RULES.md                  ← LIBRARY-specific partition + filename + hash spec
├── log.md / log/ / archive/log/   ← operational log (per KB_RULES.md §R1)
├── index.md                  ← thin top-level manifest of partition paths
│
├── raw/                      ← CONTENT-ADDRESSED, immutable blob store
│   └── <sha256[:2]>/<sha256[2:4]>/<sha256>.<ext>
│
├── archive/                  ← PARTITIONED, immutable durable record
│   └── <partition…>/         ← per RULES.md scheme (e.g. country/vendor/date)
│       ├── index.md          ← per-leaf-partition entries
│       └── <YYYY-MM-DD>-<type>-<subtype>-<title>.md   ← rendered from template
│
├── draft/                    ← MUTABLE input zone; dispatcher reads from here
│   ├── manifest.md           ← optional uploader metadata for the drop
│   └── <dropped folders or files>
│
├── shared/                   ← cross-archive durable knowledge
│   ├── conventions/          ← expert dispatch rules (binding per KB_RULES.md §R3)
│   │   └── <expert>/         ← e.g. accountant, warehouse, counsellor
│   │       ├── manifest.yaml ← dispatch triggers (mime / glob / heuristics)
│   │       ├── <protocol>.md ← the binding convention text
│   │       └── examples/     ← reference drafts + their finalized archives
│   ├── glossary/             ← cross-expert terminology
│   └── synthesis/            ← cross-archive analyses ("Q1 vendor trends", etc.)
│
├── incidents/                ← dispatch failure records
│   └── <YYYY-MM-DD>-<short-id>.md
│
├── redacted/                 ← controlled deletion zone
│   ├── raw/                  ← redacted blobs (restricted permissions)
│   └── stubs/                ← doc-existed-but-content-removed pointers
│
├── _templates/               ← seed-shipped templates for convention authors
│   ├── archive-entry.md      ← frontmatter shape for archive docs
│   ├── convention.md         ← shape of a convention protocol doc
│   └── convention-manifest.yaml ← shape of a convention's dispatch manifest
│
└── agents/<expert>/          ← per-agent operational scratch
    ├── tasks/                ← in-flight work notes
    ├── reviews/              ← convention author reviews
    └── scratch/              ← throwaway reasoning
```

The naming convention `shared/conventions/<expert>/` ↔ `agents/<expert>/`
means each binding rule set has a matching agent scratch space.
Workflow: the convention author drafts in `agents/<expert>/`, then
promotes the protocol into `shared/conventions/<expert>/` once it's
binding.

---

## Hard Rules (Non-Negotiable)

1. **`archive/` is IMMUTABLE.** Once a doc lands in `archive/`, it
   does not change. Edits happen by writing a **new version**
   (`prev_version: <hash>` frontmatter) or an **addendum**
   (`addendum_to: <hash>`). The original entry stays exactly as it
   was, byte-for-byte. Retrieval surfaces resolve "latest version"
   from the chain at read time.

2. **`raw/` is CONTENT-ADDRESSED and PARTITION-FREE.** Blobs live at
   `raw/<sha256[:2]>/<sha256[2:4]>/<sha256>.<ext>`. The partition
   scheme in `RULES.md` applies ONLY to `archive/`, never to `raw/`.
   This decouples physical storage from logical address — when
   `RULES.md` partition scheme evolves, only `archive/` is rewritten;
   `raw/` never moves. (Same model git uses for `.git/objects/`.)

3. **Conventions in `shared/conventions/` are binding.** Per
   KB_RULES.md §R3 and AGENTS.md Hard Rule #2 of the coding type.
   For a library, conventions describe **how a specific class of
   draft material gets ingested into the archive**. They are not
   suggestions; they are the contract the dispatcher honors.

4. **`draft/` is the only mutable working zone.** Living docs (work
   in flight, partial transcripts, agent scratch in the middle of an
   ingestion) belong here. When a doc finalizes, it MOVES from
   `draft/` to `archive/` via the convention-driven ingestion path —
   never copied, never lingering. (Compare: git index → tree.)

5. **`RULES.md` owns partition + filename + hash spec.** Agents and
   tooling read these from `RULES.md` at runtime. **Do not hardcode
   the partition scheme** in code that lives under `agents/` or
   `shared/`. Read it from `RULES.md` every time. Changes to
   `RULES.md` are versioned (see § Schema versioning).

6. **`incidents/` records dispatch failures.** When a draft drops in
   that no convention matches, the dispatcher writes a structured
   incident report instead of guessing. Each incident is the seed
   for a new convention. The convention author reviews the incident,
   drafts the missing protocol in `agents/<expert>/`, promotes it to
   `shared/conventions/<expert>/`, then re-runs ingestion on the
   incident's source files.

7. **Detail is load-bearing — DO NOT condense rules.** Conventions
   describe ingestion protocols. A condensed paraphrase is not a
   protocol; it's an opinion. Reviewers must be able to cite the
   shared convention page word-for-word against the same wording in
   the source (where applicable). Mirror raw rules verbatim, just
   like the coding KB type.

8. **The library is designed for migration to SQL/RAG.** Every
   on-disk decision (content-addressed blobs, per-partition index,
   frontmatter as structured metadata, hash as primary key) is
   chosen so a future migration into a relational or vector store is
   a one-pass operation, NOT a redesign. Resist any change that
   couples filename or filesystem layout to retrieval correctness —
   correctness must be reconstructible from `index.md` + frontmatter
   alone.

---

## Operations

### Ingest (draft → archive)

The convention-driven ingestion loop:

1. **A drop lands in `draft/`** — either a single file, or a folder
   containing multiple files (e.g. `2026-05-18-acme-invoice/`
   containing `invoice.pdf` + `inventory.csv` + `cert.jpg`). The
   folder may carry an optional `manifest.md` with uploader metadata
   (who, when, why, expected outcome).

2. **The dispatcher classifies the drop.** For each file or
   sub-folder, it walks `shared/conventions/<expert>/manifest.yaml`
   files looking for a match against `triggers` (glob, mime, content
   heuristics — see `_templates/convention-manifest.yaml`).
   - Single unambiguous match → dispatch to that expert.
   - Multiple matches → LLM tiebreak using the conventions' abstracts.
   - No match → write to `incidents/` (see §"Incident loop" below).

3. **The expert applies the convention.** Read the binding protocol
   from `shared/conventions/<expert>/<protocol>.md`, ingest the raw
   files, produce the archive entry(s):
   - Compute hash per `RULES.md` § Hash spec.
   - Move (don't copy) raw binaries from `draft/.../<file>` to
     `raw/<sha[:2]>/<sha[2:4]>/<sha>.<ext>`.
   - Render archive filename per `RULES.md` § Filename template.
   - Write the archive md wrapper at the partition path per
     `RULES.md` § Partition scheme.
   - Append the entry to that partition's `index.md`.
   - Optionally: emit business-side outputs (transactional CSV, DB
     stamps, etc. — domain-specific per the convention).

4. **Draft cleanup.** Once all archive entries are written and the
   raw blobs are in `raw/`, the source draft folder/file is removed.
   If the convention produced PARTIAL output (some files ingested,
   others failed), the un-ingested files stay in `draft/` and an
   incident is filed for the gap. Never leave stale half-processed
   drafts.

### Version (amend an archive entry)

1. Read the original entry (`<hash>.md` and its `raw/<hash>` blob).
2. Author the new version's content (md + optional new raw blob).
3. Compute the new version's hash.
4. Write the new entry under the SAME partition path with the new
   filename, frontmatter `prev_version: <original_hash>` plus
   whatever `prev_version:` chain the original already had.
5. Append to the partition's `index.md` with the chain hint.
6. **The original entry is NOT modified.** Retrieval picks the
   latest by walking `prev_version` chains.

### Addend (annotate without superseding)

1. Author the addendum md (a short doc — the addition only, not a
   rewrite of the original).
2. Frontmatter: `addendum_to: <original_hash>`. No new raw blob
   unless the addendum brings new evidence.
3. Write under the same partition with a filename like
   `<YYYY-MM-DD>-<type>-<subtype>-<title>-addendum-N.md`.
4. Append to `index.md` flagged as addendum.
5. **The original is NOT modified.** Retrieval surfaces include
   the original + all addenda inline (per `RULES.md` § Retrieval).

### Redact (controlled deletion)

1. Move the original archive md AND its raw blob to `redacted/`:
   - `archive/.../<file>.md` → `redacted/stubs/<hash>.md`
   - `raw/.../<hash>.<ext>` → `redacted/raw/<hash>.<ext>`
2. Replace the archive entry with a redaction stub (frontmatter
   only): `redacted_at:`, `redacted_reason:`, `redacted_by:`,
   `original_hash:`. Body is empty.
3. Update `index.md` to mark the entry redacted.
4. **The hash + index entry persist** — proof the doc existed —
   but content is no longer retrievable through normal channels.
   `redacted/` permissions should be restricted at the filesystem
   level by the operator.

### Retrieve

Today's primitives (FS-only, ripgrep-based):

- **By doc-id (hash)**: grep `index.md` files for the hash, follow
  to the archive path.
- **By tag**: `rg '^\*\*Tags:\*\*.*tag:value' archive/`.
- **By partition**: navigate `archive/<partition…>/` tree manually
  (Obsidian-friendly).
- **By full-text**: `rg '<search>' archive/` (matches md content;
  doesn't reach into binaries).
- **By date**: filename starts with `YYYY-MM-DD-…` so date-range
  queries are filename-glob feasible.

Future primitives (SQL/RAG-backed) — see `RULES.md` § Retrieval
surface for the migration target.

### Audit log

Every meaningful KB write (ingest, version, addend, redact,
convention author/edit, dispatch failure) appends a one-line entry
to `log.md` per `KB_RULES.md` §R1. The log rotates weekly; archive
entries' frontmatter carries the canonical timestamp for the entry
itself.

---

## Frontmatter contract (archive entries)

Every md file under `archive/` MUST carry both YAML frontmatter AND
the inline `**Tags:**` + `**Abstract:**` lines per KB_RULES.md §R2.
Archive entries have additional REQUIRED fields:

```markdown
---
id: <sha256>                    # REQUIRED. Hash per RULES.md spec.
type: archive-entry             # REQUIRED.
doc_type: <subject-type>        # REQUIRED. From RULES.md vocabulary.
doc_subtype: <subject-subtype>  # OPTIONAL.
title: <human title>            # REQUIRED.
date: YYYY-MM-DD                # REQUIRED. Subject date (not file date).
finalized_at: YYYY-MM-DD HH:MM  # REQUIRED. When this entry was archived.
finalized_by: <agent or human>  # REQUIRED.
partition:                      # REQUIRED. Echoes the partition path.
  - <partition-level-1>
  - <partition-level-2>
  - …
raw_path: raw/<sha[:2]>/<sha[2:4]>/<sha>.<ext>  # REQUIRED if wrapper; nil if pure-md
raw_mime: <mime>                # REQUIRED if raw_path set.
prev_version: <sha>             # OPTIONAL. Points at the doc this supersedes.
addendum_to: <sha>              # OPTIONAL. Mutually exclusive with prev_version.
tags: [<tag>, …]                # Per KB_RULES.md §R2.
status: <draft|finalized|superseded|redacted>
---

# <Title>

**Tags:** `type:archive-entry` `doc-type:<x>` `status:finalized` [other tags…]

**Abstract:** One-sentence summary so a reader (human or agent) can
decide to load the body or skip.

(body — wrapper md describes the raw doc OR carries the full content
if there's no underlying binary)
```

The wrapper body is whatever the convention author decided. Common
shapes:
- Pure md: full doc content (e.g. a meeting transcript, a policy
  decision)
- Thin wrapper: abstract + structured-fields summary + link to
  `raw_path`
- Hybrid: extracted-text + reference to `raw_path` for the rich
  original (e.g. OCR'd invoice text + link to the source PDF)

---

## Schema versioning

`RULES.md` carries a `schema_version:` field. When the partition
scheme, filename template, or hash spec changes, schema_version
bumps and a migration note lands in `shared/synthesis/`. Existing
archive entries are NOT rewritten on schema change — they carry
their original `partition:` array in frontmatter, so retrieval
remains correct even when the on-disk partition tree gets
rearranged.

---

## Convention author guide

To author a new convention (in response to an incident, or
proactively for a class of drops you expect):

1. Read the relevant incident(s) in `incidents/` (if any).
2. Draft the protocol in `agents/<your-name>/tasks/`. The protocol
   describes:
   - **Triggers**: what file shapes does this convention claim?
     (glob, mime, content heuristics)
   - **Inputs**: what fields does the convention extract from the
     raw file?
   - **Outputs**: what archive entry(s) does it produce? What
     business-side outputs (CSV, DB stamps, etc.)?
   - **Error modes**: when can ingestion fail mid-flight? Where
     does partial output land?
3. Iterate against the incident's source files. Validate by
   running ingestion against the draft files.
4. Promote: copy the finalized protocol to
   `shared/conventions/<expert>/<protocol>.md` AND author its
   manifest at `shared/conventions/<expert>/manifest.yaml`.
5. Append a one-line entry to `log.md` recording the convention
   ship + the incident(s) it resolves.
6. Re-run ingestion on the original incident's source files. If
   they archive cleanly, mark the incident `status:resolved`.

See `_templates/convention.md` and
`_templates/convention-manifest.yaml` for the shapes.

---

## Migration target (informational, not load-bearing today)

The on-disk shape is designed to be migrate-able to a SQL or
hybrid-RAG retrieval layer. The expected migration:

- **`raw/` → blob store** (S3, MinIO, or a SQL BLOB column).
  Already content-addressed, so the SHA-256 doubles as the
  storage key.
- **Archive md frontmatter → SQL rows** (one row per archive
  entry). The `partition:` array, `tags`, `doc_type`, `date`,
  `finalized_at`, etc. become indexed columns.
- **Archive md body → full-text index** (Postgres FTS, MeiliSearch,
  Tantivy, or RAG vector store keyed on abstract + body).
- **`index.md` files → derived materialized view** rebuilt by a
  walker over the SQL table; no longer authoritative.

The migration is purely additive — the FS layout remains valid as
a backup. Agents continue to read the FS form while the SQL/RAG
layer accelerates queries.

This migration target is **not in scope for v1 of the library
type**. The seed ships the FS form. When the SQL/RAG migration
lands, it lands as a separate ADR + sidecar tooling.

---

## Cross-references

- `KB_RULES.md` — universal rules (log rotation, dual-surface
  frontmatter, conventions-as-source-of-truth)
- `RULES.md` — this library's specific partition + filename + hash
  config
- `_templates/` — frontmatter and manifest shape templates
- `incidents/` — dispatch failure records (the "why" behind new
  conventions)
