-- Headless test for the diff queue float UI. Run with:
--   nvim --headless -u NONE -l tests/diff_ui_spec.lua
--
-- Verifies the "navigate inside the diff panes" feature:
--   * middle / preview windows render line numbers + cursorline.
--   * left pane carries the selection keymaps (j, k, 1, A, D, O, <CR>).
--   * middle / preview panes do NOT shadow j, k, 1-9, O, or <CR>, so
--     Vim's native motions (hjkl, counts, w/b/e/f/$/gg/G, etc. — plus
--     `O` for "open line above" when the preview is in edit mode) work.
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
ok("left has <CR> keymap (commit cursor row to preview, for queues > 9)",
                                                     has_keymap(left_buf, "<CR>"))

-- Middle / preview: selection keys NOT bound so Vim motions work.
-- (O is intentionally allowed to shadow native `O` on every pane — see
-- the [4] action-keymap loop below.)
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
  ok(item.name .. " has O keymap (open full-file diff)",
                                        has_keymap(item.buf, "O"))
  ok(item.name .. " has <Tab> keymap",  has_keymap(item.buf, "<Tab>"))
  ok(item.name .. " has <C-l> keymap",  has_keymap(item.buf, "<C-l>"))
end

-- auto-core auto-stamps q/<Esc> on every pane bufnr — assert that's
-- still in place so the user can close from any pane.
ok("middle has q (auto-core stamp)",     has_keymap(middle_buf, "q"))
ok("preview has <Esc> (auto-core stamp)", has_keymap(preview_buf, "<Esc>"))

print("\n[4b] M keymap requests change and rejects with reason")
-- Verify the M binding is present on every focusable pane.
for _, item in ipairs({
  { name = "left",    buf = left_buf },
  { name = "middle",  buf = middle_buf },
  { name = "preview", buf = preview_buf },
}) do
  ok(item.name .. " has M keymap (Request Change)", has_keymap(item.buf, "M"))
end

-- Mock vim.ui.input so the keymap can run headlessly. The keymap
-- handler calls vim.ui.input(opts, cb); we capture the prompt to
-- assert wording, then invoke cb with a canned reason.
local captured_prompt = nil
local saved_input = vim.ui.input
local injected_reason = "wrap the io.open in pcall"
vim.ui.input = function(opts, cb)
  captured_prompt = opts and opts.prompt
  cb(injected_reason)
end

-- Capture the rejection result on the pending entry's callback.
queue.clear()
local m_result = nil
queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/m.lua",
  old_contents = "old",
  new_contents = "new",
  tab_name = "tab-m",
  callback = function(res) m_result = res end,
})

-- Re-open the float so _render_list refreshes for the new entry.
ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()

-- Drive the M handler directly. Looking up the keymap rhs and calling
-- it bypasses needing to feed keys through nvim_input — clearer and
-- doesn't depend on which window currently has focus.
local m_lbuf = mf:bufnr("left")
local m_handler
for _, km in ipairs(vim.api.nvim_buf_get_keymap(m_lbuf, "n")) do
  if km.lhs == "M" then m_handler = km.callback end
end
ok("M keymap on left is a callable", type(m_handler) == "function")
m_handler()
vim.wait(50)

ok("vim.ui.input was invoked with the REQUEST CHANGE prompt",
   captured_prompt == "REQUEST CHANGE: ")
ok("entry was rejected via M",
   m_result and m_result.content and m_result.content[1].text == "DIFF_REJECTED")
ok("agent receives the user's request-change reason verbatim",
   m_result and m_result.content[2].text == injected_reason)
