# auto-agents.nvim

> Multi-agent orchestration panel for Neovim. One right-side window holds up to
> ten slots — slot **0** is an admin REPL, slots **1–5** are main-window agent
> terminals, slots **6–9** open as `snacks.nvim` floats. Project-local
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
knowledge-base scope, its own grant of paths/env, and its own task list.
Sub-agents (slots 6–9) pop out as floats so a manager agent can delegate
without losing the main view.

## Install

```lua
-- lazy.nvim
{
  "yongjohnlee80/auto-agents",
  version = "^0.1.0",
  dependencies = { "folke/snacks.nvim" },
  opts = {},  -- agents/KB live in TOML — see below
}
```

`snacks.nvim` is required for the sub-agent floats and the navigation dock.

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
                    │  │  0 1 2 3 4 5 │   │   slots 0–5: main panel
                    │  └──────────────┘   │   (single window, swapped buffers)
                    │  ░░░░░░░░░░░░░░░░   │
                    │  ░  agent term  ░   │
                    │  ░░░░░░░░░░░░░░░░   │
                    └─────────────────────┘

                   slots 6–9: snacks floats
```

- **Slot 0** — admin REPL (a prompt buffer). Type `help` and hit Enter.
- **Slots 1–5** — agent terminals in the right panel. One window, many buffers;
  the winbar shows `0 1 2 3 4 5` with the focused slot highlighted.
- **Slots 6–9** — sub-agent floats. Useful for ephemeral helpers, code review
  passes, or anything you want side-by-side rather than tabbed.

## Keymaps & commands

`auto-agents` ships **no global keymaps by default** — bind them yourself in the
lazy spec under `keys = { ... }`. Recommended bindings (this is what the
maintainer uses):

| Lhs              | Action                                   |
|------------------|------------------------------------------|
| `<F5>`           | `:AutoAgents`           — toggle panel   |
| `<F6>` / `<F12>` | `:AutoAgentsDock`       — open nav dock  |
| `<leader>ac`     | `:AutoAgents`           — toggle panel   |
| `<leader>a0`..`9`| `:AutoAgentsFocus N`    — jump to slot N |

Inside the **navigation dock** (an attached float):

- `0`–`9` jumps to that slot.
- `e` returns to the editor (the most recently used non-panel window).
- Any other key closes the dock.

User commands (always available):

| Command                   | Effect                                                    |
|---------------------------|-----------------------------------------------------------|
| `:AutoAgents[!]`          | Toggle the panel. `!` bypasses the host-width guard.      |
| `:AutoAgentsFocus <N>`    | Focus slot N. Routes 0–5 to the main panel, 6–9 to floats.|
| `:AutoAgentsSub <N>`      | Toggle a sub-agent float (slots 6–9).                     |
| `:AutoAgentsDock`         | Toggle the rightmost-centered navigation dock.            |

For an example wiring (with dynamic `which-key` descriptions per slot), see
[`examples/lazy-spec.lua`](./examples/lazy-spec.lua) — or the maintainer's live
config at [`autovim`](https://github.com/yongjohnlee80/autovim/blob/main/lua/plugins/auto-agents.lua).

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
  kind (claude|codex|gemini|junie|aider|copilot|generic)  [claude]:
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
kind          = "claude"             # claude|codex|gemini|junie|aider|copilot|generic
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
    min_width     = 50,
    max_width     = 120,
    percentage    = 0.30,
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
| `gemini`  | `gemini`               | Google Gemini CLI                                                                |
| `junie`   | `junie`                | JetBrains [Junie CLI](https://junie.jetbrains.com/docs/junie-cli.html); install via `npm i -g @jetbrains/junie-cli` |
| `aider`   | `aider --read AGENTS.md` | [aider.chat](https://aider.chat/docs/usage.html); auto-passes `--read AGENTS.md` since aider doesn't auto-load it |
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

## Status

- [x] **M1** scaffold, terminal providers (snacks/native/none), per-instance state
- [x] **M2** panel, slots, admin buffer, tab completion, form buffer
- [x] **M3** agent registry, adapters (claude/codex/gemini/junie/aider/copilot/generic), persistence
- [x] **M4** knowledge base (shared/private/isolated, manifest, Obsidian compat)
- [x] **M5** resource grants, manager designation
- [ ] **M6** README polish, ARCHITECTURE.md, test suite, `v0.1.0` tag
- [ ] **M7** per-Claude MCP / WebSocket bridge (deferred; out of scope for v0.1)

## Attribution

Core terminal-provider scaffolding, logger, cwd resolution, and tree
integrations are adapted from
[`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim) under the
MIT License. See [`NOTICE`](./NOTICE) for the list of vendored modules.

## License

MIT. See [`LICENSE`](./LICENSE).
