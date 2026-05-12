# agent — slot operations

The `agent` verb manages everything tied to a single slot in the panel:
its config, its running terminal, its task list, its placement.

Slots are partitioned: slot **0** is the admin REPL (this prompt), slots
**1–5** are the main right-window panel (one window, swapped buffers),
slots **6–9** are sub-agent floats. The admin wizard, the TOML store,
and the navigation dock all share the same numbering.

## focus

```
agent focus <N>          # alias of :AutoAgentsFocus N and <leader>aN
```

Focuses slot `N`. Routes 0–5 to the main window, 6–9 to a snacks float.
For 1–5, also resends a SIGWINCH to the underlying TUI (with the slot's
`bottom_margin` reserved) so the TUI redraws cleanly at the panel's
current dimensions.

**Affects:** `state.focused_slot` (used to restore on panel reopen).
**Does not** spawn the agent — focusing an unconfigured slot drops you
into a fallback `$SHELL`.

## list

```
agent list
```

Same output as `status`. Shows every slot 0..9 with its label, where
it lives (admin / main / float), its run state, and any open task count.

## add

```
agent add                # opens the wizard inside this admin buffer
```

Step-by-step wizard. Each step shows `[default]` — Enter to keep it,
type to change, **`<C-c>` to abort**. The final step asks for a KB type
(coding | wiki | research | ops | general | custom | none).

**Affects:**
- Writes a new `[[agents]]` block to the active TOML
  (per-project if one exists, else global).
- If a KB type is picked, scaffolds the KB layout under
  `<kb_root>` with the chosen seed copied to `<kb_root>/AGENTS.md`.
- Refreshes `<leader>aN` keymap descriptions (so which-key reflects
  the new slot label).
- Triggers `focus_slot(N)` after save.

## edit

```
agent edit <N>           # wizard pre-fills every field with the current value
```

Same wizard as `add`, but every default is the existing entry's value.
Press Enter on every step to keep everything; only changed fields are
re-written.

**Affects:** rewrites that slot's `[[agents]]` block in the active TOML.
Does **not** restart the running terminal — most fields take effect on
next spawn (use `agent restart <N>` to apply immediately). Renames also
update `<leader>aN` descriptions live.

## remove

```
agent remove <N>      # alias: agent rm <N>
```

Kills any running terminal in slot `N` and **deletes** that slot's
`[[agents]]` entry from the active TOML. After removal the slot
reverts to a plain shell on next focus (the generic adapter
fallback). Idempotent: removing an already-empty slot is a no-op.

**Affects:** running process is terminated; bootstrap entry is
deleted from disk. KB instruction files (CLAUDE.md / AGENTS.md /
GEMINI.md / .junie/guidelines.md) and grants are **not** scrubbed —
the auto-agents block in those files becomes stale but harmless,
remove manually if the file matters.

## kill

```
agent kill <N>
```

Stops the running terminal in slot `N`. Main slots (1–5): `jobstop` +
buffer wipe; sub-floats (6–9): close the snacks float. Bootstrap entry
is **not** removed — the agent reappears (unspawned) the next time you
focus the slot. To delete the entry too, use `agent remove <N>`.

**Affects:** running process is terminated. KB instruction files left
intact; resource grants left intact.

## restart

```
agent restart <N>
```

`kill` followed by `focus` — the slot respawns with the current TOML
config. Use this after `agent edit` to apply config changes
immediately.

## rename

```
agent rename <N> <new-name>
```

Renames the bootstrap entry's `name` field in-place. Live: the winbar
and `<leader>aN` description update without a restart. The KB scope
directory under `kb/agents/<name>/` does **not** auto-migrate — if the
agent has private/isolated KB content, move it manually if you care.

**Affects:** TOML is saved; in-memory state updated; keymap descriptions
refreshed.

## send

```
agent send <N> <text...>
```

Writes `<text>` to the agent's stdin via `nvim_chan_send`. No
interpretation — one shot, no submit byte added. For a paste-safe
prompt that ends with Enter, prefer `term send` (for T1..T4) or send
the text manually via the slot's terminal.

**Affects:** purely runtime. Useful for scripted dispatch from the
admin or programmatic from another agent.

## attach

```
agent attach <N> [<path1> <path2> …]
```

Sends file paths to slot `N`'s stdin. With no path args, queries the
active tree explorer (neo-tree, oil, mini.files, netrw, nvim-tree) for
the current selection / cursor target.

**Affects:** runtime stdin. The agent receives a space-separated list
of absolute paths it can choose to read.

## move

```
agent move <from> <to> [--swap]
```

Relocates a slot's bootstrap entry (and running terminal, when both
sides have one). Same-side only — main↔float crossings require a kill
+ re-add through the wizard. With `--swap`, exchanges contents.

