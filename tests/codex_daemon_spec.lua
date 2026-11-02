-- Headless tests for auto-agents.codex_daemon: a Codex agent with no crew setup is started with
-- --no-daemon when its Codex takes it, so it never runs in Codex's shared daemon under another
-- agent's environment (round 2 N1, item 14 B). Run:
--   nvim --headless -u NONE -l tests/codex_daemon_spec.lua
--
-- Stand-in Codexes are shell scripts on a PATH of their own folder alone: builtins only, and sleep
-- by its full path.
--   [1] a Codex whose --help names --no-daemon gets it; one before it gets nothing
--   [2] unknown refuses, saying why: not found, --help failing, --help hanging past the probe's time
--       (and seen to hang), --version alone answering
--   [3] a failure is never kept: once the same Codex answers, the next probe gives the flag
--   [4] each start reads the Codex it will run: one shim picking another Codex by the folder or by
--       the agent's env, in either order
--   [5] a command that already says --no-daemon, or attaches with --remote, adds nothing and runs
--       no probe
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:prepend(project_root)
package.path = project_root .. "/lua/?.lua;" .. project_root .. "/lua/?/init.lua;" .. package.path
vim.o.swapfile = false

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

local cd = require("auto-agents.codex_daemon")
cd.TIMEOUT_MS = 300

local NEWER = "      --no-daemon   Run without the shared background server"
local OLDER = "      --remote <ADDR>   Connect the TUI to a remote app server endpoint"
local SLEEP = vim.fn.exepath("sleep")

local function script(body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/codex", "w"))
  f:write("#!/bin/sh\n" .. body)
  f:close()
  vim.uv.fs_chmod(dir .. "/codex", tonumber("755", 8))
  return dir
end

local function codex(help)
  return script("case \"$1\" in --version) echo 'codex-cli 0.0.0-test';; --help) printf '%s\\n' '" .. help .. "';; esac\n")
end

-- a folder that exists, as an agent's always does (a spawn in a missing one fails before any probe)
local function folder()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function argv(dir, cwd, extra_env)
  local env = { PATH = dir }
  for k, v in pairs(extra_env or {}) do env[k] = v end
  return cd.argv({ "codex" }, env, cwd or folder())
end

do
  local a = argv(codex(NEWER))
  ok("[1] a Codex that takes --no-daemon gets it", vim.deep_equal(a, { "--no-daemon" }), vim.inspect(a))
  local b = argv(codex(OLDER))
  ok("[1] a Codex before it gets nothing", vim.deep_equal(b, {}), vim.inspect(b))
end

do
  for name, dir in pairs({
    ["not found"] = vim.fn.tempname(),
    ["help fails"] = script("exit 1\n"),
    ["help hangs"] = script("[ \"$1\" = --help ] && exec " .. SLEEP .. " 5\necho codex-cli 0.163.0\n"),
    ["version only"] = script("[ \"$1\" = --version ] && echo codex-cli 0.163.0 && exit 0\nexit 2\n"),
  }) do
    local t0 = vim.uv.hrtime()
    local a, why = argv(dir)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok("[2] " .. name .. ": refused, naming --no-daemon and what to do", a == nil and type(why) == "string"
      and why:find("--no-daemon", 1, true) ~= nil and why:find("start AutoDoc", 1, true) ~= nil, tostring(why))
    ok("[2] " .. name .. ": bounded by the probe's time", ms < 3000, ms)
    if name == "help hangs" then
      ok("[2] the hang was a hang (at least the probe's time), not a failure", ms >= cd.TIMEOUT_MS, ms)
    end
  end
end

do
  for name, failing in pairs({ fails = "exit 1", hangs = "exec " .. SLEEP .. " 5" }) do
    local dir = script("[ \"$1\" = --help ] && [ -f \"${0%/*}/broken\" ] && " .. failing .. "\n"
      .. "case \"$1\" in --version) echo codex-cli 0.163.0;; --help) printf '%s\\n' '" .. NEWER .. "';; esac\n")
    local f = assert(io.open(dir .. "/broken", "w")); f:close()
    local cwd = folder()
    local a = argv(dir, cwd)
    ok("[3] " .. name .. ": refused while its Codex can't be read", a == nil)
    os.remove(dir .. "/broken")
    local b = argv(dir, cwd)
    ok("[3] " .. name .. ", then answering: the flag (the failure wasn't kept)", vim.deep_equal(b, { "--no-daemon" }), vim.inspect(b))
  end
end

do
  local shim = script("if [ -f .codex-newer ] || [ \"$CODEX_PICK\" = newer ]; then v=0.163.0 h='" .. NEWER
    .. "'; else v=0.150.0 h='" .. OLDER .. "'; fi\ncase \"$1\" in --version) echo \"codex-cli $v\";; --help) printf '%s\\n' \"$h\";; esac\n")
  local older, newer = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(older, "p"); vim.fn.mkdir(newer, "p")
  local f = assert(io.open(newer .. "/.codex-newer", "w")); f:close()
  for _, c in ipairs({
    { "the older folder", older, nil, {} },
    { "the newer folder", newer, nil, { "--no-daemon" } },
    { "the older folder again", older, nil, {} },
    { "a profile picking the newer", folder(), { CODEX_PICK = "newer" }, { "--no-daemon" } },
    { "a folder picking none", folder(), nil, {} },
  }) do
    vim.fn.mkdir(c[2], "p")
    local a = argv(shim, c[2], c[3])
    ok("[4] " .. c[1], vim.deep_equal(a, c[4]), vim.inspect(a))
  end
end

do
  local broken = script("exit 1\n")
  local a = cd.argv({ "codex", "--no-daemon" }, { PATH = broken }, folder())
  ok("[5] a command with --no-daemon already adds nothing, no probe", vim.deep_equal(a, {}), vim.inspect(a))
  local b = cd.argv({ "codex", "--remote", "unix:///x.sock" }, { PATH = broken }, folder())
  ok("[5] one attached with --remote adds nothing", vim.deep_equal(b, {}), vim.inspect(b))
end

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
