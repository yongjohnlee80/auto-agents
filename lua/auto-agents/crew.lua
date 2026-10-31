---auto-agents.crew: this Neovim's crew scope in the AutoDoc daemon (ADR 1793271500 §4.3, phase 4c).
---
---A Neovim that hosts agents owns one scope, `autovim:<project>` from $AUTOVIM_PROJECT (autovim's tmux
---session exports it), else `nvim:<project key>` for a Neovim autovim didn't start. The scope is
---held by this process alone, fenced by an epoch:
---
---  * the run token is 32 random bytes made once per process and kept in memory only: holding it is
---    what lets this process reattach, so neither another Neovim nor a crash successor can;
---  * the first connection to the daemon claims the scope, and every later one reattaches with the
---    same token (the same scope and epoch, whatever the session's client token);
---  * the lease is renewed every 30 s; a renewal refused for a stale epoch (another owner took the
---    scope while this one was away) claims again and says so;
---  * a clean exit releases the scope, so a successor can claim it at once.
---
---Each agent is registered under the scope before it starts (phase 4d, §4.4, §4.5): `begin` sends
---`crew.register` with a fresh 32-byte secret, waits for the answer at most REGISTER_WAIT_MS, and
---writes the session's context (0600, through a rename) under <cwd>/.auto-agents/crew/.autodoc-crew/,
---which the agent is told by $AUTODOC_CREW_CONTEXT; `finish` ends it (`exit`, or `start_failed`).
---An agent whose registration fails or times out starts as before, without a session.
---
---Everything here is quiet on a daemon without the crew verbs, or with no AutoDoc at all: the scope
---is only claimed where `crew.claim` is served, and agents are registered only while it is held.
local M = {}

M.RENEW_MS = 30000
M.RELEASE_WAIT_MS = 2000

-- crew's refusal codes (core/crew/errors.go)
M.CODE_SCOPE_BUSY = -32090
M.CODE_STALE_EPOCH = -32091
M.CODE_METHOD_NOT_FOUND = -32601

M.TOPIC_CLAIMED = "auto-agents.crew:claimed"

-- How long a spawn waits for its session's registration before starting the agent without one.
M.REGISTER_WAIT_MS = 3000

-- The refusals that mean a registration or an exit is settled, never to be sent again: crew's own
-- (core/crew/errors.go), and a daemon that can't take the call at all.
M.CODE_CODENAME_BUSY = -32092
M.CODE_INSTANCE_REUSED = -32093
M.CODE_BAD_CREDENTIAL = -32094
M.CODE_INVALID_PARAMS = -32602

-- The session contexts' folder (core/crew's ContextDir), under <cwd>/.auto-agents/crew/: inside the
-- workspace's gitignored .auto-agents/, never the project's own tree.
M.CONTEXT_DIR = ".autodoc-crew"

-- crew's name for an auto-agents kind, where they differ.
M.KIND = { antigravity = "agy" }

local _s -- the module's state; nil before setup

---scope_id is this Neovim's scope: autovim:<project> when autovim named the project, else
---nvim:<project key>.
---@param env table<string, string|nil>
---@param project_key string|nil
---@return string|nil
function M.scope_id(env, project_key)
  local p = env and env.AUTOVIM_PROJECT
  if type(p) == "string" and p ~= "" then return "autovim:" .. p end
  if type(project_key) == "string" and project_key ~= "" then return "nvim:" .. project_key end
  return nil
end

---run_token is 32 random bytes as hex: made once per process, never written anywhere.
---@return string
function M.run_token()
  local bytes = vim.uv.random(32)
  return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

