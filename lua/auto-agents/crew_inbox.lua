---The human's crew inbox in Neovim (ADR 1793271500 §4.8): decision requests, reports and permission
---prompts the AutoDoc daemon holds for the user, shown here and answered from here, with no AutoDoc
---window open.
---
---One inbox.watch long-poll per Neovim, as each AutoDoc window holds one (tui/crewinbox.go): the
---open set is the daemon's snapshot, read again after every change that can alter it, so a lost
---change or a reconnect never leaves a stale entry. What the user is told follows a diff against
---the set this Neovim already knows: the first snapshot is a silent baseline but for one line, and
---the known set outlives a reconnect, so a daemon restart announces nothing already known.
---
---Subjects and bodies are a peer's text: shown only (a notice, the pick list, a read-only float),
---each line inert, never typed into a terminal and never run. The inbox verbs are the user's
---(LocalPeer, no credential): no crew scope is needed to watch or answer.
---@module 'auto-agents.crew_inbox'

local M = {}

M.WAIT_MS = 25000 -- one inbox.watch's longest wait (the daemon's own cap)
M.RETRY_MS = 5000 -- the wait after a failed watch, doubling with each failure in a row
M.RETRY_MAX_MS = 60000
M.SUBJECT_MAX = 120 -- a subject's length in a notice or the pick list
M.FROM_MAX = 24

M.CODE_ALREADY_ANSWERED = -32130
M.CODE_NOT_A_REQUEST = -32131
M.CODE_EXPIRED = -32132
M.CODE_KEY_REUSED = -32133
M.CODE_TOO_LARGE = -32134
local CODE_METHOD_NOT_FOUND = -32601
local CODE_INVALID_PARAMS = -32602
local CODE_ACCESS_DENIED = -32001

local WARN, INFO = vim.log.levels.WARN, vim.log.levels.INFO

-- the change kinds after which the open set may differ: read the snapshot again
local REREAD = { request = true, report = true, answered = true, dismissed = true, read = true, expired = true,
  attention = true, cleared = true }

---inert is s as one plain line: every control character (ESC, CR, LF, BEL, TAB …) a space, runs of
---space one, at most max bytes (cut on a character boundary, "..." marking the cut).
---@param s any
---@param max integer|nil
---@return string
function M.inert(s, max)
  s = tostring(s or ""):gsub("%c", " "):gsub("%s+", " ")
  s = vim.trim(s)
  if max and #s > max then
    s = s:sub(1, max - 3):gsub("[\192-\255][\128-\191]*$", "") .. "..."
  end
  return s
end

local function code(err) return type(err) == "table" and err.code or nil end
local function message(err)
  if type(err) == "table" then return tostring(err.message or err.code) end
  return tostring(err)
end

---why is a refused answer or dismissal, said plainly.
local function why(err)
  local c = code(err)
  if c == M.CODE_ALREADY_ANSWERED then return "already answered: " .. M.inert(message(err), 200) end
  if c == M.CODE_EXPIRED then return "the request expired before it was answered" end
  if c == M.CODE_NOT_A_REQUEST then return "that is no request to you" end
  if c == M.CODE_TOO_LARGE then return "the reply is past 64 KiB" end
  return M.inert(message(err), 200)
end

---label is an entry's line in the pick list.
---@param it table an entry of requests(), reports() or attention()
function M.label(it)
  if it.kind == "attention" then
    return ("[waiting] %s: %s"):format(M.inert(it.codename, M.FROM_MAX), M.inert(it.text, M.SUBJECT_MAX))
  end
  return ("[%s] %s: %s"):format(it.kind == "request" and "request" or "report", M.inert(it.from, M.FROM_MAX),
    M.inert(it.subject, M.SUBJECT_MAX))
end

local function random_key()
  local ok, bytes = pcall(vim.uv.random, 16)
  if ok and bytes then return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
  return ("%x%x"):format(os.time(), math.random(0, 0x7fffffff))
end

local function sorted(set)
  local out = {}
  for _, it in pairs(set) do out[#out + 1] = it end
  table.sort(out, function(a, b) return (a.seq or 0) < (b.seq or 0) or ((a.seq or 0) == (b.seq or 0) and a.id < b.id) end)
  return out
end

local Inbox = {}
Inbox.__index = Inbox

---new is an inbox on opts.session (autodoc.session, resolved when first needed). opts.notify(msg,
---level), opts.after(ms, fn), opts.focus(session) → whether this Neovim raised that session's
---agent, opts.redraw() (the winbar), opts.schedule(fn) (vim.schedule).
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    sess = opts.session,
    notify = opts.notify or function(msg, level) vim.notify(msg, level, { title = "auto-agents" }) end,
    after = opts.after or function(ms, fn) vim.defer_fn(fn, ms) end,
    focus = opts.focus or function() return false end,
    redraw = opts.redraw or function() end,
    schedule = opts.schedule or vim.schedule,
    gen = 0, -- bumped by each connection: an earlier connection's loop stops
    cursor = 0,
    retry = 0,
    refused_said = false,
    parts = nil, -- a snapshot's pages read so far
    known = false, -- whether a first snapshot set the baseline
    open = { requests = {}, reports = {}, attention = {} }, -- the known set: outlives a connection
    keys = {}, -- a reply's idempotency key, by request and text
  }, Inbox)
