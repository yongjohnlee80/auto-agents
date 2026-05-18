---
type: library-rules
schema_version: 1
created: YYYY-MM-DD                     # ← set when you customize this file
updated: YYYY-MM-DD                     # ← bump whenever rules change
status: draft                           # flip to 'active' after first ingestion succeeds
tags: [library, rules, partition-spec, filename-template, hash-spec]
---

# Library Rules — Partition, Filename, Hash, Versioning, Retrieval

**Tags:** `type:library-rules` `living-doc` `owner:shared` `area:library` `area:config` `status:draft` `schema-version:1`

**Abstract:** Per-library config that drives partition layout, filename rendering, content hashing, version chains, retrieval surface, and redaction policy. **This file is the contract** — agents and tooling read it at runtime. AGENTS.md describes *what a library KB is*; this file describes *how THIS library's archive is partitioned and addressed*. KB_RULES.md is the universal floor (rotation + frontmatter + conventions-as-source-of-truth) on top of which these rules layer.

---

## How to use this file

This is a **template**. The defaults below are reasonable starting
points, but you SHOULD customize them for your domain before the
first ingestion lands in `archive/`. Once docs are archived under a
partition scheme, changing the scheme requires a migration pass
(historic docs stay under their original partition; new docs follow
the new scheme; retrieval reads `partition:` from frontmatter, not
from on-disk path).

Edit the placeholders below (search for `← CUSTOMIZE`), flip
`status: draft` → `status: active`, and bump `schema_version` on any
later change. The schema_version is the canonical migration
breakpoint — agents inspect it to know which generation of rules
authored each archive entry.

---

## §1 — Partition scheme

The partition scheme is a **path-ordered list of partition levels**
that maps an archive entry's metadata to its physical location under
`archive/`. The list is read top-to-bottom; each level produces one
path segment.

### Declaration

```yaml
partition:
  # ← CUSTOMIZE — pick the partition order that matches your retrieval
  # patterns. Order matters: leftmost level is the broadest filter.
  - level: year             # one of: year, year-month, year-quarter, country, region, vendor, doc_type, custom:<field>
    source: date            # frontmatter field this level reads from
    format: "%Y"            # for date-derived levels, strftime format
  - level: year-quarter
    source: date
    format: "%Y-Q%q"        # custom token %q expands to 1..4 from month
  - level: vendor
    source: vendor          # frontmatter field; lowercase + kebab-cased
  # (extend as deep as your retrieval pattern needs; 2-4 levels is typical)
```

### Examples (illustrative — pick ONE for your library)

**Tax records by year + quarter:**
```yaml
partition:
  - level: year
    source: date
    format: "%Y"
  - level: year-quarter
    source: date
    format: "%Y-Q%q"
```
→ `archive/2026/2026-Q2/2026-05-18-tax-vat-q2-return.md`

**Export trade by country + vendor + date:**
```yaml
partition:
  - level: country
    source: country
  - level: vendor
    source: vendor
  - level: year-month
    source: date
    format: "%Y-%m"
```
→ `archive/de/acme-gmbh/2026-05/2026-05-18-invoice-incoming-acme-may-shipment.md`

**Document-type-led (when retrieval is dominated by doc class):**
```yaml
partition:
  - level: doc_type
    source: doc_type
  - level: year
    source: date
    format: "%Y"
```
→ `archive/invoices/2026/2026-05-18-invoice-incoming-acme.md`

### Rules

- **Every frontmatter field cited by `source:` MUST be REQUIRED in
  the archive entry's frontmatter.** If a draft doc lacks a required
  field, ingestion fails and writes an incident — never partial.
- **Date-derived levels use strftime format strings** plus custom
  tokens: `%Y` (year), `%m` (month), `%d` (day), `%q` (quarter 1-4).
- **String-derived levels are lowercased + kebab-cased** before path
  segment substitution (`Acme GmbH` → `acme-gmbh`).
- **The `partition:` array in each archive entry's frontmatter
  echoes the resolved path segments** at finalize-time, so retrieval
  remains correct even if `RULES.md` later changes (historic entries
  carry their own truth).

---

## §2 — Filename template

