---Playground terminals T1..T4 (M6).
---
---These are shared floating shells — distinct from agent slots.
---The user keeps interactive REPLs / build watchers / scratch shells
---here; agents can dispatch commands into them via `term send <N>`.
---
---Persistence across `:cd` is the headline feature: snacks normally
---hashes its terminal id from `(cmd, cwd, env, count)`, so a worktree
---change re-hashes and spawns a duplicate. We sidestep that with our
---own buffer-local marker `b:auto_agents_term_slot` and look up by
---marker before falling through to `Snacks.terminal.get/toggle`. So
---the same `T1` follows you across `:cd`.
---
---Adapted from the user's `utils/term_send.lua` (vendored under
---auto-agents now). The send() path preserves the paste-safe split
---(body via `chan_send`, then a 60ms-deferred `\r`) so TUIs treat
---the body as paste and the CR as a typed submit keypress.
---
---@module 'auto-agents.term'

local M = {}

M.MAX_SLOTS = 4
M.MARKER    = "auto_agents_term_slot"

local SLOT_TITLES = {
  [1] = " Terminal 1 ",
  [2] = " Terminal 2 ",
  [3] = " Terminal 3 ",
  [4] = " Terminal 4 ",
}

---Window options for slot N. Cascading offsets so simultaneous
---T1+T2+T3+T4 don't perfectly stack and obscure each other.
---@param slot integer
---@return table
local function win_opts(slot)
  return {
    width = 0.76,
    height = 0.76,
    row = 0.02 + ((slot - 1) * 0.025),
    col = 0.04 + ((slot - 1) * 0.03),
    title = SLOT_TITLES[slot] or (" Terminal " .. slot .. " "),
    title_pos = "center",
  }
end

local function validate_slot(slot)
  slot = tonumber(slot)
  if not slot or slot < 1 or slot > M.MAX_SLOTS or slot ~= math.floor(slot) then
    error(("term: slot must be an integer in 1..%d, got %s"):format(
      M.MAX_SLOTS, tostring(slot)))
  end
  return slot
end

---Find an existing T-terminal for a slot via our buffer-local marker.
---Bypasses Snacks's cwd/env-keyed hashing so :cd doesn't spawn a
---duplicate when the user re-presses Fn from another worktree.
---@param slot integer
---@return table|nil  -- snacks Terminal object
local function find_slot_terminal(slot)
  if not (Snacks and Snacks.terminal) then return nil end
  for _, term in ipairs(Snacks.terminal.list()) do
    local buf = term.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      if vim.b[buf][M.MARKER] == slot then return term end
    end
  end
  return nil
end

---Stamp a freshly-created snacks terminal so `find_slot_terminal`
---can recognize it later. Idempotent.
---@param term table|nil
---@param slot integer
---@return table|nil
local function stamp_slot(term, slot)
  if term and term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    vim.b[term.buf][M.MARKER] = slot
  end
  return term
end

---Get (or create, if `opts.create ~= false`) the terminal for a slot.
---@param slot integer
---@param opts table|nil  -- { create = boolean }
---@return table|nil  -- snacks Terminal
function M.get(slot, opts)
  slot = validate_slot(slot)
  opts = opts or {}
  local term = find_slot_terminal(slot)
  if term or opts.create == false then return term end
  if not (Snacks and Snacks.terminal) then return nil end
  return stamp_slot(Snacks.terminal.get(vim.o.shell, {
    count = slot,
    create = true,
    win = win_opts(slot),
  }), slot)
end

---Toggle visibility of slot N. Persistent across :cd because we
---look up the existing buffer by marker before deferring to snacks.
---@param slot integer
---@return table|nil
function M.toggle(slot)
  slot = validate_slot(slot)
  local existing = find_slot_terminal(slot)
  if existing then return existing:toggle() end
  if not (Snacks and Snacks.terminal) then return nil end
  return stamp_slot(Snacks.terminal.toggle(vim.o.shell, {
    count = slot,
    win = win_opts(slot),
  }), slot)
end

---Find the snacks-tracked window currently displaying a slot's buffer.
---@param slot integer
---@return integer|nil winid
function M.find_win(slot)
  local term = find_slot_terminal(slot)
  if not (term and term.buf and vim.api.nvim_buf_is_valid(term.buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == term.buf then return win end
  end
  return nil
end

---Stop the slot's process and wipe its buffer. Next `M.get` returns
---a fresh shell.
---@param slot integer
---@return boolean killed
function M.kill(slot)
  slot = validate_slot(slot)
  local term = find_slot_terminal(slot)
  if not term then return false end
  if type(term.close) == "function" then pcall(term.close, term) end
  if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    pcall(vim.api.nvim_buf_delete, term.buf, { force = true })
  end
  return true
end

---Hide every visible T1..T4 float without killing them. Scoped — only
---touches floats with our marker. Other snacks floats (lazygit,
---lazysql, etc.) are not touched. Agent floats (slots 6-9, marker
---`auto_agents_slot`) are not touched.
function M.hide_all()
  if not (Snacks and Snacks.terminal) then return end
  for _, term in ipairs(Snacks.terminal.list()) do
    if term.buf and vim.api.nvim_buf_is_valid(term.buf)
      and vim.b[term.buf][M.MARKER] ~= nil then
      if type(term.hide) == "function" then
        pcall(term.hide, term)
      else
        pcall(term.toggle, term)
      end
    end
  end
end

---Slot summary for `term list`.
---@return { slot: integer, alive: boolean, visible: boolean, focused: boolean, bufnr: integer|nil }[]
function M.list()
  local cur_win = vim.api.nvim_get_current_win()
  local out = {}
  for slot = 1, M.MAX_SLOTS do
    local term = find_slot_terminal(slot)
    local visible_win
    if term and term.buf and vim.api.nvim_buf_is_valid(term.buf) then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == term.buf then visible_win = w; break end
      end
    end
    table.insert(out, {
      slot = slot,
      alive = term ~= nil,
      visible = visible_win ~= nil,
      focused = visible_win == cur_win,
      bufnr = term and term.buf or nil,
    })
  end
  return out
end

---Send `text` to slot N's stdin. Paste-safe split: writes the body,
---defers 60ms, then writes `\r` so TUIs (claude, codex, ratatui,
---prompt-toolkit) classify the body as paste and the CR as a typed
---submit keypress. Pass `opts.submit = false` to omit the trailing
---CR (useful for staging a prompt the user finishes manually).
---
---@param slot integer
---@param text string
---@param opts table|nil  -- { submit = boolean, show = boolean }
---@return boolean ok
function M.send(slot, text, opts)
  slot = validate_slot(slot)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then
    error("term.send: text must be a non-empty string")
  end

  local term = M.get(slot, { create = true })
  if not term then return false end

  if opts.show ~= false and type(term.show) == "function" then
    pcall(term.show, term)
  end

  local chan = vim.b[term.buf].terminal_job_id
  if not chan then return false end

  vim.api.nvim_chan_send(chan, text)
  if opts.submit == false then return true end

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(term.buf) then
      local ch = vim.b[term.buf].terminal_job_id
      if ch then vim.api.nvim_chan_send(ch, "\r") end
    end
  end, 60)
  return true
end

return M
