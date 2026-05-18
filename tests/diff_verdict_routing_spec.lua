-- Regression test for v0.2.19: diff_queue verdict routing back to
-- the mailbox originator.
--
-- Run with:
--   nvim --headless -u NONE -l tests/diff_verdict_routing_spec.lua
--
-- Covers the response-path half of the diff-feedback-routing-to-
-- gemini-juliet todo. Pre-patch the mailbox `diff_queue` command was
-- fire-and-forget — the originating agent received an enqueue ack
-- but never learned whether the user accepted or rejected.
--
-- Post-patch:
--   1. `handle_diff_queue` reads `ctx.sender` + `ctx.correlation_id`
--      and stashes both on the queue entry.
--   2. `queue.resolve(id, ...)` / `queue.reject(id, ...)` call
--      `emit_verdict` which `transport.send`s a kind="message"
--      envelope back to the originator with the same correlation_id.
--
-- The spec asserts:
--   [1] The queue entry carries originator + correlation_id when
--       dispatched with both ctx fields.
--   [2] Resolve emits a transport.send with verdict="accepted" and
--       the original correlation_id.
--   [3] Reject (with reason) emits verdict="rejected" + comment.
--   [4] Reject without reason still emits a verdict.
--   [5] Entries without originator_mailbox_id (e.g. MCP openDiff
--       path) do NOT trigger transport.send — fire-and-forget
--       semantics preserved for that path.
--   [6] The handler's response advertises `verdict_follow_up = true`
--       + `correlation_id` when capture succeeded.

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

local mailbox = require("auto-core").mailbox
local queue   = require("auto-agents.diff.queue")
require("auto-agents.mailbox.commands").register_all()

