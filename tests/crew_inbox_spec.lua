--- Tests for auto-agents.crew_inbox: the human's crew inbox in Neovim (ADR 1793271500 §4.8). One
--- inbox.watch long-poll per Neovim shows each decision request, report and permission prompt the
--- daemon holds for the user, and answers a request (inbox.reply / inbox.dismiss) with no AutoDoc
--- window open. It mirrors AutoDoc's window (tui/crewinbox.go): the open set is the daemon's
--- snapshot, read again after every change that can alter it. Run with:
---   nvim --headless -u NONE -l tests/crew_inbox_spec.lua
---
--- A fake autodoc.session holds each call until the cell answers it.
---   [1]  a daemon without inbox.watch is never asked
---   [2]  connected: asked for a snapshot (cursor 0, the daemon's longest wait, no page)
---   [3]  the first snapshot sets the baseline silently: one INFO line if anything is open, no WARN
---   [4]  a change re-reads the snapshot; a new request is one WARN, a closed one one INFO
---   [5]  a reconnect with the same requests open announces nothing (the known set outlives it)
---   [6]  a snapshot's pages are all read before anything is shown, at its first page's cursor
---   [7]  peer text is one inert line: control characters (ESC, CR, LF) are spaces, the subject capped
---   [8]  a reply is inbox.reply(message, body, key); a retry of the same text reuses its key
---   [9]  a refused reply is said plainly; dismiss and a report's ack call their verbs
---   [10] a permission prompt is one WARN and counts; a focus for this Neovim's session raises it
---   [11] answers arriving in a fast event touch nothing until scheduled (no E5560)
---   [12] a failure asks again later, backing off; a refused or missing verb stops until reconnect
---   [13] the winbar segment is the count alone, clickable, nothing at 0
---   [14] a body is shown as plain text: nofile, text filetype, no modeline

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:prepend(project_root)
vim.o.swapfile = false

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

local inbox = require("auto-agents.crew_inbox")

-- ── fakes ───────────────────────────────────────────────────────────────────

local WARN, INFO = vim.log.levels.WARN, vim.log.levels.INFO

local function flush() vim.wait(20, function() return false end) end

local function new_world(opts)
  opts = opts or {}
  local w = { calls = {}, held = {}, notes = {}, timers = {}, focused = {}, redraws = 0, fast = {} }
  w.client = { can = function(_, verb) return opts.can == nil or opts.can(verb) end }
  w.session = {
    is_ready = function() return true end,
    client = function() return w.client end,
    call = function(method, params, cb)
      local c = { method = method, params = vim.deepcopy(params), cb = cb }
      w.calls[#w.calls + 1] = c
      w.held[#w.held + 1] = c
    end,
  }
  -- answer the oldest held call of method; from_fast answers it inside a luv callback
  w.answer = function(method, res, err, from_fast)
    for i, c in ipairs(w.held) do
      if c.method == method then
        table.remove(w.held, i)
        if from_fast then
          local t = vim.uv.new_timer()
          t:start(0, 0, function() t:close(); c.cb(res, err) end)
          vim.wait(200, function() return false end)
        else
          c.cb(res, err)
        end
        flush()
        return c
      end
    end
    error("no held call of " .. method .. ": " .. vim.inspect(w.calls))
  end
  w.of = function(method)
    local out = {}
    for _, c in ipairs(w.calls) do if c.method == method then out[#out + 1] = c end end
    return out
  end
  w.level = function(level)
    local out = {}
    for _, n in ipairs(w.notes) do if n.level == level then out[#out + 1] = n.msg end end
    return out
  end
  -- the connection drops (its held calls fail, as a closed connection's do) and a new one comes
  w.reconnect = function()
    local held = w.held
    w.held = {}
    for _, c in ipairs(held) do c.cb(nil, { code = -32000, message = "connection closed" }) end
    flush()
    w.x:connected()
  end
  w.tick = function()
    local due = w.timers
    w.timers = {}
    for _, t in ipairs(due) do t.fn() end
    flush()
  end
  w.x = inbox.new({
    session = w.session,
    notify = function(msg, level)
      w.fast[#w.fast + 1] = vim.in_fast_event()
      vim.api.nvim_echo({ { "" } }, false, {}) -- an API call E5560 would refuse in a fast event
      w.notes[#w.notes + 1] = { msg = msg, level = level }
    end,
    after = function(ms, fn) w.timers[#w.timers + 1] = { ms = ms, fn = fn } end,
    focus = function(session)
      w.fast[#w.fast + 1] = vim.in_fast_event()
      w.focused[#w.focused + 1] = session
      return session == "s-mine"
    end,
    redraw = function()
      w.fast[#w.fast + 1] = vim.in_fast_event()
      w.redraws = w.redraws + 1
    end,
  })
  return w
end

local function request(id, from, subject, body)
  return { message = id, kind = "request", from = from or "jarvis", subject = subject or ("Decision: " .. id),
    body = body or ("the question " .. id), session = "s-" .. (from or "jarvis"), state = "open" }
end

local function snapshot(cursor, items, attention, next)
  return { cursor = cursor, snapshot = { items = items or {}, attention = attention or {}, next = next or "" }, changes = {} }
end

local function changes(cursor, list) return { cursor = cursor, changes = list } end

-- connected and answered with a first snapshot of items
local function started(items, attention)
  local w = new_world()
  w.x:connected()
  w.answer("inbox.watch", snapshot(7, items, attention))
  return w
end

-- ── cells ───────────────────────────────────────────────────────────────────

do
  local w = new_world({ can = function(verb) return verb ~= "inbox.watch" end })
  w.x:connected()
  ok("[1] a daemon without inbox.watch is never asked", #w.of("inbox.watch") == 0, vim.inspect(w.calls))
end

do
  local w = new_world()
  w.x:connected()
  local p = (w.of("inbox.watch")[1] or {}).params or {}
  ok("[2] connected: a snapshot is asked (cursor 0, the longest wait, no page)",
    #w.of("inbox.watch") == 1 and p[1] == 0 and p[2] == inbox.WAIT_MS and inbox.WAIT_MS == 25000 and (p[3] == nil or p[3] == ""),
    vim.inspect(w.calls))
end

do
  local w = started({ request("r1"), request("r2", "kimmy-vision") })
  local infos = w.level(INFO)
  ok("[3] the first snapshot is the baseline: no WARN, one INFO naming how many wait",
    #w.level(WARN) == 0 and #infos == 1 and infos[1]:find("2 requests", 1, true) and infos[1]:find(":AutoAgentsInbox", 1, true),
    vim.inspect(w.notes))
  ok("[3] the open requests are known and counted", w.x:count() == 2 and #w.x:requests() == 2, vim.inspect(w.x:requests()))
  ok("[3] the next watch goes on from the snapshot's cursor", (w.of("inbox.watch")[2] or {}).params[1] == 7, vim.inspect(w.calls))
  local quiet = started({})
  ok("[3] an empty first snapshot says nothing", #quiet.notes == 0, vim.inspect(quiet.notes))
end

do
  local w = started({ request("r1") })
  local before = #w.notes
  w.answer("inbox.watch", changes(8, { { seq = 8, kind = "request", ref = "r2" } }))
  local again = w.of("inbox.watch")
  ok("[4] a change re-reads the snapshot (cursor 0)", again[#again].params[1] == 0, vim.inspect(again))
  w.answer("inbox.watch", snapshot(8, { request("r1"), request("r2", "kimmy-vision", "Decision: merge?") }))
  local warns = w.level(WARN)
  ok("[4] the new request is one WARN naming its sender and subject",
    #warns == 1 and warns[1]:find("kimmy-vision", 1, true) and warns[1]:find("Decision: merge?", 1, true) and #w.notes == before + 1,
    vim.inspect(w.notes))
  w.answer("inbox.watch", changes(9, { { seq = 9, kind = "answered", ref = "r1" } }))
  w.answer("inbox.watch", snapshot(9, { request("r2", "kimmy-vision", "Decision: merge?") }))
  local last = w.notes[#w.notes]
  ok("[4] a request that left the set is one INFO saying it closed",
    #w.level(WARN) == 1 and last.level == INFO and last.msg:find("jarvis", 1, true) and last.msg:find("closed", 1, true) and w.x:count() == 1,
    vim.inspect(w.notes))
  ok("[4] the winbar is redrawn as the count changes", w.redraws >= 2, w.redraws)
end

do
  local w = started({ request("r1"), request("r2") })
  local before = #w.notes
  w.reconnect() -- the daemon restarted: the old connection's watch fails, a new connection comes
  w.answer("inbox.watch", snapshot(3, { request("r1"), request("r2") }))
  ok("[5] a reconnect with the same two open announces nothing", #w.level(WARN) == 0 and #w.notes == before, vim.inspect(w.notes))
  w.reconnect()
  w.answer("inbox.watch", snapshot(4, { request("r1"), request("r2"), request("r3", "bartz") }))
  local warns = w.level(WARN)
  ok("[5] one that opened while it was away is announced", #warns == 1 and warns[1]:find("bartz", 1, true), vim.inspect(w.notes))
  w.tick() -- the old connections' retry timers
  ok("[5] an earlier connection's loop stops: its retry asks nothing more", #w.held == 1 and #w.of("inbox.watch") == 6,
    vim.inspect(w.calls))
end

do
  local w = new_world()
  w.x:connected()
  w.answer("inbox.watch", snapshot(11, { request("r1") }, {}, "page-2"))
  local p = (w.of("inbox.watch")[2] or {}).params or {}
  ok("[6] a snapshot's next page is asked for, nothing shown yet",
    p[3] == "page-2" and w.x:count() == 0 and #w.notes == 0, vim.inspect({ w.calls, w.notes }))
  w.answer("inbox.watch", snapshot(11, { request("r2") }))
  local q = (w.of("inbox.watch")[3] or {}).params or {}
  ok("[6] then all of it is shown, and the watch goes on at the first page's cursor",
    w.x:count() == 2 and q[1] == 11 and (q[3] == nil or q[3] == ""), vim.inspect(w.calls))
end

do
  local subject = "Decision: line one\nline two\r\27[31mred\27[0m\tend " .. string.rep("x", 300)
  local w = started({})
  w.answer("inbox.watch", changes(8, { { seq = 8, kind = "request", ref = "r1" } }))
  w.answer("inbox.watch", snapshot(8, { request("r1", "evil\27]0;title\7", subject) }))
  local warn = w.level(WARN)[1] or ""
  ok("[7] a subject with newlines and escapes arrives as one plain line",
    not warn:find("[%c]") and warn:find("line one line two", 1, true) and warn:find("red", 1, true), vim.inspect(warn))
  local label = inbox.label(w.x:requests()[1])
  ok("[7] the pick list's label is one inert line too, the subject capped",
    not label:find("[%c]") and #label <= inbox.SUBJECT_MAX + 40 and #inbox.inert(subject, inbox.SUBJECT_MAX) <= inbox.SUBJECT_MAX,
    vim.inspect(label))
end

do
  local w = started({ request("r1") })
  local results = {}
  w.x:reply("r1", "yes, merge it", function(err) results[#results + 1] = err or "ok" end)
  local first = w.answer("inbox.reply", nil, { code = -32000, message = "store busy" })
  w.x:reply("r1", "yes, merge it", function(err) results[#results + 1] = err or "ok" end)
  local second = w.answer("inbox.reply", { message = "resp-1" })
  w.x:reply("r1", "no", function(err) results[#results + 1] = err or "ok" end)
  local third = w.answer("inbox.reply", { message = "resp-2" })
  local p1, p2, p3 = first.params, second.params, third.params
  ok("[8] inbox.reply(message, body, key)", p1[1] == "r1" and p1[2] == "yes, merge it" and type(p1[3]) == "string" and #p1[3] >= 16,
    vim.inspect(p1))
  ok("[8] a retry of the same text reuses its key; another text gets its own",
    p2[3] == p1[3] and p3[3] ~= p1[3], vim.inspect({ p1[3], p2[3], p3[3] }))
  ok("[8] the outcome is told to the caller", results[2] == "ok" and results[1] ~= "ok", vim.inspect(results))
end

do
  local w = started({ request("r1"), { message = "m1", kind = "message", from = "bartz", subject = "Checkpoint: done", body = "b",
    session = "s-bartz", state = "open" } })
  local said
  w.x:reply("r1", "go", function(err) said = err end)
  w.answer("inbox.reply", nil, { code = inbox.CODE_ALREADY_ANSWERED, message = "the request was answered first" })
  ok("[9] an answer that came second is said plainly", type(said) == "string" and said:find("already answered", 1, true), vim.inspect(said))
  w.x:reply("r1", "go", function(err) said = err end)
  w.answer("inbox.reply", nil, { code = inbox.CODE_EXPIRED, message = "the message expired first" })
  ok("[9] an expired request says so", type(said) == "string" and said:find("expired", 1, true), vim.inspect(said))
  w.x:dismiss("r1", function() end)
  local d = w.answer("inbox.dismiss", {})
  w.x:ack("m1", function() end)
  local a = w.answer("inbox.ack", {})
  ok("[9] dismiss and a report's ack call their verbs", d.params[1] == "r1" and a.params[1] == "m1", vim.inspect({ d.params, a.params }))
  ok("[9] a report is listed, apart from the requests", #w.x:reports() == 1 and #w.x:requests() == 1, vim.inspect(w.x:reports()))
end

do
  local w = started({})
  w.answer("inbox.watch", changes(8, { { seq = 8, kind = "attention", ref = "s-tifa" } }))
  w.answer("inbox.watch", snapshot(8, {}, { { session = "s-tifa", codename = "tifa-lockhart", owner = "autovim:alpha", kind = "permission",
    text = "run rm -rf build?" } }))
  local warns = w.level(WARN)
  ok("[10] a permission prompt is one WARN naming the agent and the prompt, and counts",
    #warns == 1 and warns[1]:find("tifa-lockhart", 1, true) and warns[1]:find("rm -rf build", 1, true) and w.x:count() == 1,
    vim.inspect(w.notes))
  w.answer("inbox.watch", changes(9, { { seq = 9, kind = "focus", ref = "s-mine" } }))
  ok("[10] a focus raises this Neovim's agent of that session", w.focused[1] == "s-mine", vim.inspect(w.focused))
end

do
  local w = new_world()
  w.x:connected()
  w.answer("inbox.watch", snapshot(7, { request("r1") }), nil, true)
  w.answer("inbox.watch", changes(8, { { seq = 8, kind = "request", ref = "r2" } }), nil, true)
  w.answer("inbox.watch", snapshot(8, { request("r1"), request("r2") }), nil, true)
  w.answer("inbox.watch", changes(9, { { seq = 9, kind = "focus", ref = "s-mine" } }), nil, true)
  local any_fast = false
  for _, f in ipairs(w.fast) do any_fast = any_fast or f end
  ok("[11] answers from a fast event notify, redraw and focus only once scheduled",
    #w.fast >= 3 and not any_fast and w.x:count() == 2 and w.focused[1] == "s-mine", vim.inspect({ fast = w.fast, notes = w.notes }))
end

do
  local w = new_world()
  w.x:connected()
  w.answer("inbox.watch", nil, { code = -32000, message = "store busy" })
  local t1 = w.timers[1]
  w.tick()
  w.answer("inbox.watch", nil, { code = -32000, message = "store busy" })
  local t2 = w.timers[1]
  ok("[12] a failure asks again after a wait that doubles", t1 and t2 and t1.ms == inbox.RETRY_MS and t2.ms == 2 * inbox.RETRY_MS
    and #w.of("inbox.watch") == 2, vim.inspect({ t1 = t1 and t1.ms, t2 = t2 and t2.ms }))
  w.tick()
  w.answer("inbox.watch", snapshot(1, {}))
  ok("[12] an answer starts the wait over", #w.held == 1 and #w.timers == 0, vim.inspect(w.timers))
  for _, case in ipairs({ { -32602, "invalid params", true }, { -32001, "access denied", true }, { -32601, "unknown method", false } }) do
    local v = new_world()
    v.x:connected()
    v.answer("inbox.watch", nil, { code = case[1], message = case[2] })
    v.tick()
    local told = #v.notes == 1 and v.notes[1].msg:find(case[2], 1, true) ~= nil
    ok("[12] " .. case[2] .. " stops the watch until the next connection" .. (case[3] and ", told once" or ", quietly"),
      #v.held == 0 and #v.timers == 0 and (case[3] and told or #v.notes == 0), vim.inspect({ v.held, v.notes }))
  end
end

do
  ok("[13] no winbar segment at 0", inbox.winbar_segment(0) == "", vim.inspect(inbox.winbar_segment(0)))
  local seg = inbox.winbar_segment(3)
  local shown = seg:gsub("%%%d*@[^@]*@", ""):gsub("%%X", ""):gsub("%%#[^#]*#", ""):gsub("%%%*", "")
  ok("[13] the segment is the count alone, clickable", vim.trim(shown) == "!3" and seg:find("@v:lua.require'auto-agents.crew_inbox'.click@", 1, true),
    vim.inspect(seg))
end

do
  local buf = inbox.show_body({ from = "jarvis", subject = "Decision: x", body = "# vim: set ft=lua:\n<script>\n%s %d" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  ok("[14] the body is plain text: nofile, text, no modeline, as written",
    vim.bo[buf].buftype == "nofile" and vim.bo[buf].filetype == "text" and vim.bo[buf].modeline == false
      and vim.tbl_contains(lines, "# vim: set ft=lua:") and vim.tbl_contains(lines, "%s %d") and not vim.bo[buf].modifiable,
    vim.inspect({ lines, vim.bo[buf].buftype, vim.bo[buf].filetype }))
end

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
