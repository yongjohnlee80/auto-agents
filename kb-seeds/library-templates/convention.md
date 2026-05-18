---
type: convention
expert: <expert-name>                       # ← e.g. accountant, warehouse, counsellor
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft                               # flip to 'active' once promoted from agents/<name>/
tags: [convention, library, ingestion, expert:<expert-name>]
sources:                                    # OPTIONAL — incident(s) this convention resolves
  - incidents/<YYYY-MM-DD>-<short-id>.md
---

# Convention — <Expert Name>: <Concise protocol title>

**Tags:** `type:convention` `living-doc` `owner:shared` `area:library` `area:ingestion` `expert:<expert-name>` `status:active`

**Abstract:** Binding protocol for how the `<expert-name>` expert ingests `<class-of-material>` from `draft/` into `archive/`. Names the triggers, the inputs, the produced archive entries, the side-effect outputs (if any), and the error modes. Binding per KB_RULES.md §R3 and AGENTS.md Hard Rule #3.

---

## What

<!-- The protocol itself — preserve EVERY clause from the originating
incident or source rule, no condensing. If the source is regulatory
or contractual text, mirror it verbatim. -->

### Triggers

This convention claims drafts where:

- **File shapes:** <glob patterns, e.g. `*-invoice-*.pdf`>
- **MIME types:** <e.g. `application/pdf`, `image/jpeg`>
- **Content heuristics:** <e.g. "PDF text contains 'INVOICE' AND 'Total:'">
- **Folder context:** <e.g. "drop folder name matches `*-shipment-*`">

(The same triggers MUST appear in this convention's `manifest.yaml`.
The manifest is the cheap pre-dispatch filter; this prose is the
human/agent-readable rationale.)

### Inputs (what gets extracted from the raw)

For each matching draft file:

1. **<Field name>** — <where it comes from in the raw; e.g. "invoice
   number from the top-right corner of page 1, regex
   `Invoice\s*#?\s*([A-Z0-9-]+)`">
2. **<Field name>** — <…>
3. **<Field name>** — <…>

(List EVERY field the convention extracts. Each maps to an archive
entry frontmatter field per the entry template.)

### Outputs (what lands in archive/ and elsewhere)

For each ingested draft:

1. **One archive entry** per `_templates/archive-entry.md` shape:
   - `doc_type: <type>` — fixed value this convention produces
   - `doc_subtype: <subtype>` — derived from <which input field>
   - `partition:` — resolved from RULES.md §1 using <which fields>
   - `title:` — derived from <which fields>
   - `tags:` — at minimum: `<list-of-mandatory-tags>`

2. **Raw blob movement:** `draft/.../<file>` →
   `raw/<sha[:2]>/<sha[2:4]>/<sha>.<ext>` (per RULES.md §3 hash spec
   for wrapper docs).

3. **Side-effect outputs (if any):**
   - `<output-file-path>` — e.g. transactional CSV with schema X
   - `<DB stamp>` — e.g. row inserted in `<table>` with `txn_id`
   - These outputs are DOMAIN-SPECIFIC and live OUTSIDE the KB
     unless the convention says otherwise.

### Error modes (what triggers an incident)

| Failure | Behavior |
| --- | --- |
| Required input field missing from raw | Write incident; leave file in draft/ |
| Raw file can't be parsed (corrupt PDF, malformed CSV) | Write incident; leave file in draft/ |
| Convention's domain logic rejects the input (e.g. invoice total doesn't reconcile with line items) | Write incident with rejection reason; leave file in draft/ |
| Hash collision with an existing archive entry | Log INFO `command_executed`; silently de-dupe (skip re-archiving the duplicate) |
| Side-effect output fails (e.g. DB write rejected) | Roll back: don't move file to archive/; write incident; leave file in draft/ |

---

## Why

<!-- The reason this convention exists — the incident that triggered
it, the regulatory or business requirement it encodes, the prior art.
Should let a future reader understand whether the rule still applies
when conditions change. -->

---

## How to apply (concrete examples)

<!-- Walk through one or two concrete drafts and show their archive
entry shape. Code examples carried over verbatim where applicable.

Example:
  Input file: draft/2026-05-18-acme/invoice.pdf
  Extracted fields:
    invoice_number: INV-2026-05-1234
    vendor: Acme GmbH
    date: 2026-05-18
    total: 12500.00 EUR
    line_items: 14
  
  Produces:
    archive/de/acme-gmbh/2026-05/2026-05-18-invoice-incoming-acme-may-shipment.md
      id: sha256(raw blob)
      doc_type: invoice
      doc_subtype: incoming
      …
    raw/<sha[:2]>/<sha[2:4]>/<sha>.pdf  (moved from draft)
    + transactional CSV written to <output-path>
-->

---

## Exceptions

<!-- Listed explicitly with examples. When does this convention
NOT claim a draft even though it superficially looks like a match?
E.g. "outgoing invoices we issue (not incoming invoices we receive)
go through `conventions/billing/` not here, even though the file
shape looks similar."  -->

---

## Cross-references

- `manifest.yaml` (next to this file) — dispatcher's cheap match filter
- `_templates/archive-entry.md` — frontmatter shape for the archive entries this convention produces
- `RULES.md` §1 — partition scheme this convention uses
- `RULES.md` §2 — filename template this convention renders
- `RULES.md` §3 — hash spec
- `incidents/` — incidents this convention was authored to resolve
