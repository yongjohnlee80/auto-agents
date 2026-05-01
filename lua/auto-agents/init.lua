---Public API for auto-agents.nvim.
---@module 'auto-agents'

require("auto-agents.types")

local M = {}

M.version = "0.1.0-pre.1"

---@class AutoAgentsState
---@field config AutoAgentsConfig|nil
---@field initialized boolean
---@field panel_winid integer|nil
---@field terminal AutoAgentsTerminalInstance|nil
M.state = {
  config = nil,
  initialized = false,
  panel_winid = nil,
  terminal = nil,
}

---@param opts table?
function M.setup(opts)
  local config = require("auto-agents.config").apply(opts or {})
  require("auto-agents.logger").setup(config)
  M.state.config = config
  M.state.initialized = true
  require("auto-agents.logger").info("init", "auto-agents v" .. M.version .. " initialized")
end

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

---Open the panel window and spawn the default agent (M1: claude in a single split).
---Full slot management lands in M2.
---@param force boolean?
function M.open(force)
  local logger = require("auto-agents.logger")
  local cfg = M.state.config
  if not cfg then
    logger.error("init", "auto-agents.setup() must be called first")
    return
  end

  -- D9 host-width guard
  if not force and vim.o.columns < cfg.panel.min_width + cfg.panel.editor_floor then
    logger.info(
      "panel",
      "host width "
        .. vim.o.columns
        .. " below threshold (min_width "
        .. cfg.panel.min_width
        .. " + editor_floor "
        .. cfg.panel.editor_floor
        .. "); use :AutoAgents! to force"
    )
    return
  end

  -- Already open — focus and bail
  if M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid) then
    vim.api.nvim_set_current_win(M.state.panel_winid)
    vim.cmd("startinsert")
    return
  end

  -- Compute width per D9 clamp
  local width = require("auto-agents.config").resolve_panel_width(cfg, vim.o.columns)

  -- Create the side split
  local original_win = vim.api.nvim_get_current_win()
  local placement = (cfg.panel.side == "left") and "topleft" or "botright"
  vim.cmd(placement .. " " .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()

  -- Reuse existing terminal if alive (panel was closed but process kept running)
  local term = M.state.terminal
  if term and term:is_alive() then
    vim.api.nvim_win_set_buf(new_winid, term:get_bufnr())
    M.state.panel_winid = new_winid
    vim.cmd("startinsert")
    return
  end

  -- D11 default-bootstrap: spawn claude if available. Skip the executable
  -- check when the resolved provider is "none" (used by tests).
  local resolved = require("auto-agents.terminal").resolve_provider(cfg)
  if resolved == "native" and vim.fn.executable("claude") ~= 1 then
    logger.warn("panel", "'claude' binary not on PATH — skipping default-bootstrap (D11)")
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    return
  end

  local cwd = require("auto-agents.cwd").resolve(cfg.terminal, build_cwd_ctx(cfg))
  local terminal = require("auto-agents.terminal").new(cfg, {
    cmd = { "claude" },
    cwd = cwd,
    env = nil,
    on_exit = function(code)
      logger.info("panel", "claude exited code=" .. tostring(code))
    end,
  })

  local bufnr = terminal:start()
  if not bufnr then
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    return
  end

  vim.api.nvim_win_set_buf(new_winid, bufnr)
  M.state.panel_winid = new_winid
  M.state.terminal = terminal
  vim.cmd("startinsert")
  logger.debug("panel", "opened width=" .. width .. " bufnr=" .. bufnr)
end

---Close the panel window. Keeps the terminal job alive (process persists,
---window is just hidden) — matching how `claudecode.nvim`'s simple_toggle works.
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

return M