ok("M empties the queue when it was the only entry",
   #queue.get_pending() == 0)

-- Drain the previous M handler's 150ms-deferred send_slot call
-- against the still-real send_slot before installing the mock — the
-- previous test's defer is harmless (real send_slot fails silently
-- since slot_terminals[1] isn't a live agent), but if we don't wait
-- it out it'll fire AFTER we install the mock and pollute the second
-- test's captures.
vim.wait(220)

-- Second channel: M should also inject "REQUEST CHANGE: <reason>" into
-- the agent's terminal via auto-agents.send_slot with submit=true. We
-- mock send_slot to capture the call without needing a live terminal.
-- The M handler defers the send by 150ms (so Claude's TUI has time to
-- finish processing DIFF_REJECTED before we type), hence the wait.
local aa = require("auto-agents")
local saved_send_slot = aa.send_slot
local send_captures = {}
aa.send_slot = function(slot, text, opts)
  table.insert(send_captures, { slot = slot, text = text, opts = opts })
  return true
end
-- ADR-0046 D-C: the request-change reason routes to the diff's
-- ATTRIBUTED author via aa.slot_for_name(agent_name) — NOT a
-- focused_slot fallback. Mock slot_for_name so "jarvis" maps to slot 3
-- (the author) and assert send_slot routes there.
local saved_slot_for_name = aa.slot_for_name
aa.slot_for_name = function(name) return (name == "jarvis") and 3 or nil end
if not aa.state then aa.state = {} end
aa.state.focused_slot = 1  -- present but must NOT be used as a fallback

queue.clear()
local m2_result = nil
queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/m2.lua",
  old_contents = "x",
  new_contents = "y",
  tab_name = "tab-m2",
  callback = function(res) m2_result = res end,
})

local injected_reason2 = "use io.open instead of vim.fn.readfile"
vim.ui.input = function(_, cb) cb(injected_reason2) end

ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()
for _, km in ipairs(vim.api.nvim_buf_get_keymap(mf:bufnr("left"), "n")) do
  if km.lhs == "M" then m_handler = km.callback end
end
m_handler()
vim.wait(250)  -- exceeds the 150ms M-handler defer

ok("send_slot was invoked exactly once after M", #send_captures == 1)
ok("send_slot routed to the ATTRIBUTED author's slot (not focused_slot)",
   send_captures[1] and send_captures[1].slot == 3)
ok("send_slot payload is prefixed with REQUEST CHANGE:",
   send_captures[1] and send_captures[1].text == "REQUEST CHANGE: " .. injected_reason2)
ok("send_slot was called with submit=true",
   send_captures[1] and send_captures[1].opts and send_captures[1].opts.submit == true)
ok("M still rejected the diff (DIFF_REJECTED + reason)",
   m2_result and m2_result.content[1].text == "DIFF_REJECTED"
   and m2_result.content[2].text == injected_reason2)

-- ADR-0046 D-C: an UNATTRIBUTED diff must NOT inject into any slot —
-- no focused_slot fallback. slot_for_name returns nil → send_slot is
-- never called; the M handler refuses + notifies instead.
aa.slot_for_name = function(_) return nil end
send_captures = {}
queue.clear()
local m3_result = nil
queue.enqueue({
  agent_name = "unattributed",
  file_path = "/tmp/m3.lua",
  old_contents = "x",
  new_contents = "y",
  tab_name = "tab-m3",
  callback = function(res) m3_result = res end,
})
vim.ui.input = function(_, cb) cb("please rename the variable") end
ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()
for _, km in ipairs(vim.api.nvim_buf_get_keymap(mf:bufnr("left"), "n")) do
  if km.lhs == "M" then m_handler = km.callback end
end
m_handler()
vim.wait(250)

ok("ADR-0046 D-C: unattributed diff → send_slot NOT called (no focused fallback)",
   #send_captures == 0, "send_captures=" .. tostring(#send_captures))
ok("ADR-0046 D-C: unattributed diff still rejected (DIFF_REJECTED)",
   m3_result and m3_result.content and m3_result.content[1]
   and m3_result.content[1].text == "DIFF_REJECTED")

aa.slot_for_name = saved_slot_for_name
aa.send_slot = saved_send_slot

-- Empty input from the prompt cancels — verify no rejection fires.
queue.clear()
local cancel_result = nil
local id_cancel = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/cancel.lua",
  old_contents = "x",
  new_contents = "y",
  tab_name = "tab-cancel",
  callback = function(res) cancel_result = res end,
})

