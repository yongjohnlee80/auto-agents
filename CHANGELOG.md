# Changelog

All notable changes to `auto-agents.nvim` are documented here.

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
