---Public API for auto-agents.nvim.
---@module 'auto-agents'

require("auto-agents.types")

local M = {}

M.version = "0.1.5"

-- Slot stratification (D17). Slots 0..MAIN_SLOT_MAX are main (right
-- window, multi-buffer multiplex); slots MAIN_SLOT_MAX+1..MAX_SLOT are
-- sub-agent floats (mutually exclusive).
M.MAIN_SLOT_MAX = 5
M.MAX_SLOT = 9

---@class AutoAgentsState
---@field config AutoAgentsConfig|nil
---@field initialized boolean
---@field panel_winid integer|nil
---@field slot_terminals table<integer, AutoAgentsTerminalInstance>  -- main slots 1..4
---@field focused_slot integer  -- last-focused slot 0..4; restored on panel reopen
---@field session_cwd string|nil          -- raw cwd at setup() time
---@field session_project_root string|nil -- git_root(session_cwd) or session_cwd
---@field session_project_key string|nil  -- sha16(session_project_root) — TOML filename
---@field config_source string|nil        -- "project"|"global"|"none"; resolved at setup
M.state = {
  config = nil,
  initialized = false,
  panel_winid = nil,
  slot_terminals = {},
  focused_slot = 1,
  session_cwd = nil,
  session_project_root = nil,
  session_project_key = nil,
  config_source = nil,
  -- Per-slot runtime status. nil ≡ "idle"; "waiting" / "working" come
  -- from agent self-reports via :AutoAgentsStatus. Ephemeral — never
  -- written to TOML, cleared on agent exit.
  ---@type table<integer, "waiting"|"working">
  agent_status = {},
}

-- ── diff-review parity hooks (route B) ────────────────────────────────────
--
-- claudecode.nvim's diff handler resizes whatever terminal it finds to
-- its own `terminal.split_width_percentage * total_columns` (default 0.3)
-- on diff open / accept / reject. Our panel is clamped to
-- [min_width, max_width] (default 50..120) so on wider screens claudecode's
-- naive 0.3*cols disagrees with our resolved width and the panel jumps.
--
-- We replicate the original autovim diff UX:
--   1. Diff opens as a vsplit alongside the agent panel (claudecode default).
--   2. As soon as we see the diff buffer appear (b:claudecode_diff_tab_name
--      marker), we open a 1x1 invisible "ghost" float that absorbs key-
--      strokes for ~500ms — protecting against an Enter the user was
--      typing into the agent panel from accidentally accepting/rejecting
--      the diff.
--   3. After 500ms, ghost closes, agent panel width is forcibly restored,
--      focus returns to the agent terminal so the user's next keystroke
--      goes to the agent prompt.
--   4. On diff close (BufWipeout/BufDelete on the marker buffer) we
--      restore panel width again — claudecode resizes a second time on
--      accept/reject.

---Use the cached width set when the panel was opened (or last
---updated by VimResized). We deliberately do NOT recompute from
---`vim.o.columns` per restore, because if the terminal got resized
---between open and restore, recomputing gives a different value than
---what the user is currently looking at, and the panel would snap.
local function _restore_panel_width()
  local panel = M.state.panel_winid
  if not panel or not vim.api.nvim_win_is_valid(panel) then return end
  local width = M.state.panel_width
  if not width then
    -- Fallback if the cache is missing (panel was opened before this
    -- code path landed): recompute and stash.
    local cfg = M.state.config
    if not cfg then return end
    width = require("auto-agents.config").resolve_panel_width(cfg, vim.o.columns)
    M.state.panel_width = width
  end
  pcall(vim.api.nvim_win_set_width, panel, width)
end

---Refresh the cached panel width from the new terminal columns.
---Called from a VimResized autocmd so the cache stays current as the
---user resizes their terminal — the next diff-restore uses the value
---matching the user's current screen.
local function _refresh_panel_width_cache()
  local panel = M.state.panel_winid
  if not panel or not vim.api.nvim_win_is_valid(panel) then return end
  local cfg = M.state.config
  if not cfg then return end
  M.state.panel_width = require("auto-agents.config").resolve_panel_width(cfg, vim.o.columns)
  -- Apply the new width too so the panel tracks the resize.
  pcall(vim.api.nvim_win_set_width, panel, M.state.panel_width)
end

