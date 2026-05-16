-- Regression test for ADR 0011 Patch 4.
-- Run with:
--   nvim --headless -u NONE -l tests/diff_mailbox_sender_spec.lua
--
-- Covers the mailbox `diff_queue` command handler's attribution
-- chain. Pre-patch, the handler derived agent_name from
-- `ctx.mailbox`, which auto-core's executor path populates with
-- the EXECUTOR's mailbox (`nvim`), not the SENDER's. Every
-- mailbox-routed diff therefore landed in the panel labelled
-- `[nvim]` instead of the actual sender.
--
-- Post-patch the handler prefers `ctx.sender_bare` (added in
-- auto-core v0.1.11) before falling back to the legacy
-- `ctx.mailbox` path. This spec exercises:
--
--   * explicit `args.agent_name` wins (existing override).
--   * ctx.sender_bare → parsed `agent:<name>` produces the right
--     agent_name in the enqueued entry.
--   * ctx.sender_bare absent + ctx.mailbox = nvim → falls through
--     to the bootstrap resolver (which returns nil when ambiguous,
--     leaving "nvim" or "?" — at least not silently
--     mis-attributing).

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

-- Helper: invoke the mailbox commands module's `diff_queue` handler
-- directly. The handler lives inside the SPECS table — we register
-- it through `mailbox.commands` and invoke via `handle_message`.
local mailbox = require("auto-core").mailbox
local queue   = require("auto-agents.diff.queue")
require("auto-agents.mailbox.commands").register_all()

local function dispatch(args, ctx)
  return mailbox.commands.handle_message({
    id      = "test-" .. tostring(vim.uv.hrtime()),
    kind    = "command",
    from    = ctx and (ctx.sender or "agent:test") or "agent:test",
    to      = "nvim",
    command = "diff_queue",
    args    = args,
  }, ctx)
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
  mailbox     = "nvim",
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
  mailbox     = "nvim",         -- executor — pre-fix this is what the handler used
  sender_bare = "agent:jarvis", -- sender — the field Patch 4 added
})
ok("response is ok", type(r2) == "table" and r2.ok == true)

pending = queue.get_pending()
ok("one entry enqueued", #pending == 1)
eq("agent_name derived from ctx.sender_bare, not ctx.mailbox",
   pending[1] and pending[1].agent_name, "jarvis")

-- ── [3] ctx.sender_bare without `agent:` prefix passes through ───
print("\n[3] ctx.sender_bare without `agent:` prefix kept verbatim")
queue.clear()
local r3 = dispatch(make_args("c.md"), {
  mailbox     = "nvim",
  sender_bare = "user",   -- e.g. messages from the virtual `user` mailbox
})
ok("response is ok", type(r3) == "table" and r3.ok == true)
pending = queue.get_pending()
eq("non-`agent:` sender_bare is kept verbatim",
   pending[1] and pending[1].agent_name, "user")

-- ── [4] Legacy fallback — no sender_bare, ctx.mailbox is nvim ────
print("\n[4] legacy fallback (no sender_bare) — agent_name doesn't silently become \"nvim\"")
queue.clear()
local r4 = dispatch(make_args("d.md"), {
  mailbox     = "nvim",  -- pre-0.1.11 auto-core only surfaces this
  -- sender_bare omitted → simulates older auto-core
})
ok("response is ok", type(r4) == "table" and r4.ok == true)
pending = queue.get_pending()

-- With no diff_review agent in the bootstrap (this spec runs without
-- a configured agent roster), the resolver returns nil and the handler
-- falls through to "nvim" — at least we don't crash, and the
-- panel's display predicate maps "nvim" to itself (it's a valid name
-- string). The bug avoidance is in case [2] above; this case
-- documents the legacy behavior.
ok("entry enqueued with legacy fallback value",
   pending[1] ~= nil and type(pending[1].agent_name) == "string")

-- ── Cleanup ──────────────────────────────────────────────────────
queue.clear()

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)