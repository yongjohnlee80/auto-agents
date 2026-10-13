---auto-agents.mailbox.notices — the "ATTENTION: [auto-agents] …" lines typed
---into an agent's terminal when mail arrives, and the rules for NOT typing
---them (KB todo 2026-10-13, "no false check-your-inbox notifications").
---
---A notice interrupts both the agent and the user, so one is typed only when
---there is something unread to act on:
---
---  * inbox arrival   → typed, naming the real sender (`ctx.arrival_from`,
---                      auto-core's wake ctx) and the subject.
---  * responses/      → typed ONLY for an error response (`ok: false`, or a
---                      non-empty `code` / `error`), naming the command and
---                      the error, or for a response that cannot be read. A
---                      successful response is silent: an agent reads its own
---                      responses when it needs them.
---  * routing failure → typed to the SENDER (an unknown recipient, a rename
---                      or decode failure), once per message and reason. A
---                      successful routing is silent.
---  * `wake` command  → typed only when the target has unread inbox mail;
---                      otherwise silent, and the waker's response says so.
---
---Coalescing and staleness. A notice is not typed at arrival time. It waits
---`M.config.coalesce_ms` in a per-slot pending set; further arrivals for the
---slot fold into it, so a burst of N files types ONE line ("3 new inbox
---messages from A, B"). When the window closes, each pending item is checked
---again: an arrival whose file is gone (already read and archived) is
---dropped, and a generic wake is dropped when the inbox has nothing unread.
---If nothing survives, nothing is typed.
---
---The log keeps everything. Every notice, typed or suppressed, is written to
---the auto-core log (`:AutoCoreLog`) with the time, slot, kind, sender,
---subject, path and, for a suppressed one, the reason. Only the terminal
---interruption is removed.
---
---Terminal safety. Every field that comes from a message or envelope is
---sanitized before it is rendered (`safe_view`; renderers never see the raw
---item): ESC sequences, C0/DEL/C1 controls and invalid UTF-8 are removed, so
---nothing can close the bracketed paste, inject an escape sequence or submit
---early. Identity fields (sender, recipient, command, code, failure reason)
---must also be letters, digits and `:._-@/` within `M.MAX_ID`, or they render
---as `M.ID_PLACEHOLDER`; free text (subject, error) is capped at
---`config.max_text`. Codex (see `commands.lua` default_wake_nudge): every
---line leads with `ATTENTION:`, never `[` or `/`, and a path is only ever
---the last token.
---
---@module 'auto-agents.mailbox.notices'

local M = {}

M.config = {
  -- How long a notice waits for more arrivals before it is typed. Long
  -- enough to fold a burst and to let an agent that polls its own files
  -- archive them first; short enough to read as immediate.
  coalesce_ms = 1500,
  -- Cap on sender-supplied text (subject, error) inside a notice.
  max_text = 80,
}

local LOG_COMPONENT = "mailbox.notices"

---@type table<integer, { items: table[], keys: table<string, boolean>, timer: any, submit: boolean, agent: string? }>
local _pending = {}
---Routing failures already announced: key → outbox path (nil path = unverifiable).
---@type table<string, string|false>
local _undeliverable_seen = {}
local _undeliverable_sub

-- ── helpers ───────────────────────────────────────────────────

local function log()
  return require("auto-agents.log")
end

---@param v any
---@return string?
local function str(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

---Strip a mailbox id to its bare form ("agent:x:123-456" → "agent:x").
---@param id any
---@return string?
local function bare(id)
  id = str(id)
  if not id then return nil end
  local ok, core = pcall(require, "auto-core")
  if ok and core.mailbox and core.mailbox.path and core.mailbox.path.bare_id then
    local ok_b, b = pcall(core.mailbox.path.bare_id, id)
    if ok_b and str(b) then return b end
  end
  return id
end

---Strip everything a terminal could act on from `s`:
---  * ESC sequences (CSI `ESC [ … final`, OSC/DCS/APC/PM/SOS `ESC ] … BEL|ST`,
---    and any other `ESC x` pair), including the bracketed-paste end marker;
---  * C0 controls (NUL … US, so newline and CR) and DEL;
---  * C1 controls, both as UTF-8 (U+0080 … U+009F) and as raw 8-bit bytes;
---  * any byte that is not part of a valid UTF-8 sequence.
---Removed controls become a space; whitespace then collapses and trims.
---@param s string
---@return string
local function strip_controls(s)
  s = s:gsub("\27%[[\48-\63]*[\32-\47]*[\64-\126]?", " ")        -- CSI
       :gsub("\27[%]PX%^_][^\7\27]*\7", " ")                          -- OSC … BEL
       :gsub("\27[%]PX%^_][^\7\27]*\27\\", " ")                       -- OSC … ST
       :gsub("\27.?", " ")                                              -- any other ESC
  -- Walk UTF-8: keep valid printable sequences, drop C0/DEL/C1 and junk.
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1) or (b >= 0xC2 and b <= 0xDF and 2)
      or (b >= 0xE0 and b <= 0xEF and 3) or (b >= 0xF0 and b <= 0xF4 and 4) or nil
    local ok_seq = len ~= nil and i + len - 1 <= n
    if ok_seq and len > 1 then
      for k = i + 1, i + len - 1 do
        local c = s:byte(k)
        if c < 0x80 or c > 0xBF then ok_seq = false; break end
      end
    end
    if not ok_seq then
      out[#out + 1] = " "; i = i + 1
    else
      local ch = s:sub(i, i + len - 1)
      local cp1 = ch:byte(2)
      local is_c0 = len == 1 and (b < 0x20 or b == 0x7F)
      local is_c1 = len == 2 and b == 0xC2 and cp1 >= 0x80 and cp1 <= 0x9F
      out[#out + 1] = (is_c0 or is_c1) and " " or ch
      i = i + len
    end
  end
  s = table.concat(out)
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

---@param s string
---@param max integer
---@return string
local function cap(s, max)
  if vim.fn.strchars(s) > max then
    s = vim.fn.strcharpart(s, 0, max - 1) .. "…"
  end
  return s
end

---Free text from a message or envelope (subject, error): controls stripped,
---length capped. Every free-text field rendered into a notice goes through
---here.
---@param s any
---@param max integer?
---@return string?
function M.sanitize(s, max)
  if type(s) ~= "string" then return nil end
  s = strip_controls(s)
  if s == "" then return nil end
  return cap(s, max or M.config.max_text)
end

M.ID_PLACEHOLDER = "(unprintable)"
M.MAX_ID = 64

---An identity-like field from a message or envelope (sender, recipient,
---command, code, failure reason): controls stripped, then accepted only if it
---is made of letters, digits and `:._-@/` and fits `M.MAX_ID`; anything else
---becomes `M.ID_PLACEHOLDER`. nil / empty stays nil.
---@param s any
---@return string?
function M.sanitize_id(s)
  if type(s) ~= "string" or s == "" then return nil end
  local clean = strip_controls(s)
  if clean == "" or #clean > M.MAX_ID or not clean:match("^[%w:%._%-@/]+$") then
    return M.ID_PLACEHOLDER
  end
  return clean
end

---A host-built path (the router composes it, but the file name comes from
---whoever wrote the file): controls stripped, generously capped.
---@param s any
---@return string?
function M.sanitize_path(s)
  if type(s) ~= "string" then return nil end
  s = strip_controls(s)
  if s == "" then return nil end
  return cap(s, 512)
end

---The renderable view of an item: every externally sourced field, already
---sanitized. Rendering reads ONLY this view, never the raw item.
---@param item table
---@return table
local function safe_view(item)
  return {
    kind    = item.kind,
    from    = M.sanitize_id(item.from),
    to      = M.sanitize_id(item.to),
    command = M.sanitize_id(item.command),
    code    = M.sanitize_id(item.code),
    failure = M.sanitize_id(item.failure),
    subject = M.sanitize(item.subject),
    error   = M.sanitize(item.error),
    path    = M.sanitize_path(item.path),
  }
end

---@param path string?
---@return boolean
local function file_exists(path)
  if not str(path) then return false end
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

---True when `dir` holds at least one unread message file (`*.json`, not a
---dotfile / in-flight tmp file).
---@param dir string?
---@return boolean
function M.has_unread(dir)
  if not str(dir) then return false end
  local sd = vim.uv.fs_scandir(dir)
  if not sd then return false end
  while true do
    local name, t = vim.uv.fs_scandir_next(sd)
    if not name then return false end
    if (t == "file" or t == nil) and name:sub(1, 1) ~= "."
        and name:sub(-5) == ".json" then
      return true
    end
  end
end

---@param path string?
---@return table?
local function read_json(path)
  if not file_exists(path) then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local ok_d, doc = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok_d and type(doc) == "table" then return doc end
  return nil
end

---A response is an error when it says so (`ok: false`) or carries a
---non-empty `code` / `error`.
---@param ok_v any
---@param code any
---@param err_v any
---@return boolean
function M.is_error_response(ok_v, code, err_v)
  if ok_v == false then return true end
  if str(code) then return true end
  if str(err_v) then return true end
  if type(err_v) == "table" and next(err_v) ~= nil then return true end
  return false
end

---Agent name → its mailbox inbox dir, via auto-core's registry (bare ids
---resolve against this nvim's instance).
---@param name string?
---@return string?
local function inbox_dir_for(name)
  if not str(name) then return nil end
  local ok, core = pcall(require, "auto-core")
  if not ok or not core.mailbox or not core.mailbox.registry then return nil end
  local rec = core.mailbox.registry.get("agent:" .. name)
  return rec and rec.subs and rec.subs.inbox or nil
end

---Structured audit entry. `action` is "delivered", "suppressed",
---"queued" or "send_failed".
---@param action string
---@param slot integer?
---@param agent string?
---@param item table
---@param reason string?
---@param text string?
local function audit(action, slot, agent, item, reason, text)
  local fields = {
    at      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    action  = action,
    slot    = slot,
    agent   = agent,
    kind    = item.kind,
    from    = item.from,
    subject = item.subject,
    path    = item.path,
    command = item.command,
    code    = item.code,
    error   = item.error,
    to      = item.to,
    failure = item.failure,
    reason  = reason or item.note,
    text    = text,
  }
  reason = reason or item.note
  local msg = string.format("notice %s: slot=%s kind=%s from=%s%s",
    action, tostring(slot), tostring(item.kind), tostring(item.from),
    reason and (" reason=" .. reason) or "")
  local level = action == "send_failed" and "warn" or "info"
  pcall(log()[level], LOG_COMPONENT, msg, {
    event  = "auto-agents.mailbox.notice_" .. action,
    fields = fields,
  })
end
M._audit = audit

-- ── rendering ─────────────────────────────────────────────────

---Single inbox arrival: names the sender and subject, and ends with the
---file's path so the agent can Read it directly (ADR-0036).
---@param item table
---@return string
local function render_inbox_one(item)
  local subj = item.subject
  local head = string.format("ATTENTION: [auto-agents] new inbox from %s",
    item.from or "?")
  if subj then head = head .. " — " .. subj end
  if str(item.path) then
    return head .. " — read it with the Read tool: " .. item.path
  end
  return head .. " — check your inbox."
end

---@param item table
---@return string
local function describe_error(item)
  if item.kind == "response_unreadable" then
    return "a response could not be read"
  end
  if item.kind == "undeliverable" then
    local subj = item.subject
    return string.format("your message to %s was not delivered (%s)%s",
      item.to or "?", item.failure or "undeliverable",
      subj and (": " .. subj) or "")
  end
  local what = item.command and (item.command .. " failed") or "a command you sent failed"
  local detail = item.error
  if item.code and detail then
    return string.format("%s (%s): %s", what, item.code, detail)
  elseif item.code then
    return string.format("%s (%s)", what, item.code)
  elseif detail then
    return what .. ": " .. detail
  end
  return what
end

---Join a list of senders, de-duplicated, in arrival order.
---@param items table[]
---@return string
local function senders(items)
  local seen, out = {}, {}
  for _, it in ipairs(items) do
    local f = it.from or "?"
    if not seen[f] then seen[f] = true; out[#out + 1] = f end
  end
  return table.concat(out, ", ")
end

---Render the surviving items of one slot's pending set as ONE line.
---@param items table[]
---@return string
function M.render(items)
  local inbox, wakes, errors = {}, {}, {}
  for _, raw in ipairs(items) do
    local it = safe_view(raw)
    if it.kind == "inbox" then inbox[#inbox + 1] = it
    elseif it.kind == "wake" then wakes[#wakes + 1] = it
    else errors[#errors + 1] = it end
  end

  -- The common shapes keep the single-arrival wording (path last).
  if #errors == 0 and #inbox == 1 then
    return render_inbox_one(inbox[1])
  end
  if #errors == 0 and #inbox == 0 and #wakes > 0 then
    return require("auto-agents.mailbox.commands")
      .default_wake_nudge("inbox", senders(wakes))
  end
  if #inbox == 0 and #wakes == 0 and #errors == 1 then
    local e = errors[1]
    local tail = (e.kind == "undeliverable" and " — it is still in your outbox: ")
      or (e.kind == "response_unreadable" and ": ")
      or " — read it with the Read tool: "
    if str(e.path) then
      return "ATTENTION: [auto-agents] " .. describe_error(e) .. tail .. e.path
    end
    return "ATTENTION: [auto-agents] " .. describe_error(e) .. "."
  end

  -- A burst: one prose line, no paths.
  local parts = {}
  if #inbox > 0 then
    parts[#parts + 1] = string.format("%d new inbox %s from %s",
      #inbox, #inbox == 1 and "message" or "messages", senders(inbox))
  elseif #wakes > 0 then
    parts[#parts + 1] = "new inbox from " .. senders(wakes)
  end
  for _, e in ipairs(errors) do parts[#parts + 1] = describe_error(e) end
  return "ATTENTION: [auto-agents] " .. table.concat(parts, "; ")
    .. (#errors == 0 and " — check your inbox." or " — check your mailbox.")
end

-- ── the pending set ───────────────────────────────────────────

---Is the item still worth an interruption? Returns keep, reason.
---@param item table
---@return boolean, string?
local function still_relevant(item)
  if item.check == "path" then
    if file_exists(item.path) then return true end
    return false, item.kind == "undeliverable" and "no_longer_in_outbox"
      or "archived_before_delivery"
  elseif item.check == "any_unread" then
    if item.dir == nil or M.has_unread(item.dir) then return true end
    return false, "nothing_unread"
  end
  return true
end

---Close the window for `slot`: drop stale items, type one line for the rest.
---@param slot integer
---@return string? text  -- what was typed, or nil
function M.flush(slot)
  local p = _pending[slot]
  if not p then return nil end
  _pending[slot] = nil
  if p.timer then pcall(function() p.timer:stop(); p.timer:close() end) end

  local keep = {}
  for _, it in ipairs(p.items) do
    local relevant, why = still_relevant(it)
    if relevant then
      keep[#keep + 1] = it
    else
      audit("suppressed", slot, p.agent, it, why)
      if it.undeliverable_key then _undeliverable_seen[it.undeliverable_key] = nil end
    end
  end
  if #keep == 0 then return nil end

  local text = M.render(keep)
  local aa = require("auto-agents")
  -- A notice must never interrupt in-flight work: bare <CR>, no Esc (see
  -- commands.lua handle_wake, v0.2.45 follow-up #1).
  local sent = aa.send_slot(slot, text, { submit = p.submit, submit_keys = { "<CR>" } })
  local reason
  if not sent then reason = "terminal_unavailable"
  elseif #keep > 1 then reason = "coalesced" end
  for _, it in ipairs(keep) do
    audit(sent and "delivered" or "send_failed", slot, p.agent, it, reason, text)
  end
  return sent and text or nil
end

---Flush every pending slot now (tests; shutdown).
function M.flush_all()
  local slots = {}
  for s in pairs(_pending) do slots[#slots + 1] = s end
  table.sort(slots)
  local out = {}
  for _, s in ipairs(slots) do out[s] = M.flush(s) end
  return out
end

---Number of items waiting for `slot` (tests / diagnostics).
---@param slot integer
---@return integer
function M.pending_count(slot)
  local p = _pending[slot]
  return p and #p.items or 0
end

---Add `item` to `slot`'s pending notice, opening the window if needed.
---Items with the same key (the same file, or the same waker) fold into one.
---@param slot integer
---@param item table   -- { kind, from?, subject?, path?, command?, code?, error?, check?, dir? }
---@param opts { submit: boolean?, agent: string? }?
function M.enqueue(slot, item, opts)
  opts = opts or {}
  local p = _pending[slot]
  if not p then
    p = { items = {}, keys = {}, submit = false, agent = opts.agent }
    _pending[slot] = p
  end
  if opts.submit ~= false then p.submit = true end
  local key = item.path or (tostring(item.kind) .. "|" .. tostring(item.from))
  if p.keys[key] then
    audit("suppressed", slot, p.agent, item, "duplicate_of_pending")
    return
  end
  p.keys[key] = true
  p.items[#p.items + 1] = item
  audit("queued", slot, p.agent, item, #p.items > 1 and "coalescing" or nil)

  if not p.timer then
    local timer = vim.uv.new_timer()
    p.timer = timer
    timer:start(M.config.coalesce_ms, 0, vim.schedule_wrap(function()
      -- The window may already have been flushed (flush_all, a test).
      if _pending[slot] == p then M.flush(slot) end
    end))
  end
end

-- ── wake → item ───────────────────────────────────────────────

---Turn a `wake` invocation into a pending item, or a reason to stay silent.
---
---`ctx.reason == "mailbox_wake"` is auto-core's router hook for one arriving
---file; anything else is an explicit `wake` (an agent's command through the
---executioner, or the admin panel).
---
---Compatibility: against an auto-core that predates the arrival facts
---(`ctx.arrival_from`, `ctx.arrival_ok`, …) the file at `ctx.arrival_path` is
---read here instead; if it is unreadable the sender falls back to
---`ctx.mailbox`, the old behaviour.
---@param args table
---@param ctx  table?
---@return table? item, string? reason
function M.item_from_wake(args, ctx)
  ctx = type(ctx) == "table" and ctx or {}

  if ctx.reason == "mailbox_wake" then
    local kind = str(ctx.arrival_kind) or "inbox"
    local path = str(ctx.arrival_path)
    local have_facts = ctx.arrival_from ~= nil or ctx.arrival_ok ~= nil
      or ctx.arrival_read_error ~= nil or ctx.arrival_msg_kind ~= nil
    local doc
    if not have_facts and path then doc = read_json(path) end

    if path and not file_exists(path) then
      return nil, "archived_before_delivery"
    end

    if kind == "responses" then
      -- The file is there but could not be read or decoded (the router says
      -- so in arrival_read_error; an older router says nothing and our own
      -- read fails). That is not a success: say so, as an error notice.
      local unreadable = (have_facts and ctx.arrival_read_error ~= nil)
        or (not have_facts and doc == nil)
      if unreadable then
        return {
          kind    = "response_unreadable",
          note    = "response_unreadable",
          error   = ctx.arrival_read_error and tostring(ctx.arrival_read_error)
            or "unreadable",
          path    = path,
          check   = path and "path" or nil,
        }
      end
      local ok_v, code, err_v, command
      if have_facts then
        ok_v, code, err_v, command = ctx.arrival_ok, ctx.arrival_code,
          ctx.arrival_error, ctx.arrival_command
      else
        ok_v, code, err_v, command = doc.ok, doc.code, doc.error, doc.command
      end
      if not M.is_error_response(ok_v, code, err_v) then
        return nil, "response_ok"
      end
      local err_text = err_v
      if type(err_v) == "table" then
        err_text = str(err_v.message) or str(err_v.error) or vim.inspect(err_v)
      end
      return {
        kind    = "response_error",
        command = str(command),
        code    = str(code),
        error   = type(err_text) == "string" and err_text or nil,
        path    = path,
        check   = path and "path" or nil,
        from    = str(ctx.arrival_from_bare) or bare(ctx.arrival_from)
          or (doc and bare(doc.from)) or nil,
      }
    end

    local from = str(ctx.arrival_from_bare) or bare(ctx.arrival_from)
      or (doc and bare(doc.from)) or str(ctx.mailbox) or "?"
    local subject = str(ctx.arrival_subject) or (doc and str(doc.subject)) or nil
    -- The router only fires for inbox/ and responses/; anything else is
    -- treated as mail to read.
    return {
      kind    = "inbox",
      from    = from,
      subject = subject,
      path    = path,
      check   = path and "path" or nil,
    }
  end

  -- Explicit wake. The origin is whoever asked for it.
  local origin = str(ctx.sender_bare) or bare(ctx.sender)
    or (ctx.admin and "user") or str(ctx.mailbox) or "?"
  local dir = inbox_dir_for(args and args.slot)
  if dir and not M.has_unread(dir) then
    return nil, "nothing_unread", { kind = "wake", from = origin }
  end
  return { kind = "wake", from = origin, check = dir and "any_unread" or nil, dir = dir }
end

-- ── routing failures → the sender ─────────────────────────────

---`core.mailbox:outbox_undeliverable` handler: tell the SENDER, once per
---message and reason. The router retries an undeliverable file on every
---pass, so the same failure is published repeatedly; only the first types.
---@param payload table
function M.on_undeliverable(payload)
  if type(payload) ~= "table" then return end
  local from = bare(payload.from_full) or bare(payload.from)
  local item = {
    kind    = "undeliverable",
    from    = from,
    to      = bare(payload.to),
    subject = str(payload.subject),
    path    = str(payload.path),
    failure = str(payload.reason) or "undeliverable",
    error   = str(payload.error),
  }
  item.check = item.path and "path" or nil
  -- An auto-core that predates `subject` on this event: read it from the
  -- file still sitting in the outbox.
  if not item.subject and item.path then
    local doc = read_json(item.path)
    item.subject = doc and str(doc.subject) or nil
  end
  local key = table.concat({ tostring(payload.from_full or payload.from),
    tostring(payload.id), item.failure }, "|")
  item.undeliverable_key = key

  -- Forget announcements whose file has since left the outbox (delivered
  -- on retry, or removed), so the map stays bounded.
  for k, pth in pairs(_undeliverable_seen) do
    if pth and not file_exists(pth) then _undeliverable_seen[k] = nil end
  end
  if _undeliverable_seen[key] ~= nil then return end

  local name = from and from:match("^agent:(.+)$")
  local aa_ok, aa = pcall(require, "auto-agents")
  local slot = name and aa_ok and aa.slot_for_name(name) or nil
  if not slot then
    audit("suppressed", nil, name, item, "sender_has_no_slot")
    return
  end
  _undeliverable_seen[key] = item.path or false
  M.enqueue(slot, item, { agent = name })
end

---Subscribe to routing failures. Idempotent.
function M.attach()
  if _undeliverable_sub then return end
  pcall(function()
    log().register_events({
      "mailbox.notice_queued", "mailbox.notice_delivered",
      "mailbox.notice_suppressed", "mailbox.notice_send_failed",
    })
  end)
  local ok, core = pcall(require, "auto-core")
  if not ok or not core.events or type(core.events.subscribe) ~= "function" then return end
  _undeliverable_sub = core.events.subscribe("core.mailbox:outbox_undeliverable",
    function(p) pcall(M.on_undeliverable, p) end)
end

function M.detach()
  if not _undeliverable_sub then return end
  pcall(function() require("auto-core").events.unsubscribe(_undeliverable_sub) end)
  _undeliverable_sub = nil
end

---Test-only: drop every pending window and announcement.
function M._reset_for_tests()
  for _, p in pairs(_pending) do
    if p.timer then pcall(function() p.timer:stop(); p.timer:close() end) end
  end
  _pending = {}
  _undeliverable_seen = {}
  M.detach()
end

return M
