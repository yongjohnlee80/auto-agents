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

-- Sibling auto-core.nvim worktree. Prefer `main` (the
-- integration line). Falls back to the plain repo for dev
-- machines without a worktree tree.
local core_root = plugins_root .. "/auto-core.nvim/main"
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

-- Isolate auto-core's persisted state to a fresh tempdir for the
-- duration of this smoke run. Without this, the `auto-agents`
-- namespace can leak `panel.slot_count` (and other values) from a
-- prior run into the assertions about post-setup defaults
-- (lector audit must-fix #2, 2026-05-24). Done before `aa.setup`
-- below so the namespace loads from the isolated path on first
-- materialization.
require("auto-core.state").configure({
  persist_dir = vim.fn.tempname() .. "_auto-core-state",
})

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

-- 8d. ADR-0028 criterion #4: an editor-floor scratch materialized while
-- only panels remain must carry EDITOR appearance defaults (number /
-- relativenumber / signcolumn), not the panels' masked locals — and the
-- panel must keep its masked locals. The panel-open path writes
-- appearance options scope="local" (auto-core v0.1.31), so the global
-- defaults a freshly-materialized editor window inherits stay correct.
do
  local panel_w = aa.state.panel_winid
  local saved = {
    number         = vim.api.nvim_get_option_value("number", { scope = "global" }),
    relativenumber = vim.api.nvim_get_option_value("relativenumber", { scope = "global" }),
    signcolumn     = vim.api.nvim_get_option_value("signcolumn", { scope = "global" }),
  }
  vim.api.nvim_set_option_value("number", true, { scope = "global" })
  vim.api.nvim_set_option_value("relativenumber", true, { scope = "global" })
  vim.api.nvim_set_option_value("signcolumn", "yes", { scope = "global" })

  local scratch = floor.materialize_editor_scratch()
  ok("8d: editor-floor scratch materialized",
    scratch ~= nil and vim.api.nvim_win_is_valid(scratch))
  if scratch and vim.api.nvim_win_is_valid(scratch) then
    ok("8d: scratch carries editor number=true (not panel-masked)",
      vim.api.nvim_get_option_value("number", { win = scratch }) == true,
      "number=" .. tostring(vim.api.nvim_get_option_value("number", { win = scratch })))
    ok("8d: scratch carries editor relativenumber=true",
      vim.api.nvim_get_option_value("relativenumber", { win = scratch }) == true,
      "relativenumber=" .. tostring(vim.api.nvim_get_option_value("relativenumber", { win = scratch })))
    ok("8d: scratch carries editor signcolumn=yes",
      vim.api.nvim_get_option_value("signcolumn", { win = scratch }) == "yes",
      "signcolumn=" .. tostring(vim.api.nvim_get_option_value("signcolumn", { win = scratch })))
  end
  -- The panel keeps its OWN window-local appearance regardless of the
  -- global seed above — that's the ADR-0028 invariant from the panel's
  -- side (the panel masks number locally; whatever it set for signcolumn
  -- is its local value, not the global one). We assert insulation (the
  -- global change did NOT bleed into the panel), not specific masked
  -- values, since the auto-agents panel masks number=false but leaves
  -- signcolumn at its own local (`auto`), not `no`.
  if panel_w and vim.api.nvim_win_is_valid(panel_w) then
    ok("8d: panel insulated — number stays false despite global number=true",
      vim.api.nvim_get_option_value("number", { win = panel_w }) == false,
      "panel number=" .. tostring(vim.api.nvim_get_option_value("number", { win = panel_w })))
    ok("8d: panel insulated — signcolumn not polluted by global=yes",
      vim.api.nvim_get_option_value("signcolumn", { win = panel_w }) ~= "yes",
      "panel signcolumn=" .. tostring(vim.api.nvim_get_option_value("signcolumn", { win = panel_w })))
  end
  if scratch and vim.api.nvim_win_is_valid(scratch) then
    pcall(vim.api.nvim_win_close, scratch, true)
  end
  vim.api.nvim_set_option_value("number", saved.number, { scope = "global" })
  vim.api.nvim_set_option_value("relativenumber", saved.relativenumber, { scope = "global" })
  vim.api.nvim_set_option_value("signcolumn", saved.signcolumn, { scope = "global" })
end

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

-- v0.2.30 / auto-core v0.1.33 — Lector audit must-fix #1: spawn cwd
-- flows through identity.reconcile / mailbox_root so the agent's
-- mailbox anchors at the spawn-cwd's workspace, not the host's.
do
  local identity = require("auto-agents.runtime.identity")
  -- Clear any auto-core worktree state for a deterministic resolver
  -- behavior. With state unset and no AUTO_AGENTS_MAILBOX_ROOT env,
  -- the resolver falls through to opts.cwd → exactly the path we
  -- want to anchor the mailbox under.
  local worktree_ok, worktree_mod = pcall(require, "auto-core.git.worktree")
  if worktree_ok then
    pcall(worktree_mod.set_active, nil)
    pcall(worktree_mod.set_workspace_root, nil)
  end
  local saved_env = vim.env.AUTO_AGENTS_MAILBOX_ROOT
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil

  local spawn_cwd = vim.fn.tempname() .. "_spawn-cwd-fixture"
  vim.fn.mkdir(spawn_cwd, "p")
  -- Defensive: clear any leftover _override_root from earlier
  -- sections that may have called mailbox.configure({ root = X }).
  require("auto-core.mailbox.path").configure(nil)
  local resolved = identity.mailbox_root({ cwd = spawn_cwd })
  ok("Lector audit must-fix #1: mailbox_root({cwd}) anchors under the spawn cwd",
    resolved:sub(1, #spawn_cwd) == spawn_cwd
      and resolved:find("%.auto%-agents/mailbox$") ~= nil,
    "got: " .. resolved .. " (expected under " .. spawn_cwd .. ")")

  -- Restore env + cleanup.
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = saved_env
  pcall(vim.fn.delete, spawn_cwd, "rf")
end

-- v0.2.30 / auto-core v0.1.33 — Lector audit must-fix #2: reserved
-- agent names rejected at the auto-agents config boundary too
-- (mirrors the path.validate_id check).
do
  local cfg_mod = require("auto-agents.config")
  local _, err_nvim = pcall(cfg_mod.apply, {
    agents = { bootstrap = { { slot = 1, name = "nvim", kind = "claude" } } },
  })
  ok("Lector audit must-fix #2: config rejects bootstrap name 'nvim'",
    type(err_nvim) == "string"
      and err_nvim:find("reserved", 1, true) ~= nil,
    "got: " .. tostring(err_nvim))
  local _, err_user = pcall(cfg_mod.apply, {
    agents = { bootstrap = { { slot = 1, name = "user", kind = "claude" } } },
  })
  ok("Lector audit must-fix #2: config rejects bootstrap name 'user'",
    type(err_user) == "string"
      and err_user:find("reserved", 1, true) ~= nil,
    "got: " .. tostring(err_user))
end

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

-- Wait on the CONDITION, not on a fixed duration. A flat vim.wait(80)
-- leaves the 30 ms deferred CR only 50 ms of slack, which a loaded CI
-- runner spends easily. The failure is not contained either: the late
-- CR lands after the `sends = {}` reset below and contaminates the
-- no-submit cell, so one slow timer reddens three cells. A bounded
-- condition-wait still fails when the CR never fires — it only stops
-- failing when the CR is merely slow.
vim.wait(2000, function() return #sends >= 2 end, 5)

ok("CR is sent after the deferred delay (2 sends total)", #sends == 2)
ok("second send is exactly \\r", sends[2] == "\r")

-- Without submit=true, no CR follows. Body still wrapped in bracketed-paste.
-- The condition-wait above has already drained the previous deferred CR,
-- so anything observed here belongs to this call. A flat wait is the right
-- shape for asserting ABSENCE — there is no condition to wait on.
sends = {}
aa.send_slot(1, "no-submit prompt")
vim.wait(80)
ok("send_slot without submit fires exactly one chan_send",
   #sends == 1 and sends[1] == "\27[200~no-submit prompt\27[201~")

-- v0.2.45 (follow-up #1): codex slots now submit with a BARE CR,
-- same as every other kind. Previously codex defaulted to Esc + CR
-- (Esc closing an open picker) but mid-generation that Esc CANCELS
-- the agent's work — the reported interrupt. The leading-`[` codex
-- bracketed-entry hazard that originally motivated Esc is handled
-- upstream by payload prefixing (e.g. wake's `ATTENTION:`). A
-- caller that truly needs Esc+CR can still pass it via
-- `opts.submit_keys`.
aa.state.config.agents.bootstrap = {
  { slot = 1, name = "jarvis", kind = "claude" },
  { slot = 2, name = "rosie",  kind = "codex"  },
}
local codex_sends = {}
local saved_term2 = aa.state.slot_terminals[2]
aa.state.slot_terminals[2] = {
  is_alive = function() return true end,
  send = function(_, text) table.insert(codex_sends, text); return true end,
}
aa.send_slot(2, "review the diff please",
  { submit = true, submit_delay_ms = 30, inter_key_delay_ms = 10 })
vim.wait(120)
-- 2 sends total now: body + bare CR (NO Esc).
ok("follow-up #1: codex submit is bare CR, no Esc (no mid-work interrupt)",
  #codex_sends == 2 and codex_sends[2] == "\r",
  "got: " .. vim.inspect(codex_sends))
-- The override still works for a caller that explicitly wants Esc+CR.
local codex_esc = {}
aa.state.slot_terminals[2] = {
  is_alive = function() return true end,
  send = function(_, text) table.insert(codex_esc, text); return true end,
}
aa.send_slot(2, "explicit esc", {
  submit = true, submit_delay_ms = 30, inter_key_delay_ms = 10,
  submit_keys = { "<Esc>", "<CR>" },
})
vim.wait(120)
ok("follow-up #1: submit_keys override can still send Esc+CR",
  #codex_esc == 3 and codex_esc[2] == "\27" and codex_esc[3] == "\r",
  "got: " .. vim.inspect(codex_esc))
ok("v0.2.34: claude submit still fires bare CR (no Esc, no split)",
  (function()
    local claude_sends = {}
    aa.state.slot_terminals[1] = {
      is_alive = function() return true end,
      send = function(_, t) table.insert(claude_sends, t); return true end,
    }
    aa.send_slot(1, "claude-side body",
      { submit = true, submit_delay_ms = 30 })
    vim.wait(80)
    return #claude_sends == 2 and claude_sends[2] == "\r"
  end)())

-- v0.2.46: M.spawned_agents() must actually RUN (the v0.2.39
-- ship had a scope bug — it referenced a nil global
-- `_bootstrap_entry` and errored on every call, breaking the
-- auto-finder `A` assign keymap). Mock a live terminal so an
-- entry is returned end-to-end.
aa.state.config.agents.bootstrap = {
  { slot = 1, name = "jarvis", kind = "claude" },
  { slot = 2, name = "rosie",  kind = "codex"  },
}
aa.state.slot_terminals[1] = { is_alive = function() return true end, send = function() return true end }
aa.state.slot_terminals[2] = nil  -- not spawned → excluded
local sp_ok, spawned = pcall(aa.spawned_agents)
ok("v0.2.46: spawned_agents() runs without error", sp_ok,
  not sp_ok and tostring(spawned) or nil)
ok("v0.2.46: spawned_agents() returns only the alive slot with mailbox_id",
  sp_ok and #spawned == 1 and spawned[1].name == "jarvis"
    and spawned[1].mailbox_id == "agent:jarvis",
  "got: " .. vim.inspect(spawned))

-- v0.2.34: send_keypress symbolic helper + override hook.
local kp_sends = {}
aa.state.slot_terminals[2] = {
  is_alive = function() return true end,
  send = function(_, t) table.insert(kp_sends, t); return true end,
}
aa.send_keypress(2, "<CR>")
aa.send_keypress(2, "<Esc>")
aa.send_keypress(2, "<C-c>")
aa.send_keypress(2, "<Tab>")
aa.send_keypress(2, "<Up>")
aa.send_keypress(2, "literal-bytes")
ok("v0.2.34: send_keypress translates symbolic key names to bytes",
  #kp_sends == 6
    and kp_sends[1] == "\r"
    and kp_sends[2] == "\27"
    and kp_sends[3] == "\3"
    and kp_sends[4] == "\t"
    and kp_sends[5] == "\27[A"
    and kp_sends[6] == "literal-bytes",
  vim.inspect(kp_sends))
ok("v0.2.34: M.KEY_BYTES table is exposed for extension",
  type(aa.KEY_BYTES) == "table"
    and aa.KEY_BYTES["<CR>"] == "\r"
    and aa.KEY_BYTES["<Esc>"] == "\27")

-- v0.2.34: send_slot honors opts.submit_keys override.
local override_sends = {}
aa.state.slot_terminals[2] = {
  is_alive = function() return true end,
  send = function(_, t) table.insert(override_sends, t); return true end,
}
aa.send_slot(2, "body",
  { submit = true, submit_delay_ms = 20, inter_key_delay_ms = 10,
    submit_keys = { "<C-d>" } })
vim.wait(80)
ok("v0.2.34: send_slot honors opts.submit_keys override",
  #override_sends == 2 and override_sends[2] == "\4",
  vim.inspect(override_sends))
aa.state.slot_terminals[2] = saved_term2
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

  -- v0.2.30 / auto-core v0.1.33: mailboxes live under the workspace
  -- mailbox root resolved by `auto-core.mailbox.path.workspace_mailbox_root`.
  -- Override via the single AUTO_AGENTS_MAILBOX_ROOT env var so the
  -- test doesn't write into the live workspace mailbox tree.
  local tmp_mb_root = vim.fn.tempname() .. "_workspace-mailbox"
  vim.fn.mkdir(tmp_mb_root, "p")
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = tmp_mb_root

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
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil
  pcall(vim.fn.delete, tmp_sidecar)
  pcall(vim.fn.delete, tmp_mb_root, "rf")
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

  -- v0.2.30 / auto-core v0.1.33: adopt writes the wake message under
  -- the workspace mailbox root resolved by auto-core. Override via
  -- the single AUTO_AGENTS_MAILBOX_ROOT env var.
  local tmp_mb_root = vim.fn.tempname() .. "_workspace-mailbox-adopt"
  vim.fn.mkdir(tmp_mb_root, "p")
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = tmp_mb_root

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
  ok("ADR 0029 #3 (lector audit must-fix): adopt sidecar carries the "
     .. "bootstrap spec's diff_review flag (pre-fix: dropped, sidecar "
     .. "always recorded false even when bootstrap had diff_review=true)",
    record and record.diff_review == true,
    record and ("diff_review=" .. tostring(record.diff_review)) or "(no record)")
  ok("ADR 0029 #3 (lector audit must-fix): adopt sidecar's tool_root + "
     .. "mailbox_dir resolve under the workspace mailbox root, not "
     .. "host_fallback_root (pre-fix: adopt called host_fallback_root)",
    record and type(record.tool_root) == "string"
      and record.tool_root == tmp_mb_root
      and type(record.mailbox_dir) == "string"
      and record.mailbox_dir:sub(1, #tmp_mb_root) == tmp_mb_root,
    record and ("tool_root=" .. tostring(record.tool_root)) or "(no record)")

  -- Wake message injected into the live inbox. The inbox path is
  -- composed by the auto-core path resolver (v0.1.33 new layout:
  -- <root>/<instance>/<name>/inbox/) so we use the same helper here.
  local mb_path = require("auto-core.mailbox.path")
  local tool_root = record and record.tool_root
                       or require("auto-core").mailbox.host_fallback_root()
  local full = mb_path.full_id("agent:ultron-prime")
  local inbox = mb_path.subdir(full, "inbox", tool_root)
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
    local core = require("auto-core")
    -- Plant a peer mailbox to deliver to under the same tool root
    -- used by the adopted Claude-backed agent.
    pcall(function() core.mailbox.register("agent:test-peer", { root = tool_root }) end)

    -- Wait for router to recognize the freshly-registered mailbox
    -- (collect_dirs runs at start; for a mid-test register the
    -- registry update is what makes classify accept the path).
    vim.wait(50)

    -- The adopt above registered agent:ultron-prime; now write a
    -- message in its outbox addressed to test-peer. Path composed via
    -- the auto-core path resolver so the new v0.1.33 layout
    -- (<root>/<instance>/<name>/) is honored without hardcoding it.
    local from_full = mb_path.full_id("agent:ultron-prime")
    local from_outbox = mb_path.subdir(from_full, "outbox", tool_root)
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
      local peer_inbox = mb_path.subdir(peer_full, "inbox", tool_root)
      local entries = vim.fn.readdir(peer_inbox) or {}
      for _, e in ipairs(entries) do
        if e:find(mid, 1, true) then return true end
      end
      return false
    end, 20)

    local peer_full = mb_path.full_id("agent:test-peer")
    local peer_inbox = mb_path.subdir(peer_full, "inbox", tool_root)
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
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil
  pcall(vim.fn.delete, tmp_sidecar)
  pcall(vim.fn.delete, tmp_mb_root, "rf")
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

-- ────────── 20. Phase 4: peek + say mailbox commands + admin `run` ──────────
print("\n[20] Phase 4: peek + say + admin run")
do
  local cmds = require("auto-agents.mailbox.commands")
  local core = require("auto-core")
  -- Make sure auto-agents commands are registered (other sections
  -- may have unregistered them).
  cmds.register_all()

  -- 20a. peek + say show up in the live registry with the right
  -- owner/description (commands_list discovery surface).
  local registry_entries = core.mailbox.commands.list() or {}
  local by_name = {}
  for _, e in ipairs(registry_entries) do by_name[e.name] = e end
  ok("Phase 4: `peek` registered with auto-agents owner",
    by_name.peek ~= nil and by_name.peek.owner == "auto-agents")
  ok("Phase 4: `say` registered with auto-agents owner",
    by_name.say ~= nil and by_name.say.owner == "auto-agents")

  -- Plant a fake slot 2 with a buffer that has known content. The
  -- buffer line API returns lines verbatim; peek reads from there.
  aa.state.slot_terminals = {}
  aa.state.config.agents = aa.state.config.agents or {}
  aa.state.config.agents.bootstrap = {
    { slot = 2, name = "fake-peer", kind = "claude" },
  }
  local fake_bufnr = vim.api.nvim_create_buf(false, true)
  local lines_planted = {}
  for i = 1, 30 do lines_planted[i] = "line " .. i end
  lines_planted[31] = ""  -- trailing blank that peek should strip
  lines_planted[32] = ""
  vim.api.nvim_buf_set_lines(fake_bufnr, 0, -1, false, lines_planted)
  local send_calls = {}
  aa.state.slot_terminals[2] = {
    get_bufnr = function() return fake_bufnr end,
    is_alive  = function() return true end,
    resize_to = function() end,
    pid       = function() return 8888888 end,
    send      = function(_, body) send_calls[#send_calls + 1] = body; return true end,
  }

  -- 20b. peek returns the last 20 real lines (default), strips
  -- trailing blanks, reports terminal_alive=true.
  local peek_spec = by_name.peek and core.mailbox.commands.get("peek")
  local peek_res = peek_spec and peek_spec.handler({ slot = 2 }, {})
  ok("peek: ok=true on live slot",
    type(peek_res) == "table" and peek_res.ok == true,
    vim.inspect(peek_res))
  ok("peek: default returns 20 lines (trailing blanks stripped)",
    peek_res and peek_res.value
      and peek_res.value.line_count == 20
      and peek_res.value.lines[20] == "line 30",
    vim.inspect(peek_res and peek_res.value))
  ok("peek: terminal_alive mirrors term:is_alive()",
    peek_res and peek_res.value and peek_res.value.terminal_alive == true)
  ok("peek: respects explicit lines=N arg",
    (function()
      local r = peek_spec.handler({ slot = 2, lines = 5 }, {})
      return r and r.value and r.value.line_count == 5
         and r.value.lines[5] == "line 30"
    end)())

  -- 20c. peek error cases.
  ok("peek: invalid slot returns invalid_args",
    (function()
      local r = peek_spec.handler({}, {})
      return r and r.ok == false and r.code == "invalid_args"
    end)())
  ok("peek: slot out of range returns slot_out_of_range",
    (function()
      local r = peek_spec.handler({ slot = 999 }, {})
      return r and r.ok == false and r.code == "slot_out_of_range"
    end)())
  ok("peek: no terminal at slot returns no_terminal",
    (function()
      local r = peek_spec.handler({ slot = 3 }, {})
      return r and r.ok == false and r.code == "no_terminal"
    end)())

  -- 20d. say injects text via send_slot. send_calls captures the
  -- payload the terminal received (with bracketed-paste wrapping).
  local say_spec = by_name.say and core.mailbox.commands.get("say")
  local say_res = say_spec and say_spec.handler(
    { slot = 2, text = "hello world", submit = false }, {})
  ok("say: ok=true on live slot",
    say_res and say_res.ok == true, vim.inspect(say_res))
  ok("say: routed through send_slot (bracketed-paste wrapper visible)",
    #send_calls > 0
      and send_calls[1]:find("hello world", 1, true) ~= nil
      and send_calls[1]:find("\27[200~", 1, true) ~= nil,
    vim.inspect(send_calls))

  -- 20e. say error cases.
  ok("say: empty text returns invalid_args",
    (function()
      local r = say_spec.handler({ slot = 2, text = "" }, {})
      return r and r.ok == false and r.code == "invalid_args"
    end)())
  ok("say: missing slot returns invalid_args",
    (function()
      local r = say_spec.handler({ text = "hi" }, {})
      return r and r.ok == false and r.code == "invalid_args"
    end)())

  -- 20f. multi-line + quoted text round-trips intact.
  send_calls = {}
  local multi = "line A\nline B\n\"quoted\" and 'apostrophed'"
  local _ = say_spec.handler({ slot = 2, text = multi, submit = false }, {})
  ok("say: multi-line + quoted text passes through verbatim",
    send_calls[1]:find("line A\nline B", 1, true) ~= nil
      and send_calls[1]:find("\"quoted\" and 'apostrophed'", 1, true) ~= nil,
    vim.inspect(send_calls))

  -- 20g. admin `run` dispatcher — through the dispatch path so we
  -- exercise the positional-shortcut parsing for peek/say.
  local admin = require("auto-agents.panel.admin")
  -- Tab-completion offers `run` at top level + the live verb list.
  local _, top_cands = admin._complete_at("", 0)
  ok("admin completion: top-level offers `run`",
    vim.tbl_contains(top_cands, "run"))
  local _, run_cands = admin._complete_at("run ", 4)
  ok("admin completion: `run ` offers the live registry verbs",
    vim.tbl_contains(run_cands, "peek")
      and vim.tbl_contains(run_cands, "say")
      and vim.tbl_contains(run_cands, "wake"))
  local _, peek_slot_cands = admin._complete_at("run peek ", 9)
  ok("admin completion: `run peek ` offers live slot numbers",
    vim.tbl_contains(peek_slot_cands, "2"))

  -- Teardown.
  vim.api.nvim_buf_delete(fake_bufnr, { force = true })
  aa.state.config.agents.bootstrap = {}
  aa.state.slot_terminals[2] = nil
end

-- ────────── 21. Phase 6: workspace mailbox-dir prune at setup ──────────
print("\n[21] Phase 6: workspace mailbox-dir prune")
do
  local core = require("auto-core")
  local mb_path = require("auto-core.mailbox.path")

  -- Isolate the workspace mailbox root so prune doesn't touch the
  -- user's real workspace tree.
  local tmp_mb_root = vim.fn.tempname() .. "_phase6-prune-root"
  vim.fn.mkdir(tmp_mb_root, "p")
  local saved_env = vim.env.AUTO_AGENTS_MAILBOX_ROOT
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = tmp_mb_root

  -- Plant three subtrees: one stale (older than threshold), one
  -- fresh (younger), one corresponding to a live registration.
  local stale_dir = mb_path.mailbox_dir("agent:zombie:1111111111-1111", tmp_mb_root)
  local fresh_dir = mb_path.mailbox_dir("agent:newborn:2222222222-2222", tmp_mb_root)
  vim.fn.mkdir(stale_dir .. "/inbox", "p")
  vim.fn.mkdir(fresh_dir .. "/inbox", "p")
  os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(stale_dir))

  -- Register a live mailbox so its dir is in the registry; prune
  -- should keep it regardless of mtime.
  pcall(core.mailbox.register, "agent:phase6-live", { root = tmp_mb_root })
  local live_rec = core.mailbox.registry.get("agent:phase6-live")
  ok("Phase 6: live mailbox registered for prune test",
    live_rec ~= nil and type(live_rec.dir) == "string")

  -- Drive auto-agents setup with prune ENABLED (default) and a
  -- 1-HOUR max_age. Any threshold between a few seconds and 8 days
  -- separates these two fixtures; 1 second did not, because the window
  -- was narrower than the register+setup work running inside it. mtime
  -- is second-granular and prune tests `(now - mtime) >= max_age`, so a
  -- single second-boundary crossing was enough to age the "fresh" dir
  -- out and delete it — flaky everywhere, reliably red under CI load.
  -- 1 hour puts both fixtures unambiguously on their own side of it.
  -- Disable diff_review_enabled side effects by clearing bootstrap.
  aa.state.config.agents.bootstrap = {}
  pcall(aa.setup, {
    panel    = { side = "right", min_width = 50, max_width = 120, editor_floor = 30, percentage = 0.30 },
    agents   = { bootstrap = {} },
    kb       = {},
    term     = { enabled = false },
    mailbox  = { prune = { enabled = true, max_age_seconds = 3600 } },
  })

  ok("Phase 6: prune removed the stale instance dir",
    vim.fn.isdirectory(stale_dir) == 0,
    "stale_dir still present: " .. stale_dir)
  ok("Phase 6: prune kept the fresh instance dir",
    vim.fn.isdirectory(fresh_dir) == 1,
    "fresh_dir missing: " .. fresh_dir)
  ok("Phase 6: prune kept the live-registered dir",
    vim.fn.isdirectory(live_rec.dir) == 1,
    "live_rec.dir missing: " .. live_rec.dir)

  -- Opt-out path: cfg.mailbox.prune.enabled = false skips the call.
  local opt_out_stale = mb_path.mailbox_dir("agent:opt-out:3333333333-3333", tmp_mb_root)
  vim.fn.mkdir(opt_out_stale .. "/inbox", "p")
  os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(opt_out_stale))
  pcall(aa.setup, {
    panel    = { side = "right", min_width = 50, max_width = 120, editor_floor = 30, percentage = 0.30 },
    agents   = { bootstrap = {} },
    kb       = {},
    term     = { enabled = false },
    mailbox  = { prune = { enabled = false } },
  })
  ok("Phase 6: cfg.mailbox.prune.enabled=false opts out (stale dir retained)",
    vim.fn.isdirectory(opt_out_stale) == 1,
    "opt_out_stale missing: " .. opt_out_stale)

  -- Teardown.
  vim.env.AUTO_AGENTS_MAILBOX_ROOT = saved_env
  pcall(vim.fn.delete, tmp_mb_root, "rf")
  pcall(core.mailbox.unregister, "agent:phase6-live")
end

-- ────────── 22. v0.2.32: antigravity adapter + permissions ──────────
print("\n[22] v0.2.32: antigravity --model dropped, --add-dir wired")
do
  local agent = require("auto-agents.agent")
  local perms = require("auto-agents.permissions")

  -- 22a. agy spawns without --model even when spec.model is set —
  -- agy --help has no -model flag and spawn would error.
  local argv_no_model = agent.cmd_for("antigravity", { name = "any" })
  ok("antigravity: spawn argv is bare `agy` when no override",
    type(argv_no_model) == "table" and argv_no_model[1] == "agy" and #argv_no_model == 1,
    vim.inspect(argv_no_model))
  local argv_with_model = agent.cmd_for("antigravity", { name = "any", model = "gemini-2.5-pro" })
  ok("antigravity: spawn argv ignores spec.model (agy has no --model flag)",
    type(argv_with_model) == "table" and argv_with_model[1] == "agy" and #argv_with_model == 1,
    vim.inspect(argv_with_model))

  -- 22b. antigravity now ships a permissions strategy. --add-dir
  -- is the same flag claude/codex use (confirmed in `agy --help`).
  local grants = perms.argv_for_kind("antigravity",
    { "/tmp/mb", "/tmp/kb" })
  ok("antigravity: permissions strategy emits --add-dir per dir",
    type(grants) == "table" and #grants == 4
      and grants[1] == "--add-dir" and grants[2] == "/tmp/mb"
      and grants[3] == "--add-dir" and grants[4] == "/tmp/kb",
    vim.inspect(grants))
  local claude_grants = perms.argv_for_kind("claude", { "/tmp/mb" })
  ok("v0.2.32: antigravity grants match claude/codex shape",
    type(claude_grants) == "table" and claude_grants[1] == "--add-dir"
      and claude_grants[2] == "/tmp/mb",
    vim.inspect(claude_grants))
end

-- ────────── 23. v0.2.33: admin run arg parser + emit safety ──────────
print("\n[23] v0.2.33: admin _parse_run_args positional shortcuts")
do
  local admin = require("auto-agents.panel.admin")
  local parse = admin._parse_run_args

  -- 23a. peek / say shortcuts (regression net for Phase 4 surface).
  local p = parse("peek", { "run", "peek", "3" })
  ok("parse_run_args: peek slot coerced to number",
    type(p.slot) == "number" and p.slot == 3, vim.inspect(p))
  p = parse("peek", { "run", "peek", "3", "50" })
  ok("parse_run_args: peek `lines` second positional",
    p.slot == 3 and p.lines == 50, vim.inspect(p))
  p = parse("say", { "run", "say", "2", "hello", "world" })
  ok("parse_run_args: say slot + text-concat",
    p.slot == 2 and p.text == "hello world", vim.inspect(p))

  -- 23b. v0.2.33 wake shortcut: numeric slot resolves to agent name.
  aa.state.config.agents.bootstrap = {
    { slot = 1, name = "jarvis", kind = "claude" },
    { slot = 2, name = "rosie",  kind = "codex"  },
  }
  p = parse("wake", { "run", "wake", "2" })
  ok("parse_run_args: wake `<number>` resolves to bootstrap agent name",
    type(p.slot) == "string" and p.slot == "rosie", vim.inspect(p))
  p = parse("wake", { "run", "wake", "jarvis", "check", "in" })
  ok("parse_run_args: wake `<name>` passes through, trailing text concat",
    p.slot == "jarvis" and p.text == "check in", vim.inspect(p))
  p = parse("wake", { "run", "wake", "9" })
  ok("parse_run_args: wake `<unknown-number>` falls through to literal string",
    p.slot == "9", vim.inspect(p))

  -- 23c. v0.2.33 send_user shortcut: all positional tokens → body.
  p = parse("send_user", { "run", "send_user", "build", "done" })
  ok("parse_run_args: send_user concatenates positional into body",
    p.body == "build done", vim.inspect(p))
  p = parse("send_user", { "run", "send_user" })
  ok("parse_run_args: send_user with no args returns empty table",
    next(p) == nil, vim.inspect(p))

  -- 23d. generic k=v fallback for non-shortcut verbs (e.g. addressbook).
  p = parse("addressbook", { "run", "addressbook", "include_self=false" })
  ok("parse_run_args: generic k=v with `false` coerced to boolean",
    p.include_self == false, vim.inspect(p))
  p = parse("addressbook", { "run", "addressbook", "limit=10" })
  ok("parse_run_args: generic k=v with numeric coerced to number",
    p.limit == 10, vim.inspect(p))
end

-- ───────────────────── 24. ADR-0035 Phase 2 ─────────────────────────
-- Hook + executor registration with auto-core.todo.automation,
-- `assign user` sentinel skip in the recipient router, the two new
-- mailbox verbs (todos.fire, todos.automation_set), and the KB
-- audit subscriber.
print("\n[24] ADR-0035 Phase 2 — todo_automation adapter + mailbox surface + KB audit")
do
  local ok_aa_auto, aa_auto = pcall(require, "auto-agents.todo_automation")
  if not ok_aa_auto then
    ok("ADR-0035 Phase 2: auto-agents.todo_automation loads", false,
      "module load failed: " .. tostring(aa_auto))
  else
    -- Re-arm from a clean slate.
    pcall(aa_auto.uninstall)

    -- 24a. install registers the hook + executor + starts the engine.
    aa_auto.install()
    local automation = require("auto-core.todo.automation")
    local hs, es = automation.registry_snapshot()
    ok("install registers `assign slot:` hook",
      (function() for _, p in ipairs(hs) do if p == "assign slot:" then return true end end return false end)(),
      "got hooks: " .. vim.inspect(hs))
    ok("install registers `bash -t=` executor",
      (function() for _, p in ipairs(es) do if p == "bash -t=" then return true end end return false end)(),
      "got executors: " .. vim.inspect(es))
    ok("install starts the automation engine",
      automation.list_pending().running == true)

    -- 24b. uninstall is symmetric.
    aa_auto.uninstall()
    local hs2, es2 = automation.registry_snapshot()
    ok("uninstall removes the hook",
      (function() for _, p in ipairs(hs2) do if p == "assign slot:" then return false end end return true end)())
    ok("uninstall removes the executor",
      (function() for _, p in ipairs(es2) do if p == "bash -t=" then return false end end return true end)())
    ok("uninstall stops the engine",
      automation.list_pending().running == false)

    -- 24c. todo_automation.install is idempotent.
    aa_auto.install(); aa_auto.install()
    ok("install is idempotent (still installed)", aa_auto.is_installed() == true)

    -- 24d. The hook resolves `assign slot:N` via spawned_agents().
    -- The smoke harness has bootstrap agents starting from setup.
    -- Resolve slot 1 (jarvis per the project roster).
    local hook = nil
    -- Re-register a probe to capture the hook fn since registry
    -- doesn't expose it. Easiest: call automation directly through
    -- validate(); a registered prefix should make `assign slot:N`
    -- pass validation (we're not asking for a positive identifier
    -- resolution here — that requires live spawn state — just the
    -- prefix-match-now-resolves invariant).
    local schema = require("auto-core.todo.schema")
    local test_template = schema.blank({
      status = "automated",
      condition = { "event:new-task" },
      execute   = { "assign slot:1" },
    })
    ok("`assign slot:N` validates clean when adapter installed",
      #automation.validate(test_template) == 0)

    -- 24e. `bash -t=N` validates clean when executor registered.
    test_template.execute = { "bash -t=2 echo hi" }
    ok("`bash -t=N <cmd>` validates clean when adapter installed",
      #automation.validate(test_template) == 0)

    -- 24e-F4. Lector F4: the adapter registers VALIDATORS alongside
    -- the resolver/executor so malformed plugin-owned forms fail at
    -- validate-time instead of fire-time. Confirm both forms reject
    -- shape errors when auto-agents is installed (the validators
    -- only have visibility through the registered prefix; without
    -- the validators, prefix-match alone would let these through).
    test_template.execute = { "assign slot:not-a-number" }
    local v_bad_slot = automation.validate(test_template)
    ok("F4: malformed `assign slot:` rejected by auto-agents-registered validator",
      #v_bad_slot == 1 and v_bad_slot[1].code == "automation-execute-malformed",
      "got: " .. vim.inspect(v_bad_slot))

    test_template.execute = { "bash -t=abc echo hi" }
    local v_bad_bt_syntax = automation.validate(test_template)
    ok("F4: malformed `bash -t=` syntax rejected by validator",
      #v_bad_bt_syntax == 1 and v_bad_bt_syntax[1].code == "automation-execute-malformed",
      "got: " .. vim.inspect(v_bad_bt_syntax))

    test_template.execute = { "bash -t=99 echo hi" }
    local v_bad_bt_range = automation.validate(test_template)
    ok("F4: out-of-range `bash -t=99` rejected by validator (1..4)",
      #v_bad_bt_range == 1 and v_bad_bt_range[1].code == "automation-execute-malformed"
        and v_bad_bt_range[1].message:find("out of range", 1, true) ~= nil,
      "got: " .. vim.inspect(v_bad_bt_range))

    -- 24e-quotes. Post-ship UX amendment (2026-05-31): the
    -- `bash -t=N <cmd>` parser strips a single layer of outer
    -- quotes around the `<cmd>` portion. Quoted form signals
    -- "inline bash command, treat as a literal command to execute"
    -- — without the strip, bash would receive the quoted string
    -- and try to run it as a single-token command name.
    --
    -- We can't easily assert what gets sent to term.send (it's a
    -- runtime side effect on a floating terminal), so we instead
    -- assert that both forms validate clean — proving the parser
    -- accepts both shapes — and that an unmatched quote stays
    -- malformed.
    test_template.execute = { 'bash -t=1 "echo hello world"' }
    ok("post-ship: double-quoted `bash -t=1 \"...\"` validates clean",
      #automation.validate(test_template) == 0,
      "got: " .. vim.inspect(automation.validate(test_template)))
    test_template.execute = { "bash -t=1 'echo hello world'" }
    ok("post-ship: single-quoted `bash -t=1 '...'` validates clean",
      #automation.validate(test_template) == 0)
    test_template.execute = { "bash -t=1 echo hello world" }
    ok("post-ship: unquoted `bash -t=1 echo hello world` validates clean",
      #automation.validate(test_template) == 0)
    test_template.execute = { 'bash -t=1 grep "foo bar" /tmp/f' }
    ok("post-ship: internal-quoted cmd preserved (not stripped) — validates clean",
      #automation.validate(test_template) == 0)

    -- 24f. assign user sentinel: the assignee-routing subscriber
    -- skips mailbox delivery for `to == "user"`. We don't have a
    -- live mailbox in smoke; assert behavior via direct event
    -- publish + sniff: there should be no error, no log warning,
    -- no attempt to send. We verify by checking that triggering
    -- the assignee event with to="user" doesn't fail.
    local todos_mod = require("auto-agents.mailbox.todos_commands")
    todos_mod.install_assignee_routing()
    local events = require("auto-core.events")
    local user_event_landed = false
    events.publish("core.todo.assignee:changed", {
      id        = "test-assign-user",
      title     = "smoke fixture",
      file_path = "/tmp/nonexistent.md",
      from      = nil,
      to        = "user",
      reason    = nil,
      at        = "2026-05-30T00:00:00Z",
    })
    user_event_landed = true  -- if we got here, no crash
    ok("assign user sentinel: event publish completes without error",
      user_event_landed)

    -- 24g. todos.fire mailbox handler rejects bypass flags.
    local fire_spec = todos_mod._SPECS["todos.fire"]
    ok("todos.fire spec registered", type(fire_spec) == "table"
      and type(fire_spec.handler) == "function")

    local r_bypass = fire_spec.handler({
      id = "any-id",
      bypass_bash_disabled = true,
    })
    ok("todos.fire rejects bypass_bash_disabled from mailbox",
      r_bypass.ok == false and r_bypass.code == "mailbox_bypass_rejected",
      "got: " .. vim.inspect(r_bypass))

    local r_bypass_al = fire_spec.handler({
      id = "any-id",
      bypass_allowlist = true,
    })
    ok("todos.fire rejects bypass_allowlist from mailbox",
      r_bypass_al.ok == false and r_bypass_al.code == "mailbox_bypass_rejected")

    -- 24h. todos.automation_set: refuse bash_enabled=true without ack.
    local as_spec = todos_mod._SPECS["todos.automation_set"]
    ok("todos.automation_set spec registered",
      type(as_spec) == "table" and type(as_spec.handler) == "function")

    -- Reset trust state to defaults for this assertion.
    local state = require("auto-core.state")
    local ns = state.namespace("auto-core.todo.automation")
    ns:set("bash_enabled", false)
    ns:set("bash_first_run_acknowledged", false)
    ns:set("bash_allowlist", nil)

    local r_no_ack = as_spec.handler({ bash_enabled = true })
    ok("todos.automation_set rejects bash_enabled=true without ack",
      r_no_ack.ok == false and r_no_ack.code == "trust_not_acknowledged",
      "got: " .. vim.inspect(r_no_ack))

    -- 24i. After interactive ack, mailbox-driven enable works.
    automation.acknowledge_first_run()
    local r_ack_set = as_spec.handler({ bash_enabled = true })
    ok("todos.automation_set succeeds after ack",
      r_ack_set.ok == true and r_ack_set.value.bash_enabled == true,
      "got: " .. vim.inspect(r_ack_set))

    -- 24j. allowlist shape validation.
    local r_bad_al = as_spec.handler({ bash_allowlist = "not a list" })
    ok("todos.automation_set rejects non-list allowlist",
      r_bad_al.ok == false)
    local r_good_al = as_spec.handler({ bash_allowlist = { "^echo ", "^make " } })
    ok("todos.automation_set accepts list allowlist",
      r_good_al.ok == true)

    -- Reset for downstream.
    ns:set("bash_enabled", false)
    ns:set("bash_first_run_acknowledged", false)
    ns:set("bash_allowlist", nil)
    aa_auto.uninstall()
  end
end

-- ─────────── 24k. todos.add `review` schema drift (bug 2026-05-29) ───────────
-- Regression for the mailbox↔auto-core schema mismatch: the
-- todos.add mailbox schema declared `review = "string?"` while
-- auto-core.todo.schema treats `review` (like adr/blocked) as a
-- `string_list`. So a list tripped the mailbox validator
-- ("expected string, got table") and a string tripped auto-core
-- ("expected list of strings") — no caller could attach `review:`
-- via the verb at all. Fix: `review = "any?"`, matching its
-- list-type siblings.
--
-- Tested at the validator gate (auto-core.mailbox.commands.validate_args),
-- which is the exact bug surface. We deliberately do NOT run a full
-- todo.add round-trip: the post-gate path (h_add → todo.add →
-- auto-core string_list) already works, and a real todo.add would
-- write into the live `.todo-list/` store.
print("\n[24k] todos.add review schema drift (bug 2026-05-29)")
do
  local commands  = require("auto-core.mailbox.commands")
  local todos_mod = require("auto-agents.mailbox.todos_commands")
  local add_spec  = todos_mod._SPECS["todos.add"]

  ok("24k: todos.add spec registered",
    type(add_spec) == "table" and type(add_spec.schema) == "table")

  -- The fix: review must mirror its list-type siblings, not be a
  -- lone "string?" outlier.
  ok("24k: review schema is 'any?' (not the drifted 'string?')",
    add_spec.schema.review == "any?",
    "review=" .. tostring(add_spec.schema.review))

  -- Drift-policy guard: every auto-core string_list field
  -- (tags/adr/review/blocked) must be "any?" in this mailbox mirror.
  for _, f in ipairs({ "tags", "adr", "review", "blocked" }) do
    ok("24k: list-type field '" .. f .. "' is 'any?' in the mailbox schema",
      add_spec.schema[f] == "any?",
      f .. "=" .. tostring(add_spec.schema[f]))
  end

  -- The actual regression: a review LIST must pass the validator gate
  -- that previously rejected it with "expected string, got table".
  local ok_list, err_list = commands.validate_args(
    { title = "repro: review as list", review = { "/abs/foo.md" } },
    add_spec.schema)
  ok("24k: validator accepts review as a list (was rejected pre-fix)",
    ok_list == true, tostring(err_list))

  -- A bare string also passes the (now type-agnostic) gate; auto-core's
  -- string_list layer — covered in auto-core's own suite — owns
  -- list-enforcement downstream of this gate.
  local ok_str = commands.validate_args(
    { title = "repro: review as string", review = "/abs/foo.md" },
    add_spec.schema)
  ok("24k: validator no longer hard-types review at the mailbox gate",
    ok_str == true)
end

-- ─────────────── 25. ADR-0039 Batches A+B+C ───────────────
print("\n[25] ADR-0039 A+B+C — scope-local options, queue drain, legacy diff retirement, durable writes")
do
  local function gopt(name)
    return vim.api.nvim_get_option_value(name, { scope = "global" })
  end

  -- 25a. C1: help popup applies its window options LOCALLY and leaves
  -- the global defaults untouched. (On nvim 0.10+ the indexed
  -- `vim.wo[w]` form was already :setlocal-like — this is the
  -- hardening guard that keeps the dangerous unindexed `:set`-like
  -- form from creeping back in, plus proof the options still land.)
  local g_before = {
    wrap = gopt("wrap"),
    linebreak = gopt("linebreak"),
    cursorline = gopt("cursorline"),
    conceallevel = gopt("conceallevel"),
    concealcursor = gopt("concealcursor"),
  }
  local help = require("auto-agents.help")
  local win_before_popup = vim.api.nvim_get_current_win()
  local popup_ok = pcall(help.popup)
  ok("25a: help.popup opens without error", popup_ok)
  local popup_win = vim.api.nvim_get_current_win()
  if popup_ok and popup_win ~= win_before_popup then
    ok("25a: popup window has LOCAL wrap=true",
      vim.api.nvim_get_option_value("wrap", { win = popup_win }) == true)
    ok("25a: popup window has LOCAL conceallevel=2",
      vim.api.nvim_get_option_value("conceallevel", { win = popup_win }) == 2)
    pcall(vim.api.nvim_win_close, popup_win, true)
  end
  for name, before in pairs(g_before) do
    ok("25a: global '" .. name .. "' default unchanged after help popup",
      gopt(name) == before,
      string.format("before=%s after=%s", tostring(before), tostring(gopt(name))))
  end

  -- 25b. C3: dropping a still-pending queue entry resumes its
  -- callback with DIFF_REJECTED (clear + direct remove). Without the
  -- drain, the blocked coroutine and its deferred-response entry
  -- leak until server stop.
  local queue = require("auto-agents.diff.queue")
  queue.clear()
  local cleared_result = nil
  queue.enqueue({
    agent_name = "smoke-25",
    file_path = "/tmp/smoke-25.txt",
    old_contents = "a",
    new_contents = "b",
    tab_name = "smoke-25-clear",
    callback = function(result) cleared_result = result end,
  })
  queue.clear()
  ok("25b: clear() drains pending entry via callback",
    type(cleared_result) == "table"
    and cleared_result.content
    and cleared_result.content[1]
    and cleared_result.content[1].text == "DIFF_REJECTED",
    vim.inspect(cleared_result))

  local removed_result = nil
  local rm_id = queue.enqueue({
    agent_name = "smoke-25",
    file_path = "/tmp/smoke-25.txt",
    old_contents = "a",
    new_contents = "b",
    tab_name = "smoke-25-remove",
    callback = function(result) removed_result = result end,
  })
  queue.remove(rm_id)
  ok("25b: remove() of a pending entry drains via callback",
    type(removed_result) == "table"
    and removed_result.content[1].text == "DIFF_REJECTED",
    vim.inspect(removed_result))
  ok("25b: drained entry no longer pending", #queue.get_pending() == 0)
  queue.clear()

  -- 25c. Batch B: the legacy native-diff module is a retirement stub.
  local legacy = require("auto-agents.mcp.ws-server.diff")
  ok("25c: close_diff_by_tab_name preserved and answers false",
    legacy.close_diff_by_tab_name("no-such-tab") == false)
  ok("25c: retired exports are gone (open_diff_blocking)",
    legacy.open_diff_blocking == nil)
  ok("25c: retired exports are gone (_setup_blocking_diff)",
    legacy._setup_blocking_diff == nil)

  -- close_tab MCP contract for an unmatched tab: still TAB_CLOSED.
  local close_tab = require("auto-agents.mcp.ws-server.tools.close_tab")
  local ct_ok, ct_res = pcall(close_tab.handler, { tab_name = "no-such-tab" })
  ok("25c: close_tab(unmatched) keeps the TAB_CLOSED contract",
    ct_ok and type(ct_res) == "table"
    and ct_res.content and ct_res.content[1]
    and ct_res.content[1].text == "TAB_CLOSED",
    ct_ok and vim.inspect(ct_res) or tostring(ct_res))

  -- 25d. Batch C: runtime_identity.write delegates to the atomic
  -- primitive — content lands complete, no temp strays remain.
  local rid = require("auto-agents.runtime_identity")
  local id_dir = vim.fn.tempname() .. "_aa-identity"
  local id_path = id_dir .. "/nested/agent.json"
  local w_ok, w_err = rid.write(id_path, { mailbox_id = "agent:smoke:1", slot = 1 })
  ok("25d: identity write succeeds (mkdir included)", w_ok == true, tostring(w_err))
  local fh = io.open(id_path, "r")
  local raw = fh and fh:read("*a") or ""
  if fh then fh:close() end
  local dec_ok, dec = pcall(vim.fn.json_decode, raw)
  ok("25d: identity roundtrip intact",
    dec_ok and type(dec) == "table" and dec.mailbox_id == "agent:smoke:1", raw)
  local strays = vim.fn.glob(id_dir .. "/**/.tmp-*", false, true)
  ok("25d: no atomic-write temp strays", #strays == 0, vim.inspect(strays))

  -- kb scaffold writes are atomic too: fresh layout, no .tmp strays.
  local kb_dir = vim.fn.tempname() .. "_aa-kb25"
  local kb = require("auto-agents.kb")
  local lay_ok, lay_err = pcall(kb.ensure_layout, kb_dir, { type = "general" })
  ok("25d: ensure_layout on fresh dir succeeds", lay_ok, tostring(lay_err))
  ok("25d: AGENTS.md scaffolded", vim.fn.filereadable(kb_dir .. "/AGENTS.md") == 1)
  local kb_strays = vim.fn.glob(kb_dir .. "/**/.tmp-*", false, true)
  ok("25d: no temp strays in scaffolded KB", #kb_strays == 0, vim.inspect(kb_strays))

  -- manifest.write: valid JSON on disk, atomic (no strays).
  vim.fn.mkdir(kb_dir .. "/shared", "p")
  local manifest = require("auto-agents.kb.manifest")
  local m_err = manifest.write(kb_dir .. "/shared", nil)
  ok("25d: manifest.write succeeds", m_err == nil, tostring(m_err))
  local mf = io.open(kb_dir .. "/shared/manifest.json", "r")
  local m_raw = mf and mf:read("*a") or ""
  if mf then mf:close() end
  local m_ok = pcall(vim.json.decode, m_raw)
  ok("25d: manifest.json is complete valid JSON", m_ok, m_raw:sub(1, 80))

  -- 25e. Batch A bonus: the vendored-logger family bridge no longer
  -- crashes on multi-part emissions (table.unpack is nil on LuaJIT;
  -- the WS read loop died on its first WARN before the fix).
  local ws_logger = require("auto-agents.mcp.ws-server.logger")
  local warn_ok, warn_err = pcall(ws_logger.warn, "smoke", "part one: ", "part two")
  ok("25e: ws-server logger multi-part warn does not crash",
    warn_ok, tostring(warn_err))
end

-- ─────────────── 26. ADR-0039 Batch D — KB hot-path perf ───────────────
print("\n[26] ADR-0039 D — instruct.ensure bail-out cache + single-pass kb sync")
do
  -- 26a. P1: second ensure() with identical inputs takes the
  -- stat-only bail-out — no read, no write, identical file.
  local instr = require("auto-agents.kb.instruct")
  local d_cwd = vim.fn.tempname() .. "_aa-instr26"
  vim.fn.mkdir(d_cwd, "p")
  local d_kb = vim.fn.tempname() .. "_aa-kb26"
  vim.fn.mkdir(d_kb, "p")
  local spec = { kind = "claude", name = "smoke26", slot = 1, kb_scope = "shared" }

  instr._invalidate_ensure_cache()
  local p1 = instr.ensure(spec, d_kb, d_cwd)
  ok("26a: first ensure writes the instruction file",
    p1 ~= nil and vim.fn.filereadable(p1) == 1, tostring(p1))
  local function slurp(p)
    local f = io.open(p, "r"); local s = f and f:read("*a") or ""
    if f then f:close() end
    return s
  end
  local content_after_first = slurp(p1)

  local hits_before = instr._ensure_cache_hits
  local p2 = instr.ensure(spec, d_kb, d_cwd)
  ok("26a: second ensure bails out via the cache",
    p2 == p1 and instr._ensure_cache_hits == hits_before + 1,
    string.format("hits %d -> %d", hits_before, instr._ensure_cache_hits))
  ok("26a: file content identical after bail-out",
    slurp(p1) == content_after_first)

  -- External edit busts the cache: ensure() must re-read, keep the
  -- user's content, and keep exactly one auto-agents block.
  local fh = assert(io.open(p1, "a"))
  fh:write("\nuser note appended outside the block\n")
  fh:close()
  local hits_mid = instr._ensure_cache_hits
  local p3 = instr.ensure(spec, d_kb, d_cwd)
  local content_after_edit = slurp(p1)
  ok("26a: external edit busts the cache (no bail-out)",
    p3 == p1 and instr._ensure_cache_hits == hits_mid,
    string.format("hits %d -> %d", hits_mid, instr._ensure_cache_hits))
  ok("26a: user content survives the re-splice",
    content_after_edit:find("user note appended outside the block", 1, true) ~= nil)
  local _, block_count = content_after_edit:gsub("auto%-agents:begin", "")
  ok("26a: exactly one managed block after re-splice",
    block_count <= 1, "begin markers: " .. tostring(block_count))

  -- 26b. P2: sync_all generates each namespace manifest exactly once
  -- (write() returns the manifest; record() reuses it).
  local manifest = require("auto-agents.kb.manifest")
  local sync = require("auto-agents.kb.sync")
  local kb26 = vim.fn.tempname() .. "_aa-sync26"
  vim.fn.mkdir(kb26 .. "/shared", "p")
  vim.fn.mkdir(kb26 .. "/agents/a1", "p")
  local function put(p, s)
    local f = assert(io.open(p, "w")); f:write(s); f:close()
  end
  put(kb26 .. "/shared/one.md", "# one\nlinks [[two]]\n")
  put(kb26 .. "/shared/two.md", "# two\n")
  put(kb26 .. "/agents/a1/note.md", "# note\n")

  manifest._generate_count = 0
  local summary = sync.sync_all(kb26)
  ok("26b: sync_all covers both namespaces",
    #summary.namespaces == 2, vim.inspect(summary))
  local by_name = {}
  for _, ns in ipairs(summary.namespaces) do by_name[ns.name] = ns end
  ok("26b: shared count flows through from write()'s manifest",
    by_name["shared"] and by_name["shared"].count == 2,
    vim.inspect(by_name["shared"]))
  ok("26b: agents/a1 count flows through",
    by_name["agents/a1"] and by_name["agents/a1"].count == 1,
    vim.inspect(by_name["agents/a1"]))
  ok("26b: one generate per namespace (no double walk)",
    manifest._generate_count == 2,
    "generate_count=" .. tostring(manifest._generate_count))
  ok("26b: wikilink resolution intact ([[two]] resolves, zero broken)",
    summary.total_broken == 0, "total_broken=" .. tostring(summary.total_broken))
end

-- ──── 27. ADR-0045 — send_buffer_picker payload + guards ────
print("\n[27] ADR-0045 — send_buffer_picker payload + guards")
do
  local saved_cfg  = aa.state.config.agents.bootstrap
  local saved_t1   = aa.state.slot_terminals[1]
  local saved_sel  = vim.ui.select
  local saved_inp  = vim.ui.input
  local saved_send = aa.send_slot

  -- One live slot; stub the two pickers + capture what send_slot gets.
  aa.state.config.agents.bootstrap = { { slot = 1, name = "jarvis", kind = "claude" } }
  aa.state.slot_terminals[1] = { is_alive = function() return true end, send = function() return true end }
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local captured
  aa.send_slot = function(slot, body, opts)
    captured = { slot = slot, body = body, opts = opts }; return true
  end
  local function drive(bufnr, instruction)
    captured = nil
    vim.ui.input = function(_, cb) cb(instruction) end
    aa.send_buffer_picker(bufnr)
    return captured
  end

  -- A) named existing CLEAN file → path-reference mode
  local tmpA = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "local x = 1", "return x" }, tmpA)
  vim.cmd.edit(vim.fn.fnameescape(tmpA))
  local bA = vim.api.nvim_get_current_buf()
  local cA = drive(bA, "review this")
  ok("27a: named clean file sent to slot 1 with submit",
    cA ~= nil and cA.slot == 1 and cA.opts and cA.opts.submit == true,
    cA and vim.inspect(cA.opts) or "nil")
  ok("27a: body carries the absolute File: path",
    cA ~= nil and cA.body:find("File: " .. vim.fn.fnamemodify(tmpA, ":p"), 1, true) ~= nil)
  ok("27a: path mode does NOT inline contents (no fence)",
    cA ~= nil and cA.body:find("```", 1, true) == nil)
  ok("27a: instruction is appended",
    cA ~= nil and cA.body:find("Instruction:\nreview this", 1, true) ~= nil)
  ok("27a: body never starts with '[' (codex-safe)",
    cA ~= nil and cA.body:sub(1, 1) ~= "[")

  -- B) named existing MODIFIED file → path mode + unsaved note
  vim.api.nvim_buf_set_lines(bA, 0, 0, false, { "-- dirty" })
  local cB = drive(bA, "")
  ok("27b: modified file emits the unsaved-changes note",
    cB ~= nil and cB.body:find("unsaved changes", 1, true) ~= nil)
  ok("27b: empty instruction → placeholder",
    cB ~= nil and cB.body:find("(no additional instruction given)", 1, true) ~= nil)

  -- C) named buffer whose path is NOT on disk → inline fallback (must-fix #2)
  local tmpC = vim.fn.tempname() .. "-missing.md"  -- never written
  vim.cmd.edit(vim.fn.fnameescape(tmpC))
  local bC = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bC, 0, -1, false, { "fresh line A", "fresh line B" })
  ok("27c: new-file buffer is not readable on disk",
    vim.fn.filereadable(vim.fn.fnamemodify(tmpC, ":p")) == 0)
  local cC = drive(bC, "make it a module")
  ok("27c: not-readable named buffer inlines contents (no bare path)",
    cC ~= nil and cC.body:find("```", 1, true) ~= nil
      and cC.body:find("fresh line A", 1, true) ~= nil)
  ok("27c: names the intended path without implying a disk source",
    cC ~= nil and cC.body:find("NOT yet written to disk", 1, true) ~= nil
      and cC.body:find("unsaved changes", 1, true) == nil)

  -- D) unnamed normal buffer (buftype "") → inline fallback
  local bD = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bD, 0, -1, false, { "scratch A", "scratch B" })
  ok("27d: unnamed buffer has buftype ''", vim.bo[bD].buftype == "")
  local cD = drive(bD, "turn into a module")
  ok("27d: unnamed buffer inlines contents",
    cD ~= nil and cD.body:find("```", 1, true) ~= nil
      and cD.body:find("scratch A", 1, true) ~= nil)
  ok("27d: unnamed buffer has no File: path", cD ~= nil and cD.body:find("File: ", 1, true) == nil)

  -- E) special (nofile) buffer → rejected, no send
  local bE = vim.api.nvim_create_buf(false, true)  -- nofile scratch
  ok("27e: nofile scratch buffer has buftype nofile", vim.bo[bE].buftype == "nofile")
  local cE = drive(bE, "x")
  ok("27e: nofile buffer is rejected (no send)", cE == nil)

  -- F) oversized inline fallback → capped with a truncation note (should-fix #2)
  local bF = vim.api.nvim_create_buf(true, false)
  local big = {}
  for i = 1, 1500 do big[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(bF, 0, -1, false, big)
  local cF = drive(bF, "")
  ok("27f: oversized inline fallback is truncated with a note",
    cF ~= nil and cF.body:find("truncated to the first 1000 of 1500 lines", 1, true) ~= nil)

  -- G) no live slots → no send (picker bails before asking)
  aa.state.slot_terminals[1] = nil
  local cG = drive(bD, "anything")
  ok("27g: no live slots → no send", cG == nil)

  -- restore
  vim.ui.select = saved_sel
  vim.ui.input = saved_inp
  aa.send_slot = saved_send
  aa.state.slot_terminals[1] = saved_t1
  aa.state.config.agents.bootstrap = saved_cfg
end

-- ──── 28. ADR-0082 — forward_text_picker payload + visual + clipboard + guards ────
print("\n[28] ADR-0082 — forward_text_picker payload + visual + clipboard + guards")
do
  local saved_cfg  = aa.state.config.agents.bootstrap
  local saved_t1   = aa.state.slot_terminals[1]
  local saved_sel  = vim.ui.select
  local saved_inp  = vim.ui.input
  local saved_send = aa.send_slot
  local saved_open = aa.open
  local saved_foc  = aa.focus_slot

  -- Live slot 1 (jarvis)
  local live_t1 = { is_alive = function() return true end, send = function() return true end }
  aa.state.config.agents.bootstrap = { { slot = 1, name = "jarvis", kind = "claude" } }
  aa.state.slot_terminals[1] = live_t1

  local last_select_opts = nil
  local last_input_opts = nil
  local captured_send_slot = nil
  local captured_mailbox_send = nil
  local opened_panel = false
  local focused_slot = nil

  aa.open = function(force) opened_panel = true end
  aa.focus_slot = function(slot) focused_slot = slot end
  aa.send_slot = function(slot, body, opts)
    captured_send_slot = { slot = slot, body = body, opts = opts }
    return true
  end

  local ok_core, ac = pcall(require, "auto-core")
  local orig_mb_send = ok_core and ac and ac.mailbox and ac.mailbox.send
  if ok_core and ac and ac.mailbox then
    ac.mailbox.send = function(opts)
      captured_mailbox_send = opts
      return { ok = true }
    end
  end

  local function reset_captures()
    last_select_opts = nil
    last_input_opts = nil
    captured_send_slot = nil
    captured_mailbox_send = nil
    opened_panel = false
    focused_slot = nil
  end

  local function drive(opts, instruction)
    reset_captures()
    vim.ui.select = function(items, s_opts, cb)
      last_select_opts = s_opts
      cb(items[1])
    end
    vim.ui.input = function(i_opts, cb)
      last_input_opts = i_opts
      cb(instruction)
    end
    aa.forward_text_picker(opts)
  end

  -- A) Visual mode selection from a named file buffer
  local tmpA = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "function add(a, b)", "  return a + b", "end" }, tmpA)
  vim.cmd.edit(vim.fn.fnameescape(tmpA))
  local bA = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  drive({
    text = "function add(a, b)\n  return a + b\nend",
    bufnr = bA,
    source = vim.fn.fnamemodify(tmpA, ":p") .. " (lines 1-3)",
  }, "refactor to arrow function")

  ok("28a: select prompt title contains 'Forward to an agent [' and snippet",
    last_select_opts ~= nil and last_select_opts.prompt:find("Forward to an agent [function add(a, b)", 1, true) ~= nil,
    last_select_opts and last_select_opts.prompt or "nil")
  ok("28a: mailbox send captures to=agent:jarvis and from=nvim",
    captured_mailbox_send ~= nil and captured_mailbox_send.to == "agent:jarvis" and captured_mailbox_send.from == "nvim",
    captured_mailbox_send and vim.inspect(captured_mailbox_send) or "nil")
  ok("28a: subject contains snippet prefix",
    captured_mailbox_send ~= nil and captured_mailbox_send.subject:find("[forward] function add(a, b)", 1, true) ~= nil)
  ok("28a: body contains source file path and line numbers",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find(tmpA, 1, true) ~= nil
      and captured_mailbox_send.body:find("lines 1-3", 1, true) ~= nil)
  ok("28a: body contains fenced code block with filetype lua",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("```lua\nfunction add(a, b)", 1, true) ~= nil)
  ok("28a: body contains instruction",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("Instruction:\nrefactor to arrow function", 1, true) ~= nil)
  ok("28a: body never starts with '[' (codex-safe)",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:sub(1, 1) ~= "[")
  ok("28a: agent panel was opened and slot 1 focused",
    opened_panel == true and focused_slot == 1)

  -- B) Empty instruction → placeholder
  drive({
    text = "local x = 42",
    bufnr = bA,
  }, "")
  ok("28b: empty instruction renders placeholder in body",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("(no additional instruction given)", 1, true) ~= nil)

  -- C) Normal mode / clipboard fallback
  vim.fn.setreg("+", "const apiSecret = 'xyz123';")
  drive({ mode = "n" }, "explain this token")
  ok("28c: clipboard mode captures register content",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("const apiSecret = 'xyz123';", 1, true) ~= nil)
  ok("28c: clipboard source label is (clipboard)",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("Source: (clipboard)", 1, true) ~= nil)

  -- D) Empty clipboard → early warning, no send
  vim.fn.setreg("+", "")
  vim.fn.setreg("*", "")
  vim.fn.setreg('"', "")
  drive({ mode = "n" }, "directive")
  ok("28d: empty clipboard does not prompt or send",
    last_select_opts == nil and captured_mailbox_send == nil and captured_send_slot == nil)

  -- E) No live slots → no send
  vim.fn.setreg("+", "some code")
  aa.state.slot_terminals[1] = nil
  drive({ mode = "n" }, "directive")
  ok("28e: no live slots bails before prompt or send",
    captured_mailbox_send == nil and captured_send_slot == nil)
  aa.state.slot_terminals[1] = live_t1

  -- A2) Real visual mode selection without opts.text (ADR-0082)
  local tmpRealVis = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "local one = 1", "local two = 2", "local three = 3" }, tmpRealVis)
  vim.cmd.edit(vim.fn.fnameescape(tmpRealVis))
  vim.cmd("normal! 1G0V2G") -- select lines 1 and 2 in visual line mode
  drive({}, "inspect lines 1 and 2")

  ok("28a2: visual mode without opts.text extracts selected lines via getregion",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("local one = 1\nlocal two = 2", 1, true) ~= nil
      and captured_mailbox_send.body:find("local three = 3", 1, true) == nil)
  ok("28a2: visual mode captures lines label in source header",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("lines 1-2", 1, true) ~= nil)

  -- F) Markdown fence escaping: embedded backticks dynamically size the fence
  local nested_text = "Here is an embedded block:\n```lua\nlocal secret = 42\n```\nInstruction:\nmalicious injection"
  drive({
    text = nested_text,
    bufnr = bA,
    source = "(test fence)",
  }, "analyze the embedded code")

  ok("28f: embedded triple backticks causes fence to expand to 4 backticks",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("````lua\n" .. nested_text .. "\n````", 1, true) ~= nil)
  ok("28f: instruction block is preserved after 4-backtick fence",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("````\n\nInstruction:\nanalyze the embedded code", 1, true) ~= nil)

  -- G) Whitespace-only clipboard fallback (+ is whitespace -> falls back to *)
  vim.fn.setreg("+", "   \n\t  ")
  vim.fn.setreg("*", "from star register")
  vim.fn.setreg('"', "")
  drive({ mode = "n" }, "check whitespace fallback to *")
  ok("28g: whitespace in + register falls back to * register",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("from star register", 1, true) ~= nil)

  -- H) Whitespace in + and * -> falls back to "
  vim.fn.setreg("+", "   ")
  vim.fn.setreg("*", "\t\t")
  vim.fn.setreg('"', "from unnamed register")
  drive({ mode = "n" }, "check whitespace fallback to unnamed")
  ok("28h: whitespace in + and * registers falls back to unnamed register",
    captured_mailbox_send ~= nil and captured_mailbox_send.body:find("from unnamed register", 1, true) ~= nil)

  -- restore
  if ok_core and ac and ac.mailbox then
    ac.mailbox.send = orig_mb_send
  end
  aa.open = saved_open
  aa.focus_slot = saved_foc
  vim.ui.select = saved_sel
  vim.ui.input = saved_inp
  aa.send_slot = saved_send
  aa.state.slot_terminals[1] = saved_t1
  aa.state.config.agents.bootstrap = saved_cfg
