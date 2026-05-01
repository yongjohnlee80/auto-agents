# resource — per-slot grants and manager designation

Resources are coordination metadata — paths, cwd overrides, and
manager relationships — that propagate to an agent's spawn as env
vars. **Best-effort coordination, not OS-level sandboxing.** The agent
has to honor them; we don't enforce them.

Stored in `<stdpath('data')>/auto-agents/<sha16>-grants.json`,
separate from the TOML config. Survives nvim restarts. Tied to the
session's project key, not to live cwd.

## grant

```
resource grant <N> <path>
```

Grants a path to slot `N`. Multiple grants per slot are allowed —
they accumulate. Path is expanded (`~`/`$VAR`) and stored as written.

**Affects:**
- Adds the path to slot `N`'s `$AUTO_AGENTS_ALLOWED_PATHS` env at
  next spawn (colon-separated).
- Persisted to the grants JSON immediately.
- Running agent does **not** see the new grant — restart to apply.

## revoke

```
resource revoke <N> <path>
```

Removes a previously-granted path. Exact match — if you granted
`~/foo` and try to revoke `/home/you/foo`, it won't match unless the
expanded forms are identical. Use `resource list` to see what's
actually stored.

## cwd

```
resource cwd <N>                     # clear explicit cwd
resource cwd <N> <path>              # set explicit cwd
```

Sets (or clears) an explicit working directory for slot `N`. Takes
priority over the agent's `cwd` in the TOML and over the
session-default `cwd.resolve()`.

**Affects:**
- `$AUTO_AGENTS_CWD` env var at next spawn.
- The actual `cwd` passed to `termopen` (it's the resolved spawn dir).
- Persisted to grants JSON.

## list

```
resource list                         # all slots
resource list <N>                     # one slot
```

Shows every grant for the requested scope, grouped by slot then kind
(path / cwd / env / cmd). Useful for auditing what a slot can see.

## manager

```
resource manager set <S> <M>         # slot M manages slot S
resource manager set <S> none        # clear designation
resource manager show                # print manager → subordinate map
```

Records a manager relationship. **Metadata only for v0.1.0** — the
data model is in place, but no automated routing happens yet. Useful
for documentation; future versions will route grant requests and
inter-agent messages through the manager.

**Affects:**
- Persisted to grants JSON.
- Exposed as `$AUTO_AGENTS_MANAGER_SLOT` for the subordinate at spawn.

## How resource operations interact with the rest of the system

- **Spawn-time env**: every grant becomes an env var at spawn. Look
  for `$AUTO_AGENTS_ALLOWED_PATHS`, `$AUTO_AGENTS_CWD`,
  `$AUTO_AGENTS_MANAGER_SLOT` in the agent's environment.
- **Honor system**: agents read these env vars and self-restrict.
  Nothing prevents an agent from touching a non-granted path. Use
  this for prompt-shaping ("only touch these paths"), not for
  security boundaries.
- **Project**: grants are keyed by `sha16(session_project_root)` —
  same key as the TOML. `project remove` doesn't delete grants;
  they're stored under the same key and reappear if you re-init.
- **Agents**: `agent kill/restart` does not touch grants. `agent
  rename` does not migrate the per-slot mapping (the grants stay
  attached to the slot number, not the name).
