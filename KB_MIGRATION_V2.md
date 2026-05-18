# KB Migration V2 — bringing a legacy KB up to date

**Tags:** `type:migration-playbook` `living-doc` `owner:johno` `area:kb` `area:meta` `status:active` `target-version:v0.2.20`

**Abstract:** Step-by-step playbook for retrofitting an auto-agents knowledge base that pre-dates `v0.2.20` to the V2 conventions introduced by `KB_RULES.md`: weekly `log.md` rotation (R1), mandatory dual-surface frontmatter on new docs under `shared/` and `agents/` (R2), and the reaffirmation of `shared/conventions/` as the binding source of truth (R3). New KBs created by `kb init` on v0.2.20+ start in the V2 shape automatically; this doc is for KBs older than v0.2.20 whose users want the same conventions retrofitted in place.

---

## What changed in V2

`auto-agents v0.2.20` introduced a new top-level file, `KB_RULES.md`, that lives at every KB's root alongside `AGENTS.md`. It codifies three universal rules that apply across all KB types (`coding` / `wiki` / `research` / `ops` / `general` / `custom`):

- **R1 — `log.md` weekly rotation.** Live `log.md` retains only the current ISO week; closed weeks roll into `log/YYYY-W<NN>.md`; partitions older than 3 months move to `archive/log/<YYYY>-W<NN>.md`. Cadence is manual / on-demand.
- **R2 — Frontmatter required on new docs under `shared/` and `agents/`.** Both YAML (the `--- ... ---` block at the top) AND inline `**Tags:**` + `**Abstract:**` lines (after the H1) are mandatory. The inline form is the source of truth for status; the YAML form is the tool-readable echo.
- **R3 — `shared/conventions/` is the binding source of truth.** Restates `AGENTS.md` Hard Rules #2 + #4 so every KB type carries the same expectation.

Each of the 5 seed AGENTS.md templates now cites `KB_RULES.md` as a load-bearing companion. `kb/init.lua` writes `KB_RULES.md` next to `AGENTS.md` on every new-KB scaffold. `log.md` is now created with a rotation-pointer header so fresh KBs start in the rotated shape from day one.

The motivation was a 2026-05-17 token-cost audit on one production KB that found `log.md` had grown to ~46k tokens — 10% of total KB weight, almost none of it usefully retrieved.

---

## Who needs this migration

- Any KB created on auto-agents `v0.2.19` or earlier.
- Check: `[ -f <kb_root>/KB_RULES.md ]` — if missing, you're on V1 and this playbook applies.

