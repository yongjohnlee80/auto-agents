--- Tests for auto-agents.crew_server: a crew agent's server (a Codex agent's own app-server), run
--- by the host with no orphan left, as AutoDoc's window runs it (tui/agentserver.go). Run with:
---   nvim --headless -u NONE -l tests/crew_server_spec.lua
---
---   [1] a started server is waited for until its socket is there, runs in a process group of its
---       own (never Neovim's), has its pid in the folder's pid file; stopping it ends its group and
---       removes the file; a second stop is nothing
---  [1b] the server runs in the agent's working folder (Codex gives a thread its server's folder),
---       its pid file the agent folder's
---   [2] a server that never listens is stopped and refused, its pid file removed, nothing left
---   [3] a server that ends before it listens is refused
---   [4] a stale server (its pid file, its command line naming the socket) is stopped before the
---       next starts; a pid the file names that is another process now is left alone
---   [5] a stop ends the whole group: a child that ignores SIGTERM is killed once the leader ends
---   [6] bind: the server's end calls the terminal's kill; a stopped server's end doesn't
---   [7] move_grants: the agent's directory grants (--add-dir, -s) leave its command, which ends
---       with them, for its server's config (sandbox_mode, sandbox_workspace_write.writable_roots,
---       TOML strings); grants not at its end, or an argument it can't move, move nothing
---   [8] with_context: each MCP server the argv configures gets the session's context file as its
---       env (Codex starts MCP servers with a filtered environment); one already given keeps its own
---
--- The fake server stays a shell for as long as it runs, so its command line names its socket, as
--- a real one's does (an `exec sleep` would put sleep's command line in its place).

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:prepend(project_root)
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

local server = require("auto-agents.crew_server")
server.STOP_MS, server.POLL_MS = 1000, 20

local function folder()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(dir, ".autodoc-crew"), "p", tonumber("700", 8))
  return dir, vim.fs.joinpath(dir, "codex.sock")
end

