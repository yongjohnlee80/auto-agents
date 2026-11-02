---auto-agents.fallback: a delivery the crew couldn't get received, typed into its agent's terminal,
---once (auto-agents v0.4.0, with the file mailbox retired).
---
---Two senders hand it deliveries:
---  * AutoDoc's fallback jobs (mail.fallbacks, auto-agents.crew): mail an agent didn't receive in
---    time comes back to its host, this Neovim;
---  * auto-core's todo notifier (set_fallback): an assignment notice no crew wake could land.
---
---Each delivery has a key (the job's id, the notice's message id) and is typed at most once per key,
---across a Neovim restart too: the key is written to a file in Neovim's state folder BEFORE the text
---is typed, so a restart (or a crash after the write) finds it and types nothing. A crash between
---the write and the typing loses that one delivery's typing rather than typing it twice: at most
---once. A key whose typing was refused (no terminal) is taken back, since nothing was typed.
---
---The text is one line: auto-agents.sanitize strips every control (line breaks included) and caps
---it, and a line starting with `[`, `/` or `$` is prefixed, since Codex takes a leading `[` as a
---queued entry and opens a path popup on a leading `/` or `$VAR`. It is typed as one bracketed
---paste followed by a bare Enter (never Esc, which would cancel an agent mid-turn): an agent mid-turn
---gets it as queued input, whole.
---
---@module 'auto-agents.fallback'

local M = {}

M.MAX_TEXT = 4000 -- characters typed for one delivery
M.MAX_KEYS = 2000 -- keys kept in the state file; older ones are dropped
M.PREFIX = "AutoDoc: " -- before a line that would start with a hazard

---@type table<string, boolean>|nil
local _seen -- the keys typed, loaded from the state file on first use
---@type string[]
local _order = {} -- the same keys, oldest first, as the file keeps them

---The state file holding the typed keys, one per line.
---@return string
function M.state_file()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "auto-agents", "fallback-typed")
end

local function load()
  if _seen then return _seen end
  _seen, _order = {}, {}
  local f = io.open(M.state_file(), "r")
  if f then
    for line in f:lines() do
      if line ~= "" and not _seen[line] then
        _seen[line] = true
        _order[#_order + 1] = line
      end
    end
    f:close()
  end
  return _seen
end

local function save()
  local keys = vim.tbl_filter(function(k) return _seen[k] end, _order)
  if #keys > M.MAX_KEYS then
    for i = 1, #keys - M.MAX_KEYS do _seen[keys[i]] = nil end
    keys = vim.list_slice(keys, #keys - M.MAX_KEYS + 1)
  end
  _order = keys
  local path = M.state_file()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
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

---type_once types text into codename's terminal, once for key. Answers true when it is typed, or was
---before (this run or an earlier one); false and why when it can't be: no key or text, no slot runs
---codename, its terminal won't take it, or the key can't be kept.
---@param codename string the agent's name in this Neovim's roster
---@param key string the delivery's stable id
---@param text string
---@return boolean ok, string|nil why
function M.type_once(codename, key, text)
  if type(key) ~= "string" or key == "" or key:find("[\r\n]") then return false, "no key" end
  local line = M.line(text)
  if not line then return false, "nothing to type" end
  local seen = load()
  if seen[key] then return true end
  local aa = require("auto-agents")
  local slot = aa.slot_for_name(codename)
  if not slot then return false, ("no slot runs %s"):format(tostring(codename)) end
  seen[key] = true
  _order[#_order + 1] = key
  if not save() then
    seen[key] = nil
    return false, "can't keep the key in " .. M.state_file()
  end
  if not aa.send_slot(slot, line, { submit = true, submit_keys = { "<CR>" } }) then
    seen[key] = nil -- nothing was typed: it may be typed later
    save()
    return false, ("slot %d's terminal didn't take it"):format(slot)
  end
  return true
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
  return M.type_once(name, delivery.key, text)
end

---attach hands the notifier its fallback, at setup; detach takes it back.
function M.attach()
  local ok, notifier = pcall(require, "auto-core.todo.notifier")
  if ok and type(notifier.set_fallback) == "function" then notifier.set_fallback(M.notifier_handler) end
end

function M.detach()
  local ok, notifier = pcall(require, "auto-core.todo.notifier")
  if ok and type(notifier.set_fallback) == "function" then notifier.set_fallback(nil) end
end

---Test seam: forget the loaded keys (the next use reads the state file again).
function M._reset_for_tests() _seen, _order = nil, {} end

return M
