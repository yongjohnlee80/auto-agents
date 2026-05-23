---Navigation dock — a small float on the rightmost edge, vertically
---centered, that lists every slot + the editor. One keystroke (e for
---editor, 0..9 for slot N) focuses the target and closes the dock.
---<Esc> closes without focusing anything.
---@module 'auto-agents.dock'

local M = {}

---@class AutoAgentsDockState
---@field winid integer|nil
---@field bufnr integer|nil
---@field prev_winid integer|nil
M._state = { winid = nil, bufnr = nil, prev_winid = nil }

---Determine the label rendered next to a slot. Pulls from
---agents.bootstrap when configured; falls back to "shell" / "(empty)".
---When the slot has reported a status (idle/waiting/working) via
---`:AutoAgentsStatus`, that status is appended in parens — explicit
---naming is more useful in the dock than the panel-strip's terse sigil
---because the dock shows full lines.
---@param slot integer
---@return string
local function slot_label(slot)
  local aa = require("auto-agents")
  local cfg = aa.state.config
  if not cfg then return "(empty)" end
  if slot == 0 then return "admin" end
  local bs = (cfg.agents or {}).bootstrap or {}
  for _, e in ipairs(bs) do
    if e.slot == slot then
      local label = e.title or e.name or e.kind or "agent"
      -- Defensive read — see winbar.lua slot_render for the rationale.
      local status = (aa.state.agent_status or {})[slot]
      if status then
        return label .. " (" .. status .. ")"
      end
      return label .. " (idle)"
    end
  end
  return "shell"
end

---Build the rendered lines + a parallel mapping table.
---@return string[] lines
---@return integer focused_idx  -- 1-based line index of currently focused slot
local function build_lines()
  local aa = require("auto-agents")
  local focused = aa.state.focused_slot or 1
  local in_panel = aa.state.panel_winid and vim.api.nvim_win_is_valid(aa.state.panel_winid)
    and vim.api.nvim_get_current_win() == aa.state.panel_winid

  -- Slots 0..MAX_SLOT (admin + main agents). Hardcoded 0..9 was a relic
  -- of the old two-tier model. Now `slot_count` is configurable
  -- (`slot add` / `slot remove`); the dock reflects what's actually
  -- available in the current session.
  local max_slot = aa.MAX_SLOT or 5
  local entries = {
    { key = "e", label = "editor", is_editor = true },
  }
  for s = 0, max_slot do
    table.insert(entries, { key = tostring(s), label = slot_label(s), slot = s })
  end

  local lines = {}
  local focused_idx = 1
  for i, e in ipairs(entries) do
    local marker
    if e.is_editor then
      marker = (not in_panel) and "[" or " "
    elseif in_panel and e.slot == focused then
      marker = "["
    else
      marker = " "
    end
    local close = marker == "[" and "]" or " "
    table.insert(lines, string.format("%s%s%s %s", marker, e.key, close, e.label))
    if marker == "[" then focused_idx = i end
  end
  return lines, focused_idx
end

---@return boolean
function M.is_open()
  return M._state.winid ~= nil and vim.api.nvim_win_is_valid(M._state.winid)
end

---Tear down the dock without restoring focus. Used when dispatching —
---the dispatch target's own focus call will land where it should.
local function cleanup_silent()
  if M._state.winid and vim.api.nvim_win_is_valid(M._state.winid) then
    pcall(vim.api.nvim_win_close, M._state.winid, true)
  end
  if M._state.bufnr and vim.api.nvim_buf_is_valid(M._state.bufnr) then
    pcall(vim.api.nvim_buf_delete, M._state.bufnr, { force = true })
  end
  M._state.winid = nil
  M._state.bufnr = nil
  M._state.prev_winid = nil
end

