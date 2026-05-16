-- Regression tests for ADR 0011 — diff panel left-column labels.
-- Run with:
--   nvim --headless -u NONE -l tests/diff_panel_labels_spec.lua
--
-- Covers Patch 1 (D1 + D4):
--   * repo_for resolves bare-worktree paths to the bare repo basename
--     (not the worktree/branch name) — this is the regression that
--     produced "Projects/log.md" in the user's panel.
--   * repo_for resolves plain-clone paths to the clone dir basename.
--   * repo_for falls back to project_root / parent basename when no
--     git metadata is reachable.
--   * agent_for normalises every "unattributed" sentinel (nil / "" /
--     "agent" / "?" / "unknown" / "unattributed") to one display
--     string. Real attributions pass through unchanged.

-- Resolve project roots — same idiom as the other specs.
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

local function eq(name, got, want)
  ok(name, got == want,
    string.format("got=%q want=%q", tostring(got), tostring(want)))
end

-- ── Fixtures ──────────────────────────────────────────────
-- Single tmpdir, three repo shapes that match the failure modes the
-- user observed:
--   bare-style.nvim/{main,branch-x}/lua/foo.lua  ← bare repo + worktrees
--                                                  (matches auto-agents.nvim
--                                                  layout under nvim-plugins/)
--   plain-clone/log.md                            ← regular .git-as-dir clone
--                                                  (matches the KB repo)
--   nongit/foo.lua                                ← no git anywhere up

local function sh(cmd)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error("shell command failed: " .. cmd .. "\n" .. out)
  end
  return out
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local bare_root  = tmp .. "/bare-style.nvim"
local plain_root = tmp .. "/plain-clone"
local nongit     = tmp .. "/nongit"

sh(string.format("git init --bare -q %q", bare_root))
sh(string.format("git -C %q worktree add -q -b main %q/main",         bare_root, bare_root))
sh(string.format("git -C %q worktree add -q -b branch-x %q/branch-x", bare_root, bare_root))
vim.fn.mkdir(bare_root .. "/main/lua", "p")
vim.fn.writefile({ "return {}" }, bare_root .. "/main/lua/foo.lua")
vim.fn.mkdir(bare_root .. "/branch-x/lua", "p")
vim.fn.writefile({ "return {}" }, bare_root .. "/branch-x/lua/foo.lua")

sh(string.format("git init -q %q", plain_root))
vim.fn.writefile({ "# log" }, plain_root .. "/log.md")

vim.fn.mkdir(nongit, "p")
vim.fn.writefile({ "-- foo" }, nongit .. "/foo.lua")

-- ── Tests ─────────────────────────────────────────────────
local ui = require("auto-agents.diff.ui")
ok("ui._test_repo_for exposed",  type(ui._test_repo_for)  == "function")
ok("ui._test_agent_for exposed", type(ui._test_agent_for) == "function")

print("\n[1] repo_for / bare-worktree layout")
-- The regression: a file in a bare-worktree layout was labelled with
-- the workspace's PARENT (`Projects` in the user's case) or — if we
-- had used `git_root` — with the branch name (`main`, `branch-x`).
-- Correct answer is the bare repo's basename.
eq("file under bare-style.nvim/main labels as bare-style.nvim",
   ui._test_repo_for(bare_root .. "/main/lua/foo.lua"),
   "bare-style.nvim")
eq("file under bare-style.nvim/branch-x labels as bare-style.nvim (not branch-x)",
   ui._test_repo_for(bare_root .. "/branch-x/lua/foo.lua"),
   "bare-style.nvim")

print("\n[2] repo_for / plain-clone layout")
eq("file in plain-clone/log.md labels as plain-clone",
   ui._test_repo_for(plain_root .. "/log.md"),
   "plain-clone")

print("\n[3] repo_for / non-git fallback")
eq("file in non-git tmpdir labels as parent basename",
   ui._test_repo_for(nongit .. "/foo.lua"),
   "nongit")

print("\n[4] agent_for / unattributed-sentinel normalisation")
eq("nil → unattributed",                  ui._test_agent_for(nil),              "unattributed")
eq("empty string → unattributed",         ui._test_agent_for(""),               "unattributed")
eq("\"agent\" → unattributed",            ui._test_agent_for("agent"),          "unattributed")
eq("\"?\" → unattributed",                ui._test_agent_for("?"),              "unattributed")
eq("\"unknown\" → unattributed",          ui._test_agent_for("unknown"),        "unattributed")
eq("\"unattributed\" → unattributed",     ui._test_agent_for("unattributed"),   "unattributed")
eq("number → unattributed",               ui._test_agent_for(42),               "unattributed")

print("\n[5] agent_for / real attributions pass through")
eq("\"jarvis\" passes through",           ui._test_agent_for("jarvis"),         "jarvis")
eq("\"lector\" passes through",           ui._test_agent_for("lector"),         "lector")
eq("\"agent-foo\" not stripped",          ui._test_agent_for("agent-foo"),      "agent-foo")
eq("\"agent foo\" not stripped",          ui._test_agent_for("agent foo"),      "agent foo")
eq("\"?prefix\" not stripped",            ui._test_agent_for("?prefix"),        "?prefix")

-- ── Cleanup ───────────────────────────────────────────────
sh(string.format("rm -rf %q", tmp))

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)