---Open a 1x1 invisible "ghost" float at row 0 col 0 that grabs focus
---and swallows keystrokes for `delay_ms` ms, then closes itself,
---restores the agent panel width, and refocuses the agent terminal.
---@param delay_ms integer
local function _ghost_buffer_then_focus_agent(delay_ms)
  if M.state._diff_ghost_win and vim.api.nvim_win_is_valid(M.state._diff_ghost_win) then
    return  -- already in a diff cycle; don't double-trigger
  end
  local ghost_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[ghost_buf].bufhidden = "wipe"
  vim.bo[ghost_buf].buftype = "nofile"
  vim.bo[ghost_buf].swapfile = false
  -- Map common keys to no-op so they don't escape the ghost buffer
  -- and accidentally hit the diff or agent.
  for _, lhs in ipairs({ "<CR>", "<Space>", "y", "n", "Y", "N", "q", ":" }) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", { buffer = ghost_buf, silent = true, nowait = true })
  end
  local ok_win, ghost_win = pcall(vim.api.nvim_open_win, ghost_buf, true, {
    relative = "editor",
    width = 1,
    height = 1,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = true,
    zindex = 300,
    border = "none",
  })
  if not ok_win then return end
  M.state._diff_ghost_win = ghost_win
  vim.defer_fn(function()
    if M.state._diff_ghost_win and vim.api.nvim_win_is_valid(M.state._diff_ghost_win) then
      pcall(vim.api.nvim_win_close, M.state._diff_ghost_win, true)
    end
    M.state._diff_ghost_win = nil
    _restore_panel_width()
    local panel = M.state.panel_winid
    if panel and vim.api.nvim_win_is_valid(panel) then
      pcall(vim.api.nvim_set_current_win, panel)
      pcall(vim.cmd, "startinsert")
    end
  end, delay_ms or 500)
end

local function install_diff_parity_hooks()
  local group = vim.api.nvim_create_augroup("AutoAgentsDiffParity", { clear = true })

  -- Diff opens → ghost-absorb + width restore + focus agent (via the
  -- ghost's deferred callback).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      if not args.buf or not vim.api.nvim_buf_is_valid(args.buf) then return end
      if not vim.b[args.buf].claudecode_diff_tab_name then return end
      vim.schedule(function() _ghost_buffer_then_focus_agent(500) end)
    end,
  })

  -- Diff accept/reject → claudecode resizes again, so re-restore.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(args)
      if not args.buf or not vim.api.nvim_buf_is_valid(args.buf) then
        -- Buffer already invalid; still schedule a restore — the diff
        -- buffer's wipeout is what triggered us.
      end
      -- Even if we can't read the marker any more, schedule restores
      -- whenever a buffer with the marker (or in claudecode's namespace)
      -- is deleted. Keep this cheap: a few deferred restores.
      local was_diff = args.buf and vim.api.nvim_buf_is_valid(args.buf)
        and vim.b[args.buf].claudecode_diff_tab_name ~= nil
      if not was_diff then return end
      vim.schedule(_restore_panel_width)
      vim.defer_fn(_restore_panel_width, 100)
      vim.defer_fn(_restore_panel_width, 300)
    end,
  })

  -- Belt-and-suspenders: any tab close also triggers a restore. Cheap
  -- and catches edge cases where the diff buffer was inside a tab that
  -- got torn down without firing BufWipeout for the diff buf itself.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.defer_fn(_restore_panel_width, 50)
    end,
  })

  -- Terminal resize → recompute the cached panel width so subsequent
  -- diff-restore calls use the value matching the user's new screen
  -- size (otherwise we'd lock to whatever width was current at panel
  -- open and never adapt).
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = _refresh_panel_width_cache,
  })
end

