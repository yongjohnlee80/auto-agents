-- Headless tests for ADR-0082 forward_text_picker's VISUAL path. Run:
--   nvim --headless -u NONE -l tests/forward_text_visual_spec.lua
--
-- Why this exists. smoke.lua [28] has a case labelled "Visual mode selection"
-- that passes `text = "..."` pre-supplied, so it drives the `opts.text` branch
-- and never enters visual mode. The capture path it names has never run. That
-- is how the feature reached a user (Johno, 2026-09-07) unable to forward a
-- selection at all.
--
-- These assertions drive REAL visual selections through the two entry points a
-- user actually has, and assert on the payload the picker receives.
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

local function pick(rel)
  for _, wt in ipairs({ "/forward-text", "/main", "" }) do
    local p = plugins_root .. "/" .. rel .. wt
    if vim.fn.isdirectory(p .. "/lua") == 1 then return p end
  end
end
for _, p in ipairs({ project_root, pick("auto-core.nvim"), pick("worktree.nvim") }) do
  if p then
    vim.opt.runtimepath:append(p)
    package.path = p .. "/lua/?.lua;" .. p .. "/lua/?/init.lua;" .. package.path
  end
end
vim.o.columns, vim.o.lines = 160, 45

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

print("ADR-0082 — forward_text_picker, the VISUAL path a user actually takes")

local aa = require("auto-agents")
assert(pcall(aa.setup, {
  panel = { side = "right", min_width = 50, max_width = 120,
            editor_floor = 30, percentage = 0.30 },
  agents = { bootstrap = {} }, kb = {}, term = { enabled = false },
}), "setup failed")
vim.cmd("runtime! plugin/auto-agents.lua")   -- registers :AutoAgentsForwardText

-- One live slot so the picker gets past its guards.
aa.state.config.agents.bootstrap = { { slot = 1, name = "jarvis", kind = "claude" } }
aa.state.slot_terminals[1] = { is_alive = function() return true end,
                               send = function() return true end }

-- Capture the payload the picker was built from, via the prompt it renders.
local seen_prompt, seen_source
local function arm()
  seen_prompt, seen_source = nil, nil
  vim.ui.select = function(items, opts, cb)
    seen_prompt = opts and opts.prompt
    cb(nil)                       -- cancel: we only care what it CAPTURED
  end
  vim.ui.input = function(_, cb) cb(nil) end
end

local tmp = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "local alpha = 1", "local bravo = 2", "local charlie = 3" }, tmp)
vim.cmd.edit(vim.fn.fnameescape(tmp))
vim.api.nvim_win_set_cursor(0, { 1, 0 })

-- The clipboard must NOT be what answers, or a green cell proves nothing about
-- the selection. Poison it with something no assertion below looks for.
-- Short enough to survive the prompt's snippet truncation: a longer needle
-- made the clipboard cell fail while the clipboard was working correctly.
local CLIP = "CLIPBOARD-NOT-SEL"
vim.fn.setreg("+", CLIP)
vim.fn.setreg("*", CLIP)

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- ── §1 a visual-mode KEYMAP calling the function directly ───────────
-- This is the entry point being added in the consumer config. It keeps the
-- mode, so `vim.fn.mode()` inside the extractor reads "V".
vim.keymap.set({ "n", "v" }, "<Plug>FwdTest",
  function() aa.forward_text_picker() end, {})

arm()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("Vj")            -- linewise select lines 1-2
feed("<Plug>FwdTest")
ok("a visual keymap captures the SELECTION",
  seen_prompt ~= nil and seen_prompt:find("local alpha = 1", 1, true) ~= nil,
  tostring(seen_prompt))
ok("...and not the clipboard",
  seen_prompt ~= nil and seen_prompt:find(CLIP, 1, true) == nil,
  tostring(seen_prompt))

-- ── §2 the :command, invoked the way a user invokes it ──────────────
-- Typing `:` from visual mode LEAVES visual mode before the command runs, so
-- `vim.fn.mode()` reads "n" and the extractor's visual branch cannot fire.
-- Measured: a :user command sees "n" where a visual keymap sees "V". The
-- command therefore has to read the '< '> marks instead.
arm()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("Vj:AutoAgentsForwardText<CR>")
ok("the :command captures the SELECTION too",
  seen_prompt ~= nil and seen_prompt:find("local alpha = 1", 1, true) ~= nil,
  tostring(seen_prompt))
ok("...and not the clipboard",
  seen_prompt ~= nil and seen_prompt:find(CLIP, 1, true) == nil,
  tostring(seen_prompt))

-- ── §3 normal mode still falls back to the clipboard ────────────────
-- The fallback is the feature's other half; a fix that captured marks
-- unconditionally would break it, and stale '< '> marks persist after the
-- visual selection above — exactly the trap.
arm()
feed("<Esc>")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
aa.forward_text_picker()
ok("normal mode with no selection uses the clipboard",
  seen_prompt ~= nil and seen_prompt:find(CLIP, 1, true) ~= nil,
  tostring(seen_prompt))

-- ── §4 the :command with NO range still uses the clipboard ──────────
-- §3 calls the Lua function directly, so the COMMAND's own `cmd.range > 0`
-- guard goes unobserved there: mutating it to `if true` left §3 green while
-- the clipboard path was broken. `:cmd` with no range still defaults line1 and
-- line2 to the cursor line, so an unguarded read silently forwards whatever
-- line the cursor happens to sit on instead of the clipboard.
arm()
feed("<Esc>")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
feed(":AutoAgentsForwardText<CR>")
ok("the :command with no range uses the clipboard",
  seen_prompt ~= nil and seen_prompt:find(CLIP, 1, true) ~= nil, tostring(seen_prompt))
ok("...and does NOT forward the cursor's line",
  seen_prompt ~= nil and seen_prompt:find("local charlie", 1, true) == nil,
  tostring(seen_prompt))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then vim.cmd("cq") else vim.cmd("qa!") end
