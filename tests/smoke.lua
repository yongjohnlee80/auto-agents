-- Headless smoke tests for auto-agents.nvim. Run with:
--   nvim --headless -u NONE -l tests/smoke.lua
--
-- These tests focus on the panel surface and the buffer-guard added
-- to keep arbitrary file buffers out of the agent panel. Slot
-- terminals aren't actually spawned (no real CLI to drive); we
-- exercise admin-slot mounting plus the guard's bounce behavior.

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  "/home/johno/Source/Projects/nvim-plugins/auto-agents.nvim",
  LAZY .. "/plenary.nvim",
}) do
  vim.opt.runtimepath:prepend(p)
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
ok("state.mounting starts false", aa.state.mounting == false)

-- ───────────────────────── 2. open + admin slot ────────────────────
print("\n[2] open + focus_slot(0) — admin")
aa.open(true)
local panel = aa.state.panel_winid
ok("panel_winid set", panel ~= nil and vim.api.nvim_win_is_valid(panel))
ok("winfixwidth set on panel", panel and vim.wo[panel].winfixwidth == true)

aa.focus_slot(0)
ok("focused_slot == 0", aa.state.focused_slot == 0)
local panel_buf = vim.api.nvim_win_get_buf(panel)
local ft = vim.bo[panel_buf].filetype
ok("panel filetype = auto-agents-admin", ft == "auto-agents-admin", "ft=" .. ft)

-- ───────────────────────── 3. _is_panel_buffer / guard semantics ───
print("\n[3] guard semantics — :edit a regular file from panel")
-- Find a target window we expect the bounce to use. Headless starts
-- with the original main window; opening the panel made two.
local main_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if w ~= panel then main_win = w end
end
ok("main_win exists", main_win ~= nil)

vim.api.nvim_set_current_win(panel)
local tmp = "/tmp/auto-agents-smoke-target.txt"
vim.fn.writefile({ "hello" }, tmp)
vim.cmd("edit " .. tmp)
local target_bufnr = vim.fn.bufnr(tmp)

vim.wait(200, function()
  return vim.api.nvim_win_get_buf(panel) ~= target_bufnr
end, 5)
vim.wait(200, function()
  return vim.api.nvim_win_get_buf(main_win) == target_bufnr
end, 5)

panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel restored to admin buffer (filetype auto-agents-admin)",
  vim.bo[panel_buf].filetype == "auto-agents-admin",
  "ft=" .. vim.bo[panel_buf].filetype)
local main_buf = main_win and vim.api.nvim_win_get_buf(main_win) or -1
ok("file ended up in main_win", main_buf == target_bufnr,
  "main_buf=" .. main_buf .. " expected=" .. target_bufnr)

-- ───────────────────────── 4. :buffer N (bufferline-click sim) ─────
print("\n[4] guard semantics — :buffer N from panel")
vim.api.nvim_set_current_win(panel)
local another = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(another, "/tmp/auto-agents-smoke-other.txt")
vim.cmd("buffer " .. another)
vim.wait(200, function() return vim.api.nvim_win_get_buf(panel) ~= another end, 5)
panel_buf = vim.api.nvim_win_get_buf(panel)
ok("panel still admin after :buffer N",
  vim.bo[panel_buf].filetype == "auto-agents-admin",
  "ft=" .. vim.bo[panel_buf].filetype)

-- ───────────────────────── 5. terminal buffers are allowed ─────────
print("\n[5] slot-terminal buffers pass the guard")
-- Headless can't reliably spawn the agent CLIs, so we fake a slot
-- terminal entry: a thin object whose `get_bufnr()` returns a buffer
-- we control. The guard's `_is_panel_buffer` accepts any bufnr that
-- matches a slot_terminals[*]:get_bufnr() — which is the contract a
-- real auto-agents terminal satisfies.
local fake_term_buf = vim.api.nvim_create_buf(false, true)
aa.state.slot_terminals[1] = {
  get_bufnr = function() return fake_term_buf end,
  is_alive = function() return true end,
}
local saved_focused = aa.state.focused_slot
aa.state.mounting = true
pcall(vim.api.nvim_win_set_buf, panel, fake_term_buf)
aa.state.mounting = false
-- Trigger the guard manually — same shape as the BufWinEnter callback.
aa._guard_panel_buffer(fake_term_buf)
ok("slot-terminal buffer not bounced (slot_terminals contract)",
  vim.api.nvim_win_get_buf(panel) == fake_term_buf,
  "panel_buf=" .. vim.api.nvim_win_get_buf(panel) .. " fake=" .. fake_term_buf)
-- Cleanup: drop the fake slot, restore admin.
aa.state.slot_terminals[1] = nil
aa.state.mounting = true
local admin_buf = require("auto-agents.panel.admin").get_or_create_buffer()
pcall(vim.api.nvim_win_set_buf, panel, admin_buf)
aa.state.mounting = false
aa.state.focused_slot = saved_focused

-- ───────────────────────── 6. mounting flag suppresses guard ───────
print("\n[6] mounting flag short-circuits guard")
aa.state.mounting = true
local hostile = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(hostile, "/tmp/auto-agents-smoke-hostile.txt")
pcall(vim.api.nvim_win_set_buf, panel, hostile)
aa._guard_panel_buffer(hostile)
ok("hostile buffer NOT bounced while mounting=true",
  vim.api.nvim_win_get_buf(panel) == hostile,
  "panel_buf=" .. vim.api.nvim_win_get_buf(panel))
-- Now flip mounting off and call the guard directly — should bounce.
aa.state.mounting = false
aa._guard_panel_buffer(hostile)
vim.wait(200, function() return vim.api.nvim_win_get_buf(panel) ~= hostile end, 5)
ok("hostile buffer IS bounced once mounting=false",
  vim.api.nvim_win_get_buf(panel) ~= hostile)

-- ───────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