If `KB_RULES.md` is already there (you `kb init`'d on v0.2.20+ OR you ran a prior force-schema), skip to the optional audit at the end.

---

## Step 1 — install `KB_RULES.md` into the existing KB

Two paths.

### Path A — force-schema re-init (recommended for clean KBs)

If the KB doesn't have local edits to its `AGENTS.md`, the simplest move is to re-run scaffolding with `force_schema = true`:

```lua
require("auto-agents.kb").ensure_layout(nil, { force_schema = true })
```

This rewrites `AGENTS.md` from the current seed AND writes `KB_RULES.md` from `_kb-rules.md`. The seed `AGENTS.md` for v0.2.20 includes the "Read alongside this file: KB_RULES.md" pointer.

`log.md` and `index.md` are NOT overwritten if they already exist (the absent-check protects accidental data loss).

### Path B — manual placement (preserves local AGENTS.md edits)

If you've customized your KB's `AGENTS.md` and want to keep those edits:

1. Copy the rules file:
   ```bash
   cp ~/.local/share/nvim/lazy/auto-agents.nvim/kb-seeds/_kb-rules.md \
      "$AUTO_AGENTS_KB_ROOT/KB_RULES.md"
   ```
   (Adjust the source path to your plugin install location.)

2. Add the pointer paragraph to your existing `AGENTS.md`. The canonical wording is:
   ```markdown
   **Read alongside this file:** [`KB_RULES.md`](./KB_RULES.md) carries
   universal rules applying to every auto-agents KB (`log.md` weekly
   rotation, mandatory dual-surface frontmatter on new docs under
   `shared/` and `agents/`). `AGENTS.md` describes *what this KB type
   looks like*; `KB_RULES.md` describes *how every KB is operated*.
   Both are load-bearing.
   ```
   Place it right after the "This file is the canonical schema" paragraph.

---

## Step 2 — rotate `log.md` into weekly partitions

Per R1, the live `log.md` retains only the current ISO week. Closed weeks roll to `log/YYYY-W<NN>.md`, and partitions older than 12 weeks move to `archive/log/`.

The first rotation pass on a legacy KB is the heaviest because every prior week needs to be split out. Subsequent rotations only have to handle one or two newly-closed weeks.

### One-shot rotation script

```bash
cd "$AUTO_AGENTS_KB_ROOT"
mkdir -p log archive/log

python3 <<'PY'
import re, subprocess, os, collections
src = open("log.md").read()
parts = re.split(r'(?m)(?=^## \[)', src)
header_block = parts[0] if parts and not parts[0].startswith('## [') else ""
entry_blocks = [p for p in parts if p.startswith('## [')]
buckets = collections.OrderedDict()
date_re = re.compile(r'^## \[(\d{4}-\d{2}-\d{2})')
this_week = subprocess.check_output(['date', '+%G-W%V']).decode().strip()
archive_cutoff = subprocess.check_output(
    ['date', '-d', '12 weeks ago', '+%Y-%m-%d']).decode().strip()

for blk in entry_blocks:
    m = date_re.match(blk)
    if not m: continue
    d = m.group(1)
    wk = subprocess.check_output(['date','-d',d,'+%G-W%V']).decode().strip()
    buckets.setdefault(wk, []).append(blk)

for wk, blks in buckets.items():
    if wk == this_week: continue
    # Each week-file: prefer log/, but archive if older than cutoff.
    monday = subprocess.check_output(
        ['date','-d', f"{wk[:4]}-01-01 +{int(wk[6:])-1} weeks",
         '+%Y-%m-%d']).decode().strip()
    dest_dir = 'archive/log' if monday < archive_cutoff else 'log'
    path = f"{dest_dir}/{wk}.md"
    if not os.path.exists(path):
        open(path, 'w').write(f"# Log entries — {wk}\n\n")
    with open(path, 'a') as f:
        for blk in blks:
            f.write(blk.rstrip() + "\n\n")

# Rewrite log.md with the canonical header + current-week entries only.
new_header = """# auto-agents knowledge-base log

> **Current ISO week only.** Closed weeks live in `log/YYYY-W<NN>.md`;
> weeks older than 3 months live in `archive/log/YYYY-W<NN>.md`.
> See [`KB_RULES.md`](./KB_RULES.md) §R1 for the rotation procedure.

"""
current = buckets.get(this_week, [])
body = "".join(blk.rstrip() + "\n\n" for blk in current).rstrip() + "\n"
open("log.md", "w").write(new_header + body)
PY
```

After running:
- Inspect `log.md` — should be header + current-week entries only.
- Inspect `log/` — one file per closed week within the 12-week window.
- Inspect `archive/log/` — one file per closed week older than 12 weeks.

Append a one-line entry to the now-current `log.md` documenting the rotation (`## [YYYY-MM-DD HH:MM] migration | <actor> | rotated N closed weeks; M moved to archive/log/`).

### Spot-check before committing

```bash
# total entries should equal previous log.md entry count
grep -c '^## \[' log.md log/*.md archive/log/*.md 2>/dev/null
```

### Ongoing cadence

After this initial migration, rotation runs on-demand whenever `log.md` accumulates entries from a closed week. Most projects can run it monthly or quarterly. The same script above works for subsequent passes.

---

## Step 3 — audit existing docs for missing frontmatter

R2 applies to *new* docs from the cutover date forward. Existing docs are NOT required to be backfilled — but **incomplete frontmatter is a retrieval cost**, so a backfill is encouraged for high-value content.

### Audit one-liner

```bash
cd "$AUTO_AGENTS_KB_ROOT"
echo "=== docs in shared/ without YAML frontmatter ==="
find shared -name '*.md' | while read f; do
  head -1 "$f" | grep -q '^---$' || echo "$f"
done
echo
echo "=== docs in shared/ without inline **Tags:** ==="
find shared -name '*.md' | xargs grep -L '^\*\*Tags:\*\*' 2>/dev/null
echo
echo "=== docs in shared/ without inline **Abstract:** ==="
find shared -name '*.md' | xargs grep -L '^\*\*Abstract:\*\*' 2>/dev/null
echo
echo "=== same audits under agents/ ==="
find agents -name '*.md' | while read f; do
  head -1 "$f" | grep -q '^---$' || echo "  no-YAML: $f"
done
find agents -name '*.md' | xargs grep -L '^\*\*Tags:\*\*' 2>/dev/null \
  | sed 's/^/  no-Tags: /'
```

### Backfill strategy

For each flagged doc, decide:

1. **Living / actively-referenced** → backfill frontmatter now. Use the minimum shape from `KB_RULES.md` §R2.
2. **Historical / closed** → leave as-is. Don't disturb finalized work.
3. **One-shot ephemera** (old scratch notes, expired tasks) → consider moving to `archive/` per the appropriate retirement pattern; archived docs are exempt from R2.

Track the backfill in a synthesis doc (`type:todo-list`, `repo:shared`, `area:kb`) if it's a multi-session effort. Don't backfill silently — surface drift through a tracked todo so the work is auditable.

---

## Step 4 — verify and commit

```bash
cd "$AUTO_AGENTS_KB_ROOT"
git add -A
git status --short
# Should show:
#   ?? KB_RULES.md
#   ?? log/
#   ?? archive/log/        (if any week exceeded the 12-week window)
#   M  AGENTS.md           (only if Path A or manual pointer add)
#   M  log.md              (truncated to current-week + new header)
git diff --cached --stat
```

Commit with a message that names the migration:

```
kb: v2 migration — KB_RULES.md install + log.md weekly rotation
```

Push if the KB has a remote configured. `/save-kb` (if you use it) will handle this automatically and uses a changelog-style commit message.

---

## What auto-agents does for new KBs on v0.2.20+

For reference — none of the steps in this playbook apply to a freshly-created KB. The plugin handles them:

1. `kb/init.lua` `ensure_layout` writes `KB_RULES.md` from `kb-seeds/_kb-rules.md` alongside `AGENTS.md`.
2. The 5 type seeds (`coding.md`, `wiki.md`, `research.md`, `ops.md`, `general.md`) reference `KB_RULES.md` directly so the first read picks up both files.
3. `log.md` is created with the rotation-pointer header from day one (no migration ever needed; first rotation triggers naturally when the second ISO week's entries start landing).
4. Frontmatter on new docs is the agent's responsibility per `KB_RULES.md` §R2 — there's no enforcement hook yet, but a future linter could parse the seed contract and validate.

---

## Future versions

`KB_MIGRATION_V<N>.md` files document successive cutovers. Each cutover ships a new file (rather than mutating this one) so prior migrations stay readable. If you skip versions (e.g. upgrade directly from v0.2.18 to v0.3.0), read every intermediate migration doc in order before running any of the playbooks — they may have interdependencies.

The current version is V2 (introduced in `auto-agents v0.2.20`).