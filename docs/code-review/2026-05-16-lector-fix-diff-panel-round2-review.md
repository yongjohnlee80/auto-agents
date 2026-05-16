---
type: code-review
reviewer: lector
created: 2026-05-16
subject: "ADR 0011 fix-diff-panel round-2 review"
repos:
  - auto-agents.nvim/fix-diff-panel
  - auto-core.nvim/fix-diff-panel
outcome: change_requested
---

# Review: ADR 0011 fix-diff-panel round 2

Outcome: **change requested**.

The mailbox/ctx.sender shape and cascade-drain guard are directionally good, but the websocket peer attribution path still does not work as implemented. I also could not reproduce the claimed all-green test state: one new auto-agents label spec fails locally, and auto-core smoke fails two git.repo assertions.

## High

### 1. Peer attribution compares the server socket inode against the agent PID

- File: `lua/auto-agents/mcp/ws-server/peer_identity.lua:70`
- Related call site: `lua/auto-agents/mcp/ws-server/tools/open_diff.lua:91`

`find_inode_for_peer(listen_port, remote_port)` matches `/proc/net/tcp` rows where `local_address` has the server's listening port and `rem_address` has the client's ephemeral port. That returns the **server-side** accepted socket inode, which is owned by Neovim's websocket server process.

`resolve()` then checks that inode under each agent process via `/proc/<pid>/fd/*`. The agent process owns the **client-side** socket inode, whose `/proc/net/tcp` row has the opposite direction: `local_address = client ephemeral port`, `rem_address = server listen port`.

So the live PID match will miss even when `/proc` parsing is otherwise correct, and `openDiff` falls back to the ambiguous resolver / unattributed label for the exact multi-agent case ADR 0011 is meant to fix.

Fix direction: when mapping to agent PIDs, resolve the client-side inode by matching `local_port == peer_port` and `remote_port == listen_port`, or return both endpoint inodes and compare agent PIDs against the client endpoint. Add a unit/integration probe with a real local TCP pair so the test proves the inode direction, not just the port formatting and nil paths.

## Medium

### 2. The new label regression spec is not green locally

- File: `tests/diff_panel_labels_spec.lua:117`
- Implementation: `lua/auto-agents/diff/ui.lua:219`

Running `nvim --headless -u NONE -l tests/diff_panel_labels_spec.lua` fails:

```text
FAIL  file in non-git tmpdir labels as parent basename  got="tmp" want="nongit"
Passed: 17, Failed: 1
```

That contradicts the review request's all-green test summary. Either the fixture expectation is wrong, or `repo_for()` should not let the project-root fallback climb above the immediate non-git directory for this case.

Fix direction: decide the intended non-git label contract and make code and test agree. If the ADR's `/tmp/foo.lua -> tmp` fallback is the intended behavior, update this fixture. If `nongit/foo.lua -> nongit` is the intended behavior, avoid the higher-level `project_root()` fallback before the final `:h:t` fallback.

### 3. auto-core smoke is not green in this environment

- Repo: `/home/johno/Source/Projects/nvim-plugins/auto-core.nvim/fix-diff-panel`
- Command: `nvim --headless -u NONE -l tests/smoke.lua`

The full auto-core smoke run fails two assertions:

```text
[25] git.repo — is_git / root / git_dir / common_dir / is_bare
FAIL  git.repo.is_git false on a fresh empty dir
FAIL  git.repo.root nil on a fresh empty dir
...
613 passed, 2 failed
```

These failures may be pre-existing or environment-sensitive, but the branch should not be reported as fully green until the cause is understood or the failure is explicitly scoped as unrelated with reproduction notes.

## Low

### 4. Version coupling can stay as a release-note/config concern for this patch

- auto-agents consumer: `lua/auto-agents/mailbox/commands.lua:195`
- auto-core producer: `/home/johno/Source/Projects/nvim-plugins/auto-core.nvim/fix-diff-panel/lua/auto-core/mailbox/router.lua:334`

I would not add a hard minimum `api_version` gate for `ctx.sender_bare` in this patch. The auto-agents handler degrades without crashing when the new field is absent, and the old behavior is a label-quality issue rather than a correctness/safety break. A release note saying "mailbox sender attribution requires auto-core v0.1.11+" is enough unless a future command depends on sender identity for authorization.

### 5. The `agent_for` sentinel list is sufficient for the known placeholders

- File: `lua/auto-agents/diff/ui.lua:235`

The list covers the placeholders identified in ADR 0011: nil, empty string, `agent`, `?`, `unknown`, and already-normalized `unattributed`. I do not see another upstream sentinel that needs to be added before merge.

## Verification

Commands I ran:

```text
nvim --headless -u NONE -l tests/diff_peer_identity_spec.lua
  16 passed, 0 failed

nvim --headless -u NONE -l tests/diff_cascade_drain_spec.lua
  15 passed, 0 failed

nvim --headless -u NONE -l tests/diff_mailbox_sender_spec.lua
  10 passed, 0 failed

nvim --headless -u NONE -l tests/diff_queue_spec.lua
  23 passed, 0 failed

nvim --headless -u NONE -l tests/diff_ui_spec.lua
  81 passed, 0 failed

nvim --headless -u NONE -l tests/diff_panel_labels_spec.lua
  17 passed, 1 failed

nvim --headless -u NONE -l tests/smoke.lua
  auto-core: 613 passed, 2 failed
```

