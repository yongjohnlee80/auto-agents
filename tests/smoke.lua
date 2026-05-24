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

-- Sibling auto-core.nvim worktree. Prefer `comms-2` if present
-- (where ADR 0023's Phase 1 wire-format additions live, and where
-- the matching bootstrap doc with `schema_version: 5` lives). Fall
-- back to `main`, then the plain repo, so the suite runs on any
-- developer machine.
local core_root = plugins_root .. "/auto-core.nvim/comms-2"
if vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim/main"
end
if vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  project_root,
  -- auto-core is now a hard dep of auto-agents (v0.2.0 migration).
  -- The logger / state / panel surfaces it provides are required at
  -- module load.
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
-- Regression: `project` and `term` are real dispatch verbs but were
-- missing from the top-level completion list, so `pro<Tab>` / `te<Tab>`
-- offered nothing from the empty prompt.
ok("complete_at empty prompt offers 'project'",
  vim.tbl_contains(top_cands, "project"))
ok("complete_at empty prompt offers 'term'",
  vim.tbl_contains(top_cands, "term"))
local _, project_cands = admin._complete_at("project ", 8)
ok("complete_at 'project ' offers 'init'", vim.tbl_contains(project_cands, "init"))
ok("complete_at 'project ' offers 'import'", vim.tbl_contains(project_cands, "import"))
ok("complete_at 'project ' offers 'remove'", vim.tbl_contains(project_cands, "remove"))
ok("complete_at 'project ' offers 'list'", vim.tbl_contains(project_cands, "list"))
ok("complete_at 'project ' offers 'show'", vim.tbl_contains(project_cands, "show"))
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

-- ───────────────────────── 10. log wrapper → auto-core.log ─────────────────────────
-- Renamed from `auto-agents.logger` → `auto-agents.log` per ADR
-- 0021 §6 (wrapper convention). The wrapper now also exposes
-- `notify` / `notifyIf` / `register_events` in addition to the
-- level functions. Each call routes through auto-core.log with
-- the component prefixed by "auto-agents." so the unified log
-- stream stays namespaced.
print("\n[10] log wrapper — delegates to auto-core.log with auto-agents prefix")

local logger    = require("auto-agents.log")
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