end

function Inbox:session()
  if self.sess then return self.sess end
  local ok, mod = pcall(require, "autodoc.session")
  if ok then self.sess = mod end
  return self.sess
end

---serves is whether the connected daemon answers inbox.watch.
function Inbox:serves()
  local sess = self:session()
  local c = sess and sess.client and sess.client()
  if not c then return false end
  return not c.can or c:can("inbox.watch")
end

---connected starts the watch for a new connection; the loop of any earlier one stops.
function Inbox:connected()
  self.gen = self.gen + 1
  self.cursor, self.retry, self.parts = 0, 0, nil
  if self:serves() then self:watch(self.gen, "") end
end

function Inbox:stop() self.gen = self.gen + 1 end

---watch asks for what changed after the cursor, or a snapshot (cursor 0, or page, its next part).
---Everything its answer does runs scheduled, never in the connection's callback.
function Inbox:watch(gen, page)
  local asked = self.cursor
  local params = { asked, M.WAIT_MS }
  if page ~= "" then params[3] = page end
  self:session().call("inbox.watch", params, function(res, err)
    self.schedule(function()
      if gen ~= self.gen then return end -- a newer connection's loop runs
      self:answered(gen, asked, page, res, err)
    end)
  end)
end

function Inbox:answered(gen, asked, page, res, err)
  if err or type(res) ~= "table" then
    local c = code(err)
    if c == CODE_METHOD_NOT_FOUND then return end -- a daemon before the inbox: the next connection asks again
    if c == CODE_INVALID_PARAMS or c == CODE_ACCESS_DENIED then
      if not self.refused_said then
        self.refused_said = true
        self.notify("the crew inbox is refused by the daemon: " .. M.inert(message(err), 200), WARN)
      end
      return -- asking again changes nothing: the next connection asks again
    end
    local wait = math.max(self.retry, M.RETRY_MS)
    self.retry = math.min(2 * wait, M.RETRY_MAX_MS)
    self.after(wait, function()
      if gen ~= self.gen then return end
      if page ~= "" then self.cursor = 0 end -- a snapshot's part, its page perhaps gone: afresh
      self:watch(gen, "")
    end)
    return
  end
  self.retry = 0
  local snap = res.snapshot
  if type(snap) == "table" then
    if page == "" then
      self.parts = { items = {}, attention = {} }
      self.cursor = tonumber(res.cursor) or 0
    end
    self.parts = self.parts or { items = {}, attention = {} }
    for _, it in ipairs(type(snap.items) == "table" and snap.items or {}) do table.insert(self.parts.items, it) end
    for _, a in ipairs(type(snap.attention) == "table" and snap.attention or {}) do table.insert(self.parts.attention, a) end
    if type(snap.next) == "string" and snap.next ~= "" then
      return self:watch(gen, snap.next) -- the snapshot's next part, at its first page's cursor
    end
    local parts = self.parts
    self.parts = nil
    self:show(parts)
    return self:watch(gen, "")
  end
  if asked == 0 and page == "" then self:show({ items = {}, attention = {} }) end -- an empty journal
  self.cursor = tonumber(res.cursor) or self.cursor
  local again = false
  for _, ch in ipairs(type(res.changes) == "table" and res.changes or {}) do
    local kind = type(ch) == "table" and ch.kind or nil
    if REREAD[kind] then
      again = true
    elseif kind == "focus" then
      self.focus(ch.ref) -- the user asked for this agent: raised when it is this Neovim's
    end -- fallback changes are this Neovim's crew host's (crew.lua), not the inbox's
  end
  if again then self.cursor = 0 end
  self:watch(gen, "")
end

