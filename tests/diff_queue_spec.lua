-- Headless tests for auto-agents.diff.queue. Run with:
--   nvim --headless -u NONE -l tests/diff_queue_spec.lua

-- Find our own path to derive project roots (Finding 4)
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

-- Standard worktree layout: sibling auto-core.nvim/main
local core_root = plugins_root .. "/auto-core.nvim/main"
if vim.fn.isdirectory(core_root) == 0 then
  -- Fallback to plain repo if no worktree
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

print("\n[1] Queue Enqueue")
local queue = require("auto-agents.diff.queue")
queue.clear()

local result_captured = nil
local id = queue.enqueue({
  agent_name = "test-agent",
  file_path = "/tmp/test.txt",
  old_contents = "old",
  new_contents = "new",
  callback = function(res) result_captured = res end
})

ok("enqueue returns string id", type(id) == "string")
local pending = queue.get_pending()
ok("get_pending returns 1 item", #pending == 1)
ok("item has correct agent_name", pending[1].agent_name == "test-agent")

print("\n[2] Queue Resolve")
queue.resolve(id, "final text")
ok("callback was invoked with result", result_captured ~= nil)
ok("result has FILE_SAVED", result_captured and result_captured.content[1].text == "FILE_SAVED")
ok("result has final text", result_captured and result_captured.content[2].text == "final text")

local pending2 = queue.get_pending()
ok("queue is empty after resolve", #pending2 == 0)

print("\n[3] Queue Reject")
local id2 = queue.enqueue({
  agent_name = "test-agent",
  file_path = "/tmp/test2.txt",
  old_contents = "old",
  new_contents = "new",
  callback = function(res) result_captured = res end
})

result_captured = nil
queue.reject(id2)
ok("callback was invoked with result on reject", result_captured ~= nil)
ok("result has DIFF_REJECTED", result_captured and result_captured.content[1].text == "DIFF_REJECTED")

local pending3 = queue.get_pending()
ok("queue is empty after reject", #pending3 == 0)

print("\n[4] Queue lookup + reject by tab_name (close_tab MCP hook)")
queue.clear()

local cb_result = nil
local tab_name = "✻ [Claude Code] sample.md (deadbeef) ⧉"
local id3 = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/sample.md",
  old_contents = "old",
  new_contents = "new",
  tab_name = tab_name,
  callback = function(res) cb_result = res end,
})

ok("enqueue accepts tab_name", queue.get(id3) ~= nil and queue.get(id3).tab_name == tab_name)

local found = queue.find_by_tab_name(tab_name)
ok("find_by_tab_name returns the pending entry", found ~= nil and found.id == id3)

ok("find_by_tab_name returns nil for unknown tab",
   queue.find_by_tab_name("does-not-exist") == nil)

ok("find_by_tab_name returns nil for nil input",
   queue.find_by_tab_name(nil) == nil)

-- Drive the close_tab handler end-to-end. This is the actual surface
-- the MCP server invokes, so we exercise the same path Claude Code hits
-- when the user resolves the diff in the CLI terminal.
local close_tab_tool = require("auto-agents.mcp.ws-server.tools.close_tab")
local response = close_tab_tool.handler({ tab_name = tab_name })

ok("close_tab returns MCP-compliant TAB_CLOSED",
   type(response) == "table"
   and response.content
   and response.content[1]
   and response.content[1].text == "TAB_CLOSED")

ok("pending callback was resumed with DIFF_REJECTED",
   cb_result ~= nil and cb_result.content and cb_result.content[1].text == "DIFF_REJECTED")

ok("queue is empty after close_tab", #queue.get_pending() == 0)

-- close_tab on a non-diff tab_name must NOT touch the queue. We enqueue
-- a fresh pending entry and call close_tab with a plain buffer name; the
-- queue entry should remain pending and the callback must not fire.
queue.clear()
local untouched_cb = nil
local id4 = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/other.md",
  old_contents = "x",
  new_contents = "y",
  tab_name = "✻ [Claude Code] other.md (cafef00d) ⧉",
  callback = function(res) untouched_cb = res end,
})

-- Plain buffer name without the diff markers
close_tab_tool.handler({ tab_name = "plain-buffer.lua" })

ok("non-diff close_tab leaves queue entry pending",
   queue.get(id4) ~= nil and queue.get(id4).status == "pending")
ok("non-diff close_tab does not invoke callback", untouched_cb == nil)

-- Cleanup so we don't leak a pending entry across the test run.
queue.reject(id4)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