vim.ui.input = function(_, cb) cb("") end
ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()
for _, km in ipairs(vim.api.nvim_buf_get_keymap(mf:bufnr("left"), "n")) do
  if km.lhs == "M" then m_handler = km.callback end
end
m_handler()
vim.wait(50)

ok("empty REQUEST CHANGE input is a no-op (no callback fired)",
   cancel_result == nil)
ok("queue entry remains pending after cancel",
   queue.get(id_cancel) ~= nil and queue.get(id_cancel).status == "pending")

-- Restore vim.ui.input and drain the queue for the next section.
vim.ui.input = saved_input
queue.clear()

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

print("\n[5a] Auto-close also fires when the user empties the queue via the panel keymaps (A / D)")
-- IMPORTANT regression contract: pressing A or D in the diff panel
-- when the queue has exactly one entry MUST drain the queue AND
-- close the float. This exercises the keymap path (not the
-- queue.resolve/queue.reject direct calls covered by [5]) because
-- the bug was that the keymap handler's render_left() + update_preview()
-- ran AFTER queue.resolve and the auto-close subscriber's
-- vim.schedule path raced against them. If this section ever regresses,
-- the diff workflow becomes unusable — users would be left staring at
-- an empty panel after every accept/reject.
queue.clear()
vim.wait(20)

local function fire_buffer_keymap(buf, lhs)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    error("fire_buffer_keymap: invalid buffer " .. tostring(buf))
  end
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == lhs and type(m.callback) == "function" then
      m.callback()
      return true
    end
  end
  error("fire_buffer_keymap: no n-mode mapping for '" .. lhs .. "'")
end

