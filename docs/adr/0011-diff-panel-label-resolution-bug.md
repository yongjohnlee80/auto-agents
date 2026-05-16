---
type: adr
number: 0011
status: proposed
date: 2026-05-16
---

# ADR 0011 — Diff Panel Label Resolution: Repo Column + Agent Attribution

## Context

The Pending Diffs panel — introduced in v0.2.6 with "meaningful left-column
labels" (commit 518e1ca) — renders each queued diff as
`[N] {repo}/{filename} [{agent}]`. In current main (caa3fa5 / v0.2.10) the
panel ships two visible regressions, observed by the user on a live diff for
the KB `log.md`:

```
Pending Diffs (1)
▶ [1] Projects/log.md [?]
```

Both columns fail in the same direction: they collapse to a *generic ancestor*
or a sentinel placeholder instead of resolving to the file's actual repo and
the diff's actual originating agent. The cosmetic damage is small; the
information loss matters because the panel is a multi-agent triage view, and
the user needs both signals to decide "is this the diff I expected to see, and
from whom?"

The site of both bugs is `lua/auto-agents/diff/ui.lua:271-296` (the
`render_left` function) plus the upstream enqueue paths that populate
`req.agent_name`.

## Findings

### Bug 1 — repo column resolves to `"Projects"`

Source: `lua/auto-agents/diff/ui.lua:277-286`

```lua
local fs_path_ok, fs_path = pcall(require, "auto-core.fs.path")
local function wt_for(path)
  if fs_path_ok and type(fs_path.workspace_root) == "function" then
    local root = fs_path.workspace_root(path)         -- (1) positional call
    if type(root) == "string" and root ~= "" then
      return vim.fn.fnamemodify(root, ":t")
    end
  end
  return vim.fn.fnamemodify(path, ":h:t")
end
```

Two layered defects, each independently sufficient to produce the symptom:

1. **API misuse — positional vs. options table.**
   `auto-core.fs.path.workspace_root` takes `opts = { start = path }`, not a
   bare path string (see `auto-core.nvim/main/lua/auto-core/fs/path.lua:223`).
   When called positionally with a string, `opts = opts or {}` keeps the
   string; `opts.start` resolves to nil; the function falls back to
   `vim.fn.getcwd()` — the **host nvim's** cwd, which has no relationship to
   `req.file_path`.

2. **Wrong resolver for the intended output.**
   `workspace_root` is documented as "*parent of* the nearest `.bare`/`.git`
   container" — its purpose is to surface the dev-floor parent that `.bare`
   sibling worktrees share, not the worktree itself. For
   `~/Source/Projects/nvim-plugins/auto-agents.nvim/main/lua/foo.lua` it
   returns `~/Source/Projects/nvim-plugins/auto-agents.nvim` (one level
   *above* the worktree). The `wt_for` doc-comment says "basename of the
   file's containing workspace (git worktree / project root)" — that is the
   `git_root` semantic, not `workspace_root`.

When both defects compound, the call chain for the observed `log.md` is:

| Step                                  | Value                                              |
|---------------------------------------|----------------------------------------------------|
| `workspace_root(path)` — string arg   | opts.start = nil → start = `getcwd()`              |
| host cwd                              | `~/Source/Projects/nvim-plugins`                   |
| `.bare` / `.git` walk-up              | nothing matches (`nvim-plugins` is a *container of* bare repos, not a repo itself; `Projects` / `Source` / `home` have no markers either) |
| `git_root` fallback                   | nil                                                |
| "last resort" branch                  | `parent(start)` = `~/Source/Projects`              |
| `:t`                                  | `"Projects"`                                       |

This exactly reproduces the user-visible string.

### Bug 2 — agent column resolves to `"?"`

Source: `lua/auto-agents/diff/ui.lua:291-293`

```lua
local agent = (type(req.agent_name) == "string"
               and req.agent_name ~= ""
               and req.agent_name ~= "agent") and req.agent_name or "?"
```

