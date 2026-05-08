# panel — sidebar width control

The agent panel's column width is normally derived from
`panel.percentage * vim.o.columns`, clamped to
`[panel.min_width, panel.max_width]` (defaults: 35%, 60..130). On
re-resize (`VimResized`), the width is recomputed from the same
formula and every running TUI gets a fresh SIGWINCH so its draw
matches the new dims.

This subsystem lets you **pin** the panel to a fixed column count for
the active session — useful when the percentage formula picks a width
you don't like on a particular monitor, or when you want the panel
narrower / wider than `min_width` / `max_width` allow.

The override lives in the active TOML's `[panel]` section
(per-project file if present, else `global.toml`) so it survives
nvim restarts and is scoped to where the rest of your project config
lives.

## resize

```
panel resize           → wizard
panel resize <N>       → set directly, no wizard
```

Pin the panel to `<N>` columns. Allowed range: **25..160**. The wizard
form pre-fills the input with the current override (or, if none, the
currently-resolved effective width) so pressing Enter keeps what's on
screen now.

**Affects:**
- `cfg.panel.width_override` is mutated in memory.
- Active TOML is rewritten with a `[panel]` section (or just
  `width_override` row).
- The open panel window is immediately resized; every running main-slot
  TUI gets a SIGWINCH at the new width.

## reset

```
panel reset
```

Clears the override. The panel reverts to the
percentage/min/max formula at the next resize event (and immediately
for the open panel). The `width_override` row is dropped from the
TOML; if no other `[panel]` keys are present, the section is removed
entirely.

## show

```
panel show
```

Print the current effective width, the override (or `<none>`), the
percentage / min / max parameters, and the allowed range for `resize`.

## See also

- `config show` — also surfaces `panel.width_override` alongside the
  other panel keys.
- `config save` — already implicit on `panel resize` / `panel reset`,
  so you don't have to call it.
- `:AutoAgents` to (re-)open the panel after edits — the resize is
  applied live, no restart required.
