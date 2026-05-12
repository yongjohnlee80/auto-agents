-- Headless smoke tests for auto-agents.nvim. Run with:
--   nvim --headless -u NONE -l tests/smoke.lua
--
-- Tests focus on the panel surface and the winfixbuf-based protection
-- that keeps arbitrary file buffers out of the agent panel. Slot
-- terminals aren't actually spawned (no real CLI to drive); we
-- exercise admin-slot mounting plus the winfixbuf contract.

-- Find our own path to derive project roots (Finding 5)
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

-- Standard worktree layout: sibling auto-core.nvim/main
local core_root = plugins_root .. "/auto-core.nvim/main"
if vim.fn.isdirectory(core_root) == 0 then
  -- Fallback to plain repo if no worktree
  core_root = plugins_root .. "/auto-core.nvim"
end

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  project_root,
  core_root,
  LAZY .. "/plenary.nvim",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

local fail_count = 0
local pass_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

-- ───────────────────────── 1. setup ────────────────────────────────
print("\n[1] setup()")
local aa = require("auto-agents")
local setup_ok, err = pcall(aa.setup, {
  panel = {
    side = "right",
    min_width = 50,
    max_width = 120,
    editor_floor = 30,
    percentage = 0.30,
  },
  agents = { bootstrap = {} },
  kb = {},
  term = { enabled = false },
})
ok("setup returns without error", setup_ok, err)
ok("state.config populated", aa.state.config ~= nil)
ok("state.initialized true", aa.state.initialized == true)

-- ───────────────────────── 2. open + admin slot ────────────────────
print("\n[2] open + focus_slot(0) — admin")
aa.open(true)
local panel = aa.state.panel_winid
ok("panel_winid set", panel ~= nil and vim.api.nvim_win_is_valid(panel))
ok("winfixwidth set on panel", panel and vim.wo[panel].winfixwidth == true)
ok("winfixbuf set on panel", panel and vim.wo[panel].winfixbuf == true)

aa.focus_slot(0)
ok("focused_slot == 0", aa.state.focused_slot == 0)
local panel_buf = vim.api.nvim_win_get_buf(panel)
local ft = vim.bo[panel_buf].filetype
ok("panel filetype = auto-agents-admin", ft == "auto-agents-admin", "ft=" .. ft)
ok("winfixbuf restored after focus_slot", vim.wo[panel].winfixbuf == true)

-- ───────────────────────── 3. winfixbuf blocks :edit ───────────────
print("\n[3] winfixbuf blocks external :edit from inside panel")
local main_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if w ~= panel then main_win = w end
end
ok("main_win exists", main_win ~= nil)

vim.api.nvim_set_current_win(panel)
local tmp = "/tmp/auto-agents-smoke-target.txt"
vim.fn.writefile({ "hello" }, tmp)
local edit_ok, edit_err = pcall(vim.cmd, "edit " .. tmp)
ok(":edit errored with E1513 (winfixbuf)", not edit_ok and tostring(edit_err):find("winfixbuf"),
  "ok=" .. tostring(edit_ok) .. " err=" .. tostring(edit_err))
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel still has admin buffer after blocked :edit",
  vim.bo[panel_buf].filetype == "auto-agents-admin",
  "ft=" .. vim.bo[panel_buf].filetype)

-- ───────────────────────── 4. winfixbuf blocks :buffer ─────────────
print("\n[4] winfixbuf blocks :buffer N (bufferline-click sim)")
vim.api.nvim_set_current_win(panel)
local another = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(another, "/tmp/auto-agents-smoke-other.txt")
local buf_ok, buf_err = pcall(vim.cmd, "buffer " .. another)
ok(":buffer errored with E1513 (winfixbuf)", not buf_ok and tostring(buf_err):find("winfixbuf"))
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel still admin after blocked :buffer", vim.bo[panel_buf].filetype == "auto-agents-admin")

-- ───────────────────────── 5. legitimate slot swap works ───────────
print("\n[5] focus_slot can still swap buffers (winfixbuf temp-disabled)")
-- Faking a slot 1 entry so focus_slot(1) doesn't try to spawn.
local fake_term_buf = vim.api.nvim_create_buf(false, true)
aa.state.slot_terminals[1] = {
  get_bufnr = function() return fake_term_buf end,
  is_alive = function() return true end,
  resize_to = function() end,
}
aa.focus_slot(1)
ok("focused_slot == 1 after swap", aa.state.focused_slot == 1)
ok("panel buf is the fake-terminal buf", vim.api.nvim_win_get_buf(panel) == fake_term_buf,
  "panel_buf=" .. vim.api.nvim_win_get_buf(panel))