The display predicate is correct as a *defense* — `""` / `"agent"` are known
upstream placeholders that the panel should not advertise as real names. The
symptom means `req.agent_name` arrives in one of those degenerate states from
the queue. The dominant failure path on this user's setup is the **native
websocket MCP bridge** that Claude-backed agents (jarvis, ultron-prime,
white-vision) use, not the mailbox transport. The mailbox path is also
buggy, and the fix needs to address both together because they share a
common root: *attribution data is available at the boundary but not
plumbed through to the queue entry.*

#### 2a — Native websocket openDiff path (the dominant case)

Sites:
- `lua/auto-agents/mcp/server.lua:47-85` (boot, single shared port)
- `lua/auto-agents/mcp/ws-server/init.lua` (the JSON-RPC server)
- `lua/auto-agents/mcp/ws-server/tools/init.lua:80-131` (tool dispatch)
- `lua/auto-agents/mcp/ws-server/tools/open_diff.lua:73-78` (the handler)

Failure decomposes into three layered defects, each independently sufficient
to produce `[?]`:

**(i) One server, many slots, no per-slot port.**
`mcp.server.start()` returns a single port. `auto-agents/init.lua:461-473`
boots exactly one bridge when *any* slot has `diff_review = true`, and
`build_agent_env` (init.lua:673-686) hands the same port to every
diff-review-enabled slot via `CLAUDE_CODE_SSE_PORT`. The server therefore
has no way to know, from the listening port alone, which slot a given
incoming connection belongs to. In this user's `global.toml`, four slots
have `diff_review = true` — jarvis (slot 1, claude), lector (slot 2,
codex), wanda-maximoff (slot 4, junie), white-vision (slot 6, claude) —
so the ambiguity is the default state, not an edge case.

**(ii) The tool handler never sees the connection.**
`tools.handle_invoke(client, params)` (init.lua:80) receives the `client`
object — which exposes `tcp_handle` (a `vim.uv` socket from which
`tcp_getpeername` would yield the peer's source port and PID via
`/proc/net/tcp` + procfs) — but the dispatch loop strips it:

```lua
-- ws-server/tools/init.lua:103-105 (blocking branch)
local co = coroutine.create(function()
  return tool_data.handler(input)        -- input == params.arguments only
end)
-- ws-server/tools/init.lua:130 (non-blocking branch)
pcall_results = { pcall(tool_data.handler, input) }
```

Tool handlers are called with `params.arguments` and nothing else. Even if
per-slot connection identity were captured at accept-time on the `client`
struct, the openDiff handler cannot read it.

**(iii) The fallback resolver returns nil for this user's config.**
`open_diff.lua:73-78` falls through to `resolve_diff_agent_name(nil)`
(init.lua:1227-1242). That function scans the bootstrap roster for entries
with `diff_review = true` and:

| # of `diff_review = true` entries | return value | result        |
|-----------------------------------|--------------|---------------|
| exactly 1                         | the name     | works         |
| 0                                 | nil          | falls to `"?"`|
| 2 or more                         | nil          | falls to `"?"`|

For this user (4 matching entries), the resolver always returns nil. There
is no fallback that produces a sensible answer. CLI clients (Claude Code,
Codex CLI) do **not** inject `_auto_agents_name` into the openDiff payload —
that field is an auto-agents private extension, and stock clients have no
reason to populate it. So the chain is:

```
params._auto_agents_name = nil
→ resolve_diff_agent_name(nil) = nil  (ambiguous; 4 matches)
→ agent_name = nil or nil or "?" = "?"
→ enqueue(agent_name = "?")
→ panel render predicate passes "?" through (it's neither "" nor "agent")
→ display: [?]
```

So when jarvis writes a file and Claude Code sends openDiff over the native
websocket, the queue entry's `agent_name` is the literal string `"?"`. The
panel can't render a name it never received.

**Note on the symptom variant.** The exact value `"?"` (vs. `""`, `"agent"`,
or `nil`) is diagnostic — only the MCP openDiff paths produce this exact
literal. The mailbox path (2b) lands on `"nvim"` instead.

#### 2b — Mailbox `diff_queue` command path (latent; same root)

Site: `lua/auto-agents/mailbox/commands.lua:184-209`.

```lua
local from = ctx and ctx.mailbox or nil
if type(from) == "string" then
  agent_name = from:match("^agent:(.+)$") or from
end
```

