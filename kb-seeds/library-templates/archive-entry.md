---
# REQUIRED — set at finalize-time per RULES.md §3 (Hash spec).
# For wrapper docs (md describes a binary in raw/): sha256 of raw blob.
# For pure-md docs (no underlying binary): sha256 of md content with
# this `id:` line replaced by an empty `id:` placeholder.
id: <sha256-hex>

# REQUIRED — fixed value for archive-zone docs.
type: archive-entry

# REQUIRED — your library's doc-type vocabulary (e.g. invoice,
# certificate, transcript, contract, …). Drives partition + filename
# templates when those reference `doc_type`.
doc_type: <type>

# OPTIONAL — subtype refinement (e.g. invoice/incoming, invoice/outgoing,
# certificate/origin, certificate/quality). Used by filename template.
doc_subtype: <subtype>

# REQUIRED — human title. Used by filename template; truncated to
# 60 chars in filename but full string lives here.
title: <human-readable title>

# REQUIRED — the SUBJECT date (the date the doc is about, not when it
# was archived). E.g. invoice issue date, contract effective date.
# YYYY-MM-DD format.
date: YYYY-MM-DD

# REQUIRED — when this entry was finalized (moved draft → archive).
# YYYY-MM-DD HH:MM (24h, local or UTC, be consistent per library).
finalized_at: YYYY-MM-DD HH:MM

# REQUIRED — who/what finalized this entry (agent name, human user,
# automated pipeline). Used by audit log.
finalized_by: <actor>

# REQUIRED — echoes the resolved partition path segments as defined
# by RULES.md §1 at finalize-time. Frozen even if RULES.md later
# changes — historic entries carry their own truth.
partition:
  - <partition-level-1>
  - <partition-level-2>

# REQUIRED for wrappers; OMIT for pure-md docs.
# Content-addressed path under raw/, derived from `id` (sha256).
# Convention: `raw/<sha[:2]>/<sha[2:4]>/<sha>.<ext>`.
raw_path: raw/<sha[:2]>/<sha[2:4]>/<sha>.<ext>

# REQUIRED when raw_path is set. MIME type of the raw blob.
raw_mime: <mime-type>

# OPTIONAL — predecessor in a version chain. Mutually exclusive
# with addendum_to.
prev_version:

# OPTIONAL — the doc this is an addendum to. Mutually exclusive
# with prev_version.
addendum_to:

# REQUIRED — flat tag array for tool-readable indexing (Obsidian,
# RAG, SQL migration). Per KB_RULES.md §R2 — keep the inline
# **Tags:** line below in sync with this array semantically.
tags: [<tag>, <tag>]

# REQUIRED — finalized | superseded | redacted.
# - finalized: normal archived state
# - superseded: an entry with status=finalized exists with this entry
#   in its prev_version chain
# - redacted: this entry has been redacted (body cleared; see RULES.md §7)
status: finalized
---

# <Title — same human string as frontmatter `title`>

**Tags:** `type:archive-entry` `doc-type:<type>` `doc-subtype:<subtype>` `status:finalized` `partition:<top-partition>` [other tags…]

**Abstract:** One-sentence summary so a reader (human or agent) can decide to load the body or skip. Skim-by-LLM happens here. Don't restate what the title says; instead describe what the doc CONCLUDES, AUTHORIZES, RECORDS, or DEMANDS.

---

<!-- BODY — whatever shape the convention author decided.

For wrapper docs (raw_path is set), the body typically carries:
- Extracted text or OCR if the raw is image/PDF (search-able)
- Structured field summary (e.g. invoice number, amount, line items)
- A `→ See raw blob: raw_path` reference

For pure-md docs (no raw_path), the body IS the doc:
- Full content (e.g. meeting transcript, policy decision, ADR-like record)
- Wikilinks `[[doc-id]]` or `[[partition-readable-name]]` for cross-references

Either way: keep the body load-bearing. The frontmatter is metadata;
this is the content. Future RAG migration will index the body for
semantic retrieval. -->
