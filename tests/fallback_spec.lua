-- Headless tests for auto-agents.fallback: a delivery the crew couldn't get received, typed into its
-- agent's terminal at most once per key (auto-agents v0.4.0). Run:
--   nvim --headless -u NONE -l tests/fallback_spec.lua
--
-- A fake auto-agents holds the slots and records what each terminal is sent.
--   [1] typed once: one send, the whole text as one line, a bare Enter (never Esc), submitted
--   [2] the same key again types nothing and answers true, also after a restart (keys reloaded
--       from the state file)
--   [3] an agent mid-turn: the text still goes as one send, whole, however long or multi-line
--   [4] no slot runs the name: false, why, and nothing kept, so a later ask (its slot spawned) types it
--   [5] a terminal that refuses: false, why, and the key taken back
--   [6] one line, controls stripped; a line starting with [, / or $ is prefixed; capped
--   [7] the notifier's handler: subject and body typed; another instance's agent refused; no key
--       refused
--   [8] the state file keeps the newest keys, oldest dropped first
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:prepend(project_root)
package.path = project_root .. "/lua/?.lua;" .. project_root .. "/lua/?/init.lua;" .. package.path
vim.o.swapfile = false

local sb = vim.fn.tempname() .. "-fallback"
vim.env.XDG_STATE_HOME = sb .. "/state"

local pass, fail = 0, 0
local function ok(name, cond, detail)
  if cond then
    pass = pass + 1
    io.stdout:write("  PASS  " .. name .. "\n")
  else
    fail = fail + 1
    io.stdout:write("  FAIL  " .. name .. (detail and ("\n        " .. tostring(detail)) or "") .. "\n")
  end
end

-- ── fakes ───────────────────────────────────────────────────────────────────

local slots = { ["gold-man"] = 2, lector = 3 }
local sends = {}     -- { slot, text, opts }
local refuse = {}    -- slot -> true: its terminal refuses
package.loaded["auto-agents"] = {
  slot_for_name = function(name) return slots[name] end,
  send_slot = function(slot, text, opts)
    if refuse[slot] then return false end
    sends[#sends + 1] = { slot = slot, text = text, opts = opts }
    return true
  end,
}
package.loaded["auto-core.instance"] = { id = function() return "1111-2222" end }

local fb = require("auto-agents.fallback")
local function restart() fb._reset_for_tests() end

-- ── [1] typed once ──────────────────────────────────────────────────────────

do
  local ok1, why = fb.type_once("gold-man", "job-1", "Mail from jarvis. Answer with autodoc mail send jarvis.")
  ok("[1] answers true", ok1 == true and why == nil, tostring(why))
  ok("[1] one send, to the agent's slot", #sends == 1 and sends[1].slot == 2, vim.inspect(sends))
  ok("[1] the whole text, as one line", sends[1] and sends[1].text == "Mail from jarvis. Answer with autodoc mail send jarvis.")
  ok("[1] submitted with a bare Enter, never Esc", sends[1] and sends[1].opts.submit == true
    and vim.deep_equal(sends[1].opts.submit_keys, { "<CR>" }), vim.inspect(sends[1] and sends[1].opts))
  ok("[1] the key is in the state file", vim.fn.filereadable(fb.state_file()) == 1
    and vim.tbl_contains(vim.fn.readfile(fb.state_file()), "job-1"))
end

-- ── [2] never twice, across a restart ───────────────────────────────────────

do
  local n = #sends
  local again = fb.type_once("gold-man", "job-1", "Mail from jarvis.")
  ok("[2] the same key again: true, nothing typed", again == true and #sends == n)
  restart()
  local after = fb.type_once("gold-man", "job-1", "Mail from jarvis.")
  ok("[2] after a restart: true, nothing typed", after == true and #sends == n, vim.inspect(sends))
  fb.type_once("gold-man", "job-2", "another")
  ok("[2] a new key after the restart is typed", #sends == n + 1 and sends[#sends].text == "another")
end

-- ── [3] an agent mid-turn: one send, whole ──────────────────────────────────

do
  local n = #sends
  local long = {}
  for i = 1, 60 do long[#long + 1] = ("line %d of a long message."):format(i) end
  local text = table.concat(long, "\n")
  fb.type_once("lector", "job-mid", text)
  local got = sends[#sends]
  ok("[3] one send for the whole message", #sends == n + 1, #sends - n)
  ok("[3] every line in it, in order, on one line", got and got.text:find("line 1 of", 1, true) == 1
    and got.text:find("line 60 of a long message.", 1, true) ~= nil and not got.text:find("\n", 1, true), got and got.text)
  ok("[3] no Esc in the submit keys (an Esc would cancel the turn)", got
    and not vim.tbl_contains(got.opts.submit_keys or {}, "<Esc>"))
end

-- ── [4] no slot yet ─────────────────────────────────────────────────────────

do
  local n = #sends
  local r, why = fb.type_once("zen", "job-zen", "for zen")
  ok("[4] no slot: false, saying why", r == false and type(why) == "string" and why:find("zen", 1, true), tostring(why))
  ok("[4] nothing typed, nothing kept", #sends == n and not vim.tbl_contains(vim.fn.readfile(fb.state_file()), "job-zen"))
  slots.zen = 4
  local later = fb.type_once("zen", "job-zen", "for zen")
  ok("[4] once its slot runs, the same key is typed", later == true and #sends == n + 1 and sends[#sends].slot == 4)
end

-- ── [5] a terminal that refuses ─────────────────────────────────────────────

do
  refuse[2] = true
  local r, why = fb.type_once("gold-man", "job-refused", "x")
  ok("[5] refused: false, saying why", r == false and type(why) == "string", tostring(why))
  ok("[5] the key is taken back", not vim.tbl_contains(vim.fn.readfile(fb.state_file()), "job-refused"))
  restart()
  ok("[5] and isn't seen after a restart either", not vim.tbl_contains(vim.fn.readfile(fb.state_file()), "job-refused"))
  refuse[2] = nil
  local n = #sends
  ok("[5] once the terminal takes it, it is typed", fb.type_once("gold-man", "job-refused", "x") == true and #sends == n + 1)
end

-- ── [6] the line ────────────────────────────────────────────────────────────

do
  ok("[6] controls and line breaks become spaces", fb.line("a\27[31mb\r\nc\0d") == "a b c d", fb.line("a\27[31mb\r\nc\0d"))
  ok("[6] a leading [ is prefixed", fb.line("[urgent] fix it") == fb.PREFIX .. "[urgent] fix it")
  ok("[6] a leading / is prefixed", fb.line("/compact now") == fb.PREFIX .. "/compact now")
  ok("[6] a leading $VAR is prefixed", fb.line("$HOME is set") == fb.PREFIX .. "$HOME is set")
  ok("[6] a hazard after a control is still seen", fb.line("\27[0m/bin/sh") == fb.PREFIX .. "/bin/sh", fb.line("\27[0m/bin/sh"))
  ok("[6] plain text is left alone", fb.line("Mail from user.") == "Mail from user.")
  local capped = fb.line(string.rep("x", fb.MAX_TEXT + 50))
  ok("[6] capped at MAX_TEXT characters", vim.fn.strchars(capped) == fb.MAX_TEXT, vim.fn.strchars(capped))
  ok("[6] nothing printable is nothing to type", fb.line("\27[0m\r\n") == nil
    and fb.type_once("gold-man", "job-empty", "\r\n") == false)
end

-- ── [7] the notifier's handler ──────────────────────────────────────────────

do
  local n = #sends
  local r = fb.notifier_handler({ recipient = "agent:lector", key = "todo-1-7", subject = "[todos] task assigned to you: Ship",
    body = "You've been assigned a new task.\n  id : t1" })
  ok("[7] typed: subject, then body", r == true and sends[#sends].slot == 3
    and sends[#sends].text == fb.PREFIX .. "[todos] task assigned to you: Ship: You've been assigned a new task. id : t1",
    sends[#sends] and sends[#sends].text)
  ok("[7] this instance's agent is typed", fb.notifier_handler({ recipient = "agent:lector:1111-2222", key = "todo-1-8",
    body = "b" }) == true and #sends == n + 2)
  local other, why = fb.notifier_handler({ recipient = "agent:lector:9999-1", key = "todo-1-9", body = "b" })
  ok("[7] another instance's agent: false, why", other == false and type(why) == "string" and #sends == n + 2, tostring(why))
  ok("[7] no key: false", fb.notifier_handler({ recipient = "agent:lector", body = "b" }) == false and #sends == n + 2)
  ok("[7] not an agent: false", fb.notifier_handler({ recipient = "user", key = "k", body = "b" }) == false)
end

-- ── [8] the state file keeps the newest keys ────────────────────────────────

do
  local max = fb.MAX_KEYS
  fb.MAX_KEYS = 3
  for i = 1, 5 do fb.type_once("gold-man", "prune-" .. i, "p" .. i) end
  local kept = vim.fn.readfile(fb.state_file())
  ok("[8] at most MAX_KEYS kept", #kept == 3, vim.inspect(kept))
  ok("[8] the newest, in order", vim.deep_equal(kept, { "prune-3", "prune-4", "prune-5" }), vim.inspect(kept))
  restart()
  local n = #sends
  fb.type_once("gold-man", "prune-5", "p5")
  ok("[8] a kept key still types nothing after a restart", #sends == n)
  fb.MAX_KEYS = max
end

vim.fn.delete(sb, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
