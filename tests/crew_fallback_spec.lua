--- Tests for auto-agents.crew's part in AutoDoc's fallback (r15 P4): mail the crew couldn't get
--- received in time comes back to this Neovim, the recipient's host, as jobs (mail.fallbacks),
--- each typed once into the recipient's terminal (auto-agents.fallback) and reported
--- (mail.fallback_done). Run with:
---   nvim --headless -u NONE -l tests/crew_fallback_spec.lua
---
--- A fake autodoc.session answers as the test says; the typing is a fake type_once that, as the real
--- one, types a key once and answers true for a key typed before.
---   [1] a daemon before protocol 42 is never asked for jobs
---   [2] a daemon of 42 is asked once the scope is held: scope, run token, epoch, the wait
---   [3] a job is typed into its codename's terminal, keyed by its id, the daemon's text as it is;
---       reported delivered under its lease; the user told; the next ask re-armed
---   [4] a job typed before (offered again: an earlier run typed it, its report lost) is reported
---       delivered, never typed twice
---   [5] a job that can't be typed is reported unknown, and the user is given its text
---   [6] a daemon without the verb, or a lost epoch, ends the asking; any other failure asks again

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
  local w = { calls = {}, notices = {}, timers = {}, subs = {}, answer = {}, typed = {}, types = {} }
  w.client = {
    can = function() return true end,
    hello = function() return { store_id = "store-1", protocol = opts.protocol or 42 } end,
    addr = function() return "/run/autodoc.sock" end,
  }
  w.session = {
    is_ready = function() return true end,
    client = function() return w.client end,
    call = function(method, params, cb)
      w.calls[#w.calls + 1] = { method = method, params = vim.deepcopy(params) }
      local a = w.answer[method]
      local res, err
      if type(a) == "function" then res, err = a(params) else res, err = a, nil end
      cb(res, err)
    end,
    workspace_of = function() return nil end,
    primary_workspace = function() return nil end,
    workspace = function() return nil end,
    workspaces = function(cb) cb({}, nil) end,
  }
  w.events = {
    register_topics = function() end,
    publish = function() end,
    subscribe = function(topic, fn) w.subs[topic] = fn; return topic end,
    unsubscribe = function(topic) w.subs[topic] = nil end,
  }
  -- the typing: typed[key] is a key typed before; type_err refuses the next one
  w.type_once = function(codename, key, text)
    if w.typed[key] then return true end
    if w.type_err then return false, w.type_err end
    w.types[#w.types + 1] = { codename = codename, key = key, text = text }
    w.typed[key] = true
    return true
  end
  w.tick = function()
    local due = w.timers
    w.timers = {}
    for _, fn in ipairs(due) do fn() end
  end
  w.of = function(method)
    local out = {}
    for _, c in ipairs(w.calls) do if c.method == method then out[#out + 1] = c end end
    return out
  end
  w.answer["crew.claim"] = { epoch = 5 }
  w.answer["crew.renew"] = {}
  w.answer["crew.release"] = {}
  w.answer["mail.fallback_done"] = {}
  w.answer["mail.fallbacks"] = function()
    local jobs = w.jobs or {}
    w.jobs = nil
    return { jobs = jobs }
  end
  assert(crew.setup({
    session = w.session, events = w.events, env = { AUTOVIM_PROJECT = "alpha" }, project_key = "k1", proc = "",
    notify = function(msg) w.notices[#w.notices + 1] = msg end,
    after = function(_, fn) w.timers[#w.timers + 1] = fn end,
    wait = function(_, cond) return cond() end,
    type_once = w.type_once,
  }))
  return w
end

local function job(id, tries)
  return { id = id, lease = "lease-" .. id, tries = tries or 0, codename = "gold", from = "jarvis",
    message = { subject = "a subject", body = "hello gold" },
    text = "Mail from jarvis (by your host: the crew couldn't deliver it). Answer with autodoc mail send jarvis.\na subject\nhello gold" }
end

local function done_of(w, id)
  for _, c in ipairs(w.of("mail.fallback_done")) do
    if c.params[4] == id then return c.params end
  end
  return nil
end

-- ── cells ───────────────────────────────────────────────────────────────────

do
  local w = new_world({ protocol = 41 })
  ok("[1] a daemon before 42 is never asked for jobs", #w.of("mail.fallbacks") == 0, vim.inspect(w.calls))
end

do
  local w = new_world()
  local asks = w.of("mail.fallbacks")
  local p = asks[1] and asks[1].params or {}
  ok("[2] asked once the scope is held: scope, run, epoch, the wait",
    #asks == 1 and p[1] == "autovim:alpha" and type(p[2]) == "string" and #p[2] > 0 and p[3] == 5 and p[4] == crew.FALLBACK_WAIT_MS,
    vim.inspect(asks))
end

do
  local w = new_world()
  w.jobs = { job("j1") }
  w.tick() -- the next ask brings the job
  local t = w.types[1]
  ok("[3] typed once into the codename's terminal, keyed by its id, the daemon's text as it is",
    #w.types == 1 and t.codename == "gold" and t.key == "j1" and t.text == job("j1").text, vim.inspect(w.types))
  local d = done_of(w, "j1")
  ok("[3] reported delivered under its lease, scope, run and epoch",
    d ~= nil and d[1] == "autovim:alpha" and d[3] == 5 and d[5] == "lease-j1" and d[6] == "delivered", vim.inspect(d))
  local told = false
  for _, n in ipairs(w.notices) do
    if n:find("gold", 1, true) and n:find("jarvis was typed", 1, true) then told = true end
  end
  ok("[3] the user is told", told, vim.inspect(w.notices))
  local before = #w.of("mail.fallbacks")
  w.tick()
  ok("[3] the next ask is re-armed off the answer", #w.of("mail.fallbacks") == before + 1)
end

do
  local w = new_world()
  w.typed.j2 = true -- an earlier run typed it, and its report was lost
  w.jobs = { job("j2", 1) }
  w.tick()
  local d = done_of(w, "j2")
  ok("[4] a job typed before is reported delivered, never typed twice",
    #w.types == 0 and d ~= nil and d[6] == "delivered", vim.inspect({ w.types, d }))
end

do
  local w = new_world()
  w.type_err = "no slot runs gold"
  w.jobs = { job("j3") }
  w.tick()
  local d = done_of(w, "j3")
  local given = false
  for _, n in ipairs(w.notices) do
    if n:find("hello gold", 1, true) and n:find("no slot runs gold", 1, true) then given = true end
  end
  ok("[5] a job that can't be typed is reported unknown, the user given its text",
    d ~= nil and d[6] == "unknown" and given, vim.inspect({ d, w.notices }))
end

-- after a failure answer, how many more asks the next ticks make (the renewals keep ticking)
local function asks_after(w, failure)
  w.answer["mail.fallbacks"] = function() return nil, failure end
  w.tick() -- the pending re-ask, answered with the failure
  local n = #w.of("mail.fallbacks")
  for _ = 1, 3 do w.tick() end
  return #w.of("mail.fallbacks") - n, n
end

do
  local more, n = asks_after(new_world(), { code = crew.CODE_METHOD_NOT_FOUND, message = "unknown method" })
  ok("[6] a daemon without the verb ends the asking", n == 2 and more == 0, vim.inspect({ n = n, more = more }))
  more, n = asks_after(new_world(), { code = crew.CODE_STALE_EPOCH, message = "stale epoch" })
  ok("[6] a lost epoch ends the asking (the next claim starts it again)", n == 2 and more == 0, vim.inspect({ n = n, more = more }))
  more, n = asks_after(new_world(), { code = -32000, message = "store busy" })
  ok("[6] any other failure asks again", n == 2 and more >= 1, vim.inspect({ n = n, more = more }))
end

crew.stop()
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
