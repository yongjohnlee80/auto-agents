-- diff_queue's verdict goes back to the agent that queued the diff, as crew mail (auto-agents
-- v0.4.0: no file mailbox).
--
-- Run with:
--   AUTO_CORE_ROOT=<auto-core with auto-core.commands> nvim --headless -u NONE -l tests/diff_verdict_routing_spec.lua
--
-- The verb is dispatched as the editor socket does: the handler registered on auto-core.commands,
-- with the caller as ctx.sender. The crew send (auto-agents.crew.crew_send) and auto-core's daemon
-- runner are stubbed, so each verdict's send is recorded.
--   [1] the queue entry carries the originator (the caller) and the call's correlation id
--   [2] resolve sends one verdict: to the agent by name, as a message, keyed by this Neovim's
--       instance and the entry, its subject naming the verdict, its body the correlation id
--   [3] reject with a reason: rejected, the reason in the body
--   [4] reject without a reason still sends a verdict
--   [5] an entry with no originator (the MCP openDiff path) sends nothing
--   [6] the answer says a verdict follows only when the caller is known
--   [7] a send that fails (no scope held) is logged, never raised

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
-- $AUTO_CORE_ROOT overrides the sibling resolution (see tests/run-all.sh).
local core_root = vim.env.AUTO_CORE_ROOT or (plugins_root .. "/auto-core.nvim/main")
if not vim.env.AUTO_CORE_ROOT and vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end
for _, p in ipairs({ project_root, core_root }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

vim.o.swapfile = false
vim.o.hidden = true

local fail_count, pass_count = 0, 0
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

-- ── stubs: the crew send, the daemon runner, this Neovim's instance ──────────
local sent, answer = {}, true
local crew = require("auto-agents.crew")
local real_crew_send = crew.crew_send
crew.crew_send = function(name, key, msg)
  sent[#sent + 1] = { name = name, key = key, msg = msg }
  return answer
end
package.loaded["auto-core.todo.daemon"] = { run = function(fn, done)
  local res = { pcall(fn) }
  done(res[1], res[2])
end }
package.loaded["auto-core.instance"] = { id = function() return "1779105000-12345" end }
local warned = {}
local log = require("auto-agents.log")
local real_warn = log.warn
log.warn = function(scope, msg) warned[#warned + 1] = scope .. ": " .. msg end

local queue = require("auto-agents.diff.queue")
require("auto-agents.commands").register_all()
local spec = require("auto-core.commands").get("diff_queue")

local function reset_state()
  queue.clear()
  sent, warned, answer = {}, {}, true
end

local function dispatch(args, ctx)
  return spec.handler(args, ctx or {})
end

local function diff_args(name)
  return {
    old_file_path     = "/tmp/" .. name,
    new_file_path     = "/tmp/" .. name,
    new_file_contents = "new contents",
    tab_name          = "✻ [gemini] " .. name .. " ⧉",
  }
end

local function juliet(cor)
  return { sender = "agent:juliet", sender_bare = "agent:juliet", correlation_id = cor, via = "editor" }
end

ok("diff_queue is on auto-core.commands", spec ~= nil and type(spec.handler) == "function")

-- ── [1] the entry carries the originator ─────────────────────────────────────
print("\n[1] the entry carries the caller and the correlation id")
reset_state()
local r1 = dispatch(diff_args("a.md"), juliet("editor:11"))
ok("answer ok", type(r1) == "table" and r1.ok == true, vim.inspect(r1))
ok("the answer says a verdict follows", r1.value and r1.value.verdict_follow_up == true)
eq("the answer echoes the correlation id", r1.value and r1.value.correlation_id, "editor:11")
local pending = queue.get_pending()
ok("one entry enqueued", #pending == 1)
eq("entry.originator is the caller", pending[1] and pending[1].originator, "agent:juliet")
eq("entry.correlation_id kept", pending[1] and pending[1].correlation_id, "editor:11")

-- ── [2] resolve sends the accepted verdict ───────────────────────────────────
print("\n[2] resolve sends one accepted verdict, as crew mail")
reset_state()
dispatch(diff_args("b.md"), juliet("editor:12"))
local id_b = queue.get_pending()[1].id
queue.resolve(id_b, "final body contents")
ok("one send", #sent == 1, "got " .. tostring(#sent))
local s = sent[1] or { msg = {} }
eq("to the agent, by name", s.name, "juliet")
eq("a message", s.msg.kind, "message")
eq("keyed by this Neovim's instance and the entry", s.key, "diff-verdict-1779105000-12345-" .. id_b)
ok("the subject names the verdict and the tab", s.msg.subject == "diff verdict (accepted) for ✻ [gemini] b.md ⧉",
  tostring(s.msg.subject))
ok("the body says accepted and names the correlation id", s.msg.body
  and s.msg.body:find("Diff accepted for", 1, true) == 1 and s.msg.body:find("(correlation editor:12)", 1, true) ~= nil,
  tostring(s.msg.body))

-- ── [3] reject with a reason ─────────────────────────────────────────────────
print("\n[3] reject with a reason sends rejected, the reason in the body")
reset_state()
dispatch(diff_args("c.md"), juliet("editor:13"))
local id_c = queue.get_pending()[1].id
queue.reject(id_c, "rename the function before we ship")
ok("one send", #sent == 1)
local rej = (sent[1] or { msg = {} }).msg
ok("the subject says rejected", rej.subject and rej.subject:find("(rejected)", 1, true) ~= nil, tostring(rej.subject))
ok("the reason is in the body, verbatim", rej.body and rej.body:find(": rename the function before we ship", 1, true) ~= nil,
  tostring(rej.body))

-- ── [4] reject without a reason ──────────────────────────────────────────────
print("\n[4] reject without a reason still sends a verdict")
reset_state()
dispatch(diff_args("d.md"), juliet("editor:14"))
queue.reject(queue.get_pending()[1].id, nil)
ok("one send", #sent == 1)
ok("rejected", sent[1] and sent[1].msg.subject:find("(rejected)", 1, true) ~= nil)

-- ── [5] no originator: nothing sent ──────────────────────────────────────────
print("\n[5] an entry with no originator (MCP openDiff) sends nothing")
reset_state()
local mcp_id = queue.enqueue({
  agent_name = "jarvis", file_path = "/tmp/e.md", old_contents = "", new_contents = "x",
  callback = function(_) end,
})
queue.resolve(mcp_id, "accepted")
ok("no send", #sent == 0, "got " .. tostring(#sent))

-- ── [6] the follow-up flag ───────────────────────────────────────────────────
print("\n[6] the answer says a verdict follows only when the caller is known")
reset_state()
local r6 = dispatch(diff_args("f.md"), { sender_bare = nil })
ok("no caller: no follow-up", r6.value and r6.value.verdict_follow_up == false)
local r6b = dispatch(diff_args("g.md"), { sender = "agent:juliet", sender_bare = "agent:juliet" })
ok("a caller with no correlation id: a follow-up still", r6b.value and r6b.value.verdict_follow_up == true)

-- ── [7] a failed send is logged ──────────────────────────────────────────────
print("\n[7] a send that fails is logged, never raised")
reset_state()
answer = nil -- no crew scope held
dispatch(diff_args("h.md"), juliet("editor:17"))
local ok_resolve = pcall(queue.resolve, queue.get_pending()[1].id, "x")
ok("resolve doesn't raise", ok_resolve)
ok("one warning naming the agent", #warned == 1 and warned[1]:find("juliet", 1, true) ~= nil, vim.inspect(warned))

-- ── cleanup ──────────────────────────────────────────────────────────────────
crew.crew_send = real_crew_send
log.warn = real_warn
queue.clear()

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
