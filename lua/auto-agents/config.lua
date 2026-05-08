---Configuration defaults, validation, and apply for auto-agents.nvim.
---@module 'auto-agents.config'

local M = {}

---@type AutoAgentsConfig
M.defaults = {
  log_level = "info",
  panel = {
    side = "right",
    min_width = 60,
    max_width = 130,
    percentage = 0.35,
    -- Hard-pin the panel to a specific column count. When non-nil this
    -- bypasses the percentage/min/max formula entirely. Set via the
    -- admin REPL (`panel resize`) and persisted to the active TOML's
    -- [panel] section so it sticks per-project. Allowed range:
    -- PANEL_OVERRIDE_MIN..PANEL_OVERRIDE_MAX (see below).
    width_override = nil,
    editor_floor = 40,
    slot_rail = "winbar",
    -- TUIs (claude/codex) draw a status line at the bottom; if the
    -- terminal occupies the entire window height, that status line
    -- can sit flush against vim's own statusline/cmdline and look
    -- cramped. We send a SIGWINCH with rows = win_height - margin so
    -- the TUI renders this many blank rows at the bottom edge.
    bottom_margin = 1,
  },
  agents = {
    default_kind = "claude",
    primary_kind = "claude",
    bootstrap = {},
  },
  kb = {
    default_scope = "shared",
  },
  terminal = {
    provider = "auto",
    cwd = nil,
    cwd_provider = nil,
    git_repo_cwd = true,
  },
  term = {
    -- Playground terminals T1..T4 — shared user/agent shells, separate
    -- from agent slots. Set enabled = false to skip the F1..F4 default
    -- keymaps and auto-hide; you can still drive them via :AutoAgentsTerm.
    enabled = true,
    fkeys = { "<F1>", "<F2>", "<F3>", "<F4>" },
  },
}

local LOG_LEVELS = { error = true, warn = true, info = true, debug = true, trace = true }
local SIDES = { left = true, right = true }
local RAILS = { winbar = true, vertical = true, off = true }
local KINDS = { claude = true, codex = true, gemini = true, junie = true, aider = true, goose = true, opencode = true, copilot = true, generic = true }
local SCOPES = { shared = true, private = true, isolated = true }
local PROVIDERS = { auto = true, snacks = true, native = true, none = true }

-- Bounds for `panel.width_override`. Picked to leave room for both
-- usable narrow layouts (very wide monitors with tiny side panels) and
-- maximal panel-takes-most-of-screen layouts. Anything outside this
-- range is almost certainly a typo.
--
-- Defined as module-local literals AND re-exported on M. Internal
-- validate / resolve reads use the locals so they can never go nil —
-- external callers read M.PANEL_OVERRIDE_MIN/MAX (with their own
-- fallback) which protects against stale module cache after a
-- lazy.nvim hot-reload.
local PANEL_MIN = 25
local PANEL_MAX = 160
M.PANEL_OVERRIDE_MIN = PANEL_MIN
M.PANEL_OVERRIDE_MAX = PANEL_MAX

---@param cfg AutoAgentsConfig
---@return string|nil error_msg
function M.validate(cfg)
  if not LOG_LEVELS[cfg.log_level] then
    return "log_level must be one of error|warn|info|debug|trace, got " .. tostring(cfg.log_level)
  end
  local p = cfg.panel
  if not SIDES[p.side] then
    return "panel.side must be 'left' or 'right', got " .. tostring(p.side)
  end
  if type(p.min_width) ~= "number" or p.min_width < 1 then
    return "panel.min_width must be a positive integer"
  end
  if type(p.max_width) ~= "number" or p.max_width < p.min_width then
    return "panel.max_width must be >= panel.min_width"
  end
  if type(p.percentage) ~= "number" or p.percentage <= 0 or p.percentage >= 1 then
    return "panel.percentage must be between 0 and 1 (exclusive)"
  end
  if p.width_override ~= nil then
    if type(p.width_override) ~= "number" or p.width_override ~= math.floor(p.width_override) then
      return "panel.width_override must be nil or an integer"
    end
    if p.width_override < PANEL_MIN or p.width_override > PANEL_MAX then
      return string.format("panel.width_override must be in %d..%d", PANEL_MIN, PANEL_MAX)
    end
  end
  if type(p.editor_floor) ~= "number" or p.editor_floor < 0 then
    return "panel.editor_floor must be a non-negative integer"
  end
  if not RAILS[p.slot_rail] then
    return "panel.slot_rail must be 'winbar', 'vertical', or 'off'"
  end
  if type(p.bottom_margin) ~= "number" or p.bottom_margin < 0 then
    return "panel.bottom_margin must be a non-negative integer"
  end
  local a = cfg.agents
  if not KINDS[a.default_kind] then
    return "agents.default_kind must be one of claude|codex|gemini|junie|aider|goose|opencode|copilot|generic"
  end
  if not KINDS[a.primary_kind] then
    return "agents.primary_kind must be one of claude|codex|gemini|junie|aider|goose|opencode|copilot|generic"
  end
  if type(a.bootstrap) ~= "table" then
    return "agents.bootstrap must be a list of slot specs"
  end
  if not SCOPES[cfg.kb.default_scope] then
    return "kb.default_scope must be one of shared|private|isolated"
  end
  if not PROVIDERS[cfg.terminal.provider] then
    return "terminal.provider must be one of auto|snacks|native|none"
  end
  return nil
end

---Merge user opts onto defaults and validate.
---@param user_opts table?
---@return AutoAgentsConfig
function M.apply(user_opts)
  local merged = vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
  local err = M.validate(merged)
  if err then
    error("auto-agents.config: " .. err)
  end
  return merged
end

---@param cfg AutoAgentsConfig
---@param cols integer
---@return integer
function M.resolve_panel_width(cfg, cols)
  local p = cfg.panel
  if p.width_override ~= nil then
    -- Defensive clamp: validation already enforces the range, but
    -- belt-and-suspenders here matters if a future code path ever
    -- mutates cfg in-place without re-validating.
    local w = p.width_override
    if w < PANEL_MIN then w = PANEL_MIN end
    if w > PANEL_MAX then w = PANEL_MAX end
    return w
  end
  local raw = math.floor(p.percentage * cols + 0.5)
  if raw < p.min_width then
    return p.min_width
  end
  if raw > p.max_width then
    return p.max_width
  end
  return raw
end

return M
