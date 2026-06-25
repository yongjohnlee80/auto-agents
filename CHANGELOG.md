# Changelog

All notable changes to `auto-agents.nvim` are documented here.

## [v0.2.58] — 2026-06-25 — ADR-0045: `<leader>ab` send-buffer-to-agent picker

Adds `M.send_buffer_picker(bufnr?)` — an operator-push that hands the current
editor buffer to a live agent slot with an optional instruction, mirroring
auto-finder's `todos.assign` pick-agent→instruct UX but delivering via
`send_slot` (immediate TUI push, like the `<leader>am`/`ai`/`ap` pickers).
Bound to `<leader>ab` by the autovim consumer config (v0.3.17+).

- **Payload = file-path reference for a real readable file.** When the buffer
  maps to an on-disk file (`vim.fn.filereadable(abspath) == 1`), the body sends
  just the path so the agent reads/edits the real file with its own tools; a
  modified buffer gets an explicit "on-disk lags the editor" note (we never
  auto-write).
- **Inline fallback** (size-capped at `SEND_BUFFER_MAX_INLINE_LINES = 1000`,
  with a truncation note) for unnamed buffers and named-but-not-yet-saved
  buffers — naming the intended path without implying a disk source exists.
- **Guard:** accepts only `buftype == ""`; `acwrite` (this repo's synthetic
  diff-proposal buffers), `nofile`, terminals/prompts/panels are rejected.
- **`tests/smoke.lua [27]`** — 17 assertions driving the public picker with
  stubbed `vim.ui.select`/`vim.ui.input`/`send_slot` over every payload/guard
  path (named-clean→path, named-modified→unsaved note, named-not-readable→
  inline, unnamed→inline, `nofile`→rejected, oversized→truncated, no-live-slots
  →no send, codex-safe body start, empty-instruction placeholder). Suite 326
  passed / 0 failed.

Lector-reviewed: ADR-0045 r1 `change_requested` (path-reference dead-path bug +
missing committed smoke) → r2 `approved` (0 must/should-fix).

## [v0.2.57] — 2026-06-25 — Test: ADR-0028 criterion #4 editor-floor scratch coverage