ok("winfixbuf re-enabled after slot swap", vim.wo[panel].winfixbuf == true)

aa.focus_slot(0)
ok("focused_slot == 0 after swap back", aa.state.focused_slot == 0)
ok("panel back on admin", vim.bo[vim.api.nvim_win_get_buf(panel)].filetype == "auto-agents-admin")
aa.state.slot_terminals[1] = nil

-- ───────────────────────── 6. close + reopen ───────────────────────
print("\n[6] close + reopen — winfixbuf reapplied on every open")
aa.close()
ok("panel_winid cleared after close", aa.state.panel_winid == nil
  or not vim.api.nvim_win_is_valid(aa.state.panel_winid))
aa.open(true)
local panel2 = aa.state.panel_winid
ok("panel reopens", panel2 ~= nil and vim.api.nvim_win_is_valid(panel2))
ok("winfixbuf set on reopened panel", vim.wo[panel2].winfixbuf == true)

-- ───────────────────── 7. panel-singleton guard ─────────────────────
-- Simulate the orphan-duplicate scenario the user reported: state
-- thinks it has no panel (e.g. lazy reload, session restore lost the
-- winid) but a panel window with our marker is still alive in the
-- current tab. A subsequent :AutoAgents call must adopt the existing
-- window instead of creating a second vsplit.
print("\n[7] panel-singleton guard")
ok("panel marker stamped on open",
  vim.w[panel2].auto_agents_panel == 1)
local pre_count = #vim.api.nvim_tabpage_list_wins(0)
aa.state.panel_winid = nil  -- pretend state lost track
aa.open(true)               -- should re-discover panel2 via marker
ok("ensure_main_window adopts the existing marked window",
  aa.state.panel_winid == panel2)
local post_count = #vim.api.nvim_tabpage_list_wins(0)
ok("no duplicate window created when state lost track",
  post_count == pre_count, "pre=" .. pre_count .. " post=" .. post_count)
-- Toggle while state is empty but a marked panel exists should
-- close the panel (not open a second one).
aa.state.panel_winid = nil
aa.toggle()
ok("toggle with stale state but live panel closes the live one",
  not vim.api.nvim_win_is_valid(panel2))

-- ───────────────────── 8. editor-window-floor invariant ─────────────
-- AutoVim layout: AutoFinder | Editor | AutoAgents. After a :q on the
-- last editor window, the panels would otherwise stretch to fill the
-- viewport. The editor_floor module materializes a scratch in a new
-- vsplit between the panels (cfg.layout.editor_window_strategy =
-- "create_scratch", default) so the invariant "an editor window must
-- exist whenever the panel is open" holds.
print("\n[8] editor-window-floor invariant")

local floor = require("auto-agents.integrations.editor_floor")

-- Re-open the panel for the floor tests (test [7] toggled it closed).
aa.open(true)

-- 8a. is_editor_window: panels and float windows are NOT editor
-- windows; regular file buffers ARE.
local panel3 = aa.state.panel_winid
ok("panel is not an editor window per is_editor_window",
  floor.is_editor_window(panel3) == false)

-- Simulate a regular editor buffer in a sibling window. The smoke
-- prelude is run from a regular buffer; if no sibling exists, create
-- one with vsplit.
local function ensure_sibling()
  local panel = aa.state.panel_winid
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= panel and floor.is_editor_window(w) then
      return w
    end
  end
  pcall(vim.api.nvim_set_current_win, panel)
  vim.cmd("leftabove vnew")
  return vim.api.nvim_get_current_win()
end
local sibling = ensure_sibling()
ok("sibling vsplit is identified as an editor window",
  floor.is_editor_window(sibling))
ok("find_editor_window returns the sibling",
  floor.find_editor_window() == sibling
    or floor.is_editor_window(floor.find_editor_window() or -1))

