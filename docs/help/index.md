# auto-agents — admin help

Slot 0 is an interactive REPL. Type a verb at the prompt and press Enter.
Append `help` (or `?`) to any verb to see this help. `help open <verb>`
opens the help file in the editor for browsing or hand-editing.

## Top-level verbs

| Verb        | Purpose                                                |
|-------------|--------------------------------------------------------|
| `agent`     | Manage agent slots (focus, add, edit, kill, send, …)   |
| `kb`        | Knowledge-base — init, sync, scope, file ops           |
| `project`   | Per-project config (init/import/remove/list/show)      |
| `resource`  | Per-slot grants (paths, cwd, manager designation)      |
| `term`      | Playground terminals T1..T4 (shared user/agent shells) |
| `config`    | Inspect / save / reset the active TOML                 |
| `panel`     | Pin / clear / inspect the panel column width           |
| `status`    | Slot state at a glance                                 |
| `help`, `?` | This help (or `<verb> help` for command-specific docs) |
| `clear`     | Wipe history above the prompt                          |
| `quit`      | Close the auto-agents panel                            |

## Reading help in the editor

`help open <verb>` opens the underlying markdown file in a non-panel
window so you can browse, search, or edit it. Edits persist — these are
real markdown files shipped with the plugin.

## Navigation shortcuts

- Inside admin (slot 0), normal-mode `0`–`9` focuses that slot.
- `<C-c>` aborts an active wizard (`agent add`, `agent edit`, `kb scope`,
  `project import`, etc.) at any step.
- `<F5>` toggles the panel from anywhere.
- `<F6>` / `<F12>` opens the navigation dock for one-key slot dispatch.

## See also

- `agent help` — agent slot operations + the admin wizard
- `kb help` — KB types, scopes, sync, instruction files
- `project help` — TOML resolution, init/import/remove
- `term help` — playground terminals, focus behavior, paste-safe send
- `panel help` — pinning the panel column width via `panel resize` / `panel reset` / `panel show`
