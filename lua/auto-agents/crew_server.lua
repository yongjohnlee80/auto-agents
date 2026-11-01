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

---start starts argv in dir with env (over Neovim's), a stale server of the folder stopped first,
---and waits for socket. It answers the server's handle, or nil and why with nothing left running.
---@param argv string[]
---@param socket string
---@param dir string the agent's folder
---@param env table<string, string>|nil
---@return table|nil handle, string|nil why
function M.start(argv, socket, dir, env)
  if type(argv) ~= "table" or #argv == 0 or type(socket) ~= "string" or socket == "" then
    return nil, "the setup gave a server with no command or no socket"
  end
  local pid_file = vim.fs.joinpath(dir, M.PID_FILE)
  M.stop_stale(pid_file, socket)
  local h = { pid_file = pid_file, exited = false }
  local proc, pid = vim.uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2), cwd = dir, env = environ(env),
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
