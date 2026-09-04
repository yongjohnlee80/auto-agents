---Public API for auto-agents.nvim.
---@module 'auto-agents'

require("auto-agents.types")

local M = {}

M.version = "0.2.58"

-- Mailbox root resolution lives in
-- `lua/auto-agents/runtime/identity.lua` (ADR 0029 Decision #3) so
-- spawn, refresh_agent_id, and adopt-resumed-agent share one source
-- of truth. v0.1.33 (auto-core) workspace-scoped layout — the
-- resolver consults `auto-core.git.worktree.get_workspace_root()`
-- / `get_active()` per [[auto-family-state-ownership]]; agents
-- land at `<workspace>/.auto-agents/mailbox/<instance>/<name>/`.
-- Tests override the resolved root via the single
-- `AUTO_AGENTS_MAILBOX_ROOT` env.

-- Slot stratification (post-v0.1.24 flat-slot refactor). Slot 0 is
-- admin; slots 1..MAX_SLOT are main agents in the right panel. There
-- is no longer a "float" tier — `MAX_SLOT` is derived from
-- `cfg.panel.slot_count` at setup time and updated when the admin
-- DSL's `slot add N` / `slot remove N` mutates the count.
--
-- Default value reflects the previous MAIN_SLOT_MAX = 5; the
-- module-level boot-time value is 5 so any code path that fires
-- before `M.setup` (notably keymap registration in autovim's
-- `lua/plugins/auto-agents.lua`) gets a sane number. Setup overrides
-- this with the active `cfg.panel.slot_count`.
M.MAX_SLOT = 5

-- MAIN_SLOT_MAX is kept as a backwards-compat alias that always
-- equals MAX_SLOT after the flat refactor. External plugins that
-- still read it (auto-agents' own dock, integrations) get the same
-- value either way; there is no longer a separate "main" vs.
-- "float" range.
M.MAIN_SLOT_MAX = M.MAX_SLOT

---Window-local marker stamped on the panel window. The
---`ensure_main_window` discovery path scans for any window in the
---current tabpage carrying this marker before creating a new vsplit
---— guards against orphan duplicates when the cached
---`state.panel_winid` is gone (lazy reload, manual `:close`, plugin
---reload via Lazy, etc.) but the actual window is still alive.
M.PANEL_WIN_VAR = "auto_agents_panel"

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
  -- Re-entrancy flag for the panel buffer guard. Set to true by
  -- focus_slot and any other code path that legitimately swaps a
  -- buffer into the panel window. The guard skips bouncing while
  -- this is set so we don't fight ourselves.
  mounting = false,
}

---Resolve the bottom_margin to use for a slot — per-slot bootstrap
---override first, then panel-level default. Used by both focus_slot
---and the VimResized handler so they pick the same value.
---@param slot integer
---@param cfg AutoAgentsConfig
---@return integer
local function _resolve_bottom_margin(slot, cfg)
  local margin = (cfg.panel and cfg.panel.bottom_margin) or 0
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  for _, e in ipairs(bs) do
    if e.slot == slot and e.bottom_margin ~= nil then
      return e.bottom_margin
    end
  end
  return margin
end

---Refresh the cached panel width from the new terminal columns AND
---re-issue jobresize on every running main-slot terminal so each TUI
---gets a fresh SIGWINCH at the now-correct width.
---
---v0.2.0 migration: the actual width recompute + nvim_win_set_width
---moves to auto-core's `panel:refresh_width()` (which honors a
---sticky pin from `:resize`). auto-agents keeps the terminal-fanout
---loop because that's PTY-specific to slot terminals — auto-core
---panels don't know about agent terminals.
---
---Note: auto-core's Panel autoinstalls its own VimResized handler
---that calls `:refresh_width()`, so technically the auto-agents-side
---VimResized hook below is redundant for the WIDTH part. We keep it
---for the FANOUT part — without it, terminals would keep drawing at
---the pre-resize width until their slot is next focused.
local function _refresh_panel_width_cache()
  local cfg = M.state.config
  if not cfg then return end
  if M._panel then
    M._panel:refresh_width()
    if M._panel.winid and vim.api.nvim_win_is_valid(M._panel.winid) then
      M.state.panel_winid = M._panel.winid
      M.state.panel_width = vim.api.nvim_win_get_width(M._panel.winid)
    end
  end
  local panel = M.state.panel_winid
  if not panel or not vim.api.nvim_win_is_valid(panel) then return end

  -- Forward the resize to every running main-slot TUI so its PTY width
  -- matches the panel's new dims. Sub-slot floats are skipped here —
  -- their own float lib handles resize. Cheap: ~one ioctl per alive
  -- terminal per resize event.
  for slot, term in pairs(M.state.slot_terminals or {}) do
    if term and term.resize_to and term.is_alive and term:is_alive() then
      term:resize_to(panel, { bottom_margin = _resolve_bottom_margin(slot, cfg) })
    end
  end
end

---Public wrapper around the internal panel-width refresher. Used by
---the admin REPL (`panel resize` / `panel reset`) so a persisted
---`panel.width_override` change takes effect live without requiring a
---panel close/reopen.
function M.refresh_panel_width()
  _refresh_panel_width_cache()
end

---Re-sync `M.MAX_SLOT` / `M.MAIN_SLOT_MAX` from `state.config.panel.slot_count`.
---Called by the admin DSL (`slot add` / `slot remove`) after it
---mutates `cfg.panel.slot_count` so subsequent `focus_slot` calls,
---winbar renders, and dock dispatches see the new bound. Idempotent.
function M.sync_slot_count()
  local cfg = M.state.config
  if not cfg or not cfg.panel then return end
  M.MAX_SLOT = cfg.panel.slot_count
  M.MAIN_SLOT_MAX = cfg.panel.slot_count
  -- Refresh the panel winbar so the tab strip grows/shrinks immediately.
  if M.refresh_winbar then pcall(M.refresh_winbar) end
end

---Install the VimResized hook that keeps the cached panel width in
---sync with terminal size + fans out SIGWINCH to running agent
---terminals so their PTYs match the new dims.
local function install_resize_hooks()
  local group = vim.api.nvim_create_augroup("AutoAgentsResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = _refresh_panel_width_cache,
  })
end

