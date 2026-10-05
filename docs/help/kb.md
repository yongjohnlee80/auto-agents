# kb — knowledge base

Since v0.3.0 auto-agents owns no KB code (ADR 1791209946 §7). A
project's agents share **one KB: the project's primary KB**, recorded by
`auto-core.kb`. Scaffolding, search and maintenance live in AutoDoc.

```
kb                                 # show the project's primary KB
```

Prints the primary's root and AutoDoc workspace, or says the project
has none. It creates nothing.

## What an agent gets at spawn

- `AUTO_AGENTS_KB_ROOT`: the primary's root, also granted with
  `--add-dir`.
- `AUTODOC_WORKSPACE`: the primary's AutoDoc workspace, when it names one.
- `AUTODOC_KB_OPERATIONS_DOC`: `<root>/KB_OPERATIONS.md`, when it exists.
- `AUTO_AGENTS_TODOS_CONVENTION_DOC`: the todo-handling convention,
  unchanged: `<root>/conventions/todo-handling.md`, then
  `<root>/shared/conventions/todo-handling.md`, then the bundled seed.

With no primary, the agent starts with no KB environment and its
instruction file tells it to ask you which KB to use.

The managed block in each agent's instruction file (`CLAUDE.md`,
`AGENTS.md`, …) carries three KB lines: the root, the AutoDoc
workspace, and "read `<root>/AGENTS.md`". The KB's own `AGENTS.md` is
its contract.

## The first run

A project with no primary keeps the pre-v0.3.0 answer: `[kb].root` in
the TOML, the global KB for a global config, or
`<project-root>/.auto-agents/kb`. auto-core records it as the primary
once, the first time it is asked, if that directory exists.
`require("auto-agents.kb").root()` stays for this minor as a shim over
`auto-core.kb.root()`.

## Retired

- The subverbs `kb init`, `ingest`, `path`, `scope`, `sync`, `new`,
  `open`, `attach`, `tail`, `log` and `obsidian-init`.
- KB types and seeds (`[kb] type`, `[kb] seed`), the per-agent
  `kb_scope`, and `AUTO_AGENTS_KB_READ` / `_WRITE` / `_SCOPE`. Old
  TOML keys load with one warning and are dropped on the next save.
- `log.md` and `index.md`: nothing in auto-agents writes them.
