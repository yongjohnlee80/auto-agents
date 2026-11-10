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
--   [9] two Neovims, then a restart: no Neovim erases another's keys
--   [10] guarded (a delivery): an agent on a prompt gets nothing typed and no key kept, then is
--       typed once it has closed; prompts unreported (or nothing says) → pasted with no Enter,
--       typed_not_sent; unguarded typing unchanged; a todo notice is held the same way
--   [11] the inbox's waits_on_user: before a snapshot, waits when the daemon serves the inbox, nil
--       when not; then true only on a permission or blocked attention
--   [12] a guarded Enter reads the state again after SUBMIT_DELAY_MS: a prompt opened since the
--       paste, another session, slot or terminal → no Enter, typed_not_sent
--   [13] a key keeps what came of it (sent or typed_not_sent): a re-offer or a restart never
--       upgrades a paste-only key; a legacy bare line is sent; a crash before the Enter reads not sent
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

-- ── [9] two Neovims, then a restart: no Neovim erases another's keys ─────────

do
  local crew = require("auto-agents.crew")
  local real = crew.incarnation
  local function as_host(id) crew.incarnation = function() return id end; restart() end
  as_host("1001-aaaaaaaaaaaa")
  fb.type_once("gold-man", "job-host-a", "a")
  as_host("1002-bbbbbbbbbbbb")
  fb.type_once("gold-man", "job-host-b", "b")
  ok("[9] each Neovim keeps its keys in a file of its own",
    vim.tbl_contains(vim.fn.readfile(fb.state_file()), "job-host-b")
      and not vim.tbl_contains(vim.fn.readfile(fb.state_file()), "job-host-a"))
  local a_file = vim.fs.joinpath(fb.state_dir(), "1001-aaaaaaaaaaaa")
  ok("[9] the other Neovim's key is still kept", vim.tbl_contains(vim.fn.readfile(a_file), "job-host-a"))
  local n = #sends
  fb.type_once("gold-man", "job-host-a", "a")
  ok("[9] a key another Neovim typed isn't typed again here", #sends == n)
  as_host("1003-cccccccccccc") -- host A crashed; its successor is offered A's job again
  fb.type_once("gold-man", "job-host-a", "a")
  fb.type_once("gold-man", "job-host-b", "b")
  ok("[9] after a restart, neither Neovim's key is typed again", #sends == n)
  crew.incarnation = real
  restart()
end

-- ── [10] the guard: never typed into an open prompt ─────────────────────────

-- the guard's world: gold-man's crew session, whether the inbox has it on a prompt, the deferred
-- Enters (run by hand), the keys pressed, and what each guarded delivery's done heard
local G = { session = nil, waits = nil, later = {}, presses = {}, heard = {} }
do
  local crew = require("auto-agents.crew")
  local inbox = require("auto-agents.crew_inbox")
  G.real = { session_of = crew.session_of, waits_on_user = inbox.waits_on_user, after = fb._after }
  crew.session_of = function(name) return name == "gold-man" and G.session or nil end
  inbox.waits_on_user = function(id)
    if G.session and id == G.session.id then return G.waits end -- false is "no prompt open", nil "nothing says"
    return nil
  end
  fb._after = function(ms, fn) G.later[#G.later + 1] = { ms = ms, fn = fn } end
  package.loaded["auto-agents"].send_keypress = function(slot, key)
    if refuse[slot] then return false end
    G.presses[#G.presses + 1] = { slot = slot, key = key }
    return true
  end
end
local function run_later()
  local due = G.later
  G.later = {}
  for _, l in ipairs(due) do l.fn() end
end
local function line_of_key(key)
  for _, l in ipairs(vim.fn.readfile(fb.state_file())) do
    if l == key or l:sub(1, #key + 1) == key .. "\t" then return l end
  end
  return nil
end
local function guarded(key, text)
  local heard
  local r, why, how = fb.type_once("gold-man", key, text, { guard = true, done = function(...) heard = { ... } end })
  return { r = r, why = why, how = how, heard = function() return heard end }
end

do
  G.session, G.waits = { id = "s-gold", codename = "gold-man", prompts = true }, true
  local n, p = #sends, #G.presses
  local g = guarded("job-prompt", "Mail from jarvis.")
  local h = g.heard()
  ok("[10] an open prompt: done hears false, waits, saying why", h and h[1] == false and h[3] == "waits"
    and type(h[2]) == "string" and h[2]:find("prompt", 1, true) ~= nil, vim.inspect(h))
  ok("[10] an open prompt: nothing typed, not even pasted", #sends == n and #G.presses == p, vim.inspect(sends[#sends]))
  ok("[10] an open prompt: no key kept, so the next offer types it", line_of_key("job-prompt") == nil)
  G.waits = false
  g = guarded("job-prompt", "Mail from jarvis.")
  ok("[10] once the prompt has closed: pasted with no Enter of send_slot's", #sends == n + 1
    and sends[#sends].opts.submit == false and g.heard() == nil, vim.inspect(sends[#sends]))
  ok("[10] ... its line kept as not sent until its Enter", line_of_key("job-prompt") == "job-prompt\t" .. fb.NOT_SENT,
    line_of_key("job-prompt"))
  ok("[10] ... its Enter waits SUBMIT_DELAY_MS", #G.later == 1 and G.later[1].ms == fb.SUBMIT_DELAY_MS, vim.inspect(G.later))
  run_later()
  local hh = g.heard()
  ok("[10] ... then, still clear, one Enter, and done hears sent", #G.presses == p + 1 and G.presses[#G.presses].key == "<CR>"
    and G.presses[#G.presses].slot == 2 and hh and hh[1] == true and hh[3] == "sent", vim.inspect({ G.presses, hh }))
  ok("[10] ... and its line is the bare key now (sent)", line_of_key("job-prompt") == "job-prompt", line_of_key("job-prompt"))
  g = guarded("job-prompt", "Mail from jarvis.")
  ok("[10] ... once: offered again, sent, nothing typed", #sends == n + 1 and g.heard() and g.heard()[3] == "sent")

  G.session, G.waits = { id = "s-gold", codename = "gold-man", prompts = false }, false
  n, p = #sends, #G.presses
  g = guarded("job-unreported", "Mail from lector.")
  ok("[10] prompts unreported: pasted with no Enter, typed_not_sent", g.heard() and g.heard()[3] == fb.NOT_SENT
    and #sends == n + 1 and sends[#sends].opts.submit == false and sends[#sends].text == "Mail from lector."
    and #G.later == 0 and #G.presses == p, vim.inspect({ g.heard(), sends[#sends], G.later }))
  ok("[10] prompts unreported: its line kept as not sent", line_of_key("job-unreported") == "job-unreported\t" .. fb.NOT_SENT)
  G.session = nil
  g = guarded("job-nosession", "x")
  ok("[10] no crew session: unreported, pasted with no Enter", g.heard() and g.heard()[3] == fb.NOT_SENT
    and sends[#sends].opts.submit == false, vim.inspect(g.heard()))
  G.session, G.waits = { id = "s-gold", codename = "gold-man", prompts = true }, nil
  g = guarded("job-noinbox", "x")
  ok("[10] no inbox (nothing says): unreported, pasted with no Enter", g.heard() and g.heard()[3] == fb.NOT_SENT
    and sends[#sends].opts.submit == false, vim.inspect(g.heard()))

  G.waits = true
  n = #sends
  local r, _, how = fb.type_once("gold-man", "job-unguarded", "the user's own prompt")
  ok("[10] unguarded (not a delivery): typed and sent by send_slot, as before", r == true and how == "sent"
    and #sends == n + 1 and sends[#sends].opts.submit == true and vim.deep_equal(sends[#sends].opts.submit_keys, { "<CR>" }))
  ok("[10] unguarded: its line is the bare key", line_of_key("job-unguarded") == "job-unguarded")

  n, p = #sends, #G.presses
  local nr, nwhy = fb.notifier_handler({ recipient = "agent:gold-man", key = "todo-prompt-1", body = "b" })
  ok("[10] a todo notice to an agent on a prompt: false (held), nothing typed", nr == false and type(nwhy) == "string"
    and #sends == n and line_of_key("todo-prompt-1") == nil, vim.inspect({ nr, nwhy }))
  G.waits = false
  nr = fb.notifier_handler({ recipient = "agent:gold-man", key = "todo-prompt-1", body = "b" })
  ok("[10] ... once it has closed: typed (true), its Enter after the delay", nr == true and #sends == n + 1
    and sends[#sends].opts.submit == false and #G.later == 1)
  run_later()
  ok("[10] ... and pressed, still clear", #G.presses == p + 1)
end

-- ── [12] the Enter reads the state again: a prompt opened since the paste ───

do
  local function pasted(key)
    G.session, G.waits = { id = "s-gold", codename = "gold-man", prompts = true }, false
    local g = guarded(key, "Mail for " .. key)
    return g
  end
  local p = #G.presses
  local g = pasted("job-opened")
  G.waits = true -- a permission prompt opened between the paste and its Enter
  run_later()
  ok("[12] a prompt opened before the Enter: no Enter, done hears typed_not_sent", #G.presses == p
    and g.heard() and g.heard()[1] == true and g.heard()[3] == fb.NOT_SENT, vim.inspect({ G.presses, g.heard() }))
  ok("[12] ... its line stays not sent (it is in the input: never pasted again)",
    line_of_key("job-opened") == "job-opened\t" .. fb.NOT_SENT)
  g = pasted("job-newsession")
  G.session = { id = "s-gold-2", codename = "gold-man", prompts = true } -- the agent restarted meanwhile
  run_later()
  ok("[12] another session since the paste: no Enter, typed_not_sent", #G.presses == p
    and g.heard() and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
  g = pasted("job-reslotted")
  slots["gold-man"] = 3 -- the slot now runs someone else
  run_later()
  slots["gold-man"] = 2
  ok("[12] the codename's slot changed since the paste: no Enter, typed_not_sent", #G.presses == p
    and g.heard() and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
  local aa = package.loaded["auto-agents"]
  local term = { is_alive = function() return true end }
  aa.state = { slot_terminals = { [2] = term } }
  g = pasted("job-newterm")
  aa.state.slot_terminals[2] = { is_alive = function() return true end } -- a new terminal in the slot
  run_later()
  ok("[12] another terminal in the slot since the paste: no Enter, typed_not_sent", #G.presses == p
    and g.heard() and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
  aa.state.slot_terminals[2] = term
  g = pasted("job-sameterm")
  run_later()
  ok("[12] the same terminal, the same session, still clear: one Enter", #G.presses == p + 1
    and g.heard() and g.heard()[3] == "sent", vim.inspect(g.heard()))
  aa.state = nil
end

-- ── [13] a key keeps what came of it: a lost report never upgrades ──────────

do
  local n = #sends
  local g = guarded("job-unreported", "Mail from lector.") -- typed_not_sent in [10]; its report lost
  ok("[13] a paste-only key offered again: typed_not_sent, nothing typed", #sends == n
    and g.heard() and g.heard()[1] == true and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
  restart()
  g = guarded("job-unreported", "Mail from lector.")
  ok("[13] ... and after a restart", #sends == n and g.heard() and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
  g = guarded("job-opened", "x")
  ok("[13] an Enter withheld at the recheck: typed_not_sent after a restart too", #sends == n
    and g.heard() and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
  g = guarded("job-prompt", "x")
  ok("[13] one whose Enter was pressed: sent after a restart", #sends == n and g.heard() and g.heard()[3] == "sent")
  -- a line written before the guard: a bare key, typed with its Enter
  local own = vim.fn.readfile(fb.state_file())
  own[#own + 1] = "job-legacy"
  vim.fn.writefile(own, fb.state_file())
  restart()
  g = guarded("job-legacy", "x")
  ok("[13] a legacy bare line reads as sent", #sends == n and g.heard() and g.heard()[3] == "sent", vim.inspect(g.heard()))
  ok("[13] a key with a tab is no key", fb.type_once("gold-man", "a\tb", "x") == false)
  -- paste once with the line written, then crash before the Enter: a restart reads not sent
  G.session, G.waits = { id = "s-gold", codename = "gold-man", prompts = true }, false
  guarded("job-crash", "x")
  G.later = {} -- the Neovim ended before the delay was over
  restart()
  g = guarded("job-crash", "x")
  ok("[13] a restart between the paste and its Enter: typed_not_sent, nothing typed again", #sends == n + 1
    and g.heard() and g.heard()[3] == fb.NOT_SENT, vim.inspect(g.heard()))
end

-- ── [11] prompt_state reads the crew's session and the inbox's attention ────

do
  local crew = require("auto-agents.crew")
  local inbox = require("auto-agents.crew_inbox")
  crew.session_of, inbox.waits_on_user, fb._after = G.real.session_of, G.real.waits_on_user, G.real.after
  local x = inbox.new({ session = {}, notify = function() end })
  ok("[11] an inbox the daemon doesn't serve, before a snapshot, says nothing", x:waits_on_user("s-x") == nil)
  local serving = inbox.new({ notify = function() end, session = {
    client = function() return { can = function(_, verb) return verb == "inbox.watch" end } end } })
  ok("[11] an inbox the daemon serves, before its first snapshot: waits (the snapshot is on its way)",
    serving:waits_on_user("s-x") == true)
  x.known = true
  x.open.attention["s-x"] = { what = "permission" }
  ok("[11] a permission attention waits on the user", x:waits_on_user("s-x") == true)
  x.open.attention["s-x"] = { what = "blocked" }
  ok("[11] a blocked attention waits on the user", x:waits_on_user("s-x") == true)
  x.open.attention["s-x"] = { what = "idle" }
  ok("[11] another attention doesn't", x:waits_on_user("s-x") == false)
  x.open.attention["s-x"] = nil
  ok("[11] no attention doesn't", x:waits_on_user("s-x") == false)
  ok("[11] no inbox set up: nothing says", inbox.waits_on_user("s-x") == nil)
end

vim.fn.delete(sb, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
