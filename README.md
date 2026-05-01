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
- [Slot model](#slot-model)
- [Keymaps & commands](#keymaps--commands)
- [Bootstrap config](#bootstrap-config)
- [Admin panel](#admin-panel)
- [Agent kinds](#agent-kinds)
- [Knowledge base](#knowledge-base)
- [Resource grants](#resource-grants)
- [Persistence](#persistence)
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
  opts = {
    agents = {
      bootstrap = {
        { slot = 1, kind = "claude", name = "main",     title = "Claude" },
        { slot = 2, kind = "codex",  name = "reviewer", title = "Codex",
          bottom_margin = 0 },                  -- codex pads its own footer
        { slot = 5, kind = "claude", name = "scout",    title = "Claude scout" },
        -- floats:
        { slot = 6, kind = "codex",   name = "side",       title = "Codex side" },
        { slot = 7, kind = "copilot", name = "gh-copilot", title = "Copilot" },
      },
    },
  },
}
```

`snacks.nvim` is required for the sub-agent floats and the navigation dock.
Empty slots fall back to `$SHELL`, so you can leave any of them unconfigured.

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

## Bootstrap config

Each entry in `agents.bootstrap` declares one slot. All fields except `slot`
are optional.

```lua
{
  slot          = 2,                       -- 1..9
  kind          = "codex",                 -- claude|codex|gemini|copilot|generic
  name          = "reviewer",              -- handle (used for kb dir, grants)
  title         = "Codex",                 -- shown in winbar / float title
  role          = "review code changes",   -- free-text prompt hint
  cwd           = "~/Source/proj",         -- explicit cwd; defaults to git root
  cmd           = { "codex", "--mini" },   -- override adapter cmd
  allowed_paths = { "src/", "tests/" },    -- exported as AUTO_AGENTS_ALLOWED_PATHS
  manager       = nil,                     -- slot N that manages this one (M5)
  kb_scope      = "shared",                -- shared|private|isolated
  bottom_margin = 0,                       -- override panel.bottom_margin for this slot
}
```

Top-level `opts`:

```lua
{
  log_level = "info",
  panel = {
    side          = "right",   -- left|right
    min_width     = 50,
    max_width     = 120,
    percentage    = 0.30,      -- of editor cols
    editor_floor  = 40,        -- refuse to open if editor would be narrower
    slot_rail     = "winbar",  -- winbar|vertical|off
    bottom_margin = 1,         -- TUI footer breathing room (0 for codex)
  },
  agents   = { default_kind = "claude", primary_kind = "claude", bootstrap = { ... } },
  kb       = { default_scope = "shared" },
  terminal = { provider = "auto", git_repo_cwd = true },
}
```

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

## Agent kinds

Each kind ships a small adapter that resolves the launch command and any
extra env. Override them per-slot via `cmd = { ... }` if you need flags.

| `kind`    | Default cmd            | Notes                                    |
|-----------|------------------------|------------------------------------------|
| `claude`  | `claude`               | Anthropic Claude Code CLI                |
| `codex`   | `codex`                | OpenAI Codex CLI; pads its own footer    |
| `gemini`  | `gemini`               | Google Gemini CLI                        |
| `copilot` | `gh copilot`           | GitHub CLI extension                     |
| `generic` | `spec.cmd` or `$SHELL` | Catch-all for shells / homegrown tools   |

## Knowledge base

A project-local KB lives at `<git-root>/.auto-agents/kb`. `kb_scope` controls
each agent's read/write window via env vars injected at spawn:

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

## Resource grants

Per-slot allowlists exposed to the agent process via env vars:

- `AUTO_AGENTS_ALLOWED_PATHS` — colon-separated paths from `resource grant`.
- `AUTO_AGENTS_CWD`           — explicit cwd from `resource cwd`.
- `AUTO_AGENTS_MANAGER_SLOT`  — the slot that manages this one, if any.

Grants are **best-effort coordination, not OS sandboxing** — the agent has to
honor them. Use them for prompt-shaping ("only touch these paths") and for
documenting boundaries between sub-agents.

## Persistence

Bootstrap mutations (form save, rename, move, `config save`) write to
`<stdpath('data')>/auto-agents/<sha16-of-cwd>.json`. On next startup the
plugin merges the persisted bootstrap on top of the lazy spec, so live
edits survive a restart. `config reset` deletes the JSON and reverts to the
spec baseline.

## Status

- [x] **M1** scaffold, terminal providers (snacks/native/none), per-instance state
- [x] **M2** panel, slots, admin buffer, tab completion, form buffer
- [x] **M3** agent registry, adapters (claude/codex/gemini/copilot/generic), persistence
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