-- ── transport.send capture ──────────────────────────────────────
-- Monkey-patch transport.send so the spec can assert outbound
-- mailbox traffic without spinning up the file-watching router.
-- Restored at end-of-spec.
local transport = require("auto-core.mailbox.transport")
local original_send = transport.send
local sent = {}
transport.send = function(opts)
  sent[#sent + 1] = opts
  return { id = "fake-send-id", path = "/tmp/fake", message = opts, correlation_id = opts.correlation_id }, nil
end

local function reset_state()
  queue.clear()
  sent = {}
end

local function dispatch(args, ctx)
  return mailbox.commands.handle_message({
    id             = "diff-cmd-" .. tostring(vim.uv.hrtime()),
    kind           = "command",
    from           = (ctx and ctx.sender) or "agent:juliet",
    to             = "nvim",
    command        = "diff_queue",
    args           = args,
    correlation_id = ctx and ctx.correlation_id or nil,
  }, ctx)
end

local function diff_args(name)
  return {
    old_file_path     = "/tmp/" .. name,
    new_file_path     = "/tmp/" .. name,
    new_file_contents = "new contents",
    tab_name          = "✻ [gemini] " .. name .. " ⧉",
  }
end

-- ── [1] Queue entry carries originator + correlation_id ────────
print("\n[1] handle_diff_queue stashes ctx.sender + ctx.correlation_id")
reset_state()
local r1 = dispatch(diff_args("a.md"), {
  mailbox        = "nvim",
  sender         = "agent:juliet:1779105000-12345",
  sender_bare    = "agent:juliet",
  correlation_id = "cor-juliet-A",
})
ok("response ok", type(r1) == "table" and r1.ok == true)
ok("response advertises verdict_follow_up",
   r1.value and r1.value.verdict_follow_up == true,
   "value.verdict_follow_up=" .. tostring(r1.value and r1.value.verdict_follow_up))
eq("response echoes correlation_id",
   r1.value and r1.value.correlation_id, "cor-juliet-A")

local pending = queue.get_pending()
ok("one entry enqueued", #pending == 1)
eq("entry.originator_mailbox_id captured",
   pending[1] and pending[1].originator_mailbox_id,
   "agent:juliet:1779105000-12345")
eq("entry.correlation_id captured",
   pending[1] and pending[1].correlation_id, "cor-juliet-A")

-- ── [2] Resolve emits accepted verdict ─────────────────────────
print("\n[2] queue.resolve emits transport.send(verdict=accepted)")
reset_state()
dispatch(diff_args("b.md"), {
  mailbox        = "nvim",
  sender         = "agent:juliet:1779105000-12345",
  sender_bare    = "agent:juliet",
  correlation_id = "cor-juliet-B",
})
local id_b = queue.get_pending()[1].id
queue.resolve(id_b, "final body contents")
ok("transport.send was called exactly once", #sent == 1,
   "got " .. tostring(#sent) .. " sends")
local sent_msg = sent[1] or {}
eq("from = nvim", sent_msg.from, "nvim")
eq("to = originator full id", sent_msg.to, "agent:juliet:1779105000-12345")
eq("kind = message", sent_msg.kind, "message")
eq("correlation_id replayed", sent_msg.correlation_id, "cor-juliet-B")
eq("args.verdict = accepted",
   sent_msg.args and sent_msg.args.verdict, "accepted")
eq("args.comment empty on accept",
   sent_msg.args and sent_msg.args.comment, "")
eq("args.file_path forwarded",
   sent_msg.args and sent_msg.args.file_path, "/tmp/b.md")
eq("args.tab_name forwarded",
   sent_msg.args and sent_msg.args.tab_name, "✻ [gemini] b.md ⧉")
ok("subject mentions verdict",
   sent_msg.subject and sent_msg.subject:find("accepted", 1, true) ~= nil,
   "subject=" .. tostring(sent_msg.subject))

-- ── [3] Reject (with reason) emits rejected verdict + comment ──
print("\n[3] queue.reject(id, reason) emits transport.send(verdict=rejected)")
reset_state()
dispatch(diff_args("c.md"), {
  mailbox        = "nvim",
  sender         = "agent:juliet:1779105000-12345",
  sender_bare    = "agent:juliet",
  correlation_id = "cor-juliet-C",
})
local id_c = queue.get_pending()[1].id
queue.reject(id_c, "rename the function before we ship")
ok("transport.send was called", #sent == 1)
local rej = sent[1] or {}
eq("args.verdict = rejected", rej.args and rej.args.verdict, "rejected")
eq("args.comment carries the reason verbatim",
   rej.args and rej.args.comment, "rename the function before we ship")
eq("correlation_id replayed", rej.correlation_id, "cor-juliet-C")

-- ── [4] Reject without reason still emits a verdict ─────────────
print("\n[4] queue.reject(id) (no reason) still emits a verdict")
reset_state()
dispatch(diff_args("d.md"), {
  mailbox        = "nvim",
  sender         = "agent:juliet:1779105000-12345",
  sender_bare    = "agent:juliet",
  correlation_id = "cor-juliet-D",
})
local id_d = queue.get_pending()[1].id
queue.reject(id_d, nil)
ok("transport.send was called for reasonless reject", #sent == 1)
eq("verdict still rejected", sent[1] and sent[1].args and sent[1].args.verdict, "rejected")

-- ── [5] No originator → no verdict emission (MCP path) ──────────
print("\n[5] entries without originator_mailbox_id stay fire-and-forget")
reset_state()
-- Direct enqueue without going through handle_diff_queue — emulates
-- the MCP openDiff path where the coroutine callback is the reply
-- channel.
local mcp_id = queue.enqueue({
  agent_name   = "jarvis",
  file_path    = "/tmp/e.md",
  old_contents = "",
  new_contents = "x",
  callback     = function(_) end,
  -- originator_mailbox_id + correlation_id intentionally omitted.
})
queue.resolve(mcp_id, "accepted")
ok("transport.send NOT called for MCP-style entry", #sent == 0,
   "got " .. tostring(#sent) .. " sends")

-- ── [6] Missing ctx.correlation_id → no follow-up flag ─────────
print("\n[6] handler's response signals no follow-up when ctx lacks correlation_id")
reset_state()
local r6 = dispatch(diff_args("f.md"), {
  mailbox     = "nvim",
  sender      = "agent:juliet:1779105000-12345",
  sender_bare = "agent:juliet",
  -- correlation_id intentionally omitted (legacy auto-core <v0.1.23).
})
ok("response ok", type(r6) == "table" and r6.ok == true)
ok("verdict_follow_up is false (no correlation)",
   r6.value and r6.value.verdict_follow_up == false,
   "value.verdict_follow_up=" .. tostring(r6.value and r6.value.verdict_follow_up))

-- ── Cleanup ────────────────────────────────────────────────────
transport.send = original_send
queue.clear()

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