---proc_ref is this process's reference, "<boot id>:<pid ns>:<pid>:<start time>", as core/crew's
---ProcRef makes it; "" when /proc can't say (not Linux, or a read fails): then the lease decides.
---@param root string|nil the /proc root (tests)
---@return string
function M.proc_ref(root)
  root = root or "/proc"
  local function read(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
  end
  local boot = read(root .. "/sys/kernel/random/boot_id")
  local ns = vim.uv.fs_readlink(root .. "/self/ns/pid")
  local pid = vim.uv.os_getpid()
  local stat = read(root .. "/" .. pid .. "/stat")
  if not boot or not ns or not stat then return "" end
  boot = vim.trim(boot)
  ns = ns:match("^pid:%[(%d+)%]$")
  local after = stat:match("^.*%)(.*)$") -- the command may hold spaces and parentheses
  if boot == "" or not ns or not after then return "" end
  local fields = vim.split(vim.trim(after), "%s+")
  local start = fields[22 - 2] -- field 22, counted from field 3 (state) after the command
  if not start or start == "" then return "" end
  return table.concat({ boot, ns, tostring(pid), start }, ":")
end

---crew_kind is crew's name for an auto-agents kind: agy for antigravity, else the kind itself.
---@param kind string|nil
---@return string
function M.crew_kind(kind)
  if type(kind) ~= "string" or kind == "" then return "generic" end
  return M.KIND[kind] or kind
end

---endpoint_command is the SessionStart hook that registers a Claude session's endpoint (§4.7), run
---by the autodoc binary at bin: what it prints (the endpoint's generation) is not for the agent's
---context, which a SessionStart hook's output joins; a failure still says why, on stderr.
---@param bin string
---@return string
function M.endpoint_command(bin)
  return vim.fn.shellescape(bin) .. " crew endpoint --claude >/dev/null"
end

---CLAUDE_PROMPT_EVENTS are the hooks that report a crew Claude agent's permission prompts, as
---AutoDoc's own window writes them: PermissionRequest and a permission Notification raise the
---session's permission attention, and PostToolUse, UserPromptSubmit, Stop or another Notification
---clear it (`autodoc crew attention --claude-hook`). The prompt then shows in the user's crew
---inbox, and a sender that presses Enter after typing to the agent can tell it isn't waiting on one.
M.CLAUDE_PROMPT_EVENTS = { "PermissionRequest", "Notification", "PostToolUse", "UserPromptSubmit", "Stop" }

---prompt_command is the hook that reports a permission prompt, run by the autodoc binary at bin. It
---prints nothing: a PermissionRequest hook's output could decide the prompt, and a UserPromptSubmit
---hook's joins the agent's context. It always exits 0: an autodoc older than the hook rejects its
---flag with exit 2, which Claude Code would take as a PermissionRequest's denial. A failure still
---says why, on stderr.
---@param bin string
---@return string
function M.prompt_command(bin)
  return vim.fn.shellescape(bin) .. " crew attention --claude-hook >/dev/null || true"
end

---wake_argv is what a crew session's CLI of kind starts with, so the crew's fixed notice can start a
---turn (ADR 1793271500 §4.9): for Claude Code, `--settings` carrying the SessionStart hook that
---registers its endpoint, crossSessionInbound "accept", and the hooks that report its permission
---prompts (they report; they decide nothing); nothing for the others yet. Given on the command
---line, so the project's own settings are never edited; never approval policies, permission modes,
---or allow or deny rules: a turn a wake starts runs under the agent's own policy.
---@param kind string crew's kind
---@param bin string|nil the autodoc binary
---@return string[]
function M.wake_argv(kind, bin)
  if kind ~= "claude" or type(bin) ~= "string" or bin == "" then return {} end
  local hooks = { SessionStart = { { hooks = { { type = "command", command = M.endpoint_command(bin) } } } } }
  for _, event in ipairs(M.CLAUDE_PROMPT_EVENTS) do
    hooks[event] = { { hooks = { { type = "command", command = M.prompt_command(bin) } } } }
  end
  return { "--settings", vim.json.encode({ hooks = hooks, crossSessionInbound = "accept" }) }
end

-- How long a spawn waits for AutoDoc's OpenCode plugin environment before starting without it.
M.PLUGIN_ENV_WAIT_MS = 5000

---wake_env is what a crew session's CLI of kind starts with in its environment, so a wake reaches
---it (§4.9): for OpenCode, the OPENCODE_CONFIG_CONTENT that loads AutoDoc's OpenCode plugin, which
---registers the session's endpoint and wakes it. Without it the session is never reachable. It is
---what the autodoc binary at bin prints (`autodoc crew plugin --opencode --print-env`), so the
---plugin is that build's, merged by it with current (the value the agent would start with), as
---AutoDoc's own window does. The other kinds get nothing. nil and why when it can't be had: no
---binary, one older than the command, a failure, or no answer within PLUGIN_ENV_WAIT_MS.
---@param kind string crew's kind
---@param bin string|nil the autodoc binary
---@param current string|nil the OPENCODE_CONFIG_CONTENT the agent's env sets, if any
---@param run fun(argv: string[], env: table, ms: integer): integer, string, string|nil for tests
---@return table<string, string>|nil env, string|nil why
function M.wake_env(kind, bin, current, run)
  if kind ~= "opencode" then return {}, nil end
  if type(bin) ~= "string" or bin == "" then return nil, "no autodoc binary" end
  run = run or function(argv, env, ms)
    local r = vim.system(argv, { env = env, text = true }):wait(ms)
    return r.code, r.stdout or "", r.stderr
  end
  -- the agent's own value, when its env sets one; else the binary sees this Neovim's, as the agent would
  local env = {}
  if type(current) == "string" and current ~= "" then env.OPENCODE_CONFIG_CONTENT = current end
  local ok, code, out, err = pcall(run, { bin, "crew", "plugin", "--opencode", "--print-env" }, env, M.PLUGIN_ENV_WAIT_MS)
  if not ok then return nil, tostring(code) end
  local line = vim.trim(out or "")
  local value = line:match("^OPENCODE_CONFIG_CONTENT=(.+)$")
  if code ~= 0 or not value or line:find("\n", 1, true) then
    local why = vim.trim(err or "")
    return nil, ("`autodoc crew plugin --opencode --print-env` answered %s%s"):format(
      code ~= 0 and ("exit " .. tostring(code)) or ("%q"):format(line), why ~= "" and (": " .. why) or "")
  end
  return { OPENCODE_CONFIG_CONTENT = value }, nil
end

---autodoc_binary is the autodoc binary AutoDoc's plugin runs (its opts.bin, else its own build,
---else PATH), or nil.
---@return string|nil
function M.autodoc_binary()
  local ok, lifecycle = pcall(require, "autodoc.lifecycle")
  if not ok then return nil end
  local ok_ad, autodoc = pcall(require, "autodoc")
  local configured = ok_ad and type(autodoc.options) == "function" and (autodoc.options() or {}).bin or nil
  local path = lifecycle.resolve_binary(configured)
  return path
end

---context_folder is the folder whose .autodoc-crew/ holds the session contexts of the agents
---started in cwd.
---@param cwd string
---@return string
function M.context_folder(cwd)
  return vim.fs.joinpath(cwd, ".auto-agents", "crew")
end

-- a session id names its context's file: a plain file name, never a dot file
local function plain_name(session)
  return type(session) == "string" and session ~= "" and session:sub(1, 1) ~= "." and not session:find("[/\\]")
end

---write_context writes c as its session's context file in folder (core/crew's WriteContext): mode
---0600, through a dot file renamed over it, so a reader sees the whole context or none. It answers
---the file's path, which the agent is told ($AUTODOC_CREW_CONTEXT).
---@param folder string
---@param c { store: string, socket: string, scope: string, profile: string, session: string, credential: string, kind: string }
---@return string|nil path, string|nil err
function M.write_context(folder, c)
  if not plain_name(c.session) then return nil, "session id " .. tostring(c.session) end
  local dir = vim.fs.joinpath(folder, M.CONTEXT_DIR)
  -- mkdir raises (E739) when it can't make the folder: an error here, never a raise mid-spawn
  local made, merr = pcall(vim.fn.mkdir, dir, "p", tonumber("700", 8))
  if not made or vim.fn.isdirectory(dir) == 0 then
    return nil, "could not make " .. dir .. (made and "" or (": " .. tostring(merr)))
  end
  local body = vim.json.encode({ store = c.store, socket = c.socket, scope = c.scope, profile = c.profile,
    session = c.session, credential = c.credential, kind = c.kind })
  local tmp = vim.fs.joinpath(dir, "." .. c.session .. "." .. M.run_token():sub(1, 12))
  local fd, oerr = vim.uv.fs_open(tmp, "wx", tonumber("600", 8))
  if not fd then return nil, oerr end
  local _, werr = vim.uv.fs_write(fd, body)
  vim.uv.fs_close(fd)
  local path = vim.fs.joinpath(dir, c.session)
  if not werr then
    local ok, rerr = vim.uv.fs_rename(tmp, path)
    if ok then return path, nil end
    werr = rerr
  end
  vim.uv.fs_unlink(tmp)
  return nil, werr
