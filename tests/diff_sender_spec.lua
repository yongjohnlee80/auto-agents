-- Regression test for ADR 0011 Patch 4: who a queued diff is from.
-- Run with:
--   AUTO_CORE_ROOT=<auto-core with auto-core.commands> nvim --headless -u NONE -l tests/diff_sender_spec.lua
--
-- The `diff_queue` verb's handler (on auto-core.commands, as the editor socket calls it) names the
-- diff's agent from, in order: an explicit `args.agent_name`, then `ctx.sender_bare` (the editor
-- socket's caller), then the bootstrap resolver, then "?". It used to read `ctx.mailbox`, the
-- executor (`nvim`), so every mailbox-routed diff was labelled `[nvim]`:
--
--   * explicit `args.agent_name` wins.
--   * ctx.sender_bare → parsed `agent:<name>` is the agent_name.
--   * a ctx.sender_bare without `agent:` is kept verbatim.
--   * no caller → never "nvim": the resolver's answer, or "?".

-- Resolve project roots — same idiom as the other specs.
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
-- $AUTO_CORE_ROOT overrides the sibling resolution (see tests/run-all.sh).
local core_root = vim.env.AUTO_CORE_ROOT or (plugins_root .. "/auto-core.nvim/main")
if not vim.env.AUTO_CORE_ROOT and vim.fn.isdirectory(core_root) == 0 then
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

local function eq(name, got, want)
  ok(name, got == want, string.format("got=%q want=%q", tostring(got), tostring(want)))
end

-- Helper: invoke the `diff_queue` verb's handler, registered on auto-core.commands, as the editor
-- socket does.
local queue   = require("auto-agents.diff.queue")
require("auto-agents.commands").register_all()
local spec = require("auto-core.commands").get("diff_queue")

local function dispatch(args, ctx)
  return spec.handler(args, ctx or {})
end

local function make_args(name)
  return {
    old_file_path     = "/tmp/" .. name,
    new_file_path     = "/tmp/" .. name,
    new_file_contents = "new",
    tab_name          = "✻ [Claude Code] " .. name .. " (deadbeef) ⧉",
  }
end

-- ── [1] Explicit args.agent_name wins ────────────────────────────
print("\n[1] args.agent_name (explicit) wins over ctx fields")
queue.clear()
local args1 = make_args("a.md")
args1.agent_name = "explicit-override"
local r1 = dispatch(args1, {
  sender_bare = "agent:jarvis",
})
ok("response is ok",  type(r1) == "table" and r1.ok == true)

local pending = queue.get_pending()
ok("one entry enqueued", #pending == 1)
eq("explicit args.agent_name kept verbatim",
   pending[1] and pending[1].agent_name, "explicit-override")

-- ── [2] ctx.sender_bare is parsed (the headline fix) ─────────────
print("\n[2] ctx.sender_bare → agent_name (the Patch 4 headline fix)")
queue.clear()
local r2 = dispatch(make_args("b.md"), {
  sender_bare = "agent:jarvis", -- the caller
})
ok("response is ok", type(r2) == "table" and r2.ok == true)

pending = queue.get_pending()
ok("one entry enqueued", #pending == 1)
eq("agent_name derived from ctx.sender_bare",
   pending[1] and pending[1].agent_name, "jarvis")

-- ── [3] ctx.sender_bare without `agent:` prefix passes through ───
print("\n[3] ctx.sender_bare without `agent:` prefix kept verbatim")
queue.clear()
local r3 = dispatch(make_args("c.md"), {
  sender_bare = "user",
})
ok("response is ok", type(r3) == "table" and r3.ok == true)
pending = queue.get_pending()
eq("non-`agent:` sender_bare is kept verbatim",
   pending[1] and pending[1].agent_name, "user")

-- ── [4] No caller: never "nvim" ──────────────────────────────────
print("\n[4] no caller: the resolver's answer or \"?\", never \"nvim\"")
queue.clear()
local r4 = dispatch(make_args("d.md"), {})
ok("response is ok", type(r4) == "table" and r4.ok == true)
pending = queue.get_pending()
-- With no diff_review agent in the bootstrap (this spec runs without a configured roster), the
-- resolver finds no one and the handler answers "?", which the panel shows as [unattributed].
ok("entry enqueued, attributed to no one rather than the executor",
   pending[1] ~= nil and type(pending[1].agent_name) == "string" and pending[1].agent_name ~= "nvim",
   pending[1] and pending[1].agent_name)

-- ── Cleanup ──────────────────────────────────────────────────────
queue.clear()

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)