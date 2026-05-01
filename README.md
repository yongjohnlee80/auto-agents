# auto-agents.nvim

> Multi-agent orchestration panel for Neovim. One right-side window, up to 9 agent
> terminal buffers, slot-0 admin panel for orchestration, project-local shared
> knowledge-base.

**Status: pre-release (`v0.1.0-pre.1`).** Foundation only — single-pane terminal not
yet wired. See [`PLAN.md`](./PLAN.md) for the full design and milestone breakdown,
and [`LAYERED-ARCHITECTURE.md`](./LAYERED-ARCHITECTURE.md) for the rationale behind
the process-and-protocol layer split.

## Install (lazy.nvim)

```lua
{
  "yongjohnlee80/auto-agents",
  version = "^0.1.0",
  opts = {},
}
```

## Status

- [x] M1 foundation: scaffold, license, vendored utilities (logger, utils, cwd), config schema, init API stubs, `:AutoAgents` command
- [ ] M1 terminal providers (snacks/native/none, factory-based per-instance state)
- [ ] M2 panel + slots + admin buffer + tab completion + form buffer
- [ ] M3 agent registry + adapters (claude/codex/gemini/generic)
- [ ] M4 knowledge-base (shared/private/isolated; Obsidian compatibility)
- [ ] M5 resource grants + manager agents
- [ ] M6 polish, docs, `v0.1.0`

## Attribution

Core terminal-provider scaffolding, logger, cwd resolution, and tree integrations
are adapted from [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim)
under the MIT License. See [`NOTICE`](./NOTICE) for the list of vendored modules.

## License

MIT. See [`LICENSE`](./LICENSE).
