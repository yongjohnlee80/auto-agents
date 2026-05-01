---Focus / hide / open dispatch for T1..T4 (M6).
---
---Implements the F-key behavior the user specified:
---  - no terminal yet              → open + focus
---  - terminal hidden              → re-open + focus
---  - terminal visible, unfocused  → focus it (leave others alone)
---  - terminal visible, focused    → hide
---
---Plus the auto-hide rule: when WinEnter fires on any non-float window
---(editor, neo-tree, the agent panel — anything that isn't a float),
---hide every T1..T4 float at once. Scoped to T-floats only via
---`b:auto_agents_term_slot` — agent floats (6-9), lazygit, lazysql,
---telescope pickers, completion menus, etc. are NOT touched.
---
---Adapted from the user's `utils/float_focus.lua`.
---
---@module 'auto-agents.term.focus'

local term = require("auto-agents.term")

local M = {}

---@param win integer|nil
---@return boolean
local function is_float(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative ~= nil and cfg.relative ~= ""
end

---Focus dispatch for a slot. State machine in module docstring.
---@param slot integer
function M.focus_or_hide(slot)
  local existing = require("auto-agents.term").get(slot, { create = false })
  if not existing then
    -- Cold open: create and (snacks's toggle leaves it focused).
    return term.toggle(slot)
  end

  local win = term.find_win(slot)
  if not win then
    -- Hidden: re-open. Some spawn paths leave the new window
    -- unfocused; force focus just in case.
    term.toggle(slot)
    local new_win = term.find_win(slot)
    if new_win and vim.api.nvim_win_is_valid(new_win) then
      pcall(vim.api.nvim_set_current_win, new_win)
    end
    return
  end

  if vim.api.nvim_get_current_win() == win then
    -- Visible + focused → hide.
    if type(existing.hide) == "function" then
      pcall(existing.hide, existing)
    else
      pcall(existing.toggle, existing)
    end
  else
    -- Visible + unfocused → move focus to it without touching others.
    pcall(vim.api.nvim_set_current_win, win)
  end
end

---Install the WinEnter autocmd that auto-hides T1..T4 when focus
---moves into any non-float window. Re-entrant: nvim_create_augroup
---with clear=true wipes any prior install.
function M.install_auto_hide()
  local group = vim.api.nvim_create_augroup("AutoAgentsTermAutoHide", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      -- Still inside a float → user is jumping between T-floats or to
      -- some other plugin float; don't disturb.
      if is_float(vim.api.nvim_get_current_win()) then return end
      -- Defer so any pending window operation finishes first.
      vim.schedule(term.hide_all)
    end,
  })
end

return M
