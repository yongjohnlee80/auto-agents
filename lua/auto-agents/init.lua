---Public API for auto-agents.nvim.
---@module 'auto-agents'

require("auto-agents.types")

local M = {}

M.version = "0.1.0-pre.1"

---@class AutoAgentsState
---@field config AutoAgentsConfig|nil
---@field initialized boolean
---@field panel_winid integer|nil
---@field slot_terminals table<integer, AutoAgentsTerminalInstance>  -- main slots 1..4
---@field focused_slot integer  -- last-focused slot 0..4; restored on panel reopen
M.state = {
  config = nil,
  initialized = false,
  panel_winid = nil,
  slot_terminals = {},
  focused_slot = 1,
}

---@param opts table?
function M.setup(opts)
  local config = require("auto-agents.config").apply(opts or {})
  require("auto-agents.logger").setup(config)
  M.state.config = config
  M.state.initialized = true
  require("auto-agents.float").install_auto_hide()
  require("auto-agents.logger").info("init", "auto-agents v" .. M.version .. " initialized")
end

-- ── local helpers ──────────────────────────────────────────────────────────

local KIND_CMDS = {
  claude = { "claude" },
  codex = { "codex" },
  gemini = { "gemini" },
}

---@param cfg AutoAgentsConfig
---@return AutoAgentsCwdContext
local function build_cwd_ctx(cfg)
  local current_buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_buf)
  local file_dir = (current_file ~= "") and vim.fn.fnamemodify(current_file, ":h") or nil
  return {
    cwd = vim.fn.getcwd(),
    file_dir = file_dir,
  }
end

---@class AutoAgentsResolvedSpec
---@field kind string             -- agent kind or "shell" for fallback
---@field name string|nil
---@field title string|nil
---@field cmd string[]
---@field configured boolean      -- false → empty-slot shell fallback

---Resolve a slot to a runnable spec. Looks up `agents.bootstrap` first;
---falls back to a persistent shell terminal for unconfigured slots.
---@param slot integer
---@return AutoAgentsResolvedSpec
local function resolve_slot_spec(slot)
  local cfg = M.state.config
  local bootstrap = (cfg and cfg.agents and cfg.agents.bootstrap) or {}
  for _, entry in ipairs(bootstrap) do
    if entry.slot == slot then
      local kind = entry.kind or "generic"
      local cmd = entry.cmd or KIND_CMDS[kind] or { vim.o.shell }
      return {
        kind = kind,
        name = entry.name,
        title = entry.title,
        cmd = cmd,
        configured = true,
      }
    end
  end
  return {
    kind = "shell",
    name = nil,
    title = nil,
    cmd = { vim.o.shell },
    configured = false,
  }
end

---Ensure the main panel window exists (open it if not) and return its winid.
---@param force boolean?
---@return integer|nil winid
local function ensure_main_window(force)
  local logger = require("auto-agents.logger")
  local cfg = M.state.config
  if not cfg then
    logger.error("init", "auto-agents.setup() must be called first")
    return nil
  end
  if M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid) then
    return M.state.panel_winid
  end
  if not force and vim.o.columns < cfg.panel.min_width + cfg.panel.editor_floor then
    logger.info(
      "panel",
      "host width " .. vim.o.columns .. " below threshold (min_width "
        .. cfg.panel.min_width .. " + editor_floor " .. cfg.panel.editor_floor
        .. "); use :AutoAgents! to force"
    )
    return nil
  end
  local width = require("auto-agents.config").resolve_panel_width(cfg, vim.o.columns)
  local placement = (cfg.panel.side == "left") and "topleft" or "botright"
  vim.cmd(placement .. " " .. width .. "vsplit")
  local winid = vim.api.nvim_get_current_win()
  M.state.panel_winid = winid

  -- Window-local appearance (issue #2): drop line numbers and signs on
  -- the agent panel — terminals don't benefit from them and they collide
  -- with claude/codex TUI rendering.
  vim.api.nvim_set_option_value("number", false, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = winid })

  return winid
end

---Spawn or recover the terminal for a main slot (1..4). When `winid` is
---supplied, fresh spawns place the buffer in that window BEFORE
---termopen — terminal inherits correct dimensions and TUIs render with
---the prompt anchored at the bottom (issue #1, second pass).
---@param slot integer
---@param winid integer|nil
---@return integer|nil bufnr
local function ensure_main_slot_terminal(slot, winid)
  local cfg = M.state.config
  if not cfg then return nil end

  local term = M.state.slot_terminals[slot]
  if term and term:is_alive() then
    return term:get_bufnr()
  end

  local logger = require("auto-agents.logger")
  local spec = resolve_slot_spec(slot)
  local resolved = require("auto-agents.terminal").resolve_provider(cfg)
  if resolved == "native" and spec.cmd[1] and vim.fn.executable(spec.cmd[1]) ~= 1 then
    logger.warn(
      "panel",
      "'" .. spec.cmd[1] .. "' not on PATH — slot " .. slot .. " (" .. spec.kind .. ") cannot start"
    )
    return nil
  end

  local cwd = require("auto-agents.cwd").resolve(cfg.terminal, build_cwd_ctx(cfg))
  term = require("auto-agents.terminal").new(cfg, {
    cmd = spec.cmd,
    cwd = cwd,
    env = nil,
    on_exit = function(code)
      logger.info("panel", "slot " .. slot .. " (" .. spec.kind .. ") exited code=" .. tostring(code))
    end,
  })
  local bufnr = term:start(winid)
  if not bufnr then return nil end
  M.state.slot_terminals[slot] = term
  return bufnr
end

-- ── public API ─────────────────────────────────────────────────────────────

---Open the main right window and focus the last-focused slot (default: 1).
---@param force boolean?
function M.open(force)
  if not M.state.config then
    require("auto-agents.logger").error("init", "auto-agents.setup() must be called first")
    return
  end
  if not ensure_main_window(force) then return end
  M.focus_slot(M.state.focused_slot or 1)
end

---Close the panel window. Keeps terminal jobs alive (processes persist;
---window is just hidden) — matches `claudecode.nvim`'s simple_toggle.
function M.close()
  if M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid) then
    vim.api.nvim_win_close(M.state.panel_winid, true)
  end
  M.state.panel_winid = nil
