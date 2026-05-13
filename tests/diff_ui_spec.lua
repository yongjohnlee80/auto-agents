-- Headless test for the diff queue float UI. Run with:
--   nvim --headless -u NONE -l tests/diff_ui_spec.lua
--
-- Verifies the "navigate inside the diff panes" feature:
--   * middle / preview windows render line numbers + cursorline.
--   * left pane carries the selection keymaps (j, k, 1, A, D, <CR>).
--   * middle / preview panes do NOT shadow j, k, 1-9, or <CR>, so
--     Vim's native motions (hjkl, counts, w/b/e/f/$/gg/G, etc.) work.
--   * A / D stay bound on middle / preview so accept-deny works from
--     anywhere (mirrors worktree.graph's bind_pane_action_keys).
--   * pane cycling (<Tab>, <S-Tab>, <C-h>, <C-l>) is bound on every
--     focusable pane.

-- Resolve project roots
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
local core_root = plugins_root .. "/auto-core.nvim/main"
if vim.fn.isdirectory(core_root) == 0 then
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

local function has_keymap(buf, lhs)
  -- Nvim canonicalizes modifier-form lhs in km.lhs ("<C-l>" → "<C-L>",
  -- uppercase letter), and named keys stay as "<Tab>"/"<CR>". Compare
  -- case-insensitively so the test passes regardless of which case the
  -- caller wrote.
  local want = lhs:lower()
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if km.lhs and km.lhs:lower() == want then return true end
  end
  return false
end

print("\n[1] Open float with a pending entry")
local queue = require("auto-agents.diff.queue")
local ui = require("auto-agents.diff.ui")

queue.clear()
queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/sample.lua",
  old_contents = "line one\nline two\nline three\n",
  new_contents = "line one\nline two modified\nline three\nline four\n",
  tab_name = "✻ [Claude Code] sample.lua (deadbeef) ⧉",
  callback = function() end,
})

ui.open()
vim.wait(50)

local mf = ui._test_get_mfloat()
ok("multi-float instance is live", mf ~= nil and mf:is_open())

print("\n[2] Window options on diff panes")
local middle_win = mf:winid("middle")
local preview_win = mf:winid("preview")
local left_win = mf:winid("left")

ok("middle win is valid", middle_win and vim.api.nvim_win_is_valid(middle_win))
ok("preview win is valid", preview_win and vim.api.nvim_win_is_valid(preview_win))

ok("middle window has line numbers",
   middle_win and vim.wo[middle_win].number == true)
ok("preview window has line numbers",
   preview_win and vim.wo[preview_win].number == true)

ok("middle window has cursorline",
   middle_win and vim.wo[middle_win].cursorline == true)
ok("preview window has cursorline",
   preview_win and vim.wo[preview_win].cursorline == true)

-- Left pane keeps cursorline (selection follows the cursor) but does
-- NOT need number — it's a list view, not file content.
ok("left window has cursorline",
   left_win and vim.wo[left_win].cursorline == true)

print("\n[3] Selection keymaps on LEFT pane only")
local left_buf = mf:bufnr("left")
local middle_buf = mf:bufnr("middle")
local preview_buf = mf:bufnr("preview")

-- Left pane: selection keys bound.
ok("left has j keymap (selection down)",      has_keymap(left_buf, "j"))
ok("left has k keymap (selection up)",        has_keymap(left_buf, "k"))
ok("left has 1 keymap (numeric select)",      has_keymap(left_buf, "1"))
ok("left has 9 keymap (numeric select)",      has_keymap(left_buf, "9"))
ok("left has <CR> keymap (open native diff)", has_keymap(left_buf, "<CR>"))

-- Middle / preview: selection keys NOT bound so Vim motions work.
ok("middle does NOT shadow j",     not has_keymap(middle_buf, "j"))
ok("middle does NOT shadow k",     not has_keymap(middle_buf, "k"))
ok("middle does NOT shadow 1",     not has_keymap(middle_buf, "1"))
ok("middle does NOT shadow 5",     not has_keymap(middle_buf, "5"))
ok("middle does NOT shadow <CR>",  not has_keymap(middle_buf, "<CR>"))

ok("preview does NOT shadow j",    not has_keymap(preview_buf, "j"))
ok("preview does NOT shadow k",    not has_keymap(preview_buf, "k"))
ok("preview does NOT shadow 1",    not has_keymap(preview_buf, "1"))
ok("preview does NOT shadow <CR>", not has_keymap(preview_buf, "<CR>"))

print("\n[4] Accept / Deny + cycling bound on every focusable pane")
for _, item in ipairs({
  { name = "left",    buf = left_buf },
  { name = "middle",  buf = middle_buf },
  { name = "preview", buf = preview_buf },
}) do
  ok(item.name .. " has A keymap",      has_keymap(item.buf, "A"))
  ok(item.name .. " has D keymap",      has_keymap(item.buf, "D"))
  ok(item.name .. " has <Tab> keymap",  has_keymap(item.buf, "<Tab>"))
  ok(item.name .. " has <C-l> keymap",  has_keymap(item.buf, "<C-l>"))
end

-- auto-core auto-stamps q/<Esc> on every pane bufnr — assert that's
-- still in place so the user can close from any pane.
ok("middle has q (auto-core stamp)",     has_keymap(middle_buf, "q"))
ok("preview has <Esc> (auto-core stamp)", has_keymap(preview_buf, "<Esc>"))

print("\n[5] Auto-close when queue drains")
-- Clear residue from earlier sections, then re-open with two entries
-- so we can verify the float stays open after the first removal and
-- closes only when the queue is empty.
mf:close()
queue.clear()
vim.wait(20)

local id_a = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/a.lua",
  old_contents = "a",
  new_contents = "A",
  tab_name = "tab-a",
  callback = function() end,
})
local id_b = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/b.lua",
  old_contents = "b",
  new_contents = "B",
  tab_name = "tab-b",
  callback = function() end,
})

ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()
ok("float reopened with two pending entries",
   mf ~= nil and mf:is_open() and #queue.get_pending() == 2)

-- Resolve the first entry; queue still has one, float must stay open.
queue.resolve(id_a, "A")
vim.wait(50)
local mf_after_first = ui._test_get_mfloat()
ok("float still open after first resolve (1 pending remains)",
   mf_after_first ~= nil and mf_after_first:is_open())
ok("queue has 1 pending after first resolve",
   #queue.get_pending() == 1)

-- Reject the last entry; queue empties — float must auto-close.
queue.reject(id_b)
vim.wait(50)
local mf_after_drain = ui._test_get_mfloat()
ok("float closed automatically after queue drained",
   mf_after_drain == nil or not mf_after_drain:is_open())
ok("queue is empty", #queue.get_pending() == 0)

print("\n[6] Cleanup")
queue.clear()
local final_mf = ui._test_get_mfloat()
ok("float closed", final_mf == nil or not final_mf:is_open())

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)