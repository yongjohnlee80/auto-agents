--- Tests for auto-agents.crew's crew send (phase 7, ADR 1793489028 §4.7): the todo notifier's hook
--- (auto-core notifier.set_crew_recipient), which sends an assignment through AutoDoc's crew, as the
--- user, under this Neovim's claim (inbox.send, never rung), keyed by the notifier's message id. Run with:
---   nvim --headless -u NONE -l tests/crew_send_spec.lua
---
--- A fake autodoc.session holds the claim; the verb calls (crew_send's rpc) and the notifier are fakes.
---   [1] setup registers crew_send as the notifier's crew hook, stop clears it; an auto-core without
---       the hook is left alone
---   [2] with no scope held, nothing is asked (nil)
---   [3] a scoped assignment is sent by the bare name: scope, run, epoch, the name, body, mid as the
---       key, kind, subject, never rung (fire false: queued and woken as any mail); sent is true
---   [4] handed over (the recipient's host carries it) is true
---   [5] every certain refusal is false (the file notice); any other answer is "retry"
---   [6] an unscoped assignment goes only to the one live profile of its name, by name@scope; none,
---       or two projects' live agents, is false and sends nothing; an offline profile doesn't count;
---       a crew.list with no outcome is "retry"

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
  local w = { calls = {}, rpcs = {}, rpc_answer = {}, subs = {}, hook = "unset" }
  w.client = {
    can = function() return true end,
    hello = function() return { store_id = "store-1", protocol = 41 } end,
    addr = function() return "/run/autodoc.sock" end,
  }
  w.session = {
    is_ready = function() return opts.held ~= false end,
    client = function() return w.client end,
    call = function(method, params, cb)
      w.calls[#w.calls + 1] = { method = method, params = vim.deepcopy(params) }
      if method == "crew.claim" then return cb({ epoch = 5 }, nil) end
      cb({}, nil)
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
  -- the notifier: set_crew_recipient records the hook (false: an auto-core without it)
  if opts.notifier == false then
    w.notifier = {}
  else
    w.notifier = { set_crew_recipient = function(fn) w.hook = fn end }
  end
  -- the verb calls crew_send makes from inside the notifier's daemon.run
  w.rpc = function(method, params)
    w.rpcs[#w.rpcs + 1] = { method = method, params = vim.deepcopy(params) }
    local a = w.rpc_answer[method]
    if type(a) == "function" then return a(params) end
    return a, nil
  end
  w.of = function(method)
    local out = {}
    for _, c in ipairs(w.rpcs) do if c.method == method then out[#out + 1] = c end end
    return out
  end
  w.rpc_answer["inbox.send"] = { message = "m1" }
  assert(crew.setup({
    session = w.session, events = w.events, env = { AUTOVIM_PROJECT = "alpha" }, project_key = "k1", proc = "",
    notify = function() end,
    after = function() end,
    wait = function(_, cond) return cond() end,
    rpc = w.rpc,
    notifier = w.notifier,
  }))
  return w
end

local MSG = { kind = "message", subject = "[todos] task assigned to you: T", body = "You have been assigned a task." }
local MID = "todo-store-1-42"

-- ── cells ───────────────────────────────────────────────────────────────────

do
  local w = new_world()
  ok("[1] setup registers crew_send as the notifier's crew hook", w.hook == crew.crew_send, tostring(w.hook))
  crew.stop()
  ok("[1] stop clears it", w.hook == nil, tostring(w.hook))
  local w2 = new_world({ notifier = false })
  ok("[1] an auto-core without the hook is left alone", w2.hook == "unset" and crew.held() ~= nil, tostring(w2.hook))
end

do
  local w = new_world({ held = false })
  ok("[2] with no scope held, nothing is asked", crew.crew_send("vision", MID, MSG) == nil and #w.rpcs == 0,
    vim.inspect(w.rpcs))
end

do
  local w = new_world()
  local got = crew.crew_send("vision", MID, MSG, { unscoped = false })
  local p = (w.of("inbox.send")[1] or {}).params or {}
  -- never rung: rung, a send no wake reaches right now is refused for certain, and the notifier then
  -- files it in the file inbox (Johno's live test, an assignment to a cut-over agent); unrung, the
  -- daemon queues it and wakes the agent as any mail, and a stopped one gets its host's fallback
  ok("[3] a scoped assignment is sent by the bare name, under the claim, keyed by mid, never rung",
    got == true and p[1] == "autovim:alpha" and type(p[2]) == "string" and #p[2] > 0 and p[3] == 5
      and type(p[4]) == "table" and p[4][1] == "vision" and #p[4] == 1 and p[5] == MSG.body and p[6] == MID
      and p[7] == MSG.kind and p[8] == MSG.subject and p[9] == false and #w.of("crew.list") == 0,
    vim.inspect({ got = got, p = p }))
  ok("[3] a three-argument call (an auto-core before how) is scoped", crew.crew_send("vision", MID, MSG) == true
    and #w.of("crew.list") == 0)
end

do
  local w = new_world()
  w.rpc_answer["inbox.send"] = function() return nil, { code = crew.CODE_HANDED_OVER, message = "handed over" } end
  ok("[4] handed over is accepted: the recipient's host carries it", crew.crew_send("vision", MID, MSG) == true)
end

do
  local w = new_world()
  local refused = {
    unreachable = crew.CODE_UNREACHABLE, no_recipient = crew.CODE_NO_RECIPIENT, ambiguous = crew.CODE_AMBIGUOUS,
    key_reused = crew.CODE_KEY_REUSED, inbox_key_reused = crew.CODE_INBOX_KEY_REUSED,
    too_large = crew.CODE_TOO_LARGE, stale_epoch = crew.CODE_STALE_EPOCH,
    method_not_found = crew.CODE_METHOD_NOT_FOUND,
  }
  local wrong = {}
  for name, c in pairs(refused) do
    w.rpc_answer["inbox.send"] = function() return nil, { code = c, message = name } end
    local got = crew.crew_send("vision", MID, MSG)
    if got ~= false then wrong[name] = got end
  end
  ok("[5] every certain refusal is false: the notifier files its notice", next(wrong) == nil, vim.inspect(wrong))
  w.rpc_answer["inbox.send"] = function() return nil, { code = -32000, message = "connection lost" } end
  ok("[5] any other answer is retry: the notifier asks again with the same mid",
    crew.crew_send("vision", MID, MSG) == "retry")
  w.rpc_answer["inbox.send"] = function() return nil, { message = "no code" } end
  ok("[5] … an answer with no code too", crew.crew_send("vision", MID, MSG) == "retry")
end

do
  local w = new_world()
  local U = { unscoped = true }
  w.rpc_answer["crew.list"] = {
    { codename = "vision", scope = "autovim:beta", presence = "live" },
    { codename = "vision", scope = "autovim:gamma", presence = "offline" },
    { codename = "jarvis", scope = "autovim:alpha", presence = "live" },
  }
  local got = crew.crew_send("vision", MID, MSG, U)
  local sends = w.of("inbox.send")
  ok("[6] unscoped: the one live profile of the name, by name@scope (the offline one doesn't count)",
    got == true and #sends == 1 and sends[1].params[4][1] == "vision@autovim:beta", vim.inspect({ got = got, sends = sends }))
  w.rpcs = {}
  w.rpc_answer["crew.list"] = {
    { codename = "vision", scope = "autovim:beta", presence = "live" },
    { codename = "vision", scope = "autovim:alpha", presence = "live" },
  }
  got = crew.crew_send("vision", MID, MSG, U)
  ok("[6] two projects' live agents of the name: not sent, and nothing asked of inbox.send",
    got == false and #w.of("inbox.send") == 0, vim.inspect({ got = got, rpcs = w.rpcs }))
  w.rpcs = {}
  w.rpc_answer["crew.list"] = { { codename = "jarvis", scope = "autovim:alpha", presence = "live" } }
  got = crew.crew_send("vision", MID, MSG, U)
  ok("[6] no live profile of the name: not sent", got == false and #w.of("inbox.send") == 0, vim.inspect(got))
  w.rpcs = {}
  w.rpc_answer["crew.list"] = function() return nil, { code = -32000, message = "connection lost" } end
  got = crew.crew_send("vision", MID, MSG, U)
  ok("[6] a crew.list with no outcome is retry", got == "retry" and #w.of("inbox.send") == 0, vim.inspect(got))
  w.rpc_answer["crew.list"] = function() return nil, { code = crew.CODE_METHOD_NOT_FOUND, message = "unknown method" } end
  got = crew.crew_send("vision", MID, MSG, U)
  ok("[6] a crew.list refused for certain is not sent", got == false and #w.of("inbox.send") == 0, vim.inspect(got))
end

crew.stop()
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
