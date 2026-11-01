--- auto-agents.crew_server — a crew agent's server, its setup's `server` (a Codex agent's own
--- app-server, the crew MCP server on its command line: `autodoc crew setup --agent-dir`), the
--- host's to run with no orphan left, as AutoDoc's window runs it (tui/agentserver.go):
---   * started before the agent's CLI, in a process group of its own (a detached spawn: setsid), its
---     pid in the agent folder's PID_FILE; the CLI started once its socket is there (READY_MS), and
---     a server that ends first or never listens is stopped and the spawn refused;
---   * stopped when the CLI ends or fails to start: SIGTERM to its group, SIGKILL after STOP_MS, and
---     SIGKILL to what is left of the group once its leader has ended (a child that outlived the
---     SIGTERM);
---   * when it ends first, the agent's terminal is killed (bind), so the CLI, and its session, end;
---   * a Neovim that died leaves its server: the next start in that folder stops it first, by its
---     pid file, when that process's command line still names the folder's socket (a pid reused by
---     anything else is left alone).

local M = {}

-- PID_FILE is the server's pid, in the agent folder's crew folder (0700).
M.PID_FILE = ".autodoc-crew/server.pid"
-- READY_MS bounds the wait for a started server's socket.
M.READY_MS = 10000
-- STOP_MS is how long a stopped server's group has to end after SIGTERM before SIGKILL.
M.STOP_MS = 3000
-- POLL_MS is how often a server's socket, or a stale server's end, is looked for: a server says
-- nothing when it listens, and another Neovim's server ends without telling this one.
M.POLL_MS = 50

local function alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

---stop_stale stops the server a Neovim that died left in the folder: the pid in pid_file, when that
---process's command line still names socket. The pid file goes either way.
---@param pid_file string
---@param socket string
function M.stop_stale(pid_file, socket)
  local pid = tonumber(vim.trim(read(pid_file) or ""))
  if pid and pid > 1 then
    local cmdline = read("/proc/" .. pid .. "/cmdline")
    if cmdline and cmdline:find(socket, 1, true) then
      vim.uv.kill(-pid, "sigterm")
      vim.wait(M.STOP_MS, function() return not alive(pid) end, M.POLL_MS)
      vim.uv.kill(-pid, "sigkill")
    end
  end
  vim.uv.fs_unlink(pid_file)
end

---environ is env over Neovim's own environment, as "K=V" strings: what uv.spawn takes, which
---replaces the environment rather than merging it.
local function environ(env)
  local all = vim.fn.environ()
  for k, v in pairs(env or {}) do all[k] = v end
  local out = {}
  for k, v in pairs(all) do out[#out + 1] = k .. "=" .. v end
  return out
end

---start starts argv in cwd with env (over Neovim's), a stale server of the agent's folder dir
---stopped first, and waits for socket. It answers the server's handle, or nil and why with nothing
---left running. cwd is the agent's working folder (the user's project): Codex gives a thread its
---server's folder, so a server in the agent's own folder would have the agent work there, and
---codex-here, run in the working folder, find no thread of its (rows N, 2026-11-01). Its pid file is
---the agent folder's.
---@param argv string[]
---@param socket string
---@param dir string the agent's folder
---@param env table<string, string>|nil
---@param cwd string|nil the agent's working folder (dir when nil)
---@return table|nil handle, string|nil why
function M.start(argv, socket, dir, env, cwd)
  if type(argv) ~= "table" or #argv == 0 or type(socket) ~= "string" or socket == "" then
    return nil, "the setup gave a server with no command or no socket"
  end
  local pid_file = vim.fs.joinpath(dir, M.PID_FILE)
  M.stop_stale(pid_file, socket)
  local h = { pid_file = pid_file, exited = false }
  local proc, pid = vim.uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2), cwd = cwd or dir, env = environ(env),
    detached = true, -- its own session and process group: stopped whole, never Neovim's
  }, function(code)
    h.exited, h.code = true, code
    if h.proc and not h.proc:is_closing() then h.proc:close() end
    if h.on_exit then vim.schedule(function() h.on_exit(code) end) end
  end)
  if not proc then
    return nil, ("the agent's server (%s): %s"):format(argv[1], tostring(pid))
  end
  h.proc, h.pid = proc, pid
  pcall(vim.fn.mkdir, vim.fs.dirname(pid_file), "p", tonumber("700", 8))
  local fd = vim.uv.fs_open(pid_file, "w", tonumber("600", 8))
  if not fd then
    M.stop(h)
    return nil, "the agent's server's pid file: " .. pid_file
  end
  vim.uv.fs_write(fd, tostring(pid) .. "\n")
  vim.uv.fs_close(fd)
  local ready = vim.wait(M.READY_MS, function() return h.exited or vim.uv.fs_stat(socket) ~= nil end, M.POLL_MS)
  if h.exited then
    M.stop(h)
    return nil, ("the agent's server (%s) ended before it listened on %s"):format(argv[1], socket)
  end
  if not ready then
    M.stop(h)
    return nil, ("the agent's server (%s) didn't listen on %s within %d ms"):format(argv[1], socket, M.READY_MS)
  end
  return h, nil
