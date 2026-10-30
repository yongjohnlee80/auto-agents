--- Tests for auto-agents.crew's sessions: each agent registered under the scope before it starts
--- (ADR 1793271500 §4.4, §4.5, crew epic phase 4d). Run with:
---   nvim --headless -u NONE -l tests/crew_sessions_spec.lua
---
--- A fake autodoc.session answers as the test says; `wait` is the spawn's bounded wait, and runs
--- the test's on_wait (a deferred reply, a lost connection) before it reads its condition.
---   [1] crew's kind for an auto-agents kind
---   [2] the context file: 0600, the whole context, by its session's name; removing it removes
---       that file alone
---   [3] no scope held, no connection or no workspace served: no registration, the agent starts as
---       before; the workspaces are listed first when they were not yet
---   [4] a registration sends the scope, run token, epoch, codename, kind, workspace id, instance
---       and a 32-byte secret, then writes the context whose credential is <session>.<secret>
---   [5] a refused registration starts nothing and is never replayed; a lost one is replayed as it
---       was by the codename's next start; one whose kind changed is ended first
---   [6] an answer after the wait gave up is ended (start_failed) and leaves no context
---   [7] a scope, epoch or connection that changed during the wait ends the session it registered
---   [8] finish removes the context and sends crew.exit once; an unanswered exit is asked again at
---       the next renewal until it settles, a refused one is settled
---   [9] a lost registration nobody starts is replayed and ended at the next renewal
---  [10] a claim at another epoch drops the old sessions' contexts; release removes every context
---  [11] a context that can't be written ends its session

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
  local w = { calls = {}, notices = {}, timers = {}, subs = {}, answer = {}, pending = {}, deferred = {},
    workspaces = opts.workspaces or { kb = { name = "kb", root = "/proj", id = 7 } }, listed = opts.listed ~= false }
  local function new_client(addr)
    return {
      can = function() return true end,
      hello = function() return { store_id = "store-1" } end,
      addr = function() return addr end,
    }
  end
  w.client = new_client("/run/autodoc.sock")
  w.reconnect = function() w.client = new_client("/run/autodoc-2.sock") end
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
  w.session = {
    is_ready = function() return true end,
    client = function() return w.client end,
    call = function(method, params, cb)
      w.calls[#w.calls + 1] = { method = method, params = vim.deepcopy(params) }
      if w.deferred[method] then
        w.pending[#w.pending + 1] = { method = method, params = vim.deepcopy(params), cb = cb }
        return
      end
      local a = w.answer[method]
      local res, err
      if type(a) == "function" then res, err = a(params) else res, err = a, nil end
      cb(res, err)
    end,
    workspace_of = function(path)
      if not w.listed then return nil end
      for name, ws in pairs(w.workspaces) do
        if path == ws.root or vim.startswith(path, ws.root .. "/") then return name end
      end
      return nil
    end,
    primary_workspace = function() return nil end,
    workspace = function(name) return w.listed and w.workspaces[name] or nil end,
    workspaces = function(cb)
      w.calls[#w.calls + 1] = { method = "workspace.list" }
      w.listed = true
      cb({}, nil)
    end,
  }
  w.events = {
    register_topics = function() end,
    publish = function() end,
    subscribe = function(topic, fn) w.subs[topic] = fn; return topic end,
    unsubscribe = function(topic) w.subs[topic] = nil end,
  }
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
  w.answer["crew.exit"] = {}
  w.answer["crew.release"] = {}
  local n = 0
  w.answer["crew.register"] = function()
    n = n + 1
    return { session = "s" .. n, profile = "p1" }
  end
  assert(crew.setup({
    session = w.session, events = w.events, env = { AUTOVIM_PROJECT = "alpha" }, project_key = "k1", proc = "",
    notify = function(msg) w.notices[#w.notices + 1] = msg end,
    after = function(_, fn) w.timers[#w.timers + 1] = fn end,
    wait = function(_, cond)
      if w.on_wait then
        local f = w.on_wait
        w.on_wait = nil
        f()
      end
      return cond()
    end,
  }))
  if opts.claim ~= false then w.subs["autodoc.session:connected"]({}) end
  return w
end

local function tmpcwd()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function ctx_files(cwd)
  local dir = vim.fs.joinpath(crew.context_folder(cwd), crew.CONTEXT_DIR)
  local out = {}
  for name in vim.fs.dir(dir) do out[#out + 1] = name end
  table.sort(out)
  return out
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return vim.json.decode(s)
end

-- ── [1] kinds ───────────────────────────────────────────────────────────────

ok("[1] antigravity is crew's agy", crew.crew_kind("antigravity") == "agy")
ok("[1] claude, codex and opencode keep their names",
  crew.crew_kind("claude") == "claude" and crew.crew_kind("codex") == "codex" and crew.crew_kind("opencode") == "opencode")
ok("[1] no kind is generic", crew.crew_kind(nil) == "generic" and crew.crew_kind("") == "generic")

-- ── [2] the context file ────────────────────────────────────────────────────

do
  local folder = vim.fn.tempname()
  local c = { store = "st", socket = "/s", scope = "autovim:alpha", profile = "p", session = "abc", credential = "abc.sec",
    kind = "claude" }
  local path, err = crew.write_context(folder, c)
  ok("[2] the context is written at <folder>/.autodoc-crew/<session>",
    path == vim.fs.joinpath(folder, ".autodoc-crew", "abc"), tostring(path) .. " " .. tostring(err))
  local st = path and vim.uv.fs_stat(path)
  ok("[2] its mode is 0600", st and bit.band(st.mode, tonumber("777", 8)) == tonumber("600", 8),
    st and string.format("%o", st.mode))
  ok("[2] it holds the whole context", vim.deep_equal(read_json(path), c), vim.inspect(read_json(path)))
  local names = {}
  for name in vim.fs.dir(vim.fs.joinpath(folder, ".autodoc-crew")) do names[#names + 1] = name end
  ok("[2] no write-in-progress dot file is left", #names == 1, vim.inspect(names))
  ok("[2] a session id that is no plain file name is refused",
    crew.write_context(folder, vim.tbl_extend("force", c, { session = "../x" })) == nil
      and crew.write_context(folder, vim.tbl_extend("force", c, { session = ".x" })) == nil)
  crew.write_context(folder, vim.tbl_extend("force", c, { session = "other" }))
  crew.remove_context(folder, "abc")
  ok("[2] removing a context removes that file alone",
    vim.uv.fs_stat(path) == nil and vim.uv.fs_stat(vim.fs.joinpath(folder, ".autodoc-crew", "other")) ~= nil)
  crew.remove_context(folder, "abc")
  ok("[2] removing one already gone is nothing", true)
  vim.fn.delete(folder, "rf")
end

-- ── [3] nothing to register under ───────────────────────────────────────────

do
  local w = new_world({ claim = false })
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = "/proj" })
  ok("[3] no scope held: no handle, no reason, no registration", h == nil and why == nil and #w.of("crew.register") == 0)
end

do
  local w = new_world()
  w.client = nil
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = "/proj" })
  ok("[3] no connection: no registration", h == nil and why == nil and #w.of("crew.register") == 0)
end

do
  local w = new_world()
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = "/elsewhere" })
  ok("[3] no workspace serves the folder: no registration", h == nil and why == nil and #w.of("crew.register") == 0)
end

do
  local cwd = tmpcwd()
  local w = new_world({ listed = false, workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[3] the workspaces are listed first when they were not yet, then the agent is registered",
    #w.of("workspace.list") == 1 and h ~= nil and #w.of("crew.register") == 1)
  crew.finish(h, "exit")
  vim.fn.delete(cwd, "rf")
end

-- ── [4] a registration ──────────────────────────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h, why = crew.begin({ codename = "gold", kind = "antigravity", cwd = cwd })
  local reg = w.of("crew.register")[1]
  local p = reg and reg.params or {}
  local claim = w.of("crew.claim")[1].params
  ok("[4] crew.register gets scope, run token, epoch, codename, kind, workspace id, instance and secret",
    p[1] == "autovim:alpha" and p[2] == claim[2] and p[3] == 5 and p[4] == "gold" and p[5] == "agy" and p[6] == "7"
      and type(p[7]) == "string" and p[7] ~= "" and type(p[8]) == "string" and #p[8] == 64, vim.inspect(p))
  local path = h and h.context
  local c = path and read_json(path) or {}
  ok("[4] a handle answers, its env naming the context", h ~= nil and why == nil and h.env.AUTODOC_CREW_CONTEXT == path)
  ok("[4] the context names the daemon, store, scope, profile, session and kind",
    c.store == "store-1" and c.socket == "/run/autodoc.sock" and c.scope == "autovim:alpha" and c.profile == "p1"
      and c.session == "s1" and c.kind == "agy", vim.inspect(c))
  ok("[4] its credential is <session>.<the secret registered>", c.credential == "s1." .. tostring(p[8]))
  ok("[4] the context lives under the workspace's .auto-agents/, never the project's own tree",
    vim.startswith(path or "", vim.fs.joinpath(cwd, ".auto-agents", "crew", ".autodoc-crew") .. "/"))
  crew.finish(h, "exit")
  vim.fn.delete(cwd, "rf")
end

-- ── [5] refused, lost, changed ──────────────────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.answer["crew.register"] = function() return nil, { code = crew.CODE_CODENAME_BUSY, message = "busy" } end
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[5] a refused registration starts no session and says why", h == nil and why == "busy" and #ctx_files(cwd) == 0)
  w.answer["crew.register"] = { session = "s9", profile = "p1" }
  local h2 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local regs = w.of("crew.register")
  ok("[5] after a refusal, the next start registers afresh (another instance and secret)",
    h2 ~= nil and #regs == 2 and regs[1].params[7] ~= regs[2].params[7] and regs[1].params[8] ~= regs[2].params[8])
  crew.finish(h2, "exit")
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.answer["crew.register"] = function() return nil, { message = "connection lost" } end
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[5] a lost answer starts no session", h == nil and why == "connection lost")
  w.answer["crew.register"] = { session = "s4", profile = "p1" }
  local h2 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local regs = w.of("crew.register")
  ok("[5] the codename's next start replays the lost registration exactly",
    h2 ~= nil and #regs == 2 and vim.deep_equal(regs[1].params, regs[2].params), vim.inspect(regs))
  crew.finish(h2, "exit")
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.answer["crew.register"] = function() return nil, { message = "connection lost" } end
  crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.answer["crew.register"] = { session = "s4", profile = "p1" }
  local h, why = crew.begin({ codename = "gold", kind = "codex", cwd = cwd })
  local exits = w.of("crew.exit")
  ok("[5] a lost registration whose kind changed is replayed and ended first, starting nothing now",
    h == nil and why ~= nil and #exits == 1 and exits[1].params[4] == "s4" and exits[1].params[5] == "start_failed",
    vim.inspect(exits))
  local h2 = crew.begin({ codename = "gold", kind = "codex", cwd = cwd })
  ok("[5] then the next start registers the new kind", h2 ~= nil and w.of("crew.register")[3].params[5] == "codex")
  crew.finish(h2, "exit")
  vim.fn.delete(cwd, "rf")
end

-- ── [6] an answer after the wait ────────────────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.deferred["crew.register"] = true
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[6] no answer within the wait: the agent starts without a session", h == nil and why ~= nil)
  w.reply("crew.register", { session = "late", profile = "p1" })
  local exits = w.of("crew.exit")
  ok("[6] the late session is ended, start_failed, and leaves no context",
    #exits == 1 and exits[1].params[4] == "late" and exits[1].params[5] == "start_failed" and #ctx_files(cwd) == 0,
    vim.inspect(exits))
  vim.fn.delete(cwd, "rf")
end

-- ── [7] the scope changed during the wait ───────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.deferred["crew.register"] = true
  w.on_wait = function()
    w.reconnect()
    w.reply("crew.register", { session = "s1", profile = "p1" })
  end
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local exits = w.of("crew.exit")
  ok("[7] a connection that changed during the wait ends the session, and writes no context",
    h == nil and why ~= nil and #exits == 1 and exits[1].params[5] == "start_failed" and #ctx_files(cwd) == 0,
    vim.inspect(exits))
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.deferred["crew.register"] = true
  w.on_wait = function()
    crew.release()
    w.reply("crew.register", { session = "s1", profile = "p1" })
  end
  local h = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[7] a scope released during the wait starts no session and writes no context", h == nil and #ctx_files(cwd) == 0)
  vim.fn.delete(cwd, "rf")
end

-- ── [8] finish ──────────────────────────────────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local run = w.of("crew.claim")[1].params[2]
  w.answer["crew.exit"] = function() return nil, { message = "connection lost" } end
  crew.finish(h, "exit")
  local exits = w.of("crew.exit")
  ok("[8] finish removes the context at once and sends crew.exit(scope, run, epoch, session, why)",
    #ctx_files(cwd) == 0 and #exits == 1 and vim.deep_equal(exits[1].params, { "autovim:alpha", run, 5, "s1", "exit" }),
    vim.inspect(exits))
  crew.finish(h, "exit")
  ok("[8] a second finish is nothing", #w.of("crew.exit") == 1)
  w.answer["crew.exit"] = {}
  w.tick() -- the renewal answers: the exit still owed is asked again
  ok("[8] an unanswered exit is asked again at the next renewal", #w.of("crew.exit") == 2)
  w.tick()
  ok("[8] once answered, it is settled", #w.of("crew.exit") == 2)
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.answer["crew.exit"] = function() return nil, { code = crew.CODE_BAD_CREDENTIAL, message = "ended" } end
  crew.finish(h, "exit")
  w.tick()
  ok("[8] a refused exit (the session ended already) is settled, never asked again", #w.of("crew.exit") == 1)
  vim.fn.delete(cwd, "rf")
end

-- ── [9] a lost registration nobody starts ───────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.answer["crew.register"] = function() return nil, { message = "connection lost" } end
  crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.answer["crew.register"] = { session = "s7", profile = "p1" }
  w.tick()
  local regs, exits = w.of("crew.register"), w.of("crew.exit")
  ok("[9] the next renewal replays it as it was and ends the session it finds",
    #regs == 2 and vim.deep_equal(regs[1].params, regs[2].params) and #exits == 1 and exits[1].params[4] == "s7"
      and exits[1].params[5] == "start_failed", vim.inspect(exits))
  w.tick()
  ok("[9] then nothing is owed", #w.of("crew.register") == 2 and #w.of("crew.exit") == 1)
  vim.fn.delete(cwd, "rf")
end

-- ── [10] another epoch, release ─────────────────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.answer["crew.renew"] = function() return nil, { code = crew.CODE_STALE_EPOCH, message = "stale" } end
  w.answer["crew.claim"] = { epoch = 6 }
  w.tick()
  ok("[10] a claim at another epoch drops the old sessions' contexts", h ~= nil and #ctx_files(cwd) == 0)
  crew.finish(h, "exit")
  ok("[10] finishing a session the epoch change ended sends no exit", #w.of("crew.exit") == 0)
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  crew.begin({ codename = "vision", kind = "codex", cwd = cwd })
  ok("[10] two agents in one folder have a context each", #ctx_files(cwd) == 2)
  crew.release()
  ok("[10] release removes every context", #ctx_files(cwd) == 0 and #w.of("crew.release") == 1)
  vim.fn.delete(cwd, "rf")
end

-- ── [11] a context that can't be written ────────────────────────────────────

do
  local cwd = tmpcwd()
  vim.fn.writefile({}, vim.fs.joinpath(cwd, ".auto-agents")) -- a file where the folder would go
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local exits = w.of("crew.exit")
  ok("[11] its session is ended, start_failed, and the agent starts without one",
    h == nil and why ~= nil and #exits == 1 and exits[1].params[5] == "start_failed", vim.inspect({ why, exits }))
  vim.fn.delete(cwd, "rf")
end

crew.stop()
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
