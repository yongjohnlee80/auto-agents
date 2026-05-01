# Knowledge Base — Operations / Runbook Contract

This knowledge base is an **operations KB**: runbooks, incident records,
postmortems, alert patterns, and the institutional memory that an
on-call engineer needs at 3am. The agent's job is to make the next
incident shorter than the last one.

The pattern: **every alert has a runbook**, **every incident has a
postmortem**, **every postmortem updates the runbooks**. The KB is a
flywheel — operational pain gets fed back into operational knowledge.

This file is the canonical schema. `CLAUDE.md` and `GEMINI.md` are
pointers to this file.

---

## Layout

```text
<kb-root>/
├── AGENTS.md                ← this file (canonical schema)
├── CLAUDE.md                ← pointer to AGENTS.md
├── GEMINI.md                ← pointer to AGENTS.md
├── log.md                   ← append-only chronology of incidents + ops events
├── index.md                 ← catalog of services, runbooks, alerts, incidents
├── raw/                     ← IMMUTABLE evidence (see below)
│   ├── alerts/              ← raw alert payloads, screenshots, PagerDuty exports
│   ├── chatops/             ← Slack threads, war-room transcripts
│   ├── tickets/             ← Jira/Linear/GitHub issue exports
│   └── dashboards/          ← graph snapshots, query exports (PNG/JSON)
├── shared/                  ← agent-shared durable knowledge
│   ├── services/            ← one page per service: ownership, deps, SLOs
│   ├── runbooks/            ← step-by-step response procedures
│   ├── alerts/              ← alert reference: what each alert means + first response
│   ├── incidents/           ← incident records (one per declared incident)
│   ├── postmortems/         ← published postmortems, blameless
│   └── playbooks/           ← cross-service procedures (deploy, rollback, comms)
└── agents/<agent-name>/     ← per-agent scratch
    ├── oncall/              ← active-shift notes
    └── investigation/       ← ad-hoc deep dives not yet promoted
```

---

## Hard Rules (Non-Negotiable)

1. **`raw/` is immutable.** Alert payloads, chat transcripts, ticket
   exports, dashboard snapshots are evidence. Agents do not edit them.
   New evidence goes in as new files.
2. **Every alert has a runbook.** If an alert fires and there's no
   runbook, that is a paging-eligible gap — write one (or a stub) the
   same shift.
3. **Postmortems are blameless.** Focus on systems and signals, not
   people. "X engineer deployed bad code" → "deploy gate let bad code
   reach prod because Y signal was missing."
4. **Postmortem action items are tracked.** Every postmortem ends with
   a list of remediations, each with an owner and a due date. Stale
   action items are an audit finding.
5. **Cite the evidence.** Every claim in an incident page or postmortem
   cites a specific raw artifact (alert, log line, graph snapshot,
   chat message, ticket).
6. **Update runbooks at the end of every shift.** If the runbook was
   wrong, missing, or stale, fix it before logging off.
7. **Detail is load-bearing — DO NOT condense runbooks or
   postmortems.** Runbooks are operational scripts: at 3am, the on-
   call needs the **exact** command, the **exact** flag, the
   **exact** dashboard URL — not a paraphrase. Postmortem timelines,
   action items, and root-cause chains carry weight in audits and
   future incident triage; collapsing them into a 3-bullet summary
   destroys the value.

   **Therefore, on ingest:** copy runbook and postmortem content
   **verbatim** from `raw/`. Mirror the raw structure step-for-step.
   A short TL;DR at the top is fine, but the body must preserve full
   detail. When in doubt: keep the detail.

   This applies to `shared/runbooks/`, `shared/postmortems/`,
   `shared/incidents/`, `shared/alerts/`, and `shared/playbooks/`.
   Synthesize freely for cross-incident analyses if you create a
   `shared/synthesis/` page; do NOT synthesize the operational pages
   themselves.
8. **No PII / customer data.** Describe an incident's impact in
   aggregate ("3.2% of EU traffic returned 500"). Don't paste customer
   IDs, emails, or payloads.

---

## Operations

### Ingest raw evidence (alerts / chatops / tickets / dashboards)

When an incident is over and you're writing up a postmortem, you'll
ingest evidence dropped into `raw/`. **Before deciding what to
ingest**, run `kb ingest` in the admin panel (or have the user
forward via `kb ingest --attach <slot>`). The worklist buckets every
`raw/` file as **new**, **edited** (e.g. updated chat transcripts),
**current**, or **orphan**.

When ingesting a `new` or `edited` raw artifact:

1. Read it end-to-end.
2. If the artifact warrants its own summary page (rare for ops —
   most evidence flows into postmortem/incident pages), write
   `shared/sources/<slug>.md` with frontmatter that includes
   `source_sha` + `ingested_at`:

   ```yaml
   ---
   type: source
   sources: [raw/chatops/<slug>.md]
   source_sha: <sha256 of raw/chatops/<slug>.md at this ingest>
   ingested_at: 2026-05-01
   ---
   ```

3. Propagate citations into the relevant `shared/incidents/<INC-…>.md`
   and `shared/postmortems/<…>.md` — these aggregate from many raw
   artifacts and **don't track sha**, only `shared/sources/*` do.
4. Append a `log.md` line.

### When an alert fires

1. **Acknowledge** — silence the page so you can think.
2. Open `shared/alerts/<alert-id>.md` for the alert reference.
3. Open the linked `shared/runbooks/<slug>.md` and follow it.
4. Take live notes in `agents/<name>/oncall/<YYYY-MM-DD>.md` —
   timestamps, what you tried, what you saw, what you ruled out.
