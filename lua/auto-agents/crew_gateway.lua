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
local M = {}

M.MAX_BODY = 64 * 1024

-- mail's refusals that no retry changes (core/mail/errors.go)
M.CODE_NO_RECIPIENT = -32110
M.CODE_KEY_REUSED = -32111
M.CODE_TOO_LARGE = -32112

local _s -- { cutover = set|"*", call = fn, crew = module, declined = set of "<rec.id>/<mid>" }

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
  if s.declined[key] then return false end -- refused for good once: the file route delivers it
  local to = M.codename(msg.to)
  if not to or not cut_over(to) or not s.crew.in_addressbook(to) then return false end
  local cred = s.crew.gateway_credential()
  if not cred then return false end
  local body = body_of(msg)
  if not body or #body > M.MAX_BODY then return false end
  local subject = ("[from %s] %s"):format(tostring(msg.from or rec.id), tostring(msg.subject or ""))
  s.call("mail.send", { cred, { to }, body, key, "message", subject }, function(_, err)
    if not err then return done(nil) end
    local c = type(err) == "table" and err.code or nil
    if c == M.CODE_NO_RECIPIENT or c == M.CODE_KEY_REUSED or c == M.CODE_TOO_LARGE then
      s.declined[key] = true
    end
    done(err)
  end)
  return true
end

---setup installs the gateway on auto-core's router when `cutover` lists any recipient ("*" for
---all), and asks auto-agents.crew for the gateway session. Without a router that offers a gateway
---hook, or with nothing cut over, it installs nothing: the mailbox runs as before.
---@param opts { cutover: string[]|string|nil, cwd: string, router: table|nil, crew: table|nil, call: function|nil }
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
  else
    return false
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
  _s = { cutover = set, call = call, crew = crew, declined = {}, router = router }
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