---show makes the known set the snapshot p's, telling the user what changed against it.
function Inbox:show(p)
  local now = { requests = {}, reports = {}, attention = {} }
  for i, it in ipairs(p.items) do
    if type(it) == "table" and type(it.message) == "string" then
      local e = { id = it.message, kind = it.kind == "request" and "request" or "report", from = it.from, subject = it.subject,
        body = it.body, session = it.session, seq = tonumber(it.seq) or i }
      if it.kind == "request" then now.requests[e.id] = e elseif it.kind == "message" then now.reports[e.id] = e end
    end
  end
  for i, a in ipairs(p.attention) do
    if type(a) == "table" and type(a.session) == "string" then
      now.attention[a.session] = { id = a.session, kind = "attention", what = a.kind, session = a.session,
        codename = a.codename, text = a.text, owner = a.owner, seq = i }
    end
  end
  local was = self.open
  self.open = now
  if not self.known then
    self.known = true
    self:baseline()
  else
    for id, e in pairs(now.requests) do
      if not was.requests[id] then
        self.notify(("%s asks: %s (:AutoAgentsInbox to answer)"):format(M.inert(e.from, M.FROM_MAX),
          M.inert(e.subject, M.SUBJECT_MAX)), WARN)
      end
    end
    for id, e in pairs(was.requests) do
      if not now.requests[id] then
        self.notify(("%s's request is closed: %s"):format(M.inert(e.from, M.FROM_MAX), M.inert(e.subject, M.SUBJECT_MAX)), INFO)
      end
    end
    for id, e in pairs(now.reports) do
      if not was.reports[id] then
        self.notify(("%s reports: %s"):format(M.inert(e.from, M.FROM_MAX), M.inert(e.subject, M.SUBJECT_MAX)), INFO)
      end
    end
    for id, a in pairs(now.attention) do
      local before = was.attention[id]
      if not before or before.what ~= a.what then
        local who, text = M.inert(a.codename, M.FROM_MAX), M.inert(a.text, M.SUBJECT_MAX)
        if a.what == "permission" then
          self.notify(("%s waits on a permission prompt: %s"):format(who, text), WARN)
        elseif a.what == "blocked" then
          self.notify(("%s is blocked: %s"):format(who, text), WARN)
        else
          self.notify(("%s waits (%s): %s"):format(who, M.inert(a.what, 24), text), INFO)
        end
      end
    end
    for id, a in pairs(was.attention) do
      if not now.attention[id] then self.notify(("%s no longer waits"):format(M.inert(a.codename, M.FROM_MAX)), INFO) end
    end
  end
  self.redraw()
end