end

---@param force boolean?
function M.toggle(force)
  if M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid) then
    M.close()
  else
    M.open(force)
  end
end

---Toggle the navigation dock — a small float listing every slot + the
---editor, with single-keystroke dispatch.
function M.dock_toggle()
  require("auto-agents.dock").toggle()
end

---Toggle a sub-agent float (D17). Slot must be in 5..9. Resolves the
---slot's spec from `agents.bootstrap`; unconfigured slots fall back to
---a persistent shell terminal float.
---@param slot integer
function M.toggle_sub(slot)
  local logger = require("auto-agents.logger")
  local cfg = M.state.config
  if not cfg then
    logger.error("init", "auto-agents.setup() must be called first")
    return
  end
  local float = require("auto-agents.float")
  if slot < float.MIN_SLOT or slot > float.MAX_SLOT then
    logger.error("init", "toggle_sub: slot must be " .. float.MIN_SLOT .. ".." .. float.MAX_SLOT .. ", got " .. tostring(slot))
    return
  end

  local spec = resolve_slot_spec(slot)
  if spec.cmd[1] and vim.fn.executable(spec.cmd[1]) ~= 1 then
    logger.warn(
      "init",
      "'" .. spec.cmd[1] .. "' not on PATH — sub slot " .. slot .. " (" .. spec.kind .. ") cannot start"
    )
    return
  end

  local cwd = require("auto-agents.cwd").resolve(cfg.terminal, build_cwd_ctx(cfg))
  float.toggle(cfg, slot, {
    cmd = spec.cmd,
    cwd = cwd,
    env = nil,
    -- Metadata for the float title (snacks renders this in the bordered
    -- title position). Lets users distinguish e.g. two Claude floats.
    kind = spec.kind,
    name = spec.name,
    title = spec.title,
    on_exit = function(code)
      logger.info("float", "slot " .. slot .. " (" .. spec.kind .. ") exited code=" .. tostring(code))
    end,
  })
end

---Universal slot router (D17). Slots 0..4 → main right window (buffer
---multiplex); slots 5..9 → sub-agent floats (mutually exclusive).
---@param slot integer
function M.focus_slot(slot)
  local logger = require("auto-agents.logger")
  local cfg = M.state.config
  if not cfg then
    logger.error("init", "auto-agents.setup() must be called first")
    return
  end

  if slot >= 5 and slot <= 9 then
    M.toggle_sub(slot)
    return
  end

  if slot < 0 or slot > 4 then
    logger.error("init", "focus_slot: slot must be 0..9, got " .. tostring(slot))
    return
  end

  local winid = ensure_main_window(false)
  if not winid then return end

  local bufnr
  local fresh_spawn = false
  if slot == 0 then
    bufnr = require("auto-agents.panel.admin").get_or_create_buffer()
  else
    -- Detect whether this slot already has a live terminal. If not, the
    -- spawn will happen with the panel window as context (correct sizing).
    fresh_spawn = not (M.state.slot_terminals[slot] and M.state.slot_terminals[slot]:is_alive())
    bufnr = ensure_main_slot_terminal(slot, fresh_spawn and winid or nil)
    if not bufnr then return end
  end

  -- For non-fresh spawns (re-focus / slot 0 admin), explicitly place the
  -- buffer in the panel window. Fresh spawns already did this inside
  -- start(winid) so termopen could see the dimensions.
  if not fresh_spawn then
    vim.api.nvim_win_set_buf(winid, bufnr)
  end
  M.state.focused_slot = slot
  vim.api.nvim_set_current_win(winid)

  -- D10 winbar tab-strip: all 5 main slots, focused one bracketed,
  -- each wrapped in a clickable region. Implementation in
  -- panel/winbar.lua.
  do
    local winbar = require("auto-agents.panel.winbar")
    winbar.ensure_highlights()
    pcall(vim.api.nvim_set_option_value, "winbar", winbar.render(slot), { win = winid })
  end
  if slot >= 1 then
    -- Defensive resize: send SIGWINCH to the TUI so it redraws at the
    -- panel's current dimensions. Critical when the panel was resized
    -- (or the buffer was last in a different-sized window) since we
    -- last focused this slot.
    local term = M.state.slot_terminals[slot]
    if term and term.resize_to then term:resize_to(winid) end
    pcall(vim.api.nvim_win_call, winid, function() vim.cmd("normal! G") end)
    vim.cmd("startinsert")
  else
    -- Slot 0 (admin): prompt buffer — move cursor to the prompt line
    -- (last line) and enter insert mode so the user can immediately
    -- type a command. This is the one non-terminal slot where insert
    -- mode is the right default — it's an interactive REPL.
    pcall(vim.api.nvim_win_call, winid, function()
      local n = vim.api.nvim_buf_line_count(bufnr)
      pcall(vim.api.nvim_win_set_cursor, winid, { n, 0 })
    end)
    vim.cmd("startinsert!")
  end
  logger.debug("panel", "focused slot=" .. slot .. " buf=" .. bufnr .. " fresh=" .. tostring(fresh_spawn))
end

return M
