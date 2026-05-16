-- Regression test for the diff-queue cascade-drain bug.
-- Run with:
--   nvim --headless -u NONE -l tests/diff_cascade_drain_spec.lua
--
-- User-reported symptom: with N pending entries in the panel, one `A`
-- press at position 1 cleared ALL entries instead of just the one. The
-- root cause is Claude Code's CLI sending `close_tab` for every sibling
-- diff tab in its session immediately after receiving FILE_SAVED for
-- the resolved entry. close_tab's pre-fix behavior was to reject any
-- matched pending queue entry — so the response to one user `A` was
-- a cascade of agent-driven rejections.
--
-- Fix: when the diff panel is OPEN, close_tab is a no-op for pending
-- queue entries (returns TAB_CLOSED without mutating the queue). The
-- panel owns the resolution lifecycle while it's up. When the panel
-- is closed, close_tab works as before — agents can still dismiss
-- orphaned diffs the user resolved via the CLI terminal.

-- Resolve project roots — same idiom as the other specs.
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
local core_root = plugins_root .. "/auto-core.nvim/main"
if vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  project_root,
  core_root,
  LAZY .. "/plenary.nvim",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

local fail_count = 0
local pass_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

local queue          = require("auto-agents.diff.queue")
local ui             = require("auto-agents.diff.ui")
local close_tab_tool = require("auto-agents.mcp.ws-server.tools.close_tab")

local DIFF_TAB_FMT = "✻ [Claude Code] %s (deadbeef) ⧉"

-- Helper: enqueue a diff with a tab_name shaped like the real Claude Code one.
local function enqueue_diff(name, capture)
  return queue.enqueue({
    agent_name   = "jarvis",
    file_path    = "/tmp/" .. name,
    old_contents = "old",
    new_contents = "new",
    tab_name     = DIFF_TAB_FMT:format(name),
    callback     = function(res) capture.last = res end,
  })
end

-- ── [1] Pre-condition: ui.is_open is wired and false at boot ──────
print("\n[1] ui.is_open contract")
ok("ui.is_open is a function", type(ui.is_open) == "function")
ok("ui.is_open returns false when panel is closed", ui.is_open() == false)

-- ── [2] Cascade-drain regression: panel-open path is now safe ────
print("\n[2] close_tab is no-op for pending entries while panel is open")
queue.clear()

local cb_a, cb_b, cb_c = {}, {}, {}
local id_a = enqueue_diff("a.md", cb_a)
local id_b = enqueue_diff("b.md", cb_b)
local id_c = enqueue_diff("c.md", cb_c)
ok("three entries pending before open", #queue.get_pending() == 3)

ui.open()
vim.wait(50)
ok("panel is open after ui.open()", ui.is_open())

-- Simulate Claude Code's post-resolve cascade: sibling close_tab calls
-- for the two diffs the user has NOT accepted in the panel yet.
local resp_b = close_tab_tool.handler({ tab_name = DIFF_TAB_FMT:format("b.md") })
local resp_c = close_tab_tool.handler({ tab_name = DIFF_TAB_FMT:format("c.md") })

ok("close_tab returned TAB_CLOSED for b.md",
   type(resp_b) == "table" and resp_b.content and resp_b.content[1].text == "TAB_CLOSED")
ok("close_tab returned TAB_CLOSED for c.md",
   type(resp_c) == "table" and resp_c.content and resp_c.content[1].text == "TAB_CLOSED")

ok("entry b is STILL pending (cascade blocked)",
   queue.get(id_b) ~= nil and queue.get(id_b).status == "pending")
ok("entry c is STILL pending (cascade blocked)",
   queue.get(id_c) ~= nil and queue.get(id_c).status == "pending")
ok("entries b/c callbacks were NOT invoked",
   cb_b.last == nil and cb_c.last == nil)
ok("all three entries remain in the queue", #queue.get_pending() == 3)

-- ── [3] Panel-closed path: close_tab still drains (legacy behavior) ──
print("\n[3] close_tab still rejects when panel is closed (CLI-dismiss path)")

-- Resolve entry a via the panel to drain it cleanly, then close the panel.
queue.resolve(id_a, "new contents")
ok("entry a resolved", queue.get(id_a) == nil)

-- Close the panel programmatically — emulates the user pressing q.
local mf = ui._test_get_mfloat()
if mf then mf:close() end
vim.wait(50)
ok("panel is closed after :close()", not ui.is_open())

-- Now a legitimate CLI-side dismiss should still reject pending entries.
local resp_b2 = close_tab_tool.handler({ tab_name = DIFF_TAB_FMT:format("b.md") })
ok("close_tab returned TAB_CLOSED for b.md (panel closed)",
   type(resp_b2) == "table" and resp_b2.content and resp_b2.content[1].text == "TAB_CLOSED")
ok("entry b is now rejected (legitimate CLI dismiss)",
   queue.get(id_b) == nil)
ok("entry b callback fired with DIFF_REJECTED",
   cb_b.last ~= nil and cb_b.last.content and cb_b.last.content[1].text == "DIFF_REJECTED")

-- ── Cleanup ───────────────────────────────────────────────────────
queue.clear()

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)