The handler tries to derive the sender from `ctx.mailbox`. But
`auto-core/mailbox/router.lua:325-329` populates `ctx.mailbox` with the
**executor's** mailbox (`nvim`), not the **sender's**:

```lua
local response = commands.handle_message(claimed, {
  reason       = "mailbox_executioner",
  mailbox      = rec.bare_id,    -- rec is the executor (nvim), not the sender
  mailbox_full = rec.id,
})
```

`msg.from` (which holds the sender, e.g. `agent:jarvis`) is held by the
router but is **not** forwarded into the handler `ctx`. So
`from:match("^agent:(.+)$")` always fails on `"nvim"`, falls through to the
literal `"nvim"`, and the panel ends up labelling every mailbox-routed diff
as `[nvim]`. This path doesn't fire today because the claude-backed agents
use the websocket bridge — but it's a latent bug that would surface the
moment a peer switched transport, and the fix shape is the same as (2a):
*propagate the sender's identity rather than guessing*.

#### Common thread (Bug 2)

The boundary captures the sender's identity (connection-level for websocket,
`msg.from` for mailbox). The intermediate plumbing throws it away. The
handler then guesses from a bootstrap roster that only resolves cleanly in
the trivial one-agent case. The fix is to thread the sender's identity
through both transports so the handler doesn't have to guess.

### Common thread

Both bugs share a root: **information that is available at the source is
discarded before it reaches the panel.**

- The repo is derivable from `req.file_path`, but the resolver call discards
  the path (positional API misuse) and the chosen resolver returns the parent
  of the repo, not the repo itself.
- The sender's identity is on `msg.from` in the mailbox transport and on the
  MCP websocket connection's slot binding — but neither is forwarded into the
  queue entry. The handlers fall back to a brittle "guess from bootstrap
  roster" path that only works when the project has exactly one diff-review
  agent.

## Decision

Adopt three coordinated changes. Each is small in isolation; together they
make the panel labels load-bearing.

### D1 — Fix the repo resolver in `diff/ui.lua`

**Revised after review-round-1 (Lector finding #1):** the original draft
proposed `fs_path.git_root({ start = path })`, which returns the *worktree*
root — `fix-diff-panel`, `main`, `comms-1` — in this user's bare-worktree
layout. That's branch identity, not repo identity. The label needs to come
from the git **common dir**, not the worktree.

Two layouts to handle correctly:

| Layout                | `--git-common-dir` returns | Want                |
|-----------------------|----------------------------|---------------------|
| Bare repo + linked worktrees (`auto-agents.nvim/fix-diff-panel/...`) | `<...>/auto-agents.nvim/.git` (or the bare itself) | `auto-agents.nvim`  |
| Plain clone (`~/.config/nvim/.auto-agents-config/kb/log.md`)         | `<...>/kb/.git`                                    | `kb`                |
| Not in any git repo (`/tmp/foo.lua`)                                 | nil                                                | `<parent dir name>` |

Rule: `basename(parent(common_dir))` in both git cases. Auto-core already has
the right primitive: `auto-core.git.repo.common_dir(path)` (returns the
absolute common-dir or nil; `repo.lua` API documented at lines 12-22). For
the bare case it returns `<...>/auto-agents.nvim/.git`; for the plain case
`<...>/kb/.git`; for the inside-of-bare-without-dot-git case (where the bare
directory itself IS the common dir, e.g. `<...>/auto-agents.nvim`), `:h`
walks one level too far. Easy to disambiguate by checking the basename:

```lua
local function repo_for(path)
  local repo_ok, repo = pcall(require, "auto-core.git.repo")
  if repo_ok and type(repo.common_dir) == "function" then
    local cd = repo.common_dir(path)
    if type(cd) == "string" and cd ~= "" then
      local base = vim.fn.fnamemodify(cd, ":t")
      if base == ".git" or base == ".bare" then
        return vim.fn.fnamemodify(cd, ":h:t")
      end
      -- common_dir IS the bare directory (no .git/.bare subdir) — its
      -- own basename is the repo identity.
      return base
    end
  end
  -- Non-git fallback chain.
  local fs_path_ok, fs_path = pcall(require, "auto-core.fs.path")
  if fs_path_ok and type(fs_path.project_root) == "function" then
    local r = fs_path.project_root({ start = path })
    if type(r) == "string" and r ~= "" then
      return vim.fn.fnamemodify(r, ":t")
    end
  end
  return vim.fn.fnamemodify(path, ":h:t")
end
```

Also rename `wt_for` to `repo_for` to match the user's mental model — "which
repo is this file in?" rather than "which worktree?" The two coincide for
plain clones but diverge sharply for bare-worktree layouts.

**Note on `_derive_label` reuse.** `auto-core/git/graph.lua:95` already has a
private `_derive_label(common_dir, root)` doing essentially this computation
for the worktree-graph picker. If we end up needing the logic in a third
place (diff panel + worktree graph + ???), promote it to public API on
`auto-core.git.repo` rather than duplicating. For now, keep the inlined
version in `diff/ui.lua` — single caller, trivial body.

### D2 — Bind every websocket connection to its slot identity

This is the load-bearing fix; jarvis's panel entries are this path. Two
viable designs, neither as small as the first draft implied.

#### D2-A — Per-slot bridge

Replace `mcp.server.start()`'s single-port model with one server per
`diff_review`-enabled slot. Each slot's spawn-env (`build_agent_env`,
init.lua:673-686) points `CLAUDE_CODE_SSE_PORT` at *its* slot's port. The
ws-server captures `slot_name` at startup and stashes it on `M.state`.