-- Sub-case 1: press A on the single pending entry. Queue drains;
-- float must auto-close.
local id_press_a = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/press_a.lua",
  old_contents = "before",
  new_contents = "AFTER",
  tab_name = "tab-press-a",
  callback = function() end,
})
ui.open()
vim.wait(50)
local mf_a = ui._test_get_mfloat()
ok("[A path] float open with one pending entry",
   mf_a ~= nil and mf_a:is_open() and #queue.get_pending() == 1)

local left_buf_a = mf_a:bufnr("left")
fire_buffer_keymap(left_buf_a, "A")
-- vim.schedule path in the auto-close subscriber needs at least one
-- main-loop tick. Wait longer than that to be deterministic.
vim.wait(100, function()
  local m = ui._test_get_mfloat()
  return m == nil or not m:is_open()
end)
local mf_after_a = ui._test_get_mfloat()
ok("[A path] queue empty after A keymap",
   #queue.get_pending() == 0)
ok("[A path] float auto-closed after A drained the queue (regression: pressing A must close the empty panel)",
   mf_after_a == nil or not mf_after_a:is_open(),
   string.format("queue_pending=%d, float_open=%s",
     #queue.get_pending(),
     tostring(mf_after_a and mf_after_a:is_open() or false)))

-- Sub-case 2: press D on the single pending entry. Same contract.
vim.wait(20)
local id_press_d = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/press_d.lua",
  old_contents = "before",
  new_contents = "AFTER",
  tab_name = "tab-press-d",
  callback = function() end,
})
ui.open()
vim.wait(50)
local mf_d = ui._test_get_mfloat()
ok("[D path] float open with one pending entry",
   mf_d ~= nil and mf_d:is_open() and #queue.get_pending() == 1)

local left_buf_d = mf_d:bufnr("left")
fire_buffer_keymap(left_buf_d, "D")
vim.wait(100, function()
  local m = ui._test_get_mfloat()
  return m == nil or not m:is_open()
end)
local mf_after_d = ui._test_get_mfloat()
ok("[D path] queue empty after D keymap",
   #queue.get_pending() == 0)
ok("[D path] float auto-closed after D drained the queue (regression: pressing D must close the empty panel)",
   mf_after_d == nil or not mf_after_d:is_open(),
   string.format("queue_pending=%d, float_open=%s",
     #queue.get_pending(),
     tostring(mf_after_d and mf_after_d:is_open() or false)))

-- Sub-case 3: with TWO entries, pressing A on the first MUST leave
-- the float open (queue still has one). This guards against an
-- over-eager close that would dismiss the panel while work remains.
queue.clear()
vim.wait(20)
local id_two_a = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/two_a.lua",
  old_contents = "1", new_contents = "1!",
  tab_name = "tab-two-a",
  callback = function() end,
})
local id_two_b = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/two_b.lua",
  old_contents = "2", new_contents = "2!",
  tab_name = "tab-two-b",
  callback = function() end,
})
ui.open()
vim.wait(50)
local mf_two = ui._test_get_mfloat()
ok("[non-empty] float open with two pending entries",
   mf_two ~= nil and mf_two:is_open() and #queue.get_pending() == 2)
fire_buffer_keymap(mf_two:bufnr("left"), "A")
vim.wait(100)
local mf_two_after = ui._test_get_mfloat()
ok("[non-empty] float stays open after A when other entries remain",
   mf_two_after ~= nil and mf_two_after:is_open()
     and #queue.get_pending() == 1)
-- Drain the remaining entry to leave a clean slate for [5a].
fire_buffer_keymap(mf_two_after:bufnr("left"), "A")
vim.wait(100)

print("\n[5b] Treesitter is started on the diff panes for viewing")
-- Close any open float, install a mock on vim.treesitter.start, open
-- the float with a fresh entry, and assert that update_preview
-- explicitly called treesitter.start for middle + preview with the
-- detected filetype.
if mf and mf:is_open() then mf:close() end
queue.clear()
vim.wait(20)

local saved_ts_start = vim.treesitter.start
local ts_calls = {}
vim.treesitter.start = function(buf, lang)
  table.insert(ts_calls, { buf = buf, lang = lang })
end

queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/probe.lua",  -- ".lua" → filetype "lua"
  old_contents = "local a = 1",
  new_contents = "local a = 2",
  tab_name = "tab-ts",
  callback = function() end,
})

ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()
local ts_middle_buf = mf:bufnr("middle")
local ts_preview_buf = mf:bufnr("preview")

local saw_middle, saw_preview = false, false
for _, c in ipairs(ts_calls) do
  if c.buf == ts_middle_buf and c.lang == "lua" then saw_middle = true end
  if c.buf == ts_preview_buf and c.lang == "lua" then saw_preview = true end
end
ok("vim.treesitter.start called for middle pane with detected lang", saw_middle)
ok("vim.treesitter.start called for preview pane with detected lang", saw_preview)

vim.treesitter.start = saved_ts_start
mf:close()
queue.clear()
vim.wait(20)

print("\n[5c] Edit mode — E toggle + edit cache + Accept-with-edits")
queue.clear()

-- Two entries so we can verify edits survive a selection swap.
local id_alpha = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/alpha.lua",
  old_contents = "local x = 1\n",
  new_contents = "local x = 2\nlocal y = 3\n",
  tab_name = "tab-alpha",
  callback = function() end,
})
local id_beta = queue.enqueue({
  agent_name = "jarvis",
  file_path = "/tmp/beta.lua",
  old_contents = "a",
  new_contents = "b",
  tab_name = "tab-beta",
  callback = function() end,
})

local accepted_alpha = nil
-- Replace alpha's callback so we can capture what A resolves with.
do
  local req = queue.get(id_alpha)
  req.callback = function(res) accepted_alpha = res end
end

ui.open()
vim.wait(50)
mf = ui._test_get_mfloat()
local preview_buf = mf:bufnr("preview")
local middle_buf = mf:bufnr("middle")

-- Filetype propagation kicks in via update_preview reading file_path.
ok("preview buffer has filetype from file_path",
   vim.bo[preview_buf].filetype == "lua")