Test-only patch. Closes the last uncovered ADR-0028 acceptance criterion
(#4 — "editor-floor scratch materialization preserves editor defaults
after all panels are open"). The production fix shipped 2026-05-23
(auto-core v0.1.31 local-scope panel writes + auto-agents v0.2.29); only
this integration probe was outstanding.

- **`tests/smoke.lua [8d]`** — seeds editor appearance globals
  (`number`/`relativenumber`/`signcolumn`), materializes an editor-floor
  scratch while only panels remain, and asserts the scratch carries the
  editor defaults (proving the panel-open path no longer pollutes the
  global-local defaults a freshly-materialized window inherits), plus the
  panel stays insulated from a later global change. 6 assertions; suite
  309 passed / 0 failed.

Re-validating the aged todo (per todo-handling convention rev 5) confirmed
the scratch already inherits editor defaults with no explicit seeding —
obviating ADR-0028 §4.5's "seed editor defaults explicitly" deferred item.

## [v0.2.56] — 2026-06-25 — Fix: todos.add rejected every form of `review:`

Fixes a schema-drift bug (filed 2026-05-29) where the `todos.add` mailbox
command rejected **every** shape of the `review:` argument — so no caller
could attach a review doc via the verb at all (the workaround was
hand-editing the task's YAML afterward).

**Root cause.** The `todos.add` mailbox schema declared
`review = "string?"`, but auto-core's `todo.schema` treats `review` — like
`adr` and `blocked` — as a `string_list`. A list argument tripped the
mailbox validator (`field 'review' expected string, got table`); a string
argument tripped auto-core (`expected list of strings`). The sibling
list-type fields (`tags`, `adr`, `blocked`) were already `"any?"`;
`review` was the lone outlier.

**Fix.** `lua/auto-agents/mailbox/todos_commands.lua` — `review = "any?"`
in the `todos.add` schema, matching its list-type siblings, with a comment
recording the mirror policy: any auto-core `string_list` field must be
`"any?"` in the mailbox schema (the gate screens shape only; auto-core owns
list-enforcement). `todos.update` was unaffected (its `patch` is `"any"`).

- **`tests/smoke.lua [24k]`** — pins `review == "any?"`, the
  tags/adr/review/blocked drift-policy guard, and drives a `review` list
  through `auto-core.mailbox.commands.validate_args` (the gate that
  rejected it pre-fix). 8 assertions; verified red on the pre-fix schema,
  green after. Suite 303 passed / 0 failed.

Also catches up `M.version` (lagged at `0.2.48` since v0.2.49).

## [v0.2.55] — 2026-06-12 — ADR-0039 Batch D: KB hot-path performance

**P1 — `kb/instruct.ensure()` bail-out cache.** `ensure()` runs on every
`refresh_agent_id` resume and previously paid a full read of the target
CLAUDE.md / AGENTS.md / GEMINI.md each time, even when nothing changed (the
overwhelmingly common case). Now a per-path cache keyed by the rendered
block's sha256 + the file's size/mtime turns the unchanged case into a
single `fs_stat` — zero file reads, zero writes. External edits bust the
cache via the stat mismatch; config/roster changes bust it via the block
hash. Test hooks: `M._ensure_cache_hits`, `M._invalidate_ensure_cache()`.

**P2 — single-pass `kb sync`.** `manifest.write()` now returns the generated
manifest as a third value and `sync.sync_all()` reuses it — previously
`record()` called `manifest.generate()` a *second* time per namespace purely
to count entries, doubling the recursive glob + read + sha256 of every page
in the KB on every `:AutoAgents kb sync`. Test hook:
`manifest._generate_count` (asserted: one generate per namespace).

**Tests.** New smoke section `[26]` (+11 assertions): bail-out hit/miss
behavior, external-edit cache bust with user content + single managed block
preserved, per-namespace generate count, entry counts and wikilink
resolution flowing through `write()`'s returned manifest. Suite: **294
passed / 1 failed** (the pre-existing Phase 6 `/tmp` prune env issue,
unchanged). `instruct_diff_review_spec`: 24/0.

Public API unchanged (the third return value of `manifest.write` and the
test hooks are additive).

## [v0.2.54] — 2026-06-12 — ADR-0039 Batches A+B+C: correctness sweep, legacy diff retirement, durable writes

*(v0.2.49–v0.2.53 were released without changelog entries — see `git log
v0.2.48..v0.2.53` for those.)*

Implements the recommended batches from ADR-0039 (the auto-agents companion to
auto-core's ADR-0038 programme; full audit in the KB at
`shared/adrs/0039-auto-agents-structural-and-performance-enhancements.md`).
Public `M.*` API, mailbox verb surface, and event topics unchanged.

**Batch A — correctness sweep.**
- **C1 (ADR-0028 compliance):** all 12 bare `vim.wo` sites (11 writes + 1
  read across `init.lua` `_with_unfixed_buf` fallback, `help.lua` popup,
  `diff/ui.lua` panel) now use `nvim_set_option_value(..., {win, scope =
  "local"})` / `nvim_get_option_value`. Honest mechanism note: on nvim 0.10+
  the indexed `vim.wo[w].x = v` form is already `:setlocal`-like, so these
  were latent convention violations rather than active global-default
  pollution — the dangerous `:set`-like form is the *unindexed* `vim.wo.x`
  (verified empirically on 0.12.2; repo swept clean of both). The explicit
  API is version-proof and is the binding ADR-0028 rule.
- **C4 (silent pcall → logged):** setup-critical registration failures now
  log instead of vanish — workspace mailbox housekeeping, the mailbox
  command/todos wiring (ERROR-class: "agent command surface is DOWN"),
  todo-automation install, editor-floor install, the status observer's
  core-status mirror (new throttled `log.warn_throttled`/`error_throttled`
  wrapper passthroughs, additive), and `todos_commands.register_all` (the
  warn itself is no longer inside a swallowed pcall).
- **C3 (deferred-response leak):** dropping a still-pending diff entry
  (`queue.clear()`, or a direct `queue.remove()` of a pending entry) now
  drains its coroutine callback with `DIFF_REJECTED` first — the blocked
  CLI unblocks and the matching `_G.claude_deferred_responses` entry is
  released instead of leaking until server stop.
- **Bonus:** the vendored ws-server logger's family bridge (a local
  modification per ADR-0021 §10.2) called `table.unpack`, which is nil on
  LuaJIT — the first WARN-level emission crashed the bridge and the WS read
  loop above it (pre-existing `mcp_server_spec` crash). Now
  `table.unpack or unpack`.

**Batch B — legacy native-diff retirement (−1,493 lines).**
- `mcp/ws-server/diff.lua` (1,538 lines) was the retired pre-queue in-tab
  diff UI, unreachable since the unified queue: `openDiff` always enqueues
  (`tools/open_diff.lua` → `diff.queue` → `diff/ui.lua`). It carried a
  guaranteed nil-dereference stub (`pcall(function() return nil end)` then
  indexing the nil at line 99, five unguarded call sites) and every
  remaining deprecated `nvim_buf_set_option` call in owned code. Replaced
  with a 45-line contract-preserving stub.
- **The `close_tab` legacy-fallback contract is PRESERVED** (lector
  amendment 2): `close_diff_by_tab_name` keeps existing and answers
  `false`, so `close_tab` for an unmatched tab still returns `TAB_CLOSED`
  exactly as before. Spec assertion added (smoke 25c).
- Retired surface (for the record): `open_diff`, `open_diff_blocking`,
  `_open_native_diff`, `_setup_blocking_diff`, `_register_diff_state`,
  `_resolve_diff_as_saved/_rejected`, `_create_diff_view_from_window`,
  `_cleanup_diff_state`, `_cleanup_all_active_diffs`,
  `reload_file_buffers_manual`, `accept_current_diff`, `deny_current_diff`,
  `setup`. None had production callers (verification gate: repo-wide grep +
  full spec run).

**Batch C — durable writes (min auto-core floor → `0.1.58`).**
- `runtime_identity.write` (the agent identity sidecar), all KB scaffold
  writes (`kb/init.lua` ×9: AGENTS.md/KB_RULES.md/RULES.md/seeds/pointers/
  log/index stubs), `kb/manifest.json`, `kb/instruct.lua`'s CLAUDE.md/
  AGENTS.md instruction blocks, and `kb/obsidian.lua` now delegate to
  `auto-core.fs.atomic.write` (temp → fsync → rename; first shipped in
  auto-core v0.1.58) — readers never see a half-written file, no temp
  strays on failure. Append-only logs (`kb.log`, the automation KB audit)
  keep append semantics and gain `f:flush()`.
- **C5:** `kb/manifest.write` failures now log at the failure site
  (previously returned-but-unlogged; the admin `kb sync` output already
  rendered per-namespace errors).
- README dependency floor updated: `auto-core.nvim ^0.1.58` (lector
  amendment 3).
- `tests/instruct_diff_review_spec.lua` harness now puts the sibling
  auto-core on the rtp (it is a hard dep; the spec only passed before
  because instruct's write path didn't touch auto-core).

**Tests.** New smoke section `[25]` (+24 assertions): scope-local option
application + global-default guards, queue drain on clear/remove, retirement
stub + `TAB_CLOSED` contract, atomic identity/KB/manifest writes with
no-temp-stray checks, logger multi-part emission. Suite: **283 passed / 1
failed** — the single failure is the pre-existing Phase 6 `/tmp`
mailbox-prune env issue, identical to the v0.2.53 baseline. All 11 spec
files green except the pre-existing macOS-env failures unchanged from
baseline (`diff_peer_identity` 3× Linux-only `/proc/net/tcp`,
`mcp_server_spec` SSE handshake — the latter now fails *cleanly* instead of
crashing the logger).

## [v0.2.48] — 2026-05-27 — fix: assignee notification never delivered (invalid message kind + missing `from`)

Assigning a todo task to an agent (auto-finder todos panel `A`, `:AutoAgentsTodos
assign`, or the `todos.assign` mailbox verb) set the `assignee` field but never
woke the recipient — no inbox message arrived, in any workspace or session.

**Cause.** `auto-core.todo.assign()` correctly publishes
`core.todo.assignee:changed`, and the routing subscriber installed by
`install_assignee_routing()` fires on it. But the subscriber's
`auto-core.mailbox.send{…}` call was malformed in two ways:
`kind = "notification"` is **not** a valid kind (`message.lua` `M.KINDS` is
`{message, command, response, event}`), and no `from` was supplied (it is
required). `message.build()` therefore rejected the message with
`invalid message kind: notification`, `send` returned `nil, err`, and the
call was wrapped in `pcall(ac.mailbox.send, …)` with **the result and error
discarded** — so the failure was completely silent. The `assignee` field
still updated because `assign()` writes the file before publishing, which is
why it looked like "field set, no notification." Nothing to do with the
subscriber being installed or with needing an nvim restart.

**Fix.** Send a valid message: `kind = "message"`, `from = "nvim"` (the host
mailbox). The router wakes the recipient on inbox arrival regardless of kind,
so the assignee now gets the standard wake nudge. The send result is also
captured and a failed send is logged via `auto-agents.log.warn` instead of
being swallowed — this class of bug can no longer hide.

## [v0.2.47] — 2026-05-27 — fix: wake nudge submits on codex (drop path-token popup trigger)

`wake` to a codex-backed slot delivered its nudge into the composer but
never submitted it — confirmed live via `peek` on a Codex slot: the nudge
sat unsent under a "no matches / Press enter to insert or esc to close"
popup. `say` to the same slot worked.

**Cause.** Since v0.2.45 (follow-up #1), `wake` submits with a bare `<CR>`
(no `Esc`) so a wake never cancels in-flight codex generation. But the
default nudge text ended in the literal path token
`$AUTO_AGENTS_MAILBOX_DIR/<kind>/`. Codex reacts to that token by opening
a fuzzy path-completion popup even for bracketed-paste input, and the bare
`<CR>` is then swallowed by the popup instead of submitting the message.
`say` works because its default codex submit sequence is `Esc`+`CR` — the
`Esc` dismisses the popup first.

**Fix.** Extracted `commands.default_wake_nudge(kind, origin)` and reworded
it to be popup-inert: prose only, no `$VAR`, no `/` path separator, no `@`
mention token — so no popup opens and the bare `<CR>` submits cleanly. The
nudge now reads `ATTENTION: [auto-agents] new <kind> from <origin> — check
your <kind>.` The mailbox path was never load-bearing; agents resolve it
from `bootstrap-mailbox.md`. Generation-safety (no `Esc`) is preserved.

Relates to v0.2.28 (leading-`[` composer-queue dodge) — same class of
codex-composer hazard, different trigger.

**Tests.** New `tests/wake_nudge_spec.lua` (16 assertions) guards that the
nudge text carries no codex completion-trigger token and no leading `[`,
for both `inbox` and `responses` arrival kinds.

## [v0.2.35] — 2026-05-25 — mailbox command `peep` renamed to `peek`

Patch-level rename of the read-only TUI-buffer inspection command
introduced in v0.2.30 Phase 4. The command's description already used
the verb "Peek at the last N lines…"; the registered NAME now matches.
No behavior change — `args = { slot, lines? }` schema, return shape,
error codes, and admin REPL positional-shortcut parsing are all
byte-identical to v0.2.34. The only externally visible difference is
the verb you invoke (`run peek 2` instead of `run peep 2`; bare
mailbox messages must now use `command = "peek"`).

**Also catches up `M.version` drift.** The constant in
`lua/auto-agents/init.lua` had been stuck at `"0.2.30"` while
v0.2.31 / v0.2.32 / v0.2.33 / v0.2.34 shipped (each bumped the
tag + CHANGELOG without updating the runtime constant). This release
sets `M.version = "0.2.35"` so the runtime value matches the published
tag for the first time since v0.2.30.

**Breaking for hardcoded callers.** The previous name (`peep`) is no
longer registered — `kind="command"` messages with `command="peep"`
will fail with `{ ok = false, code = "unknown_command" }`. Consumers
that hardcoded the name need to switch; consumers that discover via
`commands_list` (the recommended pattern per the mailbox bootstrap
doc) pick up the new name automatically.

**Sites updated:**
- `lua/auto-agents/mailbox/commands.lua` — spec key `peep` → `peek`,
  handler `handle_peep` → `handle_peek`, docstring.
- `lua/auto-agents/panel/admin.lua` — `run` dispatcher special-case
  rendering, positional-shortcut parser, completion offers, comments.
- `tests/smoke.lua` — section [20] (Phase 4 registry + handler
  behavior + error cases) and section [23] (`_parse_run_args`
  positional shortcuts). All assertions kept; only the literal
  command-name string changed.

`M.version` bumps `0.2.30 → 0.2.35` (catches up the drift).

**Follow-up (separate repo).** `auto-core.nvim`'s mailbox bootstrap
template (`lua/auto-core/mailbox/templates/bootstrap.md`) documents
the command surface in an illustrative table that includes the old
`peep` row. That table is non-authoritative per its own disclaimer
(the registry is the source of truth), but updating it keeps the
generated bootstrap doc in agreement with the live registry on the
next regeneration.

## [v0.2.28] — 2026-05-22 — codex wake stall: sidestep leading-`[` composer queueing

Closes a long-standing friction with codex-backed peers (e.g.
`agent:lector`). Wake nudges arrived in the codex terminal but the
composer refused to auto-submit them — the user had to manually press
ESC + ENTER for every wake. Originally read as a deliberate codex
security feature against programmatic input injection (and recorded
that way in operational memory). Identified 2026-05-22 as something
more specific: **codex's composer treats a message starting with `[…]`
as a bracketed/queued entry and holds it for explicit submission**.
Our default wake nudge happened to start with `[auto-agents] …`, which
tripped the queue rule. Bracketed-paste wrapping doesn't suppress this
codex behavior. Claude and gemini composers don't share it, which is
why only codex peers stalled.

Two layers of fix.

### Changed

- **Default wake nudge** in `lua/auto-agents/mailbox/commands.lua::handle_wake`
  — synthesized text now reads `ATTENTION: [auto-agents] new <kind>
  from <mailbox> — check $AUTO_AGENTS_MAILBOX_DIR/<kind>/`. The leading
  `ATTENTION:` moves the `[` off position 0 while preserving the
  `[auto-agents]` visual tag for the agent. Applies to all backends —
  reads as a wake nudge for claude/gemini too.
- **Chokepoint guard** in `lua/auto-agents/init.lua::M.send_slot` —
  any `text` whose first character is `[`, bound for a slot whose
  bootstrap `kind == "codex"`, is auto-prefixed with `ATTENTION: `
  before the bracketed-paste envelope is built. Resolved via inline
  `cfg.agents.bootstrap` lookup; claude/gemini slots are untouched.
  Protects all six `send_slot` callers (wake handler, admin-panel
  `agent send`, diff UI `REQUEST CHANGE`, kb-worklist attach,
  `attach_slot`, bootstrap-refresh picker) against future leading-`[`
  payloads without per-call-site changes.
- **`MAILBOX.md`** — `wake` args section notes the `ATTENTION:` prefix
  is load-bearing for codex, with a one-line explanation of the
  composer behavior it sidesteps.

### Known gap

The T-slot playground sends (`auto-agents.term.send`, exposed via the
admin panel's `term send <slot> <text>` verb) are **not** guarded.
T-slots have no bootstrap entry → no known backend kind, and the text
comes from explicit user typing. Mutating leading-`[` input without
consent would be surprising. If a user starts codex in a T-slot and
`term send`s a `[…]` body, manual ESC + ENTER is still required.

### Upgrade

Soft within `^0.2.0`. No config or env changes. Restart codex-backed
slots to pick up the chokepoint guard; the wake-text change takes
effect immediately on the host nvim once the plugin reloads.

## [v0.2.26] — 2026-05-18 — `diff_review`: direct per-agent gate via env var + sidecar field

Closes a fragility gap in v0.2.25. The previous shape required each
agent to look itself up in the per-kind instruction file's roster
table by parsing its own `AUTO_AGENTS_MAILBOX_ID` — slow, error-
prone, and a different shape from every other auto-agents per-agent
signal (which all flow through env vars + the runtime-identity
sidecar). Agents often skipped the row-lookup entirely and defaulted
to "I'll just write to disk", silently breaking the diff-review UX.

Now the gate is direct:

    [ "$AUTO_AGENTS_DIFF_REVIEW" = "true" ] && follow_protocol

Same shape as the rest of the auto-agents env contract (mailbox /
KB / IDE integration). Stamped into the sidecar too so resumed
agents (`claude --resume`, codex transcript restore, …) recover the
live value via the same ADR 0023 path they already trust for
identity.

### Added

- **Env var injection** in `lua/auto-agents/init.lua::build_agent_env`
  — when `spec.diff_review == true`, the spawn env gets
  `AUTO_AGENTS_DIFF_REVIEW = "true"`. Omitted entirely when off
  (absent == false, matching the rest of the env contract). Layered
  on top of the existing `AUTO_AGENTS_IDE_INTEGRATION` /
  `AUTO_AGENTS_MCP_*` injection so today's claude bridge still works.
- **Sidecar field** in `lua/auto-agents/runtime_identity.lua` —
  `build_record` gains a 7th `diff_review` parameter and stamps a
  top-level `diff_review` boolean into the JSON record. `false` when
  unset / nil so the field is always present (downstream JSON
  consumers don't have to special-case absence).
- **Refresh-path threading** in
  `lua/auto-agents/mailbox/commands.lua::handle_refresh_agent_id` —
  the matched spec is resolved up front and its `diff_review` flag
  passed through to `build_record`. The response value carries
  `diff_review` so a resumed agent can re-acquire it from the
  refresh response without re-reading the sidecar.

### Changed

- **Preamble in `lua/auto-agents/kb/instruct.lua`** — the
  "Interactive diff review" section now opens with the env var
  check (`[ "$AUTO_AGENTS_DIFF_REVIEW" = "true" ]`) and the sidecar
  fallback for resumed sessions. The old "look up your row in the
  roster" wording is gone. The roster `diff_review` column stays as
  a project-wide visual summary.
- **Shipped doc `instructions/diff-queue-workflow.md`** — same
  reframe: authoritative gate is the env var (with sidecar fallback
  for resumed sessions); roster is purely informational.
- **`docs/help/agent.md`** — `diff_review` section gains a per-agent
  gate table documenting the env var + sidecar channels.

### Tests

- **`tests/instruct_diff_review_spec.lua`** — extended:
  - Existing [1]/[2]/[3] sections updated with three new assertions
    each: preamble references `$AUTO_AGENTS_DIFF_REVIEW`, references
    `$AUTO_AGENTS_RUNTIME_IDENTITY_PATH` for resume, and no longer
    asks the agent to "look up your own row".
  - New [4] section: `runtime_identity.build_record` round-trip.
    Verifies `diff_review=true/false/nil` produces the right field
    value, and that the field survives JSON encode/decode through
    `ri.write` + `ri.read`.
- All 24 assertions green. Pre-existing diff specs (queue, verdict
  routing, mailbox sender, peer identity) still green — 78 total.

### Upgrade

Soft within `^0.2.0`. The new env var + sidecar field are additive;
existing claude flow is unchanged. To validate end-to-end:

1. Restart any non-claude slot with `diff_review = true`.
2. Inside that slot's terminal: `echo $AUTO_AGENTS_DIFF_REVIEW`
   should print `true`. `cat $AUTO_AGENTS_RUNTIME_IDENTITY_PATH |
   jq .diff_review` should also print `true`.
3. Ask the agent to propose a file edit. The reframed instruction
   section in its `AGENTS.md` / `GEMINI.md` / etc. gates explicitly
   on the env var, so the agent no longer has to parse the roster
   to know the protocol applies.

## [v0.2.25] — 2026-05-18 — non-claude `diff_review`: mailbox `diff_queue` protocol injection

Extends the per-agent `diff_review` flag to non-claude kinds. Until
now, `diff_review = true` only had teeth for claude — it provisioned
a per-slot ws-mcp bridge so the native `openDiff` tool routed into
the unified diff queue. For codex / gemini / junie / aider / goose /
opencode / generic the flag was a no-op: those agents had no
protocol awareness, so they'd write proposed edits straight to disk.

This patch closes that gap by inlining a canonical, plugin-shipped
protocol document into each non-claude agent's per-kind instruction
file at spawn (and on every `refresh_agent_id` call). The agent
reads the protocol once on startup and then, for every proposed
edit, follows the Draft → Verify → Enqueue → Wait → Apply lifecycle
— landing the diff in the same Unified Diff Queue
(`:AutoAgentsDiffQueue`) that claude reaches via ws-mcp.

### Added

- **`instructions/diff-queue-workflow.md`** — canonical, plugin-owned
  copy of the mailbox `diff_queue` protocol. Headings start at `####`
  so the content inlines cleanly beneath the `### Interactive diff
  review` section header rendered by `lua/auto-agents/kb/instruct.lua`.
  Includes the "Safety-First" lifecycle, common pitfalls (writing
  before enqueue, relative paths, missing `new_file_contents`), and
  an example payload. Opens with an explicit "claude agents: skip
  this section" preamble so the doc is robust even if it ever
  surfaces to a claude reader.
- **`lua/auto-agents/kb/instruct.lua`** — new `plugin_root()` and
  `read_diff_queue_protocol()` helpers. When at least one peer in
  the same-kind roster has `diff_review = true`, the roster table
  gains a `diff_review` column (`✓` / `–`) so every agent can look
  up its own setting. When the kind is non-claude AND any peer is
  opted-in, an `### Interactive diff review` section is appended to
  the auto-agents block, with framing that explicitly links the
  protocol to the `diff_review = true` flag, then inlines the shipped
  markdown verbatim.
- **`lua/auto-agents/mailbox/commands.lua::handle_refresh_agent_id`**
  — after a successful sidecar identity write, re-renders the
  resumed agent's per-kind instruction file via `kb.instruct.ensure`
  so the protocol section reflects current roster / flag state.
  Soft-fails: identity reconciliation itself already succeeded,
  this is a best-effort refresh.
- **`lua/auto-agents/init.lua::_build_reassert_body`** — appends a
  line to the ADR 0024 §2.2 picker prompt reminding the resumed
  agent to re-read the *Interactive diff review* section when its
  kind is non-claude and its row shows `diff_review = ✓`.

### Changed

- **`lua/auto-agents/panel/wizard_specs.lua`** — `diff_review`
  wizard comment updated to document the kind-dispatched dispatch
  (claude → ws-mcp bridge; non-claude → mailbox protocol injection).
  The default-true set stays conservative (claude + codex only) —
  opt in explicitly for other kinds via the wizard.
- **`docs/help/agent.md`** — `diff_review` section rewritten with
  both dispatch paths, explicit note that only Claude Code is proven
  to honor ws-mcp `openDiff` end-to-end today, and a pointer to
  `instructions/diff-queue-workflow.md` for the shipped protocol.

### Tests

- **`tests/instruct_diff_review_spec.lua`** — covers the three new
  injection states: (a) `kind = codex` with a `diff_review = true`
  peer → section + roster column rendered; (b) `kind = claude` with
  a `diff_review = true` peer → roster column rendered but section
  omitted (claude routes via ws-mcp); (c) all peers
  `diff_review = false` → neither column nor section rendered.

### Upgrade

Soft. Within `^0.2.0`, autovim picks this up automatically. To put
it through its paces:

1. Pick a non-claude slot in `:AutoAgentsAdmin` and set
   `diff_review = true` on it (or run `agent edit <slot>` via the
   wizard).
2. Restart that slot. On spawn, the agent's per-kind instruction
   file (e.g. `AGENTS.md` for codex) will pick up the new
   `### Interactive diff review` section.
3. Ask the agent to propose a file change. It should send a
   `diff_queue` command to `nvim` instead of writing the file
   directly, then idle pending the `accepted` verdict.

## [v0.2.24] — 2026-05-18 — new KB type: `library` (content-addressed document archive)

Adds a sixth built-in KB type alongside `coding` / `wiki` / `research`
/ `ops` / `general`. Expected to be the second-most-used type after
`coding` per Johno's framing.

The `library` type is a content-addressed document archive optimized
for hundreds of thousands of immutable records, convention-driven
ingestion from a mutable draft zone, and a layout that pre-anticipates
a future SQL/RAG retrieval layer without locking the design to one.

### Added

- **`kb-seeds/library.md`** — canonical schema (AGENTS.md) for the
  library type. Describes the three-zone lifecycle (raw blobs / draft
  / archive), eight hard rules including archive immutability and
  content-addressed `raw/`, operations (ingest / version / addend /
  redact / retrieve / audit), the archive-entry frontmatter contract,
  schema versioning, the convention author guide, and the planned
  SQL/RAG migration target.
- **`kb-seeds/_library-rules.md`** — per-library `RULES.md` template
  installed at `<kb_root>/RULES.md` on init. Declares:
  - §1 Partition scheme (with 3 example schemes — tax by quarter,
    export trade by country/vendor/date, doc-type-led)
  - §2 Filename template (default `{date}-{doc_type}-{doc_subtype}-{title}.md`,
    human-readable, Obsidian-friendly)
  - §3 Hash spec (SHA-256 of raw blob for wrappers; SHA-256 of md
    sans `id:` for pure-md)
  - §4 Versioning + addenda rules
  - §5 Index structure (per-partition `index.md` + top-level thin
    manifest)
  - §6 Retrieval surface (FS-only primitives today; SQL/RAG migration
    target)
  - §7 Redaction policy (move-not-delete; hash + index entry persist
    as audit trail)
  - §8 Schema versioning + migration rules
- **`kb-seeds/library-templates/`** — three templates shipped at
  `<kb_root>/_templates/` on init:
  - `archive-entry.md` — frontmatter shape for archive docs
  - `convention.md` — binding protocol doc shape
  - `convention-manifest.yaml` — dispatch manifest shape (with
    glob/mime/content-match/folder-context triggers + LLM-tiebreak
    abstract + agent authorization + side-effect declarations)
- **`lua/auto-agents/kb/types.lua`** — `library` registered in
  `M.BUILTIN` and `LAYOUTS`. Layout: `shared/{conventions,glossary,synthesis}/`
  + `extra_dirs = {archive, draft, incidents, redacted, _templates}`.
  `raw/` is created as a flat dir (no subdirs — content-addressed at
  runtime).
- **`lua/auto-agents/kb/init.lua`** — generalized per-type rules
  + templates copy. When the seed bundle ships `_<type>-rules.md`,
  it's copied to `<kb_root>/RULES.md`. When it ships
  `<type>-templates/`, every file is copied to `<kb_root>/_templates/`.
  Generic mechanism with no per-type branching; library is the
  first consumer.
- **Smoke section [19]** — 39 assertions covering:
  - BUILTIN includes library
  - Layout contains all expected subdirs (archive/draft/incidents/
    redacted/_templates + shared/{conventions,glossary,synthesis})
  - All 6 seed files ship on disk (library.md, _library-rules.md,
    library-templates/{archive-entry.md, convention.md,
    convention-manifest.yaml})
  - `ensure_layout` scaffolds the full tree end-to-end
  - AGENTS.md, KB_RULES.md, RULES.md all written at the root
  - AGENTS.md content references both companion docs
  - RULES.md content declares schema_version + partition + filename
    + hash spec
  - `_templates/` is populated from the per-type bundle
  - `log.md` carries the rotation-pointer header (KB_RULES.md §R1
    applies)
  - `ensure_layout` is idempotent (re-run preserves user edits)

### Rationale

`auto-agents` had no story for archival / records-style workflows.
The library type fills that gap as a domain that's not coding, not
wiki, not research, and not ops — it's about MASS PERSISTENT
STORAGE with efficient retrieval. The motivating user story is an
export trade automation: drop invoice/inventory/certificate folders
into `draft/`; expert agents (accountant, warehouse-manager,
counsellor) dispatch via convention manifest; produce archive
entries with structured frontmatter + transactional outputs.

Design decisions that distinguish library from prior types:

1. **Content-addressed `raw/`** — like git's `.git/objects/`,
   partition scheme NEVER touches raw blobs. Decouples physical
   storage from logical address.
2. **Partition scheme is declarative** (RULES.md §1) — agents read
   it at runtime; changes don't rewrite history.
3. **Per-partition `index.md`** — scales past the single-file limit
   that R1 (`log.md` rotation) exists to address.
4. **Manifest-based convention dispatch** — cheap pre-filter via
   YAML triggers; LLM tiebreak for ambiguity; incidents drive new
   convention authoring.
5. **Migration-ready by design** — every on-disk decision (content-
   addressing, frontmatter as structured metadata, hash as primary
   key) makes the FS form a clean migration source for SQL/RAG.

### Smoke

179 passed / 0 failed across 2 consecutive isolated runs (39 new
assertions in section [19]). Section [9] intermittent
(`shared/synthesis/auto-agents-smoke-intermittent-section-9-max-slot.md`
in the KB) continues to surface under chained IO load.

### Consumer impact

None for existing KBs — additive. Users can opt into the new type
via `:AutoAgentsProject` wizard or by setting `[kb] type = "library"`
in their project TOML. Autovim caret `^0.2.0` covers v0.2.24; no
autovim retag needed.

## [v0.2.23] — 2026-05-18 — `agent add` KB-type default + smoke section [18]

Two follow-ons to v0.2.22's KB-type conflict ACK.

### Added

- **Default-value injection** on the wizard's `_kb_type` step. When
  `cfg.kb.type` is already set, the step's default returns the
  current value — so a no-op `<CR>` keeps the project type
  unchanged. Falls back to `"coding"` only on first-ever adds. The
  combined effect with v0.2.22's ACK is that the happy path
  (re-adding agents into an existing project) becomes one `<CR>`,
  and the conflict path (genuinely picking a different type) still
  fires the SHOUTY ACK.
- **Smoke section [18]** in `tests/smoke.lua` covering both the
  v0.2.22 ACK and the v0.2.23 default injection — 20 assertions:
  - Spec includes `_kb_type` and `_kb_type_conflict_ack` steps
  - `_kb_type` default returns current `cfg.kb.type` when set
  - `_kb_type` default falls back to `"coding"` when cfg.kb absent
  - ACK skip rules — match (skip), `"none"` (skip), `private` /
    `isolated` scope (skip), no-current-type (skip), and the
    conflict case (DO NOT skip)
  - ACK validate accepts only the exact `YES_CHANGE_PROJECT_TYPE`
    phrase — `yes`, `y`, partial `YES`, and empty all rejected
  - ACK `pre_emit` banner names current type, picked type, the
    word WARNING, and the exact confirmation phrase

### Changed

- `panel/wizard_specs.lua` — `_kb_type` `default` now `function()`
  instead of static `"coding"`. Reads from `cfg.kb.type` at wizard
  start.
- `panel/wizard_specs.lua` — ACK `pre_emit` banner now explicitly
  shows the required confirmation phrase
  (`TO CONFIRM, TYPE EXACTLY: YES_CHANGE_PROJECT_TYPE`) above the
  prompt line. Avoids the "wait, what was the phrase?" failure
  mode where users see the WARNING block but miss the prompt below
  it.

### Smoke

140 passed / 0 failed across 2 consecutive isolated runs. The
section [9] intermittent (tracked in the KB) continues to surface
under chained IO.

Additive — no removals, no signature changes. Autovim caret
`^0.2.0` covers v0.2.23.

## [v0.2.22] — 2026-05-18 — `agent add` warns on KB-type conflict (shared scope only)

Defensive prompt during the admin panel's `agent add` wizard: if the
picked `_kb_type` differs from the project's existing `[kb].type` AND
the new agent's `kb_scope = "shared"`, the wizard now stops and demands
the user type `YES_CHANGE_PROJECT_TYPE` (uppercase, full phrase) to
proceed. Closes the silent-misconfig hole where the wizard's per-agent
KB-type prompt LOOKED like a per-agent choice but actually overwrote
the project-scoped `[kb].type`, leaving:

- TOML `[kb].type` set to the last-added agent's pick
- `AGENTS.md` still describing the first-added agent's contract
- Both types' layout dirs coexisting under `shared/` (additive)
- Mutability paradigms colliding in `shared/synthesis/` (esp. severe
  for `coding+wiki` / `ops+wiki` — living-doc vs zettel-card models
  talk past each other)

### Added

- `lua/auto-agents/panel/wizard.lua` — new optional `step.pre_emit`
  hook: `pre_emit(values) -> string[]` runs before the step's
  single-line prompt and lets the runner emit multi-line context
  (banners, warnings, summaries). Used by the new conflict ACK step
  to render the SHOUTY warning before asking for confirmation.
  Backward-compatible — existing specs without `pre_emit` are
  unaffected.
- `lua/auto-agents/panel/wizard.lua` — `step.prompt` now accepts a
  `fun(values) -> string` in addition to a plain string. Lets ACK
  steps embed already-collected wizard values (the picked type, the
  current type, the kb_scope) directly into the question line.
- `lua/auto-agents/panel/wizard_specs.lua` `_kb_type_conflict_ack`
  step in the `agent add` flow. `skip` rules:
  - skipped if no existing `cfg.kb.type` (first-ever add)
  - skipped if `_kb_type == "none"` (user opted out of KB init)
  - skipped if `_kb_type == current` (no change)
  - skipped if `kb_scope != "shared"` (per-agent dir; no immediate
    shared-tree damage — the TOML still flips but it only affects
    future shared agents)
  - otherwise the ACK runs and demands the exact phrase
    `YES_CHANGE_PROJECT_TYPE` (uppercase). `y` / `yes` / `<CR>` are
    all rejected by design — muscle-memory shouldn't bypass.

### Rationale

The wizard's `_kb_type` field looks like a per-agent property but
its side effect is project-scoped (`cfg.kb.type = values._kb_type`).
There's no per-agent KB type in the TOML schema — `[kb].type` lives
at the project root and drives the layout, AGENTS.md seed, and (now)
the KB_RULES.md companion. For `kb_scope = "shared"` agents, picking
a different type silently creates a hybrid KB whose mutability model
varies by which agent wrote which doc — the worst case being the
coding/ops "living docs that iterate" pattern colliding with wiki's
"finalized zettel cards" pattern in the same `shared/synthesis/` dir.

For `kb_scope = "private"` and `"isolated"` agents, the immediate
damage is much smaller — those agents write to `kb/agents/<name>/`,
which the type-driven layout doesn't touch. The TOML's `[kb].type`
still gets overwritten (affecting future shared-scope agents) but
the ACK only fires for shared scope to avoid prompt fatigue.

### Smoke

119 passed, 0 failed across 5 consecutive isolated runs. The
`tests/auto-agents-smoke-intermittent-section-9-max-slot.md` flake
in `shared/synthesis/` of the auto-agents KB continues to surface
under chained IO load (~1 in 5 in this session); production behavior
of the affected section ([9] `flat slot model`) verified unchanged.

### Consumer impact

None — additive. New wizard step is `skip`-gated by the conflict
predicate; in the common case (first agent, or matching type, or
non-shared scope) the wizard runs unchanged. Autovim caret
`^0.2.0` covers v0.2.22; no autovim retag needed.

## [v0.2.21] — 2026-05-18 — KB_RULES.md + Phase 2 logging sweep + smoke fixture fix

Three bundled patches plus the M.version sync-forward (v0.2.20's
release commit shipped without bumping `M.version` from `0.2.19`; this
patch resolves the drift). See `KB_MIGRATION_V2.md` at the plugin root
for the playbook to retrofit a legacy KB.

### Added

- New top-level `KB_RULES.md` in every freshly-initialized KB —
  universal rules that apply across all KB types
  (`coding`/`wiki`/`research`/`ops`/`general`/`custom`). Codifies:
  - **R1 — `log.md` weekly rotation.** Live `log.md` retains the
    current ISO week only; closed weeks roll into
    `log/YYYY-W<NN>.md`; partitions older than 3 months move to
    `archive/log/`. Cadence is manual / on-demand.
  - **R2 — Mandatory dual-surface frontmatter** on new docs under
    `shared/` and `agents/`. Both YAML (`--- ... ---` block at the
    top) AND inline `**Tags:**` + `**Abstract:**` lines (after the
    H1) are required. Inline is the source of truth for state
    (status flips happen there first); YAML is the tool-readable echo.
  - **R3 — `shared/conventions/` is the binding source of truth.**
    Restates AGENTS.md Hard Rules #2 + #4 so seed updates carry the
    same expectation across all KB types.
- New `kb-seeds/_kb-rules.md` — the shippable universal rules
  template. Copied to `<kb_root>/KB_RULES.md` by `kb/init.lua`
  alongside the per-type AGENTS.md seed.
- New `KB_MIGRATION_V2.md` at the plugin root — playbook for
  retrofitting a legacy KB to V2 conventions. Covers
  `KB_RULES.md` install (force-schema re-init OR manual placement),
  first-pass `log.md` rotation script, and the audit-and-backfill
  approach to existing frontmatter gaps.

### Changed

- All 5 type seeds (`kb-seeds/{coding,wiki,research,ops,general}.md`)
  now cite `KB_RULES.md` as a load-bearing companion to AGENTS.md.
- `lua/auto-agents/kb/init.lua` `ensure_layout` writes `KB_RULES.md`
  from the universal seed (parallel to the per-type AGENTS.md copy
  flow; same absent-or-forced semantics).
- `kb/init.lua` initial `log.md` template now includes the
  rotation-pointer header per R1, so fresh KBs start in the rotated
  shape from day one (no migration needed when log grows past the
  first ISO week).
- `lua/auto-agents/init.lua` `_bootstrap_refresh_picker` — the three
  remaining `vim.notify` call sites (lines 1345/1355/1361 — the
  `<leader>am` / `<leader>ai` error paths) now route through
  `auto-agents.log.notify` per ADR 0021 §9 (no-direct-notify rule).
  Levels preserved (WARN for no-targets, ERROR for prompt-build /
  dispatch failures); log lines render
  `[AutoCore] [auto-agents.send_slot] [<LEVEL>] ...`.
  `grep -nE 'vim\.notify\(' lua/auto-agents/init.lua` returns 0.
- `M.version` bumped `0.2.19` → `0.2.21` (resolves the drift where
  v0.2.20's tagged commit left M.version unbumped).

### Fixed

- `tests/smoke.lua` section `[14] send_slot — opts.submit follows
  body with deferred CR` — two assertions had been silently failing
  since commit `e16ada9` added bracketed-paste wrap to `M.send_slot`
  (production wrap shipped; fixture left asserting unwrapped body).
  Assertions now expect `"\27[200~<body>\27[201~"`. Suite goes from
  117/2 to **119/0**.

### Rationale

R1 motivated by the 2026-05-17 KB token-cost audit on the production
auto-agents KB — `log.md` had grown to ~46k tokens (10% of the total
KB by token weight), almost none of it usefully retrieved. R2
codifies frontmatter practice already at 100% adoption in `shared/`
across that KB, extending the requirement to `agents/` where coverage
was patchy (8/22 files).

## [v0.2.20] — 2026-05-18 — grant KB root in spawn-time `--add-dir`

Patch the spawn-time permission injection so the per-agent
`--add-dir` list includes `AUTO_AGENTS_KB_ROOT` in addition to the
per-scope `KB_READ`/`KB_WRITE` sub-paths. Pre-patch only the
subdirs were granted (`shared/` and `agents/` for the default
`shared` scope), so every read of a root-level file —
`AGENTS.md` (the canonical schema agents are explicitly told to
read first), `log.md` (the audit trail every KB write appends
to), `index.md`, or anything in `raw/` / `archive/` /
`_templates/` — triggered a permission prompt and broke routine
agent operation. Reported against `agent:juliet`, who couldn't
perform basic reads without prompting.

### Changed

- `lua/auto-agents/init.lua` spawn pipeline (`spawn_agent_argv` /
  the `dirs` assembly around the `permissions.argv_for_kind` call):
  prepend `env.AUTO_AGENTS_KB_ROOT` to the `dirs` list before the
  existing `KB_READ` / `KB_WRITE` enumeration. Added an ancestor-
  aware `covered()` helper so sub-paths already contained by an
  added directory are not re-listed — argv stays clean across all
  three scopes (`shared`, `private`, `isolated`).

### Rationale

The per-scope KB contract was always best-effort agent self-
restraint, not OS-level sandboxing — `kb/scope.lua:4-5` says so
explicitly. The env vars `AUTO_AGENTS_KB_READ` /
`AUTO_AGENTS_KB_WRITE` continue to tell each agent what it *should*
touch (a `private` agent still won't write into `shared/` because
its `KB_WRITE` points at `agents/<name>/`). `--add-dir` is purely
a permission-prompt-noise mechanism — granting the root covers
the canonical schema and audit-trail files every agent needs and
removes friction without weakening any contract the env vars
encode.

### Behavior

- Default `shared` scope agents (the dominant case on this
  project): `--add-dir <kb-root>` replaces the redundant pair of
  `--add-dir <kb-root>/shared` + `--add-dir <kb-root>/agents`,
  since both are covered by the root.
- `private` / `isolated` agents: `--add-dir <kb-root>` is added
  alongside the existing per-agent sub-path entries that the
  `covered()` helper now collapses where redundant.
- Mailbox dir grant (`rec.dir`) is unchanged.

## [v0.2.19] — 2026-05-18 — diff_queue verdict routing back to mailbox originator

Closes the response-path half of the diff-feedback-routing-to-
gemini-juliet todo (ADR 0011 follow-up — the attribution half
landed in v0.2.11 / v0.2.12 + v0.2.13). Pre-patch the `diff_queue`
mailbox command was fire-and-forget: the originating agent
received an enqueue ack but never learned whether the user
accepted or rejected the diff. The only verdict channel for non-
Claude agents (Gemini, Junie) was for the user to type the
feedback into the agent's terminal by hand.

Post-patch the panel's accept (A) and reject (D / M-with-comment)
flows emit a follow-up `kind="message"` back to the originating
agent's inbox via the standard router, keyed by the original
`diff_queue` command's `correlation_id`. Wake fires automatically
via `auto-core.mailbox.router.handle_inbox` → `dispatch_wake`.

### Added

- `AutoAgentsDiffRequest` carries two optional fields used only by
  the mailbox-routed path:
  - `originator_mailbox_id` — full mailbox id of the agent that
    submitted via `diff_queue` (e.g. `agent:juliet:<instance>`).
  - `correlation_id` — the original `diff_queue` command's
    correlation_id, replayed on the verdict message so the agent
    can match.
  MCP openDiff (Claude / Codex via the websocket bridge) leaves
  both nil — the coroutine callback remains the reply channel for
  that path.

- `diff/queue.lua` `emit_verdict(req, verdict, comment)` helper —
  best-effort `auto-core.mailbox.transport.send` of a
  `kind="message"` envelope from `nvim` to the originator. Lands in
  inbox/, fires wake, the agent reads:

  ```text
  kind:            "message"
  from:            "nvim"
  correlation_id:  <original>
  subject:         "diff verdict (accepted|rejected) for <tab>"
  body:            human-readable summary
  args:            { verdict, comment, file_path, tab_name }
  ```

  Failures log via `auto-agents.log.warn` and do NOT propagate —
  panel resolution must not depend on the mailbox round-trip.

### Changed

- `mailbox/commands.lua` `handle_diff_queue` reads `ctx.sender`
  (auto-core v0.1.12+) and `ctx.correlation_id` (auto-core
  v0.1.23+); when both are present they propagate to the queue
  entry so `emit_verdict` can fire on resolve/reject.
- The handler's response now includes `verdict_follow_up: true`
  and `correlation_id: <cor>` when the originator was captured,
  so the caller knows a verdict message is en route. The `note`
  field documents the protocol.

### Compatibility

- **Hard dependency: `auto-core` ≥ v0.1.23** for `ctx.correlation_id`.
  Older auto-core leaves the field unset; the handler degrades to
  the v0.2.18 fire-and-forget shape (no verdict emission, no
  `verdict_follow_up` flag).
- Existing MCP openDiff entries (Claude / Codex) are unaffected —
  the new fields are nil for that path; `emit_verdict` no-ops.
- Existing tests in `tests/diff_mailbox_sender_spec.lua` continue
  to pass.

### Versioning

`M.version` jumps `0.2.17` → `0.2.19`. v0.2.18 was a tagged ship
("kb/instruct — render per-cwd block agent-neutrally") but its
ship did not update the in-source `M.version` constant — this
patch resolves that drift forward.

## [v0.2.16] — 2026-05-17 — bootstrap revision audit uses tool-root state

Corrects the auto-agents prompts that tell spawned agents how to
decide whether `bootstrap-mailbox.md` needs to be re-ingested.
The seen revision now lives beside the shared per-tool-root
bootstrap doc instead of only inside the per-instance mailbox dir.

### Changed

- **Spawn-injected KB instructions** now tell agents to check the
  bootstrap revision on spawn and before mailbox work by comparing
  `$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC` frontmatter against
  `$(dirname "$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC")/.agent-state/seen-revision`.
- **`<leader>am` / `reingest_bootstrap_picker()` prompt** now points
  at the same persistent tool-root `seen-revision` path.
- `M.version` bumped from `0.2.15` to `0.2.16`.

### Compatibility

Prompt/instruction-only patch. No public Lua API, mailbox command, or
state shape changed.

## [v0.2.13] — 2026-05-16 — ADR 0023: resumed-agent identity reconciliation (verb + sidecar + adopt command)

Closes the agent-side and host-side tracks of the resumed-agent
identity drift bug per
[ADR 0023](https://github.com/yongjohnlee80/auto-agents/blob/main/shared/adrs/0023-resumed-agent-identity-reconciliation.md).
When an agent is resumed (`/resume` in claude-code / codex), its
`$AUTO_AGENTS_MAILBOX_DIR` env stays frozen at the original
spawn's instance suffix while the host has moved on to a new
live instance. Prior to v0.2.13 the agent would silently send to
a stale outbox that the live router no longer scans, and the
host couldn't reconcile the slot without a full restart.

Requires auto-core v0.1.13+ (`mailbox.stale_orphan_detected`
event + wake `identity_hint` field).

### Added

- **`refresh_agent_id` mailbox verb** (agent-initiated
  reconciliation). Registered in
  `lua/auto-agents/mailbox/commands.lua` with a JSON-schema
  whitelist:
  ```
  { agent_pid :: integer, stamped_by :: string }
  ```
  Handler resolves the calling slot from the sender's bare id,
  builds the canonical runtime-identity record via
  `runtime_identity.build_record`, atomic-writes it to the
  sidecar path, and responds with `{ ok = true,
  runtime_identity_path = <path> }` so the agent can re-read
  identity on the next wake. Designed for the agent path where
  the wake-payload `identity_hint` reveals drift.
- **`lua/auto-agents/runtime_identity.lua`** — sidecar identity
  plumbing. New module:
  - `path_for(slot)` → `<stdpath('data')>/auto-agents/runtime-identity-<slot>.json`
    (or `AUTO_AGENTS_RUNTIME_IDENTITY_PATH` env override for
    tests).
  - `build_record(slot, agent_name, tool_root, mailbox_dir,
    stamped_by, agent_pid)` → canonical JSON-serializable
    record with `slot`, `agent_name`, `agent_pid`,
    `mailbox_bare`, `mailbox_full`, `mailbox_dir`, `tool_root`,
    `instance_id`, `stamped_by`, `stamped_at`.
  - `write(slot, record)` — atomic write via temp + rename.
  - `read(slot)` — best-effort read, returns nil if absent.
- **Spawn-time sidecar write.** `lua/auto-agents/init.lua`'s
  spawn path now calls `runtime_identity.build_record + write`
  after `env_for_agent`, so every freshly-spawned agent has a
  sidecar from t=0. Used by the agent to read its own
  identity rather than trusting the fork-frozen env vars.
- **`addressbook` augmentation.** The mailbox `addressbook`
  command now includes a `runtime_identity` field on each agent
  entry, populated from the slot's sidecar when present. Lets
  peers read identity metadata without parsing the registry.
- **`:AutoAgentsAdoptResumedAgent <slot>`** user command
  (host-initiated reconciliation). When the user knows a slot
  was just `/resume`d and wants to reconcile without waiting
  for the agent to detect drift on its own. Behavior:
  1. Resolve the slot's live PID via
     `state.slot_terminals[slot]:pid()`.
  2. Look up the agent name from the bootstrap config.
  3. Idempotently register the mailbox at the live instance
     (bare-id `register` auto-resolves under v0.1.8 semantics).
  4. Build + write the canonical sidecar record.
  5. Inject a wake message into the agent's live inbox with
     the new record + sidecar path + a preamble explaining the
     reconciliation, so the agent re-reads on next wake.
  Tab-completion lists currently-live slot numbers.

### Tests

Smoke section `[16]` — Phase 2 surface (11 assertions):
- `refresh_agent_id` verb registered + accepts schema-conformant
  args + rejects missing fields.
- Sidecar written by spawn path (idempotent, atomic).
- Addressbook entry carries `runtime_identity` when sidecar
  exists.
- Sidecar `path_for` honors env override.

Smoke section `[17]` — Phase 3 surface (11 assertions including
the §5.3 acceptance criterion):
- `:AutoAgentsAdoptResumedAgent` command registered + tab
  completion lists live slots.
- Missing-arg + unknown-slot diagnostics surface ERROR notifies.
- Command runs without error on a live slot; sidecar lands;
  record carries slot + agent_name + agent_pid; stamped_by
  reflects the adopt path.
- Wake message lands in the inbox with `runtime_identity_path`
  and the reconciliation preamble.
- **Round-trip §5.3:** post-adopt, an outbox write from the
  reconciled slot lands in the peer's inbox via the STANDARD
  router scan path (not direct-write, not silently dropped).

All 22 ADR 0023 assertions across Phase 1+2+3 green. Suite at
117 passed, 2 failed — both pre-existing `send_slot`
bracketed-paste fails from comms-1, unrelated to ADR 0023.

### Notes

- **Additive.** No existing mailbox verb, command, state key, or
  spawn-time behavior changed. Pre-resume flows ride through
  byte-identically; resumed-agent flows now have a working
  reconciliation path.
- **Sidecar is the source of truth** post-resume. Agents that
  detect `identity_hint` drift (via the v0.1.13 wake field)
  should send `refresh_agent_id` and re-read their identity
  from the returned sidecar path, NOT from their fork-frozen
  env. The convention is documented in the auto-core v0.1.13
  bootstrap doc §"Resumed-agent identity reconciliation".
- Renumbered from a pre-rebase v0.2.11 → v0.2.13 because
  v0.2.11 was claimed upstream by the ADR 0021 Phase 2 logging
  refactor and v0.2.12 by the diff-panel labels ship. This work
  rebases on top of v0.2.12 and bumps to the next patch.

### Files touched

- `lua/auto-agents/runtime_identity.lua` (new)
- `lua/auto-agents/mailbox/commands.lua` (+`refresh_agent_id`
  handler + spec; +`addressbook.runtime_identity` field)
- `lua/auto-agents/init.lua` (spawn-time sidecar write;
  version 0.2.12 → 0.2.13)
- `plugin/auto-agents.lua` (+`:AutoAgentsAdoptResumedAgent`
  user command + tab completion)
- `tests/smoke.lua` (sections `[16]` + `[17]`)

## [v0.2.12] — 2026-05-16 — diff panel: labels + cascade-drain + websocket/mailbox attribution (ADR 0011)

Renumbered from the pre-rebase v0.2.11 → v0.2.12 because v0.2.11 was
claimed upstream by the ADR 0021 Phase 2 logging refactor; this work
rebases on top of that and bumps to the next patch in line.

Bundle release of every fix on the `fix-diff-panel` branch. The
panel-labels work (ADR 0011 Patch 1) is the headline; the
cascade-drain fix and the websocket/mailbox attribution patches
(2/3/4) ship together because they all converge on the same
multi-agent diff-review surface.

### Cascade-drain fix — `A` no longer empties the queue

Symptom: with N pending entries in the Pending Diffs panel, one `A`
press at position 1 dismissed ALL N entries. Cause: after the user
accepts a diff via `A`, the resolved entry's coroutine resumes with
`FILE_SAVED` and Claude Code's CLI treats that as "the user processed
the queue" — it then sends `close_tab` for every sibling diff tab in
its session. The pre-fix close_tab handler called `queue.reject` on
each match, so one `A` produced an agent-driven cascade of rejections.

Fix (`lua/auto-agents/mcp/ws-server/tools/close_tab.lua`): when the
diff panel is OPEN, close_tab is a no-op for pending queue entries —
returns `TAB_CLOSED` without mutating the queue. The panel owns the
resolution lifecycle while it's up; A/D/M are the only paths that
remove an entry. When the panel is closed, close_tab works as before
(CLI-terminal dismiss still drains orphaned entries).

Surface: new public predicate `auto-agents.diff.ui.is_open()` so the
close_tab handler can check panel state without poking at internals.

Test: new `tests/diff_cascade_drain_spec.lua` reproduces the
user-reported scenario end-to-end — enqueue 3 entries, open the
panel, fire close_tab for two of them, assert all three remain
pending. Then close the panel and assert close_tab still drains
(legacy CLI-dismiss path intact). 15 assertions.

### Round-2 review fixes (agent:lector — 2026-05-16)

Folded in two corrections from Lector's round-2 review (review doc at
`$AUTO_AGENTS_KB_ROOT/agents/lector/reviews/2026-05-16-auto-agents-fix-diff-panel-round2-review.md`):

**HIGH — peer_identity matched the wrong inode direction.** The pre-fix
`find_inode_for_peer(listen_port, peer_port)` matched
`/proc/net/tcp` rows where `local_address == listen_port` AND
`rem_address == peer_port` — that's the **server-accept** row, whose
inode is owned by nvim itself, not the agent process. The
`/proc/<agent_pid>/fd` walk could therefore never match, and the
fallback chain landed on `unattributed` every time — defeating the
whole point of the patch.

Fixed: renamed to `find_agent_inode(server_port, client_port)` and
flipped the match to the **client-connect** row
(`local == client_port, rem == server_port`), whose inode IS in the
agent's fd table. Direct proof added to the spec: spin up a real
localhost TCP pair via `vim.uv`, call `find_agent_inode` on the
live ports, and assert (a) it returns an inode, (b) that inode is
DIFFERENT from the server-accept row's inode discovered by an
independent manual scan. 4 new assertions on top of the existing
16 in `tests/diff_peer_identity_spec.lua` (now 20 total).

**MEDIUM — repo_for non-git fallback was environment-sensitive.**
The earlier draft consulted `fs_path.project_root` (markers: `.git`,
`go.mod`, `package.json`, `pyproject.toml`, `lazy-lock.json`,
`.luarc.json`, `Cargo.toml`, `deno.json`, `deno.jsonc`, `build.zig`)
before the final `:h:t` fallback. When the test's tmpdir happened
to be a descendant of a directory containing any of those markers
— Lector's `/tmp` did, mine didn't — `repo_for` returned the
surprising ancestor's name instead of the file's own parent.

Fixed by removing the `project_root` step entirely. The diff panel
label is meant to identify *this file's locality*, not "the
nearest project marker anywhere up the tree." Non-git paths now
deterministically resolve to their parent-dir basename. The
`tests/diff_panel_labels_spec.lua` `non-git tmpdir` case is now
green on both environments.

**Acknowledged (no-op in this PR):**

- `auto-core` smoke §25 `is_git false on a fresh empty dir` /
  `root nil on a fresh empty dir` fails on Lector's machine but
  passes on mine — same class of environment sensitivity (his
  `vim.fn.tempname()` produces a path that has a `.git` ancestor;
  mine doesn't). The flakiness is in pre-existing test code at
  `tests/smoke.lua:797-800`, **not** in the §49 ctx.sender
  assertions my Patch 3 added. Out of scope for this PR; could be
  cleaned up in an auto-core follow-up.

### Websocket attribution via peer-PID lookup (ADR 0011 Patch 2, D2-B)

Closed the openDiff attribution gap on the native MCP bridge so
diffs from any `diff_review = true` slot (jarvis, lector,
wanda-maximoff, white-vision in the user's setup) render with
their actual agent name instead of `[unattributed]`. Chose D2-B
over D2-A per ADR 0011 §Recommendation — D2-A's singleton→factory
refactor wasn't justified given the spike couldn't conclusively
prove `CLAUDE_CODE_SSE_PORT` wins over lockfile discovery.

New module `lua/auto-agents/mcp/ws-server/peer_identity.lua` maps
a TCP connection back to its owning slot via `/proc/net/tcp` +
`/proc/<pid>/fd` (Linux only; non-Linux returns nil and the panel
renders `unattributed` — no regression). `tools/init.lua`
forwards `client` to handlers via a new `ctx` arg (additive).
`open_diff.lua` consults `peer_identity` when
`_auto_agents_name` is absent. Cache invalidated on disconnect.

Test: `tests/diff_peer_identity_spec.lua` — 16 assertions
covering ctx propagation, port_hex_lc round-trip, degraded-path
nil-handling, cache eviction, and explicit `_auto_agents_name`
override preservation. The full /proc walk needs a live TCP pair
from a spawned claude-code slot — verify manually after merge.

### Mailbox sender attribution (ADR 0011 Patch 4)

Companion fix to the websocket path for diffs routed via the
mailbox `diff_queue` command. Pre-patch, the handler derived
`agent_name` from `ctx.mailbox` — which auto-core's executor
populates with the EXECUTOR's mailbox (`nvim`), not the SENDER.
Every mailbox-routed diff therefore mislabelled as `[nvim]`.

Post-patch, attribution prefers in order: `args.agent_name`
(explicit override) → `ctx.sender_bare` (auto-core v0.1.11+ — the
sender's bare mailbox id, e.g. `agent:jarvis`) → legacy
`ctx.mailbox` (for older auto-core) → bootstrap resolver → "?".

Couples auto-agents to auto-core ≥ v0.1.11 for the headline fix,
but the legacy fallback chain keeps the handler functional against
older auto-core versions — it just falls back to the old (wrong)
behavior in that case.

Test: `tests/diff_mailbox_sender_spec.lua` — 10 assertions across
the four resolution chain branches.

### Diff panel labels — repo column + unattributed placeholder (ADR 0011 Patch 1)

The Pending Diffs panel in v0.2.10 rendered `Projects/log.md [?]`
for diffs of files in the user's bare-worktree layout, with no
agent name attached. Two independent bugs in the
`v0.2.6` left-column code (see ADR 0011 §Findings):

1. **Repo column resolved to `Projects`.** `wt_for` called
   `fs_path.workspace_root(path)` positionally, but the API takes
   an options table. With `opts.start = nil` the resolver walked
   from `vim.fn.getcwd()` instead of the file path, then —
   finding no `.git`/`.bare` in any ancestor — fell back to the
   "last resort: parent of start" branch and returned the cwd's
   parent (`~/Source/Projects`), basename `"Projects"`. Even with
   the call fixed, `workspace_root` returns the *parent of* the
   git container, not the repo itself; for bare-worktree layouts
   the file's worktree basename (`fix-diff-panel`, `main`) is a
   branch name, not a repo identity.

2. **Agent column showed `[?]`.** The display predicate stripped
   the literal placeholders `""` / `"agent"` but rendered the
   sentinel `"?"` (used by the MCP openDiff handlers when the
   bootstrap `resolve_diff_agent_name(nil)` returns nil under
   any 2+ `diff_review = true` config) verbatim. The user's
   global.toml has 4 such agents, so the resolver is always
   ambiguous.

### Changed

- **`lua/auto-agents/diff/ui.lua`** (`render_left`):
  - Replace `wt_for` with `repo_for`, lifted to file scope so the
    panel spec can drive it. Resolves the label through
    `auto-core.git.repo.common_dir({ start = parent(path) })` and
    derives the basename:
    * common_dir basename is `.git` / `.bare` → parent basename
      (`auto-agents.nvim`, `kb`).
    * common_dir basename is anything else (bare repo with no
      `.git`/`.bare` subdir — common_dir IS the bare itself) →
      that basename verbatim.
  - Non-git fallback: parent-dir basename via `:h:t`. The earlier
    `fs_path.project_root` step was removed after Lector's round-2
    review showed it leaked ancestor markers (`.luarc.json`,
    `package.json`, ...) into the panel label.
  - Add `agent_for` (file-scope helper). Normalises every known
    "unattributed" sentinel (nil, `""`, `"agent"`, `"?"`,
    `"unknown"`, `"unattributed"`, non-string values) to the
    literal display string `unattributed`. Real attributions
    (`jarvis`, `lector`, `agent-foo`, etc.) pass through
    unchanged.
  - Add `M._test_repo_for` / `M._test_agent_for` for the
    regression spec — not part of the public contract.

### Added

- **`tests/diff_panel_labels_spec.lua`** — headless regression
  spec for the new label resolvers. Stands up real git fixtures
  in a tmpdir (bare + linked worktrees, plain clone, non-git
  dir) and asserts the exact strings the user reported as
  broken. Existing `diff_ui_spec.lua` / `diff_queue_spec.lua`
  pass unchanged.

### Notes

- This patch is **Patch 1 of the ADR 0011 rollout**. It fixes
  both visible columns at the display layer. Patches 2-4
  (websocket attribution + mailbox sender propagation) close
  the upstream attribution gaps so the `agent_for` fallback to
  `unattributed` becomes a defense-in-depth rather than the
  primary failure mode.
- ADR 0011 was renumbered to ADR 0030 when relocated into the KB
  (the in-repo `docs/adr/` tree was retired on 2026-05-24 in favor
  of the KB as the single home for ADRs). The ADR now lives at
  `$AUTO_AGENTS_KB_ROOT/shared/adrs/0030-diff-panel-label-resolution-bug.md`
  and documents the spike + per-slot bridge proposal for Patch 2.

## [v0.2.11] — 2026-05-16 — ADR 0021 Phase 2 wrapper + diff-queue / send_slot / mailbox improvements

Bundle release. Eight commits accumulated on the `comms-1` worktree
since v0.2.10 — the Phase 2 logging refactor is the headline, but
seven smaller collab improvements ship alongside.

### ADR 0021 Phase 2 — wrapper rename + sweep + ws-server bridge

Largest single piece. Per the wrapper convention (ADR 0021 §6,
codified at `shared/conventions/auto-family-logging.md`),
auto-agents now owns `lua/auto-agents/log.lua` as the single
insertion point for all emissions. Renamed from `logger.lua`,
broadened to expose `notify` / `notifyIf` / `register_events`,
and soft-dep tolerant for pre-Phase-1 auto-core.

- **Renamed `lua/auto-agents/logger.lua` → `lua/auto-agents/log.lua`**
  via `git mv` (history preserved). The new wrapper exposes:

  ```lua
  local log = require("auto-agents.log")

  log.error / .warn / .info / .debug / .trace  -- with auto-agents.* component prefix
  log.notify(msg, opts?)                        -- force-toast single emission
  log.notifyIf(event, msg, opts?)               -- toast iff event subscribed
  log.register_events(events)                   -- declare at setup
  log.is_level_enabled(name)                    -- predicate
  log.setup(cfg)                                -- forward cfg.log_level
  ```

- **9 require paths swept** across `init.lua`,
  `integrations/{editor_floor,tree}.lua`, `mcp/server.lua`,
  `mailbox/commands.lua`, `config/store.lua`, `kb/instruct.lua`,
  `terminal/native.lua`, `resources/grants.lua`. All
  `require("auto-agents.logger")` → `require("auto-agents.log")`.

- **9 non-fork bare `vim.notify` call sites swept** —
  `diff/ui.lua` (4 sites: save-error, auto-core soft-dep,
  edit-mode toast, view-mode toast), `mailbox/commands.lua` (the
  `send_user` agent → user toast bridge),
  `help.lua` (missing-docs error),
  `status/observer.lua` (2 sites: model-sync success + failure).
  Custom toast titles (`"auto-agents diff"`, `"auto-agents"`)
  preserved via `opts.title`.

- **ws-server vendored claudecode logger — BRIDGE (ADR 0021 §10.2).**
  Audit verdict: no code outside `auto-agents/mcp/ws-server/`
  imports the vendored module by path. But the
  `vendoring-third-party-protocol-clients` playbook requires
  preserving the upstream-shape so future re-syncs from
  `coder/claudecode.nvim` minimize diff churn. Kept the file +
  signatures; rewired internals so every emit ALSO forwards to
  `auto-agents.log.<level>("ws-server.<component>", …)`. Lazy
  resolution via `af_log()` avoids init-order coupling.

- **6 ws-server-internal bare `vim.notify` calls swept** through
  the (now-bridged) vendored logger:
  `tools/init.lua` (tool-registration error), `diff.lua` x5
  (cleanup paths + user-command no-active-diff warnings).

Soft-dep tolerance: when running against an auto-core older
than v0.1.11 (no `notify` / `notifyIf` / `events.register`),
each new method in the wrapper degrades to a ring-only emission
instead of crashing. Users without auto-core get the
`[auto-agents.<component>] <msg>` fallback vim.notify so the
toast surface is preserved.

### diff queue UX — `O` opens full-file diff, `<CR>` commits cursor row

Pre-v0.2.11 the diff queue's panel bound `<CR>` to "open full-file
diff in editor", which was awkward when the queue had >9 entries
and `<CR>` was the natural "commit row N" gesture. v0.2.11
swaps:

- `<CR>` now commits the cursor row (accept the diff under
  cursor). Replaces the prior numeric-prefix flow for queues > 9.
- `O` opens the full-file diff in the editor (the action that
  used to be on `<CR>`).
- When `O` opens, the editor's view is unfolded so the user
  sees the full pre/post buffer pair without manually
  expanding folds.

### `send_slot` wraps text in bracketed-paste

When auto-agents drives `send_slot(slot, text, { submit = true })`
into a TUI's terminal (claude / codex / gemini), the receiver may
interpret the body+CR as multiple keystrokes and lose characters
to its own paste-detection heuristics. Wrapping in
`ESC[200~ … ESC[201~` (the bracketed-paste sequence) tells the
TUI "this is one paste, not typed input" — characters land
atomically.

The post-body `\r` (from `opts.submit = true`) is sent OUTSIDE the
paste brackets so the TUI sees the submit explicitly, not as part
of the paste.

### kb.instruct — inject mailbox protocol into every spawn

Every agent spawn's instruction file now carries the canonical
mailbox protocol section (the same one in
`<tool-root>/bootstrap-mailbox.md`) so agents know how to operate
their mailbox from cold start without an explicit ingest step.
Replaces the prior pattern where each agent had to either
hardcode the protocol or ingest the bootstrap doc themselves.

### mailbox.commands — add `commands_list` for verb discovery

New whitelisted verb. Agents send `kind = "command"` with
`verb = "commands_list"` and receive the live registry of every
verb currently mounted on the `nvim` executioner (across every
plugin that called `mailbox.commands.register`). Replaces the
prior pattern of hardcoding the agent-known verb set.

### diff-parity / panel restore on diff-close

Removed the diff-parity ghost-absorber that papered over a panel
column-restore bug; root-caused the panel column collapse and
restored the layout directly when the diff buffer closes.

### Tests

`tests/smoke.lua` — 92 passed, 5 failed. The 5 failures are
pre-existing on `comms-1` BEFORE the Phase 2 sweep:

- 3 slot-count failures (`MAX_SLOT defaults to 5`,
  `slot_count mirrored to 7`, `MAX_SLOT updated via
  sync_slot_count`) — caused by the global.toml having 6 agents
  rather than the smoke's assumed 5-floor. Test data, not
  auto-agents code. Tracked for a future test-fixture refresh.
- 2 send_slot bracketed-paste failures (`body sent immediately`,
  `send_slot without submit fires one chan_send`) — pre-dated
  this ship; tracked alongside the diff-queue work that landed
  earlier.

**Zero new failures introduced by the Phase 2 sweep.**

### Migration

Soft. Consumers pin via `version = "^0.2.0"` and auto-update.
`require("auto-agents.logger")` callers — none in the family
besides auto-agents itself — should switch to
`require("auto-agents.log")`. The wrapper soft-deps against
pre-Phase-1 auto-core so consumers can stage the upgrade in any
order.

## [v0.2.10] — 2026-05-14 — fix codex permission flag, add gemini support, add `diff_queue` command

v0.2.9 shipped with `--sandbox-workspace-write-root` as the codex
flag (lector hallucinated it — that's actually the TOML config
field name `sandbox_workspace_write.writable_roots`, not a CLI
flag). The real codex CLI flag is `--add-dir <DIR>` — same name
as Claude's. Verified by checking `codex --help` and confirming
the documented description: "Additional directories that should
be writable alongside the primary workspace."

Also adds gemini support — `--include-directories <DIR>` per
`gemini --help`.

### Changed

- **`permissions.lua`** STRATEGY table:
  - `codex` → `--add-dir <path>` (was `--sandbox-workspace-write-root`)
  - `gemini` → `--include-directories <path>` (new)
- Module doc-comments updated with the correct flag names + a
  note distinguishing the codex CLI flag from the TOML config
  field.

### Notes

- v0.2.9 codex spawns errored out with `error: unexpected argument
  '--sandbox-workspace-write-root' found`. This patch is the
  immediate fix.
- gemini's `--include-directories` accepts either comma-separated
  values OR repeated flags; the repeatable form is what
  `permissions.lua` emits.

### Added (mailbox commands)

- **`diff_queue` command** (auto-agents-owned). Enqueues a diff
  into the unified diff queue UI. Fire-and-forget — the user's
  accept/reject is NOT routed back to the sender through the
  mailbox transport. For a blocking verdict, use the MCP openDiff
  handler at `lua/auto-agents/mcp/ws-server/tools/open_diff.lua`.
  `args = { old_file_path, new_file_path, new_file_contents, tab_name, agent_name? }`.
  When `agent_name` is omitted, the handler derives it from the
  sender's mailbox id (`ctx.mailbox` — e.g. `agent:lector` →
  `lector`), then runs it through `resolve_diff_agent_name` for
  the bootstrap-config lookup fallback.

This rounds out the auto-agents whitelist contribution to
**four** commands: `wake`, `addressbook`, `send_user`, `diff_queue`.
Other plugins (e.g. md-harpoon's `harpoon`) register their own.

## [v0.2.9] — 2026-05-14 — spawn-time permission injection (claude `--add-dir`, codex `--add-dir`)

Agents previously prompted the user for permission on every first
file op against their mailbox dir and the KB read/write paths.
This patch pre-authorizes those dirs at spawn time by appending
the appropriate CLI flag(s) to the agent's argv — no settings-
file mutation, no persistence (the per-instance mailbox path
regenerates on every nvim restart, so the next spawn rebuilds
the argv from scratch).

### Added

- **`lua/auto-agents/permissions.lua`** — per-kind spawn-time
  permission strategy table. v0.2.9 ships strategies for two kinds:
  - `claude` → `--add-dir <path>` (repeatable)
  - `codex`  → `--sandbox-workspace-write-root <path>` (repeatable)
  Kinds without a strategy (`gemini`, `junie`, `aider`, `goose`,
  `opencode`, `copilot`, `generic`) get an empty result; the agent
  runs unchanged. Public API:
  `permissions.argv_for_kind(kind, dirs) -> string[]`,
  `permissions.supported(kind)`, `permissions.supported_kinds()`.
- **`build_agent_env`** now also assembles a dir list at spawn
  time (`AUTO_AGENTS_MAILBOX_DIR` + every entry in
  `AUTO_AGENTS_KB_READ` + `AUTO_AGENTS_KB_WRITE` if not already
  covered) and appends `permissions.argv_for_kind(spec.kind, dirs)`
  to `spec.cmd`. Logs the grant list at INFO so it's visible in
  `:AutoCoreLogs`.

### Notes

- Per-tool sandboxes already grant access to each tool's config
  dir (`~/.claude/`, `~/.codex/`, etc.); the explicit `--add-dir`
  flag is just to skip Claude Code's permission prompt for paths
  inside that tree that weren't pre-allowed. The KB paths live
  outside the tool config tree and would prompt otherwise.
- gemini support is tracked in
  `~/.config/nvim/docs/todo-lists/mailbox-wake-and-permissions.md`.
- This is a patch within the `v0.2.x` line — no API breaks, the
  `permissions.lua` module is purely additive. Future strategies
  for additional kinds land as further patches.

## [v0.2.8] — 2026-05-14 — register mailbox commands (wake, addressbook, send_user)

v0.2.7 wired the mailbox at spawn time but the wake hook silently
no-op'd: auto-core's router calls `commands.get(<wake.command>)` on
every inbox/responses arrival, and nothing had claimed that name.
This patch registers three auto-agents-owned commands so the wake
actually fires and agents can discover their peers + reach the user
without guessing.

### Added

- **`lua/auto-agents/mailbox/commands.lua`** — module that registers
  auto-agents-owned mailbox commands with auto-core's
  `mailbox.commands.register` whitelist. `M.register_all()` is
  idempotent (auto-core allows re-register from the same owner).
- **`wake` command** — `args = { slot, text?, submit? }`. The
  canonical wake hook used by the router on every inbox/responses
  arrival (`wake = { command = "wake", args = { slot = "<name>" } }`
  is registered per-agent in `build_agent_env`). Resolves `slot`
  (agent name string) → integer slot via `auto_agents.slot_for_name`.
  Calls `auto_agents.send_slot` internally to nudge the terminal.
  When invoked as a wake hook with no explicit text, synthesizes a
  default nudge: `[auto-agents] new <kind> from <mailbox> — check
  $AUTO_AGENTS_MAILBOX_DIR/<kind>/`. Returns structured errors
  (`slot_not_found`, `terminal_unavailable`). Also agent-callable —
  one agent can wake another by sending `kind="command" command="wake"`
  to `nvim`.
- **`addressbook` command** — `args = { include_self? }`. Returns
  every reachable mailbox address registered with auto-core (peer
  agents + the `nvim` executioner) plus a virtual `user` entry
  pointing at `send_user`. Dynamic by construction — the underlying
  registry is populated by `mailbox.register` at agent spawn time,
  so newly-spawned peers appear without the agent having to refresh.
  Returned shape includes `id`, `bare_id`, `kind` (`agent`/`host`/
  `virtual`), `dir`, `tool_root`, `executioner`, `wake_command`,
  and `is_self`.
- **`send_user` command** — `args = { subject?, body?, level? }`.
  Forwards to `vim.notify` (with `title = "auto-agents.mailbox"`).
  `level` accepts `info` (default), `warn`, `error`, `debug`.
- **`auto-agents.setup()`** now calls
  `require("auto-agents.mailbox.commands").register_all()` after the
  v0.2.7 mailbox wiring.

### Changed

- **Per-agent wake hook in `build_agent_env`** now uses
  `wake = { command = "wake", … }` (renamed from `"send_slot"` —
  cleaner public API name; the internal `auto_agents.send_slot`
  Lua function is unchanged and remains the implementation
  primitive the handler uses).

### Notes

- Other plugins (md-harpoon for `harpoon`, the diff MCP for an
  `openDiff` mirror, etc.) register their own commands via the
  same `auto-core.mailbox.commands.register` API. This patch is
  auto-agents' contribution to the whitelist; the architecture
  is open to extension.
- With `wake` registered, the router's `dispatch_wake` path
  (auto-core router.lua:204-233) now reaches `commands.handle_message`
  with the wake message, which fires the handler and nudges the
  slot terminal. Lector → jarvis test messages now wake jarvis.
- The on-disk per-instance bootstrap doc still references
  `send_slot` (auto-core v0.1.8 baked it in). The doc template
  update lands in auto-core v0.1.9 separately.

## [v0.2.7] — 2026-05-14 — wire the auto-core mailbox at spawn time

`auto-core` v0.1.8 shipped per-instance mailbox isolation behind
`mailbox.register` + `mailbox.env_for_agent(rec)` — but no consumer
was actually calling those APIs. Spawned agents had no
`AUTO_AGENTS_INSTANCE_ID` / `AUTO_AGENTS_MAILBOX_*` env vars and
the central router was never started, so agents couldn't locate
their mailbox even though the on-disk tree from earlier
`transport.send` test runs was still present. This patch fills
the consumer-side gap.

### Added

- **`auto-agents.setup()`** now starts the auto-core mailbox router
  (`mailbox.configure({ autostart = true })`) and registers the
  host-side `nvim` executioner mailbox so agents can send
  `kind="command"` messages back (whitelisted: `harpoon`,
  `openDiff`, `send_slot`, `send_user`).
- **`build_agent_env(spec, cwd)`** now calls
  `mailbox.register("agent:" .. spec.name, { root, wake })` per
  spawn — auto-core v0.1.8 auto-suffixes the bare id with this
  nvim's `instance_id` (`<unix-seconds>-<pid>`) so two nvims
  sharing a tool root get non-overlapping subtrees. The four env
  vars from `mailbox.env_for_agent(rec)` are merged into the spawn
  env so the agent can locate its mailbox without socket access
  (sandbox-safe).
- **`MAILBOX_ROOT_BY_KIND` constant** — maps `claude`/`codex`/
  `gemini` to their respective tool config dirs. Kinds not in the
  map fall back to `mailbox.host_fallback_root()`.

### Behavior

Each spawn now produces (using a `claude`-kind agent named `jarvis`
as an example):

- Per-instance directory `~/.claude/mailbox/agent:jarvis:<seconds>-<pid>/`
  with subdirs `inbox/`, `outbox/`, `responses/`, `processing/`,
  `archive/`, `.agent-state/`.
- Per-tool-root bootstrap doc `~/.claude/mailbox/bootstrap-mailbox.md`
  (hoisted from per-mailbox in v0.1.8 — single doc per tool root,
  content-hash short-circuit on upsert).
- Spawn env: `AUTO_AGENTS_INSTANCE_ID`, `AUTO_AGENTS_MAILBOX_ID`,
  `AUTO_AGENTS_MAILBOX_DIR`, `AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC`.
- A registered `wake = send_slot {slot=<name>}` hook — inbox arrivals
  wake the agent's terminal slot via auto-core's router.

### Compatibility

Pre-v0.2.7 bare-id mailbox trees (e.g. `~/.claude/mailbox/agent:jarvis/`)
are left in place — they're never "live" under v0.1.8+ registration
and will be swept by `mailbox.prune` once they exceed the 7-day age
threshold.

## [v0.2.6] — 2026-05-14 — diff queue panel: meaningful left-column labels

The unified-diff-queue panel's left column was rendering entries
as `[N] filename [agent]` — with the literal string `agent` in
brackets because the MCP open_diff handlers defaulted the
`agent_name` field to that placeholder and there was no
resolution step in between. This patch fixes both the resolution
and the rendering.

### Added

- **`auto-agents.resolve_diff_agent_name(explicit?)`** —
  best-effort resolution of "which agent is the source of an
  inbound diff." Returns the explicit name if the caller passed
  one, otherwise looks at the bootstrap config and returns the
  single `diff_review = true` agent's name. Returns nil when
  ambiguous (multiple diff_review agents) so callers can
  surface a `?` instead of guessing.

### Changed

- **`agent/adapters/tools/open_diff.lua`** + **`mcp/ws-server/tools/open_diff.lua`** — both
  open_diff handlers now route the agent identity through
  `resolve_diff_agent_name` before enqueuing. The literal
  `"agent"` placeholder is gone; queue entries land with the
  actual agent name when resolvable (or `"?"` as a fallback
  signal).
- **`diff/ui.lua` left-column format** — entries now render as
  `[N] {wt}/{filename} [{agent_name}]` where `{wt}` is the
  basename of the file's enclosing workspace (resolved via
  `auto-core.fs.path.workspace_root`, falling back to the
  parent directory's basename when no workspace is found).
  The `agent_name` defaults to `"?"` when unset / unresolved,
  not the old `"agent"` literal.

## [v0.2.5] — 2026-05-14 — codex adapter no longer injects auto-agents MCP via `-c`

The codex adapter previously appended
`-c mcp_servers.auto-agents={ url="http://127.0.0.1:<port>/mcp" }` to
the spawn argv for any agent with `diff_review = true`. With the
bridge as it currently stands on `main`, codex can't actually
authenticate to that endpoint, so the registration just caused codex
to error out at startup. Users who want codex to talk to the bridge
should register `mcp_servers.auto-agents` in `~/.codex/config.toml`
themselves.

The `diff_review` env hints in `init.lua`
(`AUTO_AGENTS_MCP_URL`, `AUTO_AGENTS_MCP_PORT`, `CLAUDE_CODE_SSE_PORT`,
etc.) are unchanged and still injected for the Claude-compatible
bridge path.

### Removed

- **`auto-agents.agent.adapters.codex`** — dropped the M6 block that
  appended `-c mcp_servers.auto-agents=...` when `spec.diff_review`
  was set. The codex adapter now only emits `codex` and `--model
  <id>` (when configured) before the spec-provided `cmd` override.

### Tests

- **`tests/adapter_codex_spec.lua`** — rewritten to assert that
  neither `diff_review=false` nor `diff_review=true` produces an
  `mcp_servers` entry in argv.

## [v0.2.4] — 2026-05-14 — diff-panel auto-close + winbar focus survive events-bus resets

Two bug fixes for stale-subscription regressions that surfaced when
the auto-core events bus gets reset mid-session (test harness leakage,
`:Lazy reload`, etc.). In both cases the visible symptom was the
panel state going wrong without any obvious code path having
changed — same underlying class: module-load-time `events.subscribe`
calls lose their handles when the bus is reset, and lua's module
cache prevents them from being re-registered.

### Fixed

- **`auto-agents.diff.ui`** — the auto-close + auto-refresh
  subscriptions for the diff panel are now registered inside
  `M.open()` (with handles captured into `_event_handles`) and
  released inside the float's `on_close`. Every panel open gets a
  fresh subscription pair. Symptom this fixes: pressing A or D on
  the last queued diff would empty the queue but leave the panel
  open. Regression test in `tests/diff_ui_spec.lua` section [5b]
  drives the actual A / D keymap callbacks across three scenarios
  (drain-via-A, drain-via-D, non-empty-stays-open).
- **`auto-agents.refresh_winbar`** — now reads the focused slot
  DIRECTLY from the state namespace (`state.get_focused_slot()`)
  instead of from the `M.state.focused_slot` mirror. The mirror is
  maintained by a `watch_focused_slot` subscriber registered once
  at setup; when the events bus is reset, the watcher silently
  disappears and the mirror sticks at its last value (commonly 1 =
  Jarvis). Symptom this fixes: the panel winbar always highlighted
  Jarvis regardless of which agent the user actually focused.
  Regression test in `tests/smoke.lua` near the existing
  `set_focused_slot` coverage forces the mirror out of sync and
  asserts the winbar still highlights the namespace-persisted slot.
  Namespace `:get` doesn't publish events, so it's resilient.

### Notes

These fixes also flush a latent bug in `on_close`: the old code
referenced `_event_handle` (singular) that the subscribe calls
never captured into. The unsubscribe was a no-op too. The new
`_event_handles = { refresh, autoclose }` table is properly written
and released.

The version-bump precedent: M.version in `lua/auto-agents/init.lua`
was lagging at "0.2.0" while tags advanced to v0.2.3. This release
brings the source string forward to match the tag.

## [v0.2.3] — 2026-05-13 — diff queue editorial workflow

A focused iteration on the unified diff queue panel (ADR 0010): bug fix
for the missing `close_tab` MCP hook, a UX baseline that frees Vim's
native motions inside the diff panes, two new resolution actions (M
REQUEST CHANGE, E in-pane edit), and treesitter highlighting so reviews
are actually readable. All changes are additive — the caret-pin
promise (`^0.2.0` → every v0.2.x) holds.

### Fixed

- **`close_tab` MCP hook into the unified diff queue.** Before this
  release `tools/init.lua` only registered `open_diff`. When Claude
  Code dismissed a diff out-of-band (user pressed `q` to hide the
  panel, then answered yes/no in the CLI terminal), Claude sent
  `close_tab` with the same `tab_name` — our server returned
  method-not-found and the queued coroutine stayed yielded forever.
  `close_tab` is now registered; it looks up the pending entry via
  the new `queue.find_by_tab_name(tab_name)` and calls
  `queue.reject(id)` so the yielded coroutine resumes with
  `DIFF_REJECTED` and the panel refreshes via the existing
  `auto-agents:diff_removed` event.

### Added (diff queue UX)

- **Native Vim motions inside the diff panes.** Selection keys
  (`j`/`k`/`1-9`/`<CR>`) are now scoped to the LEFT pane only;
  middle and preview let `hjkl`, counts (`5j`, `10G`), `gg`/`G`,
  `0`/`$`/`^`, `w`/`b`/`e`, `f`/`F`/`t`/`T`, `%`, etc. fall through
  to native Vim — mirrors `worktree.nvim`'s graph.lua pattern.
  `<Tab>`/`<S-Tab>`/`<C-h>`/`<C-l>` stay bound everywhere for pane
  cycling; `A`/`D`/`M` stay bound everywhere so accept / deny /
  request-change work from any pane.

- **Line numbers + cursorline on the diff panes.** Set on middle and
  preview after open. The left list pane keeps cursorline but no
  line numbers (it's a selection list, not file content).

- **Auto-close when the queue drains.** After the last entry is
  resolved through any path (A, D, M, native split save/close, or
  `close_tab` from the agent side), the panel closes itself via the
  `auto-agents:diff_removed` event subscriber. Re-opens if a new
  diff arrives via the existing `openDiff` → `M.open()` schedule.

### Added (resolution actions)

- **`M` — REQUEST CHANGE with free-form user feedback to the agent.**
  Prompts via `vim.ui.input({ prompt = "REQUEST CHANGE: " })`,
  rejects the diff with the typed reason as the `DIFF_REJECTED`
  `content[2].text`, AND injects `"REQUEST CHANGE: <reason>"` into
  the owning agent's terminal as a follow-up user prompt. Two
  channels deliberately: Claude Code's CLI currently drops
  `content[2]` from rejected `openDiff` replies and surfaces only
  a generic boilerplate to the agent, so the terminal-injection
  channel is what actually conveys the reason today. Channel 1 is
  future-proof against upstream forwarding `content[2]`. Slot
  resolution: `slot_for_name(req.agent_name)` → fall back to
  `state.focused_slot`.

- **`E` — in-pane edit mode on the preview pane.** Toggles
  `vim.bo[preview_buf].modifiable`, focuses preview, enters insert.
  A `TextChanged` / `TextChangedI` autocmd captures the user's
  edits into `_edits_by_id[req.id]`; switching to another entry
  (`j`/`k`/digit) and back restores the in-progress edits exactly
  as they were. `A` reads from `_edits_by_id[req.id]` if set so
  the agent receives `FILE_SAVED` with the user's tweaks via the
  standard protocol — no editing-side changes to the resolution
  shape. `<CR>` still opens the full native split for substantial
  edits (full editor width, real LSP attachment); `E` is the right
  tool for typo fixes and comment tweaks where opening a full
  split feels heavy.

- **`vim.notify` on `E` toggle** — enter and exit each fire a
  discreet info-level toast via the user's notification handler
  (snacks / noice / nvim-notify). Enter message documents the
  "press A to save" affordance so the user sees what to do next.

### Added (new APIs)

- **`auto-agents.send_slot(slot, text, opts)`** — new `opts.submit
  = true` follows the body with a deferred carriage return after
  `opts.submit_delay_ms` (default 60ms). The split prevents TUIs
  from treating `body .. "\r"` as a paste and swallowing the CR
  (Claude Code in particular). Mirrors the recipe `auto-agents.term.send`
  uses for the playground T1..T4 terminals. Default behavior
  (`opts.submit = false`) unchanged.

- **`auto-agents.slot_for_name(name)`** — public bootstrap-name →
  slot lookup. Returns nil for unknown / nil / empty input.

- **`auto-agents.diff.queue.reject(id, reason?)`** — accepts an
  optional user-supplied reason. nil / empty falls back to the
  existing default `"User rejected the diff."` so legacy callers
  are unaffected.

- **`auto-agents.diff.queue.find_by_tab_name(tab_name)`** — used
  by the `close_tab` MCP tool to look up a pending queue entry by
  the originating `openDiff` tab name.

### Added (highlighting)

- **Treesitter on both diff panes for viewing.** `update_preview`
  detects filetype from `req.file_path` (lifted helper from
  `mcp/ws-server/diff.lua`) and calls `vim.treesitter.start(buf,
  ft)` explicitly (pcall'd; missing parsers degrade silently to
  classic regex syntax). Distinguishes function names from
  variables, handles nested languages, accurate on unusual
  constructs — strictly better than classic syntax for a small
  diff-review pane.

### Tests

194 assertions across four headless drivers — full pass:

- `tests/smoke.lua` — 95 (+10 vs v0.2.2): adds `[14]` `send_slot`
  `opts.submit` body-then-deferred-CR split and `[15]`
  `slot_for_name` bootstrap lookup.
- `tests/diff_queue_spec.lua` — 23 (+12): `find_by_tab_name`,
  end-to-end `close_tab` reject, `reject(id, reason)` payload.
- `tests/diff_ui_spec.lua` — 73 (new): motions / numbers /
  cursorline; left-only selection keymaps; A/D/M everywhere;
  auto-close on drain; treesitter wiring; E toggle + edit cache +
  Accept-with-edits + notify.
- `tests/adapter_codex_spec.lua` — 3 (unchanged).

### Notes for upstream

- `_auto_agents_name` is referenced in both `open_diff` handlers
  (mcp/ws-server and agent/adapters) but not currently injected by
  the MCP bridge, so the `slot_for_name(req.agent_name)` lookup in
  the M handler misses and `state.focused_slot` is what carries
  single-agent setups. Wiring per-connection identity into the
  bridge is a separate follow-up.
- `openDiff`'s `DIFF_REJECTED` `content[2]` drop is a Claude Code
  CLI behavior we cannot change from the editor side. Channel 1
  (the protocol response) is correct on the wire and starts
  delivering value the moment upstream forwards `content[2]`.

## [v0.2.2] — 2026-05-11 — coding KB seed: revert to shared/ + code-review convention

Course-correction for v0.2.1's `wiki/` + `projects/` coding-KB layout.
After live use the new schema's higher overhead (more bins to
disambiguate, three frontmatter shapes, four-file schema contract,
self-inconsistency around `projects/` being "mutable state" while
hosting binding code rules) outweighed the structural payoff. New
coding KBs now scaffold the original `shared/`-based layout, with one
addition codified from production use.

### Changed

- **`kb-seeds/coding.md`** — canonical schema reverted to
  `shared/{conventions,adrs,playbooks,glossary,sources,synthesis}` +
  `raw/{specs,issues,transcripts}` + `agents/<name>/{tasks,reviews,scratch}`.
- **`lua/auto-agents/kb/types.lua`** — `coding` LAYOUT now uses
  `shared_subdirs` + `extra_dirs = { "_templates", "archive" }`.
  Dropped `wiki_subdirs` / `project_subdirs` (no other type used
  them); `layout()` simplified accordingly.
- **`lua/auto-agents/kb/init.lua`** — header comment + `raw/README.md`
  scaffold text updated to reflect the unified shared/ skeleton across
  all types.

### Added (new convention)

- **Hard Rule #4 / "Review a PR" workflow** in the coding seed now
  designates `agents/<reviewer-name>/reviews/` as the **canonical**
  home for code reviews (drafts AND finals), attributed to the
  reviewing agent. Filename pattern:
  `YYYY-MM-DD-<repo>-<branch>-pr<N>-review.md`. Reviews stay reviewer
  perspective; generalizable findings get promoted into
  `shared/conventions/` or new `shared/adrs/` as separate changes.
  `log.md` line format: `review | <reviewer> | <repo>#<pr>`.

### Fixed

- **`tests/smoke.lua`** — rtp prepends updated to the bare-clone
  worktree paths (`<plugin>/main/`) so smoke runs cleanly after the
  per-feature-worktree migration. 84/85 pass (1 pre-existing
  unrelated slot-DSL assertion failure).

## [v0.2.0] — 2026-05-10 — auto-core consumer

First release on top of [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
(`^0.1.0`). Per ADR 0006, the cross-cutting plumbing — log, state,
panel, ghost-buffer float, task-status — moves into `auto-core` so
the AutoVim family observes auto-agents transitions through one
canonical surface.

### Added

- **Hard dependency on `auto-core ^0.1.0`** — installed as a sibling
  via lazy.nvim. All four migration steps live behind it.
- **`auto-agents.logger`** — thin compatibility shim over
  `auto-core.log`. Preserves the `(component, ...)` signature; emits
  with format `[AutoCore] [auto-agents.<component>] [LEVEL] msg`.
  All 26 internal call sites kept their existing shape.
- **`auto-agents.state`** — wrapper over
  `auto-core.state.namespace("auto-agents", { persist = "json" })`.
  Typed setters + watchers for `panel.slot_count`,
  `panel.width_override`, and `focused_slot`. **`focused_slot` now
  persists across nvim restarts** (new behavior — was ephemeral
  before).
- **Canonical task-status mirror** — `M._sync_core_status(slot, state)`
  writes per-agent state into `auto-core.tasks.status`, keyed by
  agent name. Slot 0 (admin) and nameless rows are skipped.
  `:AutoCoreChannel` and other family plugins observe auto-agents
  transitions through that shared surface.

### Changed

- **Panel host → `auto-core.ui.panel` singleton.** `M._panel = panel_mod.new(…)`
  owns the vsplit lifecycle (open / close / toggle / focus / resize /
  pin / winfixwidth / winfixbuf / orphan adoption / scratch placement /
  `VimResized` + `WinResized`). Marker `auto_agents_panel` derives
  identically from auto-core's `[^%w_]` → `_` rule (compat preserved);
  also stamps the universal `w:auto_core_panel_name` for the winbar
  click router.
- **Ghost-buffer float → `auto-core.ui.float.ghost`.** The diff-parity
  helper (`_ghost_buffer_then_focus_agent`) lifts ~25 lines of inline
  `nvim_open_win` to a single auto-core call. auto-agents keeps the
  no-op key wiring on the ghost buffer (`<CR>` / `<Space>` / `y` / `n`
  / `q` / `:`) and the deferred restore-and-refocus side-effects.
- **Panel state out of TOML.** `slot_count` / `width_override` /
  `focused_slot` move out of TOML and into `auto-core.state.namespace`
  JSON persist. TOML save strips them so legacy writes no longer race
  with the namespace.

### Fixed

- **Editor-window-floor regression** when the auto-core leak guard
  bounced the new sibling created by `:leftabove vnew` from inside
  the panel (the new window briefly displayed the panel's
  buffer-owner-marked buffer, the guard closed the new window, the
  fresh buffer landed back in the panel, and the materialized
  "scratch" winid was actually the panel itself). Fix: wrap the split
  in `eventignore="all"` in `editor_floor.materialize_editor_scratch`
  so the guard's `WinEnter`/`BufWinEnter` doesn't fire during the
  transient state. Smoke 85/0 (was 83/2 post-migration).

### Not migrated (deliberate)

- **`panel/winbar.lua`** keeps its sigil rendering (`*` waiting / `+`
  working with per-sigil highlights), adaptive compact mode, and
  click router. auto-core's `ui.winbar` doesn't expose a sigil
  callback or per-section highlight injection — a 1:1 swap would
  lose fidelity. Filed for a future auto-core enhancement.
- **`help.lua` popup** keeps its markdown-rendering popup;
  auto-core's `help_overlay` doesn't expose the
  filetype/wrap/conceallevel knobs the markdown content needs.
- **Section registry** stays auto-agents-specific — the slot model
  isn't a clean fit for auto-core's `ui.section`.

### Migration notes

- Update your lazy.nvim spec to depend on `auto-core.nvim`:
  ```lua
  {
    "yongjohnlee80/auto-agents.nvim",
    dependencies = {
      "yongjohnlee80/auto-core.nvim",
      "nvim-lua/plenary.nvim",
    },
  }
  ```
- No public API renames. Existing `aa.setup({...})`,
  `aa.open(force)`, `aa.toggle()`, `aa.focus_slot(n)`,
  `aa.set_status(slot, state)`, the admin REPL verbs, and the
  `[%d:n]` keymap surface all keep their shape.
- TOML configs stay valid — legacy `panel.slot_count` /
  `panel.width_override` values are auto-seeded into the namespace on
  first open, then stripped from subsequent saves.

## [v0.1.24] — editor-window-floor invariant + flat slot model

(See git tag `v0.1.24` and prior tags for the pre-auto-core
iteration history.)
