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
    -- Number of agent slots in the main panel (1..N below admin's
    -- slot 0). Default 5 — matches the previous MAIN_SLOT_MAX
    -- constant. Range SLOT_COUNT_MIN..SLOT_COUNT_MAX (2..9). Below 2
    -- is rejected (admin + 1 agent makes the slot model pointless);
    -- above 9 is rejected as a typo.
    --
    -- Persisted to the active TOML's [panel] section by the admin
    -- DSL (`slot add N` / `slot remove N`).
    slot_count = 5,
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
  -- Three-column AutoVim layout invariant. AutoFinder | Editor |
  -- AutoAgents — when an editor window must always exist for diff
  -- review and normal editing to be possible.
  --
  -- editor_window_strategy controls what happens when WinClosed leaves
  -- only side panels visible:
  --   "create_scratch" → materialize an empty scratch in a new vsplit
  --                      between the panels (default; restores the layout
  --                      automatically). The scratch carries no
  --                      winfixwidth / winfixbuf so the user can edit
  --                      / replace it freely.
  --   "warn"           → log a warning, no recovery. User has to open a
  --                      buffer manually before the layout is usable.
  --   "off"            → no-op. Honor :q exactly.
  --
  -- See lua/auto-agents/integrations/editor_floor.lua for the autocmd
  -- that enforces this. NOT to be confused with cfg.panel.editor_floor
  -- (column-count threshold, separate concern).
  layout = {
    editor_window_strategy = "create_scratch",
  },
  -- Diff-route gate. When claudecode opens a diff buffer
  -- (BufWinEnter with b:claudecode_diff_tab_name) and no editor window
  -- existed outside the diff itself, claudecode manufactured a split
  -- inside the panel column. We refuse:
  --   "warn" → close the manufactured diff windows and log a warning
  --            (default; honors the "log warning rather than opening"
  --            request). The agent terminal still receives the diff
  --            text in its TUI; we only suppress the editor-side
  --            split.
  --   "off"  → don't intervene. Claudecode does its thing.
  diff = {
    editor_floor_strategy = "warn",
  },
}

local LOG_LEVELS = { error = true, warn = true, info = true, debug = true, trace = true }
local SIDES = { left = true, right = true }
local RAILS = { winbar = true, vertical = true, off = true }
local KINDS = { claude = true, codex = true, antigravity = true, junie = true, goose = true, opencode = true, copilot = true, generic = true }
local SCOPES = { shared = true, private = true, isolated = true }
local PROVIDERS = { auto = true, snacks = true, native = true, none = true }
local LAYOUT_STRATEGIES = { create_scratch = true, warn = true, off = true }
local DIFF_STRATEGIES = { warn = true, off = true }

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

-- Bounds for `panel.slot_count`. Floor 2 prevents the degenerate
-- "admin + 1 agent" layout (slot 0 is admin; below 2 means no usable
-- slot multiplex at all). Cap 9 keeps the winbar tab strip readable
-- and matches the keymap surface (`<leader>a0`..`<leader>a9`).
local SLOT_COUNT_MIN = 2
local SLOT_COUNT_MAX = 9
M.SLOT_COUNT_MIN = SLOT_COUNT_MIN
M.SLOT_COUNT_MAX = SLOT_COUNT_MAX

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
  if type(p.slot_count) ~= "number" or p.slot_count ~= math.floor(p.slot_count) then
    return "panel.slot_count must be an integer"
  end
  if p.slot_count < SLOT_COUNT_MIN or p.slot_count > SLOT_COUNT_MAX then
    return string.format("panel.slot_count must be in %d..%d, got %d",
      SLOT_COUNT_MIN, SLOT_COUNT_MAX, p.slot_count)
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
    return "agents.default_kind must be one of claude|codex|antigravity|junie|goose|opencode|copilot|generic"
  end
  if not KINDS[a.primary_kind] then
    return "agents.primary_kind must be one of claude|codex|antigravity|junie|goose|opencode|copilot|generic"
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
  local layout = cfg.layout or {}
  if layout.editor_window_strategy ~= nil
      and not LAYOUT_STRATEGIES[layout.editor_window_strategy] then
    return "layout.editor_window_strategy must be one of create_scratch|warn|off, got "
      .. tostring(layout.editor_window_strategy)
  end
  local diff = cfg.diff or {}
  if diff.editor_floor_strategy ~= nil
      and not DIFF_STRATEGIES[diff.editor_floor_strategy] then
    return "diff.editor_floor_strategy must be one of warn|off, got "
      .. tostring(diff.editor_floor_strategy)
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