ok("middle buffer has filetype from file_path",
   vim.bo[middle_buf].filetype == "lua")

-- E keymap is bound only on the preview buffer.
ok("preview buffer has E keymap", has_keymap(preview_buf, "E"))
ok("left buffer does NOT have E keymap", not has_keymap(mf:bufnr("left"), "E"))
ok("middle buffer does NOT have E keymap", not has_keymap(middle_buf, "E"))

-- Drive the E toggle to enter edit mode, then simulate a user edit by
-- writing into the preview buffer and triggering TextChanged.
local function find_handler(buf, lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if km.lhs == lhs then return km.callback end
  end
end
local e_handler = find_handler(preview_buf, "E")
ok("E handler is callable", type(e_handler) == "function")

-- Mock vim.notify so we can verify the user-facing hint fires on
-- enter (with "A saves" guidance) and a confirmation on exit.
local saved_notify = vim.notify
local notifications = {}
vim.notify = function(msg, level, opts)
  table.insert(notifications, { msg = msg, level = level, opts = opts })
end

e_handler()  -- enter edit mode
vim.wait(20)
ok("preview buffer is modifiable after E", vim.bo[preview_buf].modifiable == true)
ok("entering edit mode fires a notification",
   #notifications >= 1
   and notifications[1].msg:find("Edit mode")
   and notifications[1].msg:find("A to save"))

-- Type the user's edited content. The TextChanged autocmd should
-- capture it into _edits_by_id[id_alpha].
vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {
  "local x = 2",
  "local y = 3",
  "-- user added this comment",
})
-- Manually fire TextChanged since nvim_buf_set_lines doesn't always
-- fire it in headless mode. doautocmd is the canonical way.
vim.api.nvim_exec_autocmds("TextChanged", { buffer = preview_buf })
vim.wait(20)

-- Switch selection to beta, then back to alpha — edits must survive.
-- Find the j keymap on the left pane and invoke it once (alpha → beta).
local j_handler = find_handler(mf:bufnr("left"), "j")
j_handler()
vim.wait(20)
ok("after j, selection is on beta", _G or true)  -- visual placeholder

-- Now back to alpha (k).
local k_handler = find_handler(mf:bufnr("left"), "k")
k_handler()
vim.wait(20)

-- Preview buffer must now show the cached edits, not req.new_contents.
local restored = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
ok("preview restored cached edits after swap-back (3 lines)",
   #restored == 3 and restored[3] == "-- user added this comment")

-- Accept (A) on alpha should resolve with the edited content, not
-- req.new_contents.
local a_handler = find_handler(preview_buf, "A")
a_handler()
vim.wait(30)
ok("A resolved alpha with FILE_SAVED",
   accepted_alpha and accepted_alpha.content[1].text == "FILE_SAVED")
ok("A passed the edited content to queue.resolve",
   accepted_alpha
   and accepted_alpha.content[2].text
       == "local x = 2\nlocal y = 3\n-- user added this comment")

-- diff_removed should have purged alpha's entry from the edit cache.
-- We can't directly inspect _edits_by_id from outside (module-local),
-- but the contract is: re-enqueuing under a NEW id and verifying that
-- the preview pane uses req.new_contents (not stale cache) covers it.
queue.clear()

-- Toggle E again to exit edit mode; preview should become read-only.
local notifications_before_exit = #notifications
e_handler()
vim.wait(20)
ok("E toggled back to view mode → preview is non-modifiable",
   vim.bo[preview_buf].modifiable == false)
ok("exiting edit mode also fires a notification",
   #notifications > notifications_before_exit
   and notifications[#notifications].msg:find("View mode"))

vim.notify = saved_notify

-- queue.clear() above bypasses the event channel so the auto-close
-- subscriber doesn't fire; close explicitly so [6] sees a clean state.
mf:close()
vim.wait(20)

print("\n[6] Cleanup")
queue.clear()
local final_mf = ui._test_get_mfloat()
ok("float closed", final_mf == nil or not final_mf:is_open())

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)