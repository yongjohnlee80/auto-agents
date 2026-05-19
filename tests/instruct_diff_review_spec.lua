-- Headless tests for kb/instruct.lua's `diff_review`-aware rendering
-- (v0.2.25). Run with:
--   nvim --headless -u NONE -l tests/instruct_diff_review_spec.lua
--
-- Covers three injection states:
--   [1] kind = codex, peer with diff_review=true    → section + column
--   [2] kind = claude, peer with diff_review=true   → column only, no section
--   [3] all peers diff_review=false (or missing)    → neither column nor section

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:prepend(project_root)

local pass = 0
local fail = 0
local function ok(name, cond, detail)
  if cond then
    pass = pass + 1
    print(string.format("  PASS  %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

-- Minimal `auto-agents` state stub so kb.instruct's `require("auto-agents")`
-- pulls in a config with a known bootstrap roster. Each test rebuilds
-- this stub before calling ensure().
local function set_bootstrap(entries)
  package.loaded["auto-agents"] = {
    state = {
      config = {
        kb     = { type = "coding" },
        agents = { bootstrap = entries },
      },
      session_project_root = nil,
      session_cwd          = nil,
    },
  }
end

local instruct = require("auto-agents.kb.instruct")

local function fresh_tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local KB_ROOT = "/tmp/instruct-test-kb"

print("\n[1] codex + diff_review=true → section + roster column inlined")
do
  local cwd = fresh_tmpdir()
  set_bootstrap({
    { slot = 2, kind = "codex", name = "codex-a",  kb_scope = "shared", model = "gpt-5", diff_review = true,  configured = true },
    { slot = 3, kind = "codex", name = "codex-b",  kb_scope = "shared", model = "gpt-5", diff_review = false, configured = true },
    -- claude peer should not be visible in the codex roster (filtered by kind)
    { slot = 1, kind = "claude", name = "claude-a", kb_scope = "shared", diff_review = true, configured = true },
  })
  local spec = { slot = 2, kind = "codex", name = "codex-a", kb_scope = "shared", model = "gpt-5", diff_review = true }
  local path = instruct.ensure(spec, KB_ROOT, cwd)
  ok("ensure wrote a file", type(path) == "string" and read_file(path) ~= nil, path)
  local content = read_file(path) or ""
  ok("file is AGENTS.md for codex kind", path == cwd .. "/AGENTS.md", path)
  ok("renders diff_review column header",
    content:find("| diff_review |", 1, true) ~= nil, "missing column header")
  ok("renders diff_review ✓ for codex-a row",
    content:find("| `codex-a` | `shared` | `gpt%-5` | ✓ |") ~= nil
      or content:find("| `codex-a` | `shared` | `gpt-5` | ✓ |", 1, true) ~= nil,
    "missing ✓ in codex-a row")
  ok("renders diff_review – for codex-b row",
    content:find("| `codex-b` | `shared` | `gpt%-5` | – |") ~= nil
      or content:find("| `codex-b` | `shared` | `gpt-5` | – |", 1, true) ~= nil,
    "missing – in codex-b row")
  ok("renders Interactive diff review section",
    content:find("### Interactive diff review", 1, true) ~= nil,
    "missing section header")
  ok("includes \"Safety-First\" lifecycle from shipped doc",
    content:find("\"Safety%-First\" lifecycle") ~= nil
      or content:find('"Safety-First" lifecycle', 1, true) ~= nil,
    "missing inlined lifecycle heading")
  ok("includes Enqueue (`diff_queue`) step",
    content:find("Enqueue %(`diff_queue`%)") ~= nil
      or content:find("Enqueue (`diff_queue`)", 1, true) ~= nil,
    "missing enqueue step")
  ok("does NOT include the source HTML provenance comment from the shipped doc",
    content:find("Canonical, plugin-shipped copy", 1, true) == nil,
    "leading HTML comment leaked through")
end

print("\n[2] claude + diff_review=true peer → roster column only, NO section")
do
  local cwd = fresh_tmpdir()
  set_bootstrap({
    { slot = 1, kind = "claude", name = "claude-a",       kb_scope = "shared", model = "claude-opus-4-7", diff_review = true,  configured = true },
    { slot = 5, kind = "claude", name = "claude-b", kb_scope = "shared", model = "claude-opus-4-7", diff_review = false, configured = true },
  })
  local spec = { slot = 1, kind = "claude", name = "claude-a", kb_scope = "shared", model = "claude-opus-4-7", diff_review = true }
  local path = instruct.ensure(spec, KB_ROOT, cwd)
  ok("ensure wrote CLAUDE.md", path == cwd .. "/CLAUDE.md", tostring(path))
  local content = read_file(path) or ""
  ok("renders diff_review column for claude roster",
    content:find("| diff_review |", 1, true) ~= nil, "column missing")
  ok("does NOT render the Interactive diff review section for claude",
    content:find("### Interactive diff review", 1, true) == nil,
    "section leaked into claude file — claude should use ws-mcp openDiff, not the mailbox protocol")
  ok("does NOT inline the shipped lifecycle for claude",
    content:find('"Safety-First" lifecycle', 1, true) == nil,
    "lifecycle leaked into claude file")
end

print("\n[3] no peers opted in → neither column nor section")
do
  local cwd = fresh_tmpdir()
  set_bootstrap({
    { slot = 2, kind = "codex", name = "codex-a", kb_scope = "shared", model = "gpt-5", diff_review = false, configured = true },
    { slot = 3, kind = "codex", name = "codex-b", kb_scope = "shared", model = "gpt-5",                       configured = true },
  })
  local spec = { slot = 2, kind = "codex", name = "codex-a", kb_scope = "shared", model = "gpt-5" }
  local path = instruct.ensure(spec, KB_ROOT, cwd)
  local content = read_file(path) or ""
  ok("no diff_review column in roster when no peer opted in",
    content:find("| diff_review |", 1, true) == nil,
    "column rendered when no peer is opted in")
  ok("no Interactive diff review section when no peer opted in",
    content:find("### Interactive diff review", 1, true) == nil,
    "section leaked when no peer is opted in")
end

print(string.format("\nResults: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end