**Affects:** TOML is rewritten with the new slot numbers. Winbar +
keymap descriptions refresh. `state.focused_slot` follows the move.

## task

```
agent task add <N> <text>
agent task done <N> <index>
agent task list [<N>]
```

A lightweight per-slot task list, stored in the TOML's `[[agents]]`
entry as `tasks = [...]`. `done` removes the task by 1-based index.
List with no slot shows every slot's tasks.

**Affects:** TOML is saved on each mutation. Tasks are visible via
`status` (suffix `[N tasks]`). They're informational — agents read
them when you tell them to.

## mem

```
agent mem
```

Reports RSS per running agent (Linux `/proc` only — silently empty on
other platforms). Useful for spotting runaways. Shows total at the
bottom.

## model (preferred CLI model)

Optional `[[agents]].model` field. Per-kind handling at spawn:

- claude/codex/gemini/junie/aider/opencode → appended as `--model <id>`
- goose → exported as `GOOSE_MODEL` env var (env vars override
  `goose configure`). `goose` also reads `GOOSE_PROVIDER` (from
  `[[agents]].provider`) and `GOOSE_PROVIDER__HOST` (from
  `api_base`).
- opencode model id is `<provider>/<id>` format
  (e.g. `anthropic/claude-sonnet-4-5`, `ollama/llama3.1`).

Ignored for `copilot` and `generic`, and skipped when the user has
overridden `cmd = [...]` — in that case the user's argv is used
verbatim.

There's no curated allow-list of model ids — each CLI evolves on its
own cadence and an allow-list rots immediately. Whatever string you
set is passed through verbatim; if the CLI rejects it, you'll see
the error in the agent's terminal.

### Local-LLM connection settings: `model`, `provider`, `api_base`

Aider, goose, and opencode all take per-spawn connection settings.
The wizard prompts for them only when relevant (other kinds skip
these steps and use whatever `:AutoAgentsModel` set instead).

| field | aider | goose | opencode |
|-------|-------|-------|----------|
| `model` | ✓ `--model` | ✓ `GOOSE_MODEL` env | ✓ `--model` |
| `provider` | — | ✓ `GOOSE_PROVIDER` env | — (encoded in model id) |
| `api_base` | ✓ `--api-base` | ✓ `GOOSE_PROVIDER__HOST` env | — (configure in `opencode.json`) |

Example aider slot pointing at ollama on the LAN:

```toml
[[agents]]
slot     = 4
kind     = "aider"
name     = "lentil"
model    = "ollama_chat/llama3.1"
api_base = "http://192.168.1.10:11434"
```

Renders to `aider --model ollama_chat/llama3.1 --api-base
http://192.168.1.10:11434 --read AGENTS.md` at spawn.

Equivalent goose slot:

```toml
[[agents]]
slot     = 5
kind     = "goose"
name     = "gander"
model    = "llama3.1"
provider = "ollama"
api_base = "http://192.168.1.10:11434"
```

Spawned as `goose session` with `GOOSE_MODEL`, `GOOSE_PROVIDER`,
`GOOSE_PROVIDER__HOST` exported into the agent's env.

For cloud providers (anthropic/openai/etc.) where the base URL is
implicit, leave `api_base` blank — provider auth env vars
(`ANTHROPIC_API_KEY` etc.) carry the connection.

### `:AutoAgentsModel <name> [<model>|-]`

- `:AutoAgentsModel jarvis` — show the agent's current preference.
- `:AutoAgentsModel jarvis claude-opus-4-7` — set.
- `:AutoAgentsModel jarvis -` — clear (back to CLI default).

Mutates the live in-memory bootstrap entry **and** persists to the
active TOML (project file if present, else global) via the same
`save_current()` path the wizard uses. The change takes effect on
the **next** spawn of that slot — the running session keeps the
model it was launched with.

### Agents persist their own preference

