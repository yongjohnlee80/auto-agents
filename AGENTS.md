<!-- auto-agents:begin -->
## auto-agents knowledge base

This project uses [auto-agents.nvim](https://github.com/yongjohnlee80/auto-agents)
for multi-agent orchestration. The agent in slot 2 (kind: codex, name: lector) has the
following knowledge-base configured:

- KB root:    `/Users/yongsunglee/.config/nvim/.auto-agents-config/kb`  (`$AUTO_AGENTS_KB_ROOT`)
- KB type:    `coding`
- KB scope:   `shared`
- Read from:  `$AUTO_AGENTS_KB_READ`  (colon-separated)
- Write to:   `$AUTO_AGENTS_KB_WRITE` (single directory)

### Read this first

**The canonical schema for this KB is at `/Users/yongsunglee/.config/nvim/.auto-agents-config/kb/AGENTS.md`.**
Read it before any non-trivial KB operation. It defines the directory
layout, the required frontmatter, the operations (ingest / review / lint /
etc.), the immutability rule for `raw/`, and the things to avoid.

Each KB type has its own contract — `coding`, `wiki`, `research`, `ops`,
or `general`. The `AGENTS.md` at the KB root is authoritative for this
specific KB; this file (auto-injected at the agent's cwd) is a minimal
pointer with the env vars and a one-line convention summary.

### Quick conventions

- **`raw/` is immutable.** Read it; never edit or delete its contents.
- **Read before writing.** Consult `shared/` for durable conventions and
  your own `agents/lector/` for prior operational notes.
- **Append, don't overwrite.** Use `[[wikilinks]]` to cross-reference.
- **Audit trail.** Append a one-line entry to `log.md` after each
  meaningful KB write (e.g. `## [2026-05-01 14:00] op | summary`).

### Model preference

Your preferred model is `gpt-5.5`. This is persisted in
auto-agents' TOML config and passed to the CLI as `--model <id>` on
every spawn.

If the user asks you to switch models mid-session — switch first, then
ask: "Should I persist this as your preferred model for me (lector) going forward?" If yes, write it to the config
yourself by running this in any shell tool you have:

    nvim --server "$NVIM" --remote-expr 'execute("AutoAgentsModel lector <new-model>")'

Replace `<new-model>` with the model id (e.g. `claude-opus-4-7`).
`$NVIM` is set automatically inside this terminal and points at the
parent nvim's socket — the command runs `:AutoAgentsModel lector
<new-model>` in that nvim, which updates the TOML and saves it.

To clear the preference (back to CLI default):

    nvim --server "$NVIM" --remote-expr 'execute("AutoAgentsModel lector -")'

The change takes effect on the **next** agent restart, not the current
session. Tell the user to restart this slot when convenient.

<!-- auto-agents:end -->