---baseline tells the user, in one line, what was open when the inbox was first read.
function Inbox:baseline()
  local function n(set)
    local k = 0
    for _ in pairs(set) do k = k + 1 end
    return k
  end
  local parts = {}
  local function add(k, one, many) if k > 0 then parts[#parts + 1] = ("%d %s"):format(k, k == 1 and one or many) end end
  local prompts = 0
  for _, a in pairs(self.open.attention) do if a.what == "permission" or a.what == "blocked" then prompts = prompts + 1 end end
  add(n(self.open.requests), "request", "requests")
  add(prompts, "agent prompt", "agent prompts")
  add(n(self.open.reports), "report", "reports")
  if #parts > 0 then
    self.notify(("%s wait%s: :AutoAgentsInbox"):format(table.concat(parts, ", "), #parts == 1 and parts[1]:match("^1 ") and "s" or ""), INFO)
  end
end

function Inbox:requests() return sorted(self.open.requests) end
function Inbox:reports() return sorted(self.open.reports) end
function Inbox:attention() return sorted(self.open.attention) end

---count is what waits on the user: the open requests and the agents on a permission prompt.
function Inbox:count()
  local k = 0
  for _ in pairs(self.open.requests) do k = k + 1 end
  for _, a in pairs(self.open.attention) do if a.what == "permission" then k = k + 1 end end
  return k
end

local function answer(self, verb, params, cb)
  self:session().call(verb, params, function(res, err)
    self.schedule(function()
      if err then cb(why(err)) else cb(nil, res) end
    end)
  end)
end

---reply answers request id with body: the first answer wins. The key is bound to the request and
---the text, so a retry after a lost answer is the same reply.
function Inbox:reply(id, body, cb)
  local k = id .. "\0" .. body
  self.keys[k] = self.keys[k] or random_key()
  answer(self, "inbox.reply", { id, body, self.keys[k] }, cb or function() end)
end

---dismiss declines request id; its sender is told.
function Inbox:dismiss(id, cb) answer(self, "inbox.dismiss", { id }, cb or function() end) end

---ack marks report id read.
function Inbox:ack(id, cb) answer(self, "inbox.ack", { id }, cb or function() end) end

---raise asks session's current owner, wherever it is, to raise its agent.
function Inbox:raise(session, cb) answer(self, "inbox.focus", { session }, cb or function() end) end

-- ── the winbar, the body and the pick list ──────────────────────────────────

---winbar_segment is the panel winbar's "!N": the count alone, clicking it opens the inbox.
function M.winbar_segment(n)
  n = tonumber(n) or 0
  if n <= 0 then return "" end
  return ("%%0@v:lua.require'auto-agents.crew_inbox'.click@%%#AutoAgentsInbox# !%d %%*%%X"):format(n)
end

function M.click() vim.schedule(M.pick) end

---show_body shows an entry's text in a read-only float, as plain text: never markdown, no modeline.
---@return integer buf
function M.show_body(it)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modeline = false
  vim.bo[buf].bufhidden = "wipe"
  local lines = {
    "From: " .. M.inert(it.from or it.codename, 80),
    "Subject: " .. M.inert(it.subject or it.text, 400),
    "",
  }
  for line in (tostring(it.body or "") .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "text"
  vim.bo[buf].modifiable = false
  local width = math.min(100, math.max(40, vim.o.columns - 10))
  local height = math.min(#lines, math.max(5, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height, row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    title = " crew inbox ", title_pos = "center" })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return buf
end

-- the inbox of this Neovim: one, set up by M.setup
local _x

function M.count() return _x and _x:count() or 0 end

local function said(what)
  return function(err) _x.notify(err and (what .. " failed: " .. err) or (what .. ": done"), err and WARN or INFO) end
end

local function act(it)
  local actions
  if it.kind == "request" then
    actions = { "Reply…", "Dismiss", "Show" }
  elseif it.kind == "report" then
    actions = { "Show", "Mark read" }
  else
    actions = { "Raise its agent" }
  end
  vim.ui.select(actions, { prompt = M.label(it) }, function(choice)
    if choice == "Reply…" then
      vim.ui.input({ prompt = "Reply to " .. M.inert(it.from, M.FROM_MAX) .. ": " }, function(text)
        if text and vim.trim(text) ~= "" then _x:reply(it.id, text, said("the reply")) end
      end)
    elseif choice == "Dismiss" then
      _x:dismiss(it.id, said("the dismissal"))
    elseif choice == "Show" then
      M.show_body(it)
    elseif choice == "Mark read" then
      _x:ack(it.id, said("marking it read"))
    elseif choice == "Raise its agent" then
      if not _x.focus(it.session) then _x:raise(it.session, said("raising " .. M.inert(it.codename, M.FROM_MAX))) end
    end
  end)
end

---pick lists what waits for the user and acts on the one chosen.
function M.pick()
  if not _x then return vim.notify("the crew inbox isn't running", WARN, { title = "auto-agents" }) end
  local items = {}
  for _, it in ipairs(_x:requests()) do items[#items + 1] = it end
  for _, it in ipairs(_x:attention()) do items[#items + 1] = it end
  for _, it in ipairs(_x:reports()) do items[#items + 1] = it end
  if #items == 0 then return _x.notify("nothing waits in the crew inbox", INFO) end
  vim.ui.select(items, { prompt = "Crew inbox", format_item = M.label }, function(it) if it then act(it) end end)
end

---focus_session raises this Neovim's agent whose crew session is session.
function M.focus_session(session)
  local ok, aa = pcall(require, "auto-agents")
  if not ok or not aa.state then return false end
  for slot, term in pairs(aa.state.slot_terminals or {}) do
    local h = term and term.crew_session
    if h and h.session and h.session.id == session then
      aa.focus_slot(slot)
      return true
    end
  end
  return false
end

---setup starts this Neovim's inbox: a watch for each connection to the daemon, :AutoAgentsInbox.
---Quiet without AutoDoc. opts.events (auto-core.events), opts.session for a test.
function M.setup(opts)
  opts = opts or {}
  if _x then _x:stop() end
  _x = M.new({ session = opts.session, notify = opts.notify, focus = M.focus_session,
    redraw = function() pcall(vim.cmd, "redrawstatus!") end })
  pcall(vim.api.nvim_set_hl, 0, "AutoAgentsInbox", { link = "WarningMsg", default = true })
  vim.api.nvim_create_user_command("AutoAgentsInbox", function() M.pick() end,
    { desc = "The crew inbox: answer an agent's request, read its report" })
  local events = opts.events
  if events == nil then
    local ok, ev = pcall(require, "auto-core.events")
    events = ok and ev or nil
  end
  if events and events.subscribe then
    local x = _x
    events.subscribe("autodoc.session:connected", function() if _x == x then x:connected() end end)
  end
  local sess = _x:session()
  if sess and sess.is_ready and sess.is_ready() then _x:connected() end
  return true
end

return M
