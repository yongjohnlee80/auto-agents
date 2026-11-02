---auto-agents.codex_daemon: a Codex agent with no crew setup is kept off Codex's shared daemon.
---
---A plain `codex` attaches to Codex's own shared app-server (`codex app-server --managed-daemon`),
---started by whichever agent came first and kept with that one's environment: its commands then
---run under another agent's identity, its editor token and its mail context included (round 2, N1).
---AutoDoc's setup gives a Codex agent its own app-server, or `--no-daemon` (core/crew/setup.go
---codexSetup). With no setup at all (no crew scope held, an AutoDoc without crew setup, or a setup
---that failed), this does the same: a Codex whose `--help` names `--no-daemon` is started with it.
---
---The probe has three answers, as AutoDoc's: takes the flag, lacks it (a Codex before it, with no
---shared daemon to keep off), or unknown (not found, failing, or past its time). Unknown refuses the
---start, saying why: either way of starting it could be wrong. An answer is kept by the binary, its
---time and its `--version` line, read as the start will run it (the agent's env and folder), since a
---shim (mise's) picks the Codex by both; a failure is never kept.
---@module 'auto-agents.codex_daemon'

local M = {}

M.TIMEOUT_MS = 5000 -- each run of the CLI (a mise shim runs mise first)
M.FLAG = "--no-daemon"

---@type table<string, boolean>
local _known = {}

---find is program as a shell in cwd with PATH path finds it: a path is taken as it is (relative to
---cwd); a name, the first executable of that name on path.
---@param program string
---@param path string
---@param cwd string
---@return string|nil
local function find(program, path, cwd)
  if program:find("/", 1, true) then
    local p = program:sub(1, 1) == "/" and program or vim.fs.joinpath(cwd, program)
    return vim.fn.executable(p) == 1 and p or nil
  end
  for d in (path or ""):gmatch("[^:]*") do
    if d == "" then d = "." end
    if d:sub(1, 1) ~= "/" then d = vim.fs.joinpath(cwd, d) end
    local p = vim.fs.joinpath(d, program)
    local st = vim.uv.fs_stat(p)
    if st and st.type == "file" and vim.fn.executable(p) == 1 then return p end
  end
  return nil
end

---run is bin's output for arg, or nil and why.
local function run(bin, arg, env, cwd)
  local ok, res = pcall(function()
    return vim.system({ bin, arg }, { cwd = cwd, env = env, text = true, timeout = M.TIMEOUT_MS }):wait()
  end)
  if not ok then return nil, ("%s %s: %s"):format(bin, arg, tostring(res)) end
  if res.code ~= 0 or res.signal ~= 0 then
    return nil, ("%s %s: exit %s%s"):format(bin, arg, tostring(res.code),
      res.signal ~= 0 and (", signal " .. tostring(res.signal)) or "")
  end
  return res.stdout or ""
end

---takes_flag is whether the Codex program, started in cwd with env (the agent's, over Neovim's),
---takes --no-daemon: true, false, or nil and why when that can't be told.
---@param program string
---@param env table|nil
---@param cwd string
---@return boolean|nil, string|nil
function M.takes_flag(program, env, cwd)
  local path = (env and env.PATH) or vim.env.PATH or ""
  local bin = find(program, path, cwd)
  if not bin then return nil, ("no %s on PATH"):format(program) end
  local st = vim.uv.fs_stat(bin)
  local version = run(bin, "--version", env, cwd)
  local key
  if version and vim.trim(version) ~= "" and st then
    key = table.concat({ bin, tostring(st.mtime.sec), tostring(st.mtime.nsec), vim.trim(version) }, "\0")
    if _known[key] ~= nil then return _known[key] end
  end
  local help, why = run(bin, "--help", env, cwd)
  if not help then return nil, why end
  local has = help:find(M.FLAG, 1, true) ~= nil
  if key then _known[key] = has end
  return has
end

---argv is what a Codex agent with no crew setup adds to its command: { "--no-daemon" } when its
---Codex takes the flag, {} when it predates it, and nil and why when that can't be told (the start
---is then refused). A command that already says --no-daemon, or attaches elsewhere with --remote,
---adds nothing.
---@param cmd string[]
---@param env table|nil
---@param cwd string
---@return string[]|nil, string|nil
function M.argv(cmd, env, cwd)
  for _, a in ipairs(cmd) do
    if a == M.FLAG or a == "--remote" or vim.startswith(a, "--remote=") then return {} end
  end
  local has, why = M.takes_flag(cmd[1], env, cwd)
  if has == nil then
    return nil, ("can't tell whether Codex takes %s, which keeps an agent with no crew setup off Codex's shared daemon (%s): start AutoDoc so it gets a setup, or start it again")
      :format(M.FLAG, why)
  end
  return has and { M.FLAG } or {}
end

---Test seam: forget the kept answers.
function M._reset_for_tests() _known = {} end

return M
