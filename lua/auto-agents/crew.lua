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

---held is the scope and epoch this process holds, nil when it holds none.
---@return string|nil scope, integer|nil epoch
function M.held()
  if not _s or not _s.epoch then return nil, nil end
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
local function session()
  if _s.session then return _s.session end
  local ok, mod = pcall(require, "autodoc.session")
  if ok then _s.session = mod end
  return _s.session
end

local function serves_crew()
  if not session() then return false end
  local c = _s.session.client and _s.session.client()
  if not c then return false end
  if c.can and not c:can("crew.claim") then return false end
  return true
end

local claim -- forward

local function renew_later(gen)
  _s.after(M.RENEW_MS, function()
    if not _s or gen ~= _s.gen or not _s.epoch then return end
    local scope, run, epoch = _s.scope, _s.run, _s.epoch
    _s.session.call("crew.renew", { scope, run, epoch }, function(_, err)
      if not _s or gen ~= _s.gen then return end
      if code(err) == M.CODE_STALE_EPOCH then
        local lost = _s.epoch
        _s.epoch = nil
        claim(lost)
        return
      end
      -- any other failure (the daemon gone, say) leaves the lease to the next renewal or reconnect
      renew_later(gen)
    end)
  end)
end

---claim takes the scope, or reattaches to it with this process's run token. lost is the epoch a
---stale renewal gave up, so a claim at another epoch says the agents moved.
claim = function(lost)
  if not _s or _s.claiming or _s.dormant then return end
  if not serves_crew() then return end
  _s.claiming = true
  local before = _s.epoch or lost
  _s.session.call("crew.claim", { _s.scope, _s.run, _s.proc }, function(res, err)
    _s.claiming = false
    if err then
      local c = code(err)
      if c == M.CODE_METHOD_NOT_FOUND then
        _s.dormant = true -- an AutoDoc without crew: stay quiet
        return
      end
      if c == M.CODE_SCOPE_BUSY then
        if not _s.busy_said then
          _s.busy_said = true
          _s.notify(("Crew scope %s is held by another live Neovim: this one's agents stay unregistered until it's free."):format(_s.scope),
            vim.log.levels.WARN)
        end
      else
        _s.notify("Crew scope " .. _s.scope .. " could not be claimed: " .. message(err), vim.log.levels.WARN)
      end
      _s.gen = _s.gen + 1
      local gen = _s.gen
      _s.after(M.RENEW_MS, function()
        if _s and gen == _s.gen and not _s.epoch then claim(before) end
      end)
      return
    end
    local epoch = type(res) == "table" and tonumber(res.epoch) or nil
    if not epoch then
      _s.notify("Crew scope " .. _s.scope .. ": the daemon answered crew.claim without an epoch", vim.log.levels.WARN)
      return
    end
    _s.busy_said = false
    if before and epoch ~= before then
      _s.notify(("This Neovim lost its crew scope %s while away and claimed it again (epoch %d): agents registered before must register again.")
        :format(_s.scope, epoch), vim.log.levels.WARN)
    end
    _s.epoch = epoch
    _s.gen = _s.gen + 1
    _s.publish(M.TOPIC_CLAIMED, { scope = _s.scope, epoch = epoch, reattached = before == epoch })
    renew_later(_s.gen)
  end)
end

---release gives the scope up, waiting at most RELEASE_WAIT_MS: a clean exit lets a successor claim
---it at once, and its run can't reattach after.
function M.release()
  if not _s or not _s.epoch then return end
  local scope, run, epoch = _s.scope, _s.run, _s.epoch
  _s.epoch = nil
  _s.gen = _s.gen + 1
  local done = false
  _s.session.call("crew.release", { scope, run, epoch }, function() done = true end)
  _s.wait(M.RELEASE_WAIT_MS, function() return done end)
end

---setup starts holding the scope. opts (all optional, for tests): session (autodoc.session), events
---(auto-core.events), env, project_key, notify, after(ms, fn), wait(ms, cond), proc.
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  local scope = M.scope_id(opts.env or vim.env, opts.project_key)
  if not scope then return false end
  M.stop()
  _s = {
    session = opts.session, -- else autodoc.session, resolved when first needed
    scope = scope,
    run = M.run_token(),
    proc = opts.proc or M.proc_ref(),
    epoch = nil,
    gen = 0,
    claiming = false,
    dormant = false,
    notify = opts.notify or function(msg, level) vim.notify(msg, level, { title = "auto-agents" }) end,
    after = opts.after or function(ms, fn) vim.defer_fn(fn, ms) end,
    wait = opts.wait or function(ms, cond) vim.wait(ms, cond, 20) end,
    publish = function() end,
    subs = {},
  }
  local events = opts.events
  if events == nil then
    local ok, ev = pcall(require, "auto-core.events")
    events = ok and ev or false
  end
  _s.events = events or nil
  if events then
    _s.publish = function(topic, payload) pcall(events.publish, topic, payload) end
    pcall(events.register_topics, "auto-agents", {
      [M.TOPIC_CLAIMED] = { doc = "This Neovim holds its crew scope in the AutoDoc daemon.",
        payload = "{ scope = string, epoch = integer, reattached = boolean }", publishers = { "auto-agents" } },
    })
    -- every connection to the daemon claims or reattaches; a lost one leaves the scope to the lease
    table.insert(_s.subs, events.subscribe("autodoc.session:connected", function()
      _s.dormant = false
      claim()
    end))
  end
  _s.augroup = vim.api.nvim_create_augroup("auto-agents.crew", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = _s.augroup, callback = function() M.release() end })
  local sess = session()
  if sess and sess.is_ready and sess.is_ready() then claim() end
  return true
end

---stop forgets the scope without releasing it (tests, a reload): its lease lapses on its own.
function M.stop()
  if not _s then return end
  for _, sub in ipairs(_s.subs or {}) do
    if _s.events then pcall(_s.events.unsubscribe, sub) end
  end
  if _s.augroup then pcall(vim.api.nvim_del_augroup_by_id, _s.augroup) end
  _s = nil
end

return M
