---auto-agents.crew_gateway: the legacy mailbox's sender for cut-over recipients (ADR 1793271500
---phase 4e, §4.10).
---
---auto-core's router offers each outbox message to a gateway before its file move. For a recipient
---listed in `crew.cutover`, this one sends the message through the AutoDoc daemon instead, as the
---scope's `gateway` session (auto-agents.crew), so the recipient receives it as crew mail:
---
---  mail.send(gateway credential, { codename }, body, "legacy:<sender id>/<mid>", "message",
---            "[from <legacy from>] <subject>")
---
---The legacy `from` goes into the subject only, never into an identity. The key makes a retry the
---same message. Anything it can't send for sure stays on the file route: a recipient not cut over or
---not in the addressbook, a command or a response, no gateway session yet, a body past MaxBody.
---A send the daemon refuses for good (no recipient, too large, the key reused) is not retried: the
---next scan declines that message, and the file route delivers it. Nothing is lost either way.
---
---A message sent through the gateway stays the gateway's until the daemon answers it (Lector #5
---F1). Before its first send, a record naming it by its key is written under
---<cwd>/.auto-agents/crew/gateway-sent/: the key, the authority it was sent under (store, scope and
---the gateway's profile; the key dedups only under that one), its outbox file, and its state.
---  * sent, outcome unknown: it is sent again with the same key, under the same authority only.
---    With no gateway session, or another authority (the daemon swapped stores), it waits in the
---    outbox, never the file route, and says so once; `:AutoAgentsGatewayRelease` hands such a
---    message to the file route when the user decides it was not delivered.
---  * delivered: it is never sent again; the router archives its file, and the record goes once
---    the file is gone (a sweep at setup and after each delivery), so an archive that failed before
---    a restart still never takes the file route.
---  * refused for good: the record goes, and the file route delivers it.
---Within one authority, then, a message reaches the daemon at most once and is never also filed.
local M = {}

M.MAX_BODY = 64 * 1024

-- mail's refusals that no retry changes (core/mail/errors.go)
M.CODE_NO_RECIPIENT = -32110
M.CODE_KEY_REUSED = -32111
M.CODE_TOO_LARGE = -32112

local _s -- { cutover, call, crew, declined (keys), sent_dir, said (keys noticed), after, notify, router }

-- record_path is the path of the record naming a message sent through the gateway, by its key.
local function record_path(key)
  return vim.fs.joinpath(_s.sent_dir, vim.fn.sha256(key))
end

-- read_record is key's record, or nil.
local function read_record(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, r = pcall(vim.json.decode, text)
  return ok and type(r) == "table" and r or nil
end

-- write_record writes r for its key through a dot file renamed over it: false when it can't be
-- written (then a first send is not taken: nothing was sent yet).
local function write_record(r)
  local made = pcall(vim.fn.mkdir, _s.sent_dir, "p", tonumber("700", 8))
  if not made or vim.fn.isdirectory(_s.sent_dir) == 0 then return false end
  local path = record_path(r.key)
  local tmp = vim.fs.joinpath(_s.sent_dir, "." .. vim.fn.sha256(r.key) .. ".tmp")
  local fd = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then return false end
  local _, werr = vim.uv.fs_write(fd, vim.json.encode(r))
  vim.uv.fs_close(fd)
  if werr or not vim.uv.fs_rename(tmp, path) then
    vim.uv.fs_unlink(tmp)
    return false
  end
  return true
end

local function drop_record(key)
  vim.uv.fs_unlink(record_path(key))
end

local function same_authority(a, b)
  return a and b and a.store == b.store and a.scope == b.scope and a.profile == b.profile
end

---sweep removes the records of delivered messages whose outbox file is gone (archived).
function M.sweep()
  if not _s then return end
  for name in vim.fs.dir(_s.sent_dir) do
    if name:sub(1, 1) ~= "." then
      local r = read_record(vim.fs.joinpath(_s.sent_dir, name))
      if r and r.state == "delivered" and (not r.source or not vim.uv.fs_stat(r.source)) then
        vim.uv.fs_unlink(vim.fs.joinpath(_s.sent_dir, name))
      end
    end
  end
end

---held is the messages sent through the gateway whose outcome is unknown and that wait: their keys.
---@return string[]
function M.held()
  local out = {}
  if not _s then return out end
  for name in vim.fs.dir(_s.sent_dir) do
    local r = name:sub(1, 1) ~= "." and read_record(vim.fs.joinpath(_s.sent_dir, name)) or nil
    if r and r.state == "sent" then out[#out + 1] = r.key end
  end
  table.sort(out)
  return out
end

---release hands a waiting message to the file route, by its key ("all" for every one): the user's
---decision that the daemon never delivered it. Answers how many it released.
---@param which string
---@return integer
function M.release(which)
  local n = 0
  for _, key in ipairs(M.held()) do
    if which == "all" or which == key then
      drop_record(key)
      _s.declined[key] = true
      n = n + 1
    end
  end
  return n
end

---codename is the agent a legacy mailbox id names: agent:<name>[:<instance>] → <name>.
---@param id string|nil
---@return string|nil
function M.codename(id)
  if type(id) ~= "string" then return nil end
  return id:match("^agent:([^:]+)")
end

local function cut_over(codename)
  if _s.cutover == "*" then return true end
  return _s.cutover[codename] == true
end

local function body_of(msg)
  local b = msg.body
  if type(b) == "string" then return b end
  if b == nil then return "" end
  local ok, enc = pcall(vim.json.encode, b)
  return ok and enc or nil
end

-- gateway is the router's hook: fn(rec, mid, msg, done) -> took.
local function gateway(rec, mid, msg, done)
  local s = _s
  if not s or type(msg) ~= "table" then return false end
  if (msg.kind or "message") ~= "message" then return false end
  local key = "legacy:" .. tostring(rec.id) .. "/" .. tostring(mid)
  if s.declined[key] then return false end -- refused for good, or released: the file route delivers it
  local r = read_record(record_path(key))
  if r and r.state == "delivered" then
    done(nil) -- delivered before: only its file is left to archive
    s.after(2000, M.sweep)
    return true
  end
  local to = M.codename(msg.to)
  local body = body_of(msg)
  local cred = s.crew.gateway_credential()
  local who = s.crew.gateway_identity and s.crew.gateway_identity() or nil
  if not r then
    -- a first send: only when everything says the daemon can take it
    if not to or not cut_over(to) or not s.crew.in_addressbook(to) then return false end
    if not cred or not who then return false end
    if not body or #body > M.MAX_BODY then return false end
    local source = rec.subs and rec.subs.outbox and (rec.subs.outbox .. "/" .. mid .. ".json") or nil
    r = { key = key, state = "sent", store = who.store, scope = who.scope, profile = who.profile, source = source }
    if not write_record(r) then return false end
  elseif not cred or not to or not body or not same_authority(r, who) then
    -- sent before, its outcome unknown, and no session of the authority it was sent under: it waits
    if not s.said[key] then
      s.said[key] = true
      s.notify(("A message sent through the crew gateway (%s) waits: its outcome on store %s is unknown. :AutoAgentsGatewayRelease hands it to the file mailbox if it was never delivered.")
        :format(key, tostring(r.store)), vim.log.levels.WARN)
    end
    done({ message = "sent through the crew gateway before, its outcome unknown: waiting for its own store's gateway session" })
    return true
  end
  local subject = ("[from %s] %s"):format(tostring(msg.from or rec.id), tostring(msg.subject or ""))
  s.call("mail.send", { cred, { to }, body, key, "message", subject }, function(_, err)
    if not err then
      r.state = "delivered" -- kept until its file is archived: a restart never files it again
      write_record(r)
      done(nil)
      s.after(2000, M.sweep)
      return
    end
    local c = type(err) == "table" and err.code or nil
    if c == M.CODE_NO_RECIPIENT or c == M.CODE_KEY_REUSED or c == M.CODE_TOO_LARGE then
      drop_record(key) -- the daemon holds nothing for it: the file route may deliver it
      s.declined[key] = true
    end
    done(err)
  end)
  return true
end

---setup installs the gateway on auto-core's router when `cutover` lists any recipient ("*" for
---all), and asks auto-agents.crew for the gateway session. Without a router that offers a gateway
---hook, or with nothing cut over, it installs nothing: the mailbox runs as before.
---@param opts { cutover: string[]|string|nil, cwd: string, router: table|nil, crew: table|nil, call: function|nil, sent_dir: string|nil, after: function|nil, notify: function|nil }
---@return boolean installed
function M.setup(opts)
  opts = opts or {}
  local cutover = opts.cutover
  local set
  if cutover == "*" then
    set = "*"
  elseif type(cutover) == "table" and #cutover > 0 then
    set = {}
    for _, name in ipairs(cutover) do set[name] = true end
  end
  local sent_dir = opts.sent_dir or vim.fs.joinpath(opts.cwd or vim.fn.getcwd(), ".auto-agents", "crew", "gateway-sent")
  if not set then
    -- nothing cut over now, but messages sent through the gateway before (a restart, the list
    -- emptied) are still the gateway's until the daemon answers them: it stays installed for those
    local any = false
    for name in vim.fs.dir(sent_dir) do
      if name:sub(1, 1) ~= "." then any = true break end
    end
    if not any then return false end
    set = {}
  end
  local router = opts.router
  if router == nil then
    local ok, r = pcall(require, "auto-core.mailbox.router")
    router = ok and r or nil
  end
  if not router or type(router.set_gateway) ~= "function" then return false end
  local crew = opts.crew or require("auto-agents.crew")
  local call = opts.call or function(method, params, cb)
    local ok, session = pcall(require, "autodoc.session")
    if not ok then return cb(nil, { message = "autodoc.session is not available" }) end
    session.call(method, params, cb)
  end
  _s = { cutover = set, call = call, crew = crew, declined = {}, router = router, sent_dir = sent_dir, said = {},
    after = opts.after or function(ms, fn) vim.defer_fn(fn, ms) end,
    notify = opts.notify or function(msg, level) vim.notify(msg, level, { title = "auto-agents" }) end }
  M.sweep()
  crew.enable_gateway(opts.cwd)
  router.set_gateway(gateway)
  return true
end

---stop removes the gateway: every message takes the file route again.
function M.stop()
  if _s and _s.router then pcall(_s.router.set_gateway, nil) end
  _s = nil
end

return M