---@param opts table?
function M.setup(opts)
  local config = require("auto-agents.config").apply(opts or {})
  require("auto-agents.log").setup(config)

  -- Apply the persisted slot_count to module-level MAX_SLOT so all
  -- slot-bounded code paths (focus_slot, agent dispatch, winbar tab
  -- strip, dock, admin REPL guards) see the same value. The `slot
  -- add` / `slot remove` admin verbs mutate cfg.panel.slot_count and
  -- re-sync via M._sync_slot_count_from_config.
  M.MAX_SLOT = config.panel.slot_count
  M.MAIN_SLOT_MAX = config.panel.slot_count

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

  -- v0.2.0 migration: panel slot_count + width_override + focused_slot
  -- now live in auto-core.state.namespace("auto-agents") with json
  -- persist. The TOML store keeps the agent bootstrap rows + kb config;
  -- this block owns ambient panel state.
  --
  -- Sequence:
  --   1. Claim the namespace (idempotent).
  --   2. **Validated** seed from the TOML loader's panel block —
  --      `state.set_slot_count` / `state.set_width_override`
  --      validate against cfg.SLOT_COUNT_MIN/MAX + PANEL_OVERRIDE_*
  --      and return (false, err) for out-of-range; we warn and let
  --      the namespace default stand. (The TOML save path strips
  --      these keys on next save, so legacy values eventually drain.)
  --   3. Read the namespace back into cfg.panel.* so the dozens of
  --      reader sites that walk `cfg.panel.slot_count` /
  --      `cfg.panel.width_override` keep working unchanged.
  --   4. Install watchers that re-sync cfg.panel + call the side-
  --      effect functions (sync_slot_count, refresh_panel_width)
  --      automatically on every namespace mutation. Setters in
  --      panel/admin.lua go through state.set_* and trigger this.
  --   5. focused_slot likewise mirrors into M.state.focused_slot.
  local state_mod = require("auto-agents.state")
  state_mod.setup()

  if loaded and loaded.panel then
    if loaded.panel.slot_count ~= nil then
      local ok_sc, err_sc = state_mod.set_slot_count(loaded.panel.slot_count)
      if not ok_sc then
        require("auto-agents.log").warn("init",
          "ignoring legacy TOML panel.slot_count: " .. tostring(err_sc)
            .. "; using default 5")
      end
    end
    if loaded.panel.width_override ~= nil then
      local ok_wo, err_wo = state_mod.set_width_override(loaded.panel.width_override)
      if not ok_wo then
        require("auto-agents.log").warn("init",
          "ignoring legacy TOML panel.width_override: " .. tostring(err_wo))
      end
    end
  end

  -- Read namespace values into the live config / state mirrors.
  config.panel = config.panel or {}
  config.panel.slot_count     = state_mod.get_slot_count()
  config.panel.width_override = state_mod.get_width_override()
  M.state.focused_slot        = state_mod.get_focused_slot()
  M.MAX_SLOT      = config.panel.slot_count
  M.MAIN_SLOT_MAX = config.panel.slot_count

  -- v0.2.0 panel migration: claim the auto-core.ui.panel singleton.
  -- The panel name "auto-agents" produces marker var `auto_agents_panel`
  -- after auto-core's `[^%w_]` → `_` substitution — identical to the
  -- prior local M.PANEL_WIN_VAR, so external readers (notably
  -- integrations/editor_floor.lua and auto-finder's editor-floor
  -- invariant) keep working without changes. winfixwidth + winfixbuf,
  -- number/signcolumn/foldcolumn defaults, orphan-adoption, and the
  -- WinResized/VimResized auto-pin enforcement all move to auto-core.
  local panel_mod = require("auto-core").ui.panel
  M._panel = panel_mod.new({
    name  = "auto-agents",
    side  = config.panel.side,
    width = {
      percentage = config.panel.percentage,
      min        = config.panel.min_width,
      max        = config.panel.max_width,
    },
    -- filetype intentionally nil: each slot mounts its own buffer
    -- with its own filetype; the panel host doesn't impose one.
    on_open = function(winid)
      M.state.panel_winid = winid
      M.state.panel_width = vim.api.nvim_win_get_width(winid)
    end,
    on_close = function()
      M.state.panel_winid = nil
    end,
  })
  -- Apply any persisted width pin so the very first open uses it.
  local pin = state_mod.get_width_override()
  if pin then M._panel:resize(pin) end

  -- Watcher: slot_count change → mirror + sync_slot_count +
  -- refresh_keymaps. The keymap re-registration is what makes
  -- `slot add N` / `slot remove N` reflect in `<leader>aN`
  -- bindings immediately: setup() owns the initial registration,
  -- and this watcher keeps it in sync without a nvim restart.
  -- Without this hook, growing slot_count from 7 to 9 would
  -- leave `<leader>a8` / `<leader>a9` unbound until the next
  -- agent rename / move / remove (the only other refresh_keymaps
  -- callsites).
  state_mod.watch_slot_count(function(payload)
    config.panel.slot_count = payload.new
    M.sync_slot_count()
    M.refresh_keymaps()
  end)

  -- Watcher: width_override change → mirror + drive the panel's
  -- sticky pin (auto-core's panel:resize / :reset_width handle
  -- the actual nvim_win_set_width). The terminal SIGWINCH fanout
  -- still goes through M.refresh_panel_width below.
  state_mod.watch_width_override(function(payload)
    config.panel.width_override = payload.new
    if M._panel then
      if payload.new then
        M._panel:resize(payload.new)
      else
        M._panel:reset_width()
      end
    end
    if M.refresh_panel_width then M.refresh_panel_width() end
  end)

  -- Watcher: focused_slot change → mirror.
  state_mod.watch_focused_slot(function(payload)
    M.state.focused_slot = payload.new
  end)

  -- M5: load resource grants for this project.
  require("auto-agents.resources.grants").load()
  M.state.config = config
  M.state.initialized = true

  -- v0.2.30: workspace-scoped mailbox housekeeping. (1) Append
  -- `.auto-agents/` to the workspace `.gitignore` if missing so the
  -- mailbox tree never ends up tracked. (2) Surface a one-line
  -- migration warning if any legacy per-CLI mailbox dirs are
  -- detected, so the user knows running agents may need re-spawn.
  -- ADR-0039 C4: capture + log — a silent failure here hides broken
  -- housekeeping (gitignore, legacy detection, mailbox prune).
  local ok_housekeeping, housekeeping_err = pcall(function()
    local identity = require("auto-agents.runtime.identity")
    local logger = require("auto-agents.log")
    local mailbox_root = identity.mailbox_root()
    -- workspace_root is the parent of `.auto-agents/mailbox`.
    local workspace_root = mailbox_root:gsub("/%.auto%-agents/mailbox$", "")
    local gitignore_path = workspace_root .. "/.gitignore"
    local needs_append = true
    local f = io.open(gitignore_path, "r")
    if f then
      for line in f:lines() do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s == ".auto-agents/" or s == ".auto-agents"
           or s == "/.auto-agents/" or s == "/.auto-agents" then
          needs_append = false
          break
        end
      end
      f:close()
    end
    if needs_append then
      local append = io.open(gitignore_path, "a")
      if append then
        append:write("\n# auto-agents workspace mailbox (v0.2.30+)\n.auto-agents/\n")
        append:close()
        logger.info("setup", ("appended `.auto-agents/` to %s"):format(gitignore_path))
      end
    end
    -- Legacy-layout detection. The old per-CLI mailbox roots are
    -- `~/.claude/mailbox`, `~/.codex/mailbox`, `~/.gemini/mailbox`.
    -- If any has agent:* subdirs left over from a prior auto-agents
    -- version, warn once so the user can re-spawn slots (the new
    -- workspace-scoped routing won't see the old dirs).
    local legacy = { "~/.claude/mailbox", "~/.codex/mailbox", "~/.gemini/mailbox" }
    local stale = {}
    for _, p in ipairs(legacy) do
      local expanded = vim.fn.expand(p)
      if vim.fn.isdirectory(expanded) == 1 then
        local sd = vim.uv.fs_scandir(expanded)
        if sd then
          while true do
            local name, type_ = vim.uv.fs_scandir_next(sd)
            if not name then break end
            if type_ == "directory" and name:match("^agent:") then
              stale[#stale + 1] = expanded .. "/" .. name
              break  -- one example per root is enough
            end
          end
        end
      end
    end
    if #stale > 0 then
      logger.warn("setup",
        ("v0.2.30 layout: %d legacy mailbox dir(s) detected (e.g. %s). "
         .. "Live slots writing there won't see the new workspace mailbox "
         .. "at %s — restart affected slots or run mailbox.prune on the legacy roots."):format(
          #stale, stale[1], mailbox_root))
    end

    -- v0.2.30 / Phase 6: prune stale per-instance mailbox dirs at
    -- setup. `auto-core.mailbox.prune` walks <root>/<instance>/<name>/,
    -- matches against the live registry by `rec.dir`, and removes
    -- subtrees older than `max_age_seconds` (default 7 days). Live
    -- registrations are kept regardless of age; nothing in the
    -- current nvim's working tree is at risk. Default ON to keep
    -- the per-instance dir count bounded; cfg.mailbox.prune.enabled
    -- = false opts out, cfg.mailbox.prune.max_age_seconds adjusts.
    local prune_cfg = (config.mailbox and config.mailbox.prune) or {}
    local prune_enabled = prune_cfg.enabled
    if prune_enabled == nil then prune_enabled = true end
    if prune_enabled then
      local max_age = tonumber(prune_cfg.max_age_seconds) or (7 * 24 * 60 * 60)
      local ok_core, core = pcall(require, "auto-core")
      if ok_core then
        -- `force = true` because this setup-time prune fires BEFORE
        -- auto-agents registers the `nvim` host mailbox, so the
        -- workspace root has zero live registrations at this moment
        -- — auto-core's safety rail (Phase 8) would otherwise refuse.
        -- We know we're pruning auto-agents' own workspace tree; the
        -- rail exists for ad-hoc callers who might typo a path.
        local res = core.mailbox.prune({
          root            = mailbox_root,
          max_age_seconds = max_age,
          force           = true,
        })
        if res and (res.refused or #(res.removed or {}) > 0
           or #(res.failed or {}) > 0) then
          if res.refused then
            logger.warn("setup", string.format(
              "mailbox.prune refused: %s (root=%s)",
              tostring(res.reason), mailbox_root))
          else
            logger.info("setup", string.format(
              "mailbox.prune: removed=%d kept_alive=%d kept_recent=%d failed=%d "
              .. "(root=%s, max_age=%ds)",
              #res.removed, #res.kept_alive, #res.kept_recent, #(res.failed or {}),
              mailbox_root, max_age))
          end
        end
      end
    end
  end)
  if not ok_housekeeping then
    require("auto-agents.log").warn("setup",
      "workspace mailbox housekeeping failed: " .. tostring(housekeeping_err))
  end

  -- M6 diff-review bridge: agents opted in via `diff_review =
  -- true` in TOML will route their openDiff requests to our native
  -- unified queue via a first-party MCP bridge (SSE over HTTP).
  M.state.diff_review_enabled = false
  M.state.diff_review_port = nil
  for _, e in ipairs(config.agents.bootstrap) do
    if e.diff_review then M.state.diff_review_enabled = true; break end
  end
  if M.state.diff_review_enabled then
    local mcp = require("auto-agents.mcp.server")
    local port = mcp.start()
    if port then
      M.state.diff_review_port = port
      require("auto-agents.log").info("init",
        "diff-review bridge ready on port " .. tostring(port))
    else
      require("auto-agents.log").error("init",
        "failed to start diff-review bridge (MCP server)")
    end
  end

  -- Keep the cached panel width in sync with terminal size and fan
  -- out SIGWINCH to running agent terminals on resize. Independent of
  -- diff-review — runs whether or not the MCP bridge is enabled.
  install_resize_hooks()

  -- v0.2.7: wire the auto-core mailbox subsystem. Start the central
  -- router and register the `nvim` executioner mailbox so agents can
  -- send `kind="command"` messages back to us. Per-agent registration
  -- happens later in `build_agent_env` so each spawn gets a fresh
  -- per-instance mailbox + the four
  -- `AUTO_AGENTS_INSTANCE_ID/MAILBOX_ID/MAILBOX_DIR/MAILBOX_BOOTSTRAP_DOC`
  -- env vars consumers need.
  --
  -- v0.2.8: register auto-agents-owned mailbox commands with auto-core's
  -- whitelist registry — `send_slot` (wake hook used by the router on
  -- inbox/responses arrival; previously a no-op because nothing claimed
  -- the name) and `send_user` (vim.notify bridge). Other plugins
  -- (md-harpoon for `harpoon`, the diff MCP for an `openDiff` mirror,
  -- etc.) register their own commands via the same
  -- `auto-core.mailbox.commands.register` API when they load — this is
  -- just auto-agents' contribution to the whitelist.
  -- ADR-0039 C4: capture + log — a silent failure here means agents
  -- lose their entire command surface (wake/say/todos.*) with zero
  -- diagnostics. Failures here are ERROR-class per auto-family-logging.
  local ok_mailbox_wire, mailbox_wire_err = pcall(function()
    local mailbox = require("auto-core").mailbox
    mailbox.configure({ autostart = true })
    mailbox.register("nvim", { root = mailbox.host_fallback_root() })
    require("auto-agents.mailbox.commands").register_all()
    -- v0.2.37: register the 13 todos.* command verbs + install
    -- the `core.todo.assignee:changed` mailbox-routing subscriber
    -- so `auto-core.todo.assign()` / `todos.assign` notify the
    -- recipient agent's inbox (per ADR-0031 §5 + lector S1).
    local ok_todos, todos_mod = pcall(require, "auto-agents.mailbox.todos_commands")
    if ok_todos then
      todos_mod.register_all()
      todos_mod.install_assignee_routing()
    else
      require("auto-agents.log").warn("init",
        "todos.* mailbox surface unavailable: " .. tostring(todos_mod))
    end

    -- ADR-0067 A3: the review.* surface, registered INDEPENDENTLY of todos.*.
    -- It was nested inside the todos success branch, so an unrelated todos
    -- module load failure removed the entire review surface — two unrelated
    -- capabilities sharing one failure.
    local ok_rev, rev_mod = pcall(require, "auto-agents.mailbox.review_commands")
    if ok_rev then
      rev_mod.register_all()
    else
      require("auto-agents.log").warn("init",
        "review.* mailbox surface unavailable: " .. tostring(rev_mod))
    end

    -- ADR-0035 Phase 2: register auto-agents-owned execute primitives
    -- with the auto-core automation engine, and install the KB-audit
    -- subscriber. Auto-core knows nothing about slots, terminals, or
    -- the KB — that knowledge stays here, behind the hook/executor
    -- registry boundary per ADR-0035 §"Plugin boundaries (recap)".
    local ok_aa_auto, aa_auto = pcall(require, "auto-agents.todo_automation")
    if ok_aa_auto then
      local ok_install, install_err = pcall(aa_auto.install)
      if not ok_install then
        require("auto-agents.log").warn("init",
          "todo automation install failed: " .. tostring(install_err))
      end
    else
      require("auto-agents.log").warn("init",
        "todo_automation module unavailable: " .. tostring(aa_auto))
    end
  end)
  if not ok_mailbox_wire then
    require("auto-agents.log").error("init",
      "mailbox wiring failed — agent command surface is DOWN: "
      .. tostring(mailbox_wire_err))
  end

  -- Editor-window-floor invariant. AutoVim's three-column layout
  -- (AutoFinder | Editor | AutoAgents) needs at least one editor window
  -- to remain usable; without it claudecode diff requests can't find a
  -- target and either hit E1513 (winfixbuf on auto-finder) or
  -- manufacture a split inside our panel column. The integration owns
  -- both the WinClosed-recovery autocmd and the BufWinEnter diff-route
  -- gate. Defaults: post-:q create-scratch, diff manufactured-by-
  -- claudecode warn-and-close.
  -- ADR-0039 C4: capture + log instead of silent swallow.
  local ok_floor, floor_err = pcall(function()
    require("auto-agents.integrations.editor_floor").install(config)
  end)
  if not ok_floor then
    require("auto-agents.log").warn("init",
      "editor-floor integration install failed: " .. tostring(floor_err))
  end

  -- Default the initial focus to admin (slot 0) when no agents are
  -- configured. Otherwise the first :AutoAgents drops you into a
  -- fallback shell at slot 1 — the wizard auto-engages from admin, so
  -- admin is the right landing slot for an empty config. With agents
  -- loaded, the previous focused_slot (or 1) still applies.
  if #config.agents.bootstrap == 0 then
    -- v0.2.0: route through state.set so the namespace persists +
    -- the watcher mirrors back into M.state.focused_slot.
    require("auto-agents.state").set_focused_slot(0)
  end

  -- Panel buffer protection is handled by `winfixbuf = true` on the
  -- panel window (set in ensure_main_window). vim itself refuses to
  -- replace the panel's buffer via :edit / :buffer / b# — bufferline
  -- click, neo-tree's :edit-from-current, etc. all error E1513.
  -- (Earlier BufWinEnter/BufEnter guard removed in v0.1.23+1 because
  -- it raced with termopen and produced duplicate terminal windows.)
  -- Clear any leftover guard augroup from older versions for hot-reload.
  pcall(vim.api.nvim_del_augroup_by_name, "AutoAgentsPanelGuard")

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

  -- v0.1.24 migration warning: agents bootstrapped to slots > slot_count
  -- (formerly the float range, slots 6..9 by default) become invalid in
  -- the flat-slot model. Surface them so the user knows to either grow
  -- slot_count via `slot add N` or `agent move <hi> <lo>` to a valid
  -- slot. We don't auto-promote — slot_count is a deliberate user
  -- decision, not something the plugin should override.
  do
    local high = {}
    for _, e in ipairs(config.agents.bootstrap) do
      if type(e.slot) == "number" and e.slot > config.panel.slot_count then
        high[#high + 1] = e
      end
    end
    if #high > 0 then
      local labels = {}
      for _, e in ipairs(high) do
        labels[#labels + 1] = string.format("slot %d (%s)",
          e.slot, e.title or e.name or e.kind or "agent")
      end
      require("auto-agents.log").warn("init",
        ("v0.1.24 migration: %d agent%s configured to slot%s above slot_count=%d: %s. "
          .. "Either run `slot add %d` in the admin REPL to grow the panel, "
          .. "or move the agent%s to a slot in 1..%d via `agent move <hi> <lo>`.")
          :format(#high, #high == 1 and "" or "s",
                  #high == 1 and "" or "s",
                  config.panel.slot_count,
                  table.concat(labels, ", "),
                  -- Suggest growing by enough to cover the highest one.
                  ((function()
                    local maxh = 0
                    for _, e in ipairs(high) do
                      if e.slot > maxh then maxh = e.slot end
                    end
                    return maxh - config.panel.slot_count
                  end)()),
                  #high == 1 and "" or "s",
                  config.panel.slot_count))
    end
  end

  -- Refresh `<leader>aN` keymap descriptions now that the bootstrap
  -- is populated. The autovim consumer's lazy.nvim spec registers
  -- these keys with static descriptions ("Focus slot N"); this call
  -- overrides them with live `slot_desc(N)` ("Focus slot N — Jarvis",
  -- "Focus slot N — shell", etc.) so which-key shows agent identity
  -- immediately, not just after the first rename/move/remove.
  M.refresh_keymaps()

  require("auto-agents.log").info("init",
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
---@field model string|nil        -- preferred model id (--model for claude/codex/junie/opencode; GOOSE_MODEL env for goose; silently ignored for antigravity/copilot/generic)
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

  -- v0.2.40: two todos-related env vars for spawned agents.
  --
  -- AUTO_AGENTS_TODOS_BOOTSTRAP_DOC — absolute path to the
  -- bundled `bootstrap-todos.md` (operational reference for
  -- the `todos.*` command surface). Mirrors the existing
  -- AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC pattern. Soft: skipped
  -- when the doc can't be located on the runtimepath.
  --
  -- AUTO_AGENTS_TODOS_CONVENTION_DOC — absolute path to the
  -- per-KB todo-handling convention (seeded by ensure_layout;
  -- per-project customizable). Agents track the convention's
  -- `revision:` in their own local memory and re-ingest on
  -- change per the doc's own protocol.
  local ok_todos, todos_mod = pcall(require, "auto-agents.mailbox.todos_commands")
  if ok_todos and type(todos_mod.bootstrap_doc_path) == "function" then
    local doc_path = todos_mod.bootstrap_doc_path()
    if doc_path and doc_path ~= "" then
      env.AUTO_AGENTS_TODOS_BOOTSTRAP_DOC = doc_path
    end
  end
  do
    local conv = kb_root .. "/shared/conventions/todo-handling.md"
    if vim.fn.filereadable(conv) == 1 then
      env.AUTO_AGENTS_TODOS_CONVENTION_DOC = conv
    end
  end

  -- v0.2.26: per-agent diff_review gate. Direct, unambiguous signal
  -- the agent can self-check via `[ "$AUTO_AGENTS_DIFF_REVIEW" = "true" ]`
  -- without parsing the AGENTS.md/CLAUDE.md roster or its own mailbox
  -- ID. Set to "true" when opted-in; omitted entirely when off (absent
  -- == false, matching the rest of auto-agents' env contract).
  if spec.diff_review then
    env.AUTO_AGENTS_DIFF_REVIEW = "true"
  end

  -- M6 diff-review bridge: opted-in agents get the env vars needed
  -- to find + authenticate to our internal MCP bridge.
  -- Finding 1: use agent-generic env vars + Claude compatibility.
  if spec.diff_review and M.state.diff_review_port then
    local port_str = tostring(M.state.diff_review_port)
    local url = "http://127.0.0.1:" .. port_str .. "/mcp"

    -- Generic contract
    env.AUTO_AGENTS_IDE_INTEGRATION = "true"
    env.AUTO_AGENTS_MCP_PORT         = port_str
    env.AUTO_AGENTS_MCP_URL          = url

    -- Claude compatibility layer (Legacy SSE)
    env.ENABLE_IDE_INTEGRATION  = "true"
    env.FORCE_CODE_TERMINAL     = "true"
    env.CLAUDE_CODE_SSE_PORT    = port_str
  end

  -- M6 KB-aware launch: write the per-kind instruction file (idempotent)
  -- and emit a visible confirmation. This is the durable, TUI-safe way
  -- to inform the agent — sending stdin to claude/codex would be parsed
  -- as a prompt, so we lean on each kind's auto-loaded markdown.
  if spec.configured ~= false then  -- skip empty-slot shells
    local instr_path = require("auto-agents.kb.instruct").ensure(spec, kb_root, cwd)
    local logger = require("auto-agents.log")
    logger.info("spawn",
      string.format("slot %s (%s/%s) → KB=%s scope=%s%s",
        tostring(spec.slot or "?"),
        spec.kind or "?",
        spec.name or "anon",
        kb_root,
        spec.kb_scope or "shared",
        instr_path and (" instr=" .. instr_path) or ""))
  end

  -- Per-instance mailbox registration. auto-core's `register`
  -- auto-suffixes the bare `agent:<name>` id with this nvim's
  -- instance_id (`<unix-seconds>-<pid>`); under the v0.1.33
  -- workspace layout that instance becomes a directory level so
  -- two nvims sharing one workspace get non-overlapping subtrees:
  -- `<workspace>/.auto-agents/mailbox/<instance>/<name>/`. The
  -- workspace root resolves via auto-core's worktree state per
  -- the auto-family state-ownership convention. The agent finds
  -- its mailbox via the four env vars below; the bootstrap doc
  -- at `<workspace_root>/.auto-agents/mailbox/bootstrap-mailbox.md`
  -- is upserted on every register (cheap content-hash short-circuit
  -- when unchanged — see auto-core v0.1.7).
  if spec.configured ~= false and spec.name and spec.kind then
    local ok, err = pcall(function()
      local mailbox = require("auto-core").mailbox
      local identity = require("auto-agents.runtime.identity")
      local wake_spec = { command = "wake", args = { slot = spec.name } }

      local rec
      if spec.slot ~= nil then
        -- ADR 0023 §3.1 + ADR 0029 Decision #3: reconcile() owns
        -- per-kind mailbox root resolution, mailbox registration,
        -- and sidecar identity write. One call replaces the three
        -- previously duplicated paths (spawn / refresh_agent_id /
        -- adopt-resumed-agent). `cwd` flows through so the mailbox
        -- root anchors at the spawn cwd's workspace when auto-core
        -- worktree state is unset (Lector audit must-fix #1, 2026-05-24).
        local result = identity.reconcile({
          slot        = spec.slot,
          agent_name  = spec.name,
          kind        = spec.kind,
          diff_review = spec.diff_review,
          stamped_by  = "auto-agents.spawn",
          wake        = wake_spec,
          cwd         = cwd,
        })
        if not result.ok then
          require("auto-agents.log").warn("spawn",
            "identity reconcile failed: " .. tostring(result.detail))
          if not result.mailbox_record then
            error(result.detail or result.error or "identity reconcile failed")
          end
        end
        rec = result.mailbox_record
        if result.sidecar_path then
          env.AUTO_AGENTS_RUNTIME_IDENTITY_PATH = result.sidecar_path
        end
      else
        -- Preview / unconfigured spawn — register without a sidecar
        -- (no slot to key it to). Same cwd-through pattern as the
        -- reconcile branch above.
        rec = mailbox.register("agent:" .. spec.name, {
          root = identity.mailbox_root({ cwd = cwd }),
          wake = wake_spec,
        })
      end
      for k, v in pairs(mailbox.env_for_agent(rec)) do env[k] = v end

      -- v0.3.0: spawn-time permission injection. Append the per-kind
      -- CLI flag(s) that pre-authorize the agent to read/write its
      -- own mailbox dir and the KB read/write paths. No prompt on
      -- first file op; no settings-file mutation. Per-instance paths
      -- (mailbox dir) regenerate on every nvim restart, so the next
      -- spawn rebuilds the argv from scratch — persistence isn't
      -- desirable here.
      local dirs = { rec.dir }
      -- Grant the KB root (covers root-level files like AGENTS.md /
      -- log.md / index.md and the conventional subdirs in one entry).
      -- Per-scope read/write contracts remain encoded in
      -- AUTO_AGENTS_KB_{READ,WRITE} env vars — agents self-restrain
      -- via those (best-effort coordination; see kb/scope.lua).
      -- --add-dir is purely about removing permission-prompt friction
      -- for the surface the agent is expected to operate within.
      local function covered(path)
        for _, d in ipairs(dirs) do
          if d == path then return true end
          if path:sub(1, #d + 1) == d .. "/" then return true end
        end
        return false
      end
      if type(env.AUTO_AGENTS_KB_ROOT) == "string" and env.AUTO_AGENTS_KB_ROOT ~= "" then
        dirs[#dirs + 1] = env.AUTO_AGENTS_KB_ROOT
      end
      for path in tostring(env.AUTO_AGENTS_KB_READ or ""):gmatch("[^:]+") do
        if path ~= "" and not covered(path) then dirs[#dirs + 1] = path end
      end
      if type(env.AUTO_AGENTS_KB_WRITE) == "string" and env.AUTO_AGENTS_KB_WRITE ~= "" then
        if not covered(env.AUTO_AGENTS_KB_WRITE) then
          dirs[#dirs + 1] = env.AUTO_AGENTS_KB_WRITE
        end
      end

      local perms = require("auto-agents.permissions")
      local extra_argv = perms.argv_for_kind(spec.kind, dirs)
      if #extra_argv > 0 and type(spec.cmd) == "table" then
        for _, a in ipairs(extra_argv) do
          spec.cmd[#spec.cmd + 1] = a
        end
        require("auto-agents.log").info("spawn",
          string.format("slot %s (%s/%s) grants=%d dirs (%s)",
            tostring(spec.slot or "?"), spec.kind, spec.name,
            #dirs, table.concat(dirs, " ")))
      end
    end)
    if not ok then
      require("auto-agents.log").warn("spawn",
        string.format("mailbox register failed for %s/%s: %s",
          spec.kind or "?", spec.name or "?", tostring(err)))
    end
  end

  if next(env) == nil then return nil end
  return env
end

---Ensure the main panel window exists (open it if not) and return
---its winid.
---
---v0.2.0 migration: delegates to the auto-core.ui.panel singleton
---claimed in setup() (`M._panel`). auto-core handles:
---  - per-tab marker-based singleton-guard (orphan adoption after
---    :Lazy reload / session restore — `w:auto_agents_panel`
---    marker name is identical to the prior auto-agents-side var,
---    so external readers like the editor-floor invariant still
---    work)
---  - winfixwidth + winfixbuf application
---  - window-local number/relativenumber/signcolumn/foldcolumn=0
---  - `panel:opened/closed/focused` events on the auto-core bus
---
---auto-agents keeps:
---  - the editor-floor preflight (cfg.panel.editor_floor) — wider
---    than auto-core's internal min check
---  - the panel_winid + panel_width mirrors so legacy reader sites
---    keep working without changes
---@param force boolean?
---@return integer|nil winid
local function ensure_main_window(force)
  local logger = require("auto-agents.log")
  local cfg = M.state.config
  if not cfg then
    logger.error("init", "auto-agents.setup() must be called first")
    return nil
  end
  -- Editor-floor preflight: don't open the panel if the host window
  -- is too narrow to leave room for an editor split. auto-core's
  -- own minimum check is just `min + 10`; auto-agents wants the
  -- richer `min_width + editor_floor` budget so the editor side
  -- isn't squeezed to a useless ~10 cols.
  if not force and vim.o.columns < cfg.panel.min_width + cfg.panel.editor_floor then
    logger.info(
      "panel",
      "host width " .. vim.o.columns .. " below threshold (min_width "
        .. cfg.panel.min_width .. " + editor_floor " .. cfg.panel.editor_floor
        .. "); use :AutoAgents! to force"
    )
    return nil
  end
  if not M._panel then
    logger.error("init", "M._panel not initialized — setup() must run first")
    return nil
  end
  local winid = M._panel:open(force)
  if not winid then return nil end
  -- Mirror into legacy state for reader sites that walk
  -- M.state.panel_winid / panel_width directly.
  M.state.panel_winid = winid
  M.state.panel_width = vim.api.nvim_win_get_width(winid)
  return winid
end

---Run `fn` with the panel's `winfixbuf` temporarily disabled so our
---own legitimate buffer swaps (slot focus, terminal placement)
---aren't blocked by the same option that protects the panel from
---external hijacks. Restores the prior winfixbuf state before
---returning.
---
---v0.2.0 migration: delegates to the panel singleton's
---`with_unfixed_buf`. The `winid` arg is now informational —
---auto-core knows the panel's own winid. Kept for signature
---compatibility with the single in-tree caller.
---@param winid integer|nil   -- ignored when M._panel is set
---@param fn fun(): any
---@return boolean ok, any result_or_err
local function _with_unfixed_buf(winid, fn)
  if M._panel then
    return M._panel:with_unfixed_buf(fn)
  end
  -- Fallback (auto-core not loaded — shouldn't happen post-setup):
  -- replicate the original semantics so call sites don't crash.
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return pcall(fn)
  end
  -- ADR-0028 / ADR-0039 C1: winfixbuf is global-local; a bare
  -- `vim.wo[winid].winfixbuf = v` write uses `:set` semantics and
  -- mutates the GLOBAL default (the family's "winfixbuf propagation"
  -- bug). Restore must be scope-local — same fix as auto-core
  -- panel:with_unfixed_buf (v0.1.57).
  local was = vim.api.nvim_get_option_value("winfixbuf", { win = winid })
  if was then
    vim.api.nvim_set_option_value("winfixbuf", false, { win = winid, scope = "local" })
  end
  local ok, result = pcall(fn)
  if was and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_option_value("winfixbuf", true, { win = winid, scope = "local" })
  end
  return ok, result
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

  local logger = require("auto-agents.log")
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
      -- v0.2.0: clear the canonical auto-core status entry too. The
      -- name lookup uses the cfg.agents.bootstrap row; if the agent
      -- was despawned mid-flight before its status ever transitioned,
      -- this is a no-op (set(nil) on already-nil state).
      pcall(function()
        local cfg = M.state.config
        if cfg and cfg.agents and cfg.agents.bootstrap then
          for _, e in ipairs(cfg.agents.bootstrap) do
            if e.slot == slot and type(e.name) == "string" and e.name ~= "" then
              require("auto-core").tasks.status.set(e.name, nil)
              return
            end
          end
        end
      end)
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
    require("auto-agents.log").error("init", "auto-agents.setup() must be called first")
    return
  end
  if not ensure_main_window(force) then return end
  M.focus_slot(M.state.focused_slot or 1)
end

---Close the panel window. Keeps terminal jobs alive (processes persist;
---window is just hidden) — matches `claudecode.nvim`'s simple_toggle.
---Resolves the target via the marker scan when state lost track, so
---`:AutoAgentsClose` after a session restore still hits the orphan.
function M.close()
  -- v0.2.0: orphan-discovery via the panel singleton's marker scan.
  local target = nil
  if M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid) then
    target = M.state.panel_winid
  elseif M._panel then
    target = M._panel:_find_existing_in_tab()
  end
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_win_close(target, true)
  end
  M.state.panel_winid = nil
end

---@param force boolean?
function M.toggle(force)
  -- v0.2.0: panel singleton owns the per-tab marker discovery.
  -- M._panel:_find_existing_in_tab handles the orphan-adoption
  -- case (state lost track of winid but the marked panel still
  -- exists). We probe via :open() — if a panel already exists,
  -- it returns the existing winid; if not, it creates one. Then
  -- we close-or-keep based on whether _is_open already returned
  -- a live panel before our probe. Equivalent semantics to the
  -- old find_existing_panel_in_tab path, with the bonus that
  -- M.state.panel_winid stays in sync via the on_open callback.
  local already_open = M._panel and M._panel:_is_open()
  if not already_open and M._panel then
    -- Look for an unclaimed panel window in the tab — auto-core
    -- exposes the marker scan via _find_existing_in_tab. If found,
    -- it's an orphan we should adopt-and-close.
    local existing = M._panel:_find_existing_in_tab()
    if existing then
      M._panel.winid = existing
      M.state.panel_winid = existing
      already_open = true
    end
  end
  if already_open then
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
  return string.format("Focus slot %d — shell", slot)
end

---Re-register the `<leader>a[0..MAX_SLOT]` keymaps with descriptions
---reflecting current bootstrap state, and `nvim_del_keymap` any
---`<leader>aN` for N > MAX_SLOT that a previous consumer-spec or
---earlier slot_count may have left behind. Called from setup() so
---initial descriptions are accurate, and from agent rename / move /
---remove so which-key et al. stay in sync with live state.
function M.refresh_keymaps()
  for slot = 0, M.MAX_SLOT do
    pcall(vim.keymap.set, "n", "<leader>a" .. slot,
      "<cmd>AutoAgentsFocus " .. slot .. "<cr>",
      { desc = M.slot_desc(slot), silent = true })
  end
  -- Defensive del-sweep: a consumer's static lazy.nvim spec may
  -- have registered `<leader>a8` / `<leader>a9` from the pre-flat-
  -- refactor era when 6..9 were hardcoded float slots. With the
  -- live `MAX_SLOT` configurable (and typically < 9), those
  -- bindings now point at AutoAgentsFocus N for N out-of-range,
  -- which the focus guard rejects. Drop them so they stop showing
  -- in which-key. Range cap is 9 to cover the legacy hardcode.
  for slot = M.MAX_SLOT + 1, 9 do
    pcall(vim.api.nvim_del_keymap, "n", "<leader>a" .. slot)
  end
end

-- ── lifecycle (M3) ─────────────────────────────────────────────────────────

---Kill the agent process in a slot. For main slots (1..4) jobstops the
---terminal and wipes its buffer; for sub slots (5..9) closes the snacks
---float (which also stops the underlying job).
---@param slot integer
---@return boolean killed
function M.kill_slot(slot)
  local logger = require("auto-agents.log")
  if slot >= 1 and slot <= M.MAX_SLOT then
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
  end
  logger.error("lifecycle", "kill_slot: invalid slot " .. tostring(slot))
  return false
end

---Restart a slot — kill then re-spawn, focusing the new terminal in
---the panel.
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
  local logger = require("auto-agents.log")
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
---
---By default the body is wrapped in bracketed-paste markers
---(`ESC[200~ ... ESC[201~`) so the receiving TUI routes the text to
---its main chat input rather than whatever input the agent has
---*currently* focused — an open `@`-mention picker, slash-command
---autocomplete, fuzzy file picker, or the agent's own modal prompt.
---Without bracketed paste the chan_send is interpreted as keystrokes
---and lands wherever focus happens to be (the bug that made wakes
---disappear into Codex pickers in early comms-1 testing). Modern TUIs
---(Claude Code, Codex, Gemini CLI) honor bracketed paste; set
---`opts.bracketed_paste = false` to skip the wrapping for legacy
---TUIs that misrender the markers as literal text.
---
---Optional `opts.submit = true` follows the body with a deferred CR
---(`"\r"`) after `opts.submit_delay_ms` (default 60ms). The split is
---deliberate: most TUI agents (Claude Code included) treat a single
---chan_send containing body+CR as a paste and DON'T submit, while a
---separate CR keypress after a short delay is interpreted as the user
---hitting Enter. Without the delay the second chan_send races the
---first and the agent often eats the CR. The CR is sent OUTSIDE the
---bracketed-paste envelope on purpose — paste itself doesn't submit,
---the trailing CR keystroke does.
---@param slot integer
---@param text string
---@param opts table?  -- { submit = boolean, submit_delay_ms = integer, bracketed_paste = boolean }
---@return boolean ok
function M.send_slot(slot, text, opts)
  if not text or text == "" then return false end
  if slot < 1 or slot > M.MAX_SLOT then return false end
  local term = M.state.slot_terminals[slot]
  if not term or not term:is_alive() or not term.send then return false end

  -- Per-kind composer quirks. Resolve once: same lookup powers both
  -- the leading-`[` dodge AND v0.2.30 Phase 7's codex Esc-CR submit
  -- (see below).
  local slot_kind
  do
    local cfg = M.state.config
    if cfg and cfg.agents and cfg.agents.bootstrap then
      for _, e in ipairs(cfg.agents.bootstrap) do
        if e.slot == slot then slot_kind = e.kind; break end
      end
    end
  end
  local is_codex = slot_kind == "codex"

  -- Codex composer treats a leading `[` as a bracketed/queued entry and
  -- refuses to auto-submit until the user manually hits ESC + ENTER —
  -- bracketed-paste wrapping doesn't suppress this. Force-prefix any
  -- leading `[…]` body bound for a codex slot with `ATTENTION: ` so the
  -- composer accepts it as normal input. claude/antigravity composers
  -- don't share this behavior — leave their text untouched.
  if is_codex and text:sub(1, 1) == "[" then
    text = "ATTENTION: " .. text
  end

  local payload = text
  if not (opts and opts.bracketed_paste == false) then
    payload = "\27[200~" .. text .. "\27[201~"
  end
  if not term:send(payload) then return false end
  if opts and opts.submit then
    local delay = opts.submit_delay_ms or 60
    -- Submit keystroke sequence. v0.2.45 (follow-up #1): bare Enter
    -- for EVERY kind. Previously codex defaulted to `Esc` + `Enter`
    -- (Esc closing a composer picker so the Enter submits). But
    -- when codex is mid-generation that Esc CANCELS the work — a
    -- recurring interrupt the user asked us to stop. The leading-
    -- `[` codex bracketed-entry hazard (the original reason Esc was
    -- introduced, v0.2.30 Phase 7) is handled upstream by prefixing
    -- such payloads (e.g. the wake nudge's `ATTENTION:`), so the
    -- Esc is no longer load-bearing for the common path. A caller
    -- that genuinely needs the old behavior can still opt in with
    -- `opts.submit_keys = { "<Esc>", "<CR>" }`. The bytes are sent
    -- as discrete keypresses with an inter-key delay (sending
    -- `\27\r` as one chunk read as Alt+Enter — the v0.2.33 report).
    local submit_keys = opts.submit_keys or { "<CR>" }
    local inter_delay = opts.inter_key_delay_ms or 30
    local function press_seq(i)
      if i > #submit_keys then return end
      if not (term and term.is_alive and term:is_alive() and term.send) then return end
      M.send_keypress(slot, submit_keys[i])
      if i < #submit_keys then
        vim.defer_fn(function() press_seq(i + 1) end, inter_delay)
      end
    end
    vim.defer_fn(function() press_seq(1) end, delay)
  end
  return true
end

---Map of symbolic key names to the byte sequences a terminal sends
---for those keypresses. Exposed on M so callers and tests can
---inspect / extend it. Add a binding by mutating
---`M.KEY_BYTES[name] = "<bytes>"`.
M.KEY_BYTES = {
  ["<CR>"]    = "\r",
  ["<Enter>"] = "\r",
  ["<Esc>"]   = "\27",
  ["<Tab>"]   = "\t",
  ["<BS>"]    = "\b",
  ["<Space>"] = " ",
  ["<C-a>"]   = "\1",
  ["<C-b>"]   = "\2",
  ["<C-c>"]   = "\3",
  ["<C-d>"]   = "\4",
  ["<C-e>"]   = "\5",
  ["<C-k>"]   = "\11",
  ["<C-l>"]   = "\12",
  ["<C-n>"]   = "\14",
  ["<C-p>"]   = "\16",
  ["<C-u>"]   = "\21",
  ["<C-w>"]   = "\23",
  -- Arrow keys (CSI sequences). Most TUIs accept either CSI or
  -- application-mode forms; CSI is more portable.
  ["<Up>"]    = "\27[A",
  ["<Down>"]  = "\27[B",
  ["<Right>"] = "\27[C",
  ["<Left>"]  = "\27[D",
  ["<Home>"]  = "\27[H",
  ["<End>"]   = "\27[F",
}

---Send a single symbolic keypress to a slot's TUI. Unlike
---`send_slot` (which wraps body text in bracketed-paste markers
---and is meant for delivering chunks of input text), this sends
---the raw byte sequence the terminal would generate for the named
---key — discrete keypress, not pasted content. Use it when you
---need the agent's TUI to see a real keyboard event (e.g. Enter to
---submit, Esc to dismiss a picker, Ctrl+C to interrupt).
---
---`key` is a vim-style key name (`<CR>`, `<Esc>`, `<C-c>`, ...) —
---see `M.KEY_BYTES` for the recognized set. If `key` isn't in the
---table, it's sent as-is (so callers can pass literal byte
---sequences like `"\27[13;1u"` for kitty-keyboard-protocol Enter
---without needing to extend the table).
---@param slot integer
---@param key  string
---@return boolean ok
function M.send_keypress(slot, key)
  if slot < 1 or slot > M.MAX_SLOT then return false end
  local term = M.state.slot_terminals[slot]
  if not term or not term:is_alive() or not term.send then return false end
  local bytes = M.KEY_BYTES[key] or key
  if not term:send(bytes) then return false end
  return true
end

---Sorted list of slot numbers that have a bootstrap entry (i.e. the
---live `cfg.agents.bootstrap` set). The right abstraction for any
---module that needs to enumerate "the configured agents", as opposed
---to the panel's `MAX_SLOT` upper-bound capacity. Returns an empty
---table when setup hasn't run yet or there are no entries.
---@return integer[]
function M.configured_slots()
  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return {} end
  local out = {}
  for _, e in ipairs(cfg.agents.bootstrap) do
    if type(e.slot) == "number" then out[#out + 1] = e.slot end
  end
  table.sort(out)
  return out
end

-- Forward declaration so `M.spawned_agents` (defined below) can
-- reference `_bootstrap_entry` even though its `function` body is
-- defined further down. Without this, the reference inside
-- spawned_agents bound to a nil GLOBAL `_bootstrap_entry` and the
-- call errored (`attempt to call global '_bootstrap_entry'`) — a
-- v0.2.39 regression that broke the auto-finder `A` assign keymap.
local _bootstrap_entry

---v0.2.39: enumerate every currently-spawned agent slot. Returns
---a list of `{slot, name, kind, mailbox_id}` entries — one per
---configured slot whose terminal is alive. Consumers (e.g.
---auto-finder.todos panel's `A` assign keymap) use this to pick a
---live recipient for a `todos.assign` call without having to
---thread through the mailbox `addressbook` indirection.
---
---Entries:
---  • `slot`       — 1-based slot integer
---  • `name`       — agent name (`jarvis`, `lector`, etc.)
---  • `kind`       — `"claude"` / `"codex"` / etc. (from cfg)
---  • `mailbox_id` — `agent:<name>` (bare form; the resolver
---                    accepts both bare and full instance-scoped
---                    forms)
---@return { slot: integer, name: string, kind: string?, mailbox_id: string }[]
function M.spawned_agents()
  local out = {}
  for _, slot in ipairs(M.configured_slots()) do
    local term = M.state.slot_terminals[slot]
    if term and term.is_alive and term:is_alive() then
      local entry = _bootstrap_entry(slot)
      if entry and type(entry.name) == "string" and entry.name ~= "" then
        out[#out + 1] = {
          slot       = slot,
          name       = entry.name,
          kind       = entry.kind,
          mailbox_id = "agent:" .. entry.name,
        }
      end
    end
  end
  return out
end

---Bootstrap entry lookup by slot. Internal helper for the pickers
---below; returns the raw `cfg.agents.bootstrap` entry or nil.
---@param slot integer
---@return table|nil
-- (forward-declared above so M.spawned_agents can call it; no
-- `local` keyword here — assigns the existing upvalue.)
function _bootstrap_entry(slot)
  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == slot then return e end
  end
  return nil
end

---Resolve the live mailbox record for a bootstrap entry. Returns nil
---if the agent isn't registered (not yet spawned, or the registry was
---wiped). Used by the bootstrap-refresh pickers to read the live
---authoritative identity env vars via `mailbox.env_for_agent(rec)`.
---@param entry table  -- bootstrap entry (must have .name)
---@return AutoCoreMailboxRecord|nil
local function _live_mailbox_record(entry)
  if not (entry and type(entry.name) == "string" and entry.name ~= "") then return nil end
  local ok, mailbox = pcall(function() return require("auto-core").mailbox end)
  if not ok or not mailbox or not mailbox.registry or not mailbox.registry.get then
    return nil
  end
  -- Lookup is on `mailbox.registry.get`, NOT `mailbox.get` — the
  -- top-level mailbox module doesn't expose a `get` shortcut; record
  -- lookups go through `registry`. ADR 0024 originally called
  -- `mailbox.get` and every <leader>am / <leader>ai call returned
  -- "no live mailbox record" regardless of agent. Fixed in v0.2.15.
  local rec_ok, rec = pcall(mailbox.registry.get, "agent:" .. entry.name)
  if not rec_ok then return nil end
  return rec
end

---Compute the live authoritative env surface for a bootstrap entry.
---Mirrors what `build_agent_env` would produce on a fresh spawn —
---KB scope env vars from `kb.scope.env_for(entry, kb_root)` plus the
---mailbox identity vars from `mailbox.env_for_agent(rec)`. Used by
---the reassert-identity picker as the authoritative source of truth
---to compare the agent's cached env against.
---@param entry table
---@return table<string,string>|nil
local function _live_env_for(entry)
  if not entry then return nil end
  local env = {}
  local ok_kb, kb_mod = pcall(require, "auto-agents.kb")
  local ok_scope, scope_mod = pcall(require, "auto-agents.kb.scope")
  if ok_kb and ok_scope then
    local kb_root_ok, kb_root = pcall(kb_mod.root)
    if kb_root_ok and kb_root then
      for k, v in pairs(scope_mod.env_for(entry, kb_root) or {}) do env[k] = v end
    end
  end
  local rec = _live_mailbox_record(entry)
  if rec then
    local ok_mb, mailbox = pcall(function() return require("auto-core").mailbox end)
    if ok_mb and mailbox and mailbox.env_for_agent then
      for k, v in pairs(mailbox.env_for_agent(rec) or {}) do env[k] = v end
    end
  end
  return env
end

---Build the list of picker entries for the bootstrap-refresh keymaps.
---Only includes slots that (a) have a bootstrap entry and (b) have a
---live terminal. Empty slots are hidden from the picker (ADR 0024 §2.1).
---@return { slot: integer, entry: table, label: string }[]
local function _refresh_picker_items()
  local items = {}
  for _, slot in ipairs(M.configured_slots()) do
    local term = M.state.slot_terminals[slot]
    if term and term.is_alive and term:is_alive() then
      local entry = _bootstrap_entry(slot)
      if entry then
        local name = entry.name or entry.title or ("agent" .. tostring(slot))
        local kind = entry.kind or "?"
        items[#items + 1] = {
          slot  = slot,
          entry = entry,
          label = string.format("%d: %s (%s)", slot, name, kind),
        }
      end
    end
  end
  return items
end

---Deterministic re-ingest prompt body. Owned by auto-agents — the
---whole point of the keymap is to eliminate per-invocation prompt
---variation. Resolves the agent's bootstrap doc path from the live
---registry, not from any hardcoded per-CLI path.
---@param entry table
---@return string|nil body, string|nil err
local function _build_reingest_body(entry)
  local rec = _live_mailbox_record(entry)
  if not rec then
    return nil, "no live mailbox record for agent:" .. tostring(entry.name)
  end
  local ok_mb, mailbox = pcall(function() return require("auto-core").mailbox end)
  if not ok_mb or not mailbox or not mailbox.env_for_agent then
    return nil, "auto-core.mailbox.env_for_agent unavailable"
  end
  local env = mailbox.env_for_agent(rec) or {}
  local doc = env.AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC
  if not doc or doc == "" then
    return nil, "no AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC in live env"
  end
  -- Resolve the seen-revision path HOST-SIDE so the agent receives a
  -- literal absolute path. Previously the body embedded a
  -- `$(dirname "$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC")/...` shell
  -- expression, which agents copied verbatim into `cat`/`stat`
  -- commands — command substitution trips Claude Code's permission
  -- gate ("Contains simple_expansion") and stalls the re-ingest.
  local seen_dir = doc:match("^(.*)/[^/]+$") or "."
  local seen = seen_dir .. "/.agent-state/seen-revision"
  return table.concat({
    "Re-ingest your bootstrap-mailbox protocol doc.",
    "",
    "Bootstrap doc:  " .. doc,
    "Seen-revision:  " .. seen,
    "",
    "Use the **Read tool** on each of those two literal paths — do NOT",
    "build a shell command (`cat`, `$(dirname …)`, `;`-chains, pipes,",
    "redirects all trip the permission gate). Compare the doc's",
    "`revision:` frontmatter against the seen-revision file. If they",
    "differ, adopt the protocol changes the doc describes, then **Write**",
    "the new revision to the seen-revision path (Write tool, not",
    "`echo >`). Acknowledge here with the revision you adopted.",
  }, "\n")
end

---Deterministic re-assert-identity prompt body. Enumerates the live
---authoritative identity surface from the host registry — what the
---agent SHOULD see if it were freshly spawned right now. The agent
---compares against its own cached env / sidecar; on drift it calls
---`refresh_agent_id` (ADR 0023 §3.2) and adopts the sidecar.
---@param entry table
---@return string|nil body, string|nil err
local function _build_reassert_body(entry)
  local env = _live_env_for(entry)
  if not env or not env.AUTO_AGENTS_MAILBOX_ID then
    return nil, "no live identity surface for agent:" .. tostring(entry.name)
  end
  local keys = {
    "AUTO_AGENTS_INSTANCE_ID",
    "AUTO_AGENTS_MAILBOX_ID",
    "AUTO_AGENTS_MAILBOX_DIR",
    "AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC",
    "AUTO_AGENTS_KB_ROOT",
    "AUTO_AGENTS_KB_READ",
    "AUTO_AGENTS_KB_WRITE",
  }
  local lines = {
    "Re-assert your runtime identity.",
    "",
    "Your live authoritative env (per the host registry — this is what",
    "a fresh spawn would receive right now):",
    "",
  }
  for _, k in ipairs(keys) do
    lines[#lines + 1] = "  " .. k .. "=" .. tostring(env[k] or "")
  end
  vim.list_extend(lines, {
    "",
    "Compare each value to your cached env (and sidecar at",
    "$AUTO_AGENTS_RUNTIME_IDENTITY_PATH if set). If ANY value differs,",
    "call the `refresh_agent_id` mailbox command (ADR 0023 §3.2) with",
    "your current process PID as `actor_pid`. Adopt the returned",
    "sidecar identity as authoritative, then acknowledge here.",
    "",
    "If your kind is NOT `claude` AND your roster row in your per-kind",
    "instruction file (AGENTS.md / GEMINI.md / .junie/guidelines.md /",
    ".goosehints) shows `diff_review = ✓`, also re-read the",
    "**Interactive diff review** section in that file before proposing",
    "any further edits — the host re-renders the file on every",
    "refresh_agent_id call, so the protocol you load now is the current",
    "one.",
  })
  return table.concat(lines, "\n")
end

---Deterministic permission-bootstrap prompt body (ADR-0036). Injects
---the prompt-avoidance directive + a directive to read & follow the
---agent's `PERMISSION.md` guideline. The agent VERIFIES its mailbox/KB
---grants and REQUESTS any missing ones from the user — it does not
---self-provision. Goes through `send_slot` (Esc+CR for codex), so the
---PERMISSION.md path token is safe here (unlike the bare-`<CR>` wake
---nudge, which must stay path-token-free).
---@param entry table
---@return string|nil body, string|nil err
local function _build_permission_body(entry)
  local env = _live_env_for(entry)
  local doc = env and env.AUTO_AGENTS_PERMISSION_DOC
  local lines = {
    "Permission bootstrap (ADR-0036).",
    "",
    "The user has their own work to complete, and your mailbox",
    "permission prompts disrupt the user's workflow greatly. Make the",
    "best effort to avoid requesting permission prompts on mailbox",
    "operations to the best of your ability, and instead tell the user",
    "which grants you require to perform read/write and other available",
    "mailbox operations at your hand.",
    "",
  }
  if doc and doc ~= "" then
    lines[#lines + 1] = "Read and follow your PERMISSION.md guideline at: " .. doc
  else
    lines[#lines + 1] = "Read and follow your PERMISSION.md guideline (a peer of"
    lines[#lines + 1] = "your bootstrap-mailbox.md, in the same workspace mailbox root)."
  end
  vim.list_extend(lines, {
    "",
    "Use the **Read tool** to read it. Then VERIFY the permission grants",
    "it lists for your capability bucket are present, and REQUEST any",
    "missing ones from the user (state the exact rule + what it unlocks)",
    "— do NOT write your own permission settings. Do mailbox/KB work via",
    "the Read/Write tools, never shell that expands `$VAR`. Acknowledge",
    "here with what you verified and what (if anything) you are",
    "requesting.",
  })
  return table.concat(lines, "\n")
end

---Bootstrap-refresh picker shared between §2.1 and §2.2. Opens
---`vim.ui.select` over the live (configured + alive) slots, then
---feeds the selected slot through `build_body` to produce the prompt
---and submits it via `M.send_slot(slot, body, { submit = true })`.
---@param banner string
---@param build_body fun(entry: table): string|nil, string|nil
local function _bootstrap_refresh_picker(banner, build_body)
  local items = _refresh_picker_items()
  if #items == 0 then
    require("auto-agents.log").notify("no live agent slots to target",
      { level = "warn", component = "send_slot" })
    return
  end
  vim.ui.select(items, {
    prompt = banner,
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    local body, err = build_body(choice.entry)
    if not body then
      require("auto-agents.log").notify(err or "failed to build prompt",
        { level = "error", component = "send_slot" })
      return
    end
    local ok = M.send_slot(choice.slot, body, { submit = true })
    if not ok then
      require("auto-agents.log").notify("send_slot failed for slot " .. choice.slot,
        { level = "error", component = "send_slot" })
    end
  end)
end

---ADR 0024 §2.1 — re-ingest bootstrap doc into a live agent slot.
---Slot picker → deterministic prompt → paste-safe submit. Bound to
---`<leader>am` by the autovim consumer config.
function M.reingest_bootstrap_picker()
  _bootstrap_refresh_picker("Re-ingest bootstrap doc into slot:", _build_reingest_body)
end

---ADR 0024 §2.2 — re-assert runtime identity for a resumed agent.
---Slot picker → deterministic prompt naming the live env values from
---`mailbox.env_for_agent(rec)` → paste-safe submit. The agent
---reconciles via `refresh_agent_id` if its cached env has drifted.
---Bound to `<leader>ai` by the autovim consumer config.
function M.reassert_identity_picker()
  _bootstrap_refresh_picker("Re-assert identity for slot:", _build_reassert_body)
end

---ADR-0036 — bootstrap mailbox permissions into a live agent slot.
---Slot picker → deterministic prompt (the prompt-avoidance directive +
---"read & follow PERMISSION.md") → paste-safe submit. The agent
---verifies its capability-bucket grants and requests any missing ones
---from the user. Bound to `<leader>ap` by the autovim consumer config
---(replacing the prior help-tip binding).
function M.permission_bootstrap_picker()
  _bootstrap_refresh_picker("Bootstrap permissions for slot:", _build_permission_body)
end

---Line cap for the inline-contents fallback (ADR-0045 r2 / Lector
---should-fix #2). Path-reference payloads are unaffected (they send a
---path, not content); only the unnamed / not-yet-on-disk fallback can
---paste arbitrary buffer text into the TUI, so it is bounded.
local SEND_BUFFER_MAX_INLINE_LINES = 1000

---ADR-0045 — build the deterministic prompt body for `send_buffer_picker`.
---Payload model: **file-path reference, but only for a real readable
---on-disk file** (Lector review, must-fix #2). When `abspath` names a
---file that exists on disk, send just the path so the recipient agent
---reads/edits the real file with its own tools (a modified buffer gets
---an explicit "on-disk lags the editor" note — we never auto-write).
---Otherwise — an unnamed buffer, OR a named buffer whose path is not a
---readable file yet (a brand-new `:edit foo` not saved) — fall back to
---**inline fenced contents** (size-capped) so the agent still gets
---something actionable; when there is an intended-but-absent path we
---name it without implying a disk source exists. The body never starts
---with `[` (send_slot's codex leading-`[` hazard), so it submits
---cleanly on every kind.
---@param bufnr integer
---@param abspath string?   -- absolute path, or nil for an unnamed buffer
---@param modified boolean  -- buffer has unsaved changes
---@param instruction string  -- may be "" (no extra directive)
---@return string|nil body
local function _build_send_buffer_body(bufnr, abspath, modified, instruction)
  local lines = {}
  local has_path = abspath ~= nil and abspath ~= ""
  local readable = has_path and vim.fn.filereadable(abspath) == 1

  if readable then
    -- Path-reference mode: the file exists on disk; the agent reads/
    -- edits it directly. No content paste.
    lines[#lines + 1] = "Please work on this file per the instruction below."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "File: " .. abspath
    if modified then
      lines[#lines + 1] = "(note: the editor buffer has unsaved changes — read the"
      lines[#lines + 1] = " file as-is on disk; ask before assuming the latest edits)"
    end
  else
    -- Inline fallback: unnamed buffer, or a named buffer whose path is
    -- not a readable on-disk file yet. Either way a path reference is
    -- useless, so inline the (size-capped) contents.
    local ok, content = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
    if not ok then return nil end
    local total = #content
    local truncated = false
    if total > SEND_BUFFER_MAX_INLINE_LINES then
      local capped = {}
      for i = 1, SEND_BUFFER_MAX_INLINE_LINES do capped[i] = content[i] end
      content = capped
      truncated = true
    end
    local ft = vim.bo[bufnr].filetype or ""
    if has_path then
      -- Named but not on disk (e.g. unsaved new file). Name the
      -- intended path WITHOUT implying it can be read (Lector nit).
      lines[#lines + 1] = "Please work on the buffer contents below per the instruction."
      lines[#lines + 1] = "Intended file path (NOT yet written to disk): " .. abspath
    else
      lines[#lines + 1] = "Please work on the (unnamed) buffer contents below per the"
      lines[#lines + 1] = "instruction."
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```" .. ft
    vim.list_extend(lines, content)
    lines[#lines + 1] = "```"
    if truncated then
      lines[#lines + 1] = string.format(
        "(buffer truncated to the first %d of %d lines)",
        SEND_BUFFER_MAX_INLINE_LINES, total)
    end
  end

  lines[#lines + 1] = ""
  if instruction and instruction ~= "" then
    lines[#lines + 1] = "Instruction:"
    lines[#lines + 1] = instruction
  else
    lines[#lines + 1] = "(no additional instruction given)"
  end
  return table.concat(lines, "\n")
end

---ADR-0045 — `<leader>ab` operator-push: hand the current editor buffer
---to a live agent slot with an optional instruction. Mirrors the
---auto-finder `todos.assign` (`A`) two-step UX (pick agent → instruct),
---but delivers via `send_slot` (immediate TUI push) like the other
---operator pickers rather than a mailbox message.
---
---The target buffer is captured at invocation (before `vim.ui.select`
---steals focus). Non-file buffers (terminals / agent panels / prompts)
---are rejected. Bound to `<leader>ab` by the autovim consumer config.
---@param bufnr integer?  -- defaults to the current buffer at call time
function M.send_buffer_picker(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    require("auto-agents.log").notify("no valid buffer to send",
      { level = "warn", component = "send_slot" })
    return
  end
  -- Normal editor file buffers only: `buftype == ""`. Everything else
  -- is rejected — terminals/prompts/help, the agent panel, the picker,
  -- AND `acwrite` (Lector review): this repo uses `acwrite` for the
  -- synthetic diff-proposal buffers (`diff/ui.lua`) whose names are not
  -- real on-disk paths, so they must not be treated as files. `nofile`
  -- scratch buffers stay rejected; the inline fallback covers unnamed
  -- and not-yet-saved `buftype == ""` buffers instead.
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then
    require("auto-agents.log").notify(
      "current buffer is not a normal file buffer (buftype=" .. buftype .. ")",
      { level = "warn", component = "send_slot" })
    return
  end

  local items = _refresh_picker_items()
  if #items == 0 then
    require("auto-agents.log").notify("no live agent slots to target",
      { level = "warn", component = "send_slot" })
    return
  end

  -- Capture buffer state NOW — the picker will change the current buffer.
  local name = vim.api.nvim_buf_get_name(bufnr)
  local abspath = (name ~= nil and name ~= "")
    and vim.fn.fnamemodify(name, ":p") or nil
  local modified = vim.bo[bufnr].modified and true or false

  vim.ui.select(items, {
    prompt = "Send buffer to slot:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    vim.ui.input({ prompt = "Instructions: " }, function(instruction)
      if instruction == nil then return end  -- user cancelled the input
      local body = _build_send_buffer_body(bufnr, abspath, modified, instruction)
      if not body then
        require("auto-agents.log").notify("failed to build buffer-send prompt",
          { level = "error", component = "send_slot" })
        return
      end
      local ok = M.send_slot(choice.slot, body, { submit = true })
      if not ok then
        require("auto-agents.log").notify("send_slot failed for slot " .. choice.slot,
          { level = "error", component = "send_slot" })
      end
    end)
  end)
end

---ADR-0082 — extract visual selection or clipboard text payload for forward_text_picker.
---@param opts table?
---@return table|nil payload
local function _extract_forward_payload(opts)
  opts = opts or {}
  local text = opts.text
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local mode = opts.mode or vim.fn.mode()
  local ft = (bufnr and vim.api.nvim_buf_is_valid(bufnr)) and (vim.bo[bufnr].filetype or "") or ""
  if ft == "" and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local bname = vim.api.nvim_buf_get_name(bufnr)
    if bname and bname ~= "" then
      ft = vim.filetype.match({ buf = bufnr, filename = bname }) or ""
    end
  end
  local source_info = nil
  local lines_label = nil

  if text and text ~= "" then
    -- Explicitly provided text (e.g. from tests or caller)
    source_info = opts.source or "(provided text)"
    lines_label = opts.lines_label
  elseif mode:match("^[vV\22]") then
    -- Visual mode: capture selection region
    local s_pos = vim.fn.getpos("v")
    local e_pos = vim.fn.getpos(".")
    local sel_type = mode
    -- Exit visual mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)

    local s_line, s_col = s_pos[2], s_pos[3]
    local e_line, e_col = e_pos[2], e_pos[3]
    if s_line > e_line or (s_line == e_line and s_col > e_col) then
      s_line, e_line = e_line, s_line
      s_col, e_col = e_col, s_col
      s_pos, e_pos = e_pos, s_pos
    end

    if s_line > 0 and e_line > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      if vim.fn.exists("*getregion") == 1 then
        local ok, region = pcall(vim.fn.getregion, s_pos, e_pos, { type = sel_type })
        if ok and region and #region > 0 then
          text = table.concat(region, "\n")
        end
      end
      if not text or text == "" then
        local lines = vim.api.nvim_buf_get_lines(bufnr, s_line - 1, e_line, false)
        if #lines > 0 then
          if sel_type == "V" then
            text = table.concat(lines, "\n")
          elseif sel_type == "\22" then
            local res = {}
            local c1 = math.min(s_col, e_col)
            local c2 = math.max(s_col, e_col)
            for _, l in ipairs(lines) do
              res[#res + 1] = string.sub(l, c1, c2)
            end
            text = table.concat(res, "\n")
          else
            if #lines == 1 then
              lines[1] = string.sub(lines[1], s_col, e_col)
            else
              lines[1] = string.sub(lines[1], s_col)
              lines[#lines] = string.sub(lines[#lines], 1, e_col)
            end
            text = table.concat(lines, "\n")
          end
        end
      end
      lines_label = s_line == e_line and string.format("line %d", s_line) or string.format("lines %d-%d", s_line, e_line)
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name and name ~= "" then
        source_info = vim.fn.fnamemodify(name, ":p") .. " (" .. lines_label .. ")"
      else
        source_info = "(unnamed buffer, " .. lines_label .. ")"
      end
    end
  else
    -- Normal mode: read clipboard (+ > * > ")
    local function _is_valid_text(t)
      return t and t ~= "" and not t:match("^%s*$")
    end
    local clip = vim.fn.getreg("+")
    if not _is_valid_text(clip) then clip = vim.fn.getreg("*") end
    if not _is_valid_text(clip) then clip = vim.fn.getreg('"') end
    if _is_valid_text(clip) then
      text = clip
      source_info = "(clipboard)"
    end
  end

  if not text or text == "" or text:match("^%s*$") then
    return nil
  end

  local clean = text:gsub("[\r\n%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local snippet = clean:sub(1, 20)

  return {
    text        = text,
    snippet     = snippet,
    source      = source_info or "(selection)",
    filetype    = ft,
    lines_label = lines_label,
  }
end

---ADR-0082 — build deterministic prompt body for forwarding text.
---Dynamically sizes markdown fence delimiter to prevent early termination
---when forwarded text contains embedded backtick sequences.
---@param payload table
---@param instruction string?
---@return string
local function _build_forward_text_body(payload, instruction)
  local max_ticks = 0
  if payload.text then
    for ticks in payload.text:gmatch("`+") do
      if #ticks > max_ticks then
        max_ticks = #ticks
      end
    end
  end
  local fence = string.rep("`", math.max(3, max_ticks + 1))

  local lines = {}
  lines[#lines + 1] = "Please work on the forwarded text below per the instruction."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Source: " .. payload.source
  lines[#lines + 1] = ""
  lines[#lines + 1] = fence .. (payload.filetype or "")
  lines[#lines + 1] = payload.text
  lines[#lines + 1] = fence
  lines[#lines + 1] = ""
  if instruction and instruction ~= "" then
    lines[#lines + 1] = "Instruction:"
    lines[#lines + 1] = instruction
  else
    lines[#lines + 1] = "(no additional instruction given)"
  end
  return table.concat(lines, "\n")
end

---ADR-0082 — `<leader>af` operator forward-text to agent picker:
---Forward selected text (visual mode) or clipboard (normal mode) to a live agent
---slot with an optional instruction. Displays prompt with a 15-20 char preview,
---toggles the agent panel into view if not already open, focuses the agent,
---and sends the structured payload to the agent via mailbox.
---@param opts table?  -- optional overrides for testing/programmatic use
function M.forward_text_picker(opts)
  opts = opts or {}
  local payload = _extract_forward_payload(opts)
  if not payload then
    require("auto-agents.log").notify("clipboard is empty or no text selected",
      { level = "warn", component = "forward_text" })
    return
  end

  local items = _refresh_picker_items()
  if #items == 0 then
    require("auto-agents.log").notify("no live agent slots to target",
      { level = "warn", component = "forward_text" })
    return
  end

  local prompt_title = string.format("Forward to an agent [%s]:", payload.snippet)

  vim.ui.select(items, {
    prompt = prompt_title,
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end

    vim.ui.input({ prompt = "Instructions: " }, function(instruction)
      if instruction == nil then return end  -- user cancelled

      -- Toggle on agent panel to view if not already so
      local already_open = M._panel and M._panel:_is_open()
      if not already_open then
        M.open()
      end
      -- Focus target slot
      if type(choice.slot) == "number" then
        M.focus_slot(choice.slot)
      end

      local body = _build_forward_text_body(payload, instruction)
      if not body then
        require("auto-agents.log").notify("failed to build forward-text prompt",
          { level = "error", component = "forward_text" })
        return
      end

      -- Try to send via auto-core.mailbox.send
      local agent_name = choice.entry and choice.entry.name
      local to_addr = agent_name and ("agent:" .. agent_name) or ("slot:" .. tostring(choice.slot))

      local ok_core, ac = pcall(require, "auto-core")
      local delivered = false
      if ok_core and ac and ac.mailbox and ac.mailbox.send then
        local res, send_err = ac.mailbox.send({
          to      = to_addr,
          from    = "nvim",
          kind    = "message",
          subject = "[forward] " .. payload.snippet,
          body    = body,
        })
        if res then
          delivered = true
        else
          require("auto-agents.log").warn("forward_text",
            "mailbox.send failed for " .. to_addr .. ": " .. tostring(send_err))
        end
      end

      -- Fallback if mailbox send not delivered (e.g. headless/test harness without mailbox router)
      if not delivered then
        local sent = M.send_slot(choice.slot, body, { submit = true })
        if not sent then
          require("auto-agents.log").notify("forward_text delivery failed for slot " .. tostring(choice.slot),
            { level = "error", component = "forward_text" })
        end
      end
    end)
  end)
end

---Resolve an agent slot from its name. Returns nil if no bootstrap
---entry matches. Public-facing wrapper around the same lookup used by
---resolve_status_slot — handy for consumers that have an agent_name
---string (e.g. the diff queue) and need to talk to that slot.
---@param name string
---@return integer? slot
function M.slot_for_name(name)
  if type(name) ~= "string" or name == "" then return nil end
  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return nil end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.name == name then return e.slot end
  end
  return nil
end

---Enumerate every running agent slot that has `diff_review = true`,
---along with its agent name and live PID. Used by the openDiff MCP
---bridge to attribute an incoming connection to its originating slot
---via peer-PID lookup (procfs on Linux). Slots that aren't currently
---running, or whose PID can't be probed, are omitted.
---
---Output is a flat array — callers usually want all of it (the
---peer_identity module does an O(N) lsof-style match), but the slot
---and name are both included so single-result lookups are also cheap.
---@return { slot: integer, name: string, pid: integer }[]
function M.diff_review_slots_with_pid()
  local out = {}
  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return out end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.diff_review and type(e.name) == "string" and e.name ~= ""
        and type(e.slot) == "number"
    then
      local term = M.state.slot_terminals[e.slot]
      if term and term:is_alive() and term.get_jobid then
        local jobid = term:get_jobid()
        if jobid and jobid > 0 then
          local ok, pid = pcall(vim.fn.jobpid, jobid)
          if ok and type(pid) == "number" and pid > 0 then
            out[#out + 1] = { slot = e.slot, name = e.name, pid = pid }
          end
        end
      end
    end
  end
  return out
end

---ADR-0046 D-A: like `diff_review_slots_with_pid()` but over EVERY live
---spawned slot, not just `diff_review = true` ones. The openDiff MCP
---bridge is a single shared port; any spawned agent — not only
---`diff_review`-enabled ones — can reach it via lockfile auto-discovery
---when agents share a workspace. So the peer-PID attribution candidate
---set must be all live slots, else a peer's connection matches nothing
---and collapses to the lone `diff_review` agent. No kind filter: a
---non-connecting kind simply won't own the socket inode.
---@return { slot: integer, name: string, pid: integer }[]
function M.spawned_agents_with_pid()
  local out = {}
  for _, entry in ipairs(M.spawned_agents()) do
    local term = M.state.slot_terminals[entry.slot]
    if term and term:is_alive() and term.get_jobid then
      local jobid = term:get_jobid()
      if jobid and jobid > 0 then
        local ok, pid = pcall(vim.fn.jobpid, jobid)
        if ok and type(pid) == "number" and pid > 0 then
          out[#out + 1] = { slot = entry.slot, name = entry.name, pid = pid }
        end
      end
    end
  end
  return out
end

---Best-effort resolution of "which agent is the source of an
---inbound diff." Used by the MCP open_diff handlers + the queue UI
---to display a meaningful name in the panel instead of the literal
---`agent` placeholder.
---
---Resolution strategy (first hit wins):
---  1. If the caller passed an explicit name, use it.
---  2. If exactly one bootstrap entry has `diff_review = true`,
---     return that entry's name. This is the dominant case (one
---     CLI agent like claude-code with the diff bridge enabled).
---  3. If multiple have it enabled, return nil — the bridge can't
---     distinguish them at the MCP layer today, so leaving the
---     field nil signals "unknown" rather than picking arbitrarily.
---
---Returns nil when no agent is identifiable; callers should fall
---back to a literal "?" or similar.
---@param explicit string?
---@return string?
function M.resolve_diff_agent_name(explicit)
  if type(explicit) == "string" and explicit ~= ""
      and explicit ~= "agent" then
    return explicit
  end
  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then return nil end
  local match
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.diff_review and type(e.name) == "string" and e.name ~= "" then
      if match then return nil end  -- ambiguous
      match = e.name
    end
  end
  return match
end

---Read RSS for a pid in kB. Tries Linux `/proc/<pid>/status` first (cheap,
---no subprocess); falls back to `ps -o rss= -p <pid>` for platforms without
---procfs (macOS, BSD). Returns nil if both probes fail.
---@param pid integer
---@return integer|nil rss_kb
local function read_rss_kb(pid)
  local f = io.open("/proc/" .. tostring(pid) .. "/status", "r")
  if f then
    local rss
    for line in f:lines() do
      local v = line:match("^VmRSS:%s+(%d+)")
      if v then rss = tonumber(v); break end
    end
    f:close()
    if rss then return rss end
  end
  local out = vim.fn.system({ "ps", "-o", "rss=", "-p", tostring(pid) })
  if vim.v.shell_error ~= 0 then return nil end
  return tonumber((out:gsub("%s+", "")))
end

---Resolve the live PID for a slot (or nil if not running).
---@param slot integer
---@return integer|nil pid
local function pid_for_slot(slot)
  if slot >= 1 and slot <= M.MAX_SLOT then
    local term = M.state.slot_terminals[slot]
    if not term or not term:is_alive() then return nil end
    if not term.get_jobid then return nil end
    local jobid = term:get_jobid()
    if not jobid or jobid <= 0 then return nil end
    local ok, pid = pcall(vim.fn.jobpid, jobid)
    return ok and pid or nil
  end
  return nil
end

---Build a memory report across all running agents. Uses `/proc` on Linux
---and falls back to `ps` on macOS/BSD. Returns a list of strings suitable
---for printing into the admin buffer.
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
      if rss_mb then
        total = total + rss_mb
        table.insert(lines, string.format("  %d  %-22s  pid=%d  rss=%d MB", slot, label, pid, rss_mb))
      else
        table.insert(lines, string.format("  %d  %-22s  pid=%d  rss=?", slot, label, pid))
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
---Both `from` and `to` must be in 1..MAX_SLOT (admin slot 0 is excluded).
---@param from integer
---@param to integer
---@param swap boolean|nil  -- if true, swap with destination's content
---@return boolean ok
---@return string|nil err
function M.move_slot(from, to, swap)
  if from == to then return false, "from and to are the same slot" end
  local function valid(s) return s >= 1 and s <= M.MAX_SLOT end
  if not valid(from) then return false, "invalid 'from' slot " .. from end
  if not valid(to) then return false, "invalid 'to' slot " .. to end

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

  -- Transfer running terminals.
  local t_from = M.state.slot_terminals[from]
  local t_to   = M.state.slot_terminals[to]
  M.state.slot_terminals[from] = swap and t_to or nil
  M.state.slot_terminals[to]   = t_from

  -- Refresh focused_slot if the move moved the focused terminal.
  -- v0.2.0: route through state.set_focused_slot so the namespace
  -- persists + the watcher mirrors into M.state.focused_slot.
  local state_mod = require("auto-agents.state")
  if M.state.focused_slot == from then
    state_mod.set_focused_slot(to)
  elseif M.state.focused_slot == to and swap then
    state_mod.set_focused_slot(from)
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
---
---Reads the focused slot DIRECTLY from the state namespace, not from
---the `M.state.focused_slot` mirror. The mirror is maintained by a
---`watch_focused_slot` subscriber registered once at setup() — if the
---auto-core events bus ever gets reset mid-session (test harness
---leakage, `:Lazy reload`, etc.), the watcher silently disappears
---and the mirror sticks at the last value it saw (typically slot 1
---= Jarvis). Bypassing the mirror here keeps the winbar truthful
---even when the events bus is dirty. The namespace `:get` doesn't
---publish; only `:set` does, so it's resilient.
function M.refresh_winbar()
  if not (M.state.panel_winid and vim.api.nvim_win_is_valid(M.state.panel_winid)) then
    return
  end
  local winbar = require("auto-agents.panel.winbar")
  local state_mod = require("auto-agents.state")
  local w = vim.api.nvim_win_get_width(M.state.panel_winid)
  local focused = state_mod.get_focused_slot()
                  or M.state.focused_slot or 1
  -- ADR 0028: `scope = "local"` so this write does NOT mutate the
  -- global-local default for `winbar`.
  pcall(vim.api.nvim_set_option_value, "winbar",
    winbar.render(focused, w),
    { win = M.state.panel_winid, scope = "local" })
end

---Re-render the navigator dock, if it's currently open. Cheap no-op
---otherwise. Called from the same code paths as refresh_winbar so the
---two surfaces stay in lock-step.
function M.refresh_dock()
  pcall(function() require("auto-agents.dock").refresh() end)
end

---Remove a slot's bootstrap entry. Kills any running terminal first,
---then deletes the entry from config.agents.bootstrap and persists.
---After removal the slot reverts to a plain shell on next focus
---(generic adapter fallback).
---
---Idempotent on the missing-entry case: returns `true, "already empty"`
---rather than failing, so re-running is safe.
---
---@param slot integer
---@return boolean ok
---@return string|nil note  -- e.g. "already empty" when nothing to remove
function M.remove_slot(slot)
  if type(slot) ~= "number" or slot < 1 or slot > M.MAX_SLOT then
    return false, "slot must be 1.." .. tostring(M.MAX_SLOT)
  end
  local removed_names = {}
  do
    local cfg = M.state.config
    local bs = cfg and cfg.agents and cfg.agents.bootstrap or {}
    for _, entry in ipairs(bs) do
      if entry.slot == slot and type(entry.name) == "string" and entry.name ~= "" then
        removed_names[#removed_names + 1] = entry.name
      end
    end
  end
  -- Kill any running terminal first (idempotent — kill_slot returns
  -- false if there's nothing running, which is fine).
  pcall(M.kill_slot, slot)

  local cfg = M.state.config
  if not (cfg and cfg.agents and cfg.agents.bootstrap) then
    return true, "already empty"
  end
  local bs = cfg.agents.bootstrap
  local removed = false
  for i = #bs, 1, -1 do
    if bs[i].slot == slot then
      table.remove(bs, i)
      removed = true
    end
  end

  if removed then
    pcall(function()
      local mailbox = require("auto-core").mailbox
      for _, name in ipairs(removed_names) do
        mailbox.unregister("agent:" .. name)
      end
    end)
    if slot >= 0 and slot <= M.MAX_SLOT then
      M.refresh_winbar()
    end
    M.refresh_keymaps()
    pcall(function() require("auto-agents.config.store").save_current() end)
    require("auto-agents.log").info("lifecycle",
      "slot " .. slot .. " bootstrap entry removed")
    return true, nil
  end
  return true, "already empty"
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
      if slot >= 0 and slot <= M.MAX_SLOT then
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

---v0.2.0 internal: mirror a slot's status into the canonical
---`auto-core.tasks.status` namespace keyed by agent name. Slot 0
---(admin) and nameless bootstrap rows are skipped — auto-core's
---surface is name-keyed, so admin doesn't have a canonical entry.
---Idempotent: auto-core's `set` no-ops when the new state matches
---the previous, so no over-publish.
---@param slot integer
---@param state "idle"|"waiting"|"working"
function M._sync_core_status(slot, state)
  if slot == 0 then return end
  local cfg = M.state.config
  if not cfg or not cfg.agents or not cfg.agents.bootstrap then return end
  for _, e in ipairs(cfg.agents.bootstrap) do
    if e.slot == slot and type(e.name) == "string" and e.name ~= "" then
      pcall(function()
        require("auto-core").tasks.status.set(e.name, state)
      end)
      return
    end
  end
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
  -- v0.2.0: also publish through auto-core.tasks.status keyed by
  -- agent name so external observers (the :AutoCoreChannel panel,
  -- other family plugins) see this slot's state. Slot 0 (admin) +
  -- nameless rows skip the canonical write.
  M._sync_core_status(slot, state)
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
  local logger = require("auto-agents.log")
  local cfg = M.state.config
  if not cfg then
    logger.error("init", "auto-agents.setup() must be called first")
    return
  end

  if slot < 0 or slot > M.MAX_SLOT then
    logger.error("init", "focus_slot: slot must be 0.." .. M.MAX_SLOT .. ", got " .. tostring(slot))
    return
  end

  local winid = ensure_main_window(false)
  if not winid then return end

  -- Wrap the entire buffer-placement flow in `_with_unfixed_buf`: the
  -- panel has `winfixbuf = true` to keep external :edit / :buffer /
  -- bufferline-clicks from hijacking the slot, but our own slot
  -- swaps need to swap the buffer. Includes both the fresh-spawn
  -- termopen path (terminal/native.lua's nvim_win_set_buf) and the
  -- re-focus path's explicit win_set_buf.
  local bufnr
  local fresh_spawn = false
  local placement_ok, placement_err = _with_unfixed_buf(winid, function()
    if slot == 0 then
      bufnr = require("auto-agents.panel.admin").get_or_create_buffer()
    else
      -- Detect whether this slot already has a live terminal. If not,
      -- the spawn will happen with the panel window as context (correct
      -- sizing).
      fresh_spawn = not (M.state.slot_terminals[slot] and M.state.slot_terminals[slot]:is_alive())
      bufnr = ensure_main_slot_terminal(slot, fresh_spawn and winid or nil)
      if not bufnr then error("no_terminal") end
    end
    -- For non-fresh spawns (re-focus / slot 0 admin), explicitly place
    -- the buffer in the panel window. Fresh spawns already did this
    -- inside start(winid) so termopen could see the dimensions.
    if not fresh_spawn then
      vim.api.nvim_win_set_buf(winid, bufnr)
    end
  end)
  if not placement_ok then
    if placement_err == "no_terminal" or
        (type(placement_err) == "string" and placement_err:find("no_terminal")) then
      return
    end
    logger.warn("panel", "focus_slot placement error: " .. tostring(placement_err))
    return
  end
  if not bufnr then return end
  -- v0.2.0: persist focused_slot via the state namespace; the
  -- watcher mirrors back into M.state.focused_slot.
  require("auto-agents.state").set_focused_slot(slot)
  vim.api.nvim_set_current_win(winid)

  -- D10 winbar tab-strip: all main slots, focused one bracketed, each
  -- wrapped in a clickable region. Adaptive: full labels when panel is
  -- wide enough, focused-only labels when it isn't. Implementation in
  -- panel/winbar.lua.
  do
    local winbar = require("auto-agents.panel.winbar")
    winbar.ensure_highlights()
    local w = vim.api.nvim_win_get_width(winid)
    -- ADR 0028: `scope = "local"` so this write does NOT mutate the
    -- global-local default for `winbar`.
    pcall(vim.api.nvim_set_option_value, "winbar", winbar.render(slot, w), { win = winid, scope = "local" })
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
      term:resize_to(winid, { bottom_margin = _resolve_bottom_margin(slot, cfg) })
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

---Release auto-agents-owned runtime resources. Intended for plugin
---teardown/hot-reload and VimLeavePre; normal slot restart should use
---restart_slot so the mailbox registration remains live.
function M.teardown()
  for slot in pairs(M.state.slot_terminals or {}) do
    pcall(M.kill_slot, slot)
  end
  pcall(function() require("auto-agents.mcp.server").stop() end)
  pcall(function() require("auto-agents.mailbox.commands").unregister_all() end)
  pcall(function()
    local mailbox = require("auto-core").mailbox
    local cfg = M.state.config
    local bs = cfg and cfg.agents and cfg.agents.bootstrap or {}
    for _, entry in ipairs(bs) do
      if type(entry.name) == "string" and entry.name ~= "" then
        mailbox.unregister("agent:" .. entry.name)
      end
    end
    mailbox.unregister("nvim")
  end)
  M.state.initialized = false
end

return M