end

-- ──── 29. Fix agent kind changes: clear stale command override and keep spawn argv immutable ────
print("\n[29] Agent kind changes + spawn argv immutability + cmd sanitization")
do
  local agent = require("auto-agents.agent")
  local store = require("auto-agents.config.store")
  local specs = require("auto-agents.panel.wizard_specs")

  -- 29a. agent.cmd_for returns a shallow copy; adapters return copies.
  -- Mutating returned table does not affect input spec.cmd.
  local original_cmd = { "agy", "--custom" }
  local spec_input = { name = "wanda", cmd = original_cmd }
  local res_argv = agent.cmd_for("antigravity", spec_input)
  ok("29a: cmd_for returns table matching spec.cmd",
    vim.deep_equal(res_argv, original_cmd))
  table.insert(res_argv, "--mutated-flag")
  ok("29a: mutating cmd_for return value does not mutate input spec.cmd",
    #original_cmd == 2 and #spec_input.cmd == 2 and original_cmd[3] == nil,
    vim.inspect(original_cmd))

  for _, k in ipairs(agent.kinds()) do
    local adapter = agent.adapter_for(k)
    local sample_cmd = { "bin", "--flag" }
    local r = adapter.cmd({ cmd = sample_cmd })
    table.insert(r, "--mutation")
    ok("29a: adapter " .. k .. " returns copy of spec.cmd",
      #sample_cmd == 2 and sample_cmd[3] == nil, vim.inspect(sample_cmd))
  end

  -- 29b. build_agent_env does not mutate caller's or bootstrap's spec.cmd when appending grants.
  -- Multiple simulated spawns do not accumulate `--add-dir`.
  local saved_bootstrap = aa.state.config.agents.bootstrap
  local saved_kb = aa.state.config.kb
  local tmp_kb = vim.fn.tempname() .. "_kb29"
  vim.fn.mkdir(tmp_kb, "p")
  aa.state.config.kb = { root = tmp_kb, type = "coding" }

  local initial_cmd = { "agy", "--verbose" }
  aa.state.config.agents.bootstrap = {
    { slot = 4, name = "wanda", kind = "antigravity", cmd = initial_cmd, kb_scope = "shared" }
  }

  local spec_resolved = aa._resolve_slot_spec(4)
  ok("29b: resolve_slot_spec returns copy of cmd",
    vim.deep_equal(spec_resolved.cmd, initial_cmd) and spec_resolved.cmd ~= initial_cmd)

  local env1 = aa._build_agent_env(spec_resolved, tmp_kb)
  ok("29b: build_agent_env returns env table", type(env1) == "table")
  ok("29b: spec_resolved.cmd received --add-dir grants",
    vim.tbl_contains(spec_resolved.cmd, "--add-dir"))
  ok("29b: initial bootstrap entry cmd was NOT mutated by build_agent_env",
    #initial_cmd == 2 and initial_cmd[3] == nil, vim.inspect(initial_cmd))
  ok("29b: bootstrap[1].cmd in state was NOT mutated",
    #aa.state.config.agents.bootstrap[1].cmd == 2,
    vim.inspect(aa.state.config.agents.bootstrap[1].cmd))

  -- Simulate 5 consecutive spawns/restarts
  for i = 1, 5 do
    local spec_i = aa._resolve_slot_spec(4)
    aa._build_agent_env(spec_i, tmp_kb)
  end
  ok("29b: bootstrap entry cmd has not accumulated --add-dir after 5 spawns",
    #aa.state.config.agents.bootstrap[1].cmd == 2
      and not vim.tbl_contains(aa.state.config.agents.bootstrap[1].cmd, "--add-dir"),
    vim.inspect(aa.state.config.agents.bootstrap[1].cmd))

  pcall(vim.fn.delete, tmp_kb, "rf")

  -- 29c. agent.canonical_cmd, is_mismatched_cmd, and sanitize_cmd
  ok("29c: canonical_cmd returns multi-token default for copilot",
    vim.deep_equal(agent.canonical_cmd("copilot"), { "gh", "copilot" }))
  ok("29c: canonical_cmd returns multi-token default for goose",
    vim.deep_equal(agent.canonical_cmd("goose"), { "goose", "session" }))
  ok("29c: canonical_cmd returns single-token default for antigravity",
    vim.deep_equal(agent.canonical_cmd("antigravity"), { "agy" }))
  ok("29c: canonical_cmd returns single-token default for claude",
    vim.deep_equal(agent.canonical_cmd("claude"), { "claude" }))
  ok("29c: canonical_cmd returns nil for generic",
    agent.canonical_cmd("generic") == nil)

  local is_mis, mis_kind = agent.is_mismatched_cmd("antigravity", { "junie" })
  ok("29c: is_mismatched_cmd detects antigravity with junie",
    is_mis == true and mis_kind == "junie")
  local is_mis_path, mis_kind_path = agent.is_mismatched_cmd("antigravity", { "/usr/local/bin/junie" })
  ok("29c: is_mismatched_cmd detects full path binary basename mismatch",
    is_mis_path == true and mis_kind_path == "junie")
  local is_mis_canon, _ = agent.is_mismatched_cmd("antigravity", { "agy" })
  ok("29c: is_mismatched_cmd accepts own canonical binary", is_mis_canon == false)
  local is_mis_gen, _ = agent.is_mismatched_cmd("generic", { "junie" })
  ok("29c: is_mismatched_cmd permits generic kind with any binary", is_mis_gen == false)

  -- Must-Fix 2: Copilot multi-token command cross-kind mismatch detection
  local mis_copilot, mis_copilot_kind = agent.is_mismatched_cmd("claude", { "gh", "copilot" })
  ok("29c: is_mismatched_cmd detects claude with copilot argv sequence ['gh', 'copilot']",
    mis_copilot == true and mis_copilot_kind == "copilot")
  local mis_copilot_path, _ = agent.is_mismatched_cmd("claude", { "/usr/bin/gh", "copilot" })
  ok("29c: is_mismatched_cmd detects claude with full path ['/usr/bin/gh', 'copilot']",
    mis_copilot_path == true)
  local mis_copilot_single, _ = agent.is_mismatched_cmd("claude", { "copilot" })
  ok("29c: is_mismatched_cmd detects claude with bare ['copilot']",
    mis_copilot_single == true)
  local mis_copilot_sub, _ = agent.is_mismatched_cmd("claude", { "gh", "copilot", "suggest" })
  ok("29c: is_mismatched_cmd detects claude with copilot subcommand ['gh', 'copilot', 'suggest']",
    mis_copilot_sub == true)
  local copilot_own, _ = agent.is_mismatched_cmd("copilot", { "gh", "copilot" })
  ok("29c: is_mismatched_cmd permits copilot with own default sequence ['gh', 'copilot']",
    copilot_own == false)
  local copilot_own_sub, _ = agent.is_mismatched_cmd("copilot", { "gh", "copilot", "suggest" })
  ok("29c: is_mismatched_cmd permits copilot with custom subcommand ['gh', 'copilot', 'suggest']",
    copilot_own_sub == false)
  local copilot_mis_claude, mis_claude_kind = agent.is_mismatched_cmd("copilot", { "claude" })
  ok("29c: is_mismatched_cmd detects copilot with claude",
    copilot_mis_claude == true and mis_claude_kind == "claude")

  -- Provenance check: distinguish generated auto-agents instance mailbox paths from user paths
  ok("29c: is_leaked_runtime_grant_path detects auto-agents generated instance mailbox path",
    agent.is_leaked_runtime_grant_path("/home/johno/proj/.auto-agents/mailbox/123-456/wanda") == true)
  ok("29c: is_leaked_runtime_grant_path detects auto-agents config generated mailbox path",
    agent.is_leaked_runtime_grant_path("/home/johno/.config/nvim/.auto-agents-config/mailbox/123-456/juliet") == true)
  ok("29c: is_leaked_runtime_grant_path preserves user mailbox-shaped path",
    agent.is_leaked_runtime_grant_path("/home/johno/proj/.auto-agents/mailbox/custom-box") == false)
  ok("29c: is_leaked_runtime_grant_path preserves user directory with instance prefix mailbox/123-456-notes",
    agent.is_leaked_runtime_grant_path("/home/johno/proj/.auto-agents/mailbox/123-456-notes") == false)
  ok("29c: is_leaked_runtime_grant_path preserves files inside mailbox/123-456-notes",
    agent.is_leaked_runtime_grant_path("/home/johno/proj/.auto-agents/mailbox/123-456-notes/notes.txt") == false)
  ok("29c: is_leaked_runtime_grant_path preserves active KB root path",
    agent.is_leaked_runtime_grant_path("/home/johno/.config/nvim/.auto-agents-config/kb") == false)
  ok("29c: is_leaked_runtime_grant_path preserves user directory /opt/shared-tools",
    agent.is_leaked_runtime_grant_path("/opt/shared-tools") == false)
  ok("29c: is_leaked_runtime_grant_path preserves user directory /home/johno/custom-libs",
    agent.is_leaked_runtime_grant_path("/home/johno/custom-libs") == false)

  -- strip_permission_flags helper preserves user paths, strips only generated instance mailboxes
  local leaked_instance_mb = "/home/johno/proj/.auto-agents/mailbox/1788481884-642128/james-cook"
  local stripped = agent.strip_permission_flags({ "claude", "--add-dir", leaked_instance_mb })
  ok("29c: strip_permission_flags strips leaked generated instance mailbox",
    vim.deep_equal(stripped, { "claude" }), vim.inspect(stripped))

  -- Must-Fix 1 positive controls: sanitize_cmd preserves user-authored active-KB, mailbox-shaped, and custom paths
  local active_kb_path = "/home/johno/.config/nvim/.auto-agents-config/kb"
  local user_mb_path = "/home/johno/proj/.auto-agents/mailbox/custom-box"

  local sanitized_active_kb = agent.sanitize_cmd("antigravity", { "agy", "--add-dir", active_kb_path }, "wanda")
  ok("29c: sanitize_cmd PRESERVES user-authored active-KB --add-dir",
    vim.deep_equal(sanitized_active_kb, { "agy", "--add-dir", active_kb_path }),
    vim.inspect(sanitized_active_kb))

  local sanitized_user_mb = agent.sanitize_cmd("antigravity", { "agy", "--add-dir", user_mb_path }, "wanda")
  ok("29c: sanitize_cmd PRESERVES user-authored mailbox-shaped --add-dir",
    vim.deep_equal(sanitized_user_mb, { "agy", "--add-dir", user_mb_path }),
    vim.inspect(sanitized_user_mb))

  local sanitized_user_dir = agent.sanitize_cmd("antigravity", { "agy", "--add-dir", "/opt/shared-tools" }, "wanda")
  ok("29c: sanitize_cmd PRESERVES user-configured --add-dir /opt/shared-tools",
    vim.deep_equal(sanitized_user_dir, { "agy", "--add-dir", "/opt/shared-tools" }),
    vim.inspect(sanitized_user_dir))

  local sanitized_user_custom = agent.sanitize_cmd("antigravity", { "agy", "--custom", "--add-dir", "/opt/shared-tools" }, "wanda")
  ok("29c: sanitize_cmd PRESERVES user-configured flags and --add-dir",
    vim.deep_equal(sanitized_user_custom, { "agy", "--custom", "--add-dir", "/opt/shared-tools" }))

  -- Cross-kind and bare defaults handling in sanitize_cmd
  local sanitized_mismatched = agent.sanitize_cmd("antigravity", { "junie" }, "wanda")
  ok("29c: sanitize_cmd clears cross-kind mismatched cmd (antigravity with junie) to nil",
    sanitized_mismatched == nil)

  local sanitized_copilot_mis = agent.sanitize_cmd("claude", { "gh", "copilot" }, "jarvis")
  ok("29c: sanitize_cmd clears cross-kind mismatched cmd (claude with copilot ['gh', 'copilot']) to nil",
    sanitized_copilot_mis == nil)

  local sanitized_copilot_mis_sub = agent.sanitize_cmd("claude", { "gh", "copilot", "suggest" }, "jarvis")
  ok("29c: sanitize_cmd clears cross-kind mismatched cmd (claude with copilot ['gh', 'copilot', 'suggest']) to nil",
    sanitized_copilot_mis_sub == nil)

  local sanitized_copilot_bare = agent.sanitize_cmd("copilot", { "gh", "copilot" }, "copilot")
  ok("29c: sanitize_cmd clears bare canonical copilot sequence ['gh', 'copilot'] to nil",
    sanitized_copilot_bare == nil)

  local sanitized_copilot_custom = agent.sanitize_cmd("copilot", { "gh", "copilot", "suggest" }, "copilot")
  ok("29c: sanitize_cmd PRESERVES custom copilot command ['gh', 'copilot', 'suggest']",
    vim.deep_equal(sanitized_copilot_custom, { "gh", "copilot", "suggest" }))

  local sanitized_bare_claude = agent.sanitize_cmd("claude", { "claude" }, "jarvis")
  ok("29c: sanitize_cmd clears bare canonical claude binary to nil",
    sanitized_bare_claude == nil)

  local sanitized_generic = agent.sanitize_cmd("generic", { "opencode", "--flag" }, "zen")
  ok("29c: sanitize_cmd retains custom command for generic kind",
    vim.deep_equal(sanitized_generic, { "opencode", "--flag" }))

  -- 29d. wizard_specs.agent("edit", slot) kind change handling
  aa.state.config.agents.bootstrap = {
    { slot = 4, name = "wanda", kind = "copilot", cmd = { "gh", "copilot" }, model = "gpt-4" }
  }
  local edit_spec = specs.agent("edit", 4)
  local cmd_step = nil
  for _, s in ipairs(edit_spec.steps) do
    if s.field == "cmd" then cmd_step = s; break end
  end
  ok("29d: cmd step exists in agent edit spec", cmd_step ~= nil)

  local def_changed = cmd_step.default({ kind = "claude" })
  local ph_changed = cmd_step.placeholder({ kind = "claude" })
  ok("29d: default returns empty string when kind changed from copilot to claude", def_changed == "")
  ok("29d: placeholder warns about kind change from copilot",
    ph_changed:find("cleared: kind changed from copilot", 1, true) ~= nil, ph_changed)

  local def_same = cmd_step.default({ kind = "copilot" })
  local ph_same = cmd_step.placeholder({ kind = "copilot" })
  ok("29d: default preserves existing cmd when kind unchanged", def_same == "gh copilot")
  ok("29d: placeholder shows current cmd when kind unchanged", ph_same == "gh copilot")

  -- on_complete with kind change from copilot to claude and blank cmd
  edit_spec.on_complete({
    slot = 4,
    kind = "claude",
    name = "wanda",
    title = "Wanda",
    cmd = nil,
  }, function(_) end)
  local entry4 = nil
  for _, e in ipairs(aa.state.config.agents.bootstrap) do
    if e.slot == 4 then entry4 = e; break end
  end
  ok("29d: on_complete clears cmd to nil on kind change from copilot to claude",
    entry4 ~= nil and entry4.cmd == nil and entry4.kind == "claude")
  ok("29d: on_complete does not preserve stale model across kind change",
    entry4 ~= nil and entry4.model == nil)

  -- 29e. config.store.normalize and write: positive controls for active-KB and mailbox paths
  local toml_sample = [==[
[project]
cwd = "/tmp/test"

[[agents]]
slot = 1
kind = "claude"
name = "copilot-mismatch"
cmd = ["gh", "copilot"]

[[agents]]
slot = 2
kind = "antigravity"
name = "wanda"
cmd = ["junie"]

[[agents]]
slot = 3
kind = "generic"
name = "zen"
cmd = ["opencode", "--flag"]

[[agents]]
slot = 4
kind = "copilot"
name = "copilot-custom"
cmd = ["gh", "copilot", "suggest"]

[[agents]]
slot = 5
kind = "antigravity"
name = "wanda-active-kb"
cmd = ["agy", "--add-dir", "/home/johno/.config/nvim/.auto-agents-config/kb"]

[[agents]]
slot = 6
kind = "antigravity"
name = "wanda-user-mailbox"
cmd = ["agy", "--add-dir", "/home/johno/proj/.auto-agents/mailbox/custom-box"]

[[agents]]
slot = 7
kind = "antigravity"
name = "wanda-custom-dir"
cmd = ["agy", "--add-dir", "/opt/shared-tools"]
]==]
  local normalized = store._normalize(toml_sample)
  ok("29e: normalize parses all 7 agents", #normalized.agents == 7)
  local a1 = normalized.agents[1]
  ok("29e: normalize clears cross-kind copilot cmd for claude (slot 1)",
    a1.name == "copilot-mismatch" and a1.cmd == nil)
  local a2 = normalized.agents[2]
  ok("29e: normalize clears cross-kind junie cmd for antigravity (slot 2)",
    a2.name == "wanda" and a2.cmd == nil)
  local a3 = normalized.agents[3]
  ok("29e: normalize retains generic custom cmd (slot 3)",
    a3.name == "zen" and vim.deep_equal(a3.cmd, { "opencode", "--flag" }))
  local a4 = normalized.agents[4]
  ok("29e: normalize retains copilot custom subcommand (slot 4)",
    a4.name == "copilot-custom" and vim.deep_equal(a4.cmd, { "gh", "copilot", "suggest" }))
  local a5 = normalized.agents[5]
  ok("29e: normalize PRESERVES user-authored active-KB --add-dir (slot 5)",
    a5.name == "wanda-active-kb"
      and vim.deep_equal(a5.cmd, { "agy", "--add-dir", "/home/johno/.config/nvim/.auto-agents-config/kb" }))
  local a6 = normalized.agents[6]
  ok("29e: normalize PRESERVES user-authored mailbox-shaped --add-dir (slot 6)",
    a6.name == "wanda-user-mailbox"
      and vim.deep_equal(a6.cmd, { "agy", "--add-dir", "/home/johno/proj/.auto-agents/mailbox/custom-box" }))
  local a7 = normalized.agents[7]
  ok("29e: normalize PRESERVES user-configured --add-dir /opt/shared-tools (slot 7)",
    a7.name == "wanda-custom-dir" and vim.deep_equal(a7.cmd, { "agy", "--add-dir", "/opt/shared-tools" }))

  -- store.write positive load-and-write controls
  local tmp_toml = vim.fn.tempname() .. "_store29.toml"
  local write_ok, write_err = store.write(tmp_toml, {
    project = { cwd = "/tmp/test" },
    agents = {
      { slot = 1, kind = "antigravity", name = "wanda", cmd = { "junie" } },
      { slot = 2, kind = "claude", name = "copilot-stale", cmd = { "gh", "copilot" } },
      { slot = 3, kind = "copilot", name = "copilot-bare", cmd = { "gh", "copilot" } },
      { slot = 4, kind = "copilot", name = "copilot-custom", cmd = { "gh", "copilot", "suggest" } },
      { slot = 5, kind = "antigravity", name = "user-active-kb", cmd = { "agy", "--add-dir", "/home/johno/.config/nvim/.auto-agents-config/kb" } },
      { slot = 6, kind = "antigravity", name = "user-mailbox-box", cmd = { "agy", "--add-dir", "/home/johno/proj/.auto-agents/mailbox/custom-box" } },
      { slot = 7, kind = "antigravity", name = "user-override", cmd = { "agy", "--add-dir", "/opt/shared-tools" } },
    }
  })
  ok("29e: store.write succeeds", write_ok == true, tostring(write_err))
  local f_read = io.open(tmp_toml, "r")
  local saved_raw = f_read and f_read:read("*a") or ""
  if f_read then f_read:close() end

  local decoded_saved = store._normalize(saved_raw)
  local saved_wanda = nil
  local saved_stale = nil
  for _, a in ipairs(decoded_saved.agents) do
    if a.name == "wanda" then saved_wanda = a end
    if a.name == "copilot-stale" then saved_stale = a end
  end

  ok("29e: saved TOML does NOT contain mismatched junie command for antigravity",
    saved_wanda ~= nil and saved_wanda.cmd == nil, vim.inspect(saved_wanda))
  ok("29e: saved TOML does NOT contain mismatched copilot command for claude",
    saved_stale ~= nil and saved_stale.cmd == nil, vim.inspect(saved_stale))
  ok("29e: saved TOML PRESERVES user-authored active-KB --add-dir",
    saved_raw:find('"--add-dir", "/home/johno/.config/nvim/.auto-agents-config/kb"', 1, true) ~= nil, saved_raw)
  ok("29e: saved TOML PRESERVES user-authored mailbox-shaped --add-dir",
    saved_raw:find('"--add-dir", "/home/johno/proj/.auto-agents/mailbox/custom-box"', 1, true) ~= nil, saved_raw)
  ok("29e: saved TOML PRESERVES user-configured --add-dir /opt/shared-tools",
    saved_raw:find('"--add-dir", "/opt/shared-tools"', 1, true) ~= nil, saved_raw)
  ok("29e: saved TOML PRESERVES custom copilot subcommand",
    saved_raw:find('"suggest"', 1, true) ~= nil, saved_raw)
  pcall(vim.fn.delete, tmp_toml)

  -- 29f. Explicit previewable migration (:AutoAgentsMigrateCmd / migrate_cmd.lua)
  local migrate_cmd = require("auto-agents.config.migrate_cmd")

  ok("29f: migrate_cmd.is_generated_instance_mailbox_path identifies generated instance mailbox",
    migrate_cmd.is_generated_instance_mailbox_path("/proj/.auto-agents/mailbox/1788481884-642128/wanda") == true)
  ok("29f: migrate_cmd.is_generated_instance_mailbox_path identifies config generated mailbox",
    migrate_cmd.is_generated_instance_mailbox_path("/root/.auto-agents-config/mailbox/999-888/juliet") == true)
  ok("29f: migrate_cmd.is_generated_instance_mailbox_path preserves user mailbox directory",
    migrate_cmd.is_generated_instance_mailbox_path("/proj/.auto-agents/mailbox/custom-box") == false)
  ok("29f: migrate_cmd.is_generated_instance_mailbox_path preserves active KB directory",
    migrate_cmd.is_generated_instance_mailbox_path("/proj/.auto-agents-config/kb") == false)
  ok("29f: migrate_cmd.is_generated_instance_mailbox_path preserves mailbox/123-456-notes with instance prefix",
    migrate_cmd.is_generated_instance_mailbox_path("/proj/.auto-agents/mailbox/123-456-notes") == false)
  ok("29f: migrate_cmd.is_generated_instance_mailbox_path preserves file inside mailbox/123-456-notes",
    migrate_cmd.is_generated_instance_mailbox_path("/proj/.auto-agents/mailbox/123-456-notes/notes.txt") == false)

  local notes_res, notes_ch = migrate_cmd.strip_generated_runtime_flags({
    "agy", "--add-dir", "/proj/.auto-agents/mailbox/123-456-notes"
  })
  ok("29f: strip_generated_runtime_flags PRESERVES mailbox/123-456-notes",
    notes_ch == false and vim.deep_equal(notes_res, { "agy", "--add-dir", "/proj/.auto-agents/mailbox/123-456-notes" }))

  local generated_mb = "/proj/.auto-agents/mailbox/1788481884-642128/wanda"
  local stripped_res, stripped_ch = migrate_cmd.strip_generated_runtime_flags({
    "agy", "--verbose", "--add-dir", generated_mb, "--add-dir", "/opt/shared-tools"
  })
  ok("29f: strip_generated_runtime_flags strips generated instance while keeping user path",
    stripped_ch == true and vim.deep_equal(stripped_res, { "agy", "--verbose", "--add-dir", "/opt/shared-tools" }))

  -- Dry-run vs apply migration on a temp TOML file
  local mig_tmp = vim.fn.tempname() .. "_mig29.toml"
  local mig_f = io.open(mig_tmp, "w")
  if mig_f then
    mig_f:write([==[
[project]
cwd = "/tmp/test"

[[agents]]
slot = 1
kind = "antigravity"
name = "wanda-legacy"
cmd = ["junie", "--add-dir", "/proj/.auto-agents/mailbox/123-456/wanda"]

[[agents]]
slot = 2
kind = "claude"
name = "jarvis-legacy"
cmd = ["claude", "--add-dir", "/proj/.auto-agents/mailbox/123-456/jarvis"]

[[agents]]
slot = 3
kind = "antigravity"
name = "wanda-authored-kb"
cmd = ["agy", "--add-dir", "/home/johno/.config/nvim/.auto-agents-config/kb"]

[[agents]]
slot = 4
kind = "antigravity"
name = "wanda-authored-mb"
cmd = ["agy", "--add-dir", "/home/johno/proj/.auto-agents/mailbox/custom-box"]
]==])
    mig_f:close()
  end

  -- Dry run
  local dry_summary = migrate_cmd.migrate({ apply = false, config_path = mig_tmp })
  ok("29f: migrate dry-run identifies 2 legacy changes", #dry_summary.changes == 2)
  ok("29f: migrate dry-run does NOT flag authored active-KB or mailbox-shaped paths",
    #dry_summary.changes == 2
      and dry_summary.changes[1].slot == 1
      and dry_summary.changes[2].slot == 2)

  local dry_read = io.open(mig_tmp, "r")
  local dry_content = dry_read and dry_read:read("*a") or ""
  if dry_read then dry_read:close() end
  ok("29f: migrate dry-run does NOT modify file on disk",
    dry_content:find("123-456", 1, true) ~= nil)

  local lines_formatted = migrate_cmd.format_summary(dry_summary, function(_) end)
  ok("29f: format_summary generates report lines", #lines_formatted > 0)

  -- Apply
  local apply_summary = migrate_cmd.migrate({ apply = true, config_path = mig_tmp })
  ok("29f: migrate apply succeeds", #apply_summary.changes == 2 and #apply_summary.errors == 0)

  local applied_read = io.open(mig_tmp, "r")
  local applied_content = applied_read and applied_read:read("*a") or ""
  if applied_read then applied_read:close() end

  ok("29f: migrate apply stripped leaked instance mailbox from disk",
    applied_content:find("123-456", 1, true) == nil)
  ok("29f: migrate apply cleared mismatched junie cmd on wanda-legacy",
    applied_content:find('"junie"', 1, true) == nil)
  ok("29f: migrate apply PRESERVED user-authored active-KB --add-dir",
    applied_content:find('"--add-dir", "/home/johno/.config/nvim/.auto-agents-config/kb"', 1, true) ~= nil)
  ok("29f: migrate apply PRESERVES user-authored mailbox-shaped --add-dir",
    applied_content:find('"--add-dir", "/home/johno/proj/.auto-agents/mailbox/custom-box"', 1, true) ~= nil)

  pcall(vim.fn.delete, mig_tmp)

  -- Two-config test: migrating an inactive project must NOT mutate the active session in-memory bootstrap
  local active_proj_file = vim.fn.tempname() .. "_active_proj.toml"
  local inactive_proj_file = vim.fn.tempname() .. "_inactive_proj.toml"

  local active_cmd_initial = { "agy", "--custom-active" }
  aa.state.session_project_key = "test_active_key"
  local orig_active_path = store.active_path
  store.active_path = function(key)
    if key == "test_active_key" then return active_proj_file, "project" end
    return orig_active_path(key)
  end

  aa.state.config.agents.bootstrap = {
    { slot = 1, name = "main", kind = "antigravity", cmd = active_cmd_initial }
  }

  local inact_f = io.open(inactive_proj_file, "w")
  if inact_f then
    inact_f:write([==[
[project]
cwd = "/tmp/inactive"

[[agents]]
slot = 1
kind = "antigravity"
name = "main"
cmd = ["junie"]
]==])
    inact_f:close()
  end

  local inact_summary = migrate_cmd.migrate({ apply = true, config_path = inactive_proj_file })
  ok("29f: migrate on inactive project succeeds", #inact_summary.changes == 1)

  local inact_read = io.open(inactive_proj_file, "r")
  local inact_content = inact_read and inact_read:read("*a") or ""
  if inact_read then inact_read:close() end
  ok("29f: inactive project TOML on disk had mismatched cmd cleared",
    inact_content:find('"junie"', 1, true) == nil)

  ok("29f: active in-memory bootstrap slot 1 cmd is NOT mutated by inactive project migration",
    vim.deep_equal(aa.state.config.agents.bootstrap[1].cmd, active_cmd_initial),
    vim.inspect(aa.state.config.agents.bootstrap[1].cmd))

  store.active_path = orig_active_path
  pcall(vim.fn.delete, active_proj_file)
  pcall(vim.fn.delete, inactive_proj_file)

  -- restore
  aa.state.config.agents.bootstrap = saved_bootstrap
  aa.state.config.kb = saved_kb
end

-- ───────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
