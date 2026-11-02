--- Tests for auto-agents.crew's sessions: each agent registered under the scope before it starts
--- (ADR 1793271500 §4.4, §4.5, crew epic phase 4d). Run with:
---   nvim --headless -u NONE -l tests/crew_sessions_spec.lua
---
--- A fake autodoc.session answers as the test says; `wait` is the spawn's bounded wait, and runs
--- the test's on_wait (a deferred reply, a lost connection) before it reads its condition.
---   [1] crew's kind for an auto-agents kind
---   [2] the context file: 0600, the whole context, by its session's name; removing it removes
---       that file alone
---   [3] no scope held or no connection: no registration, the agent starts as before; no workspace
---       served: registered with none (NO_WORKSPACE); the workspaces are listed first when they
---       were not yet
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
---  [12] Claude starts with --settings carrying the SessionStart endpoint hook, the five hooks that
---       report its permission prompts (each always exiting 0) and
---       crossSessionInbound accept, nothing else; the other kinds with nothing added
---  [4b] prompts (the setup reports the session's permission prompts) is crew.register's 9th
---       parameter, sent only when true and only to a daemon of protocol 41 or later
---  [12c] AutoDoc's setup (`autodoc crew setup`): its argv carries no value of the agent's
---       environment, which is its process environment; its answer is parsed and kept; a failure
---       is not kept; an autodoc without the command is told apart (older); after steps get the start
---  [12b] OpenCode starts with the OPENCODE_CONFIG_CONTENT that loads AutoDoc's plugin, as the
---       binary prints it, merged by the binary with the agent's own value; a binary that fails,
---       answers no such line, or is missing gives none, with why; the other kinds get nothing;
---       an answer is kept per binary (path, size, mtime) and agent value, a failure never
---  [13] a restart: the codename's previous session, still counted live, is ended before the new
---       registration, and its exit is waited for within the spawn's wait (Juliet #4 r0 F1)
---  [14] an answer after release, or after a claim at another epoch, counts nothing and owes no
---       exit (Juliet #4 r0 F2)
---  [15] the spawn's terminal: a constructor or a start that throws, or no buffer, ends the
---       registered session start_failed once and raises the error as it was (Lector #4 r1 F3)
---  [19] mail_via (protocol 43): the setup asks for the crew MCP server (`--mail-via mcp`) only when
---       told to, keeps the answer's mail_via, and is kept per mode; mail_via_offered only from a 43
---       daemon holding the scope; crew.register's 10th parameter is the answered mail_via, sent
---       only to a 43 daemon, with prompts (the 9th) sent whatever it is
---  [20] the agent's own folder: the setup is asked with --agent-dir and kept per folder; its
---       server, socket and folder files are kept; agent_folder is <root>/<scope>/<codename>, 0700,
---       only with a scope held and a plain codename; write_folder_files writes 0600 inside the
---       folder and refuses a path out of it
---  [18] the crew guide for the instruction block: none while no scope is held or the daemon lacks
---       crew.guide; asked by crew's kind and cached per store, daemon version and kind; an answer
---       that fails or doesn't come within the wait is none, not cached, and asked again

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
      hello = function() return { store_id = w.store, version = w.version, protocol = w.protocol } end,
      addr = function() return addr end,
    }
  end
  w.store = "store-1"
  w.protocol = opts.protocol or 41
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
    is_ready = function() return opts.claim ~= false end,
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
  local cwd = tmpcwd() -- no workspace serves it: the world's one is /proj
  local w = new_world()
  local h, why = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local reg = w.of("crew.register")[1]
  local p = reg and reg.params or {}
  ok("[3] no workspace serves the folder: registered with none, so its mail still reaches it",
    h ~= nil and why == nil and #w.of("crew.register") == 1 and p[6] == crew.NO_WORKSPACE and p[6] == ""
      and p[4] == "gold", vim.inspect(p))
  crew.finish(h, "exit")
  vim.fn.delete(cwd, "rf")
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

-- ── [12] Claude's wake acceptance ───────────────────────────────────────────

do
  local argv = crew.wake_argv("claude", "/opt/auto doc/bin/autodoc")
  local settings = argv[2] and vim.json.decode(argv[2]) or {}
  local hook = (((settings.hooks or {}).SessionStart or {})[1] or {}).hooks or {}
  ok("[12] Claude starts with --settings carrying the SessionStart endpoint hook",
    argv[1] == "--settings" and #argv == 2 and #hook == 1 and hook[1].type == "command"
      and hook[1].command == "'/opt/auto doc/bin/autodoc' crew endpoint --claude >/dev/null", vim.inspect(argv))
  ok("[12] and crossSessionInbound accept, and nothing else: no permissions or rules",
    settings.crossSessionInbound == "accept" and vim.tbl_count(settings) == 2, vim.inspect(settings))
  local want = "'/opt/auto doc/bin/autodoc' crew attention --claude-hook >/dev/null || true"
  local reported = 0
  for _, event in ipairs({ "PermissionRequest", "Notification", "PostToolUse", "UserPromptSubmit", "Stop" }) do
    local h = ((((settings.hooks or {})[event] or {})[1] or {}).hooks or {})
    if #h == 1 and h[1].type == "command" and h[1].command == want and #settings.hooks[event] == 1 then
      reported = reported + 1
    end
  end
  ok("[12] and the five hooks that report its permission prompts, each one command that always exits 0",
    reported == 5 and vim.tbl_count(settings.hooks) == 6, vim.inspect(settings.hooks))
  ok("[12] the other kinds start with nothing added",
    #crew.wake_argv("codex", "/bin/autodoc") == 0 and #crew.wake_argv("agy", "/bin/autodoc") == 0)
  ok("[12] no autodoc binary: nothing added", #crew.wake_argv("claude", nil) == 0)
end

do
  crew._reset_plugin_env()
  local calls = {}
  local function runner(code, out, err)
    return function(argv, env, ms)
      calls[#calls + 1] = { argv = argv, env = env, ms = ms }
      return code, out, err
    end
  end
  local env, why = crew.wake_env("opencode", "/opt/auto doc/bin/autodoc", nil,
    runner(0, 'OPENCODE_CONFIG_CONTENT={"plugin":["/d/autodoc-crew.js"]}\n'))
  ok("[12b] OpenCode gets the OPENCODE_CONFIG_CONTENT the binary prints, asked once with its argv",
    why == nil and env and env.OPENCODE_CONFIG_CONTENT == '{"plugin":["/d/autodoc-crew.js"]}' and vim.tbl_count(env) == 1
      and #calls == 1 and vim.deep_equal(calls[1].argv, { "/opt/auto doc/bin/autodoc", "crew", "plugin", "--opencode", "--print-env" })
      and vim.tbl_count(calls[1].env) == 0 and calls[1].ms == crew.PLUGIN_ENV_WAIT_MS, vim.inspect({ env, why, calls }))
  calls = {}
  crew.wake_env("opencode", "/bin/autodoc", '{"model":"x/y"}', runner(0, 'OPENCODE_CONFIG_CONTENT={"model":"x/y","plugin":["p"]}'))
  ok("[12b] the agent's own OPENCODE_CONFIG_CONTENT goes to the binary, which merges it",
    #calls == 1 and calls[1].env.OPENCODE_CONFIG_CONTENT == '{"model":"x/y"}', vim.inspect(calls))
  local e1, w1 = crew.wake_env("opencode", "/bin/autodoc", nil, runner(2, "", "unknown command crew plugin"))
  local e2, w2 = crew.wake_env("opencode", "/bin/autodoc", nil, runner(0, "/d/autodoc-crew.js\n"))
  local e3, w3 = crew.wake_env("opencode", "/bin/autodoc", nil, runner(0, "OPENCODE_CONFIG_CONTENT={}\nmore\n"))
  local e4, w4 = crew.wake_env("opencode", "/bin/autodoc", nil, function() error("spawn failed") end)
  local e5, w5 = crew.wake_env("opencode", nil, nil, runner(0, "OPENCODE_CONFIG_CONTENT={}"))
  ok("[12b] a failing binary, another answer, two lines, a throw or no binary: none, with why",
    e1 == nil and w1:find("exit 2", 1, true) and w1:find("unknown command", 1, true)
      and e2 == nil and w2 ~= nil and e3 == nil and w3 ~= nil and e4 == nil and w4:find("spawn failed", 1, true)
      and e5 == nil and w5 == "no autodoc binary", vim.inspect({ w1, w2, w3, w4, w5 }))
  calls = {}
  local ec = crew.wake_env("claude", "/bin/autodoc", nil, runner(0, "OPENCODE_CONFIG_CONTENT={}"))
  local ex = crew.wake_env("codex", "/bin/autodoc", nil, runner(0, "OPENCODE_CONFIG_CONTENT={}"))
  ok("[12b] the other kinds get nothing, and nothing is run", vim.tbl_count(ec) == 0 and vim.tbl_count(ex) == 0 and #calls == 0)

  -- kept: a binary's later spawns don't wait on it again (Jarvis #15 r0)
  crew._reset_plugin_env()
  local bin = vim.fn.tempname()
  vim.fn.writefile({ "#!/bin/sh" }, bin)
  calls = {}
  local good = runner(0, "OPENCODE_CONFIG_CONTENT={\"plugin\":[\"p\"]}")
  local a1 = crew.wake_env("opencode", bin, nil, good)
  a1.OPENCODE_CONFIG_CONTENT = "changed by the caller"
  local a2 = crew.wake_env("opencode", bin, nil, good)
  ok("[12b] a second spawn with the same binary and value is answered from the session's copy, unchanged by a caller",
    #calls == 1 and a2 and a2.OPENCODE_CONFIG_CONTENT == '{"plugin":["p"]}', vim.inspect({ calls, a2 }))
  crew.wake_env("opencode", bin, '{"model":"x/y"}', good)
  ok("[12b] another agent value is asked again", #calls == 2, vim.inspect(calls))
  vim.uv.fs_utime(bin, 1000, 1000)
  crew.wake_env("opencode", bin, nil, good)
  ok("[12b] a changed binary (its mtime) is asked again", #calls == 3, vim.inspect(calls))
  calls = {}
  local bad = runner(1, "", "boom")
  local f1 = crew.wake_env("opencode", bin .. "-other", nil, bad)
  local f2, fw = crew.wake_env("opencode", bin .. "-other", nil, good)
  ok("[12b] a failure is not kept: the next spawn asks again, and its answer counts",
    f1 == nil and #calls == 2 and fw == nil and f2 and f2.OPENCODE_CONFIG_CONTENT == '{"plugin":["p"]}', vim.inspect({ calls, f2 }))
  vim.fn.delete(bin)
  crew._reset_plugin_env()
end

-- ── [4b] prompts at registration ────────────────────────────────────────────

do
  for _, c in ipairs({ { protocol = 41, prompts = true, want = 9 }, { protocol = 41, prompts = false, want = 8 },
    { protocol = 40, prompts = true, want = 8 } }) do
    local cwd = tmpcwd()
    local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } }, protocol = c.protocol })
    crew.begin({ codename = "gold", kind = "claude", cwd = cwd, prompts = c.prompts })
    local reg = w.of("crew.register")[1]
    ok(("[4b] prompts=%s to a protocol %d daemon: %d register params"):format(tostring(c.prompts), c.protocol, c.want),
      reg and #reg.params == c.want and (c.want == 8 or reg.params[9] == true), vim.inspect(reg and reg.params))
    crew.release()
    vim.fn.delete(cwd, "rf")
  end
end

-- ── [12c] AutoDoc's setup ───────────────────────────────────────────────────

do
  crew._reset_setups()
  local calls = {}
  local function runner(code, out, err)
    return function(argv, env, ms)
      calls[#calls + 1] = { argv = argv, env = env, ms = ms }
      return code, out, err
    end
  end
  local answer = vim.json.encode({ argv = { "--settings", "{}" }, env = { X = "y" }, files = {}, prompts = true,
    notices = { "n1" }, after = { { "crew", "endpoint", "--codex-here", "--since", "{since}", "--wait", "60s" } } })
  local env = { CLAUDE_CONFIG_DIR = "/accounts/work/.claude", PATH = "/p/bin" }
  local s, why = crew.agent_setup("claude", "/opt/autodoc", "claude", env, runner(0, answer))
  ok("[12c] the setup runs `crew setup` for the kind, host nvim, the program and the autodoc",
    #calls == 1 and vim.deep_equal(calls[1].argv, { "/opt/autodoc", "crew", "setup", "--kind", "claude", "--host", "nvim",
      "--program", "claude", "--autodoc", "/opt/autodoc" }) and calls[1].ms == crew.SETUP_WAIT_MS, vim.inspect(calls))
  ok("[12c] the agent's environment is the command's process environment, and none of it is in argv",
    calls[1].env == env and not table.concat(calls[1].argv, " "):find("/accounts/work", 1, true)
      and not table.concat(calls[1].argv, " "):find("/p/bin", 1, true), vim.inspect(calls[1]))
  ok("[12c] its answer is parsed", why == nil and s and s.prompts == true and s.argv[1] == "--settings" and s.env.X == "y"
    and s.notices[1] == "n1", vim.inspect(s))
  s.argv[1] = "changed by the caller"
  local again = crew.agent_setup("claude", "/opt/autodoc", "claude", env, runner(0, answer))
  ok("[12c] kept: a second spawn with the same binary, program and env asks nothing, its copy unchanged",
    #calls == 1 and again.argv[1] == "--settings", vim.inspect(calls))
  crew.agent_setup("claude", "/opt/autodoc", "claude", { PATH = "/other/bin" }, runner(0, answer))
  ok("[12c] another PATH is asked again", #calls == 2)
  local steps = crew.after_argv(again, "/opt/autodoc", 1234)
  ok("[12c] an after step is run by the autodoc, the start given as {since}",
    vim.deep_equal(steps, { { "/opt/autodoc", "crew", "endpoint", "--codex-here", "--since", "1234", "--wait", "60s" } }),
    vim.inspect(steps))
  calls = {}
  local n1, w1, o1 = crew.agent_setup("opencode", "/opt/autodoc", "opencode", {}, runner(2, "", 'autodoc: no command "crew setup"'))
  local n2, w2, o2 = crew.agent_setup("opencode", "/opt/autodoc", "opencode", {}, runner(1, "", "boom"))
  local n3, w3 = crew.agent_setup("opencode", "/opt/autodoc", "opencode", {}, runner(0, "not json"))
  local n4, _, o4 = crew.agent_setup("opencode", nil, "opencode", {}, runner(0, answer))
  ok("[12c] an autodoc without crew setup is older; a failure, an answer that is no setup, or no binary is none",
    n1 == nil and o1 == true and w1 ~= nil and n2 == nil and o2 == false and w2:find("boom", 1, true) and n3 == nil
      and w3 ~= nil and n4 == nil and o4 == false and #calls == 3, vim.inspect({ w1, w2, w3, calls }))
  crew.agent_setup("opencode", "/opt/autodoc", "opencode", {}, runner(0, answer))
  ok("[12c] a failure is not kept: the next spawn asks again", #calls == 4)
  crew._reset_setups()
end

-- ── [13] a restart (Juliet #4 r0 F1) ────────────────────────────────────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h1 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local h2 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd }) -- h1's exit not yet reaped
  local order = {}
  for i, c in ipairs(w.calls) do
    if c.method == "crew.exit" or c.method == "crew.register" then order[#order + 1] = c.method .. ":" .. i end
  end
  local exits = w.of("crew.exit")
  ok("[13] the previous session is ended (exit) before the codename registers again",
    h1 and h2 and #exits == 1 and exits[1].params[4] == "s1" and exits[1].params[5] == "exit"
      and order[2]:match("^crew.exit") ~= nil and order[3]:match("^crew.register") ~= nil, vim.inspect(order))
  crew.finish(h1, "exit")
  ok("[13] the old handle's own finish then sends nothing more", #w.of("crew.exit") == 1)
  crew.finish(h2, "exit")
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h1 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.deferred["crew.exit"] = true
  crew.finish(h1, "exit") -- the kill: its exit in flight
  local registered_before
  w.on_wait = function()
    registered_before = #w.of("crew.register")
    w.reply("crew.exit", {})
  end
  local h2 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[13] a start waits for the codename's exit in flight, then registers",
    registered_before == 1 and h2 ~= nil and #w.of("crew.register") == 2)
  crew.finish(h2, "exit")
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  local h1 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.deferred["crew.exit"] = true
  crew.finish(h1, "exit")
  local h2 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  ok("[13] an exit still unconfirmed when the wait ends: the registration goes ahead",
    h2 ~= nil and #w.of("crew.register") == 2)
  vim.fn.delete(cwd, "rf")
end

-- ── [14] answers after release or another epoch (Juliet #4 r0 F2) ───────────

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.deferred["crew.register"] = true
  crew.begin({ codename = "gold", kind = "claude", cwd = cwd }) -- gives up waiting
  crew.release()
  w.reply("crew.register", { session = "late", profile = "p1" })
  ok("[14] an answer after release owes no exit and writes no context", #w.of("crew.exit") == 0 and #ctx_files(cwd) == 0)
  vim.fn.delete(cwd, "rf")
end

do
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })
  w.deferred["crew.register"] = true
  crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  w.answer["crew.renew"] = function() return nil, { code = crew.CODE_STALE_EPOCH, message = "stale" } end
  w.answer["crew.claim"] = { epoch = 6 }
  w.tick() -- claimed again at epoch 6, which ended epoch 5's sessions
  w.reply("crew.register", { session = "late", profile = "p1" })
  ok("[14] an answer from an earlier epoch owes no exit", #w.of("crew.exit") == 0)
  vim.fn.delete(cwd, "rf")
end

-- ── [15] the spawn's terminal (Lector #4 r1 F3) ─────────────────────────────

do
  local aa = require("auto-agents")
  local real_terminal = package.loaded["auto-agents.terminal"]
  local function with_terminal(fake, fn)
    package.loaded["auto-agents.terminal"] = fake
    local ok_, a, b = pcall(fn)
    package.loaded["auto-agents.terminal"] = real_terminal
    return ok_, a, b
  end
  local cwd = tmpcwd()
  local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } } })

  local h = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local okc, err = with_terminal({ new = function() error("terminal provider 'snacks': module not found", 0) end },
    function() return aa._start_terminal({}, {}, nil, h) end)
  local exits = w.of("crew.exit")
  ok("[15] a constructor that throws ends the session start_failed, and its error is raised as it was",
    okc == false and err == "terminal provider 'snacks': module not found" and #exits == 1
      and exits[1].params[5] == "start_failed" and #ctx_files(cwd) == 0, vim.inspect({ okc, err, exits }))

  local h2 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local oks, term, buf = with_terminal({ new = function() return { start = function() return nil end } end },
    function() return aa._start_terminal({}, {}, nil, h2) end)
  ok("[15] a start that answers no buffer ends it start_failed once, and answers nothing",
    oks and term == nil and buf == nil and #w.of("crew.exit") == 2 and w.of("crew.exit")[2].params[5] == "start_failed")
  crew.finish(h2, "exit")
  ok("[15] the exit's own finish afterwards sends nothing more", #w.of("crew.exit") == 2)

  local h3 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local okt, terr = with_terminal({ new = function() return { start = function() error("termopen failed", 0) end } end },
    function() return aa._start_terminal({}, {}, nil, h3) end)
  ok("[15] a start that throws ends it start_failed and raises its error",
    okt == false and terr == "termopen failed" and #w.of("crew.exit") == 3)

  local h4 = crew.begin({ codename = "gold", kind = "claude", cwd = cwd })
  local okg, term4, buf4 = with_terminal({ new = function() return { start = function() return 42 end } end },
    function() return aa._start_terminal({}, {}, nil, h4) end)
  ok("[15] a terminal that starts keeps its session", okg and term4 ~= nil and buf4 == 42 and #w.of("crew.exit") == 3)
  crew.finish(h4, "exit")
  vim.fn.delete(cwd, "rf")
end

-- ── [18] the crew guide ─────────────────────────────────────────────────────

do
  local w = new_world({ claim = false })
  ok("[18] no scope held: no guide, and nothing asked", crew.guide("claude") == nil and #w.of("crew.guide") == 0)
end

do
  local w = new_world()
  w.answer["crew.guide"] = function(p) return { markdown = "guide for " .. p[1], protocol = 41 } end
  local g = crew.guide("antigravity")
  ok("[18] the daemon's markdown, asked by crew's kind", g == "guide for agy" and w.of("crew.guide")[1].params[1] == "agy",
    tostring(g))
  crew.guide("antigravity")
  ok("[18] asked once per store, build and kind", #w.of("crew.guide") == 1)
  crew.guide("claude")
  ok("[18] another kind is asked", #w.of("crew.guide") == 2)
  w.version = "v2"
  crew.guide("antigravity")
  ok("[18] another daemon build is asked again", #w.of("crew.guide") == 3)
  w.store = "store-2"
  crew.guide("antigravity")
  ok("[18] another store is asked again", #w.of("crew.guide") == 4)
end

do
  local w = new_world()
  w.deferred["crew.guide"] = true
  ok("[18] no answer within the wait: no guide", crew.guide("claude") == nil)
  w.reply("crew.guide", { markdown = "late" }) -- answered after the wait gave up
  w.deferred["crew.guide"] = nil
  w.answer["crew.guide"] = { markdown = "now" }
  ok("[18] nothing cached: asked again, and the late answer is not the guide",
    crew.guide("claude") == "now" and #w.of("crew.guide") == 2)
end

do
  local w = new_world()
  w.answer["crew.guide"] = function() return nil, { code = -32603, message = "busy" } end
  ok("[18] a failed answer: no guide", crew.guide("claude") == nil)
  w.answer["crew.guide"] = { markdown = "ok" }
  ok("[18] a failure isn't cached: asked again", crew.guide("claude") == "ok" and #w.of("crew.guide") == 2)
end

do
  local w = new_world()
  w.client.can = function(_, m) return m ~= "crew.guide" end
  ok("[18] a daemon without crew.guide is not asked", crew.guide("claude") == nil and #w.of("crew.guide") == 0)
end

-- ── [19] mail_via ──────────────────────────────────────────────────────────

do
  crew._reset_setups()
  local calls = {}
  local function runner(answer)
    return function(argv, env, ms)
      calls[#calls + 1] = { argv = argv }
      return 0, vim.json.encode(answer), ""
    end
  end
  local s = crew.agent_setup("claude", "/opt/autodoc", "claude", {}, runner({ argv = {}, mail_via = "mcp" }), "mcp")
  local argv = calls[1] and calls[1].argv or {}
  ok("[19] asked for MCP: the setup runs with --mail-via mcp, its mail_via kept",
    argv[#argv - 1] == "--mail-via" and argv[#argv] == "mcp" and s and s.mail_via == "mcp", vim.inspect({ argv, s }))
  local s2 = crew.agent_setup("claude", "/opt/autodoc", "claude", {}, runner({ argv = {}, mail_via = "cli" }))
  ok("[19] not asked: no --mail-via, and the CLI mode is its own kept answer",
    #calls == 2 and not vim.tbl_contains(calls[2].argv, "--mail-via") and s2 and s2.mail_via == "cli", vim.inspect({ calls, s2 }))
  local s3 = crew.agent_setup("claude", "/opt/autodoc", "claude", {}, runner({ argv = {}, mail_via = "bogus" }), "cli")
  ok("[19] a mode the daemon doesn't name is none", s3 and s3.mail_via == nil, vim.inspect(s3))
  crew._reset_setups()
end

do
  for _, c in ipairs({ { protocol = 42, want = false }, { protocol = 43, want = true } }) do
    local w = new_world({ protocol = c.protocol })
    ok(("[19] mail_via_offered from a protocol %d daemon: %s"):format(c.protocol, tostring(c.want)), crew.mail_via_offered() == c.want)
    crew.release()
    local _ = w
  end
end

do
  for _, c in ipairs({
    { protocol = 43, prompts = false, mail_via = "mcp", want = { n = 10, p9 = false, p10 = "mcp" } },
    { protocol = 43, prompts = true, mail_via = "cli", want = { n = 10, p9 = true, p10 = "cli" } },
    { protocol = 42, prompts = true, mail_via = "mcp", want = { n = 9, p9 = true } },
    { protocol = 43, prompts = false, mail_via = nil, want = { n = 8 } },
  }) do
    local cwd = tmpcwd()
    local w = new_world({ workspaces = { kb = { name = "kb", root = cwd, id = 7 } }, protocol = c.protocol })
    crew.begin({ codename = "gold", kind = "claude", cwd = cwd, prompts = c.prompts, mail_via = c.mail_via })
    local reg = w.of("crew.register")[1]
    local p = reg and reg.params or {}
    ok(("[19] mail_via=%s prompts=%s to a protocol %d daemon: %d register params"):format(tostring(c.mail_via), tostring(c.prompts),
      c.protocol, c.want.n),
      #p == c.want.n and (c.want.p9 == nil or p[9] == c.want.p9) and (c.want.p10 == nil or p[10] == c.want.p10), vim.inspect(p))
    crew.release()
    vim.fn.delete(cwd, "rf")
  end
end

-- ── [20] the agent's own folder: --agent-dir, its files, its server ─────────

do
  crew._reset_setups()
  local calls = {}
  local function runner(answer)
    return function(argv, env, ms)
      calls[#calls + 1] = { argv = argv }
      return 0, answer, ""
    end
  end
  local answer = vim.json.encode({ argv = { "--remote", "unix:///a/codex.sock" }, env = { AUTODOC_CODEX_SERVER = "/a/codex.sock" },
    files = {}, prompts = false, notices = {}, after = {}, mail_via = "mcp",
    folder_files = { { path = ".agents/mcp_config.json", content = "{}" } },
    server = { "codex", "app-server", "--listen", "unix:///a/codex.sock" }, server_socket = "/a/codex.sock" })
  local s = crew.agent_setup("codex", "/opt/autodoc", "codex", { PATH = "/p" }, runner(answer), "mcp", "/a")
  ok("[20] the setup is asked with the agent's own folder (--agent-dir)",
    #calls == 1 and calls[1].argv[#calls[1].argv - 1] == "--agent-dir" and calls[1].argv[#calls[1].argv] == "/a",
    vim.inspect(calls))
  ok("[20] its server, socket and folder files are kept",
    s and vim.deep_equal(s.server, { "codex", "app-server", "--listen", "unix:///a/codex.sock" })
      and s.server_socket == "/a/codex.sock" and #s.folder_files == 1 and s.folder_files[1].path == ".agents/mcp_config.json",
    vim.inspect(s))
  crew.agent_setup("codex", "/opt/autodoc", "codex", { PATH = "/p" }, runner(answer), "mcp", "/b")
  ok("[20] another agent's folder is asked again (the setup is kept per folder)", #calls == 2)
  crew.agent_setup("codex", "/opt/autodoc", "codex", { PATH = "/p" }, runner(answer), "mcp", "/a")
  ok("[20] the same folder again asks nothing", #calls == 2)

  -- agent_folder: <root>/<scope as a file name>/<codename>, 0700, only with a scope held
  local held, root = crew.held, vim.fn.tempname()
  crew.held = function() return nil, nil end
  local none, nwhy = crew.agent_folder("cx", root)
  ok("[20] no scope held: no folder", none == nil and nwhy ~= nil)
  crew.held = function() return "autodoc:abc/../x", 3 end
  local dir = crew.agent_folder("cx", root)
  local st = dir and vim.uv.fs_stat(dir)
  ok("[20] the folder is the scope's (a file name: no / or ..) and the codename's, made 0700",
    dir == vim.fs.joinpath(root, "autodoc_abc_.._x", "cx") and st and bit.band(st.mode, tonumber("777", 8)) == tonumber("700", 8),
    vim.inspect({ dir, st and st.mode }))
  ok("[20] a codename that isn't a plain name gets none", crew.agent_folder("../cx", root) == nil)
  crew.held = held

  -- write_folder_files: inside the folder, 0600; refused for a path out of it
  if dir then
    local why = crew.write_folder_files(dir, { { path = ".agents/mcp_config.json", content = '{"mcpServers":{}}' } })
    local fst = vim.uv.fs_stat(vim.fs.joinpath(dir, ".agents", "mcp_config.json"))
    ok("[20] a setup's file is written in the folder, 0600", why == nil and fst and bit.band(fst.mode, tonumber("777", 8)) == tonumber("600", 8),
      vim.inspect({ why, fst and fst.mode }))
    for _, bad in ipairs({ "/etc/x", "../out", "a/../../out", "" }) do
      ok("[20] a setup file's path " .. vim.inspect(bad) .. " is refused", crew.write_folder_files(dir, { { path = bad, content = "x" } }) ~= nil)
    end
    ok("[20] nothing was written out of the folder", vim.uv.fs_stat(vim.fs.joinpath(vim.fs.dirname(dir), "out")) == nil)
  end
end

crew.stop()
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
