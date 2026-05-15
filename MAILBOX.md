# auto-agents mailbox — architecture & command registry

This document describes the file-backed mailbox that lets
auto-agents-managed agents (Claude, Codex, Gemini, …) talk to
each other and to Neovim — across processes, across sandboxes,
across nvim restarts. It is the consumer-side view of
**auto-core's ADR 0013 mailbox**; the canonical protocol lives
in `auto-core.nvim`. Read this when you need to:

- Send a message from an agent
- Add a new whitelisted command
- Understand why a wake didn't fire
- Reason about isolation across multiple nvim instances

## Why a file-backed mailbox at all?

Each agent we spawn runs as its **own CLI process** under a
**different sandbox** (Claude Code's permission system, Codex's
seatbelt, Gemini's CLI). They cannot see each other's TCP
sockets, cannot see nvim's RPC socket from inside their sandbox,
and may not even share write access to the same directory tree.

What they do all share:

1. The **user's home dir** (because each tool authenticates from
   its own dotdir there, with read+write to it).
2. The ability to **read environment variables** set at process
   spawn time.

So the mailbox protocol uses (1) for storage (`~/.claude/mailbox/`,
`~/.codex/mailbox/`, etc.) and (2) to tell each agent where its
mailbox is. Messages are atomically-written JSON files; a host-side
router (running inside Neovim) watches them and routes
sender-outbox → recipient-inbox.

## Layout

```
~/.claude/mailbox/                              ← tool root (per-kind)
├── bootstrap-mailbox.md                        ← single protocol doc per tool root (v0.1.8)
├── agent:jarvis:1778824643-683526/             ← per-instance mailbox (v0.1.8)
│   ├── inbox/         ← messages addressed to me
│   ├── outbox/        ← messages I'm sending (router picks up)
│   ├── responses/     ← replies to messages I sent
│   ├── processing/    ← claimed-but-not-completed
│   ├── archive/       ← completed/failed history (never deleted)
│   └── .agent-state/  ← per-agent state (seen-revision, etc.)
└── agent:other:<id>/                           ← another agent on the same tool

~/.codex/mailbox/                               ← codex agents land here
└── agent:lector:1778824643-683526/

~/.gemini/mailbox/                              ← gemini agents land here

~/.local/state/nvim/auto-core/mailbox/          ← host-side fallback root
└── nvim/                                       ← executioner mailbox (auto-agents v0.2.7+)
```

### Per-tool vs per-mailbox

The bootstrap doc is **one file per tool root** (auto-core
v0.1.8 hoisted it from per-mailbox). Two agents sharing
`~/.claude/mailbox/` see the same `bootstrap-mailbox.md`.
Upserts use a content-hash short-circuit (v0.1.7) so re-registering
the same tool root is effectively free unless the protocol changed.

### Per-instance isolation

Each nvim process generates an `instance_id` of the form
`<unix-seconds>-<pid>` at startup. Bare mailbox ids passed to
`mailbox.register("agent:jarvis", …)` are auto-suffixed to
`agent:jarvis:1778824643-683526` so two nvims sharing the same
tool root land in non-overlapping subtrees. The four env vars
the agent sees:

| Var | Value |
|---|---|
| `AUTO_AGENTS_INSTANCE_ID` | `1778824643-683526` |
| `AUTO_AGENTS_MAILBOX_ID` | `agent:jarvis:1778824643-683526` |
| `AUTO_AGENTS_MAILBOX_DIR` | `/home/johno/.claude/mailbox/agent:jarvis:1778824643-683526` |
| `AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC` | `/home/johno/.claude/mailbox/bootstrap-mailbox.md` |

Cross-instance addressing: senders may use a **bare id**
(`"to": "agent:jarvis"`) — auto-core's router resolves it to the
live full-id mailbox of the same instance. Messaging across nvim
instances requires the full id.

## Sending a message — atomic write contract

```
1. Build the JSON envelope with from = your full mailbox id.
2. Write to a temp file:    outbox/.tmp-<random>
3. Best-effort fsync.
4. Atomic rename:           outbox/<id>.json
5. The router detects, atomically renames into recipient's inbox.
6. Router fires the recipient's wake hook (see § Command registry).
```

Step 4 is the commit point — the router treats `.tmp-` files as
in-flight and won't pick them up.

### Message shape (baseline)