**Honest scope (revised after review-round-1, Lector finding #2).** The
first draft framed this as a state-table change. It is not. Both
`auto-agents.mcp.server` and `auto-agents.mcp.ws-server` are *module
singletons*:

- `mcp/server.lua:48` — `if M.state.server then return M.state.port end`
- `ws-server/init.lua:35-37` — `if M.state.server then return false,
  "Server already running" end`
- `tools.setup(M)` (ws-server/init.lua:51) registers tools onto the single
  module-level server reference.
- `tcp_server.start_ping_timer(server, 30000)` (ws-server/init.lua:93)
  starts a singleton ping timer.
- `_G.claude_deferred_responses` (init.lua:114-117) is process-global, not
  per-server.

To get N independent servers, **both modules must become factories** that
return *instance objects*, each owning their own state. That includes:
the bound TCP server + clients map, the ping timer, the
`handlers`/`tools` registries, the deferred-response coroutine map (or a
keying scheme on it), the lockfile path, the auth token, the stop
semantics, AND every test that currently calls `ws.start()` /
`mcp.start()` expecting a singleton.

Concretely the change set is:

| File                                | Change                                                                  |
|-------------------------------------|-------------------------------------------------------------------------|
| `mcp/server.lua`                    | `M.new(slot_name)` factory; `M.start_instance(inst)` / `M.stop_instance(inst)`. Keep `M.start()` as a one-instance shim for callers that don't care. |
| `mcp/ws-server/init.lua`            | Same — accept `slot_name`, return an instance, capture in closure on `register_handlers` + `_handle_request`. Stop touching module-level `M.state`. |
| `mcp/ws-server/tools/init.lua`      | Each instance gets its own tools registry; `setup(server_inst)` writes onto `server_inst.tools`, not `M.tools`. |
| `_G.claude_deferred_responses`      | Key by `server_id .. ":" .. tostring(co)` so two servers can both have outstanding deferred responses without collisions. Or move it onto the instance. |
| `auto-agents/init.lua:453-473`      | Iterate `bootstrap` entries with `diff_review = true`, boot one bridge per entry, store result in `M.state.diff_review_ports = { [slot] = port }`. |
| `auto-agents/init.lua:673-686`      | `build_agent_env` reads `M.state.diff_review_ports[spec.slot]` instead of the singleton. |
| `tests/diff_*_spec.lua`             | Fixture rewrites — every spec that calls `mcp.start()` / `ws.start()` needs to opt into either the singleton shim or the instance API. |

This is real refactor work. It's the right shape, but framing it as a
patch-bump (`v0.2.12`) is dishonest — depending on test coverage, this
could easily run two or three patches inside the same minor line, or
deserves its own minor bump after the user's version policy review.

**D2-A is also gated on a spike** (Lector finding #3). The proposal
assumes that setting `CLAUDE_CODE_SSE_PORT=<slot_port>` in the spawn-env
*constrains* the Claude Code client to that specific port. If Claude Code
falls back to lockfile auto-discovery for any reason (env var unset on
some code path, lockfile preferred over env, multi-port aggregation),
spawning multiple lockfiles puts the binding at the *client's* discretion,
and the structural-attribution claim collapses. Lockfile content has no
slot identity — it's just `{ port, authToken, ide_name }` — so if any
client connects to the "wrong" lockfile, that server attributes the call
to the wrong slot.

The spike test before committing to D2-A:

1. Boot two `diff_review = true` claude slots side-by-side.
2. Confirm via `ss -tnp` (or `lsof`) that each `claude-code` process's
   established connection points only at the port set by its
   `CLAUDE_CODE_SSE_PORT` env var.
3. Try the inverse: with one slot's lockfile *only* but the env var set
   to a different non-existent port. Does Claude fall back to lockfile
   discovery, or does it fail?

If the env var is authoritative, D2-A is sound. If lockfile discovery
can override it, D2-A needs a different identity hook (e.g.,
per-slot auth tokens — each slot's spawn-env carries a token that
*only its own ws-server* will accept, and the ws-server can reject
cross-wired connections at the handshake layer).

#### D2-B — Pass `client` through, attribute via peer-PID lookup

Keep the single-port server. Patch `tools/init.lua:103-105` and `:130` to
call `tool_data.handler(input, client)` (additive — handlers ignore the
second arg if they don't need it). On the openDiff handler side, when
`_auto_agents_name` is absent:

  1. `vim.uv.tcp_getpeername(client.tcp_handle)` → peer source port.
  2. Read `/proc/net/tcp` (and `tcp6`), find the row whose `local_address`
     matches our listening port and `rem_address` matches the peer's
     source port → inode.
  3. For each slot's spawned PID
     (`M.state.slot_terminals[slot]:get_jobid() → jobpid`), walk
     `/proc/<pid>/fd/*` looking for `socket:[<inode>]`. The matching
     slot is the originator.
  4. Cache `client.id → slot_name` so subsequent tool calls on the same
     connection skip the procfs walk.

**Pros:** truly small delta — one signature change in `tools/init.lua`,
one procfs helper module, one cache table in the openDiff handler. No
multi-server refactor. No spike needed (the OS-level inode→PID mapping is
deterministic on Linux). Works regardless of how Claude Code resolves
ports.

**Cons:** Linux-only as written; would need `lsof -n -P -i :<port>`
shell-out fallback on macOS/BSD. Fragile across slot restarts (PID
changes between the cached connection and the new spawn — though stale
cache entries naturally evict on `on_disconnect`). The procfs walk is
fast (microseconds) but it's still os-coupled code we'd own.

#### Recommendation (revised after review-round-1)

Given the singleton-server scope (Lector #2) and the unresolved
lockfile-vs-env-var question (Lector #3), I no longer recommend D2-A
unconditionally. The pragmatic order is:

1. Run the D2-A spike (above) to settle whether `CLAUDE_CODE_SSE_PORT`
   authoritatively binds the client. ~30 minutes of investigation.
2. **If the spike passes:** D2-A is worth the refactor. It's the right
   long-term abstraction, and the singleton-to-factory change has value
   beyond this bug (cleaner per-slot lifecycle, easier testing).
3. **If the spike fails or is inconclusive:** ship D2-B. It's the
   smallest delta that solves the user-visible bug today and doesn't
   commit us to a refactor whose foundation isn't verified.

In both designs, **the `_auto_agents_name` payload field stays as a manual
override** for tests / adapters that need to spoof identity. It just stops
being load-bearing.

### D3 — Forward `msg.from` through the mailbox executor `ctx`

This is the parallel fix for the mailbox transport (Bug 2b). Extend
`auto-core.mailbox.router.execute_command` (router.lua:325-329) with two
new ctx fields:

```lua
local response = commands.handle_message(claimed, {
  reason       = "mailbox_executioner",
  mailbox      = rec.bare_id,
  mailbox_full = rec.id,
  sender       = claimed.from,                           -- NEW
  sender_bare  = mb_path.bare_id(claimed.from),          -- NEW
})
```

Update the `diff_queue` handler
(`lua/auto-agents/mailbox/commands.lua:197-208`) to prefer in order:

1. `args.agent_name` (explicit, non-empty, not `"agent"`).
2. `ctx.sender_bare` parsed as `agent:<name>`.
3. The bootstrap `resolve_diff_agent_name` fallback (kept as last-resort).
4. `"unknown"` (see D4) — *not* `"?"`.

This is a contract-compatible auto-core change: existing handlers that read
`ctx.mailbox` keep working; new handlers opt into `ctx.sender_bare`. The
router already holds `claimed.from`; the cost is two extra string fields.
Worth doing in the same release window as D2 because (a) the fix shape is
identical at the conceptual level — *propagate sender identity* — and (b)
the mailbox path is a latent regression waiting for any peer agent to use
it; fixing it now is cheaper than fixing it later when a user file-reports.

### D4 — Tighten the UI display predicate

In `diff/ui.lua:291-293`, treat `nil`, `""`, `"agent"`, `"?"`, and `"unknown"`
all as "unattributed", and render the literal string `"unattributed"` rather
than the bare `?`. This is purely cosmetic but makes failure of D2/D3 less
ambiguous when one of the upstream paths regresses.

## Alternatives Considered

- **Don't change the auto-core router; pass `msg.from` via a side-channel
  table indexed by message id.** Rejected — `ctx` already exists for
  exactly this purpose, and adding a parallel registry would just be a
  worse version of D2.

- **Just hard-code the bootstrap resolver to pick the most-recent agent
  when multiple `diff_review` agents are configured.** Rejected — the
  resolver's `nil` return on ambiguity is correct behavior; the fix
  belongs upstream (preserve the sender's identity), not in the resolver.

- **Show the full absolute path in the panel instead of `{repo}/{file}`.**
  Rejected — too long for the 20% left pane, and the `{repo}/{file}` form
  is already the right information density. The bug is in the resolver,
  not in the format.

- **Drop the agent column entirely until D2/D3 land.** Rejected — the
  column carries information when it works (peer-attributed writes,
  multi-agent triage), and the user has explicitly asked for it. Better
  to fix the upstream than hide the symptom.

## Consequences

**Pros**
- The panel becomes trustworthy as a multi-agent triage view: both labels
  resolve to the file's actual repo and the diff's actual originating agent.
- **D2 (websocket attribution)** removes a fragile coupling to whether each
  CLI's openDiff payload includes `_auto_agents_name`. Adapter writers no
  longer have to remember to inject it; the bridge attributes the call by
  connection identity (D2-A: structural binding; D2-B: PID forensics).
- **D3 (mailbox `ctx.sender`)** generalises beyond the diff panel — any
  future mailbox command that cares about the sender (audit logs,
  rate-limiting, capability checks) gets the right field for free.

**Cons**
- **D2 (whichever variant)** changes ws-server internals. D2-A is a
  singleton→factory refactor across `mcp/server.lua`, `mcp/ws-server/init.lua`,
  `mcp/ws-server/tools/init.lua`, and every test fixture that calls
  `mcp.start()` / `ws.start()` (see honest scope table in D2-A). D2-B is
  smaller — one signature change in `tools/init.lua` and a procfs helper —
  but adds OS-coupled glue.
- **D3 (auto-core)** is a public-API surface change. It's backward-compatible
  (additive `ctx.sender` / `ctx.sender_bare`), but it commits us to
  maintaining those fields as a public contract.
- **D4** changes the visible string from `?` to `unattributed`. Tests asserting
  the literal `?` (if any) must be updated. Check
  `tests/diff_ui_spec.lua` and `tests/diff_queue_spec.lua` for hardcoded
  expectations before landing.

## Rollout

This ADR is **proposed**, not yet implemented. Suggested commit order
(websocket path first because it's the dominant user-visible failure).
Every patch ships with the regression tests in its row of the test
matrix below — they are part of the patch, not a follow-up.

1. **Patch 1 — D1 + D4 (auto-agents.nvim, isolated cosmetic fixes).** Fixes
   the repo column for every diff and unifies the agent-column placeholder
   to `unattributed`. Self-contained — no auto-core change, no transport
   change. Patch bump: `v0.2.11`.

2. **Spike (no commit, ~30 min): verify `CLAUDE_CODE_SSE_PORT` binding.**
   Boot two `diff_review = true` claude slots side-by-side, confirm via
   `ss -tnp` / `lsof` that each `claude-code` connects only to its own
   port. Outcome gates Patch 2:
   - **Pass →** proceed with D2-A.
   - **Fail / inconclusive →** ship D2-B instead.

3. **Patch 2 — D2 (auto-agents.nvim, websocket attribution).** Either
   D2-A (per-slot bridge: singleton→factory refactor across `mcp/server.lua`
   + `mcp/ws-server/`) or D2-B (pass `client` through + procfs PID lookup),
   per the spike outcome. After this lands, jarvis/lector/wanda/
   white-vision all show their actual names in the panel for every
   native-MCP-routed diff. Patch bump (D2-B): `v0.2.12`. D2-A may need
   multiple patches in the line or a minor-bump discussion per the user's
   plugin version policy.

4. **Patch 3 — D3a (auto-core.nvim, ctx.sender).** Adds `ctx.sender` /
   `ctx.sender_bare` to the executor path in `mailbox/router.lua`. Patch
   bump on auto-core's current line.

5. **Patch 4 — D3b (auto-agents.nvim, consume ctx.sender_bare).** Wire the
   new ctx fields into the `diff_queue` handler. Patch bump: `v0.2.13`.

### Test matrix (revised after review-round-1, Lector finding #5)

Every patch lands with the named tests below. They're written against the
specific symptoms the user reported, not synthetic golden paths — running
the existing `tests/diff_ui_spec.lua` and `tests/diff_queue_spec.lua`
would not have caught any of these.

| Patch | Test                                              | Asserts                                                                                                       |
|-------|---------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| 1     | `repo_for/bare-worktree path`                     | a file under `<container>/auto-agents.nvim/fix-diff-panel/lua/foo.lua` labels as `auto-agents.nvim`, NOT `fix-diff-panel`, NOT `Projects` |
| 1     | `repo_for/plain-clone path`                       | a file under `<...>/kb/log.md` labels as `kb`                                                                  |
| 1     | `repo_for/non-git path`                           | a file under `/tmp/foo.lua` labels as `tmp` (parent basename fallback)                                          |
| 1     | `repo_for/auto-core unavailable`                  | falls back to `:h:t` cleanly; never raises                                                                     |
| 1     | `render_left/unattributed placeholder`            | a queue entry with `agent_name = ""` / `"agent"` / `"?"` / `nil` all render as `[unattributed]`, never `[?]`   |
| 2     | `openDiff/multi-diff_review/jarvis attribution`   | with 2+ `diff_review = true` bootstrap entries, an openDiff from jarvis's claude process labels as `[jarvis]`, not `[?]` or `[unattributed]` |
| 2     | `openDiff/no `_auto_agents_name``                 | absent `_auto_agents_name` no longer falls through to `"?"` — connection identity provides the answer          |
| 2     | `openDiff/instance isolation` (D2-A only)         | two server instances do not collide on `_G.claude_deferred_responses`; each resolves its own coroutines        |
| 4     | `diff_queue/sender from ctx`                      | a `kind="command"` `diff_queue` from `agent:jarvis` to `nvim` labels as `[jarvis]`, not `[nvim]`               |
| 4     | `diff_queue/explicit args.agent_name wins`        | `args.agent_name = "explicit"` overrides `ctx.sender_bare`                                                     |

Patches 1, 2, and 4 are independently testable; the panel improves
visibly after patches 1 and 2 (the two the user has actually observed
regressing). Patches 3-4 close the latent mailbox regression so peer
agents that switch transport later don't re-introduce the bug.

## References

- ADR 0010 — Agent Unified Diff Queue & View (introduces the queue + UI
  this ADR repairs).
- v0.2.6 commit (518e1ca) — "diff queue panel — meaningful left-column
  labels" — the introducer of `wt_for` and `resolve_diff_agent_name`.
- `lua/auto-agents/diff/ui.lua:271-296` — the render site.
- `lua/auto-agents/diff/queue.lua` — `AutoAgentsDiffRequest` schema.
- `lua/auto-agents/mcp/server.lua:40-85` — single-port bridge bootstrap;
  D2-A target.
- `lua/auto-agents/mcp/ws-server/init.lua:34-96, 258-326` — server
  start + tools/call dispatch.
- `lua/auto-agents/mcp/ws-server/tools/init.lua:80-131` — handler
  dispatch loop; D2-B target (signature change to pass `client` through).
- `lua/auto-agents/mcp/ws-server/tools/open_diff.lua:73-78` — websocket
  openDiff handler; the attribution fall-through.
- `lua/auto-agents/mcp/ws-server/client.lua:18-32` — `WebSocketClient` /
  `tcp_handle` surface that `getpeername` would use under D2-B.
- `lua/auto-agents/agent/adapters/tools/open_diff.lua:73-78` — adapter
  mirror of the same handler (kept in sync with D2 fix).
- `lua/auto-agents/init.lua:453-473, 673-686` — diff-review bootstrap +
  spawn-env wiring; D2-A target (split single-port → per-slot map).
- `lua/auto-agents/init.lua:1209-1242` — `resolve_diff_agent_name`; the
  ambiguous-fallback function that returns nil under the user's
  4-`diff_review`-agent config.
- `~/.config/nvim/.auto-agents-config/global.toml` — current bootstrap
  with 4 `diff_review = true` entries (jarvis / lector / wanda-maximoff /
  white-vision) — the configuration that exercises the ambiguous-branch
  failure mode.
- `lua/auto-agents/mailbox/commands.lua:184-249` — `diff_queue` mailbox
  command handler (Bug 2b site).
- `auto-core.nvim/main/lua/auto-core/fs/path.lua:203-245` — `git_root` /
  `workspace_root` / `project_root` resolvers (D1 target).
- `auto-core.nvim/main/lua/auto-core/mailbox/router.lua:316-334` —
  executor ctx construction site (D3a target).
- `auto-core.nvim/main/lua/auto-core/git/repo.lua:12-22` —
  `M.common_dir(path)` API; the primitive D1 now uses.
- `auto-core.nvim/main/lua/auto-core/git/graph.lua:88-105` — existing
  `_derive_label(common_dir, root)` helper; candidate for promotion to
  public API if D1's `repo_for` logic grows a second caller.

## Review history

### Round 1 — agent:lector (2026-05-16)

Lector reviewed the first draft and raised five findings. Summary of
disposition:

| # | Severity | Finding                                                        | Disposition                                                                                       |
|---|----------|----------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| 1 | High     | `git_root` returns branch identity, not repo identity, in bare-worktree layouts | **Accepted.** Rewrote D1 to use `auto-core.git.repo.common_dir` + `:h:t` with `.git`/`.bare` disambiguation. Added explicit test cases for both bare-worktree and plain-clone layouts. |
| 2 | High     | D2-A under-scoped — `mcp.server` and `ws-server` are module singletons; per-slot bridge needs a full singleton→factory refactor | **Accepted.** Rewrote D2-A with an honest scope table listing every file that needs to change, called out `_G.claude_deferred_responses` keying, and acknowledged that the patch may need multiple commits or a minor-bump discussion. |
| 3 | Medium   | D2-A assumes `CLAUDE_CODE_SSE_PORT` constrains the client; Claude `--ide` lockfile discovery may override | **Accepted.** Added an explicit spike step (Rollout #2) gating the choice between D2-A and D2-B. Recommendation is now conditional on the spike outcome. |
| 4 | Medium   | Consequences section swaps D2/D3 labels (mailbox ctx is D3, connection state is D2) | **Accepted.** Fixed labels in Consequences. |
| 5 | Medium   | Test coverage should be part of the rollout, not a note         | **Accepted.** Added explicit test matrix with named cases mapped to each patch. Existing specs don't catch any of the reported regressions; new tests target the exact symptoms. |

Lector's "what I agree with" list was preserved without changes (the
`workspace_root(path)` opts-vs-string bug, the multi-`diff_review`
ambiguity, the mailbox `ctx.sender` shape).

The recommendation order in Rollout was reordered to honor finding #3:
spike before commit, then D2-A or D2-B per the spike outcome.