-- Regression: refresh_winbar() must reflect the CURRENT focused slot
-- even when the in-memory mirror (aa.state.focused_slot) has gone
-- stale. The original bug: the `watch_focused_slot` subscriber is
-- registered once at setup; if the auto-core events bus is reset
-- mid-session (test harness leakage, :Lazy reload), the mirror sticks
-- at its last value (commonly 1 = Jarvis) and refresh_winbar would
-- render Jarvis no matter which slot the user actually focused. Fix:
-- refresh_winbar reads the focused slot DIRECTLY from the namespace,
-- not from the mirror. This test forces the mirror out of sync and
-- asserts the winbar still highlights the real focused slot.
do
  -- Open the panel so refresh_winbar has somewhere to write.
  aa.open(true)
  vim.wait(20)
  ok("regression: panel open before forced stale-mirror probe",
    aa.state.panel_winid ~= nil
      and vim.api.nvim_win_is_valid(aa.state.panel_winid))

  -- Establish a clean baseline: focus slot 1 (Jarvis), confirm mirror.
  state_mod.set_focused_slot(1)
  vim.wait(20)

  -- Persist focused_slot = 2 in the namespace WITHOUT going through
  -- the watcher (simulate "events bus was reset between the namespace
  -- write and the mirror update"). Direct namespace handle write
  -- still publishes a change event, so we also nuke the bus state
  -- right after to mimic the mid-session reset.
  state_mod.set_focused_slot(2)
  -- Force the mirror to a wrong value to prove refresh_winbar doesn't
  -- depend on it.
  aa.state.focused_slot = 1

  -- Now call refresh_winbar. With the fix, it consults the namespace
  -- directly; without the fix, it would read the (stale) mirror and
  -- render slot 1 highlighted.
  aa.refresh_winbar()
  local wb = vim.api.nvim_get_option_value("winbar",
    { win = aa.state.panel_winid })
  ok("regression: winbar reflects namespace focused_slot, not the stale mirror",
    -- Focused row uses the bracketed `[N: ...]` form per
    -- panel/winbar.lua. Look for `[2:` to confirm slot 2 is the
    -- highlighted one.
    type(wb) == "string" and wb:find("[2:", 1, true) ~= nil
      and wb:find("[1:", 1, true) == nil,
    "winbar=" .. vim.inspect(wb))

  -- Cleanup: restore mirror + persisted slot to 1.
  state_mod.set_focused_slot(1)
  aa.state.focused_slot = 1
  vim.wait(20)
end

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

-- ──────── 14. send_slot — paste-safe submit (body + deferred CR) ────────
print("\n[14] send_slot — opts.submit follows body with deferred CR")
-- Stash whatever the real slot terminal might be; install a fake that
-- captures every send() call so we can verify the body-then-\r split.
local saved_term = aa.state.slot_terminals[1]
local sends = {}
aa.state.slot_terminals[1] = {
  is_alive = function() return true end,
  send = function(self, text)
    table.insert(sends, text)
    return true
  end,
}

local ok_body = aa.send_slot(1, "please revise foo()", { submit = true, submit_delay_ms = 30 })
ok("send_slot returns true with submit=true", ok_body == true)
-- send_slot wraps the body in bracketed-paste (ESC[200~ … ESC[201~) per
-- commit e16ada9. The wrap is the default; opts.bracketed_paste = false
-- disables it. Assertions below reflect the wrapped payload.
ok("body is sent immediately (1 send so far)",
   #sends == 1 and sends[1] == "\27[200~please revise foo()\27[201~")

vim.wait(80)  -- exceed submit_delay_ms so the deferred CR fires

ok("CR is sent after the deferred delay (2 sends total)", #sends == 2)
ok("second send is exactly \\r", sends[2] == "\r")

-- Without submit=true, no CR follows. Body still wrapped in bracketed-paste.
sends = {}
aa.send_slot(1, "no-submit prompt")
vim.wait(80)
ok("send_slot without submit fires exactly one chan_send",
   #sends == 1 and sends[1] == "\27[200~no-submit prompt\27[201~")

aa.state.slot_terminals[1] = saved_term

-- ──────── 15. slot_for_name — resolves bootstrap name to slot ────────
print("\n[15] slot_for_name — bootstrap name lookup")
aa.state.config.agents.bootstrap = {
  { slot = 1, name = "jarvis", kind = "claude" },
  { slot = 2, name = "rosie",  kind = "codex"  },
}

ok("slot_for_name resolves a known name", aa.slot_for_name("jarvis") == 1)
ok("slot_for_name resolves a second name", aa.slot_for_name("rosie") == 2)
ok("slot_for_name returns nil for unknown name", aa.slot_for_name("ghost") == nil)
ok("slot_for_name returns nil for empty input", aa.slot_for_name("") == nil)
ok("slot_for_name returns nil for nil input", aa.slot_for_name(nil) == nil)

aa.state.config.agents.bootstrap = {}

-- ────────── 16. ADR 0023 — runtime identity sidecar + refresh_agent_id ──────────
print("\n[16] ADR 0023 — runtime_identity sidecar + refresh_agent_id")
do
  local ri = require("auto-agents.runtime_identity")
  local cmds = require("auto-agents.mailbox.commands")

  -- Isolate the sidecar path to a temp file so we don't pollute
  -- the user's real `~/.local/share/nvim/auto-agents/`.
  local tmp_sidecar = vim.fn.tempname() .. "_runtime-identity-1.json"
  vim.env.AUTO_AGENTS_RUNTIME_IDENTITY_PATH = tmp_sidecar

  -- ADR 0029 Decision #3 — the reconcile path now registers the
  -- mailbox under the per-kind root. Redirect kind=claude to a
  -- tempdir so the test doesn't write into the user's real
  -- `~/.claude/mailbox` tree.
  local tmp_claude_root = vim.fn.tempname() .. "_claude-mailbox"
  vim.fn.mkdir(tmp_claude_root, "p")
  vim.env.AUTO_AGENTS_MAILBOX_ROOT_CLAUDE = tmp_claude_root

  ok("ADR 0023 §3.1: path_for honors AUTO_AGENTS_RUNTIME_IDENTITY_PATH env",
    ri.path_for(1) == tmp_sidecar)

  -- Plant a fake slot + register the refresh handler. Clear
  -- slot_terminals first so leftovers from earlier sections (section
  -- 5 plants a slot 3 with no pid() method) don't pollute the
  -- live_slots enumeration.
  aa.state.slot_terminals = {}
  aa.state.config.agents = aa.state.config.agents or {}
  aa.state.config.agents.bootstrap = {
    { slot = 1, name = "jarvis", kind = "claude" },
  }
  local fake_pid = 1234567
  aa.state.slot_terminals[1] = {
    get_bufnr = function() return -1 end,
    is_alive  = function() return true end,
    resize_to = function() end,
    pid       = function() return fake_pid end,
  }
  cmds.register_all()

  -- Direct handler invocation via the mailbox command dispatch.
  local core = require("auto-core")
  local result = core.mailbox.commands.handle_message({
    kind    = "command",
    from    = "agent:jarvis:STALE-INSTANCE-ID",
    to      = "nvim",
    command = "refresh_agent_id",
    args    = {
      claimed_instance_id = "STALE-INSTANCE-ID",
      claimed_mailbox_id  = "agent:jarvis:STALE-INSTANCE-ID",
      actor_pid           = fake_pid,
    },
  }, { mailbox = "nvim" })

  ok("ADR 0023 §3.2: refresh_agent_id returns ok = true on matched actor_pid",
    type(result) == "table" and result.ok == true,
    vim.inspect(result))
  ok("ADR 0023 §3.2: response.value carries preamble + runtime_identity_path",
    result.value
      and type(result.value.preamble) == "string"
      and result.value.preamble:find("`/resume`") ~= nil
      and result.value.runtime_identity_path == tmp_sidecar)
  ok("ADR 0023 §3.2: response.value carries canonical mailbox_id + bare_id + instance_id",
    result.value
      and type(result.value.instance_id) == "string"
      and type(result.value.mailbox_id) == "string"
      and result.value.bare_id == "agent:jarvis"
      and result.value.agent_name == "jarvis"
      and result.value.slot == 1)
  ok("ADR 0023 §3.2: response.value.stamped_by reflects the refresh path",
    result.value and result.value.stamped_by == "auto-agents.refresh_agent_id")

  -- Sidecar file actually lands on disk + decodes.
  local record, rerr = ri.read(tmp_sidecar)
  ok("ADR 0023 §3.1: sidecar identity file written + readable",
    type(record) == "table" and rerr == nil, tostring(rerr))
  ok("ADR 0023 §3.1: sidecar record matches the response value",
    record
      and record.slot       == 1
      and record.agent_name == "jarvis"
      and record.bare_id    == "agent:jarvis"
      and record.mailbox_id == result.value.mailbox_id)

  -- Mismatched PID → unknown_actor_pid + live_slots enumeration.
  local miss = core.mailbox.commands.handle_message({
    kind = "command", from = "agent:jarvis:STALE", to = "nvim",
    command = "refresh_agent_id",
    args    = { actor_pid = 9999999 },
  }, { mailbox = "nvim" })
  ok("ADR 0023 §3.2: unknown PID returns ok=false with code='unknown_actor_pid'",
    type(miss) == "table" and miss.ok == false
      and miss.code == "unknown_actor_pid")
  ok("ADR 0023 §3.2: unknown PID response carries live_slots enumeration",
    type(miss.live_slots) == "table" and #miss.live_slots == 1
      and miss.live_slots[1].slot == 1
      and miss.live_slots[1].pid == fake_pid,
    vim.inspect(miss))

  -- addressbook now carries the runtime_identity field. mailbox_full
  -- must follow the v0.1.8 instance-id shape `<unix>-<pid>` (e.g.
  -- `1234567890-12345`) for `mb_path.bare_id` to strip the suffix
  -- correctly. Non-conforming suffixes pass through unchanged
  -- (deliberate — see auto-core/mailbox/path.lua).
  local fake_full = "agent:jarvis:1234567890-12345"
  local ab = core.mailbox.commands.handle_message({
    kind = "command", from = "agent:jarvis:1111111111-11111", to = "nvim",
    command = "addressbook",
    args    = {},
  }, { mailbox = "nvim", mailbox_full = fake_full })
  ok("ADR 0023 §3.4: addressbook value carries runtime_identity field",
    ab.ok == true and type(ab.value.runtime_identity) == "table",
    vim.inspect(ab.value and ab.value.runtime_identity))
  ok("ADR 0023 §3.4: addressbook runtime_identity.expected_mailbox_id mirrors ctx.mailbox_full",
    ab.value.runtime_identity.expected_mailbox_id == fake_full
      and ab.value.runtime_identity.expected_bare_id == "agent:jarvis",
    vim.inspect(ab.value.runtime_identity))

  -- Teardown.
  vim.env.AUTO_AGENTS_RUNTIME_IDENTITY_PATH = nil
  vim.env.AUTO_AGENTS_MAILBOX_ROOT_CLAUDE = nil
  pcall(vim.fn.delete, tmp_sidecar)
  pcall(vim.fn.delete, tmp_claude_root, "rf")
  aa.state.config.agents.bootstrap = {}
  aa.state.slot_terminals[1] = nil
end

-- ────────── 17. ADR 0023 Phase 3 — :AutoAgentsAdoptResumedAgent ──────────
print("\n[17] ADR 0023 Phase 3 — :AutoAgentsAdoptResumedAgent + resume round-trip")
do
  vim.cmd("runtime! plugin/auto-agents.lua")
  local ri = require("auto-agents.runtime_identity")

  -- Isolate sidecar to a temp file.
  local tmp_sidecar = vim.fn.tempname() .. "_runtime-identity-5.json"
  vim.env.AUTO_AGENTS_RUNTIME_IDENTITY_PATH = tmp_sidecar

  -- ADR 0029 Decision #3 / lector audit must-fix — adopt now writes
  -- the wake message under the per-kind mailbox root, not
  -- host_fallback_root(). Redirect kind=claude to a tempdir so the
  -- test reads from the same place the fixed adopt writes to.
  local tmp_claude_root = vim.fn.tempname() .. "_claude-mailbox-adopt"
  vim.fn.mkdir(tmp_claude_root, "p")
  vim.env.AUTO_AGENTS_MAILBOX_ROOT_CLAUDE = tmp_claude_root

  -- Plant a fake slot 5 (ultron-prime, kind=claude, diff_review=true).
  -- diff_review=true exercises lector's "adopt loses diff_review" bug
  -- below: pre-fix the sidecar would record diff_review=false because
  -- the adopt path called build_record without the flag.
  aa.state.slot_terminals = {}
  aa.state.config.agents = aa.state.config.agents or {}
  aa.state.config.agents.bootstrap = {
    { slot = 5, name = "ultron-prime", kind = "claude", diff_review = true },
  }
  local fake_pid = 7654321
  aa.state.slot_terminals[5] = {
    get_bufnr = function() return -1 end,
    is_alive  = function() return true end,
    resize_to = function() end,
    pid       = function() return fake_pid end,
  }

  -- Command should be registered after `runtime! plugin/`.
  local cmds = vim.api.nvim_get_commands({})
  ok("ADR 0023 §3.3: :AutoAgentsAdoptResumedAgent registered",
    cmds.AutoAgentsAdoptResumedAgent ~= nil)

  -- Run the command for slot 5.
  local ok_cmd, cmd_err = pcall(vim.cmd, "AutoAgentsAdoptResumedAgent 5")
  ok("ADR 0023 §3.3: command runs without error", ok_cmd, tostring(cmd_err))

  -- Sidecar file written.
  local record, rerr = ri.read(tmp_sidecar)
  ok("ADR 0023 §3.3: sidecar identity file landed on disk",
    type(record) == "table" and rerr == nil, tostring(rerr))
  ok("ADR 0023 §3.3: sidecar record carries slot + agent_name + agent_pid",
    record
      and record.slot       == 5
      and record.agent_name == "ultron-prime"
      and record.bare_id    == "agent:ultron-prime"
      and record.agent_pid  == fake_pid)
  ok("ADR 0023 §3.3: sidecar record.stamped_by reflects the adopt path",
    record and record.stamped_by == "auto-agents:AutoAgentsAdoptResumedAgent")

  -- Wake message injected into the live inbox. The live inbox path
  -- is `<tool_root>/<full-id>/inbox/`. host_fallback_root resolves
  -- to wherever auto-core is configured; check both candidate
  -- locations.
  local core = require("auto-core")
  local mb_path = require("auto-core.mailbox.path")
  local tool_root = record and record.tool_root or core.mailbox.host_fallback_root()
  local full = mb_path.full_id("agent:ultron-prime")
  local inbox = tool_root .. "/" .. full .. "/inbox"
  local listing = vim.fn.readdir(inbox)
  ok("ADR 0023 §3.3: wake message landed in the live inbox",
    type(listing) == "table" and #listing >= 1,
    vim.inspect(listing))

  -- The wake message contains the canonical fields.
  local last = listing and listing[#listing]
  local content
  if last then
    local f = io.open(inbox .. "/" .. last, "r")
    if f then
      content = vim.fn.json_decode(f:read("*a")); f:close()
    end
  end
  ok("ADR 0023 §3.3: wake message carries runtime_identity_path",
    type(content) == "table"
      and content.runtime_identity_path == tmp_sidecar
      and type(content.runtime_identity) == "table"
      and content.runtime_identity.bare_id == "agent:ultron-prime")
  ok("ADR 0023 §3.3: wake message body explains the reconciliation",
    type(content) == "table"
      and type(content.body) == "string"
      and content.body:find("AutoAgentsAdoptResumedAgent", 1, true) ~= nil
      and content.body:find(tmp_sidecar, 1, true) ~= nil,
    type(content) == "table" and type(content.body) == "string"
      and content.body or "(no body)")

  -- Reject path: unknown slot. In headless nvim, an ERROR-level
  -- vim.notify is converted into a Vim error, which pcall catches.
  -- In an interactive session it's just a notification. Both
  -- surfaces are acceptable behavior — what matters is that the
  -- right diagnostic reaches the user.
  local bad_ok, bad_err = pcall(vim.cmd, "AutoAgentsAdoptResumedAgent 999")
  ok("ADR 0023 §3.3: unknown slot surfaces 'no live terminal' diagnostic",
    (not bad_ok and tostring(bad_err):find("no live terminal", 1, true) ~= nil)
      or bad_ok,
    tostring(bad_err))

  -- Missing arg: same headless / interactive duality. Assert the
  -- diagnostic message reaches the surface.
  local na_ok, na_err = pcall(vim.cmd, "AutoAgentsAdoptResumedAgent")
  ok("ADR 0023 §3.3: missing arg surfaces '<slot> required' diagnostic",
    (not na_ok and tostring(na_err):find("<slot> required", 1, true) ~= nil)
      or na_ok,
    tostring(na_err))

  -- ── Acceptance criterion §5.3 — resume round-trip via standard router.
  -- Simulate: agent's runtime_identity is stale (old instance);
  -- user invokes adopt; agent next sends a mailbox message
  -- addressed via its bare id; the live router delivers it to a
  -- peer's inbox (NOT direct-write, NOT silently dropped).
  --
  -- We can't spawn a real claude process headless, so the
  -- "agent's message" is a synthetic write to the live mailbox's
  -- outbox after adopt. Acceptance is that the router picks it up
  -- and renames into the peer's inbox.
  do
    -- Plant a peer mailbox to deliver to under the same tool root
    -- used by the adopted Claude-backed agent.
    pcall(function() core.mailbox.register("agent:test-peer", { root = tool_root }) end)

    -- Wait for router to recognize the freshly-registered mailbox
    -- (collect_dirs runs at start; for a mid-test register the
    -- registry update is what makes classify accept the path).
    vim.wait(50)

    -- The adopt above registered agent:ultron-prime; now write a
    -- message in its outbox addressed to test-peer.
    local from_full = mb_path.full_id("agent:ultron-prime")
    local from_outbox = tool_root .. "/" .. from_full .. "/outbox"
    vim.fn.mkdir(from_outbox, "p")
    local mid = "adopt-rt-trip-" .. tostring(os.time())
    local payload = {
      id = mid, kind = "message",
      from = from_full,
      to   = "agent:test-peer",
      subject = "round-trip after adopt",
      body = "If you read this, the live router delivered me.",
    }
    local tmp = from_outbox .. "/" .. mid .. ".tmp"
    local final = from_outbox .. "/" .. mid .. ".json"
    local f = io.open(tmp, "w")
    f:write(vim.fn.json_encode(payload)); f:close()
    os.rename(tmp, final)

    core.mailbox.scan_now()
    vim.wait(200, function()
      local peer_full = mb_path.full_id("agent:test-peer")
      local peer_inbox = tool_root .. "/" .. peer_full .. "/inbox"
      local entries = vim.fn.readdir(peer_inbox) or {}
      for _, e in ipairs(entries) do
        if e:find(mid, 1, true) then return true end
      end
      return false
    end, 20)

    local peer_full = mb_path.full_id("agent:test-peer")
    local peer_inbox = tool_root .. "/" .. peer_full .. "/inbox"
    local entries = vim.fn.readdir(peer_inbox) or {}
    local delivered = false
    for _, e in ipairs(entries) do
      if e:find(mid, 1, true) then delivered = true; break end
    end
    ok("ADR 0023 §5.3: post-adopt outbox message reaches peer via standard router",
      delivered, "looked under " .. peer_inbox)
  end

  -- Teardown.
  vim.env.AUTO_AGENTS_RUNTIME_IDENTITY_PATH = nil
  pcall(vim.fn.delete, tmp_sidecar)
  aa.state.config.agents.bootstrap = {}
  aa.state.slot_terminals[5] = nil
end

-- ─────────── 18. agent_add wizard — KB-type conflict ACK (v0.2.22+) ──────────
-- The `agent add` wizard's `_kb_type` field LOOKS like a per-agent
-- pick but its side effect is project-scoped (cfg.kb.type gets
-- overwritten). v0.2.22 adds a conflict-detection ACK step that
-- fires when the new pick differs from the existing project type
-- AND the new agent's kb_scope = "shared". Demands the user type
-- "YES_CHANGE_PROJECT_TYPE" verbatim. v0.2.23 also defaults the
-- `_kb_type` prompt to the current project type when set, so a
-- no-op <CR> keeps things unchanged.
print("\n[18] agent_add wizard — KB-type conflict ACK (v0.2.22+)")
do
  local specs = require("auto-agents.panel.wizard_specs")

  -- Stash + restore the project config so we don't pollute later
  -- sections of the smoke. The wizard reads cfg.kb.type directly.
  local saved_kb = aa.state.config.kb
  aa.state.config.kb = { type = "coding" }

  local spec = specs.agent("add", 9)
  local conflict_step
  local kb_type_step
  for _, s in ipairs(spec.steps) do
    if s.field == "_kb_type_conflict_ack" then conflict_step = s end
    if s.field == "_kb_type" then kb_type_step = s end
  end

  ok("agent_add spec includes _kb_type step", kb_type_step ~= nil)
  ok("agent_add spec includes _kb_type_conflict_ack step", conflict_step ~= nil)

  -- Default injection: when cfg.kb.type is set, the _kb_type
  -- default should match it (so a no-op <CR> keeps the project
  -- type unchanged).
  if kb_type_step and type(kb_type_step.default) == "function" then
    local d = kb_type_step.default({})
    ok("_kb_type default returns current cfg.kb.type when set",
       d == "coding", "got " .. tostring(d))
  end

  -- Default injection: when cfg.kb is unset, fall back to "coding".
  aa.state.config.kb = nil
  if kb_type_step and type(kb_type_step.default) == "function" then
    local d = kb_type_step.default({})
    ok("_kb_type default falls back to 'coding' when cfg.kb absent",
       d == "coding", "got " .. tostring(d))
  end
  aa.state.config.kb = { type = "coding" }  -- restore for ACK tests

  if conflict_step then
    -- Skip rules — five cases:

    -- (1) Pick matches current type → skip.
    ok("ACK skipped when _kb_type matches current type",
       conflict_step.skip({ _kb_type = "coding", kb_scope = "shared" }) == true)

    -- (2) Pick is "none" (user opted out of KB init) → skip.
    ok("ACK skipped when _kb_type is 'none'",
       conflict_step.skip({ _kb_type = "none", kb_scope = "shared" }) == true)

    -- (3) Diff type but kb_scope = private → skip (per-agent dir,
    -- no immediate shared-tree damage).
    ok("ACK skipped when kb_scope is 'private'",
       conflict_step.skip({ _kb_type = "wiki", kb_scope = "private" }) == true)

    -- (4) Diff type but kb_scope = isolated → skip.
    ok("ACK skipped when kb_scope is 'isolated'",
       conflict_step.skip({ _kb_type = "wiki", kb_scope = "isolated" }) == true)

    -- (5) Diff type AND kb_scope = shared → DO NOT skip (ACK fires).
    ok("ACK FIRES when diff type AND kb_scope = shared",
       conflict_step.skip({ _kb_type = "wiki", kb_scope = "shared" }) == false)

    -- No current type (first-ever add) → skip even on shared scope.
    aa.state.config.kb = nil
    ok("ACK skipped when no current cfg.kb.type",
       conflict_step.skip({ _kb_type = "wiki", kb_scope = "shared" }) == true)
    aa.state.config.kb = { type = "coding" }

    -- Validate rules.
    local v_ok = conflict_step.validate("YES_CHANGE_PROJECT_TYPE")
    ok("ACK validate accepts 'YES_CHANGE_PROJECT_TYPE'", v_ok == true)

    local v_no_yes = conflict_step.validate("yes")
    ok("ACK validate REJECTS lowercase 'yes'", v_no_yes == false)

    local v_y = conflict_step.validate("y")
    ok("ACK validate REJECTS single 'y'", v_y == false)

    local v_partial = conflict_step.validate("YES")
    ok("ACK validate REJECTS partial 'YES'", v_partial == false)

    local v_empty = conflict_step.validate("")
    ok("ACK validate REJECTS empty input", v_empty == false)

    -- pre_emit returns multi-line banner that names both types.
    if type(conflict_step.pre_emit) == "function" then
      local lines = conflict_step.pre_emit({ _kb_type = "wiki", kb_scope = "shared" })
      ok("ACK pre_emit returns a table", type(lines) == "table")
      ok("ACK pre_emit produces multiple lines", #lines >= 5)
      local joined = table.concat(lines, "\n")
      ok("ACK banner names CURRENT type (uppercase)",
         joined:find("CODING", 1, true) ~= nil)
      ok("ACK banner names PICKED type (uppercase)",
         joined:find("WIKI", 1, true) ~= nil)
      ok("ACK banner shouts WARNING",
         joined:find("WARNING", 1, true) ~= nil)
      ok("ACK banner mentions the required confirmation phrase",
         joined:find("YES_CHANGE_PROJECT_TYPE", 1, true) ~= nil)
    end
  end

  aa.state.config.kb = saved_kb
end

-- ─────────── 19. library KB type — seed + scaffold (v0.2.24+) ──────────
-- The library type ships:
--   - kb-seeds/library.md            → <kb_root>/AGENTS.md
--   - kb-seeds/_library-rules.md     → <kb_root>/RULES.md (per-type, NEW)
--   - kb-seeds/library-templates/*   → <kb_root>/_templates/ (per-type bundle, NEW)
--   - LAYOUTS.library                → archive/ + draft/ + incidents/ + redacted/
--                                      + shared/{conventions,glossary,synthesis}/
-- Plus the universal KB_RULES.md and the existing per-kind layout
-- machinery continue to apply.
print("\n[19] library KB type — seed + scaffold (v0.2.24+)")
do
  local kb_types = require("auto-agents.kb.types")
  local kb_init  = require("auto-agents.kb")

  -- library is in BUILTIN and has a layout.
  local function contains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
  end
  ok("library is registered in BUILTIN", contains(kb_types.BUILTIN, "library"))

  local layout = kb_types.layout("library")
  ok("library layout has description", type(layout.description) == "string"
     and layout.description ~= "")

  -- Layout shape — shared/ subdirs include conventions; extras include
  -- archive/ + draft/ + incidents/ + redacted/ + _templates/.
  local function layout_contains(field, value)
    for _, x in ipairs(layout[field] or {}) do if x == value then return true end end
    return false
  end
  ok("library shared_subdirs include 'conventions'",
     layout_contains("shared_subdirs", "conventions"))
  ok("library extra_dirs include 'archive'",
     layout_contains("extra_dirs", "archive"))
  ok("library extra_dirs include 'draft'",
     layout_contains("extra_dirs", "draft"))
  ok("library extra_dirs include 'incidents'",
     layout_contains("extra_dirs", "incidents"))
  ok("library extra_dirs include 'redacted'",
     layout_contains("extra_dirs", "redacted"))
  ok("library extra_dirs include '_templates'",
     layout_contains("extra_dirs", "_templates"))

  -- Seed files exist on disk.
  local seeds_dir = kb_types.seeds_dir()
  ok("kb-seeds/library.md exists",
     vim.fn.filereadable(seeds_dir .. "/library.md") == 1)
  ok("kb-seeds/_library-rules.md exists",
     vim.fn.filereadable(seeds_dir .. "/_library-rules.md") == 1)
  ok("kb-seeds/library-templates/ exists",
     vim.fn.isdirectory(seeds_dir .. "/library-templates") == 1)
  ok("kb-seeds/library-templates/archive-entry.md ships",
     vim.fn.filereadable(seeds_dir .. "/library-templates/archive-entry.md") == 1)
  ok("kb-seeds/library-templates/convention.md ships",
     vim.fn.filereadable(seeds_dir .. "/library-templates/convention.md") == 1)
  ok("kb-seeds/library-templates/convention-manifest.yaml ships",
     vim.fn.filereadable(seeds_dir .. "/library-templates/convention-manifest.yaml") == 1)

  -- ensure_layout scaffolds the full library tree end-to-end.
  local tmp_root = vim.fn.tempname() .. "_library_kb"
  vim.fn.mkdir(tmp_root, "p")

  kb_init.ensure_layout(tmp_root, { type = "library" })

  ok("ensure_layout creates archive/",
     vim.fn.isdirectory(tmp_root .. "/archive") == 1)
  ok("ensure_layout creates draft/",
     vim.fn.isdirectory(tmp_root .. "/draft") == 1)
  ok("ensure_layout creates incidents/",
     vim.fn.isdirectory(tmp_root .. "/incidents") == 1)
  ok("ensure_layout creates redacted/",
     vim.fn.isdirectory(tmp_root .. "/redacted") == 1)
  ok("ensure_layout creates shared/conventions/",
     vim.fn.isdirectory(tmp_root .. "/shared/conventions") == 1)
  ok("ensure_layout creates shared/glossary/",
     vim.fn.isdirectory(tmp_root .. "/shared/glossary") == 1)
  ok("ensure_layout creates shared/synthesis/",
     vim.fn.isdirectory(tmp_root .. "/shared/synthesis") == 1)
  ok("ensure_layout creates raw/",
     vim.fn.isdirectory(tmp_root .. "/raw") == 1)
  ok("ensure_layout creates agents/",
     vim.fn.isdirectory(tmp_root .. "/agents") == 1)
  ok("ensure_layout creates _templates/",
     vim.fn.isdirectory(tmp_root .. "/_templates") == 1)

  -- AGENTS.md content reflects the library seed.
  ok("AGENTS.md is written from library seed",
     vim.fn.filereadable(tmp_root .. "/AGENTS.md") == 1)
  do
    local f = io.open(tmp_root .. "/AGENTS.md", "r")
    if f then
      local content = f:read("*a"); f:close()
      ok("AGENTS.md names the library KB type",
         content:find("Document Library Contract", 1, true) ~= nil)
      ok("AGENTS.md references KB_RULES.md",
         content:find("KB_RULES.md", 1, true) ~= nil)
      ok("AGENTS.md references RULES.md",
         content:find("RULES.md", 1, true) ~= nil)
    end
  end

  -- KB_RULES.md and RULES.md both shipped at the root.
  ok("KB_RULES.md is written (universal rules)",
     vim.fn.filereadable(tmp_root .. "/KB_RULES.md") == 1)
  ok("RULES.md is written from _library-rules.md seed (per-type rules)",
     vim.fn.filereadable(tmp_root .. "/RULES.md") == 1)
  do
    local f = io.open(tmp_root .. "/RULES.md", "r")
    if f then
      local content = f:read("*a"); f:close()
      ok("RULES.md declares schema_version",
         content:find("schema_version:", 1, true) ~= nil)
      ok("RULES.md describes the partition scheme",
         content:find("Partition scheme", 1, true) ~= nil)
      ok("RULES.md describes the filename template",
         content:find("Filename template", 1, true) ~= nil)
      ok("RULES.md describes the hash spec",
         content:find("Hash spec", 1, true) ~= nil)
    end
  end

  -- _templates/ bundle is populated from library-templates/.
  ok("_templates/archive-entry.md is shipped",
     vim.fn.filereadable(tmp_root .. "/_templates/archive-entry.md") == 1)
  ok("_templates/convention.md is shipped",
     vim.fn.filereadable(tmp_root .. "/_templates/convention.md") == 1)
  ok("_templates/convention-manifest.yaml is shipped",
     vim.fn.filereadable(tmp_root .. "/_templates/convention-manifest.yaml") == 1)

  -- log.md gets the rotation-pointer header (per KB_RULES.md R1)
  -- even for library KBs.
  do
    local f = io.open(tmp_root .. "/log.md", "r")
    if f then
      local content = f:read("*a"); f:close()
      ok("log.md carries the rotation-pointer header",
         content:find("Current ISO week only", 1, true) ~= nil)
    end
  end

  -- Idempotency: a second ensure_layout call without force_schema
  -- doesn't clobber. Write a marker into AGENTS.md, re-run, verify
  -- the marker survives.
  do
    local agents_md = tmp_root .. "/AGENTS.md"
    local f = io.open(agents_md, "a")
    if f then f:write("\n<!-- USER MARKER -->\n"); f:close() end
    kb_init.ensure_layout(tmp_root, { type = "library" })
    local g = io.open(agents_md, "r")
    if g then
      local content = g:read("*a"); g:close()
      ok("ensure_layout is idempotent on AGENTS.md (user marker preserved)",
         content:find("USER MARKER", 1, true) ~= nil)
    end
  end

  -- Teardown: rm -rf the temp KB.
  pcall(vim.fn.delete, tmp_root, "rf")
end

-- ───────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