The archive md filename is **rendered deterministically from
frontmatter** at finalize-time. Filename is NOT a source of truth —
the frontmatter is — but it's the human-and-Obsidian-facing surface,
so it must be readable, sortable, and predictable.

### Declaration

```yaml
filename_template: "{date}-{doc_type}-{doc_subtype}-{title}.md"
# ← CUSTOMIZE if you want a different ordering or set of tokens.
# Tokens:
#   {date}         → frontmatter `date` formatted as YYYY-MM-DD
#   {doc_type}     → kebab-cased
#   {doc_subtype}  → kebab-cased; if absent, the surrounding `-` is collapsed
#   {title}        → kebab-cased; truncated to 60 chars if longer
#   {hash_short}   → first 8 chars of doc-id (rarely needed; useful for disambiguation)
#   {seq}          → 2-digit sequence for same-day-same-type collisions (01, 02, …)
```

### Recommended default

`{date}-{doc_type}-{doc_subtype}-{title}.md` — produces filenames
like `2026-05-18-invoice-incoming-acme-may-shipment.md`. Sortable by
date (filesystem alpha-sort = chronological), classifiable by
type/subtype at-a-glance, full title for human eyeball search,
Obsidian-friendly.

### Rules

- **Filename rendering is deterministic** — same frontmatter
  always produces same filename. Reproducibility is a correctness
  invariant: agents must be able to regenerate filename from
  frontmatter alone.
- **Filename is NOT load-bearing for retrieval.** Tooling looks up
  by hash via `index.md`, not by filename. Renames are allowed if
  the template changes; just rewrite per the new template + update
  per-partition `index.md` rows.
- **Truncate `{title}` at 60 chars** to keep filenames manageable;
  full title lives in frontmatter.
- **`{seq}` only appears on collision** — same-day same-type
  same-subtype same-title means two finalizations would clash. Pick
  `{seq}` automatically and document the disambiguation in
  frontmatter `seq: 02`.

---

## §3 — Hash spec (document-id)

Each archive entry has a **document-id (`id:`) that is a SHA-256
hash**. The id is the primary key for retrieval, version chains,
addenda, and the future SQL/RAG migration. Two domains:

### Wrapper docs (md describes a binary in `raw/`)

```
id = sha256( <raw_blob_bytes> )
```

The hash is the SHA-256 of the underlying raw file's bytes. Same
binary → same id (natural dedup). The wrapper md is metadata about
the blob; the blob IS the doc.

### Pure-md docs (no underlying binary)

```
id = sha256( <md_content_with_id_line_replaced_by_blank> )
```

