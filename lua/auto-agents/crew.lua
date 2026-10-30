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
---Everything here is quiet on a daemon without the crew verbs, or with no AutoDoc at all: the scope
---is only claimed where `crew.claim` is served. Registering the agents themselves under the scope
---is phase 4d; this module only holds the scope they will live under.
local M = {}

M.RENEW_MS = 30000
M.RELEASE_WAIT_MS = 2000

-- crew's refusal codes (core/crew/errors.go)
M.CODE_SCOPE_BUSY = -32090
M.CODE_STALE_EPOCH = -32091
M.CODE_METHOD_NOT_FOUND = -32601

M.TOPIC_CLAIMED = "auto-agents.crew:claimed"

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
    st.publish(M.TOPIC_CLAIMED, { scope = st.scope, epoch = epoch, reattached = before == epoch })
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
  if not epoch then return end
  local done = false
  st.session.call("crew.release", { st.scope, st.run, epoch }, function() done = true end)
  st.wait(M.RELEASE_WAIT_MS, function() return done end)
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
