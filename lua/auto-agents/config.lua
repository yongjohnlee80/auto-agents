---Configuration defaults, validation, and apply for auto-agents.nvim.
---@module 'auto-agents.config'

local M = {}

---@type AutoAgentsConfig
M.defaults = {
  log_level = "info",
  panel = {
    side = "right",
    min_width = 50,
    max_width = 80,
    percentage = 0.30,
    editor_floor = 40,
    slot_rail = "winbar",
  },
  agents = {
    default_kind = "claude",
    primary_kind = "claude",
    bootstrap = true,
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
}

local LOG_LEVELS = { error = true, warn = true, info = true, debug = true, trace = true }
local SIDES = { left = true, right = true }
local RAILS = { winbar = true, vertical = true, off = true }
local KINDS = { claude = true, codex = true, gemini = true, generic = true }
local SCOPES = { shared = true, private = true, isolated = true }
local PROVIDERS = { auto = true, snacks = true, native = true, none = true }

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
  if type(p.editor_floor) ~= "number" or p.editor_floor < 0 then
    return "panel.editor_floor must be a non-negative integer"
  end
  if not RAILS[p.slot_rail] then
    return "panel.slot_rail must be 'winbar', 'vertical', or 'off'"
  end
  local a = cfg.agents
  if not KINDS[a.default_kind] then
    return "agents.default_kind must be one of claude|codex|gemini|generic"
  end
  if not KINDS[a.primary_kind] then
    return "agents.primary_kind must be one of claude|codex|gemini|generic"
  end
  if type(a.bootstrap) ~= "boolean" then
    return "agents.bootstrap must be boolean"
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
