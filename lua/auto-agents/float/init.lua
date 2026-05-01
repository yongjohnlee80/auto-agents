---Sub-agent float dispatcher (D17). Slots 5..9 are rendered as snacks
---floats positioned in the right column of the screen — not overlapping
---the center editor area. Mutually exclusive: at most one sub-float
---visible at a time. Diff vsplits are forbidden from these (D18); diff
---requests queue through admin.
---
---Adapted from the slot-marker disambiguation pattern in
---`~/.config/nvim/lua/utils/term_send.lua` and the four-state focus
---dispatch in `~/.config/nvim/lua/utils/float_focus.lua` (both authored
---by the user; vendored here so this plugin doesn't depend on the
---user's personal nvim config).
---@module 'auto-agents.float'

local logger = require("auto-agents.logger")

local M = {}

local SLOT_MARKER = "auto_agents_slot"
-- Boundary: slots 0..5 are main, 6..9 are sub-floats. Mirrors
-- M.MAIN_SLOT_MAX in lua/auto-agents/init.lua (kept duplicated to avoid
-- a require cycle between auto-agents and auto-agents.float).
M.MIN_SLOT = 6
M.MAX_SLOT = 9

---@return boolean
local function is_snacks_available()
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks ~= nil and snacks.terminal ~= nil
end

---@param slot integer
---@return table|nil  -- snacks terminal instance or nil
local function find_slot_terminal(slot)
  if not is_snacks_available() then return nil end
  for _, term in ipairs(Snacks.terminal.list()) do
    local buf = term.buf
    if buf and vim.api.nvim_buf_is_valid(buf) and vim.b[buf][SLOT_MARKER] == slot then
      return term
    end
  end
  return nil
end

---@param term table
---@param slot integer
local function stamp_slot(term, slot)
  if term and term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    vim.b[term.buf][SLOT_MARKER] = slot
  end
  return term
end

---@param buf integer
---@return integer|nil winid
local function find_win_for_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

---@param term table
local function hide_term(term)
  if not term then return end
  if type(term.hide) == "function" then
    pcall(term.hide, term)
  elseif type(term.toggle) == "function" then
    pcall(term.toggle, term)
  end
end

---Compute right-column staggered float position for a slot.
---@param cfg AutoAgentsConfig
---@param slot integer  -- 5..9
---@param spec AutoAgentsTerminalSpec
---@return table
local function build_win_opts(cfg, slot, spec)
  local idx = slot - M.MIN_SLOT  -- 0..4
  local pct = cfg.panel.percentage
  local label = (spec and (spec.title or spec.name or spec.kind)) or "agent"
  return {
    position = "float",
    relative = "editor",
    width = pct,
    height = 0.85,
    col = (1.0 - pct) - (idx * 0.005),
    row = 0.02 + (idx * 0.02),
    border = "rounded",
    title = string.format(" %d: %s ", slot, label),
    title_pos = "center",
    -- Stamp the slot marker synchronously when snacks creates the
    -- buffer, BEFORE any autocmd can fire. Critical because the user
    -- may have a global "hide all snacks floats on WinEnter to non-
    -- float" autocmd (e.g. float_focus.lua) that filters by this
    -- marker. Without this, the marker isn't set until our post-
    -- spawn `stamp_slot` call, and a deferred hide-all could fire
    -- in between and close the freshly-spawned float.
    on_buf = function(self)
      if self and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
        vim.b[self.buf][SLOT_MARKER] = slot
      end
    end,
  }
end

---Hide every auto-agents sub-float (slots 5..9). Does not touch F1..F5
---helper floats — they live in a separate keyspace identified by
---`b:term_send_slot`.
---
---**Always hides — unconditional.** Used by float.toggle() to enforce
---mutual exclusion. The auto-hide schedule has its OWN current-focus
---guard (in install_auto_hide) so that race protection happens at
---the schedule layer, not here.
function M.hide_all()
  if not is_snacks_available() then return end
  for _, term in ipairs(Snacks.terminal.list()) do
    local buf = term.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local s = vim.b[buf][SLOT_MARKER]
      if type(s) == "number" and s >= M.MIN_SLOT and s <= M.MAX_SLOT then
        if find_win_for_buf(buf) then
          hide_term(term)
        end
      end
    end
  end
end

---Toggle the sub-agent float for a slot. Implements the four-state
---dispatch (no-term → spawn; hidden → show + focus; visible-unfocused
---→ focus; visible-focused → hide) with mutual exclusion across all
---auto-agents sub-floats.
---
---@param cfg AutoAgentsConfig
---@param slot integer  -- 5..9
---@param spec AutoAgentsTerminalSpec
---@return table|nil  -- snacks terminal instance, or nil if snacks unavailable / spawn failed
function M.toggle(cfg, slot, spec)
  if slot < M.MIN_SLOT or slot > M.MAX_SLOT then
    error(("auto-agents.float: slot must be %d..%d, got %s"):format(M.MIN_SLOT, M.MAX_SLOT, tostring(slot)))
  end
  if not is_snacks_available() then
    logger.error("float", "snacks.nvim is required for sub-agent floats; slot " .. slot .. " is unavailable")
    return nil
  end

  local term = find_slot_terminal(slot)
  local win = term and term.buf and find_win_for_buf(term.buf) or nil
  local current_win = vim.api.nvim_get_current_win()

  if not term then
    -- Spawn fresh. Hide any other sub-float first to enforce mutual exclusion.
    M.hide_all()
    local opts = {
      cwd = spec.cwd,
      env = spec.env,
      auto_close = false,
      win = build_win_opts(cfg, slot, spec),
    }
    local new_term = Snacks.terminal.toggle(spec.cmd, opts)
    if not new_term then
      logger.error("float", "Snacks.terminal.toggle returned nil for slot " .. slot)
      return nil
    end
    stamp_slot(new_term, slot)
    if spec.on_exit and new_term.buf then
      vim.api.nvim_create_autocmd("TermClose", {
        buffer = new_term.buf,
        once = true,
        callback = function()
          local code = (type(vim.v.event) == "table" and vim.v.event.status) or 0
          vim.schedule(function() spec.on_exit(code) end)
        end,
      })
    end
    return new_term
  end

  if not win then
    -- Hidden — hide other sub-floats and re-show this one.
    M.hide_all()
    if type(term.toggle) == "function" then
      pcall(term.toggle, term)
    end
    return term
  end

  if current_win == win then
    -- Visible + focused — hide.
    hide_term(term)
    return term
  end

  -- Visible + unfocused — hide other sub-floats and focus this one.
  M.hide_all()
  -- After hide_all, our own win may have been hidden too — re-show.
  if not find_win_for_buf(term.buf) then
    if type(term.toggle) == "function" then
      pcall(term.toggle, term)
    end
  end
  local refreshed_win = find_win_for_buf(term.buf)
  if refreshed_win and vim.api.nvim_win_is_valid(refreshed_win) then
    pcall(vim.api.nvim_set_current_win, refreshed_win)
  end
  return term
end

---@param slot integer
---@return integer|nil bufnr
function M.get_bufnr(slot)
  local term = find_slot_terminal(slot)
  return term and term.buf or nil
end

---Auto-hide sub-floats when the user enters a non-float window.
---Mirrors `float_focus.install_auto_hide` for slots 5..9. Race
---protection happens INSIDE the deferred schedule: by the time
---vim.schedule fires, the user may have already moved INTO a float
---(e.g. just dispatched a sub-agent via <leader>a5..9). In that case
---we abort to avoid hiding the freshly-summoned float.
function M.install_auto_hide()
  local group = vim.api.nvim_create_augroup("AutoAgentsFloatAutoHide", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      if not vim.api.nvim_win_is_valid(cur) then return end
      local cfg = vim.api.nvim_win_get_config(cur)
      if cfg.relative ~= nil and cfg.relative ~= "" then
        return  -- still in a float; leave the float group alone
      end
      vim.schedule(function()
        local recur = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_is_valid(recur) then
          local recfg = vim.api.nvim_win_get_config(recur)
          if recfg.relative ~= nil and recfg.relative ~= "" then
            return  -- user moved into a float between schedule and run
          end
        end
        M.hide_all()
      end)
    end,
  })
end

return M
