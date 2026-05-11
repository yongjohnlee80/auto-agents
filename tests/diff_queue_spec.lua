-- Headless tests for auto-agents.diff.queue. Run with:
--   nvim --headless -u NONE -l tests/diff_queue_spec.lua

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  "/home/johno/Source/Projects/nvim-plugins/auto-agents.nvim/unified-diff-queue",
  "/home/johno/Source/Projects/nvim-plugins/auto-core.nvim",
  LAZY .. "/plenary.nvim",
}) do
  vim.opt.runtimepath:prepend(p)
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

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