The auto-injected instruction file (`CLAUDE.md` / `AGENTS.md` /
`GEMINI.md` / `.junie/guidelines.md` at the agent's cwd) carries the agent's current
preference and tells it how to update the config when the user
asks for a model change mid-session: run

    nvim --server "$NVIM" --remote-expr 'execute("AutoAgentsModel <name> <new-model>")'

…from any shell tool the agent has. `$NVIM` is set automatically
inside the agent's terminal and points at the parent nvim's socket,
so the remote expression invokes `:AutoAgentsModel` in your editor
session — no manual `:` typing needed. The user is still the gate
because the agent must surface the question first; the persistence
itself is automated.

## status (idle / waiting / working)

Each agent slot carries a runtime status that surfaces in the panel
winbar and the navigator dock. Three states:

| State | Panel sigil | Dock label   | Meaning |
|-------|-------------|--------------|---------|
| `idle`    | (none)  | `(idle)`     | done with the previous turn, ready for the next prompt |
| `waiting` | `*`     | `(waiting)`  | needs user input; about to ask a question |
| `working` | `+`     | `(working)`  | running a non-trivial unit of work right now |

Wide panel: ` 1: *Jarvis ` (sigil precedes the name). Narrow panel
(when the strip wouldn't fit): ` 1* `. The sigil's color comes from
the `AutoAgentsStatusWaiting` (linked to `WarningMsg`) and
`AutoAgentsStatusWorking` (linked to `MoreMsg`) highlight groups
— override in your colorscheme to taste.

Status is **ephemeral** — never written to TOML, cleared whenever
the agent process exits. A stale `working` will not survive a kill
or a vim restart.

### `:AutoAgentsStatus <slot|name> <state>`

- `:AutoAgentsStatus 1 working` — by slot
- `:AutoAgentsStatus jarvis waiting` — by name
- `:AutoAgentsStatus 1 idle` — clears (back to no sigil)

Useful for manual override; in normal use the agent reports its own
transitions (see below).

### Agents self-report their own status

The auto-injected instruction file tells each interactive agent
(claude/codex/gemini/junie/aider) the three transitions and the exact shell
commands to run for each. Inside the agent's terminal, `$NVIM` is
set to the parent nvim's socket, so a one-liner like

    nvim --server "$NVIM" --remote-expr 'execute("AutoAgentsStatus 1 working")'

invokes `:AutoAgentsStatus 1 working` in your editor without any
`:` typing. The agent runs `working` at the start of a non-trivial
turn, `waiting` if it stops to ask a question, and `idle` when
done. Status pings are silent on success — failures land in
`:messages` but never block the agent's real work.

The user is **not** in the loop for these transitions, by design.
They fire constantly and would be intolerable otherwise. Compare
with `:AutoAgentsModel`, where the agent surfaces a question first
and persists only if the user agrees — model preferences are
durable, status pings are not.

## diff_review (in-editor diff splits for proposed edits)

Per-agent boolean. The wizard asks **"Show diff views from this agent
in your editor?"** on add/edit (default y for `kind = "claude"`,
N for the rest).

- **`diff_review = true`** — when this agent proposes a file edit,
  it lands in the **Unified Diff Queue** (`:AutoAgentsDiffQueue`).
  Opening an item from the queue opens a native diff split in your
  editor (left current, right proposed). You can edit the proposed
  side manually before accepting; `:w` on the proposed buffer
  accepts and writes the file, closing the diff rejects.
  Implemented by injecting `AUTO_AGENTS_IDE_INTEGRATION=true`,
  `AUTO_AGENTS_MCP_PORT=<port>`, and `AUTO_AGENTS_MCP_URL=<url>`
  at spawn so the agent's `openDiff` tool routes to our internal MCP
  bridge (SSE over HTTP). Claude Code agents also receive legacy
  `CLAUDE_CODE_SSE_PORT` for compatibility.

- **`diff_review = false`** — no MCP env injection. Claude Code CLI
  falls back to its built-in TUI confirm prompt **inside that agent's
  own terminal** — useful for sub-agents whose every edit you don't
  want popping at you alongside your main coding agent's.

Typical setup: one main coding agent (jarvis in slot 1) has
`diff_review = true`; workers in other slots have it `false` so their
edits stay scoped to their own terminals. To watch a sub-agent's
proposed edits, focus its slot.

### Roadmap: manager-routed approval

A future milestone (post-v0.1.0, alongside M5.C inter-agent comms)
will let sub-agents route diffs through their **manager** (set via
`resource manager set <S> <M>`): subordinate proposes → manager
reviews/edits/approves → result returns to subordinate. That requires
a deeper Claude Code CLI integration than the current `openDiff` tool
exposes, so it ships separately from v0.1.0.

## How agent operations interact with the rest of the system

- **Project**: `agent add/edit/move/rename` writes to the **active**
  TOML — that's the per-project file if `project init` was run, else
  the global default. `project remove` falls back to global; agents
  added before `init` "promote" to project on next save.
- **KB**: Each agent has a `kb_scope` (shared|private|isolated) which
  controls the env vars at spawn (`$AUTO_AGENTS_KB_{ROOT,READ,WRITE}`).
  KB type is project-wide (`[kb].type` in TOML). The instruction file
  at the agent's cwd (`CLAUDE.md`/`AGENTS.md`/`GEMINI.md`) points at
  `<kb_root>/AGENTS.md` for the schema.
- **Resources**: Per-slot grants (`resource grant N <path>`) and cwd
  overrides land in the spawn's env. Relevant during fresh spawn or
  `restart`, not applied to a running terminal.
- **Manager designation**: `resource manager set <S> <M>` records that
  slot `M` manages slot `S`; metadata only for v0.1.0.