end

---stop ends the server's group (SIGTERM, then SIGKILL after STOP_MS, and SIGKILL to what is left of
---the group once its leader has ended) and removes its pid file; a second stop is nothing.
---@param h table|nil a handle start answered
function M.stop(h)
  if not h or h.stopped or not h.pid then return end
  h.stopped = true
  h.on_exit = nil -- its end, from here on, is this stop's
  vim.uv.kill(-h.pid, "sigterm")
  if not vim.wait(M.STOP_MS, function() return h.exited end, M.POLL_MS) then
    vim.uv.kill(-h.pid, "sigkill")
    vim.wait(M.STOP_MS, function() return h.exited end, M.POLL_MS)
  end
  -- the leader's end isn't its group's: a child that outlived the SIGTERM is killed too
  vim.uv.kill(-h.pid, "sigkill")
  vim.uv.fs_unlink(h.pid_file)
end

---toml_string is s as a TOML basic string: its backslashes, quotes and control characters escaped,
---nothing else (JSON's `\/`, which an encoder may write, is no TOML escape).
---@param s string
---@return string
local function toml_string(s)
  return '"' .. s:gsub('[\\"%c]', function(c)
    if c == "\\" then return "\\\\" end
    if c == '"' then return '\\"' end
    return ("\\u%04X"):format(c:byte())
  end) .. '"'
end

---move_grants moves an agent's directory grants (permissions' argv: `--add-dir <dir>` repeated, and
---the `-s workspace-write` that makes them writable) from its command to its server's: a Codex TUI
---attached with --remote refuses --add-dir ("configure additional workspace roots on the server",
---codex-cli 0.163.0), so the server gets them as config overrides, sandbox_mode and
---sandbox_workspace_write.writable_roots. cmd loses exactly grant, its last arguments as appended;
---a cmd that doesn't end with them is left as it is, and so is the server.
---@param cmd string[]
---@param grant string[]
---@param server string[]
---@return string[] cmd, string[] server
function M.move_grants(cmd, grant, server)
  local n, g = #cmd, #grant
  if g == 0 or n < g or not vim.deep_equal(vim.list_slice(cmd, n - g + 1, n), grant) then return cmd, server end
  local dirs, mode = {}, nil
  local i = 1
  while i <= g do
    if (grant[i] == "--add-dir") and grant[i + 1] then
      dirs[#dirs + 1] = grant[i + 1]
      i = i + 2
    elseif (grant[i] == "-s" or grant[i] == "--sandbox") and grant[i + 1] then
      mode = grant[i + 1]
      i = i + 2
    else
      return cmd, server -- an argument this doesn't know how to move: nothing is moved
    end
  end
  local out = vim.list_slice(server)
  if mode then vim.list_extend(out, { "-c", "sandbox_mode=" .. toml_string(mode) }) end
  if #dirs > 0 then
    local items = vim.tbl_map(toml_string, dirs)
    vim.list_extend(out, { "-c", "sandbox_workspace_write.writable_roots=[" .. table.concat(items, ", ") .. "]" })
  end
  return vim.list_slice(cmd, 1, n - g), out
end

---with_context gives each MCP server the server's argv configures (`-c mcp_servers.<name>.command=…`)
---the session's context, context (its file's path, $AUTODOC_CREW_CONTEXT), as that server's env: Codex
---starts its MCP servers with a filtered environment, so `autodoc crew mcp` would see neither the
---variable nor, the server running in the agent's working folder, a ./.autodoc-crew/ that names one
---(rows N, 2026-11-01: "no session context"). The path is no secret: the credential is in the 0600
---file. A server already given the variable keeps its own.
---@param argv string[]
---@param context string|nil
---@return string[]
function M.with_context(argv, context)
  if type(context) ~= "string" or context == "" then return argv end
  local out, names, given = vim.list_slice(argv), {}, {}
  for i = 1, #argv - 1 do
    if argv[i] == "-c" then
      local name = argv[i + 1]:match("^mcp_servers%.([%w_%-]+)%.command=")
      if name and not vim.list_contains(names, name) then names[#names + 1] = name end
      local has = argv[i + 1]:match("^mcp_servers%.([%w_%-]+)%.env%.AUTODOC_CREW_CONTEXT=")
      if has then given[has] = true end
    end
  end
  for _, name in ipairs(names) do
    if not given[name] then
      vim.list_extend(out, { "-c", ("mcp_servers.%s.env.AUTODOC_CREW_CONTEXT=%s"):format(name, toml_string(context)) })
    end
  end
  return out
end

---bind ties the server to the agent's terminal: when the server ends first, kill is called (the
---terminal's), so the CLI ends and its session with it. The CLI's end stops the server: the
---caller's on_exit calls stop.
---@param h table
---@param kill fun()
function M.bind(h, kill)
  if not h or h.stopped then return end
  if h.exited then
    kill()
    return
  end
  h.on_exit = function() kill() end
end

return M