```json
{
  "id":              "<monotonic-time-and-random-suffix>",
  "kind":            "message | command | response | event",
  "from":            "agent:jarvis:1778824643-683526",
  "to":              "agent:lector",
  "subject":         "short summary",
  "body":            "full text",
  "command":         null,
  "args":            {},
  "reply_to":        null,
  "correlation_id":  null,
  "status":          "queued",
  "created_at":      "2026-05-15T06:00:57Z",
  "expires_at":      null
}
```

- `kind = "command"` requires a non-empty `command` string. Only
  whitelisted commands execute; unknown commands return
  `{ ok = false, code = "unknown_command" }`. **Never send raw
  Lua, Vimscript, shell, or RPC as a command — auto-core rejects
  them.**
- `kind = "response"` requires `reply_to` or `correlation_id`.

## Command registry (whitelist)

The command registry is the **security boundary** that decides
what a `kind = "command"` message is allowed to do. Lives in
auto-core (`auto-core/mailbox/commands.lua`). Plugins opt in by
calling `mailbox.commands.register(name, spec)` at setup time.
auto-core does NOT ship any commands itself — everything is
plugin-owned.

The router uses the same registry for its **wake-hook dispatch**:
when a file arrives in a recipient's inbox or responses, the
router calls `commands.handle_message` with the recipient's
registered `wake = { command = "...", args = { ... } }`. If the
command name isn't registered, `dispatch_wake` silently returns
(router.lua:208-212) — that's by design (wake hooks are
fire-and-forget), but it does mean **forgetting to register a
wake command makes wakes silently fail.** This is exactly what
happened in v0.2.7 and motivated v0.2.8.

### Commands auto-agents registers (v0.2.8)

| Name | Owner | Purpose |
|---|---|---|
| `wake` | auto-agents | Wake a slot terminal by agent name. Default wake hook for every spawned agent. |
| `addressbook` | auto-agents | Return every reachable mailbox address registered with auto-core. |
| `send_user` | auto-agents | Surface a short message to the user via `vim.notify`. |

#### `wake`

```
args = { slot: string, text: string?, submit: boolean? }
```

- `slot` — agent name (e.g. `"jarvis"`). Resolved → integer slot
  via `auto_agents.slot_for_name`.
- `text` — terminal nudge. When omitted, auto-agents synthesizes
  a default: `[auto-agents] new <kind> from <mailbox> — check
  $AUTO_AGENTS_MAILBOX_DIR/<kind>/`.
- `submit` — whether to follow the text with a CR (default
  `true`).

Returns:

```json
{ "ok": true,  "value": { "slot": 1, "text": "...", "submit": true } }
{ "ok": false, "code": "invalid_args"        | "slot_not_found" | "terminal_unavailable", "error": "..." }
```

Used both as the router's wake hook (registered per-agent at
spawn time as `wake = { command = "wake", args = { slot = "<name>" } }`)
AND as an agent-callable command — one agent can wake another by
sending `kind = "command" command = "wake"` to `nvim`.

#### `addressbook`

```
args = { include_self: boolean? }   // default true
```

