--- Tests for auto-agents.crew, this Neovim's crew scope in the AutoDoc daemon (ADR 1793271500 §4.3,
--- crew epic phase 4c). Run with: nvim --headless -u NONE -l tests/crew_scope_spec.lua
---
--- A fake autodoc.session answers crew.claim / crew.renew / crew.release as the test says, a fake
--- clock runs the renew timers on demand, and a fake event bus fires autodoc.session:connected.
---   [1] the scope: autovim:<project> from AUTOVIM_PROJECT, else nvim:<project key>, else none
---   [2] proc_ref reads boot id, pid namespace, pid and start time as core/crew's ProcRef does,
---       a command holding spaces and parentheses included; "" when /proc can't say
---   [3] the first connection claims; a reconnect reattaches with the same run token
---   [4] the lease is renewed every interval with the held epoch
---   [5] a renewal refused for a stale epoch claims again and says the agents moved
---   [6] a busy scope is said once and retried; any other refusal is said and retried
---   [7] a daemon without the crew verbs is never asked, and a method-not-found keeps it quiet
---   [8] release gives the scope up, and no renewal runs after it
---   [9] late replies (a deferred fake): a claim accepted after release is given back and holds
---       nothing; a reattach answered after release resurrects nothing; a stopped state's late
---       reply and timers leave a newer setup's state alone
---  [10] a held scope whose reattach, renewal or claim fails is no longer reported held, is
---       retried, and recovers: at the same epoch quietly, at another saying the agents moved

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

local crew = require("auto-agents.crew")

-- ── fakes ───────────────────────────────────────────────────────────────────