---@param opts table?
function M.setup(opts)
  local config = require("auto-agents.config").apply(opts or {})
  require("auto-agents.logger").setup(config)

  -- Cache the session's project identity once. :cd doesn't move agents
  -- or KB — we resolve everything against the cwd we saw at setup().
  local cwd_mod = require("auto-agents.cwd")
  local raw_cwd = vim.fn.getcwd()
  local root = cwd_mod.git_root(raw_cwd) or raw_cwd
  M.state.session_cwd = raw_cwd
  M.state.session_project_root = root
  M.state.session_project_key = vim.fn.sha256(root):sub(1, 16)

  -- M6: TOML config store replaces the lazy-spec bootstrap entirely.
  -- Resolution order: per-project file → global file → empty.
  local store = require("auto-agents.config.store")
  local loaded, source = store.load(M.state.session_project_key)
  config.agents = config.agents or {}
  config.agents.bootstrap = (loaded and loaded.agents) or {}
  if loaded and loaded.kb then
    config.kb = config.kb or {}
    if loaded.kb.root then config.kb.root_override = loaded.kb.root end
    if loaded.kb.type then config.kb.type = loaded.kb.type end
    if loaded.kb.seed then config.kb.seed_path = loaded.kb.seed end
  end
  M.state.config_source = source

  -- M5: load resource grants for this project.
  require("auto-agents.resources.grants").load()
  M.state.config = config
  M.state.initialized = true

  -- M6 diff-review bridge: if any agent opted in via `diff_review =
  -- true` in TOML, start claudecode.nvim's WebSocket MCP server and
  -- cache its port. Opted-in agents get `CLAUDE_CODE_SSE_PORT` at
  -- spawn so Claude Code CLI's `openDiff` tool routes to the user's
  -- editor as a diff split. Non-opted-in agents don't get the port,
  -- so Claude Code CLI falls back to its built-in TUI confirm prompt
  -- (no in-editor diff for them). Manager-routed approval flow is
  -- on the roadmap (post-v0.1.0, alongside M5.C inter-agent comms).
  -- claudecode.nvim is a soft dep; we error gracefully if missing.
  M.state.diff_review_enabled = false
  M.state.diff_review_port = nil
  for _, e in ipairs(config.agents.bootstrap) do
    if e.diff_review then M.state.diff_review_enabled = true; break end
  end
  if M.state.diff_review_enabled then
    local ok, claudecode = pcall(require, "claudecode")
    if not ok then
      require("auto-agents.logger").warn("init",
        "agent has diff_review=true but claudecode.nvim is not installed — "
          .. "diff splits will be unavailable. Add `coder/claudecode.nvim` "
          .. "to your plugin list.")
    else
      -- Use claudecode's defaults (vsplit layout). We replicate the
      -- original autovim diff-review parity in our own autocmd hooks
      -- below: a 1x1 ghost-buffer absorbs reflexive keystrokes for
      -- ~500ms after the diff opens, then closes and returns focus to
      -- the agent panel. Panel width is forcibly restored on every
      -- diff transition since claudecode's resize math disagrees with
      -- our clamped panel.percentage on wide screens.
      pcall(claudecode.setup, (claudecode.state and claudecode.state.config) or {})
      if not (claudecode.state and claudecode.state.server) then
        local ok2, _err = pcall(claudecode.start, false)
        if not ok2 then
          require("auto-agents.logger").warn("init",
            "claudecode.nvim server failed to start; diff env will be skipped")
        end
      end
      if claudecode.state and claudecode.state.port then
        M.state.diff_review_port = claudecode.state.port
        require("auto-agents.logger").info("init",
          "diff-review bridge ready on port " .. tostring(M.state.diff_review_port))
      end
      install_diff_parity_hooks()
    end
  end

  -- Default the initial focus to admin (slot 0) when no agents are
  -- configured. Otherwise the first :AutoAgents drops you into a
  -- fallback shell at slot 1 — the wizard auto-engages from admin, so
  -- admin is the right landing slot for an empty config. With agents
  -- loaded, the previous focused_slot (or 1) still applies.
  if #config.agents.bootstrap == 0 then
    M.state.focused_slot = 0
  end

  require("auto-agents.float").install_auto_hide()

  -- M6: playground terminals T1..T4. Auto-hide on editor focus +
  -- default F1..F4 keymaps unless the user opts out.
  if config.term and config.term.enabled then
    require("auto-agents.term.focus").install_auto_hide()
    for slot, lhs in ipairs(config.term.fkeys or {}) do
      pcall(vim.keymap.set, { "n", "t" }, lhs, function()
        require("auto-agents.term.focus").focus_or_hide(slot)
      end, { desc = "Auto-agents term " .. slot .. " (focus/hide)" })
    end
  end

  require("auto-agents.logger").info("init",
    string.format("auto-agents v%s initialized; config_source=%s, agents=%d",
      M.version, source, #config.agents.bootstrap))
end

-- ── local helpers ──────────────────────────────────────────────────────────

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
---@field model string|nil        -- preferred model id (passed as --model to claude/codex/gemini)
---@field cmd string[]
---@field configured boolean      -- false → empty-slot shell fallback

---Resolve a slot to a runnable spec. Looks up `agents.bootstrap` first;
---falls back to a persistent shell terminal for unconfigured slots.
---Per-kind cmd resolution goes through `agent.adapters.<kind>` (D3).
---@param slot integer
---@return AutoAgentsResolvedSpec
local function resolve_slot_spec(slot)
  local cfg = M.state.config
  local agent = require("auto-agents.agent")
  local bootstrap = (cfg and cfg.agents and cfg.agents.bootstrap) or {}
  for _, entry in ipairs(bootstrap) do
    if entry.slot == slot then
      local kind = entry.kind or "generic"
      return {
        kind = kind,
        name = entry.name,
        title = entry.title,
        model = entry.model,
        cmd = agent.cmd_for(kind, entry),
        kb_scope = entry.kb_scope,
        diff_review = entry.diff_review == true,
        slot = slot,
        configured = true,
      }
    end
  end
  -- Unconfigured slot — fall back to the generic adapter (vim.o.shell).
  return {
    kind = "shell",
    name = nil,
    title = nil,
    cmd = agent.cmd_for("generic", {}),
    kb_scope = "shared",
    slot = slot,
    configured = false,
  }
end

---Build the env table merged for an agent's spawn — KB scope vars
---(M4) + resource grants (M5). Returns nil if no env extras to keep
---snacks's defaulting clean.
---
---Side effects (M6, KB-aware launch): ensures the KB layout and writes
---the per-kind instruction file (CLAUDE.md/AGENTS.md/GEMINI.md) at the
---agent's cwd so the TUI auto-loads project conventions on startup.
---Logs a one-line confirmation banner so the user sees it landed.
---@param spec AutoAgentsResolvedSpec
---@param cwd string|nil
---@return table<string,string>|nil
local function build_agent_env(spec, cwd)
  local cfg = M.state.config
  if not cfg then return nil end
  local kb = require("auto-agents.kb")
  local kb_root = kb.root()
  kb.ensure_layout(kb_root, {
    type = (cfg.kb or {}).type,
    seed_path = (cfg.kb or {}).seed_path,
  })
  local env = require("auto-agents.kb.scope").env_for(spec, kb_root)
  -- M5: merge in resource grants (AUTO_AGENTS_ALLOWED_PATHS, etc.).
  local resources_env = require("auto-agents.resources").env_for(spec.slot or 0)
  for k, v in pairs(resources_env) do env[k] = v end

  -- M6 diff-review bridge: opted-in agents get the env vars Claude
  -- Code CLI uses to find + authenticate to claudecode.nvim's MCP
  -- server. The headline tool is `openDiff` — proposed edits open
  -- as a reviewable diff split in the user's editor. Without the
  -- port, Claude Code CLI falls back to its TUI confirm prompt.
  if spec.diff_review and M.state.diff_review_port then
    env.ENABLE_IDE_INTEGRATION  = "true"
    env.FORCE_CODE_TERMINAL     = "true"
    env.CLAUDE_CODE_SSE_PORT    = tostring(M.state.diff_review_port)
  end

  -- M6 KB-aware launch: write the per-kind instruction file (idempotent)
  -- and emit a visible confirmation. This is the durable, TUI-safe way
  -- to inform the agent — sending stdin to claude/codex would be parsed
  -- as a prompt, so we lean on each kind's auto-loaded markdown.
  if spec.configured ~= false then  -- skip empty-slot shells
    local instr_path = require("auto-agents.kb.instruct").ensure(spec, kb_root, cwd)
    local logger = require("auto-agents.logger")
    logger.info("spawn",
      string.format("slot %s (%s/%s) → KB=%s scope=%s%s",
        tostring(spec.slot or "?"),
        spec.kind or "?",
        spec.name or "anon",
        kb_root,
        spec.kb_scope or "shared",
        instr_path and (" instr=" .. instr_path) or ""))
  end

  if next(env) == nil then return nil end
  return env
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
  -- Cache the resolved width so the diff-parity restore path uses the
  -- value the panel was opened at (not a fresh recompute) — otherwise
  -- a terminal resize between open and restore would make us snap to
  -- a different width than the user is currently looking at. The
  -- VimResized autocmd below updates this on terminal-size change.
  M.state.panel_width = width

  -- Window-local appearance (issue #2): drop line numbers and signs on
  -- the agent panel — terminals don't benefit from them and they collide
  -- with claude/codex TUI rendering.
  vim.api.nvim_set_option_value("number", false, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = winid })

  -- Lock the panel width: claudecode.nvim's diff handler runs
  -- `wincmd =` (equalize) when the diff vsplit opens, which would
  -- otherwise stretch our panel to ~1/3 of the editor. winfixwidth
  -- tells vim to leave THIS window's width alone during equalize and
  -- balance ops. Direct `nvim_win_set_width` calls bypass it, but
  -- those are caught by the AutoAgentsDiffParity autocmd hooks below.
  vim.api.nvim_set_option_value("winfixwidth", true, { win = winid })

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
  -- M5: explicit `resource cwd` grant > first path grant > cwd.resolve default.
  cwd = require("auto-agents.resources").cwd_for(slot, cwd)
  term = require("auto-agents.terminal").new(cfg, {
    cmd = spec.cmd,
    cwd = cwd,
    env = build_agent_env(spec, cwd),
    on_exit = function(code)
      logger.info("panel", "slot " .. slot .. " (" .. spec.kind .. ") exited code=" .. tostring(code))
      pcall(function() require("auto-agents.status.observer").detach(slot) end)
      if M.state.agent_status then M.state.agent_status[slot] = nil end
      M.refresh_winbar()
      M.refresh_dock()
    end,
  })
  local bufnr = term:start(winid)
  if not bufnr then return nil end
  M.state.slot_terminals[slot] = term
  pcall(function()
    require("auto-agents.status.observer").attach(slot, bufnr, spec.kind)
  end)
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

---Convenience proxies for the term module, so `require('auto-agents')`
---is enough for any playground terminal driver.

---Focus / hide / open dispatch for T1..T4. State machine:
---  no terminal     → open + focus
---  hidden          → re-open + focus
---  visible & blur  → focus
---  visible & focus → hide
---@param slot integer
function M.term_focus(slot)
  require("auto-agents.term.focus").focus_or_hide(slot)
end

---Paste-safe send to T-slot: chan_send body, 60ms defer, then \r.
---Pass `opts.submit = false` to skip the trailing CR.
---@param slot integer
---@param text string
---@param opts table|nil
---@return boolean
function M.term_send(slot, text, opts)
  return require("auto-agents.term").send(slot, text, opts)
end

---Build a human-readable description for a slot's keymap, derived from
---the agents.bootstrap config. Used by autovim's lazy spec to keep
---<leader>a[0..9] descriptions in sync with the actual configured kind/
---name. Optional `bootstrap` arg lets the lazy spec call this BEFORE
---setup() runs (when state.config isn't populated yet).
---@param slot integer
---@param bootstrap table[]|nil  -- list of bootstrap entries; defaults to current config
---@return string
function M.slot_desc(slot, bootstrap)
  if slot == 0 then
    return "Focus admin (slot 0)"
  end
  bootstrap = bootstrap or ((M.state.config or {}).agents or {}).bootstrap or {}
  for _, e in ipairs(bootstrap) do
    if e.slot == slot then
      local label = e.title or e.name or e.kind or "agent"
      return string.format("Focus slot %d — %s", slot, label)
    end
  end
  local where = (slot > M.MAIN_SLOT_MAX) and "float" or "main"
  return string.format("Focus slot %d — shell (%s, empty)", slot, where)
end

---Re-register the <leader>a[0..9] keymaps with descriptions reflecting
---current bootstrap state. Called automatically from agent rename /
---add / edit so which-key et al. stay in sync.
function M.refresh_keymaps()
  for slot = 0, 9 do
    pcall(vim.keymap.set, "n", "<leader>a" .. slot,
      "<cmd>AutoAgentsFocus " .. slot .. "<cr>",
      { desc = M.slot_desc(slot), silent = true })
  end
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
  cwd = require("auto-agents.resources").cwd_for(slot, cwd)
  local sub_term = float.toggle(cfg, slot, {
    cmd = spec.cmd,
    cwd = cwd,
    env = build_agent_env(spec, cwd),
    -- Metadata for the float title (snacks renders this in the bordered
    -- title position). Lets users distinguish e.g. two Claude floats.
    kind = spec.kind,
    name = spec.name,
    title = spec.title,
    on_exit = function(code)
      logger.info("float", "slot " .. slot .. " (" .. spec.kind .. ") exited code=" .. tostring(code))
      pcall(function() require("auto-agents.status.observer").detach(slot) end)
      if M.state.agent_status then M.state.agent_status[slot] = nil end
      M.refresh_winbar()
      M.refresh_dock()
    end,
  })
  if sub_term and sub_term.buf and vim.api.nvim_buf_is_valid(sub_term.buf) then
    pcall(function()
      require("auto-agents.status.observer").attach(slot, sub_term.buf, spec.kind)
    end)
  end
end

-- ── lifecycle (M3) ─────────────────────────────────────────────────────────

---Find and return the snacks terminal for a sub-agent slot, if any.
---Returns the term object or nil.
local function find_sub_term(slot)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks or not snacks.terminal then return nil end
  for _, term in ipairs(Snacks.terminal.list()) do
    if term.buf and vim.api.nvim_buf_is_valid(term.buf)
      and vim.b[term.buf].auto_agents_slot == slot then
      return term
    end
  end
  return nil
end

---Kill the agent process in a slot. For main slots (1..4) jobstops the
---terminal and wipes its buffer; for sub slots (5..9) closes the snacks
---float (which also stops the underlying job).
---@param slot integer
---@return boolean killed
function M.kill_slot(slot)
  local logger = require("auto-agents.logger")
  if slot >= 1 and slot <= M.MAIN_SLOT_MAX then
    local term = M.state.slot_terminals[slot]
    if not term then
      logger.info("lifecycle", "slot " .. slot .. " has no running terminal")
      return false
    end
    if term.kill then term:kill() end
    local buf = term.get_bufnr and term:get_bufnr() or nil
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    M.state.slot_terminals[slot] = nil
    -- If the panel was showing this slot, swap to admin so the dead
    -- buffer doesn't linger in the window.
    if M.state.focused_slot == slot and M.state.panel_winid
      and vim.api.nvim_win_is_valid(M.state.panel_winid) then
      M.focus_slot(0)
    end
    logger.info("lifecycle", "slot " .. slot .. " killed")
    return true
  elseif slot > M.MAIN_SLOT_MAX and slot <= M.MAX_SLOT then
    local term = find_sub_term(slot)
    if not term then
      logger.info("lifecycle", "sub slot " .. slot .. " has no running terminal")
      return false
    end
    if type(term.close) == "function" then pcall(term.close, term) end
    if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
      pcall(vim.api.nvim_buf_delete, term.buf, { force = true })
    end
    logger.info("lifecycle", "sub slot " .. slot .. " killed")
    return true
  end
  logger.error("lifecycle", "kill_slot: invalid slot " .. tostring(slot))
  return false
end

---Restart a slot — kill then re-spawn. For main slots, focuses the new
---terminal in the panel. For sub slots, opens the new float.
---@param slot integer
function M.restart_slot(slot)
  M.kill_slot(slot)
  vim.schedule(function() M.focus_slot(slot) end)
end

---Attach files to an agent slot — sends file paths via stdin so the
---agent has them as context. If `paths` is empty, queries the active
---tree explorer (neo-tree, oil, etc.) via integrations/tree.lua and
---uses whatever's selected/under-cursor there.
---@param slot integer
---@param paths string[]|nil  -- explicit paths; nil = ask tree integration
---@return boolean ok
---@return string|nil err
function M.attach_slot(slot, paths)
  local logger = require("auto-agents.logger")
  if not paths or #paths == 0 then
    local tree = require("auto-agents.integrations.tree")
    local files, err = tree.get_selected_files_from_tree()
    if not files or #files == 0 then
      return false, err or "no paths supplied and tree integration found nothing"
    end
    paths = files
  end
  local text = table.concat(paths, " ")
  local ok = M.send_slot(slot, text)
  if not ok then
    logger.warn("attach", "send to slot " .. slot .. " failed (no running agent?)")
    return false, "slot " .. slot .. " has no running agent or send failed"
  end
  return true, nil
end

-- ── tasks (M3.5) ────────────────────────────────────────────────────────────

---Find the bootstrap entry for a slot, mutating-friendly.
---@param slot integer
---@return table|nil entry
local function bootstrap_entry(slot)
  local cfg = M.state.config
  if not cfg or not cfg.agents or not cfg.agents.bootstrap then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == slot then return e end
  end
  return nil
end

---Append a task to the agent's task list.
---@param slot integer
---@param text string
---@return boolean ok
function M.task_add(slot, text)
  local entry = bootstrap_entry(slot)
  if not entry then return false end
  entry.tasks = entry.tasks or {}
  table.insert(entry.tasks, text)
  pcall(function() require("auto-agents.config.store").save_current() end)
  return true
end

---Mark a task as done — removes it from the list. (We chose remove over
---'mark complete' for v0.1.0 simplicity; the agent's purpose is forward.)
---@param slot integer
---@param index integer  -- 1-based
---@return boolean ok
---@return string|nil removed_text
function M.task_done(slot, index)
  local entry = bootstrap_entry(slot)
  if not entry or not entry.tasks then return false end
  if index < 1 or index > #entry.tasks then return false end
  local text = table.remove(entry.tasks, index)
  pcall(function() require("auto-agents.config.store").save_current() end)
  return true, text
end

---Return the task list for a slot, or empty table.
---@param slot integer
---@return string[]
function M.task_list(slot)
  local entry = bootstrap_entry(slot)
  if not entry or not entry.tasks then return {} end
  return entry.tasks
end

---Send `text` to the agent's stdin via `nvim_chan_send`. Works for both
---main slots (native terminal) and sub-float slots (snacks terminal).
---@param slot integer
---@param text string
---@return boolean ok
function M.send_slot(slot, text)
  if not text or text == "" then return false end
  if slot >= 1 and slot <= M.MAIN_SLOT_MAX then
    local term = M.state.slot_terminals[slot]
    if term and term:is_alive() and term.send then
      return term:send(text)
    end
    return false
  elseif slot > M.MAIN_SLOT_MAX and slot <= M.MAX_SLOT then
    local sterm = find_sub_term(slot)
    if sterm and sterm.buf and vim.api.nvim_buf_is_valid(sterm.buf) then
      local jobid = vim.b[sterm.buf].terminal_job_id
      if jobid then
        vim.api.nvim_chan_send(jobid, text)
        return true
      end
    end
    return false
  end
  return false
end

---Read VmRSS for a pid (Linux). Returns kB or nil if unavailable.
---@param pid integer
---@return integer|nil rss_kb
local function read_rss_kb(pid)
  local f = io.open("/proc/" .. tostring(pid) .. "/status", "r")
  if not f then return nil end
  local rss
  for line in f:lines() do
    local v = line:match("^VmRSS:%s+(%d+)")
    if v then rss = tonumber(v); break end
  end
  f:close()
  return rss
end

---Resolve the live PID for a slot (or nil if not running).
---@param slot integer
---@return integer|nil pid
local function pid_for_slot(slot)
  if slot >= 1 and slot <= M.MAIN_SLOT_MAX then
    local term = M.state.slot_terminals[slot]
    if not term or not term:is_alive() then return nil end
    if not term.get_jobid then return nil end
    local jobid = term:get_jobid()
    if not jobid or jobid <= 0 then return nil end
    local ok, pid = pcall(vim.fn.jobpid, jobid)
    return ok and pid or nil
  elseif slot > M.MAIN_SLOT_MAX and slot <= M.MAX_SLOT then
    local sterm = find_sub_term(slot)
    if not sterm or not sterm.buf or not vim.api.nvim_buf_is_valid(sterm.buf) then return nil end
    local jobid = vim.b[sterm.buf].terminal_job_id
    if not jobid then return nil end
    local ok, pid = pcall(vim.fn.jobpid, jobid)
    return ok and pid or nil
  end
  return nil
end

---Build a memory report across all running agents (Linux /proc only).
---Returns a list of strings suitable for printing into the admin buffer.
---@return string[] lines
function M.mem_report()
  local cfg = M.state.config or {}
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  local by_slot = {}
  for _, e in ipairs(bs) do by_slot[e.slot] = e end

  local lines = { "", "Memory (RSS, MB):" }
  local total = 0
  local any = false
  for slot = 1, M.MAX_SLOT do
    local pid = pid_for_slot(slot)
    if pid then
      any = true
      local rss_kb = read_rss_kb(pid)
      local rss_mb = rss_kb and math.floor(rss_kb / 1024) or nil
      local entry = by_slot[slot]
      local label = entry and (entry.title or entry.name or entry.kind) or "shell"
      local where = (slot > M.MAIN_SLOT_MAX) and "float" or "main"
      if rss_mb then
        total = total + rss_mb
        table.insert(lines, string.format("  %d  %-22s  %-5s  pid=%d  rss=%d MB", slot, label, where, pid, rss_mb))
      else
        table.insert(lines, string.format("  %d  %-22s  %-5s  pid=%d  rss=?", slot, label, where, pid))
      end
    end
  end
  if not any then
    table.insert(lines, "  (no running agents)")
  else
    table.insert(lines, string.format("  %30s total=%d MB", "", total))
  end
  table.insert(lines, "")
  return lines
end

---Move a slot's bootstrap entry + running terminal to a different slot.
---Restricted to same-side moves (both main 1..MAIN_SLOT_MAX or both
---sub MAIN_SLOT_MAX+1..MAX_SLOT) to avoid crossing the native/snacks
---divide. Cross-boundary moves require kill + add via the form.
---@param from integer
---@param to integer
---@param swap boolean|nil  -- if true, swap with destination's content
---@return boolean ok
---@return string|nil err
function M.move_slot(from, to, swap)
  if from == to then return false, "from and to are the same slot" end
  local function side(s)
    if s == 0 then return "admin" end
    if s >= 1 and s <= M.MAIN_SLOT_MAX then return "main" end
    if s > M.MAIN_SLOT_MAX and s <= M.MAX_SLOT then return "float" end
    return "invalid"
  end
  local sf, st = side(from), side(to)
  if sf == "invalid" or sf == "admin" then return false, "invalid 'from' slot " .. from end
  if st == "invalid" or st == "admin" then return false, "invalid 'to' slot " .. to end
  if sf ~= st then
    return false, "cross-boundary moves (main↔float) not yet supported; kill the source and re-add via the form"
  end

  local cfg = M.state.config
  if not cfg then return false, "auto-agents.setup() not called" end
  cfg.agents = cfg.agents or {}
  cfg.agents.bootstrap = cfg.agents.bootstrap or {}

  local entry_from, entry_to
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == from then entry_from = e
    elseif e.slot == to then entry_to = e end
  end

  if entry_to and not swap then
    return false, "destination slot " .. to .. " is occupied; pass --swap to exchange"
  end

  -- Mutate bootstrap entries.
  if entry_from then entry_from.slot = to end
  if entry_to and swap then entry_to.slot = from end

  -- Transfer running terminals on the same side.
  if sf == "main" then
    local t_from = M.state.slot_terminals[from]
    local t_to   = M.state.slot_terminals[to]
    M.state.slot_terminals[from] = swap and t_to or nil
    M.state.slot_terminals[to]   = t_from
  else
    -- Sub-float: re-stamp the slot marker on the underlying buffer(s).
    local sterm_from = find_sub_term(from)
    local sterm_to   = find_sub_term(to)
    if sterm_from and sterm_from.buf and vim.api.nvim_buf_is_valid(sterm_from.buf) then
      vim.b[sterm_from.buf].auto_agents_slot = to
    end
    if swap and sterm_to and sterm_to.buf and vim.api.nvim_buf_is_valid(sterm_to.buf) then
      vim.b[sterm_to.buf].auto_agents_slot = from
    end
  end

  -- Refresh focused_slot if the move moved the focused terminal.
  if M.state.focused_slot == from then
    M.state.focused_slot = to
  elseif M.state.focused_slot == to and swap then
    M.state.focused_slot = from
  end

  -- Refresh keymap descriptions and panel winbar.
  M.refresh_keymaps()
  M.refresh_winbar()
  pcall(function() require("auto-agents.config.store").save_current() end)
  return true, nil
end

---Re-render the panel winbar with the current focused slot + slot
---statuses. Idempotent — bails silently if the panel isn't open. Called
---after any state change that affects what the winbar displays
---(focused slot, slot rename, slot move, status transition, agent exit).
function M.refresh_winbar()
  if not (M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid)) then
    return
  end
  local winbar = require("auto-agents.panel.winbar")
  local w = vim.api.nvim_win_get_width(M.state.panel_winid)
  pcall(vim.api.nvim_set_option_value, "winbar",
    winbar.render(M.state.focused_slot or 1, w),
    { win = M.state.panel_winid })
end

---Re-render the navigator dock, if it's currently open. Cheap no-op
---otherwise. Called from the same code paths as refresh_winbar so the
---two surfaces stay in lock-step.
function M.refresh_dock()
  pcall(function() require("auto-agents.dock").refresh() end)
end

---Rename a slot's bootstrap entry (mutates config.agents.bootstrap).
---No process restart — the new name surfaces in winbar/status on the
---next render cycle.
---@param slot integer
---@param new_name string
---@return boolean
function M.rename_slot(slot, new_name)
  local cfg = M.state.config
  if not cfg then return false end
  cfg.agents = cfg.agents or {}
  cfg.agents.bootstrap = cfg.agents.bootstrap or {}
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == slot then
      e.name = new_name
      if slot >= 0 and slot <= M.MAIN_SLOT_MAX then
        M.refresh_winbar()
      end
      M.refresh_keymaps()
      pcall(function() require("auto-agents.config.store").save_current() end)
      return true
    end
  end
  return false
end

local STATUSES = { idle = true, waiting = true, working = true }

---Resolve a numeric slot or agent name to a slot number.
---@param slot_or_name integer|string
---@return integer|nil slot
local function resolve_status_slot(slot_or_name)
  if type(slot_or_name) == "number" then return slot_or_name end
  local n = tonumber(slot_or_name)
  if n then return n end
  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.name == slot_or_name then return e.slot end
  end
  return nil
end

---@param slot integer
---@return "idle"|"waiting"|"working"
function M.get_status(slot)
  return (M.state.agent_status or {})[slot] or "idle"
end

---List every configured slot's current state. Intended for a manager
---agent that wants a single-call snapshot of the panel without having
---to read the underlying state table directly.
---@return { slot: integer, name: string, kind: string, state: "idle"|"waiting"|"working", alive: boolean }[]
function M.list_status()
  local out = {}
  local cfg = M.state.config
  local bs = (cfg and cfg.agents and cfg.agents.bootstrap) or {}
  local seen = {}
  for _, e in ipairs(bs) do
    local slot = e.slot
    if slot and not seen[slot] then
      seen[slot] = true
      local term = M.state.slot_terminals[slot]
      local alive = (term and term.is_alive and term:is_alive()) and true or false
      table.insert(out, {
        slot = slot,
        name = e.name or ("agent" .. slot),
        kind = e.kind or "?",
        state = (M.state.agent_status or {})[slot] or "idle",
        alive = alive,
      })
    end
  end
  table.sort(out, function(a, b) return a.slot < b.slot end)
  return out
end

---Plain-text report — one line per slot. Used by
---`:AutoAgentsStatusReport` and consumable by other agents via
---`nvim --server "$NVIM" --remote-expr 'execute("AutoAgentsStatusReport")'`.
---@return string[]
function M.status_report()
  local lines = {}
  for _, e in ipairs(M.list_status()) do
    local liveness = e.alive and "" or " [dead]"
    table.insert(lines, string.format(
      "slot %d  %-20s  (%s)  %s%s", e.slot, e.name, e.kind, e.state, liveness))
  end
  return lines
end

---Set an agent slot's runtime status. Slot identified by numeric slot
---or by configured agent name. State must be one of idle/waiting/working.
---"idle" clears the entry (kept sparse). Triggers a winbar refresh so
---the sigil updates without waiting for the next focus event.
---
---Used by `:AutoAgentsStatus`, which agents themselves invoke via
---`nvim --server "$NVIM" --remote-expr 'execute("AutoAgentsStatus ...")'`.
---
---@param slot_or_name integer|string
---@param state "idle"|"waiting"|"working"
---@return boolean ok
---@return string message
function M.set_status(slot_or_name, state)
  if not STATUSES[state] then
    return false, "state must be one of idle|waiting|working, got " .. tostring(state)
  end
  local slot = resolve_status_slot(slot_or_name)
  if not slot or slot < 0 or slot > M.MAX_SLOT then
    return false, "no slot/agent matched '" .. tostring(slot_or_name) .. "'"
  end
  -- Lazy-init in case state was loaded by a stale module (the original
  -- init.lua before this field was added). Belt-and-suspenders.
  M.state.agent_status = M.state.agent_status or {}
  if state == "idle" then
    M.state.agent_status[slot] = nil
  else
    M.state.agent_status[slot] = state
  end
  -- Cooperate with the passive observer. Explicit `waiting` becomes a
  -- sticky pin (survives until output resumes). Explicit idle/working
  -- clears any pin so the observer can take over again.
  pcall(function()
    local obs = require("auto-agents.status.observer")
    if state == "waiting" then obs.pin_waiting(slot)
    else obs.clear_pin(slot) end
  end)
  M.refresh_winbar()
  M.refresh_dock()
  return true, "slot " .. slot .. " → " .. state
end

-- ── focus (existing) ───────────────────────────────────────────────────────

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

  if slot > M.MAIN_SLOT_MAX and slot <= M.MAX_SLOT then
    M.toggle_sub(slot)
    return
  end

  if slot < 0 or slot > M.MAIN_SLOT_MAX then
    logger.error("init", "focus_slot: slot must be 0.." .. M.MAX_SLOT .. ", got " .. tostring(slot))
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

  -- D10 winbar tab-strip: all main slots, focused one bracketed, each
  -- wrapped in a clickable region. Adaptive: full labels when panel is
  -- wide enough, focused-only labels when it isn't. Implementation in
  -- panel/winbar.lua.
  do
    local winbar = require("auto-agents.panel.winbar")
    winbar.ensure_highlights()
    local w = vim.api.nvim_win_get_width(winid)
    pcall(vim.api.nvim_set_option_value, "winbar", winbar.render(slot, w), { win = winid })
  end
  if slot >= 1 then
    -- Defensive resize: send SIGWINCH to the TUI so it redraws at the
    -- panel's current dimensions, with bottom_margin rows reserved so
    -- the TUI's own status line doesn't sit flush against vim's
    -- statusline/cmdline. Margin resolves per-slot first (bootstrap
    -- entry's bottom_margin), then falls back to cfg.panel default.
    -- Different TUIs have different internal padding (codex pads
    -- internally; claude doesn't) so per-slot override is essential.
    local term = M.state.slot_terminals[slot]
    if term and term.resize_to then
      local margin = cfg.panel.bottom_margin or 0
      local bs = (cfg.agents and cfg.agents.bootstrap) or {}
      for _, e in ipairs(bs) do
        if e.slot == slot and e.bottom_margin ~= nil then
          margin = e.bottom_margin
          break
        end
      end
      term:resize_to(winid, { bottom_margin = margin })
    end
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