end

---remove_context removes session's context file from folder once the session has ended, so no
---later process reads its credential: that file alone, by its session's name. One already gone is
---no error.
---@param folder string
---@param session string
function M.remove_context(folder, session)
  if not plain_name(session) then return end
  vim.uv.fs_unlink(vim.fs.joinpath(folder, M.CONTEXT_DIR, session))
end

-- The state of one setup, st, is never reached through a global by a callback or a timer: each
-- captures st and the attempt it was made for, and does nothing once st is no longer the module's
-- (a stop, or a setup that replaced it) or a later attempt superseded it.
--
-- st.status:
--   "idle"        no claim yet, or the last one was refused (a retry is scheduled)
--   "claiming"    a claim is in flight
--   "held"        the scope is held at st.epoch, renewed every RENEW_MS
--   "reattaching" it was held, but a reattach or a renewal failed: the lease may lapse, so nothing
--                 is reported held until a claim answers again (a retry is scheduled)
--   "released"    given up on exit: nothing claims again in this process
--   "stopped"     forgotten (stop, or a newer setup)

---held is the scope and epoch this process holds, nil when it holds none for sure.
---@return string|nil scope, integer|nil epoch
function M.held()
  if not _s or _s.status ~= "held" then return nil, nil end
  return _s.scope, _s.epoch
end

local function code(err)
  return type(err) == "table" and err.code or nil
end

local function message(err)
  if type(err) == "table" then return tostring(err.message or err.code) end
  return tostring(err)
end

-- session is autodoc.session, resolved when first needed: AutoDoc's plugin may load after this one.
local function session(st)
  if st.session then return st.session end
  local ok, mod = pcall(require, "autodoc.session")
  if ok then st.session = mod end
  return st.session
end

local function serves_crew(st)
  local sess = session(st)
  if not sess then return false end
  local c = sess.client and sess.client()
  if not c then return false end
  if c.can and not c:can("crew.claim") then return false end
  return true
end

local function live(st) return _s == st and st.status ~= "released" and st.status ~= "stopped" end

-- next_attempt supersedes every callback and timer made before it.
local function next_attempt(st)
  st.attempt = st.attempt + 1
  return st.attempt
end

local claim -- forward

-- later runs fn after ms for attempt a of st, only while that attempt is current.
local function later(st, a, ms, fn)
  st.after(ms, function()
    if live(st) and st.attempt == a then fn() end
  end)
end

-- ── sessions (phase 4d): each agent registered before it starts ─────────────
--
-- st.sessions  the agents' sessions registered and not yet ended, by id
-- st.pending   each codename's registration whose answer was lost: the daemon may have committed
--              it, so its exact tuple is replayed, by the codename's next start or by settle, never
--              a fresh one that would find the session it left as busy
-- st.owed      each ended session whose crew.exit the daemon has not confirmed, by id: asked again
--              until it answers

local _instances = 0 -- the spawns this process made: each registration's instance id

