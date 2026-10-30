-- Headless tests for kb/instruct.lua's crew and editor sections (ADR 1793271500 phase 5, step 3).
-- Run with:
--   nvim --headless -u NONE -l tests/instruct_crew_spec.lua
--
--   [1] nobody cut over and no editor socket: neither section, the mailbox section as before, and
--       the daemon is never asked for the guide (no spawn waits for it)
--   [2] "*": the crew section names every agent, carries the daemon's guide for the spawn's kind
--       verbatim, before the mailbox section, which stays for Neovim's commands
--   [3] a list: the codenames sorted, and mail to anyone else still through outbox/
--   [4] cut over but no guide (no scope held, no answer): no crew section
--   [5] the editor socket serving: the editor section, with the verbs and the grants

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:prepend(project_root)

-- kb/instruct writes through auto-core.fs.atomic (see instruct_diff_review_spec.lua)
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
local core_root = vim.env.AUTO_CORE_ROOT or (plugins_root .. "/auto-core.nvim/main")
if not vim.env.AUTO_CORE_ROOT and vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end
vim.opt.runtimepath:prepend(core_root)

local pass, fail = 0, 0
local function ok(name, cond, detail)
  if cond then
    pass = pass + 1
    io.stdout:write("  PASS  " .. name .. "\n")
  else
    fail = fail + 1
    io.stdout:write("  FAIL  " .. name .. (detail and ("\n        " .. tostring(detail)) or "") .. "\n")
  end
end

local GUIDE = "**Your identity**\n1. At session start, run `autodoc crew whoami`.\n\n**When you're woken**\n1. Run `autodoc mail receive`.\n"

-- the world: the config's cutover, the guide the daemon answers (nil: none), the editor socket's path
local asked, editor_path
local function world(cutover, guide)
  asked = {}
  package.loaded["auto-agents"] = {
    state = {
      config = {
        agents = { bootstrap = {
          { slot = 1, kind = "claude", name = "gold", configured = true },
          { slot = 2, kind = "claude", name = "vision", configured = true },
        } },
        crew = { cutover = cutover },
      },
    },
  }
  package.loaded["auto-agents.crew"] = {
    guide = function(kind)
      asked[#asked + 1] = kind
      return guide
    end,
  }
  package.loaded["auto-agents.editor_socket"] = { path = function() return editor_path end }
end

local instruct = require("auto-agents.kb.instruct")
local KB = { root = "/tmp/instruct-crew-kb", workspace = "kb" }

local function block_for(kind)
  instruct._invalidate_ensure_cache()
  local cwd = vim.fn.tempname()
  vim.fn.mkdir(cwd, "p")
  local path = instruct.ensure({ kind = kind or "claude", name = "gold", slot = 1 }, KB, cwd)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  vim.fn.delete(cwd, "rf")
  return s
end

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- ── [1] nothing cut over, no editor socket ──────────────────────────────────

do
  editor_path = nil
  world({}, GUIDE)
  local s = block_for()
  ok("[1] no crew section", not has(s, "### Crew mail"))
  ok("[1] no editor section", not has(s, "### Neovim's editor"))
  ok("[1] the mailbox section as before", has(s, "### Mailbox protocol") and has(s, "`addressbook` → reachable mailboxes"))
  ok("[1] the daemon isn't asked for the guide", #asked == 0, vim.inspect(asked))
  world(nil, GUIDE)
  block_for()
  ok("[1] nor with no crew table at all", #asked == 0)
end

-- ── [2] every agent cut over ────────────────────────────────────────────────

do
  editor_path = nil
  world("*", GUIDE)
  local s = block_for("antigravity")
  ok("[2] the guide is asked for the spawn's kind", vim.deep_equal(asked, { "antigravity" }), vim.inspect(asked))
  ok("[2] the crew section names every agent", has(s, "### Crew mail (AutoDoc)") and has(s, "Mail to every agent goes through the AutoDoc daemon"))
  ok("[2] it carries the guide verbatim", has(s, GUIDE:gsub("\n+$", "")), s)
  ok("[2] no outbox/ line for the others: there are none", not has(s, "Mail to anyone else"))
  ok("[2] with no crew session, the mailbox", has(s, "Without `$AUTODOC_CREW_CONTEXT`, or when `autodoc crew whoami` fails"))
  local crew_at, mailbox_at = s:find("### Crew mail", 1, true), s:find("### Mailbox protocol", 1, true)
  ok("[2] the crew section comes before the mailbox section, which stays", crew_at and mailbox_at and crew_at < mailbox_at)
end

-- ── [3] some agents cut over ────────────────────────────────────────────────

do
  editor_path = nil
  world({ "vision", "gold", "user" }, GUIDE)
  local s = block_for()
  ok("[3] the codenames, sorted", has(s, "Mail to `gold`, `user` and `vision` goes through the AutoDoc daemon"), s)
  ok("[3] mail to anyone else still through outbox/", has(s, "Mail to anyone else still goes through `outbox/`"))
  world({ "gold" }, GUIDE)
  ok("[3] one codename alone", has(block_for(), "Mail to `gold` goes through"))
end

-- ── [4] cut over, but no guide ──────────────────────────────────────────────

do
  editor_path = nil
  world("*", nil)
  local s = block_for()
  ok("[4] asked, but no crew section without the guide", #asked == 1 and not has(s, "### Crew mail"))
  ok("[4] the mailbox section stays", has(s, "### Mailbox protocol"))
end

-- ── [5] the editor socket ───────────────────────────────────────────────────

do
  editor_path = "/run/user/1000/auto-agents/editor-1.sock"
  world({}, GUIDE)
  local s = block_for()
  ok("[5] the editor section while the socket serves", has(s, "### Neovim's editor")
    and has(s, "When `$AUTODOC_EDITOR` is set, Neovim answers `autodoc --editor <verb>"))
  ok("[5] it names the verbs", has(s, "`editor.workspace`, `editor.buffers`,") and has(s, "`peek`, `diff_queue` and"))
  ok("[5] and the grants", has(s, "the roster entry's `editor_grants`"))
  ok("[5] it is independent of the cutover", not has(s, "### Crew mail") and #asked == 0)
  editor_path = nil
end

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
