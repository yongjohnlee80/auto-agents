<!--
Canonical, plugin-shipped copy of the mailbox `diff_queue` protocol.

This file is inlined by `lua/auto-agents/kb/instruct.lua` into every
non-claude agent's per-kind instruction file (AGENTS.md / GEMINI.md /
.junie/guidelines.md / .goosehints) when the agent's bootstrap row has
`diff_review = true`. Claude agents are excluded because they have the
native ws-mcp `openDiff` path via the per-slot bridge (ADR 0011).

Heading levels start at `####` so the content nests cleanly beneath the
`### Interactive diff review` section header emitted by `instruct.lua`.
Source authored by agent:juliet during the 2026-05 diff-view session;
verbatim KB mirror at `$AUTO_AGENTS_KB_ROOT/shared/conventions/diff-queue-workflow.md`.
-->

**Claude-backed agents: skip this section.** You use the native
ws-mcp `openDiff` path via your slot's per-slot MCP bridge (set up by
the host when your bootstrap row has `diff_review = true`). Continue
proposing edits via your normal Edit/Write tools — the host attributes
your diffs through the bridge. The mailbox `diff_queue` lifecycle below
is for non-claude kinds (codex / gemini / junie / aider / goose /
opencode / generic) that have no equivalent native integration.

**For non-claude kinds:** when your roster row in the per-kind
instruction file shows `diff_review = ✓` (the column directly above
this section), the user has opted your slot into in-editor diff
review. That means you must NOT write proposed edits to disk
directly. Instead, every file change goes through the mailbox
`diff_queue` lifecycle below: enqueue a unified diff, wait for the
user's verdict in the diff panel, then apply on `accepted`.

#### "Safety-First" lifecycle

1. **Draft & prep** — Formulate the code change internally. Do NOT
   write it to the target file yet.
2. **Verify disk state** — Check the file on disk matches the "old"
   state you expect. If you modified it during research / testing,
   **REVERT it to its current head state first**.
   *Rationale*: if the disk already matches your proposal, the
   `diff_queue` panel shows "No Changes" and the user rejects.
3. **Enqueue (`diff_queue`)** — Send a `kind="command"` message to
   `nvim` with the `diff_queue` verb. Required args:
    - `diff` — unified diff string
    - `old_file_path` — absolute path of the current file
    - `new_file_path` — absolute path of the target file
    - `tab_name` — descriptive label (e.g. `<your-name>: Feature`)
    - `new_file_contents` — complete final content of the file
4. **Idle / wait** — Stop all execution on that file. Wait for an
   `inbox/` message where `args.verdict == "accepted"`.
5. **Apply** — Only after the `accepted` verdict, write
   `new_file_contents` to disk.
6. **Cleanup** — Archive the verdict message and any related
   response tokens.

#### Common pitfalls

- **Writing to disk before enqueue** — causes the diff panel to
  appear empty; the user sees nothing to review and rejects.
- **Relative paths** — always use absolute paths so the host can
  locate the file for the diff display.
- **Missing `new_file_contents`** — the host uses this to populate
  the "new" side of the comparison; without it the panel can't
  render the proposed state.

#### Example payload

    {
      "kind": "command",
      "to": "nvim",
      "command": "diff_queue",
      "args": {
        "diff": "--- a/file.txt\n+++ b/file.txt\n@@ -1,1 +1,2 @@\n old line\n+new line",
        "old_file_path": "/abs/path/to/file.txt",
        "new_file_path": "/abs/path/to/file.txt",
        "tab_name": "<your-name>: Update file.txt",
        "new_file_contents": "old line\nnew line\n",
        "context": "Adding a new line as requested."
      }
    }