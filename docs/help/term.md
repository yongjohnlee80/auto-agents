# term — playground terminals (T1..T4)

T1..T4 are **shared playground terminals** — floating shells that the
human and any agent can both use. They're separate from agent slots
(0–9): not tied to the panel, not tied to the TOML, no kb_scope, no
bootstrap config. Just four persistent floats keyed by slot number.

Mapped to `<F1>..<F4>` by default. Press the F-key to focus (or open
if not yet alive); press it again while focused to hide. Moving focus
into any non-float window auto-hides every T1..T4 float at once.

The terminals **persist across `:cd`**. We mark each buffer with
`b:auto_agents_term_slot` so a worktree change doesn't re-hash the
snacks key and spawn a duplicate — your interactive `python` or `npm
run dev` stays alive across directory hops.

## focus

```
term focus <N>           # alias of <FN>
```

Open-or-focus-or-hide dispatch. State machine:

| Current state                    | Effect              |
|----------------------------------|---------------------|
| Slot N has no terminal yet       | Create + focus      |
| Slot N hidden                    | Show + focus        |
| Slot N visible, not focused      | Move focus to it    |
| Slot N visible, focused          | Hide                |

Other T-floats are **not** disturbed — only the targeted slot moves.

## send

```
term send <N> <text...>
```

Paste-safe stdin write. Splits the body and the `\r` (submit byte)
across a 60ms defer so TUIs (codex, claude, prompt-toolkit, ratatui)
classify the body as paste and the `\r` as a real keypress. Without
the split, the trailing CR gets eaten as part of the paste event and
the prompt isn't submitted.

If the slot has no terminal yet, one is opened first.

**Pass `submit=false`** programmatically (`require("auto-agents.term")
.send(slot, text, { submit = false })`) to send the body without the
trailing CR — useful for staging a prompt the user will edit before
hitting Enter.

**Affects:** runtime stdin only. Useful for agents driving a build
tool, REPL, or scratch shell.

## list

```
term list
```

Shows every T-slot with its run state, current visibility, and the
buffer number. Useful for debugging "why isn't F2 working" type
issues.

## kill

```
term kill <N>
```

Closes T`N` and wipes its buffer. Next `term focus N` creates a fresh
shell. Kill is destructive — anything running in that terminal is
SIGTERM'd.

## hide

```
term hide
```

Hides every visible T1..T4 float without killing them. Same effect as
moving focus into the editor (which the WinEnter autocmd does
automatically). Useful from a keymap when you want explicit control.

## How term operations interact with the rest of the system

- **Independent of agent slots**: T1..T4 don't appear in `status`,
  don't have a kb_scope, don't get an instruction file written to
  their cwd. They're just shells.
- **Independent of TOML**: T-config doesn't persist — these are
  ephemeral playground shells, not configured agents. After nvim
  restart, F1..F4 spawn fresh shells.
- **Persist across `:cd`**: marker-based lookup ignores cwd, so the
  same `T1` follows you across worktree changes.
- **Auto-hide on editor focus**: `WinEnter` on any non-float window
  hides every T-float (scoped — won't fight lazygit/lazysql or other
  snacks consumers; only T1..T4 with our marker are touched). Agent
  floats (slots 6–9) have their own auto-hide and are not affected.
- **Agents can drive them**: `term send <N> <text>` is callable from
  the admin DSL, the `:AutoAgentsTermSend` user cmd, and via
  `require("auto-agents.term").send(slot, text)` from any lua. An
  agent in slot 1 can dispatch a build command to T2 without leaving
  its panel.