-- fake is a server's argv that makes socket (a file stands in) and runs until stopped, naming
-- socket on its command line for as long as it runs; never: it never makes it
local function fake(socket, listens)
  local script = listens and 'touch "$1"; while :; do sleep 1; done' or "while :; do sleep 1; done"
  return { "sh", "-c", script, "sh", socket }
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- naming are the live (not zombie) processes whose command line names s
local function naming(s)
  local out = {}
  for name, t in vim.fs.dir("/proc") do
    if t == "directory" and name:match("^%d+$") then
      local cmd = read("/proc/" .. name .. "/cmdline")
      local stat = read("/proc/" .. name .. "/stat") or ""
      if cmd and cmd:find(s, 1, true) and not stat:find("%) Z ") then out[#out + 1] = tonumber(name) end
    end
  end
  return out
end

local function pgid_of(pid)
  local stat = read("/proc/" .. pid .. "/stat") or ""
  -- field 5 of stat, after the parenthesized command
  local after = stat:match("%) (.*)$") or ""
  local fields = vim.split(after, " ", { plain = true })
  return tonumber(fields[3])
end

local function alive(pid) return vim.uv.kill(pid, 0) == 0 end
local function eventually(cond) return vim.wait(5000, cond, 20) end

-- ── [1] ────────────────────────────────────────────────────────────────
do
  local dir, socket = folder()
  local h, why = server.start(fake(socket, true), socket, dir, {})
  ok("[1] a server that listens is started", h ~= nil, why)
  if h then
    local pid = h.pid
    ok("[1] in a process group of its own, never Neovim's", pgid_of(pid) == pid and pgid_of(pid) ~= pgid_of(vim.uv.os_getpid()),
      ("pgid %s, pid %d, Neovim's %s"):format(tostring(pgid_of(pid)), pid, tostring(pgid_of(vim.uv.os_getpid()))))
    ok("[1] its pid in the folder's pid file", vim.trim(read(vim.fs.joinpath(dir, server.PID_FILE)) or "") == tostring(pid))
    server.stop(h)
    ok("[1] stopped: it ends", eventually(function() return not alive(pid) end))
    ok("[1] stopped: its pid file is gone", vim.uv.fs_stat(vim.fs.joinpath(dir, server.PID_FILE)) == nil)
    server.stop(h)
    ok("[1] a second stop is nothing", true)
  end
end

-- ── [1b] the server runs in the agent's working folder ─────────────────────
do
  local dir, socket = folder()
  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  local h = server.start(fake(socket, true), socket, dir, {}, work)
  local cwd = h and vim.uv.fs_readlink("/proc/" .. h.pid .. "/cwd")
  ok("[1b] the server runs in the agent's working folder, its pid file in the agent's folder",
    cwd == vim.uv.fs_realpath(work) and vim.uv.fs_stat(vim.fs.joinpath(dir, server.PID_FILE)) ~= nil, vim.inspect(cwd))
  server.stop(h)
end

-- ── [2] ────────────────────────────────────────────────────────────────
do
  local saved = server.READY_MS
  server.READY_MS = 300
  local dir, socket = folder()
  local h, why = server.start(fake(socket, false), socket, dir, {})
  server.READY_MS = saved
  ok("[2] a server that never listens is refused", h == nil and why and why:find("didn't listen") ~= nil, why)
  ok("[2] its pid file is removed", vim.uv.fs_stat(vim.fs.joinpath(dir, server.PID_FILE)) == nil)
  ok("[2] nothing of it is left", eventually(function() return #naming(socket) == 0 end), vim.inspect(naming(socket)))
end

-- ── [3] ────────────────────────────────────────────────────────────────
do
  local dir, socket = folder()
  local h, why = server.start({ "sh", "-c", "exit 3", "sh", socket }, socket, dir, {})
  ok("[3] a server that ends before it listens is refused", h == nil and why and why:find("ended before it listened") ~= nil, why)
end

-- ── [4] ────────────────────────────────────────────────────────────────
do
  local dir, socket = folder()
  local function spawn(argv)
    local proc, pid = vim.uv.spawn(argv[1], { args = vim.list_slice(argv, 2), detached = true }, function() end)
    return proc, pid
  end
  local _, stale = spawn(fake(socket, false))
  vim.wait(200, function() return false end, 20) -- past any exec: the fixture's premise holds for good
  ok("[4] the stale fake names its socket", vim.list_contains(naming(socket), stale), vim.inspect(naming(socket)))
  local pid_file = vim.fs.joinpath(dir, server.PID_FILE)
  vim.fn.writefile({ tostring(stale) }, pid_file)
  local h = server.start(fake(socket, true), socket, dir, {})
  ok("[4] a stale server is stopped before the next starts", eventually(function() return not alive(stale) end))
  server.stop(h)

  local _, other = spawn({ "sleep", "300" }) -- a pid the file names that is no server of this folder
  vim.fn.writefile({ tostring(other) }, pid_file)
  local h2 = server.start(fake(socket, true), socket, dir, {})
  ok("[4] another process the pid file names is left alone", alive(other))
  server.stop(h2)
  vim.uv.kill(-other, "sigkill")
end

-- ── [5] ────────────────────────────────────────────────────────────────
do
  local dir, socket = folder()
  local child = [[sh -c 'trap "" TERM; touch "$1"; while :; do sleep 1; done' child "$1" & while :; do sleep 1; done]]
  local h, why = server.start({ "sh", "-c", child, "sh", socket }, socket, dir, {})
  ok("[5] the server with a TERM-ignoring child starts", h ~= nil, why)
  if h then
    local pgid = h.pid
    server.stop(h)
    ok("[5] its whole group ends: the child too", eventually(function() return #naming(socket) == 0 end), vim.inspect(naming(socket)))
    vim.uv.kill(-pgid, "sigkill")
  end
end

-- ── [6] ────────────────────────────────────────────────────────────────
do
  local dir, socket = folder()
  local h = server.start(fake(socket, true), socket, dir, {})
  local killed = 0
  server.bind(h, function() killed = killed + 1 end)
  vim.uv.kill(-h.pid, "sigterm") -- the server ends on its own
  ok("[6] the server's end kills the agent's terminal", eventually(function() return killed == 1 end), "killed " .. killed)
  server.stop(h)

  local dir2, socket2 = folder()
  local h2 = server.start(fake(socket2, true), socket2, dir2, {})
  local killed2 = 0
  server.bind(h2, function() killed2 = killed2 + 1 end)
  server.stop(h2) -- the CLI ended first: its stop is no end of the server's to answer
  vim.wait(300, function() return false end, 20)
  ok("[6] a stopped server's end kills nothing", killed2 == 0, "killed " .. killed2)
end

-- ── [7] the grants move to the server ──────────────────────────────────
do
  local grant = { "--add-dir", "/m/box", "--add-dir", '/kb "x"', "-s", "workspace-write" }
  local cmd = { "codex", "--model", "m", unpack(grant) }
  local c, sv = server.move_grants(cmd, grant, { "codex", "app-server", "--listen", "unix:///a/codex.sock" })
  ok("[7] the agent's command loses its grants (a TUI on --remote refuses --add-dir)",
    vim.deep_equal(c, { "codex", "--model", "m" }), vim.inspect(c))
  ok("[7] the server gets them as config: the sandbox mode, then the writable roots (TOML strings)",
    vim.deep_equal(sv, { "codex", "app-server", "--listen", "unix:///a/codex.sock",
      "-c", 'sandbox_mode="workspace-write"', "-c", 'sandbox_workspace_write.writable_roots=["/m/box", "/kb \\"x\\""]' }),
    vim.inspect(sv))
  local c2, sv2 = server.move_grants({ "codex", "--add-dir", "/a", "--remote", "u" }, { "--add-dir", "/a" }, { "codex", "app-server" })
  ok("[7] grants that aren't the command's last arguments are left, and the server unchanged",
    vim.deep_equal(c2, { "codex", "--add-dir", "/a", "--remote", "u" }) and vim.deep_equal(sv2, { "codex", "app-server" }))
  local c3, sv3 = server.move_grants({ "codex", "--weird", "x" }, { "--weird", "x" }, { "codex", "app-server" })
  ok("[7] an argument it doesn't know how to move: nothing moves",
    vim.deep_equal(c3, { "codex", "--weird", "x" }) and vim.deep_equal(sv3, { "codex", "app-server" }))
end

-- ── [8] the MCP servers get the session's context ──────────────────────────
do
  local argv = { "codex", "app-server", "--listen", "unix:///a/codex.sock",
    "-c", 'mcp_servers.autodoc.command="/bin/autodoc"', "-c", 'mcp_servers.autodoc.args=["crew","mcp"]',
    "-c", 'mcp_servers.other.command="/x"', "-c", 'mcp_servers.other.env.AUTODOC_CREW_CONTEXT="/own"' }
  local out = server.with_context(argv, '/p/.auto-agents/crew/.autodoc-crew/s1')
  ok("[8] each MCP server is given the session's context as its env (Codex filters theirs)",
    vim.list_contains(out, 'mcp_servers.autodoc.env.AUTODOC_CREW_CONTEXT="/p/.auto-agents/crew/.autodoc-crew/s1"'), vim.inspect(out))
  ok("[8] a server already given one keeps its own, nothing added twice",
    #vim.tbl_filter(function(a) return a:find("mcp_servers.other.env", 1, true) ~= nil end, out) == 1
      and #out == #argv + 2, vim.inspect(out))
  ok("[8] no context: the argv as it was", vim.deep_equal(server.with_context(argv, nil), argv))
end

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
vim.cmd(fail == 0 and "qa!" or "cq!")