5. If the issue meets the bar, **declare an incident** (open
   `shared/incidents/<slug>.md` — see below).
6. Mitigate first, root-cause later. Bias to user impact reduction.

### Declare an incident

`shared/incidents/<slug>.md`:

```yaml
---
type: incident
id: INC-2026-0042
status: active | mitigated | resolved | postmortem-pending | closed
declared: YYYY-MM-DD HH:MM
mitigated: YYYY-MM-DD HH:MM   # set when impact ends
resolved: YYYY-MM-DD HH:MM    # set when fix is in place
severity: SEV1 | SEV2 | SEV3
services: [<service-slug>, …]
related: [<incident-slug>, …]
tags: [<tag>, …]
---

# INC-2026-0042 — <one-line title>

## Impact
<User-visible impact, in aggregate. e.g. "5% of API requests returned
500 between 14:02 and 14:38 UTC. 1.1k affected users.">

## Timeline
- 14:00  baseline alert clear
- 14:02  CPU saturation alert fired on `api-prod-east`
- 14:05  oncall ack'd, opened war room
- 14:12  identified runaway query
- 14:38  hotfix deployed; alert clears
- 15:00  declared resolved

## What we tried
<In order, what mitigations were attempted and their effects.>

## Root cause
<Best current understanding. Update during postmortem.>

## Mitigation
<What stopped the bleeding.>

## Action items
- [ ] <owner> — <remediation> (due YYYY-MM-DD) — `[[postmortem-XXX#YYY]]`
```

### Write a postmortem

`shared/postmortems/<slug>.md`:

```yaml
---
type: postmortem
incident: INC-2026-0042
created: YYYY-MM-DD
updated: YYYY-MM-DD
authors: [<name>, …]
severity: SEV2
status: draft | published
---

# Postmortem — <incident title>

## Summary
<3-5 sentences: what happened, who was affected, how it ended.>

## Timeline
<Detailed timeline with citations to raw/alerts, raw/chatops, etc.>

## Impact
<Quantified. Errors, latency, users, revenue if known.>

## Root causes
<Plural. Almost always more than one. Cite evidence.>

## What went well
<Detection time, comms, mitigations that worked.>

## What went poorly
<Gaps, slow signals, missing runbooks, blind spots.>

## Where we got lucky
<Honest catalog of things that *almost* made it worse.>

## Action items
| Owner | Item | Due | Status |
|-------|------|-----|--------|
| <name> | <remediation> | YYYY-MM-DD | open |

## Lessons
<What this teaches us beyond the immediate fix.>
```

Postmortems are **blameless** — describe systems, not people. A bad
deploy isn't a bad engineer; it's a system that let a bad deploy reach
prod.

### Update runbooks

A runbook is the doc you wish you'd had at 3am. **Preserve every step
from the source verbatim** — exact commands, exact flags, exact
dashboard URLs. Detail is the entire reason this page exists; a
condensed runbook is a fiction. See Hard Rule #7.

Format `shared/runbooks/<slug>.md`:

```yaml
---
type: runbook
service: <service-slug>
alerts: [<alert-id>, …]
created: YYYY-MM-DD
updated: YYYY-MM-DD
last-validated: YYYY-MM-DD   # when did someone actually run through this?
status: active | stale | deprecated
---

# Runbook — <title>

## When this fires
<What conditions trigger this. Link the alert.>

## What to check first
<2-4 fastest checks to confirm the alert is real.>

## Common causes
1. <Cause + how to confirm + how to fix>
2. <Cause + how to confirm + how to fix>

## Escalation
<Who to ping, when, and what to hand off.>

## Related
- `[[postmortem-slug]]` — earlier incident
- `[[playbook-slug]]` — broader procedure
```

If you used the runbook this shift, update `last-validated`. If it was
wrong or stale, fix it.

### Lint

On demand:

- runbooks with `last-validated` >6 months ago → review
- alerts in `shared/alerts/` without a linked runbook → gap
- postmortem action items past due → escalate
- `shared/services/` pages with stale ownership info → ping owner
- incidents in `mitigated` status >7 days → push to postmortem

---

## index.md and log.md

- **index.md**: catalog organized by **service** then by category
  (alerts, runbooks, incidents). Quick lookup is the priority.
- **log.md**: append-only ops log.
  Format: `## [YYYY-MM-DD HH:MM] <op> | <summary>`.
  Use for shift handoff: `grep "^## \[" log.md | tail -20`.

---

## Things To Avoid

- **Condensing runbook or postmortem content during ingest.** A
  paraphrased runbook is worse than no runbook — it implies coverage
  it doesn't have. Mirror the raw source step-for-step. (See Hard
  Rule #7.)
- Naming individuals as causes — name the system gap instead.
- Pasting customer PII, emails, or payloads anywhere.
- Closing an incident without action items if anything went poorly.
- Letting `last-validated` rot — a runbook nobody has run is fiction.
- Promoting agent scratch (`agents/<name>/`) to `shared/` without
  cleaning it up.
- Editing raw alert payloads or chat transcripts to "clean them up."
- Treating `mitigated` as `resolved` — they're different states.

---

## Why This Style

Operational knowledge decays. Engineers rotate, alerts get tweaked,
services get rewritten — and the runbook that worked last quarter is
slightly wrong this quarter. The flywheel here makes that decay
visible (`last-validated` drifts, postmortem action items linger),
forces it back into action items, and gives the next person on call
fewer surprises.
