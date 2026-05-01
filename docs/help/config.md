# config — TOML inspection + persistence

`config` deals with the **active** TOML file. Use `project init` /
`project remove` to switch *which* file is active; use `config save` /
`config show` to interact with whatever's already there.

## save

```
config save
```

Writes the live in-memory `[[agents]]` and `[kb]` to the active TOML.
Wizards already call this on completion — `config save` is for the
case where you've mutated state programmatically (or via lua) and
want to flush.

**Affects:**
- Filesystem: rewrites the active TOML.
- In-memory: `state.config_source` updates to `project` or `global`
  depending on which file got written.

## reset

```
config reset
```

Alias for `project remove` — deletes the per-project TOML, falling
back to global. KB on disk is preserved. Provided as `config reset`
because the verb evolved out of the original JSON-persistence reset.
Prefer `project remove` for clarity.

## show

```
config show
```

Prints:

- `config_source` — `project` / `global` / `none`
- `active_target` + path — which file `save` would write to
- both `project_path` and `global_path` so you can see all candidates
- session cwd + project root cache values
- panel resolution numbers (percentage, min/max width, side)
- log level

Useful sanity check when "agents aren't loading" or "wizard saved to
the wrong file."

## path

```
config path
```

Just the active TOML path, one line. Convenient for `xclip` or for
opening it with `:edit` outside the admin.

## How config operations interact with the rest of the system

- **Project boundary**: `config save` follows `active_path()` —
  always writes to the per-project file if it exists, else global.
  `project init` creates the per-project file; `project remove`
  deletes it; both flip what `config save` targets.
- **Wizard mutations**: `agent add/edit/move/rename`, `kb scope`, and
  `kb init` all call the same `config.store.save_current()`. So you
  rarely need `config save` directly — it's a fallback.
- **Session cwd cache**: every config command uses
  `state.session_project_key`, cached at startup. `:cd` doesn't
  change which TOML you write to.
