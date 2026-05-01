# general — top-level standalone verbs

A handful of admin verbs aren't subverbs of anything else.

## status

```
status
```

Lists every slot 0..9 with: focus marker (`→`), label (kind/name/title
or `(empty → shell)`), where it lives (`admin`/`main`/`float`), run
state (`running`/`-`/`active` for admin), and any open task count.

Same output as `agent list`.

**Affects:** read-only.

## clear

```
clear
```

Wipes every line above the prompt — admin scrollback only. Doesn't
touch the prompt input, doesn't kill agents, doesn't change config.

## quit

```
quit
```

Closes the auto-agents panel window. Agent terminals **stay alive** —
processes persist; the window is just hidden. Reopen with `:AutoAgents`
or `<F5>`.

## help / ?

```
help                         # top-level index
? <verb> [<sub>]             # contextual help
<verb> ?                     # same as 'help <verb>'
<verb> <sub> ?               # same as 'help <verb> <sub>'
help open <verb> [<sub>]     # open the help md in the editor
```

Help is loaded from `docs/help/*.md` shipped with the plugin. `help
open` opens the file for browsing or editing — your edits persist.

## How these interact with the rest of the system

- **No state changes** — `status` / `help` / `clear` are read-only.
- `quit` only hides the window. `agent kill <N>` is the way to stop
  an actual process.