-- refused is an answer that settles a registration or an exit: never to be sent again.
local function refused(err)
  local c = code(err)
  return c == M.CODE_SCOPE_BUSY or c == M.CODE_STALE_EPOCH or c == M.CODE_CODENAME_BUSY or c == M.CODE_INSTANCE_REUSED
    or c == M.CODE_BAD_CREDENTIAL or c == M.CODE_METHOD_NOT_FOUND or c == M.CODE_INVALID_PARAMS
end

local function send_exit(st, id)
  local o = st.owed[id]
  if not o or o.inflight then return end
  o.inflight = true
  st.session.call("crew.exit", { o.s.scope, st.run, o.s.epoch, o.s.id, o.why }, function(_, err)
    if _s ~= st or st.owed[id] ~= o then return end
    if not err or refused(err) then -- ended, or ended already by the scope changing hands
      st.owed[id] = nil
      return
    end
    o.inflight = false
  end)
end

-- end_session ends s, why: its context file goes at once, so no later process reads its credential,
-- and the daemon is told; until it answers, the exit is owed.
local function end_session(st, s, why)
  M.remove_context(s.folder, s.id)
  st.sessions[s.id] = nil
  st.owed[s.id] = { s = s, why = why }
  send_exit(st, s.id)
end

local function forget(st, r)
  if st.pending[r.codename] == r then st.pending[r.codename] = nil end
end

-- send_register sends r's crew.register; then(s, err) gets the session, now counted live, or why
-- there is none. r stays pending only when the answer was lost.
local function send_register(st, r, then_)
  r.inflight = true
  st.session.call("crew.register", { r.scope, st.run, r.epoch, r.codename, r.kind, r.workspace, r.instance, r.secret },
    function(res, err)
      r.inflight = false
      if _s ~= st then return end
      if not live(st) or st.scope ~= r.scope or st.epoch ~= r.epoch then
        -- released, or claimed again at another epoch: either ended every session of r's epoch, so
        -- whatever this answer made is over; nothing is counted, and no exit is owed for it
        forget(st, r)
        return then_(nil, { message = "the crew scope changed while the registration was answered" })
      end
      local id = not err and type(res) == "table" and res.session or nil
      if not id then
        err = err or { message = "the registration answered no session" }
        if refused(err) then forget(st, r) end
        return then_(nil, err)
      end
      forget(st, r)
      local s = { id = id, profile = res.profile, scope = r.scope, epoch = r.epoch, folder = r.folder, kind = r.kind,
        codename = r.codename }
      st.sessions[id] = s
      then_(s, nil)
    end)
end

-- resolve ends lost registration r, which nobody is starting: replayed as it was, the session the
-- daemon committed comes back and is ended (start_failed), so its codename is free.
local function resolve(st, r)
  if r.inflight then return end
  send_register(st, r, function(s)
    if s then end_session(st, s, "start_failed") end
  end)
end

-- settle asks the daemon again for what this Neovim owes it, each time a renewal or a claim answers:
-- every exit not yet confirmed, and every lost registration nobody is starting. One under a scope
-- or epoch no longer held was ended by the claim that changed it.
local function settle(st)
  for id, o in pairs(st.owed) do
    if o.s.scope ~= st.scope or o.s.epoch ~= st.epoch then
      st.owed[id] = nil
    else
      send_exit(st, id)
    end
  end
  for codename, r in pairs(st.pending) do
    if r.scope ~= st.scope or r.epoch ~= st.epoch then
      if not r.inflight then st.pending[codename] = nil end
    else
      resolve(st, r)
    end
  end
end

-- drop_sessions forgets the sessions of an epoch no longer held: the claim that changed it ended
-- them, so their contexts go too. The gateway's goes with them, to be registered again.
local function drop_sessions(st)
  for id, s in pairs(st.sessions) do
    if s.epoch ~= st.epoch then
      M.remove_context(s.folder, id)
      st.sessions[id] = nil
    end
  end
  local g = st.gateway
  if g and g.r and (g.r.scope ~= st.scope or g.r.epoch ~= st.epoch) then
    g.r, g.s, g.credential = nil, nil, nil
  end
end

-- ── the gateway session (phase 4e): this Neovim's own sender ─────────────────
--
-- The legacy mailbox's sender for cut-over recipients (auto-agents.crew_gateway) sends as one
-- session of the scope, codename `gateway`, kind `host`. Its credential lives in memory only: no
-- process but this one sends with it, so no context is written. It is registered once the scope is
-- held and asked for, kept across renewals, registered again after an epoch change, and replayed
-- as it was when its registration's answer was lost.
M.GATEWAY_CODENAME = "gateway"
M.GATEWAY_KIND = "host"

---NO_WORKSPACE is the workspace a session is registered with when no AutoDoc workspace serves its
---folder (nor the project's primary KB): the daemon keeps a session's workspace as metadata, so an
---agent anywhere gets its crew session and its mail.
M.NO_WORKSPACE = ""

-- ensure_gateway registers the gateway session when it is wanted and not held or in flight.
-- store_of is the store the session's connection serves (sys.hello's store_id), or nil.
local function store_of(sess)
  local c = sess and sess.client and sess.client()
  local h = c and c.hello and c:hello() or nil
  local id = h and h.store_id or nil
  return type(id) == "string" and id ~= "" and id or nil
end

