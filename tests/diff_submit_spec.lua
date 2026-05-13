-- Headless tests for external diff submissions. Run with:
--   nvim --headless -u NONE -l tests/diff_submit_spec.lua

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

local pass_count = 0
local fail_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local queue = require("auto-agents.diff.queue")
local submit = require("auto-agents.diff.submit")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

print("\n[1] Async submit writes only after accept")
queue.clear()
local target = root .. "/sample.txt"
local proposal = root .. "/proposal.txt"
write_file(target, "old\n")
write_file(proposal, "new\n")

local id, err = submit.enqueue_file({
  agent_name = "lector",
  file_path = target,
  proposal_path = proposal,
  open_ui = false,
})

ok("enqueue_file returns id", type(id) == "string", err)
ok("target not written before accept", read_file(target) == "old\n")
ok("queue has one pending entry", #queue.get_pending() == 1)

queue.resolve(id, "accepted\n")
ok("accept writes final content", read_file(target) == "accepted\n")
ok("queue drains after accept", #queue.get_pending() == 0)

print("\n[2] Reject leaves target untouched")
queue.clear()
write_file(target, "base\n")
write_file(proposal, "rejected\n")

local reject_id = assert(submit.enqueue_file({
  agent_name = "lector",
  file_path = target,
  proposal_path = proposal,
  open_ui = false,
}))

queue.reject(reject_id, "try again")
ok("reject does not write proposal", read_file(target) == "base\n")
ok("queue drains after reject", #queue.get_pending() == 0)

print("\n[3] submit_file_and_wait returns accepted decision")
queue.clear()
write_file(target, "before wait\n")
write_file(proposal, "during wait\n")

vim.defer_fn(function()
  local pending = queue.get_pending()
  if pending[1] then
    queue.resolve(pending[1].id, "wait accepted\n")
  end
end, 30)

local result = submit.submit_file_and_wait({
  agent_name = "lector",
  file_path = target,
  proposal_path = proposal,
  open_ui = false,
  timeout_ms = 1000,
})

ok("wait result is accepted", result.status == "accepted", vim.inspect(result))
ok("wait result includes queue id", type(result.id) == "string")
ok("wait accept writes content", read_file(target) == "wait accepted\n")

print("\n[4] submit_file_and_wait returns rejected decision")
queue.clear()
write_file(target, "before reject wait\n")
write_file(proposal, "after reject wait\n")

vim.defer_fn(function()
  local pending = queue.get_pending()
  if pending[1] then
    queue.reject(pending[1].id, "not yet")
  end
end, 30)

local rejected = submit.submit_file_and_wait({
  agent_name = "lector",
  file_path = target,
  proposal_path = proposal,
  open_ui = false,
  timeout_ms = 1000,
})

ok("wait result is rejected", rejected.status == "rejected", vim.inspect(rejected))
ok("wait reject preserves target", read_file(target) == "before reject wait\n")
ok("wait reject includes reason", rejected.reason == "not yet")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
