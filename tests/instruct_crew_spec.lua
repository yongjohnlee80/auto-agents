-- Headless tests for kb/instruct.lua's crew and editor sections (ADR 1793271500 phase 5; auto-agents
-- v0.4.0: every message through AutoDoc's crew, no file mailbox). Run with:
--   nvim --headless -u NONE -l tests/instruct_crew_spec.lua
--
--   [1] the crew section, always: every message through AutoDoc's daemon, no file mailbox, what to do
--       with no crew session; no mailbox section and no mailbox env named anywhere
--   [2] the daemon's guide for the spawn's kind, verbatim, inside the crew section; the daemon is
--       asked for the spawn's kind
--   [3] no guide (no scope held, no answer): the crew section's rules still, only the guide left out
--   [4] the editor socket serving: the editor section, with the verbs (todos.* included) and the
--       grants; none without it
--   [5] identity: resolved with `autodoc crew whoami`, never from an env var
--   [6] the model preference resolves <your-name> with `autodoc crew whoami` too
--   [7] the todo rules: the todos.* verbs on the editor socket, and why not a raw daemon assign

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

-- the world: the guide the daemon answers (nil: none), the editor socket's path
local asked, editor_path
local function world(guide)
  asked = {}
  package.loaded["auto-agents"] = {
    state = {
      config = {
        agents = { bootstrap = {
          { slot = 1, kind = "claude", name = "gold", configured = true },
          { slot = 2, kind = "claude", name = "vision", configured = true },
        } },
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

do
  world(nil)
  editor_path = nil
  local s = block_for("claude")
  ok("[1] the crew section is always there", has(s, "### Crew mail (AutoDoc)"))
  ok("[1] every message through the daemon, no file mailbox",
    has(s, "Every message to you, from the user or a peer, goes through AutoDoc's") and has(s, "there is no file mailbox"))
  ok("[1] with no crew session yet: ask again in a minute (Neovim joins it), then tell the user",
    has(s, "no session") and has(s, "context, you started before AutoDoc's daemon answered") and has(s, "ask again in a minute")
      and has(s, "still fails") and has(s, "tell the user"))
  ok("[1] no mailbox section", not has(s, "### Mailbox protocol") and not has(s, "inbox/") and not has(s, "outbox/"))
  ok("[1] no mailbox env, no cutover", not has(s, "AUTO_AGENTS_MAILBOX") and not has(s, "cutover"))
end

do
  world(GUIDE)
  editor_path = nil
  local s = block_for("codex")
  local crew_at, guide_at, todo_at = s:find("### Crew mail", 1, true), s:find(GUIDE:sub(1, 30), 1, true),
    s:find("### Todo handling", 1, true)
  ok("[2] the guide, verbatim, inside the crew section", crew_at and guide_at and todo_at
    and crew_at < guide_at and guide_at < todo_at and has(s, "1. Run `autodoc mail receive`."), s)
  ok("[2] introduced as the daemon's guide", has(s, "The daemon's guide for your CLI:"))
  ok("[2] the daemon was asked for the spawn's kind", #asked == 1 and asked[1] == "codex", vim.inspect(asked))
end

do
  world(nil)
  local s = block_for("claude")
  ok("[3] no guide: the rules still, only the guide left out", has(s, "### Crew mail (AutoDoc)")
    and not has(s, "The daemon's guide for your CLI:"))
end

do
  world(nil)
  editor_path = "/run/user/1000/auto-agents/editor-1.sock"
  local s = block_for("claude")
  ok("[4] the editor section, with the socket's verbs", has(s, "### Neovim's editor")
    and has(s, "`peek`, `diff_queue`,") and has(s, "the `todos.*` verbs,") and has(s, "`editor_grants`"))
  editor_path = nil
  ok("[4] none without the socket", not has(block_for("claude"), "### Neovim's editor"))
end

do
  world(nil)
  local s = block_for("claude")
  ok("[5] identity with `autodoc crew whoami`", has(s, "own identity at runtime with `autodoc crew whoami` (its `codename`;"))
  ok("[6] the model preference resolves the name the same way", has(s, "Resolve `<your-name>` with")
    and has(s, "`autodoc crew whoami` (its `codename`) and write it yourself"))
  ok("[7] the todos verbs on the editor socket", has(s, "`autodoc --editor todos.<verb> '[{…}]'`, the `todos` grant)"))
  ok("[7] and why not a raw daemon assign", has(s, "a raw daemon `todos.assign`") and has(s, "carries no scope and notifies no one"))
end

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
