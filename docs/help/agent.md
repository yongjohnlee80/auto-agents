# agent — slot operations

The `agent` verb manages everything tied to a single slot in the panel:
its config, its running terminal, its task list, its placement.

Slots are partitioned: slot **0** is the admin REPL (this prompt), slots
**1–5** are the main right-window panel (one window, swapped buffers),
slots **6–9** are sub-agent floats. The admin wizard, the TOML store,
and the navigation dock all share the same numbering.

## focus

```
agent focus <N>          # alias of :AutoAgentsFocus N and <leader>aN
```

Focuses slot `N`. Routes 0–5 to the main window, 6–9 to a snacks float.
For 1–5, also resends a SIGWINCH to the underlying TUI (with the slot's
`bottom_margin` reserved) so the TUI redraws cleanly at the panel's
current dimensions.

**Affects:** `state.focused_slot` (used to restore on panel reopen).
**Does not** spawn the agent — focusing an unconfigured slot drops you
into a fallback `$SHELL`.

## list

```
agent list
```

Same output as `status`. Shows every slot 0..9 with its label, where
it lives (admin / main / float), its run state, and any open task count.

## add

```
agent add                # opens the wizard inside this admin buffer
```

Step-by-step wizard. Each step shows `[default]` — Enter to keep it,
type to change, **`<C-c>` to abort**. The final step asks for a KB type
(coding | wiki | research | ops | general | custom | none).

**Affects:**
- Writes a new `[[agents]]` block to the active TOML
  (per-project if one exists, else global).
- If a KB type is picked, scaffolds the KB layout under
  `<kb_root>` with the chosen seed copied to `<kb_root>/AGENTS.md`.
- Refreshes `<leader>aN` keymap descriptions (so which-key reflects
  the new slot label).
- Triggers `focus_slot(N)` after save.

## edit

```
agent edit <N>           # wizard pre-fills every field with the current value
```

Same wizard as `add`, but every default is the existing entry's value.
Press Enter on every step to keep everything; only changed fields are
re-written.

**Affects:** rewrites that slot's `[[agents]]` block in the active TOML.
Does **not** restart the running terminal — most fields take effect on
next spawn (use `agent restart <N>` to apply immediately). Renames also
update `<leader>aN` descriptions live.

## kill

```
agent kill <N>
```

Stops the running terminal in slot `N`. Main slots (1–5): `jobstop` +
buffer wipe; sub-floats (6–9): close the snacks float. Bootstrap entry
is **not** removed — the agent reappears (unspawned) the next time you
focus the slot. Use `agent edit` then leave kind/name blank to remove
the bootstrap entry, or hand-edit the TOML.

**Affects:** running process is terminated. KB instruction files left
intact; resource grants left intact.

## restart

```
agent restart <N>
```

`kill` followed by `focus` — the slot respawns with the current TOML
config. Use this after `agent edit` to apply config changes
immediately.

## rename

```
agent rename <N> <new-name>
```

Renames the bootstrap entry's `name` field in-place. Live: the winbar
and `<leader>aN` description update without a restart. The KB scope
directory under `kb/agents/<name>/` does **not** auto-migrate — if the
agent has private/isolated KB content, move it manually if you care.

**Affects:** TOML is saved; in-memory state updated; keymap descriptions
refreshed.

## send

```
agent send <N> <text...>
```

Writes `<text>` to the agent's stdin via `nvim_chan_send`. No
interpretation — one shot, no submit byte added. For a paste-safe
prompt that ends with Enter, prefer `term send` (for T1..T4) or send
the text manually via the slot's terminal.

**Affects:** purely runtime. Useful for scripted dispatch from the
admin or programmatic from another agent.

## attach

```
agent attach <N> [<path1> <path2> …]
```

Sends file paths to slot `N`'s stdin. With no path args, queries the
active tree explorer (neo-tree, oil, mini.files, netrw, nvim-tree) for
the current selection / cursor target.

**Affects:** runtime stdin. The agent receives a space-separated list
of absolute paths it can choose to read.

## move

```
agent move <from> <to> [--swap]
```

Relocates a slot's bootstrap entry (and running terminal, when both
sides have one). Same-side only — main↔float crossings require a kill
+ re-add through the wizard. With `--swap`, exchanges contents.

**Affects:** TOML is rewritten with the new slot numbers. Winbar +
keymap descriptions refresh. `state.focused_slot` follows the move.

## task

```
agent task add <N> <text>
agent task done <N> <index>
agent task list [<N>]
```

A lightweight per-slot task list, stored in the TOML's `[[agents]]`
entry as `tasks = [...]`. `done` removes the task by 1-based index.
List with no slot shows every slot's tasks.

**Affects:** TOML is saved on each mutation. Tasks are visible via
`status` (suffix `[N tasks]`). They're informational — agents read
them when you tell them to.

## mem

```
agent mem
```

Reports RSS per running agent (Linux `/proc` only — silently empty on
other platforms). Useful for spotting runaways. Shows total at the
bottom.

## How agent operations interact with the rest of the system

- **Project**: `agent add/edit/move/rename` writes to the **active**
  TOML — that's the per-project file if `project init` was run, else
  the global default. `project remove` falls back to global; agents
  added before `init` "promote" to project on next save.
- **KB**: Each agent has a `kb_scope` (shared|private|isolated) which
  controls the env vars at spawn (`$AUTO_AGENTS_KB_{ROOT,READ,WRITE}`).
  KB type is project-wide (`[kb].type` in TOML). The instruction file
  at the agent's cwd (`CLAUDE.md`/`AGENTS.md`/`GEMINI.md`) points at
  `<kb_root>/AGENTS.md` for the schema.
- **Resources**: Per-slot grants (`resource grant N <path>`) and cwd
  overrides land in the spawn's env. Relevant during fresh spawn or
  `restart`, not applied to a running terminal.
- **Manager designation**: `resource manager set <S> <M>` records that
  slot `M` manages slot `S`; metadata only for v0.1.0.