The hash is the SHA-256 of the finalized md content with the
`id:` frontmatter line replaced by an empty `id:` (so the hash
doesn't depend on itself). All other frontmatter fields and the
body are included in the hash input.

### Rules

- **Hash computation runs ONCE at finalize-time.** Once the entry
  is in `archive/`, the id is frozen.
- **A new version is a new id.** Editing wrapper content for a
  binary that hasn't changed → still bumps the wrapper's md id if
  the doc-type is pure-md; if wrapper points at a new raw blob,
  both the raw and the wrapper get new ids.
- **Hash collision is treated as a deduplication signal.** If a
  new finalization computes a hash that already exists in any
  `index.md`, the ingestion logs a `core.mailbox.commands.command_executed`
  level INFO entry naming both entries and skips re-archiving the
  duplicate. (Both copies are kept where they are; the new copy is
  silently de-duped to the existing entry's path.)
- **Use lower-case hex SHA-256** (64 chars). Avoid base64 or
  truncated forms in `id:` — the full hash is the canonical key.

---

## §4 — Versioning + addenda

### Version chain

A new version supersedes its predecessor. Each version's frontmatter
declares `prev_version: <hash>`. Version chains form a singly-linked
list. Retrieval default: **walk to the newest entry in the chain;
older versions are accessible by direct id lookup but are not
surfaced in default queries**.

```yaml
# v1
id: a1b2c3…
finalized_at: 2026-05-01 14:00
prev_version:                  # (no value — this is the root)

# v2
id: d4e5f6…
finalized_at: 2026-05-15 09:30
prev_version: a1b2c3…
```

### Addenda

Addenda annotate without superseding. A doc can carry many addenda.
Retrieval default: **return original + ALL addenda inline, ordered
by `finalized_at` ascending**.

```yaml
# addendum on v1
id: 99aabb…
finalized_at: 2026-05-10 11:15
addendum_to: a1b2c3…
```

### Rules

- **`prev_version:` and `addendum_to:` are mutually exclusive.** An
  entry is either a version (supersedes) or an addendum
  (annotates), never both.
- **Version chains follow the latest version's partition path.** If
  partition fields change between versions (e.g. vendor renamed),
  the newer version lands at its new partition AND the older
  version is left where it was. Retrieval follows `prev_version`
  links across partitions.
- **Addenda live in the SAME partition as the doc they annotate.**

---

## §5 — Index structure

Each leaf partition has its own `index.md`. The top-level
`/index.md` is a thin manifest of partition paths + entry counts (NO
per-doc rows at the top level — top-level scales by partition count,
not by archive size).

### Per-partition `index.md` shape

```markdown
---
type: archive-partition-index
partition:
  - <level-1-value>
  - <level-2-value>
schema_version: 1
updated: YYYY-MM-DD HH:MM
---

# Index — <partition path>

**Tags:** `type:archive-partition-index` `living-doc` `partition:<path>`

**Abstract:** Per-partition manifest of archived doc-ids, version chain heads, addenda flags, and filepaths. Rebuilt incrementally by the ingestion path; can be regenerated wholesale by `:LibraryReindex <partition>` (future tooling).

## Entries

| id (sha256) | filename | doc_type | date | status | prev_version | addendum_to |
| --- | --- | --- | ---: | --- | --- | --- |
| `a1b2c3…` | `2026-05-18-invoice-incoming-acme.md` | invoice | 2026-05-18 | finalized | — | — |
| `d4e5f6…` | `2026-05-18-invoice-incoming-acme-v2.md` | invoice | 2026-05-18 | finalized | a1b2c3… | — |
| `99aabb…` | `2026-05-18-invoice-incoming-acme-addendum-01.md` | invoice | 2026-05-18 | finalized | — | a1b2c3… |
```

### Top-level `/index.md` shape

```markdown
---
type: archive-top-manifest
schema_version: 1
updated: YYYY-MM-DD HH:MM
---

# Archive — top-level manifest

**Tags:** `type:archive-top-manifest` `living-doc`

**Abstract:** Manifest of partitions in `archive/`. Each row points at a per-partition `index.md` and reports entry count + last-updated timestamp.

## Partitions

| Path | Entries | Updated |
| --- | ---: | --- |
| `archive/2026/2026-Q1/` | 142 | 2026-04-15 12:00 |
| `archive/2026/2026-Q2/` | 89  | 2026-05-18 14:30 |
```

### Rules

- **Per-partition `index.md` is APPENDED on each ingestion** (cheap
  append, no rewrite). Rewrite happens only on
  redaction/version-chain corrections.
- **Top-level manifest is RE-RENDERED** by the ingestion path after
  any per-partition `index.md` change (cheap walk over partition
  dirs; no need to scan archive bodies).
- **`index.md` is the migration entry point** for SQL/RAG. The
  column shape in the per-partition table maps directly to a SQL
  schema.

---

## §6 — Retrieval surface

### Today's primitives (FS-only)

```bash
# By doc-id (exact hash):
rg -l '<hash>' archive/**/index.md  →  follow to archive path

# By tag:
rg '^\*\*Tags:\*\*.*doc-type:invoice' archive/

# By partition (Obsidian-friendly):
ls archive/2026/2026-Q2/de/acme-gmbh/

# By date range (filename starts with YYYY-MM-DD):
find archive/ -name '2026-05-*.md'

# Full-text on wrapper bodies (NOT inside raw binaries):
rg '<search>' archive/

# Walk version chain backward (latest → oldest):
for hash in <head>; do
  rg -l "^id: $hash" archive/
  hash=$(rg -m1 '^prev_version: (.+)$' archive/**/<file>.md | …)
done
```

### Future primitives (SQL/RAG-backed)

The on-disk shape maps to:

- **`archive_entry` table** — one row per md frontmatter; primary
  key = `id` (sha256). Indexed columns: `doc_type`, `doc_subtype`,
  `date`, `status`, `prev_version`, plus partition fields.
- **`archive_tags` table** — many-to-one; one row per inline tag
  atom. Indexed `(key, value)`.
- **Blob store** — `raw/<sha>.<ext>` files migrate to S3-or-similar;
  the SHA-256 doubles as object key.
- **FTS / vector index** — md body + abstract become full-text
  index entries (Postgres FTS, MeiliSearch, Tantivy) and/or a
  vector store keyed on `id`.
- **`index.md` becomes a derived materialized view** — rebuilt by
  a walker over the SQL table; FS no longer authoritative.

The migration is **additive** — the FS form remains a valid backup.
Agents continue to read the FS form while the SQL layer accelerates
queries.

### Rules

- **Today: design queries against the FS primitives above.** Don't
  pre-optimize for the future SQL layer.
- **Future migration is not in v1 scope.** When the team decides to
  add SQL/RAG, it lands as a separate ADR + sidecar tooling. This
  RULES.md gets a `migration:` section pointing at the chosen
  backend.

---

## §7 — Redaction policy

Real archives need controlled deletion (GDPR right-to-be-forgotten,
sealed legal records, suspected-malicious docs). Immutability is the
default but it MUST have a controlled exception.

### Mechanism

1. **Move** the archive md → `redacted/stubs/<hash>.md`. Move the
   raw blob → `redacted/raw/<hash>.<ext>`.
2. **Replace** the archive entry with a redaction stub at the
   original archive path (frontmatter only, empty body):
   ```yaml
   ---
   id: <original_hash>           # preserved — the hash chain stays consistent
   type: archive-entry
   status: redacted
   redacted_at: YYYY-MM-DD HH:MM
   redacted_reason: <reason>     # e.g. "GDPR Art. 17 request 2026-05-18"
   redacted_by: <actor>
   ---
   ```
3. **Update** per-partition `index.md` row to flag `status: redacted`.
4. **Restrict** `redacted/` filesystem permissions externally (chmod
   600, owner-only, or a separate dataset under different access
   control). The library doesn't enforce this in code — the
   operator is responsible.

### Rules

- **Hash + index entry persist** as proof the doc existed.
- **Content moves, not deleted.** `redacted/` retains the bytes for
  legal-discovery scenarios even when the original archive path no
  longer surfaces them in normal retrieval.
- **Redaction is auditable** — every redaction appends a line to
  `log.md` per `KB_RULES.md` §R1 with the `redacted_by` actor and
  the reason.
- **`redacted/` is NEVER overwritten.** A redacted doc cannot be
  un-redacted by editing — it can only be UNDONE by re-ingestion
  from external source material that produces the same hash.

---

## §8 — Schema versioning + migration

When this `RULES.md` changes in a way that affects how new archives
get partitioned, named, hashed, or indexed, bump `schema_version`
and write a migration note to
`shared/synthesis/<YYYY-MM-DD>-rules-schema-v<n>-migration.md`.

### Migration rules

- **Existing archive entries are NOT rewritten** on schema_version
  bump. They carry their original `partition:` array, filename, and
  `id` — frozen at finalize-time.
- **New ingestions follow the new schema_version** rules from the
  moment `RULES.md` flips.
- **Mixed-schema reads are correct** — retrieval reads
  `partition:`/`id:`/`filename` from each entry's frontmatter, never
  from the live `RULES.md`. The live `RULES.md` only affects
  **writes**, never reads.
- **The migration note documents:**
  - What changed (partition added/removed/reordered; filename
    template; hash spec)
  - What's NOT migrated (existing entries stay as-is)
  - Whether retrieval surfaces need updating (usually no — they
    read frontmatter)
  - Whether the future SQL migration is affected

---

## Cross-references

- `AGENTS.md` — what a library KB is (canonical schema, hard rules,
  operations)
- `KB_RULES.md` — universal cross-KB-type rules (log rotation,
  dual-surface frontmatter, conventions-as-source-of-truth)
- `_templates/archive-entry.md` — frontmatter shape template
- `_templates/convention.md` — convention protocol shape
- `_templates/convention-manifest.yaml` — convention dispatch
  manifest shape
- `KB_MIGRATION_V2.md` in auto-agents source — playbook for
  retrofitting a legacy KB; library type was added in
  auto-agents v0.2.24
