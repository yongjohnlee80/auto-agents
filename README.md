# auto-agents.nvim

> Multi-agent orchestration panel for Neovim. One right-side window holds slot
> **0** (an admin REPL) plus a **configurable number of agent slots** (default
> 5, up to 9) — all in the same panel, switched by buffer. Project-local
> knowledge-base, per-slot resource grants, and one-key navigation.

**Status:** pre-release. M1–M5 are implemented and in daily use. See
[`PLAN.md`](./PLAN.md) for the full design and milestone log,
[`LAYERED-ARCHITECTURE.md`](./LAYERED-ARCHITECTURE.md) for the process/protocol
split, and [`PERFORMANCE.md`](./PERFORMANCE.md) for the memory/CPU budget.

---

## Contents

- [Why](#why)
- [Install](#install)
- [First run](#first-run)
- [Slot model](#slot-model)
- [Keymaps & commands](#keymaps--commands)
- [TOML config](#toml-config)
- [Project commands](#project-commands)
- [Admin panel](#admin-panel)
- [Help](#help)
- [Wizards](#wizards)
- [Playground terminals (T1..T4)](#playground-terminals-t1t4)
- [Agent kinds](#agent-kinds)
- [Knowledge base](#knowledge-base)
- [Resource grants](#resource-grants)
- [Status](#status)
- [Attribution](#attribution)
- [License](#license)

---

## Why

A single right-hand panel that hosts **multiple** agent terminals — Claude
Code, Codex, Gemini, Copilot, or any shell — switchable by slot, with shared
project context. Each slot can have its own working directory, its own
knowledge-base scope, its own grant of paths/env, and its own task list. Add as
many agent slots as you need (up to 9) with `slot add`, so a manager agent and
its helpers all share one panel.

## Install

```lua
-- lazy.nvim
{
  "yongjohnlee80/auto-agents",
  version = "^0.2.0",  -- v0.2.0 is the auto-core consumer release
  dependencies = {
    "yongjohnlee80/auto-core.nvim",  -- foundation library; hard dep as of v0.2.0
    "folke/snacks.nvim",              -- navigation dock + playground-terminal floats
  },
  opts = {},  -- agents/KB live in TOML — see below
}
```

### Dependencies

- **[`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
  ^0.1.58** — foundation library for the AutoVim plugin family. Provides the
  shared event bus, namespaced state store, panel singleton, float
  primitives, canonical task-status surface, and the `fs.atomic` write
  primitive that auto-agents consumes. Required. The `0.1.58` floor is
  set by auto-agents v0.2.54+ (ADR-0039 Batch C: identity/KB persistence
  delegates to `auto-core.fs.atomic.write`, first shipped in auto-core
  v0.1.58).
- **[`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)** — required
  for the `:AutoAgentsDock` navigation dock and the playground-terminal floats
  (`T1..T4`).

> **Caret pin (`^0.2.0`)**: future v0.2.x releases auto-include without a
> manual bump. The `auto-core` family follows an additive-only minor-bump
> rule — no v0.X.Y release renames, removes, or break-shapes any existing
> public surface. Crossing to a future v0.3.0 requires bumping the caret
> deliberately.

**Agents are not configured in your lazy spec.** They live in TOML files
under `<stdpath('config')>/.auto-agents-config/`:

- `<sha16-of-project-root>.toml` — per-project (overrides global)
- `global.toml`                  — shared default across all projects

On first run with no TOML, `:AutoAgents` opens slot 0 (admin) and auto-engages
an `agent add` wizard. Step through the prompts and you get a working agent
plus a saved TOML. See [First run](#first-run) below.

The session pins its project key at startup — `:cd` does not move agents or
KB mid-session, so you can wander the file tree freely.

## Slot model

```
                    ┌─────────────────────┐
   editor           │    auto-agents      │
                    │  ┌──────────────┐   │
                    │  │  winbar      │   │
                    │  │  0 1 2 3 4 5 │   │   all slots: one right-side panel
                    │  └──────────────┘   │   (single window, swapped buffers)
                    │  ░░░░░░░░░░░░░░░░   │
                    │  ░  agent term  ░   │
                    │  ░░░░░░░░░░░░░░░░   │
                    └─────────────────────┘
```

- **Slot 0** — admin REPL (a prompt buffer). Type `help` and hit Enter.
- **Slots 1..N** — agent terminals, **all in the one right-side panel** (single
  window, swapped buffers). The winbar shows the active slots with the focused
  one highlighted.
- **Configurable count.** `N` is `panel.slot_count` — **default 5, range 2–9**.
  Grow or shrink it live from the admin REPL with `slot add` / `slot remove`
  (persisted to the TOML). There is **no separate "float" tier** — the old
  slots-6-9 sub-agent floats were retired in the v0.1.24 flat-slot refactor;
  every agent now lives in the same panel, and ephemeral helpers are just extra
  slots. (The four **playground terminals** `T1..T4` below are a different
  thing — shared shells, not agent slots.)

## Keymaps & commands

`auto-agents` ships **no global keymaps by default** — bind them yourself in the
lazy spec under `keys = { ... }`. Recommended bindings (this is what the
maintainer uses):

| Lhs              | Action                                   |
|------------------|------------------------------------------|
| `<F5>`           | `:AutoAgents`           — toggle panel       |
| `<F6>` / `<F12>` | `:AutoAgentsDock`       — open nav dock      |
| `<F11>`          | `:AutoAgentsDiffQueue`  — toggle diff queue  |
| `<leader>ac`     | `:AutoAgents`           — toggle panel       |
| `<leader>ad`     | `:AutoAgentsDiffQueue`  — toggle diff queue  |
| `<leader>a0`..`9`| `:AutoAgentsFocus N`    — jump to slot N     |

Inside the **navigation dock** (an attached float):

- `0`–`9` jumps to that slot.
- `e` returns to the editor (the most recently used non-panel window).
- Any other key closes the dock.

User commands (always available):

| Command                   | Effect                                                    |
|---------------------------|-----------------------------------------------------------|
| `:AutoAgents[!]`          | Toggle the panel. `!` bypasses the host-width guard.      |
| `:AutoAgentsFocus <N>`    | Focus slot N (0..`slot_count`) in the right-side panel.   |
| `:AutoAgentsDock`         | Toggle the rightmost-centered navigation dock.            |
| `:AutoAgentsDiffQueue`    | Toggle the unified diff queue review panel. See below.    |
| `:AutoAgentsForwardText`  | Forward selected text or clipboard to an agent.           |

For an example wiring (with dynamic `which-key` descriptions per slot), see
[`examples/lazy-spec.lua`](./examples/lazy-spec.lua) — or the maintainer's live
config at [`autovim`](https://github.com/yongjohnlee80/autovim/blob/main/lua/plugins/auto-agents.lua).

## Diff queue

When an agent proposes a file edit through its MCP `openDiff` tool, the
request is queued into the **unified diff queue** instead of immediately
hijacking your editor with a split. Open the review panel with
`:AutoAgentsDiffQueue` (default `<F11>` / `<leader>ad`) — a three-pane
float lets you review each queued change on your own terms.

### Layout

```
┌─ Agent Diff Queue ────────────────────────────────────────────────┐
│ Pending Diffs (3) │ Current               │ Proposed              │
│                   │                       │                       │
│ ▶ [1] foo.go      │ <old content from     │ <new content the      │
│   [2] bar.lua     │  the file on disk>    │  agent wants to write>│
│   [3] readme.md   │                       │                       │
│                   │                       │                       │
│                   │ — diff-highlighted —  │ — diff-highlighted —  │
└───────────────────┴───────────────────────┴───────────────────────┘
 A/D/M Accept/Deny/Modify • E Edit (preview) • [1-9] Select • Tab Cycle • hjkl in diff • q Close
```

The left pane is the queue. The middle pane shows the current
on-disk content. The right ("preview") pane shows the agent's
proposed content. Both diff panes get **line numbers** and
**treesitter syntax highlighting** based on the file's extension —
the diff isn't just colored by `:diffthis` add/remove cues, it's
also grammar-aware for the underlying language.

### Resolution actions

All actions operate on the currently-selected entry (the row marked
`▶` in the left pane):

| Key   | Where bound    | Effect |
|-------|----------------|--------|
| `A`   | every pane     | **Accept**. Resolves the diff with the proposed content. The agent receives `FILE_SAVED` and the file is written. |
| `D`   | every pane     | **Deny**. Resolves with `DIFF_REJECTED`. The agent reads it as a flat refusal. |
| `M`   | every pane     | **Modify** — REQUEST CHANGE with a reason. Prompts for free-form text via `vim.ui.input`; the reason reaches the agent through two channels (see below). |
| `E`   | preview only   | **Edit in place**. Flips the preview pane to modifiable + enters insert mode. Tweak the proposed content directly; `A` then resolves with your edited version. Toggle `E` again to leave edit mode. Edits survive selection switches (`j`/`k`/digit). |
| `<CR>`| left only      | Open the **native split** diff (full editor width, real LSP attachment) for substantial edits. Saving (`:w`) accepts, `:q` denies. |
| `1`–`9` | left only    | Jump to entry N. |
| `j`/`k` | left only    | Move selection up/down. |
| `<Tab>` / `<S-Tab>` / `<C-h>` / `<C-l>` | every pane | Cycle between panes. |
| `q` / `<Esc>` | every pane | Close the panel. |

`h`/`j`/`k`/`l` and the rest of Vim's normal-mode motions (`gg`, `G`,
`$`, `^`, `w`, `b`, `e`, `f`, `t`, `%`, counts like `5j`/`10G`, etc.)
work natively inside the middle and preview panes — they're not
shadowed by the selection keys. The panel auto-closes when the queue
drains.

### Two channels for REQUEST CHANGE (`M`)

`openDiff`'s response protocol returns a free-form text in
`content[2]` of `DIFF_REJECTED`, which we populate with your reason.
That's the "right" channel, but **Claude Code's CLI currently drops
`content[2]` and surfaces only a generic "user rejected" message to
the agent**, so the reason wouldn't get through on its own.

To deliver the feedback today, `M` also injects `"REQUEST CHANGE:
<reason>"` into the owning agent's terminal as a follow-up user
prompt via `auto-agents.send_slot(slot, body, { submit = true })`.
The agent reads it on its main input loop and iterates. When upstream
Claude Code eventually forwards `content[2]`, both channels carrying
the same text becomes a benign duplicate — no editor-side changes
needed.

See [ADR 0012](kb-seeds/coding.md) in the KB for the full rationale.

## First run

Open `nvim` in a project directory, then `:AutoAgents`. With no TOML
configured, the panel opens at slot 0 (admin) and auto-starts the
`agent add` wizard:

```text
auto-agents v0.1.0 — orchestration admin (slot 0)
Type ? for help. Try 'status' to see slot states.

(no agents configured — starting 'agent add' wizard)
(<C-c> to cancel; type 'project init' first if you want a per-project config)

auto-agents: new agent
  <C-c> to cancel.
  slot  [1..9]:
> 1
  kind (claude|codex|antigravity|junie|goose|opencode|copilot|generic)  [claude]:
> 
  name (handle, used for KB dir + grants)  [(blank to auto-generate)]:
> main
  ...
  Create / ensure KB for this project? (y|N)  [N]:
> y

✓ Slot 1 added (claude/main)
  saved → ~/.config/nvim/auto-agents/<project-key>.toml
  KB ensured at <project-root>/.auto-agents/kb
```

Each step shows the current/default value in `[…]`. Press Enter to keep it,
or type a new value. **`<C-c>` cancels** the wizard at any step (terminal
convention).

If you'd rather configure a **per-project** TOML before adding agents, type
`project init` first — then run `agent add`.

## TOML config

Agents and KB are stored in TOML files under
`<stdpath('config')>/.auto-agents-config/`:

| File                     | Used for                                          |
|--------------------------|---------------------------------------------------|
| `<project-sha16>.toml`   | Per-project agents — wins if it exists.           |
| `global.toml`            | Default agents for any project without its own.   |

The session resolves its project key at nvim startup (`sha16(git_root || cwd)`)
and **caches it** — `:cd` does not move agents/KB mid-session.

```toml
[project]
cwd = "/abs/path"
created_at = "2026-05-01T12:34:56Z"

[kb]
root = "/abs/path/.auto-agents/kb"   # absolute; can be shared across projects

[[agents]]
slot          = 1
kind          = "claude"             # claude|codex|antigravity|junie|goose|opencode|copilot|generic
name          = "main"
title         = "Claude"
role          = "primary engineering pair"   # optional
cwd           = "/abs/path"                  # optional; defaults to project root
cmd           = ["claude", "--mini"]         # optional override
allowed_paths = ["src/", "tests/"]           # exported as AUTO_AGENTS_ALLOWED_PATHS
manager       = 0                            # optional: managing slot
kb_scope      = "shared"                     # shared|private|isolated
bottom_margin = 1                            # optional: per-slot TUI footer override
```

You can hand-edit the TOML, or use the wizard inside the admin panel. Either
way, mutations from the wizard land back in the same file.

Top-level lua `opts` is now small — just runtime settings:

```lua
{
  log_level = "info",
  panel = {
    side          = "right",   -- left|right
    min_width     = 60,
    max_width     = 130,
    percentage    = 0.35,
    editor_floor  = 40,
    slot_rail     = "winbar",  -- winbar|vertical|off
    bottom_margin = 1,         -- TUI footer breathing room (overridden per-slot in TOML)
  },
  kb       = { default_scope = "shared" },
  terminal = { provider = "auto", git_repo_cwd = true },
}
```

## Project commands

`:AutoAgentsProject <sub>` and the admin `project ...` verb manage TOML files.

| Command                                 | Effect                                                            |
|-----------------------------------------|-------------------------------------------------------------------|
| `project init`                          | Create a fresh per-project TOML for the cached cwd.               |
| `project import <key\|path\|cwd>`       | Copy `[[agents]]` from another project; **shares its `[kb].root`**. |
| `project import` (no args)              | List candidates, ask you to re-run with the chosen one.           |
| `project remove`                        | Delete the per-project TOML. **KB on disk survives.** Falls back to global. |
| `project list`                          | Show every TOML in the config dir + which is active.              |
| `project show`                          | Print the active resolution (`project`/`global`/`none`) + paths.  |

`project import` exists for the case where you have the same project mirrored
at multiple paths (a clone, a worktree, a sibling repo) — agents are
duplicated, but the KB is shared so notes don't fragment.

## Mailbox command surface — and where verbs live

An agent discovers what it can ask the host to do by sending
`kind = "command"`, `command = "commands_list"` to `nvim`. The reply lists
every whitelisted verb with its `name`, `owner`, `description` and **arg
`schema`**, so discovery is actionable rather than a list of names. An
optional `owner` filter narrows it to one plugin. `addressbook` is its
sibling: peer discovery vs verb discovery, both backed by a live registry
so results stay accurate as plugins register and unregister.

**The registry is not here.** This is the part that surprises people
adding a verb:

| Concern | Lives in |
|---|---|
| the registry | `auto-core.mailbox.commands` (`register` / `list` / `handle_message`, incl. schema validation) |
| dispatch | `auto-core.mailbox.router`, calling `commands.handle_message` |
| discovery | auto-agents' `commands_list` — a **relay**: it calls `core.mailbox.commands.list()` and forwards the entries, schema included |

So **a verb registered in auto-core (or in any family plugin) is discovered
and dispatched with no auto-agents change at all.** auto-core's
`editor.open` was added exactly that way and needed nothing here. Adding a
matching entry on this side would be a second implementation of whatever
the verb does, which is the shape worth avoiding rather than mirroring.

Either side *may* register — the registry is shared, and this repo does
both. Verbs registered here are `wake`, `say`, `send_user`, `peek`,
`diff_queue`, `refresh_agent_id`, `addressbook`, `commands_list`, plus the
`todos.*` roster (15 thin wrappers over `auto-core.todo` — ADR-0031 §5's
thirteen, plus `todos.fire` and `todos.automation_set` from ADR-0035) and
the `review.*` namespace, four verbs wrapping `worktree.review`. So "it
wraps another plugin's Lua API" is not by itself a reason to put a verb in
that plugin.

What matters is that a verb is registered **once**, and that the logic it
needs lives in exactly one place. `editor.open` belongs in auto-core
because the window-selection logic is auto-core's — registering it here as
well would mean a second implementation of that logic, which is the shape
worth avoiding. A thin wrapper with no logic of its own, like `todos.*`,
carries no such risk.

## Help

Every admin command is documented in a markdown file under `docs/help/`.
You can browse the docs three ways:

- **At the prompt** — append `help` or `?` to any command:

  ```
  agent add help          # → renders the `## add` section of agent.md
  kb init ?               # → same, for kb.md
  ?                       # → top-level index.md
  ```

- **In the editor** — `help open <verb> [<sub>]` opens the underlying
  markdown in a non-panel window so you can read or hand-edit. Edits
  persist; the plugin never rewrites these files.

- **On disk** — the files ship as plain markdown under
  `docs/help/{index,agent,kb,project,resource,term,config,general}.md`.

Tab-completion in the admin offers `help`, `help open`, and the verb
list as candidates.

## Wizards

The wizard runs **inside the admin prompt buffer** — it's not a modal float.
Each step shows the field name, choices (if any), and `[current]` default.
Press Enter to keep, type to change, **`<C-c>` to abort.**

| Verb                        | Wizard                                                            |
|-----------------------------|-------------------------------------------------------------------|
| `agent add`                 | New agent. Pre-filled with sensible defaults. Final step offers KB init. |
| `agent edit <slot>`         | Edit existing agent. Every field pre-fills with the current value.|
| `kb new`                    | Create + open a KB file. Single prompt.                           |
| `kb scope <slot>`           | Change a slot's `kb_scope` interactively (pre-fills current).     |
| `project import` (no arg)   | Pick a source project from a listing.                             |

## Admin panel

Slot 0 is a prompt buffer (`auto-agents://admin`). Type a verb, press Enter.
`help` lists everything.

```text
agent focus 3                          focus slot 3
agent list                             list configured agents
agent add                              open new-agent form
agent edit 4                           open edit form for slot 4
agent kill 2                           stop slot 2
agent restart 2                        kill + respawn slot 2
agent rename 1 reviewer-v2             rename a bootstrap entry
agent send 2 review the diff           write to slot 2's stdin
agent attach 2 src/foo.lua             send paths (or tree selection) to slot 2
agent move 2 5 [--swap]                relocate (or swap) a slot's content
agent task add 2 ship the migration    add a task to slot 2's list
agent task done 2 1                    mark task #1 done
agent task list [N]                    show tasks (one slot or all)
agent mem                              report RSS per running agent
kb path                                print kb root + ensure layout
kb scope 2 private                     change kb_scope (shared|private|isolated)
kb sync                                regenerate manifest.json per namespace
kb new <relative>                      create + open a kb file
kb open <relative>                     open a kb file
kb attach 2 <relative>                 send a kb path to slot 2
kb tail                                open log.md (autoread)
kb log                                 print path of log.md
kb obsidian-init                       scaffold .obsidian/ in kb root
resource grant 2 <path>                grant a path to slot 2
resource revoke 2 <path>               revoke a previously-granted path
resource cwd 2 [<path>]                set/clear explicit cwd for slot 2
resource list [N]                      list grants (all or for slot N)
resource manager set <S> <M>           designate slot M as manager of S
resource manager show                  show manager → subordinate map
config save                            persist current bootstrap to JSON
config reset                           delete persisted JSON
config show                            show effective config + persistence path
clear                                  wipe history above the prompt
quit                                   close the panel
status                                 list slots with state, focus, task counts
help, ?, :h                            this help
```

In normal mode the admin buffer also accepts `0`–`9` as one-key shortcuts that
focus a slot, and `<Tab>` completes verbs/sub-verbs/slot numbers.

## Playground terminals (T1..T4)

Four shared shells, **separate from agent slots**, mapped to `<F1>..<F4>`
by default. Same key:

| Current state                | Effect             |
|------------------------------|--------------------|
| Slot N has no terminal yet   | Create + focus     |
| Slot N hidden                | Show + focus       |
| Slot N visible, unfocused    | Move focus to it   |
| Slot N visible, focused      | Hide               |

Moving focus into any non-float window auto-hides every T1..T4 float at
once (scoped — won't fight lazygit/lazysql or other snacks consumers).

T-floats **persist across `:cd`**: a buffer-local marker
(`b:auto_agents_term_slot`) bypasses snacks's cwd-keyed hashing, so the
same `T1` follows you across worktree changes — your interactive REPL
or build watcher stays alive.

```
term focus 1            # also: <F1>
term send 2 npm run dev # paste-safe: chan_send body, 60ms defer, then \r
term list               # state of all four slots
term kill 3
term hide               # hide all four floats at once
```

User commands: `:AutoAgentsTerm <sub>` and `:AutoAgentsTermSend <slot>
<text>`. From lua: `require("auto-agents").term_send(slot, text)`.

Agents can drive playground terminals from their own admin slot — the
admin verb `term send <N> <text>` is callable inside any agent's
session, so a manager agent can dispatch a build command to T2 without
leaving its panel.

Disable defaults with `opts.term = { enabled = false }`. Customize the
F-keys with `opts.term.fkeys = { "<F1>", "<F2>", ... }`.

## Agent kinds

Each kind ships a small adapter that resolves the launch command and any
extra env. Override them per-slot via `cmd = { ... }` if you need flags.

| `kind`    | Default cmd            | Notes                                                                            |
|-----------|------------------------|----------------------------------------------------------------------------------|
| `claude`  | `claude`               | Anthropic Claude Code CLI                                                        |
| `codex`   | `codex`                | OpenAI Codex CLI; pads its own footer                                            |
| `antigravity` | `agy`              | Google Antigravity CLI (replaces deprecated `gemini`; v0.2.30+). Config nests at `~/.gemini/antigravity/`; mailbox tool root is `~/.gemini/antigravity/mailbox`. |
| `junie`   | `junie`                | JetBrains [Junie CLI](https://junie.jetbrains.com/docs/junie-cli.html); install via `npm i -g @jetbrains/junie-cli` |
| `goose`   | `goose session`        | [goose-docs.ai](https://goose-docs.ai/); env-var-driven (`GOOSE_MODEL`, `GOOSE_PROVIDER`, `GOOSE_PROVIDER__HOST` for ollama). Wizard prompts for `model` / `provider` / `api_base`. |
| `opencode`| `opencode`             | [opencode.ai](https://opencode.ai/docs); takes `--model <provider>/<id>`. Local LLMs configured in `~/.config/opencode/opencode.json` (no CLI flag for base URL). |
| `copilot` | `gh copilot`           | GitHub CLI extension                                                             |
| `generic` | `spec.cmd` or `$SHELL` | Catch-all for shells / homegrown tools                                           |

## Knowledge base

A project-local KB lives at `<git-root>/.auto-agents/kb` (or wherever
`[kb].root` in the TOML points). Every KB has an immutable `raw/` directory
for source material — agents read it, never edit it.

### KB types

When you create a KB (via `agent add` wizard or `kb init <type>`), pick a
specialized seed that comes with its own layout, conventions, and operations.
The seed is copied to `<kb_root>/AGENTS.md` and is the canonical contract for
that KB.

| Type       | When to use                                                                  |
|------------|------------------------------------------------------------------------------|
| `coding`   | **Default for nvim users.** Codebase conventions, ADRs, review playbooks.    |
| `wiki`     | LLM-wiki / Zettelkasten-flavored — durable, interlinked knowledge that compounds. |
| `research` | Paper-driven research notebook — papers, hypotheses, experiments, synthesis. |
| `ops`      | Runbook / SRE — alerts, runbooks, incidents, postmortems.                    |
| `library`  | Content-addressed document archive — immutable records with a partitioned, content-addressed `raw/` (v0.2.24+). |
| `general`  | Living KB — minimal seed; structure emerges from real work.                  |
| `custom`   | You supply the seed `.md`. Everything else (layout, raw immutability) still applies. |

The seeds ship under the plugin's `kb-seeds/` directory. They're
self-documenting markdown — open `kb-seeds/coding.md` (or any of the others)
to see the full contract before picking a type.

### Scope (per-agent)

`kb_scope` controls each agent's read/write window via env vars injected at spawn:

| Scope      | Reads                                         | Writes                  |
|------------|-----------------------------------------------|-------------------------|
| `shared`   | `kb/shared` + `kb/agents/*`                   | `kb/shared`             |
| `private`  | `kb/shared` + `kb/agents/<name>`              | `kb/agents/<name>`      |
| `isolated` | `kb/agents/<name>`                            | `kb/agents/<name>`      |

The plugin exports:

- `AUTO_AGENTS_KB_ROOT`  — kb root
- `AUTO_AGENTS_KB_READ`  — colon-separated read paths
- `AUTO_AGENTS_KB_WRITE` — single write dir
- `AUTO_AGENTS_KB_SCOPE` — the scope name itself

`kb sync` regenerates a `manifest.json` per namespace (sha256, mtime, size,
wikilinks). `kb obsidian-init` scaffolds an Obsidian vault config in the kb
root so you can browse the same files visually.

### Telling the agent about the KB

Two layers cooperate:

1. **`<kb_root>/AGENTS.md`** — the canonical KB contract (copied from the
   seed when you ran `kb init`). Defines the layout, operations, frontmatter,
   immutability rule, and things to avoid for *this* KB. `<kb_root>/CLAUDE.md`
   and `<kb_root>/GEMINI.md` sit alongside as thin pointers so each kind
   auto-loads the same source of truth.
2. **Per-kind instruction file at the agent's cwd** — `CLAUDE.md` /
   `AGENTS.md` / `GEMINI.md` (per kind), with a small auto-agents block
   between `<!-- auto-agents:begin -->` and `<!-- auto-agents:end -->`
   markers. The block lists the env vars (`$AUTO_AGENTS_KB_ROOT` etc.) and
   directs the agent to read `<kb_root>/AGENTS.md` for the full schema.

Your hand-written content above or below the block is preserved on every
re-spawn — the plugin only rewrites the delimited section.

## Resource grants

Per-slot allowlists exposed to the agent process via env vars:

- `AUTO_AGENTS_ALLOWED_PATHS` — colon-separated paths from `resource grant`.
- `AUTO_AGENTS_CWD`           — explicit cwd from `resource cwd`.
- `AUTO_AGENTS_MANAGER_SLOT`  — the slot that manages this one, if any.

Grants are **best-effort coordination, not OS sandboxing** — the agent has to
honor them. Use them for prompt-shaping ("only touch these paths") and for
documenting boundaries between sub-agents.

## Known issues

### Junie and Goose: leftmost columns clipped at spawn / on slot navigation

When a `junie` or `goose` agent first spawns into the panel — and again
when you navigate away and back — the leftmost ~2-4 columns of the TUI
content render clipped (e.g. `Welcome to Junie` displays as `ome to
Junie`). Once the artifact appears, simply re-focusing the slot does
not clear it.

**Workaround for the session:** press your panel-toggle key (default
`<F5>` if you bound it that way, otherwise `:AutoAgents`) **twice** —
once to close the panel, once to reopen it. The close-and-reopen
forces nvim to re-instantiate the vterm-to-window binding for the
agent's buffer, which produces a clean repaint. Subsequent slot
navigation within the same session stays clean.

**Why we haven't auto-fixed it:** investigated and unresolved. SIGWINCH
delivery and per-kind redraw nudges (`Ctrl+L`, `F5`, FocusIn) all
verified insufficient; only window/buffer rebind clears the artifact,
and we don't yet have a non-disruptive way to trigger that rebind
automatically without flickering the panel. Not present on
`claude` / `codex` / `antigravity` (which full-clear on SIGWINCH and self-correct).

Goose has a known upstream cause:
[block/goose#8177](https://github.com/block/goose/issues/8177) —
goose has no SIGWINCH handler at all in its CLI, so the artifact will
persist until upstream fixes it.

Junie's compose-for-terminal renderer does handle SIGWINCH but its
spawn-time render race remains undiagnosed.

## Continuous integration

`.github/workflows/ci.yml` runs two jobs, and the split between them is
the point.

**`lua` — the gate.** Every push to `main` and every pull request. It
installs a pinned toolchain and hands the verdict to `tests/run-all.sh`.
Everything is pinned, so a red run means *this change* rather than
something that moved underneath it:

| Pinned by | What | Why |
|---|---|---|
| commit SHA | `actions/checkout` | a tag can be moved to different code under the same name |
| version **and SHA-256** | Neovim `v0.12.5` | a release asset can be replaced under the same tag and name, so the version alone is not reproducible |
| commit SHA | `auto-core.nvim`, `worktree.nvim`, `plenary.nvim` | reproducibility; the pin's age is reported (see below) |

**`drift` — the early warning.** The same suite, with **auto-core resolved
at its default branch** instead of the commit `lua` pins. A regression in
auto-core reaches its consumers before anyone notices, and a consumer
pinned to a frozen auto-core is precisely the thing that cannot notice.
Both properties are wanted and they conflict, so they are split rather
than traded.

`drift` runs on a **schedule (Mondays, 06:00 UTC) and manual dispatch
only** — deliberately *not* on push or pull request. On push it would
redden the merge run for an upstream change unrelated to the PR being
merged, and would put a code path on the merge that no PR run exercised.

### `tests/run-all.sh` is the whole verdict

CI does not reimplement the gate; it supplies the environment and lets the
runner be the judge. `run-all.sh` runs every suite and treats a **missing**
`N passed, M failed` summary line as a hard failure, rather than parsing
whatever partial PASS lines a suite emitted before it stopped. That
sentinel is the only thing that catches a C-level crash mid-run, which is
why running a single suite by hand is **not** a substitute:

```sh
./tests/run-all.sh                              # the gate
nvim --headless -u NONE -l tests/smoke.lua      # one suite, while iterating
```

### A failing `drift` run has an addressee

A red row in the Actions tab is not a signal — nobody is obliged to open
it, and the one time a drift job caught a real regression in this family,
it was caught because somebody dispatched it by hand while investigating
something unrelated. Left to the schedule it would have gone red and sat
there. So on failure the job opens an **issue**, which has an addressee
that outlives a run's log retention and records *when* divergence started:

- **One issue per repo**, found by the **`ci-drift` label**, not by title.
  Title matching breaks the moment somebody edits the title — the next
  failure opens a duplicate instead of commenting.
- Reopened and commented rather than duplicated, so a month of Mondays is
  one thread instead of four issues nobody triages.
- **Closed automatically on the next green** drift run, with a comment
  saying the divergence cleared.

A `ci-drift` issue does **not** mean this plugin is broken for its users:
the gating job pins auto-core and is green. It means auto-core has moved in
a way this suite does not accept yet, and one of the two has to change
before the pin is bumped.

### Exercising the notifier, and the pin's age

`workflow_dispatch` takes a **`force_drift_failure`** boolean that fails the
drift job deliberately:

```sh
gh workflow run ci.yml --repo yongjohnlee80/auto-agents --ref main \
  -f force_drift_failure=true
```

The whole premise of the notifier is that an unread signal is not a signal
— so an untested notifier is the same bug one layer up, and there has to be
a way to make it fire without waiting for auto-core to break something.

Proven here, both halves, on the real runner: a forced dispatch opened
[#10](https://github.com/yongjohnlee80/auto-agents/issues/10)
and the next green drift run closed it again. The design was piloted
in
[auto-finder.nvim](https://github.com/yongjohnlee80/auto-finder.nvim) and
rolled out unchanged.

The `lua` job also reports **how stale the auto-core pin is**, as routine
output rather than something discovered while debugging.
It is
reported and never acted on: **bumping the pin is a deliberate, reviewed
change, never automatic.** A gating job that changes under a PR
reintroduces exactly the mystery failure on unrelated work that pinning was
adopted to prevent.

Two guards keep that report honest, and both exist because the first
version was wrong:

- It reads the compare API's **`ahead_by`**, not `behind_by`. For
  `compare/PIN...main`, `behind_by` is always `0` when the pin is an
  ancestor — the first version printed `0` on a pin eight commits stale,
  ran green, and would have called the pin current for as long as the repo
  existed. An unparseable answer now emits a `::warning` saying staleness
  was **not determined**, because `0` reads as "current".
- It **counts the `AUTO_CORE_REF` values in the file** and fails with
  `::error` if there is more than one. When this design was rolled out
  across the family, the step arrived carrying the pilot repo's SHA — every
  copy would have reported the age of a pin it does not use, in a step
  whose whole job is noticing staleness, with nothing about the copy
  looking wrong.
## Status

- [x] **M1** scaffold, terminal providers (snacks/native/none), per-instance state
- [x] **M2** panel, slots, admin buffer, tab completion, form buffer
- [x] **M3** agent registry, adapters (claude/codex/gemini/junie/aider/goose/opencode/copilot/generic), persistence
- [x] **M4** knowledge base (shared/private/isolated, manifest, Obsidian compat)
- [x] **M5** resource grants, manager designation
- [ ] **M6** README polish, ARCHITECTURE.md, test suite, `v0.1.0` tag
- [x] **M7** per-Claude MCP / WebSocket bridge — vendored claudecode.nvim's WS stack as of v0.2.x; `openDiff` + `close_tab` registered, `auto-agents:diff_queued`/`diff_removed` topics drive the unified queue
- [x] **M8** diff queue editorial workflow (v0.2.3) — multi-pane review float, `A`/`D`/`M`/`E`/`<CR>` actions, native motions + treesitter in the diff panes, REQUEST CHANGE two-channel feedback, auto-close on drain

## Attribution

Core terminal-provider scaffolding, logger, cwd resolution, and tree
integrations are adapted from
[`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim) under the
MIT License. See [`NOTICE`](./NOTICE) for the list of vendored modules.

## License

MIT. See [`LICENSE`](./LICENSE).