Returns the live mailbox registry contents (peer agents + the
`nvim` executioner) plus a virtual `user` entry. The book is
**dynamic by construction** — `mailbox.register` is called for
every fresh agent spawn, so newly-spawned peers appear without
the agent having to refresh anything. Querying the book is
always cheap (it's an in-memory table walk).

Returns:

```json
{
  "ok": true,
  "value": {
    "instance_id": "1778824643-683526",
    "caller":      "agent:jarvis:1778824643-683526",
    "count":       3,
    "addresses": [
      {
        "id":           "agent:lector:1778824643-683526",
        "bare_id":      "agent:lector",
        "kind":         "agent",
        "dir":          "/home/johno/.codex/mailbox/agent:lector:1778824643-683526",
        "tool_root":    "/home/johno/.codex/mailbox",
        "executioner":  false,
        "wake_command": "wake",
        "is_self":      false
      },
      {
        "id":           "nvim:1778824643-683526",
        "bare_id":      "nvim",
        "kind":         "host",
        "executioner":  true,
        "is_self":      false
      },
      {
        "id":          "user",
        "bare_id":     "user",
        "kind":        "virtual",
        "description": "Not a mailbox. Reach by sending kind='command' command='send_user' addressed to 'nvim'.",
        "is_self":     false
      }
    ]
  }
}
```

Use the `bare_id` of a peer when addressing them from inside the
same instance — auto-core resolves bare ids to full per-instance
ids on the host side. For cross-instance delivery, use the full
`id`.

#### `send_user`

```
args = { subject: string?, body: string?, level: "info"|"warn"|"error"|"debug"? }
```

Forwards to `vim.notify(...)` with `title = "auto-agents.mailbox"`.

### Adding a new command (from another plugin)

```lua
-- In your plugin's setup function:
local ok, core = pcall(require, "auto-core")
if not ok then return end  -- auto-core not loaded; skip gracefully

core.mailbox.commands.register("harpoon", {
  owner       = "md-harpoon",
  description = "Open a markdown file in an md-harpoon preview slot",
  schema      = { file = "string", slot = "string?" },
  handler     = function(args, _ctx)
    if type(args) ~= "table" or type(args.file) ~= "string" then
      return { ok = false, code = "invalid_args", error = "args.file required" }
    end
    local target_slot = args.slot or "s"
    -- ... call into md-harpoon's API ...
    return { ok = true, value = { slot = target_slot, file = args.file } }
  end,
})
```

Rules:

1. **Owner string is mandatory.** Re-registering with the same
   owner is allowed (hot-reload); re-registering with a different
   owner is a fail-fast.
2. **Handler signature is `fun(args: table, ctx: table): table`.**
   `ctx` carries router metadata when fired as a wake hook
   (`mailbox`, `mailbox_full`, `arrival_kind`, `arrival_id`).
3. **Return a structured response.** `{ ok = true, value = … }` on
   success; `{ ok = false, code = "...", error = "..." }` on
   failure. Never throw — auto-core's `handle_message` catches
   thrown errors but you lose structured error info.
4. **Don't execute raw code.** If the command needs to do
   something dynamic, decompose it into a finite set of named
   commands. The registry is the only thing protecting users from
   compromised agents.

## Dependencies — what has to work for messaging to function

This list is the actual operational chain. Break any link and
agent-to-agent messaging stops working.

### 1. `auto-core.nvim` ≥ v0.1.8 loaded into Neovim

Provides:

- `auto-core.mailbox.configure({ autostart = true })` — starts
  the central router.
- `auto-core.mailbox.register(id, { root, wake })` — creates the
  mailbox tree, auto-suffixes with `instance_id`, upserts the
  per-tool-root bootstrap doc.
- `auto-core.mailbox.commands.register(name, spec)` — adds to the
  whitelist.
- `auto-core.mailbox.env_for_agent(rec)` — returns the four env
  vars to inject at spawn time.

### 2. `auto-agents.setup()` runs (v0.2.7+ for spawn-time wiring, v0.2.8+ for wake)

Inside `setup()`:

- `mailbox.configure({ autostart = true })` — router watcher
  starts.
- `mailbox.register("nvim", { root = host_fallback_root() })` —
  registers the `nvim` executioner mailbox so agents can address
  commands back at Neovim.
- `require("auto-agents.mailbox.commands").register_all()` —
  registers `send_slot` and `send_user` so the wake hook actually
  fires.

### 3. `build_agent_env(spec, cwd)` per agent spawn (v0.2.7+)

For each `configured` agent:

- Calls `mailbox.register("agent:" .. spec.name, { root, wake })`
  with `root` resolved by `MAILBOX_ROOT_BY_KIND` (claude →
  `~/.claude/mailbox`, codex → `~/.codex/mailbox`, gemini →
  `~/.gemini/mailbox`; other kinds → `host_fallback_root()`).
- Merges the four `AUTO_AGENTS_*` env vars into the spawn env so
  the spawned CLI can locate its mailbox via env, not socket.

### 4. The agent CLI process has read/write access to its mailbox dir

The user's `~/.claude/`, `~/.codex/`, `~/.gemini/` are inside
each tool's sandbox by default — the agent can read and write
without extra grants. To skip the per-op permission prompt for
the mailbox dir + KB paths, auto-agents v0.2.9 appends the
appropriate per-kind CLI flag at spawn time:

| Kind   | Flag                                      |
|--------|-------------------------------------------|
| claude | `--add-dir <path>` (repeatable)           |
| codex  | `--sandbox-workspace-write-root <path>` (repeatable) |
| gemini | (not yet supported — falls back to prompt) |

Paths granted at spawn:

- `$AUTO_AGENTS_MAILBOX_DIR` (the agent's own mailbox)
- Every entry of `$AUTO_AGENTS_KB_READ` (colon-split)
- `$AUTO_AGENTS_KB_WRITE` (if not already covered by READ)

Strategy module: `lua/auto-agents/permissions.lua`. Add new
kinds by extending the `STRATEGY` table with a
`repeatable_flag("--your-flag")` entry. No persistence — the
per-instance mailbox dir regenerates every nvim restart, so the
next spawn rebuilds the argv from scratch.

### 5. The router can read every mailbox's tool root

The router walks each registered mailbox's root directory and
either uses `fs_event` (Linux/macOS inotify-style) or falls back
to polling. If the router can't read a root (permissions, missing
directory), outbox → inbox routing for that root stops.

### 6. The wake command is registered

If the registered wake (`wake = { command = "send_slot", args = {
slot = "jarvis" } }`) names a command that's **not** in the
registry, `dispatch_wake` silently returns. Pre-v0.2.8 this was
the canonical failure mode — files routed correctly but the
agent never woke.

## Troubleshooting

### "Agent isn't waking on new mail"

Check, in order:

1. `env | grep AUTO_AGENTS_MAILBOX` in the agent terminal — if
   empty, `build_agent_env`'s mailbox block didn't run (auto-core
   not loaded? auto-agents < v0.2.7?).
2. `ls "$AUTO_AGENTS_MAILBOX_DIR/inbox/"` — if the file isn't
   there, the router didn't route. Check that the sender's
   outbox was actually written (atomic rename completed) and
   that the router is running:
   ```lua
   :lua print(require("auto-core").mailbox.is_running())
   ```
3. `:lua vim.print(require("auto-core").mailbox.commands.list())`
   — confirm `send_slot` is in the list with
   `owner = "auto-agents"`. Pre-v0.2.8 it won't be.
4. Slot resolution: `:lua print(require("auto-agents").slot_for_name("jarvis"))`
   — should return an integer. If `nil`, the agent's `name` in
   the bootstrap config doesn't match what the wake hook is
   passing.

### "I want to inspect what's in flight"

```bash
# Live wakes / arrivals
nvim --remote-expr 'execute("AutoCoreMailboxOpen")'   # human-readable viewer
:Subscribe core.mailbox:message_routed                # event topic for routing
:Subscribe core.mailbox:message_queued                # event topic for inbox arrival
:Subscribe core.command:registered                    # when a plugin registers a command
:Subscribe core.command:dispatched                    # when handle_message fires
```

### "I want to send a message manually for testing"

From inside the host nvim:

```lua
require("auto-core").mailbox.send({
  to       = "agent:jarvis",          -- bare id resolves to same-instance full id
  from     = "nvim",
  kind     = "message",
  subject  = "test",
  body     = "hello jarvis",
})
```

`mailbox.send` is the host-side helper that writes directly into
the recipient's inbox (Neovim is trusted; agents have to round-
trip via their own outbox + the router).