-- 8b. materialize_editor_scratch produces a non-panel editor window
-- without winfixwidth/winfixbuf.
-- First close the sibling so we test the materialize path against
-- the panel-only state.
pcall(vim.api.nvim_win_close, sibling, true)
local scratch_winid = floor.materialize_editor_scratch()
ok("materialize_editor_scratch returned a winid",
  scratch_winid and vim.api.nvim_win_is_valid(scratch_winid))
ok("materialized scratch is an editor window per predicate",
  floor.is_editor_window(scratch_winid))
ok("materialized scratch has no winfixwidth",
  vim.wo[scratch_winid].winfixwidth == false)
ok("materialized scratch has no winfixbuf",
  vim.wo[scratch_winid].winfixbuf == false)

-- 8c. count_editor_windows reflects the layout.
local n_editors = floor.count_editor_windows()
ok("count_editor_windows returns >= 1 with scratch present",
  n_editors >= 1, "got " .. tostring(n_editors))

-- Cleanup so subsequent tests start fresh.
pcall(vim.api.nvim_win_close, scratch_winid, true)

-- ───────────────────── 9. flat slot model + admin DSL ───────────────
-- v0.1.24: cfg.panel.slot_count (default 5, range 2..9). The admin
-- DSL `slot add N` / `slot remove N` mutates the count and re-syncs
-- M.MAX_SLOT. Removal refuses if any to-be-removed slot has an agent.
print("\n[9] flat slot model + admin DSL")

ok("M.MAX_SLOT defaults to 5 after setup",
  aa.MAX_SLOT == 5, "got " .. tostring(aa.MAX_SLOT))
ok("M.MAIN_SLOT_MAX equals MAX_SLOT after setup",
  aa.MAIN_SLOT_MAX == aa.MAX_SLOT)

local cfg_mod = require("auto-agents.config")
ok("SLOT_COUNT_MIN exported",
  cfg_mod.SLOT_COUNT_MIN == 2, "got " .. tostring(cfg_mod.SLOT_COUNT_MIN))
ok("SLOT_COUNT_MAX exported",
  cfg_mod.SLOT_COUNT_MAX == 9, "got " .. tostring(cfg_mod.SLOT_COUNT_MAX))

-- sync_slot_count picks up cfg mutations.
aa.state.config.panel.slot_count = 7
aa.sync_slot_count()
ok("sync_slot_count moves MAX_SLOT to 7",
  aa.MAX_SLOT == 7, "got " .. tostring(aa.MAX_SLOT))
aa.state.config.panel.slot_count = 5
aa.sync_slot_count()
ok("sync_slot_count moves MAX_SLOT back to 5",
  aa.MAX_SLOT == 5)

-- Admin REPL tab-complete: `slot` registers + `slot add` offers integers.
local admin = require("auto-agents.panel.admin")
local _, top_cands = admin._complete_at("", 0)
ok("complete_at empty prompt offers 'slot'",
  vim.tbl_contains(top_cands, "slot"))
local _, slot_cands = admin._complete_at("slot ", 5)
ok("complete_at 'slot ' offers 'add'", vim.tbl_contains(slot_cands, "add"))
ok("complete_at 'slot ' offers 'remove'", vim.tbl_contains(slot_cands, "remove"))
ok("complete_at 'slot ' offers 'show'", vim.tbl_contains(slot_cands, "show"))

-- Validation: out-of-range slot_count rejected by config.validate.
local err_low = cfg_mod.validate({
  log_level = "info",
  panel = { side = "right", min_width = 60, max_width = 130, percentage = 0.35,
    width_override = nil, slot_count = 1, editor_floor = 40, slot_rail = "winbar",
    bottom_margin = 1 },
  agents = { default_kind = "claude", primary_kind = "claude", bootstrap = {} },
  kb = { default_scope = "shared" },
  terminal = { provider = "auto" },
  term = { enabled = true, fkeys = {} },
})
ok("validate rejects slot_count = 1 (below floor 2)",
  type(err_low) == "string" and err_low:find("slot_count") ~= nil,
  tostring(err_low))
local err_high = cfg_mod.validate({
  log_level = "info",
  panel = { side = "right", min_width = 60, max_width = 130, percentage = 0.35,
    width_override = nil, slot_count = 10, editor_floor = 40, slot_rail = "winbar",
    bottom_margin = 1 },
  agents = { default_kind = "claude", primary_kind = "claude", bootstrap = {} },
  kb = { default_scope = "shared" },
  terminal = { provider = "auto" },
  term = { enabled = true, fkeys = {} },
})
ok("validate rejects slot_count = 10 (above cap 9)",
  type(err_high) == "string" and err_high:find("slot_count") ~= nil,
  tostring(err_high))