---Cancellation close (Esc/q) — restores focus to the invocation window.
function M.close()
  local prev = M._state.prev_winid
  cleanup_silent()
  if prev and vim.api.nvim_win_is_valid(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  end
end

---Predicate: is `winid` a regular editable file window? (i.e. not a
---panel, not a float, not neo-tree, not a special buftype).
local function is_editor_window(winid, panel_winid)
  if not vim.api.nvim_win_is_valid(winid) then return false end
  if winid == panel_winid then return false end
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative ~= nil and cfg.relative ~= "" then return false end
  local buf = vim.api.nvim_win_get_buf(winid)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  return true
end

local SKIPPABLE_FILETYPES = {
  ["neo-tree"] = true,
  ["NvimTree"] = true,
  ["oil"] = true,
  ["minifiles"] = true,
  ["aerial"] = true,
  ["Outline"] = true,
  ["trouble"] = true,
}

---Score a window for "is this a normal editing buffer?" Higher is
---better. Used to pick the most-editor-like window when dispatching
---to "e" — preferring non-tree, non-special buffers.
local function editor_score(winid)
  local buf = vim.api.nvim_win_get_buf(winid)
  local bt = vim.bo[buf].buftype
  local ft = vim.bo[buf].filetype
  if bt ~= "" then return 0 end           -- terminal / nofile / quickfix etc.
  if SKIPPABLE_FILETYPES[ft] then return 1 end
  return 2                                 -- regular file buffer (preferred)
end

---Focus a target. `key` is "e" (editor) or "0".."9" (slot). Tears down
---the dock first (without restoring focus to the invocation window) so
---the focus call's destination wins. This avoids a flicker through the
---editor that would trigger the float auto-hide for sub-agent slots.
---@param key string
function M.dispatch(key)
  cleanup_silent()
  if key == "e" then
    local panel = require("auto-agents").state.panel_winid
    local best, best_score = nil, -1
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if is_editor_window(w, panel) then
        local s = editor_score(w)
        if s > best_score then
          best, best_score = w, s
        end
      end
    end
    if best then
      pcall(vim.api.nvim_set_current_win, best)
      -- If the dock was invoked from a terminal slot, terminal mode
      -- auto-exited when focus moved to the dock float — but the editor
      -- can still inherit insert mode through some focus paths. Force
      -- normal mode for editor destinations.
      vim.cmd("stopinsert")
    end
    return
  end
  local slot = tonumber(key)
  if slot and slot >= 0 and slot <= 9 then
    require("auto-agents").focus_slot(slot)
  end
end

---Open the dock float.
function M.open()
  if M.is_open() then
    M.close()
    return
  end

  M._state.prev_winid = vim.api.nvim_get_current_win()

  local lines, focused_idx = build_lines()
  -- Width adapts to the longest line so "(working)" / "(waiting)"
  -- suffixes don't get clipped on agents with longer names. Floor at
  -- 22 (the previous fixed width) so it doesn't shrink below comfort.
  local max_len = 22
  for _, l in ipairs(lines) do
    if #l > max_len then max_len = #l end
  end
  local width = max_len + 1
  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "auto-agents-dock"
  vim.api.nvim_buf_set_name(buf, "auto-agents://dock")

  local row = math.max(0, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, vim.o.columns - width - 1)

  local winid = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " nav ",
    title_pos = "center",
    focusable = true,
    zindex = 200,
  })
  vim.api.nvim_win_set_cursor(winid, { focused_idx, 0 })
  -- ADR 0028: `scope = "local"` is required so this write does NOT
  -- mutate the global-local default for `cursorline`. The other
  -- appearance options (`number`, `relativenumber`, `signcolumn`)
  -- previously written here are already set to the right values by
  -- `style = "minimal"` above — repeating them was both redundant
  -- AND the mechanism by which the dock leaked panel defaults into
  -- subsequent editor windows. They have been removed.
  vim.api.nvim_set_option_value("cursorline", true, { win = winid, scope = "local" })

  -- Force normal mode on entry. The F6/F12 keymaps that open the dock
  -- are bound on `n`+`t` modes; when invoked from a terminal-insert
  -- agent buffer, the `<cmd>...<cr>` mapping preserves the source
  -- mode through the command. Even though the dock buffer is
  -- non-terminal/nomodifiable, nvim can carry an "insert intent" that
  -- only resolves on the next mode-changing event — so the user has
  -- to press <Esc> before single-keystroke dispatch keys (0-9, e)
  -- fire. Explicit stopinsert here is the canonical fix and matches
  -- the pattern dispatch() already uses on the editor path (line 170).
  vim.cmd("stopinsert")

  M._state.winid = winid
  M._state.bufnr = buf

  -- Single-keystroke dispatch.
  local keys = { "e", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  for _, k in ipairs(keys) do
    vim.keymap.set("n", k, function() M.dispatch(k) end, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q",     function() M.close() end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>",  function()
    -- Enter on the cursor line acts on whichever entry is highlighted.
    local idx = vim.api.nvim_win_get_cursor(winid)[1]
    -- index 1 is editor; 2..11 are slots 0..9
    if idx == 1 then M.dispatch("e")
    else M.dispatch(tostring(idx - 2)) end
  end, { buffer = buf, nowait = true, silent = true })

  -- Auto-close when the dock loses focus (e.g. user clicks elsewhere).
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function() vim.schedule(M.close) end,
  })
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

---Re-render the dock buffer in place. No-op when the dock isn't open.
---Lets status transitions update labels live without forcing the user
---to close+reopen the float.
function M.refresh()
  if not M.is_open() then return end
  local buf = M._state.bufnr
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local lines = build_lines()
  pcall(function()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end)
end

return M
