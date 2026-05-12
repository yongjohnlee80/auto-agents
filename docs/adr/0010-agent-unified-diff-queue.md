---
type: adr
number: 0010
status: accepted
date: 2026-05-11
---

# ADR 0010 — Agent Unified Diff Queue & View

## Context
Currently, diff views are tightly coupled to the `claudecode.nvim` plugin, which uses a blocking MCP protocol that immediately interrupts the user's workflow by opening split windows. As we expand `auto-agents.nvim` to support multiple agents (Codex, Junie, Gemini, Claude, etc.), we need a generic, unified diffing mechanism that doesn't forcefully hijack the editor UI. The goal is to queue agent diff requests and present them in a coherent, non-interruptive multi-pane floating UI (leveraging `auto-core.ui.float.multi`), allowing the user to review and resolve them on their own terms.

## Decision
We implemented a unified diff queue and 3-pane float UI (using `auto-core`) to handle agent diff proposals.

### 1. Queueing Mechanism (Blocking Coroutines)
When an agent invokes a "diff" or "edit" tool, the adapter calls `require("auto-agents.diff.queue").enqueue(request)`. The `enqueue` function yields the current coroutine, blocking the agent until the user explicitly resolves the diff.

### 2. Floating Multi-Pane UI
Using `auto-core.ui.float.multi`, the user can toggle a "Diff Queue" view:
* **Left Pane (`agent_name`):** A list of pending diff requests.
* **Middle Pane (`current`):** Read-only buffer showing `old_contents`.
* **Right Pane (`proposed`):** Read-only buffer showing `new_contents`.

### 3. Interactive Resolution (Native Splits)
When the user presses `<CR>` on a queued item in the left pane, the float window closes and a native Neovim `diffthis` split view opens.
* Saving (`:w`) the proposed buffer triggers the callback with `FILE_SAVED` and the finalized text.
* Closing without saving (`:q`) triggers `DIFF_REJECTED`.

## Alternatives Considered
* **Non-Blocking (Fire & Forget) Queueing:** Considered allowing the agent to continue work immediately, but this complicates state management if subsequent edits conflict with a rejected diff.
* **Single-Buffer Unified Diff (Editable):** Considered an editable unified diff (similar to `git diff`), but native splits provide a more robust and familiar editing environment for users.

## Consequences
- **Pros:** Workflow remains uninterrupted; unified handling for all agent types; familiar native editing environment for final resolution.
- **Cons:** Agents are blocked while waiting for user review (intentional to ensure deterministic state).