-- Dock entries reflect the live slot_count rather than a hardcoded
-- 0..9. Open the dock once at slot_count=5, count entries; grow to 7
-- via sync_slot_count, count again; expect entry count to grow by 2.
local dock = require("auto-agents.dock")

aa.state.config.panel.slot_count = 5
aa.sync_slot_count()
dock.open()
local lines5 = vim.api.nvim_buf_get_lines(dock._state.bufnr, 0, -1, false)
dock.close()
ok("dock at slot_count=5 has editor + 6 slot lines (0..5)",
  #lines5 == 7, "got " .. #lines5)

aa.state.config.panel.slot_count = 7
aa.sync_slot_count()
dock.open()
local lines7 = vim.api.nvim_buf_get_lines(dock._state.bufnr, 0, -1, false)
dock.close()
ok("dock at slot_count=7 has editor + 8 slot lines (0..7)",
  #lines7 == 9, "got " .. #lines7)

-- restore
aa.state.config.panel.slot_count = 5
aa.sync_slot_count()

-- ───────────────────────── 10. logger shim → auto-core.log ─────────────────────────
-- v0.2.0 migration: auto-agents.logger is now a thin shim over
-- auto-core.log. Each call routes through the canonical logger
-- with the component prefixed by "auto-agents." so the unified
-- log stream stays namespaced.
print("\n[10] logger shim — delegates to auto-core.log with auto-agents prefix")

local logger    = require("auto-agents.logger")
local core_log  = require("auto-core").log
core_log._reset_for_tests()

-- Stub the user-visible side-effects so test output stays clean.
local orig_notify = vim.notify
local orig_echo   = vim.api.nvim_echo
vim.notify       = function() end
vim.api.nvim_echo = function() end

-- After reset, default level is INFO. error/warn/info should record;
-- debug/trace should drop. Other auto-agents code paths may have
-- queued log entries during setup; we measure the delta after the
-- reset, then drain to be sure our calls are the only contribution.
local before = #core_log.recent()
logger.error("spawn", "boom")
logger.warn("init",  "wait")
logger.info("panel", "fyi")
logger.debug("panel", "internal")  -- dropped (below INFO)
logger.trace("panel", "deep")      -- dropped

vim.wait(20)  -- drain pending vim.schedule notify mirrors

local ring = core_log.recent()
-- Other auto-agents code paths (e.g. editor-floor scratch
-- materialization from earlier tests) may have queued log entries
-- that drain during vim.wait. We only care that OUR 3 calls landed
-- AND the dropped levels (debug/trace) didn't.
ok("logger shim recorded at least 3 entries",
  #ring - before >= 3,
  string.format("before=%d after=%d", before, #ring))
local function find_by_level(name)
  local count = 0
  for _, e in ipairs(ring) do
    if e.level_name == name then count = count + 1 end
  end
  return count
end
ok("no DEBUG entries from filtered calls",
  find_by_level("DEBUG") == 0)
ok("no TRACE entries from filtered calls",
  find_by_level("TRACE") == 0)

-- Find our entries by component. Earlier ring entries (from other
-- code paths) may sit between resets; locate ours by name.
local function find_by_component(name)
  for _, e in ipairs(ring) do
    if e.component == name then return e end
  end
  return nil
end
local e_spawn = find_by_component("auto-agents.spawn")
local e_init  = find_by_component("auto-agents.init")
local e_panel = find_by_component("auto-agents.panel")
ok("entry 'auto-agents.spawn' present",
  e_spawn ~= nil and e_spawn.level_name == "ERROR")
ok("entry 'auto-agents.init' present",
  e_init ~= nil and e_init.level_name == "WARN")
ok("entry 'auto-agents.panel' present",
  e_panel ~= nil and e_panel.level_name == "INFO")

-- Already-prefixed components pass through unchanged.
core_log._reset_for_tests()
logger.info("auto-agents.lifecycle", "kill called")
local r2 = core_log.recent()
ok("already-prefixed component is NOT double-prefixed",
  r2[1] and r2[1].component == "auto-agents.lifecycle",
  "got '" .. tostring(r2[1] and r2[1].component) .. "'")

-- No component at all (caller passes message as first arg).
core_log._reset_for_tests()
logger.info("no-component-message")
local r3 = core_log.recent()
ok("string-only first arg gets prefixed (treated as component)",
  r3[1] and r3[1].component
    and r3[1].component:sub(1, #"auto-agents") == "auto-agents",
  "got '" .. tostring(r3[1] and r3[1].component) .. "'")

-- Non-string first arg falls through to default namespace.
core_log._reset_for_tests()
logger.info({ payload = "data" }, "with table")
local r4 = core_log.recent()
ok("table first arg → component='auto-agents'",
  r4[1] and r4[1].component == "auto-agents",
  "got '" .. tostring(r4[1] and r4[1].component) .. "'")

-- Setup forwards log_level.
logger.setup({ log_level = "error" })
ok("logger.setup({log_level='error'}) lowers level via auto-core",
  core_log.is_level_enabled("error") == true
    and core_log.is_level_enabled("warn") == false)

-- Restore default level + stubs.
logger.setup({ log_level = "info" })
vim.notify       = orig_notify
vim.api.nvim_echo = orig_echo
core_log._reset_for_tests()

-- ───────────────────────── 11. state — auto-core namespace bridge ─────────────────────────
-- v0.2.0 migration: panel slot_count + width_override + focused_slot
-- live in auto-core.state.namespace("auto-agents") with json persist.
-- setup() installs watchers that mirror namespace mutations into
-- cfg.panel.* and aa.state.focused_slot, plus call the side-effect
-- functions (sync_slot_count, refresh_panel_width).
print("\n[11] state — set_* drives cfg.panel + sync side-effects")
local state_mod = require("auto-agents.state")

-- set_slot_count: namespace write → watcher updates cfg.panel.slot_count
-- AND aa.MAX_SLOT (because the watcher calls aa.sync_slot_count()).
local before_max = aa.MAX_SLOT
local ok_sc = state_mod.set_slot_count(7)
ok("state.set_slot_count(7) succeeds", ok_sc)
ok("namespace value is 7", state_mod.get_slot_count() == 7)
ok("cfg.panel.slot_count mirrored to 7",
  aa.state.config.panel.slot_count == 7)
ok("aa.MAX_SLOT updated via sync_slot_count",
  aa.MAX_SLOT == 7,
  string.format("before=%d after=%d", before_max, aa.MAX_SLOT))

-- Out-of-range rejected.
local ok_bad, err_bad = state_mod.set_slot_count(99)
ok("state.set_slot_count(99) rejected with err string",
  ok_bad == false and type(err_bad) == "string"
    and err_bad:find("slot_count must be an integer"))
ok("namespace value unchanged after rejection",
  state_mod.get_slot_count() == 7)

-- set_width_override: namespace write → cfg.panel.width_override mirrored.
local ok_wo = state_mod.set_width_override(80)
ok("state.set_width_override(80) succeeds", ok_wo)
ok("cfg.panel.width_override mirrored to 80",
  aa.state.config.panel.width_override == 80)

-- nil clears.
state_mod.set_width_override(nil)
ok("state.set_width_override(nil) clears the override",
  state_mod.get_width_override() == nil
    and aa.state.config.panel.width_override == nil)

-- set_focused_slot: namespace write → aa.state.focused_slot mirrored.
state_mod.set_focused_slot(3)
ok("state.set_focused_slot(3) mirrors to aa.state.focused_slot",
  state_mod.get_focused_slot() == 3
    and aa.state.focused_slot == 3)

-- Restore (slot_count back to default 5 so subsequent tests aren't
-- distorted; aa.sync_slot_count fires via the watcher).
state_mod.set_slot_count(5)
state_mod.set_focused_slot(1)

-- ───────────────────────── 12. panel — auto-core.ui.panel singleton bridge ─────────────────────────
-- v0.2.0 migration: ensure_main_window delegates to the
-- auto-core.ui.panel singleton claimed at setup() (M._panel).
-- The marker, winfixwidth/winfixbuf, on_open/on_close hooks, and
-- WinResized/VimResized auto-pin enforcement all live in auto-core.
print("\n[12] panel — auto-core.ui.panel delegation")

ok("M._panel singleton claimed at setup",
  type(aa._panel) == "table" and aa._panel.opts ~= nil,
  type(aa._panel))
ok("M._panel.opts.name == 'auto-agents'",
  aa._panel.opts.name == "auto-agents")
ok("panel marker var derives to 'auto_agents_panel'",
  aa._panel._marker_var == "auto_agents_panel",
  tostring(aa._panel._marker_var))

-- Close any existing panel from earlier tests, then reopen via the
-- canonical M.open path.
aa.close()
aa.open(true)
ok("panel opens after reopen via M.open(force)",
  aa.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(aa.state.panel_winid))
ok("panel marker stamped on the open winid",
  vim.api.nvim_win_get_var(aa.state.panel_winid, "auto_agents_panel") == 1)
ok("panel name marker (auto-core canonical) stamped too",
  vim.api.nvim_win_get_var(aa.state.panel_winid, "auto_core_panel_name")
    == "auto-agents")
ok("winfixwidth set on panel",
  vim.wo[aa.state.panel_winid].winfixwidth == true)
ok("winfixbuf set on panel",
  vim.wo[aa.state.panel_winid].winfixbuf == true)

-- width_override watcher should drive panel:resize.
state_mod.set_width_override(72)
vim.wait(20)
ok("width_override=72 applied as a panel pin",
  aa._panel.user_width == 72,
  "got " .. tostring(aa._panel.user_width))
state_mod.set_width_override(nil)
vim.wait(20)
ok("width_override=nil clears the panel pin",
  aa._panel.user_width == nil)

-- Toggle: open + close routes through panel singleton.
local pre_toggle_winid = aa.state.panel_winid
aa.toggle()
ok("toggle() closes the live panel",
  aa.state.panel_winid == nil
    or not vim.api.nvim_win_is_valid(aa.state.panel_winid),
  "winid=" .. tostring(aa.state.panel_winid))
aa.toggle(true)
ok("toggle(true) re-opens the panel",
  aa.state.panel_winid ~= nil
    and vim.api.nvim_win_is_valid(aa.state.panel_winid))

aa.close()

-- ───────────────────────── 13. status — set_status mirrors to auto-core.tasks.status ─────────────────────────
-- v0.2.0 migration: M.set_status (and the passive observer) now
-- write through to auto-core.tasks.status keyed by agent name. The
-- :AutoCoreChannel panel + other family plugins observe transitions
-- via the canonical auto-core surface.
print("\n[13] status — set_status mirrors slot state to auto-core.tasks.status")

-- Seed a synthetic agent row so the slot→name resolver has something
-- to map. We can't spawn real terminals headlessly; just stuff the
-- bootstrap config so M._sync_core_status finds a name.
aa.state.config.agents = aa.state.config.agents or {}
aa.state.config.agents.bootstrap = {
  { slot = 1, name = "smoke-jarvis", kind = "claude" },
  { slot = 2, name = "smoke-vision", kind = "codex" },
}
local core_status = require("auto-core").tasks.status
core_status._reset_for_tests()

aa.set_status(1, "working")
ok("set_status(1, 'working') mirrors to auto-core under agent name",
  core_status.get("smoke-jarvis") == "working",
  "got " .. tostring(core_status.get("smoke-jarvis")))

aa.set_status(1, "waiting")
ok("set_status(1, 'waiting') updates auto-core",
  core_status.get("smoke-jarvis") == "waiting")

aa.set_status(1, "idle")
ok("set_status(1, 'idle') sets idle in auto-core (not nil)",
  core_status.get("smoke-jarvis") == "idle")

-- Slot 0 (admin) should NOT touch auto-core (no agent identity).
aa._sync_core_status(0, "working")
local snap = core_status.list()
ok("slot 0 (admin) skipped in auto-core mirror",
  snap.smoke == nil and snap[0] == nil and snap.admin == nil,
  vim.inspect(snap))

-- Nameless slot should also skip.
aa.state.config.agents.bootstrap[#aa.state.config.agents.bootstrap + 1] =
  { slot = 3, name = "", kind = "claude" }
aa._sync_core_status(3, "working")
ok("nameless agent skipped in auto-core mirror",
  core_status.get("") == nil)

core_status._reset_for_tests()
aa.state.config.agents.bootstrap = {}

-- ───────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
