---auto-agents.mcp.ws-server.diff — RETIRED legacy native-diff surface.
---
---ADR-0039 Batch B (v0.2.54): this module previously carried the
---1,538-line pre-queue in-tab diff UI inherited from claudecode.nvim's
---application layer (native split/tab orchestration, temp-file
---machinery, autocmd lifecycle, blocking-coroutine state). That path
---has been unreachable since the unified diff queue landed: `openDiff`
---always enqueues via `tools/open_diff.lua` → `auto-agents.diff.queue`
---and renders through `auto-agents.diff.ui`. The dead code also
---harbored a guaranteed nil-dereference stub (the vendoring-time
---`pcall(function() return nil end)` terminal-module placeholder) and
---every remaining deprecated `nvim_buf_set_option` call in owned code.
---
---What survives is the single production contract still wired up:
---`tools/close_tab.lua` consults `close_diff_by_tab_name` as a legacy
---fallback AFTER the queue lookup misses. With the native path retired
---there are never active legacy diffs, so the answer is always `false`
---— close_tab then takes its "Diff not found" branch and returns
---TAB_CLOSED, exactly as it did when this module tracked state. Do not
---grow this surface; new diff behavior belongs in `diff/queue.lua` /
---`diff/ui.lua`.
---
---This file is OWNED application code (not part of the vendored WS
---protocol set — see NOTICE / the vendoring playbook).
---
---@module 'auto-agents.mcp.ws-server.diff'

local M = {}

---Legacy fallback consulted by the `close_tab` MCP tool when a
---tab_name matches no unified-queue entry. The native diff registry
---was retired in ADR-0039 Batch B; there is nothing to close.
---@param tab_name string?
---@return boolean closed Always false — no legacy diffs can exist.
function M.close_diff_by_tab_name(tab_name)
  local ok_log, log = pcall(require, "auto-agents.log")
  if ok_log then
    log.debug("mcp.diff",
      "legacy close_diff_by_tab_name('" .. tostring(tab_name)
      .. "') — native diff path retired (ADR-0039 B); no-op")
  end
  return false
end

return M
