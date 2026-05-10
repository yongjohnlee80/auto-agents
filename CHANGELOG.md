# Changelog

All notable changes to `auto-agents.nvim` are documented here.

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