local function ensure_gateway(st)
  local g = st.gateway
  if not g or not live(st) or st.status ~= "held" then return end
  local sess = st.session
  local store = store_of(sess)
  if not store then return end
  -- registered on another store (the daemon swapped stores, at the same epoch or not): that
  -- credential names nothing here, so it is dropped and the gateway registered again (Lector #5 F2)
  if g.r and g.r.store ~= store and not g.r.inflight then g.r, g.s, g.credential = nil, nil, nil end
  -- the addressbook is the current store's and claim's only (Lector #5 r1 F2): another's says
  -- nothing about who holds the codename here
  if g.book and (g.book_store ~= store or g.book_epoch ~= st.epoch) then g.book = nil end
  if g.s or (g.r and g.r.inflight) then return end
  -- the codename is this Neovim's own: an agent's profile of that name (an older registration, not
  -- a host) is never taken over, nor its mail (Lector #5 F3); the addressbook says, so it comes first
  if not g.book then return end
  local held = g.book[M.GATEWAY_CODENAME]
  if held and held ~= M.GATEWAY_KIND then
    if not g.said_taken then
      g.said_taken = true
      st.notify(("The crew gateway is off: this scope already has an agent profile named %q (kind %s). Rename that agent to cut mail over.")
        :format(M.GATEWAY_CODENAME, tostring(held)), vim.log.levels.WARN)
    end
    return
  end
  if not g.r then
    local name = (sess.workspace_of and sess.workspace_of(g.cwd)) or (sess.primary_workspace and sess.primary_workspace())
    local w = name and sess.workspace and sess.workspace(name) or nil
    local id = w and tonumber(w.id) or nil
    if (not id or id <= 0) and sess.workspaces and not g.listed then
      if not g.listing then
        g.listing = true
        sess.workspaces(function()
          g.listing = false
          if g.listed then return end
          g.listed = true -- one listing per claim: a store with no workspace for it never loops
          ensure_gateway(st)
        end)
      end
      return
    end
    _instances = _instances + 1
    g.r = { codename = M.GATEWAY_CODENAME, kind = M.GATEWAY_KIND,
      workspace = (id and id > 0) and tostring(id) or M.NO_WORKSPACE,
      instance = ("nvim-gateway-%d-%d"):format(vim.uv.os_getpid(), _instances), secret = M.run_token(),
      scope = st.scope, epoch = st.epoch, store = store, folder = nil }
  end
  local r = g.r
  r.inflight = true
  st.session.call("crew.register", { r.scope, st.run, r.epoch, r.codename, r.kind, r.workspace, r.instance, r.secret },
    function(res, err)
      r.inflight = false
      if _s ~= st or st.gateway ~= g or g.r ~= r then return end
      if store_of(st.session) ~= r.store then -- answered by the store it was sent to, now replaced
        g.r = nil
        return
      end
      local sid = not err and type(res) == "table" and res.session or nil
      if not sid then
        if refused(err) then g.r = nil end -- a lost answer keeps r, replayed as it was at the next renewal
        st.notify("The crew gateway session could not be registered: " .. message(err), vim.log.levels.WARN)
        return
      end
      if not live(st) or st.status ~= "held" or st.epoch ~= r.epoch then return end
      g.s = { id = sid, profile = res.profile, scope = r.scope, epoch = r.epoch }
      g.credential = sid .. "." .. r.secret
    end)
end

-- refresh_addressbook keeps the codenames crew.list answers, for the gateway's sender to check a
-- recipient against before it takes a message (an unknown one stays on the file route).
local refresh_addressbook
refresh_addressbook = function(st)
  local g = st.gateway
  if not g or not live(st) or g.listing_book then return end
  local store, epoch = store_of(st.session), st.epoch
  if not store then return end
  g.listing_book = true
  st.session.call("crew.list", {}, function(res, err)
    g.listing_book = false
    if _s ~= st or st.gateway ~= g or err or type(res) ~= "table" then return end
    -- answered for a store or claim no longer current: dropped, and asked again for this one
    if store_of(st.session) ~= store or st.epoch ~= epoch then
      g.book = nil
      return refresh_addressbook(st)
    end
    local book = {}
    for _, e in ipairs(res) do
      if type(e) == "table" and e.scope == st.scope and type(e.codename) == "string" then
        book[e.codename] = type(e.kind) == "string" and e.kind or "?"
      end
    end
    g.book, g.book_store, g.book_epoch = book, store, epoch
    ensure_gateway(st) -- the gateway registers once the addressbook says its codename is free
  end)
end

---enable_gateway asks for the gateway session (phase 4e), registered under the workspace holding
---cwd (else the project's primary KB, else M.NO_WORKSPACE once the workspaces are listed) once the
---scope is held, and kept from then on.
---@param cwd string
function M.enable_gateway(cwd)
  local st = _s
  if not st or st.gateway then return end
  st.gateway = { cwd = cwd }
  ensure_gateway(st)
  if st.status == "held" then refresh_addressbook(st) end
end

---gateway_credential is the gateway session's "<session>.<secret>" while it is held under the
---scope's current epoch, else nil.
---@return string|nil
function M.gateway_credential()
  local st = _s
  local g = st and st.gateway
  if not g or not g.s or st.status ~= "held" or g.s.epoch ~= st.epoch then return nil end
  if store_of(st.session) ~= g.r.store then return nil end -- a credential of another store names nothing here
  return g.credential
end

---gateway_identity is the authority the gateway sends under, while it is held: the store, the
---scope and the gateway's profile. A send's idempotency key dedups only under the same one.
---@return { store: string, scope: string, profile: string }|nil
function M.gateway_identity()
  local st = _s
  if not M.gateway_credential() then return nil end
  local g = st.gateway
  return { store = g.r.store, scope = g.r.scope, profile = g.s.profile }
end

---in_addressbook is whether codename is a profile in this scope, as crew.list last said.
---@param codename string
---@return boolean
function M.in_addressbook(codename)
  local g = _s and _s.gateway
  return g ~= nil and g.book ~= nil and codename ~= M.GATEWAY_CODENAME and g.book[codename] ~= nil
end

local function renew_later(st, a)
  later(st, a, M.RENEW_MS, function()
    st.session.call("crew.renew", { st.scope, st.run, st.epoch }, function(_, err)
      if not live(st) or st.attempt ~= a then return end
      if code(err) == M.CODE_STALE_EPOCH then
        claim(st, st.epoch) -- another owner took it while this one was away
        return
      end
      if err then
        -- the daemon may be gone: the lease may lapse, so it is not reported held; reattach soon
        st.status = "reattaching"
        local r = next_attempt(st)
        later(st, r, M.RENEW_MS, function() claim(st, st.epoch) end)
        return
      end
      settle(st)
      ensure_gateway(st)
      refresh_addressbook(st)
      renew_later(st, a)
    end)
  end)
end

---claim takes the scope, or reattaches to it with this process's run token. lost is an epoch this
---process held, so an answer at another epoch says the agents moved.
claim = function(st, lost)
  if not live(st) or st.status == "claiming" or st.dormant then return end
  if not serves_crew(st) then return end
  local was = st.status
  st.status = "claiming"
  local a = next_attempt(st)
  local before = lost or (was == "held" and st.epoch) or nil
  st.session.call("crew.claim", { st.scope, st.run, st.proc }, function(res, err)
    local epoch = (not err and type(res) == "table") and tonumber(res.epoch) or nil
    if _s ~= st or st.attempt ~= a or st.status == "released" or st.status == "stopped" then
      -- superseded: a claim the daemon accepted after a release or a stop is given back, under the
      -- identity it was made with, so nothing holds the scope that no one renews
      if epoch and (st.status == "released" or st.status == "stopped") then
        st.session.call("crew.release", { st.scope, st.run, epoch }, function() end)
      end
      return
    end
    if err then
      local c = code(err)
      if c == M.CODE_METHOD_NOT_FOUND then
        st.dormant, st.status = true, "idle" -- an AutoDoc without crew: stay quiet
        return
      end
      if c == M.CODE_SCOPE_BUSY then
        if not st.busy_said then
          st.busy_said = true
          st.notify(("Crew scope %s is held by another live Neovim: this one's agents stay unregistered until it's free."):format(st.scope),
            vim.log.levels.WARN)
        end
      else
        st.notify("Crew scope " .. st.scope .. " could not be claimed: " .. message(err), vim.log.levels.WARN)
      end
      st.status = before and "reattaching" or "idle"
      local r = next_attempt(st)
      later(st, r, M.RENEW_MS, function() claim(st, before) end)
      return
    end
    if not epoch then
      st.notify("Crew scope " .. st.scope .. ": the daemon answered crew.claim without an epoch", vim.log.levels.WARN)
      st.status = before and "reattaching" or "idle"
      local r = next_attempt(st)
      later(st, r, M.RENEW_MS, function() claim(st, before) end)
      return
    end
    st.busy_said = false
    if before and epoch ~= before then
      st.notify(("This Neovim lost its crew scope %s while away and claimed it again (epoch %d): agents registered before must register again.")
        :format(st.scope, epoch), vim.log.levels.WARN)
    end
    st.epoch, st.status = epoch, "held"
    drop_sessions(st)
    st.publish(M.TOPIC_CLAIMED, { scope = st.scope, epoch = epoch, reattached = before == epoch })
    settle(st)
    if st.gateway then st.gateway.listed = false end
    ensure_gateway(st)
    refresh_addressbook(st)
    renew_later(st, a)
  end)
end

---release gives the scope up, waiting at most RELEASE_WAIT_MS, so a successor can claim it at once
---and this run can't reattach after. Nothing claims again in this process after it. A claim still
---in flight is given back when it answers; if the process exits first (the first claim had not
---answered, so no epoch was known), the scope is freed only when its lease lapses.
function M.release()
  local st = _s
  if not st or st.status == "released" or st.status == "stopped" then return end
  local epoch = st.epoch
  st.status = "released"
  next_attempt(st) -- every pending callback and timer is now superseded
  -- a reattach in flight still has the epoch it held: give that up now; a late accepted claim is
  -- given back when it arrives (a second release of one epoch is harmless)
  -- the agents stop with this Neovim: their contexts go now, and the release ends their sessions
  for id, s in pairs(st.sessions) do M.remove_context(s.folder, id) end
  st.sessions, st.pending, st.owed = {}, {}, {}
  if st.gateway then st.gateway.r, st.gateway.s, st.gateway.credential = nil, nil, nil end -- ended with the scope
  if not epoch then return end
  local done = false
  st.session.call("crew.release", { st.scope, st.run, epoch }, function() done = true end)
  st.wait(M.RELEASE_WAIT_MS, function() return done end)
end


-- workspace_id is the id (in the daemon's store) of the AutoDoc workspace holding cwd, else the
-- project's primary KB's; nil when neither is served. The workspaces are listed first when they
-- were not yet, within the spawn's wait.
local function workspace_id(st, sess, cwd, deadline)
  local function find()
    local name = sess.workspace_of and sess.workspace_of(cwd) or nil
    name = name or (sess.primary_workspace and sess.primary_workspace()) or nil
    local w = name and sess.workspace and sess.workspace(name) or nil
    local n = w and tonumber(w.id) or nil
    return n and n > 0 and tostring(n) or nil
  end
  local id = find()
  if id or not sess.workspaces then return id end
  local listed = false
  sess.workspaces(function() listed = true end)
  st.wait(math.max(deadline - vim.uv.now(), 0), function() return listed end)
  return find()
end

---begin registers an agent's session before it starts (ADR 1793271500 §4.4, §4.5), waiting at most
---REGISTER_WAIT_MS, and writes its context once the session is still this Neovim's. It answers the
---session's handle, whose env (AUTODOC_CREW_CONTEXT) the spawn adds; finish ends it. nil when no
---scope is held (the agent starts as before, without a crew session); an agent no workspace serves
---is registered with M.NO_WORKSPACE,
---with why when the registration was tried and failed. A registration answered after the wait is
---ended, since nobody starts it; one whose answer was lost is replayed as it was by the codename's
---next start, or ended by the next renewal.
---@param opts { codename: string, kind: string|nil, cwd: string }
---@return table|nil handle the session, its context's path and the env to add
---@return string|nil why
function M.begin(opts)
  local st = _s
  if not st or st.status ~= "held" or not st.session then return nil, nil end
  if vim.in_fast_event() then return nil, "a crew session can't be registered from a fast event" end
  local sess = st.session
  local c = sess.client and sess.client()
  if not c then return nil, nil end
  local h = c.hello and c:hello() or {}
  local store, socket = h.store_id, c.addr and c:addr() or nil
  if type(store) ~= "string" or store == "" or type(socket) ~= "string" or socket == "" then return nil, nil end
  local deadline = vim.uv.now() + M.REGISTER_WAIT_MS
  -- the workspace is the session's metadata, not its address: an agent in a folder no AutoDoc
  -- workspace serves is registered with none, so its mail still reaches it once the file mailbox
  -- is retired
  local ws = workspace_id(st, sess, opts.cwd, deadline) or M.NO_WORKSPACE
  -- the wait may have outlived the scope, the epoch or the connection: start nothing under them
  if _s ~= st or st.status ~= "held" or sess.client() ~= c then return nil, nil end

  local codename, kind, folder = opts.codename, M.crew_kind(opts.kind), M.context_folder(opts.cwd)
  if codename == M.GATEWAY_CODENAME then
    return nil, ("the codename %q is this Neovim's mail gateway's: rename the agent to give it a crew session"):format(codename)
  end
  -- the codename's previous session is over first, or this one is refused as busy: one still
  -- counted live (its process killed, its exit not yet reaped) is ended now, and its exit, with
  -- any other still owed for the codename, is waited for within the spawn's wait
  for _, live_s in pairs(st.sessions) do
    if live_s.codename == codename then end_session(st, live_s, "exit") end
  end
  local function owing()
    for _, o in pairs(st.owed) do
      if o.s.codename == codename and o.s.scope == st.scope and o.s.epoch == st.epoch then return true end
    end
    return false
  end
  if owing() then
    for id, o in pairs(st.owed) do
      if o.s.codename == codename then send_exit(st, id) end
    end
    st.wait(math.max(deadline - vim.uv.now(), 0), function() return not owing() end)
    if _s ~= st or st.status ~= "held" or sess.client() ~= c then return nil, nil end
    -- an exit still unconfirmed: the registration goes ahead, and a busy codename is refused and said
  end
  local r = st.pending[codename]
  if r and r.inflight then return nil, "its last registration is still unanswered" end
  if r and (r.scope ~= st.scope or r.epoch ~= st.epoch or r.store ~= store) then
    st.pending[codename] = nil -- the claim that changed the epoch ended its session; another store has none
    r = nil
  end
  if r and (r.kind ~= kind or r.workspace ~= ws) then
    resolve(st, r) -- its profile changed since: the session it left is ended first
    return nil, "its last registration is still being ended"
  end
  if not r then
    _instances = _instances + 1
    r = { codename = codename, kind = kind, workspace = ws, instance = ("nvim-%d-%d"):format(vim.uv.os_getpid(), _instances),
      secret = M.run_token(), scope = st.scope, epoch = st.epoch, store = store, folder = folder }
    st.pending[codename] = r
  end
  r.folder = folder

  local waiting, answered, s, err = true, false, nil, nil
  send_register(st, r, function(got, e)
    if not waiting then
      if got then end_session(st, got, "start_failed") end -- answered after the spawn gave up: nobody starts it
      return
    end
    answered, s, err = true, got, e
  end)
  st.wait(math.max(deadline - vim.uv.now(), 0), function() return answered end)
  waiting = false
  if not answered then return nil, "the daemon did not answer the registration in time" end
  if not s then return nil, message(err) end
  -- still this Neovim's: the scope held at the epoch it was registered under, on the same connection
  if _s ~= st or st.status ~= "held" or st.epoch ~= s.epoch or sess.client() ~= c then
    if live(st) and st.epoch == s.epoch then end_session(st, s, "start_failed") end
    return nil, "the crew scope changed while the session was registered"
  end
  local path, werr = M.write_context(folder, { store = store, socket = socket, scope = s.scope, profile = s.profile,
    session = s.id, credential = s.id .. "." .. r.secret, kind = kind })
  r.secret = nil -- kept no longer than it is needed
  if not path then
    end_session(st, s, "start_failed")
    return nil, "its session context could not be written: " .. tostring(werr)
  end
  return { session = s, context = path, env = { AUTODOC_CREW_CONTEXT = path } }, nil
end

---finish ends handle's session, why: "exit" when the agent's process ended, "start_failed" when it
---never started. Its context file goes at once; the daemon is told, and asked again until it
---answers. A second finish is nothing.
---@param handle table|nil
---@param why string|nil
function M.finish(handle, why)
  if not handle or handle.ended then return end
  handle.ended = true
  local s, st = handle.session, _s
  if st and st.sessions[s.id] == s then
    end_session(st, s, why or "exit")
  else
    M.remove_context(s.folder, s.id) -- the scope changed hands or was released: its session ended with it
  end
end

-- How long writing an instruction block waits for the daemon's crew guide before writing it without.
M.GUIDE_WAIT_MS = 1000

---guide is the crew and mail procedure for an auto-agents kind, the daemon's crew.guide markdown
---(§4.10), which the instruction block carries: cached per store, daemon version and kind, so a
---restarted daemon of another build is asked again. nil while the scope isn't held, on a daemon
---without the verb, or when it fails or doesn't answer within GUIDE_WAIT_MS (asked again next time).
---@param kind string auto-agents' kind
---@return string|nil
function M.guide(kind)
  local st = _s
  if not st or st.status ~= "held" or vim.in_fast_event() then return nil end
  local sess = session(st)
  local c = sess and sess.client and sess.client()
  if not c or (c.can and not c:can("crew.guide")) then return nil end
  local h = c.hello and c:hello() or {}
  if type(h.store_id) ~= "string" or h.store_id == "" then return nil end
  local k = M.crew_kind(kind)
  local key = table.concat({ h.store_id, tostring(h.version), k }, "\0")
  st.guides = st.guides or {}
  if st.guides[key] then return st.guides[key] end
  local answered, md = false, nil
  sess.call("crew.guide", { k }, function(res, err)
    answered = true
    if not err and type(res) == "table" and type(res.markdown) == "string" and res.markdown ~= "" then md = res.markdown end
  end)
  st.wait(M.GUIDE_WAIT_MS, function() return answered end)
  if answered and md then st.guides[key] = md end
  return md
end


---setup starts holding the scope. opts (all optional, for tests): session (autodoc.session), events
---(auto-core.events), env, project_key, notify, after(ms, fn), wait(ms, cond), proc.
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  local scope = M.scope_id(opts.env or vim.env, opts.project_key)
  if not scope then return false end
  M.stop()
  local st = {
    session = opts.session, -- else autodoc.session, resolved when first needed
    scope = scope,
    run = M.run_token(),
    proc = opts.proc or M.proc_ref(),
    epoch = nil,
    status = "idle",
    attempt = 0,
    dormant = false,
    notify = opts.notify or function(msg, level) vim.notify(msg, level, { title = "auto-agents" }) end,
    after = opts.after or function(ms, fn) vim.defer_fn(fn, ms) end,
    wait = opts.wait or function(ms, cond) vim.wait(ms, cond, 20) end,
    publish = function() end,
    subs = {},
    sessions = {},
    pending = {},
    owed = {},
  }
  _s = st
  local events = opts.events
  if events == nil then
    local ok, ev = pcall(require, "auto-core.events")
    events = ok and ev or false
  end
  st.events = events or nil
  if events then
    st.publish = function(topic, payload) pcall(events.publish, topic, payload) end
    pcall(events.register_topics, "auto-agents", {
      [M.TOPIC_CLAIMED] = { doc = "This Neovim holds its crew scope in the AutoDoc daemon.",
        payload = "{ scope = string, epoch = integer, reattached = boolean }", publishers = { "auto-agents" } },
    })
    -- every connection to the daemon claims or reattaches; a lost one leaves the scope to the lease
    table.insert(st.subs, events.subscribe("autodoc.session:connected", function()
      if not live(st) then return end
      st.dormant = false
      if st.status == "claiming" then return end -- the claim in flight answers for this connection
      claim(st, st.status ~= "idle" and st.epoch or nil)
    end))
  end
  st.augroup = vim.api.nvim_create_augroup("auto-agents.crew", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = st.augroup, callback = function() M.release() end })
  local sess = session(st)
  if sess and sess.is_ready and sess.is_ready() then claim(st) end
  return true
end

---stop forgets the scope without releasing it (tests, a reload): its lease lapses on its own.
function M.stop()
  local st = _s
  if not st then return end
  st.status = "stopped"
  next_attempt(st)
  for _, sub in ipairs(st.subs or {}) do
    if st.events then pcall(st.events.unsubscribe, sub) end
  end
  if st.augroup then pcall(vim.api.nvim_del_augroup_by_id, st.augroup) end
  _s = nil
end

return M
