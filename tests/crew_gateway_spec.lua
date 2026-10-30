--- Tests for auto-agents.crew_gateway, the legacy mailbox's sender for cut-over recipients
--- (ADR 1793271500 phase 4e). Run with: nvim --headless -u NONE -l tests/crew_gateway_spec.lua
---
--- A fake router keeps the hook; a fake crew says which codenames the addressbook holds and
--- whether the gateway's credential is held; a fake call answers mail.send as the test says.
---   [1] nothing cut over, or a router without a gateway hook: nothing installed
---   [2] a cut-over recipient's message is sent as the gateway, keyed legacy:<sender>/<mid>, with
---       the legacy sender in the subject only; delivered means done(nil)
---   [3] what stays on the file route: a recipient not cut over or not in the addressbook, a
---       command, no gateway credential, a body past MaxBody
---   [4] a transient failure is done(err) and retried with the same key
---   [5] a refusal for good is done(err) once, then declined: the file route delivers it
---   [6] "*" cuts over every recipient; stop removes the hook

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

local gw = require("auto-agents.crew_gateway")

local function new_world(opts)
  opts = opts or {}
  local w = { calls = {}, book = opts.book or { gold = true, vision = true }, cred = "g1.secret", answer = {} }
  w.router = { set_gateway = function(fn) w.hook = fn end }
  w.crew = {
    enable_gateway = function(cwd) w.enabled = cwd end,
    gateway_credential = function() return w.cred end,
    in_addressbook = function(name) return w.book[name] == true end,
  }
  w.call = function(method, params, cb)
    w.calls[#w.calls + 1] = { method = method, params = vim.deepcopy(params) }
    local a = w.answer[method]
    local res, err
    if type(a) == "function" then res, err = a(params) else res, err = a, nil end
    cb(res, err)
  end
  w.answer["mail.send"] = { message = {} }
  w.installed = gw.setup({ cutover = opts.cutover == nil and { "gold" } or opts.cutover, cwd = "/proj",
    router = opts.router or w.router, crew = w.crew, call = w.call })
  -- offer runs the hook as auto-core's router does: took, and what done was given
  w.offer = function(rec, mid, msg)
    local settled, gerr = false, nil
    local took = w.hook and w.hook(rec, mid, msg, function(e) settled, gerr = true, e end) or false
    return took, settled, gerr
  end
  return w
end

local rec = { id = "agent:jarvis:123-4" }
local function msg(over)
  return vim.tbl_extend("force", { kind = "message", from = "agent:jarvis:123-4", to = "agent:gold:123-4", subject = "hi",
    body = "hello" }, over or {})
end

-- ── [1] nothing installed ───────────────────────────────────────────────────

do
  local w = new_world({ cutover = {} })
  ok("[1] nothing cut over: no hook, no gateway session asked", not w.installed and w.hook == nil and w.enabled == nil)
  gw.stop()
  local w2 = new_world({ router = {} })
  ok("[1] a router without set_gateway: nothing installed", not w2.installed and w2.hook == nil)
  gw.stop()
end

-- ── [2] sent as the gateway ─────────────────────────────────────────────────

do
  local w = new_world()
  ok("[2] a cut-over list installs the hook and asks for the gateway session", w.installed and w.hook ~= nil
    and w.enabled == "/proj")
  local took, settled, gerr = w.offer(rec, "m1", msg())
  local p = w.calls[1] and w.calls[1].params or {}
  ok("[2] the message is taken and delivered: done(nil)", took == true and settled and gerr == nil)
  ok("[2] mail.send(credential, {codename}, body, key, message, subject)",
    w.calls[1].method == "mail.send" and p[1] == "g1.secret" and vim.deep_equal(p[2], { "gold" }) and p[3] == "hello"
      and p[4] == "legacy:agent:jarvis:123-4/m1" and p[5] == "message", vim.inspect(p))
  ok("[2] the legacy sender is in the subject only", p[6] == "[from agent:jarvis:123-4] hi", p[6])
  w.offer(rec, "m2", msg({ body = { a = 1 } }))
  ok("[2] a table body is sent as its JSON", w.calls[2].params[3] == vim.json.encode({ a = 1 }))
  gw.stop()
end

-- ── [3] the file route ──────────────────────────────────────────────────────

do
  local w = new_world()
  local cases = {
    { "a recipient not cut over", msg({ to = "agent:vision:1" }) },
    { "a command", msg({ kind = "command", to = "agent:gold:1" }) },
    { "a response", msg({ kind = "response" }) },
    { "a body past MaxBody", msg({ body = string.rep("x", gw.MAX_BODY + 1) }) },
    { "an address that names no agent", msg({ to = "user" }) },
  }
  for i, c in ipairs(cases) do
    local took = w.offer(rec, "f" .. i, c[2])
    ok("[3] " .. c[1] .. " stays on the file route", took == false)
  end
  w.book.gold = nil
  ok("[3] a recipient not in the addressbook stays on the file route", w.offer(rec, "f9", msg()) == false)
  w.book.gold = true
  w.cred = nil
  ok("[3] no gateway credential: the file route", w.offer(rec, "f10", msg()) == false)
  ok("[3] none of them was sent", #w.calls == 0)
  gw.stop()
end

-- ── [4] transient ───────────────────────────────────────────────────────────

do
  local w = new_world()
  w.answer["mail.send"] = function() return nil, { message = "connection lost" } end
  local took, settled, gerr = w.offer(rec, "t1", msg())
  ok("[4] a transient failure is taken, then done(err): the file stays for the next scan",
    took and settled and gerr ~= nil)
  w.answer["mail.send"] = { message = {} }
  local took2, _, gerr2 = w.offer(rec, "t1", msg())
  ok("[4] the next scan sends it again, with the same key, and it is delivered",
    took2 and gerr2 == nil and #w.calls == 2 and w.calls[1].params[4] == w.calls[2].params[4])
  gw.stop()
end

-- ── [5] refused for good ────────────────────────────────────────────────────

for _, code in ipairs({ gw.CODE_NO_RECIPIENT, gw.CODE_TOO_LARGE, gw.CODE_KEY_REUSED }) do
  local w = new_world()
  w.answer["mail.send"] = function() return nil, { code = code, message = "refused" } end
  local took, settled, gerr = w.offer(rec, "r1", msg())
  local took2 = w.offer(rec, "r1", msg())
  ok(("[5] refused (%d): done(err) once, then declined, so the file route delivers it"):format(code),
    took and settled and gerr ~= nil and took2 == false and #w.calls == 1)
  ok(("[5] refused (%d): another message is still sent"):format(code), w.offer(rec, "r2", msg()) == true)
  gw.stop()
end

-- ── [6] "*" and stop ────────────────────────────────────────────────────────

do
  local w = new_world({ cutover = "*" })
  ok("[6] \"*\" cuts over every recipient in the addressbook", w.offer(rec, "s1", msg({ to = "agent:vision:9" })) == true)
  gw.stop()
  ok("[6] stop removes the hook", w.hook == nil)
end

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
