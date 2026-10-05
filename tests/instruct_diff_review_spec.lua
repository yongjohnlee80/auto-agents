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

-- auto-core is a hard dep of auto-agents (v0.2.0+); kb/instruct's
-- write path delegates to `auto-core.fs.atomic.write` as of ADR-0039
-- Batch C, so this spec needs it on the rtp like smoke.lua does.
-- Prefer the sibling `main` worktree; fall back to the plain repo.
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
-- $AUTO_CORE_ROOT overrides the sibling resolution (see tests/run-all.sh).
local core_root = vim.env.AUTO_CORE_ROOT or (plugins_root .. "/auto-core.nvim/main")
if not vim.env.AUTO_CORE_ROOT and vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end
vim.opt.runtimepath:prepend(core_root)

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
local KB = { root = KB_ROOT, workspace = "instruct-test" }

print("\n[1] codex + diff_review=true → section + roster column inlined")
do
  local cwd = fresh_tmpdir()
  set_bootstrap({
    { slot = 2, kind = "codex", name = "codex-a",  model = "gpt-5", diff_review = true,  configured = true },
    { slot = 3, kind = "codex", name = "codex-b",  model = "gpt-5", diff_review = false, configured = true },
    -- claude peer should not be visible in the codex roster (filtered by kind)
    { slot = 1, kind = "claude", name = "claude-a", diff_review = true, configured = true },
  })
  local spec = { slot = 2, kind = "codex", name = "codex-a", model = "gpt-5", diff_review = true }
  local path = instruct.ensure(spec, KB, cwd)
  ok("ensure wrote a file", type(path) == "string" and read_file(path) ~= nil, path)
  local content = read_file(path) or ""
  ok("file is AGENTS.md for codex kind", path == cwd .. "/AGENTS.md", path)
  ok("renders diff_review column header",
    content:find("| diff_review |", 1, true) ~= nil, "missing column header")
  ok("renders diff_review ✓ for codex-a row",
    content:find("| `codex-a` | `gpt-5` | ✓ |", 1, true) ~= nil,
    "missing ✓ in codex-a row")
  ok("renders diff_review – for codex-b row",
    content:find("| `codex-b` | `gpt-5` | – |", 1, true) ~= nil,
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

  -- v0.2.26: preamble now gates on env var, not "look up your row"
  ok("preamble references AUTO_AGENTS_DIFF_REVIEW env var",
    content:find("$AUTO_AGENTS_DIFF_REVIEW", 1, true) ~= nil,
    "preamble missing AUTO_AGENTS_DIFF_REVIEW gate")
  ok("preamble references runtime-identity sidecar fallback for resumed sessions",
    content:find("$AUTO_AGENTS_RUNTIME_IDENTITY_PATH", 1, true) ~= nil,
    "preamble missing sidecar fallback")
  ok("preamble no longer asks agent to look up its own row",
    content:find("look up your own row", 1, true) == nil,
    "stale 'look up your own row' instruction leaked through")
end

print("\n[2] claude + diff_review=true peer → roster column only, NO section")
do
  local cwd = fresh_tmpdir()
  set_bootstrap({
    { slot = 1, kind = "claude", name = "claude-a",       model = "claude-opus-4-7", diff_review = true,  configured = true },
    { slot = 5, kind = "claude", name = "claude-b", model = "claude-opus-4-7", diff_review = false, configured = true },
  })
  local spec = { slot = 1, kind = "claude", name = "claude-a", model = "claude-opus-4-7", diff_review = true }
  local path = instruct.ensure(spec, KB, cwd)
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
    { slot = 2, kind = "codex", name = "codex-a", model = "gpt-5", diff_review = false, configured = true },
    { slot = 3, kind = "codex", name = "codex-b", model = "gpt-5",                       configured = true },
  })
  local spec = { slot = 2, kind = "codex", name = "codex-a", model = "gpt-5" }
  local path = instruct.ensure(spec, KB, cwd)
  local content = read_file(path) or ""
  ok("no diff_review column in roster when no peer opted in",
    content:find("| diff_review |", 1, true) == nil,
    "column rendered when no peer is opted in")
  ok("no Interactive diff review section when no peer opted in",
    content:find("### Interactive diff review", 1, true) == nil,
    "section leaked when no peer is opted in")
end

