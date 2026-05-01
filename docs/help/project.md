# project — TOML config lifecycle

Auto-agents resolves its agents and KB from TOML files under
`<stdpath('config')>/.auto-agents-config/`:

- `<sha16-of-project-root>.toml` — per-project (wins if it exists).
- `global.toml` — default for any project without its own.

The session caches the project key at nvim startup (`sha16(git_root ||
cwd)`). `:cd` does **not** move the project boundary mid-session —
your agents and KB stay tied to the directory you opened nvim from.

## init

```
project init
```

Creates a fresh per-project TOML for the cached cwd. Refuses if one
already exists (`project remove` first). After init the file is
**empty** — no agents, no KB section. Run `agent add` to populate it
(or `project import` to copy from another project).

**Affects:**
- Writes `<stdpath('config')>/.auto-agents-config/<sha16>.toml`.
- Reloads in-memory state — `state.config_source` flips to `project`.
- If the wizard auto-engages (zero agents loaded), it'll prompt you
  through `agent add`.

## import

```
project import                       # list candidates, pick one
project import <key|path|cwd>        # power-user form
```

Copies `[[agents]]` from another project's TOML into the current
project. **Shares the source's `[kb].root`** verbatim — useful when
you have the same project mirrored at multiple paths (a clone, a
worktree, a sibling repo) and want a single shared KB rather than
fragmenting notes.

Refuses if the current project already has a config (`project remove`
first if you really mean it).

**Affects:**
- Writes the per-project TOML for the cached cwd.
- KB on disk is **not** copied — both projects point at the same root.
- In-memory agents reload from the new file.
- `<leader>aN` keymap descriptions refresh.

## remove

```
project remove
```

Deletes the per-project TOML for the cached cwd. KB on disk is
**preserved** — clean it up manually if you want. After remove, the
session falls back to whatever `global.toml` provides (or `none` if
neither exists).

**Affects:**
- Filesystem: removes one TOML file.
- In-memory state reloads — `state.config_source` becomes `global` or
  `none`.
- Agents currently running keep running; their bootstrap definitions
  are gone, so the next `restart` won't have a config to spawn from.

## list

```
project list
```

Shows every TOML in the config dir with the recorded `[project].cwd`
and which one is active for the current session. Sorted alphabetically
with the active session marked `← active`.

## show

```
project show
```

Prints the active resolution: source (`project`/`global`/`none`),
cached `session_cwd` and `session_project_root`, and both
`project_path` and `global_path` so you can see which file is in play.

## How project commands interact with the rest of the system

- **TOML store**: `project init/import/remove` are the only commands
  that change which file is "active." Wizard mutations
  (`agent add/edit/move/rename`) and `config save` always write to
  whichever file is active *at that moment*.
- **KB**: `project import` shares the source's KB root, but doesn't
  copy KB content. `project remove` leaves the KB on disk. KB types
  travel with the project TOML (`[kb].type`).
- **Resources**: per-slot grants live in a separate JSON file
  (`<stdpath('data')>/auto-agents/<key>-grants.json`). `project
  remove` does not delete grants — they sit unused under the same key
  until you re-init or hand-clean.
- **Session boundary**: the project key is cached at startup. If you
  `project init` mid-session, the cache doesn't change — the new file
  becomes the active one for the same key.
