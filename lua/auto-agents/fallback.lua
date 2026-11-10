---auto-agents.fallback: a delivery the crew couldn't get received, typed into its agent's terminal,
---once (auto-agents v0.4.0, with the file mailbox retired).
---
---Two senders hand it deliveries:
---  * AutoDoc's fallback jobs (mail.fallbacks, auto-agents.crew): mail an agent didn't receive in
---    time comes back to its host, this Neovim;
---  * auto-core's todo notifier (set_fallback): an assignment notice no crew wake could land.
---
---Each delivery has a key (the job's id, the notice's message id) and is typed at most once per key,
---across a Neovim restart too: the key is written BEFORE the text is typed, so a restart (or a crash
---after the write) finds it and types nothing. A crash between the write and the typing loses that
---one delivery's typing rather than typing it twice: at most once. A key whose typing was refused
---(no terminal) is taken back, since nothing was typed.
---
---Every Neovim writes its keys to a file of its own (its crew incarnation's) in one folder, through a
---temporary file of its own, and never another's; whether a key was typed is read from every file
---there, fresh each time. So no Neovim erases another's keys, and a restart finds its predecessor's.
---No lock is shared: a key is offered to one host at a time (a fallback job is leased to the host
---running its agent; a notice names its Neovim's instance). The guarantee holds while a key is
---kept: the newest MAX_KEYS of each Neovim's, and files of other runs untouched for KEEP_DAYS.
---
---The text is one line: auto-agents.sanitize strips every control (line breaks included) and caps
---it, and a line starting with `[`, `/` or `$` is prefixed, since Codex takes a leading `[` as a
---queued entry and opens a path popup on a leading `/` or `$VAR`. It is typed as one bracketed
---paste followed by a bare Enter (never Esc, which would cancel an agent mid-turn): an agent mid-turn
---gets it as queued input, whole.
---
---A delivery is typed guarded, as AutoDoc's own window types one: never into an open prompt. While
---its agent's session shows the user a prompt (a permission prompt, an AskUserQuestion dialog), a
---paste or an Enter would answer it, so nothing is typed and no key kept: the job's lease lapses and
---its next offer is typed once the prompt has closed (a todo notice is held by the notifier). When
---nothing reports the agent's prompts, the line is pasted with no Enter, for the user to send. A
---guarded Enter is pressed only once the state is read again after the paste, and a key's line keeps
---whether its Enter was pressed, so a re-offer or a restart reports what really came of it.
---
---@module 'auto-agents.fallback'

local M = {}

M.MAX_TEXT = 4000 -- characters typed for one delivery
M.MAX_KEYS = 2000 -- keys kept in a Neovim's own file; older ones are dropped
M.KEEP_DAYS = 7 -- another run's file untouched this long is removed
M.PREFIX = "AutoDoc: " -- before a line that would start with a hazard
M.SUBMIT_DELAY_MS = 60 -- between a guarded paste and its Enter, once the state is read again

---@type string[]|nil
local _mine -- this Neovim's own key lines, oldest first, as its file keeps them

-- A key's line is the bare key once its text was sent (typed with its Enter: every line written
-- before the guard was), or "<key>\ttyped_not_sent" while it is in the agent's input without one:
-- written so BEFORE a guarded paste, so a restart mid-decision reads it as not sent, and rewritten
-- bare only once its Enter was pressed.
M.NOT_SENT = "typed_not_sent"

local function parse(line)
  local key, state = line:match("^([^\t]+)\t(.+)$")
  if key then return key, state end
  return line, "sent"
end

local function line_of(key, state)
  if state == M.NOT_SENT then return key .. "\t" .. M.NOT_SENT end
  return key
end

---The deferral a guarded Enter waits on (a test seam).
M._after = function(ms, fn) vim.defer_fn(fn, ms) end

---The folder holding every Neovim's typed keys, a file each.
---@return string
function M.state_dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "auto-agents", "fallback-typed.d")
end

---This Neovim's own file of typed keys, one per line.
---@return string
function M.state_file()
  return vim.fs.joinpath(M.state_dir(), require("auto-agents.crew").incarnation())
end

local function read_keys(path, into)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    if line ~= "" then
      local k, state = parse(line)
      into[k] = state
    end
  end
  f:close()
end