print("\n[4] runtime_identity.build_record stamps diff_review (v0.2.26)")
do
  -- build_record requires auto-core for instance_id + full_id; emulate
  -- those two surfaces with a minimal stub so the test doesn't need a
  -- real auto-core install on the runtimepath.
  package.loaded["auto-core"] = {
    mailbox = { get_instance_id = function() return "test-instance-id" end },
  }
  package.loaded["auto-core.mailbox.path"] = {
    full_id = function(bare) return bare .. ":test-instance-id" end,
  }
  -- Force a re-require so our stubs are honored even if the module was
  -- loaded earlier in this test run.
  package.loaded["auto-agents.runtime_identity"] = nil
  local ri = require("auto-agents.runtime_identity")

  local r_true = ri.build_record(2, "codex-a", "/tmp/tr", "/tmp/tr/agent:codex-a", "test", 99999, true)
  ok("build_record(diff_review=true) → record.diff_review == true",
    r_true.diff_review == true, tostring(r_true.diff_review))

  local r_false = ri.build_record(3, "codex-b", "/tmp/tr", nil, "test", nil, false)
  ok("build_record(diff_review=false) → record.diff_review == false",
    r_false.diff_review == false, tostring(r_false.diff_review))

  local r_nil = ri.build_record(4, "codex-c", "/tmp/tr", nil, "test", nil, nil)
  ok("build_record(diff_review=nil) → record.diff_review == false (default off)",
    r_nil.diff_review == false, tostring(r_nil.diff_review))

  -- Round-trip through atomic write + read so we verify the field
  -- survives JSON encode/decode (resumed-agent recovery path).
  local sidecar_path = vim.fn.tempname() .. ".json"
  local wok, werr = ri.write(sidecar_path, r_true)
  ok("ri.write(sidecar) ok", wok == true, tostring(werr))
  local decoded, derr = ri.read(sidecar_path)
  ok("ri.read returns the record back", type(decoded) == "table", tostring(derr))
  ok("sidecar JSON round-trip preserves diff_review=true",
    decoded and decoded.diff_review == true,
    decoded and tostring(decoded.diff_review) or "decoded is nil")
end

print("\n[5] KB v2 managed block (ADR 1791209946 §2.4)")
do
  local function block_of(content)
    return content:match("<!%-%- auto%-agents:begin %-%->(.-)<!%-%- auto%-agents:end %-%->") or ""
  end
  local function kb_part(block)
    return block:match("### Knowledge base\n(.-)\n### ") or ""
  end
  set_bootstrap({
    { slot = 1, kind = "claude", name = "claude-a", model = "claude-opus-4-7", diff_review = true, configured = true },
    { slot = 5, kind = "claude", name = "claude-b", model = "claude-opus-4-7", configured = true },
  })
  local spec = { slot = 1, kind = "claude", name = "claude-a", model = "claude-opus-4-7", diff_review = true }

  -- With a primary that names a workspace.
  local cwd = fresh_tmpdir()
  local block = block_of(read_file(instruct.ensure(spec, KB, cwd)) or "")
  local part = kb_part(block)
  local bullets = {}
  for l in part:gmatch("[^\n]+") do bullets[#bullets + 1] = l end
  ok("KB part is exactly three lines", #bullets == 3, vim.inspect(bullets))
  ok("line 1: the KB root",
    (bullets[1] or ""):find("`" .. KB_ROOT .. "`", 1, true) ~= nil
      and (bullets[1] or ""):find("$AUTO_AGENTS_KB_ROOT", 1, true) ~= nil, bullets[1])
  ok("line 2: the AutoDoc workspace",
    (bullets[2] or ""):find("`instruct-test`", 1, true) ~= nil
      and (bullets[2] or ""):find("$AUTODOC_WORKSPACE", 1, true) ~= nil, bullets[2])
  ok("line 3: read <root>/AGENTS.md",
    (bullets[3] or ""):find("Read `" .. KB_ROOT .. "/AGENTS.md`", 1, true) ~= nil, bullets[3])
  ok("roster has no KB-scope column", block:find("KB scope", 1, true) == nil)
  ok("roster header is Slot | Name | Model | diff_review",
    block:find("| Slot | Name | Model | diff_review |", 1, true) ~= nil)
  ok("no `append to log.md` rule", block:find("log.md", 1, true) == nil)
  ok("no agents/<your-name>/ folder", block:find("agents/<your-name>", 1, true) == nil)
  ok("no KB READ/WRITE/SCOPE env vars",
    block:find("KB_READ", 1, true) == nil and block:find("KB_WRITE", 1, true) == nil
      and block:find("KB_SCOPE", 1, true) == nil)
  ok("no KB types", block:find("KB type", 1, true) == nil)
  ok("mailbox protocol kept", block:find("### Mailbox protocol", 1, true) ~= nil
    and block:find("$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC", 1, true) ~= nil)
  ok("todo protocol kept", block:find("### Todo handling", 1, true) ~= nil
    and block:find("$AUTO_AGENTS_TODOS_CONVENTION_DOC", 1, true) ~= nil
    and block:find(":AutoAgentsMigrateKbTodos --apply", 1, true) ~= nil)
  ok("model preference kept", block:find("### Model preference", 1, true) ~= nil)

  -- A primary imported before it was given a workspace.
  cwd = fresh_tmpdir()
  part = kb_part(block_of(read_file(instruct.ensure(spec, { root = KB_ROOT }, cwd)) or ""))
  ok("no workspace: line 2 says none is named",
    part:find("none named yet", 1, true) ~= nil, part)

  -- No primary.
  cwd = fresh_tmpdir()
  block = block_of(read_file(instruct.ensure(spec, nil, cwd)) or "")
  part = kb_part(block)
  ok("no primary: the block says to ask the user",
    part:find("no primary KB", 1, true) ~= nil and part:find("Ask the user", 1, true) ~= nil, part)
  ok("no primary: no KB root line", block:find("$AUTO_AGENTS_KB_ROOT", 1, true) == nil)
  ok("no primary: todo protocol still rendered", block:find("### Todo handling", 1, true) ~= nil)
end

print(string.format("\nResults: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end