## Pruning

Mailbox dirs accumulate over time. `mailbox.prune({ max_age_seconds })`
(default 7 days) walks each registered tool root, skips currently-
registered ids, and removes dirs whose mtime is older than the
threshold. Bare-id legacy dirs (pre-v0.1.8) are also swept — they
can never be "live" under v0.1.8+ registration since registrations
are always per-instance.

Run manually:

```lua
:lua vim.print(require("auto-core").mailbox.prune({ max_age_seconds = 7 * 24 * 60 * 60 }))
```

Returns `{ removed, kept_alive, kept_recent, failed }`.

## References

- **Canonical schema:** `auto-core.nvim/main/lua/auto-core/mailbox/templates/bootstrap.md`
  (also lives at `<tool_root>/bootstrap-mailbox.md` once any agent
  registers under that root).
- **ADR 0013** — auto-core's design doc for the mailbox protocol
  (see `auto-core.nvim/docs/adr/`).
- **`auto-core/mailbox/router.lua:204-233`** — wake-hook dispatch.
- **`auto-core/mailbox/commands.lua`** — registry + valid-name
  rules.
- **`auto-agents/init.lua:474-494`** — setup-time mailbox wiring
  (v0.2.7+).
- **`auto-agents/init.lua:build_agent_env`** — per-spawn
  registration + env injection.
- **`auto-agents/mailbox/commands.lua`** — auto-agents-owned
  commands (v0.2.8+).
- **Open work:** `~/.config/nvim/docs/todo-lists/mailbox-wake-and-permissions.md`
  (spawn-time permission injection, additional commands).