-- typed is what came of key when this Neovim or any other typed it ("sent", or typed_not_sent: in
-- the input, never sent), nil when nobody did, read from every file now; the one-file store of
-- auto-agents before v0.4.0 counts too. Another run's file untouched for KEEP_DAYS goes.
local function typed(key)
  local seen = {}
  for _, line in ipairs(_mine or {}) do
    local k, state = parse(line)
    seen[k] = state
  end
  local dir, own = M.state_dir(), M.state_file()
  local old = os.time() - M.KEEP_DAYS * 86400
  for name, kind in vim.fs.dir(dir) do
    local path = vim.fs.joinpath(dir, name)
    if kind == "file" and name:sub(1, 1) ~= "." and path ~= own then
      local st = vim.uv.fs_stat(path)
      if st and st.mtime.sec < old then
        vim.uv.fs_unlink(path)
      else
        read_keys(path, seen)
      end
    end
  end
  read_keys(vim.fs.joinpath(vim.fs.dirname(dir), "fallback-typed"), seen)
  return seen[key]
end

local function load_mine()
  if _mine then return _mine end
  _mine = {}
  local seen = {}
  local f = io.open(M.state_file(), "r")
  if f then
    for line in f:lines() do
      if line ~= "" and not seen[line] then
        seen[line] = true
        _mine[#_mine + 1] = line
      end
    end
    f:close()
  end
  return _mine
end

-- forget drops key's lines from this Neovim's own (nothing of it was typed).
local function forget(key)
  _mine = vim.tbl_filter(function(line) return (parse(line)) ~= key end, _mine)
end

-- save writes this Neovim's keys to its own file through its own temporary file.
local function save()
  local keys = _mine
  if #keys > M.MAX_KEYS then keys = vim.list_slice(keys, #keys - M.MAX_KEYS + 1) end
  _mine = keys
  local path = M.state_file()
  vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
  local tmp = vim.fs.joinpath(vim.fs.dirname(path), "." .. vim.fs.basename(path) .. ".tmp")
  if vim.fn.writefile(keys, tmp) ~= 0 then return false end
  return vim.uv.fs_rename(tmp, path) == true
end

---The one line a delivery is typed as.
---@param text any
---@return string|nil
function M.line(text)
  local s = require("auto-agents.sanitize").sanitize(text, M.MAX_TEXT)
  if not s then return nil end
  if s:match("^[%[/%$]") then s = M.PREFIX .. s end
  return s
end

---prompt_state is whether codename's agent may be typed to now, as AutoDoc's own window decides it
---(its submitter): "waits" while its session shows the user a prompt (a permission prompt, an
---AskUserQuestion dialog, blocked: the inbox's attention), where any key would answer it;
---"unreported" when nothing says whether one is open (a session registered without its prompts
---reported, a kind with no hooks, no inbox watching), where an Enter could approve one unseen;
---"clear" otherwise.
---@param codename string
---@return "waits"|"unreported"|"clear"
function M.prompt_state(codename)
  local s = require("auto-agents.crew").session_of(codename)
  if not s or s.prompts ~= true then return "unreported" end
  local waits = require("auto-agents.crew_inbox").waits_on_user(s.id)
  if waits == nil then return "unreported" end
  return waits and "waits" or "clear"
end

---type_once types text into codename's terminal, once for key. Answers true when it is typed, or was
---before (this run or an earlier one), with how: "sent" (its Enter pressed) or "typed_not_sent" (in
---the input, never sent), as the key's line keeps it; false and why when it can't be: no key or
---text, no slot runs codename, its terminal won't take it, or the key can't be kept.
---
---With opts.guard (a delivery to an agent, not a prompt the user asked for), it first asks
---prompt_state: while the agent waits on the user, nothing is typed and no key kept, so a later offer
---types it once the prompt has closed (false, why, "waits"); when its prompts aren't reported, the
---line is pasted with no Enter, for the user to send (typed_not_sent). When clear, the line is pasted
---with no Enter, and the Enter is pressed SUBMIT_DELAY_MS later only if the state is read clear again,
---for the same slot, terminal and session: a prompt that opened meanwhile would take it. Otherwise it
---stays typed_not_sent, never pasted again.
---
---opts.done(ok, why, how), when given, hears the outcome once it is settled (after that Enter's
---decision); the return is then only that the line was typed.
---@param codename string the agent's name in this Neovim's roster
---@param key string the delivery's stable id
---@param text string
---@param opts { guard: boolean|nil, done: fun(ok: boolean, why: string|nil, how: string|nil)|nil }|nil
---@return boolean ok, string|nil why, "sent"|"typed_not_sent"|"waits"|nil how
function M.type_once(codename, key, text, opts)
  local done = opts and opts.done
  local function finish(ok, why, how)
    if done then done(ok, why, how) end
    return ok, why, how
  end
  if type(key) ~= "string" or key == "" or key:find("[\r\n\t]") then return finish(false, "no key") end
  local line = M.line(text)
  if not line then return finish(false, "nothing to type") end
  local mine = load_mine()
  local was = typed(key)
  if was then return finish(true, nil, was) end
  local aa = require("auto-agents")
  local slot = aa.slot_for_name(codename)
  if not slot then return finish(false, ("no slot runs %s"):format(tostring(codename))) end
  local guard = opts and opts.guard
  local state = guard and M.prompt_state(codename) or "clear"
  -- NOTE: an open prompt takes any key as its answer, a paste's too: nothing is typed, nor its key
  -- kept, so the job's lease lapses and its next offer types it once the prompt has closed.
  if state == "waits" then return finish(false, ("%s waits on the user's answer to a prompt"):format(codename), "waits") end
  mine[#mine + 1] = line_of(key, guard and M.NOT_SENT or "sent")
  if not save() then
    forget(key)
    return finish(false, "can't keep the key in " .. M.state_file())
  end
  local send = { submit = true, submit_keys = { "<CR>" } }
  if guard then send = { submit = false } end -- a guarded Enter is decided below, never send_slot's
  if not aa.send_slot(slot, line, send) then
    forget(key) -- nothing was typed: it may be typed later
    save()
    return finish(false, ("slot %d's terminal didn't take it"):format(slot))
  end
  if not guard then return finish(true, nil, "sent") end
  if state == "unreported" then return finish(true, nil, M.NOT_SENT) end -- an Enter could approve a prompt unseen
  local term = aa.state and aa.state.slot_terminals and aa.state.slot_terminals[slot]
  local s = require("auto-agents.crew").session_of(codename)
  local session = s and s.id
  M._after(M.SUBMIT_DELAY_MS, function()
    local now = require("auto-agents.crew").session_of(codename)
    local same = aa.slot_for_name(codename) == slot and (now and now.id) == session
      and (not term or (aa.state.slot_terminals[slot] == term and term:is_alive()))
    -- NOTE: the state is read again at the Enter: a prompt opened since the paste would take it.
    if same and M.prompt_state(codename) == "clear" and aa.send_keypress(slot, "<CR>") then
      for i, l in ipairs(_mine) do
        if (parse(l)) == key then _mine[i] = key end -- sent now
      end
      save()
      finish(true, nil, "sent")
      return
    end
    finish(true, nil, M.NOT_SENT)
  end)
  return true -- typed; its Enter is decided once the delay is over
end

---notifier_handler is auto-core's todo-notifier fallback (set_fallback): delivery = { recipient =
---"agent:<name>[:<instance>]", key, subject, body }. A recipient of another Neovim's instance is
---refused: its own host types it.
---@param delivery table
---@return boolean ok, string|nil why
function M.notifier_handler(delivery)
  if type(delivery) ~= "table" or type(delivery.recipient) ~= "string" then return false, "no recipient" end
  local name, instance = delivery.recipient:match("^agent:([^:]+):?(.*)$")
  if not name then return false, "not an agent: " .. delivery.recipient end
  if instance ~= "" then
    local ok, inst = pcall(function() return require("auto-core.instance").id() end)
    if ok and inst ~= instance then return false, "another Neovim's agent" end
  end
  local text = delivery.body
  if type(delivery.subject) == "string" and delivery.subject ~= "" then
    text = delivery.subject .. ": " .. tostring(delivery.body or "")
  end
  -- an agent showing the user a prompt is held: the notifier asks again within its grace window
  return M.type_once(name, delivery.key, text, { guard = true })
end

---attach hands the notifier its fallback, at setup, and starts it; detach takes the fallback back.
---The host that sets the notifier's hooks starts it: since auto-core v0.6.0 only auto-core's setup
---starts it otherwise, and a consumer such as autovim never calls that setup, so no assignment was
---ever read. start is idempotent, waits for VimEnter, and keeps `vim.g.auto_core_todo_notifier =
---false` off.
function M.attach()
  local ok, notifier = pcall(require, "auto-core.todo.notifier")
  if not ok then return end
  if type(notifier.set_fallback) == "function" then notifier.set_fallback(M.notifier_handler) end
  if type(notifier.start) == "function" then
    local oks, err = pcall(notifier.start)
    if not oks then
      pcall(function() require("auto-agents.log").warn("fallback", "the todo notifier didn't start: " .. tostring(err)) end)
    end
  end
end

function M.detach()
  local ok, notifier = pcall(require, "auto-core.todo.notifier")
  if ok and type(notifier.set_fallback) == "function" then notifier.set_fallback(nil) end
end

---Test seam: forget the loaded keys (the next use reads the state file again).
function M._reset_for_tests() _mine = nil end

return M