local function new_world(opts)
  opts = opts or {}
  local w = { calls = {}, notices = {}, published = {}, timers = {}, subs = {}, answer = {}, pending = {},
    deferred = opts.deferred == true }
  -- reply answers the oldest pending call of method, as the daemon would, later
  w.reply = function(method, res, err)
    for i, c in ipairs(w.pending) do
      if c.method == method then
        table.remove(w.pending, i)
        c.cb(res, err)
        return true
      end
    end
    return false
  end
  w.client = { can = function(_, m) return opts.serves ~= false or m ~= "crew.claim" end }
  w.session = {
    is_ready = function() return opts.ready == true end,
    client = function() return w.client end,
    call = function(method, params, cb)
      w.calls[#w.calls + 1] = { method = method, params = vim.deepcopy(params) }
      if w.deferred then
        w.pending[#w.pending + 1] = { method = method, params = vim.deepcopy(params), cb = cb }
        return
      end
      local a = w.answer[method]
      local res, err
      if type(a) == "function" then res, err = a(params) else res, err = a, nil end
      cb(res, err)
    end,
  }
  w.events = {
    register_topics = function() end,
    publish = function(topic, payload) w.published[#w.published + 1] = { topic = topic, payload = payload } end,
    subscribe = function(topic, fn)
      w.subs[topic] = fn
      return topic
    end,
    unsubscribe = function(topic) w.subs[topic] = nil end,
  }
  w.connect = function() if w.subs["autodoc.session:connected"] then w.subs["autodoc.session:connected"]({}) end end
  w.tick = function() -- run every timer due now
    local due = w.timers
    w.timers = {}
    for _, fn in ipairs(due) do fn() end
  end
  w.of = function(method)
    local out = {}
    for _, c in ipairs(w.calls) do if c.method == method then out[#out + 1] = c end end
    return out
  end
  assert(crew.setup({
    session = w.session, events = w.events, env = opts.env or { AUTOVIM_PROJECT = "alpha" }, project_key = "k1",
    proc = "boot:4026531836:1234:99",
    notify = function(msg) w.notices[#w.notices + 1] = msg end,
    after = function(_, fn) w.timers[#w.timers + 1] = fn end,
    wait = function() end,
  }))
  return w
end

-- ── [1] the scope ───────────────────────────────────────────────────────────

ok("[1] AUTOVIM_PROJECT names the scope autovim:<project>", crew.scope_id({ AUTOVIM_PROJECT = "alpha" }, "k1") == "autovim:alpha")
ok("[1] without it, the scope is nvim:<project key>", crew.scope_id({}, "k1") == "nvim:k1")
ok("[1] an empty AUTOVIM_PROJECT falls back too", crew.scope_id({ AUTOVIM_PROJECT = "" }, "k1") == "nvim:k1")
ok("[1] neither: no scope, nothing to claim", crew.scope_id({}, nil) == nil and crew.setup({ env = {}, project_key = nil }) == false)

-- ── [2] proc_ref ────────────────────────────────────────────────────────────

do
  local root = vim.fn.tempname()
  local pid = vim.uv.os_getpid()
  vim.fn.mkdir(root .. "/sys/kernel/random", "p")
  vim.fn.mkdir(root .. "/self/ns", "p")
  vim.fn.mkdir(root .. "/" .. pid, "p")
  vim.fn.writefile({ "6f1c8e2a-boot" }, root .. "/sys/kernel/random/boot_id")
  vim.uv.fs_symlink("pid:[4026531836]", root .. "/self/ns/pid")
  -- fields after the command: 3 (state) .. 22 (start time) = 777
  local after = "S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777 21 22"
  vim.fn.writefile({ pid .. " (nvim (x) y) " .. after }, root .. "/" .. pid .. "/stat")
  ok("[2] proc_ref is <boot id>:<pid ns>:<pid>:<start time>, past a command with spaces and parentheses",
    crew.proc_ref(root) == ("6f1c8e2a-boot:4026531836:%d:777"):format(pid), crew.proc_ref(root))
  ok("[2] a missing /proc answers \"\", leaving it to the lease", crew.proc_ref(vim.fn.tempname()) == "")
  vim.fn.delete(root, "rf")
end

-- ── [3] claim, then reattach ────────────────────────────────────────────────

do
  local w = new_world()
  w.answer["crew.claim"] = { epoch = 3 }
  ok("[3] nothing is claimed before the daemon is connected", #w.calls == 0)
  w.connect()
  local claims = w.of("crew.claim")
  local p = claims[1] and claims[1].params or {}
  ok("[3] the first connection claims the scope with the run token and the process reference",
    #claims == 1 and p[1] == "autovim:alpha" and type(p[2]) == "string" and #p[2] == 64 and p[3] == "boot:4026531836:1234:99",
    vim.inspect(claims))
  local scope, epoch = crew.held()
  ok("[3] the scope is held at the daemon's epoch", scope == "autovim:alpha" and epoch == 3)
  ok("[3] claimed is published, not as a reattach",
    w.published[1] and w.published[1].topic == crew.TOPIC_CLAIMED and w.published[1].payload.reattached == false)
  w.connect()
  claims = w.of("crew.claim")
  ok("[3] a reconnect reattaches with the same run token", #claims == 2 and claims[2].params[2] == p[2])
  ok("[3] the same epoch is a quiet reattach", #w.notices == 0 and w.published[2].payload.reattached == true)
  crew.stop()
end

-- ── [4] [5] renew, and a stale epoch ────────────────────────────────────────

do
  local w = new_world()
  w.answer["crew.claim"] = { epoch = 3 }
  w.connect()
  w.answer["crew.renew"] = nil
  w.tick()
  local renews = w.of("crew.renew")
  ok("[4] the lease is renewed with the scope, run token and held epoch",
    #renews == 1 and renews[1].params[1] == "autovim:alpha" and renews[1].params[3] == 3, vim.inspect(renews))
  w.tick()
  ok("[4] and again at the next interval", #w.of("crew.renew") == 2)
  w.answer["crew.renew"] = function() return nil, { code = crew.CODE_STALE_EPOCH, message = "crew: stale epoch" } end
  w.answer["crew.claim"] = { epoch = 4 }
  w.tick()
  local _, epoch = crew.held()
  ok("[5] a stale epoch claims the scope again", #w.of("crew.claim") == 2 and epoch == 4)
  ok("[5] and says the agents moved to the new epoch", #w.notices == 1 and w.notices[1]:find("epoch 4", 1, true) ~= nil, vim.inspect(w.notices))
  crew.stop()
end

-- ── [6] busy, and other refusals ────────────────────────────────────────────

do
  local w = new_world()
  w.answer["crew.claim"] = function() return nil, { code = crew.CODE_SCOPE_BUSY, message = "crew: the scope is held" } end
  w.connect()
  ok("[6] a busy scope holds nothing and is said once", crew.held() == nil and #w.notices == 1 and w.notices[1]:find("held by another", 1, true))
  w.tick()
  ok("[6] it is retried, and not said again", #w.of("crew.claim") == 2 and #w.notices == 1)
  w.answer["crew.claim"] = { epoch = 7 }
  w.tick()
  local _, epoch = crew.held()
  ok("[6] once free, the retry claims it", epoch == 7)
  crew.stop()

  w = new_world()
  w.answer["crew.claim"] = function() return nil, { code = -32603, message = "store down" } end
  w.connect()
  ok("[6] another refusal is said with its reason", #w.notices == 1 and w.notices[1]:find("store down", 1, true))
  w.answer["crew.claim"] = { epoch = 2 }
  w.tick()
  ok("[6] and retried", select(2, crew.held()) == 2)
  crew.stop()
end

-- ── [7] a daemon without crew ───────────────────────────────────────────────

do
  local w = new_world({ serves = false })
  w.connect()
  ok("[7] a daemon whose capabilities lack crew.claim is never asked", #w.calls == 0 and #w.notices == 0)
  crew.stop()

  w = new_world()
  w.answer["crew.claim"] = function() return nil, { code = crew.CODE_METHOD_NOT_FOUND, message = "unknown method" } end
  w.connect()
  w.tick()
  ok("[7] a method-not-found keeps it quiet, with no retry", #w.of("crew.claim") == 1 and #w.notices == 0 and #w.timers == 0)
  w.answer["crew.claim"] = { epoch = 1 }
  w.connect()
  ok("[7] the next connection (an upgraded daemon) tries again", select(2, crew.held()) == 1)
  crew.stop()
end

-- ── [8] release ─────────────────────────────────────────────────────────────

do
  local w = new_world()
  w.answer["crew.claim"] = { epoch = 5 }
  w.connect()
  crew.release()
  local rel = w.of("crew.release")
  ok("[8] release gives the scope up with the run token and epoch",
    #rel == 1 and rel[1].params[1] == "autovim:alpha" and rel[1].params[3] == 5 and crew.held() == nil, vim.inspect(rel))
  w.tick()
  ok("[8] no renewal runs after it", #w.of("crew.renew") == 0)
  crew.release()
  ok("[8] a second release asks nothing", #w.of("crew.release") == 1)
  crew.stop()
end

-- ── [9] lifetimes: replies that arrive late (#3 r0, F1) ─────────────────────

do -- a release before the first claim answers gives the late epoch back, and holds nothing
  local w = new_world({ deferred = true })
  w.connect()
  crew.release()
  w.reply("crew.claim", { epoch = 9 })
  local rel = w.of("crew.release")
  ok("[9] a claim accepted after release is given back at its epoch", #rel == 1 and rel[1].params[3] == 9, vim.inspect(rel))
  ok("[9] and nothing is held, no renewal scheduled", crew.held() == nil and #w.timers == 0)
  w.connect()
  ok("[9] a connection after release claims nothing", #w.of("crew.claim") == 1)
  crew.stop()
end

do -- a reattach answered after release resurrects nothing
  local w = new_world({ deferred = true })
  w.connect(); w.reply("crew.claim", { epoch = 3 })
  w.connect() -- a reconnect: the reattach is in flight
  crew.release()
  w.reply("crew.release", nil)
  w.reply("crew.claim", { epoch = 3 })
  w.tick()
  ok("[9] a reattach answered after release holds nothing and renews nothing",
    crew.held() == nil and #w.of("crew.renew") == 0, vim.inspect(w.calls))
  crew.stop()
end

do -- stop, then a new setup: the old state's late claim reply touches nothing of the new one
  local w = new_world({ deferred = true })
  w.connect()
  local w2 = new_world() -- setup again: the first state is stopped
  w2.answer["crew.claim"] = { epoch = 1 }
  w2.connect()
  w.reply("crew.claim", { epoch = 50 }) -- the old state's claim, late
  local _, epoch = crew.held()
  ok("[9] a stopped state's late claim leaves the new state's epoch alone", epoch == 1, tostring(epoch))
  ok("[9] and is given back, not left held", #w.of("crew.release") == 1 and w.of("crew.release")[1].params[3] == 50)
  crew.stop()
end

do -- a held state's renewal timer, fired after a new setup at the same attempt count, renews nothing
  local w = new_world()
  w.answer["crew.claim"] = { epoch = 3 }
  w.connect() -- held: one renewal timer pending, at this state's attempt
  local old_timers = w.timers
  w.timers = {}
  ok("[9] the held state has its renewal timer pending", #old_timers == 1)
  local w2 = new_world() -- a new state, whose attempt counter starts where the old one's did
  w2.answer["crew.claim"] = { epoch = 3 }
  w2.connect()
  for _, fn in ipairs(old_timers) do fn() end
  ok("[9] the stopped state's timer sends nothing, through either session",
    #w.of("crew.renew") == 0 and #w2.of("crew.renew") == 0)
  ok("[9] and the new state is still held", select(2, crew.held()) == 3)
  crew.stop()
end

-- ── [10] a held scope whose reattach fails is not reported held, and recovers (#3 r0, F2) ──

do
  local w = new_world({ deferred = true })
  w.connect(); w.reply("crew.claim", { epoch = 3 })
  w.connect() -- reconnect while held
  w.reply("crew.claim", nil, { code = -32603, message = "store down" })
  ok("[10] a failed reattach reports nothing held: the lease may lapse", crew.held() == nil)
  w.tick() -- the retry
  ok("[10] it is retried", #w.of("crew.claim") == 3)
  w.reply("crew.claim", { epoch = 3 })
  local _, epoch = crew.held()
  ok("[10] and the retry reattaches at the same epoch, quietly", epoch == 3 and #w.notices == 1, vim.inspect(w.notices))
  w.tick() -- renewal resumes
  ok("[10] renewal resumes after the recovery", #w.of("crew.renew") == 1)
  crew.stop()

  w = new_world({ deferred = true })
  w.connect(); w.reply("crew.claim", { epoch = 3 })
  w.connect()
  w.reply("crew.claim", nil, { code = crew.CODE_SCOPE_BUSY, message = "busy" })
  ok("[10] busy after held reports nothing held", crew.held() == nil)
  w.tick()
  w.reply("crew.claim", { epoch = 4 })
  local _, e2 = crew.held()
  ok("[10] and a later claim at another epoch says the agents moved",
    e2 == 4 and w.notices[#w.notices]:find("epoch 4", 1, true) ~= nil, vim.inspect(w.notices))
  crew.stop()

  w = new_world({ deferred = true })
  w.connect(); w.reply("crew.claim", { epoch = 3 })
  w.tick()
  w.reply("crew.renew", nil, { code = -32000, message = "connection lost" })
  ok("[10] a renewal lost to the transport reports nothing held", crew.held() == nil)
  w.tick()
  w.reply("crew.claim", { epoch = 3 })
  ok("[10] and reattaches on the retry", select(2, crew.held()) == 3)
  crew.stop()
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
