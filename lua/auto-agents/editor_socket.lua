---auto-agents.editor_socket: Neovim's editor socket for the agents it starts (ADR 1793271500 phase
---5, Johno's Q5-1 (a)).
---
---AutoDoc's editor protocol (ADR 1792014854), served by Neovim: msgpack-RPC on a unix socket of its
---own, `$XDG_RUNTIME_DIR/auto-agents/editor-<pid>.sock` (a 0700 folder, a 0600 socket), which an
---agent calls with `autodoc --editor <verb> '[params]'`, exactly as an agent of AutoDoc's window
---does. The agent learns where from $AUTODOC_EDITOR, and who it is there from
---$AUTODOC_EDITOR_TOKEN: a secret made when the agent is started, kept in memory, and passed as
---every verb's first parameter. A token names an agent, never a name the caller chooses, so one
---agent can't use another's grants. Like AutoDoc's, the grants keep the user's agents to what each
---was allowed; they're no defense against the user's own hostile programs, which can read another
---process's environment.
---
---  editor.workspace                       {spawn_workspace, workspace_in_use}             none
---  editor.buffers                         [{number, path, modified, current}]             editor.read
---  editor.read [from_line, to_line, buf]  {text, revision}                                editor.read
---  editor.find term [buf]                 [[l1, c1, l2, c2], …]                           editor.read
---  editor.open path                       {opening}                                       commands
---  peek / diff_queue / review.* {args}    the mailbox command's own answer                review (peek: peek)
---
---Positions are 1-based lines and columns (a column is a character), as AutoDoc's are. The mailbox
---commands that act in Neovim (peek, diff_queue, review.*) are served here unchanged: the same
---registered handler, its argument schema checked, so the file mailbox can be retired without them.
local M = {}

-- golib rpc's codes (server/rpc/message.go), and AutoDoc's editor refusal (tui/editorsocket.go).
M.CODE_ACCESS_DENIED = -32001
M.CODE_METHOD_NOT_FOUND = -32601
M.CODE_INVALID_PARAMS = -32602
M.CODE_INTERNAL = -32603
M.CODE_REFUSED = -32097

-- An agent's grants unless its roster entry says otherwise: what any agent could do through the
-- mailbox before (read the page, review, peek a slot), so the move loses nothing.
M.DEFAULT_GRANTS = { "editor.read", "review", "peek" }

-- The longest request a client may send, as a guard against a runaway peer.
M.MAX_REQUEST = 4 * 1024 * 1024

local _s -- { path, server, tokens = token -> agent, grants = agent -> set, spawn_ws = agent -> name }

local function rpc_error(code, message) return { code = code, message = message } end

---socket_dir is the folder the socket lives in: under $XDG_RUNTIME_DIR, else Neovim's run dir.
---@return string
function M.socket_dir()
  local base = vim.env.XDG_RUNTIME_DIR
  if not base or base == "" then base = vim.fn.stdpath("run") end
  return vim.fs.joinpath(base, "auto-agents")
end

---path is the socket being served, or nil.
---@return string|nil
function M.path() return _s and _s.path or nil end

-- ── verbs ───────────────────────────────────────────────────────────────────

-- page_buffer is the buffer a verb acts on: buf when given (refused when not a loaded buffer), else
-- the buffer of the current tab's first ordinary window (not the agents' terminals).
local function page_buffer(buf)
  if buf ~= nil and buf ~= vim.NIL then
    local n = tonumber(buf)
    if not n or not vim.api.nvim_buf_is_valid(n) or not vim.api.nvim_buf_is_loaded(n) then
      return nil, rpc_error(M.CODE_REFUSED, ("no buffer %s"):format(tostring(buf)))
    end
    return n
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].buftype == "" then return b end
  end
  return nil, rpc_error(M.CODE_REFUSED, "no page is open: no ordinary buffer in this tab")
end

local function int_or_nil(v)
  if v == nil or v == vim.NIL then return nil end
  return tonumber(v)
end

local function workspace_of(cwd)
  local ok, session = pcall(require, "autodoc.session")
  if ok and session.workspace_of then return session.workspace_of(cwd) end
  return nil
end

local function in_use()
  return workspace_of(vim.fn.getcwd()) or vim.fn.getcwd()
end

local verbs = {}

verbs["editor.workspace"] = { grant = nil, fn = function(agent)
  return { spawn_workspace = _s.spawn_ws[agent] or vim.NIL, workspace_in_use = in_use() }
end }

verbs["editor.buffers"] = { grant = "editor.read", fn = function()
  local cur = vim.api.nvim_get_current_buf()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and vim.bo[b].buflisted then
      out[#out + 1] = { number = b, path = vim.api.nvim_buf_get_name(b), modified = vim.bo[b].modified, current = b == cur }
    end
  end
  return out
end }

verbs["editor.read"] = { grant = "editor.read", fn = function(_, args)
  local b, err = page_buffer(args[3])
  if not b then return nil, err end
  local count = vim.api.nvim_buf_line_count(b)
  local from, to = int_or_nil(args[1]) or 1, int_or_nil(args[2]) or count
  if from < 1 or to < from then
    return nil, rpc_error(M.CODE_INVALID_PARAMS, ("lines %d to %d: want 1 <= from <= to"):format(from, to))
  end
  local lines = vim.api.nvim_buf_get_lines(b, from - 1, math.min(to, count), false)
  return { text = table.concat(lines, "\n"), revision = vim.api.nvim_buf_get_changedtick(b) }
end }

verbs["editor.find"] = { grant = "editor.read", fn = function(_, args)
  local term = args[1]
  if type(term) ~= "string" or term == "" then
    return nil, rpc_error(M.CODE_INVALID_PARAMS, "param 2: the term to find, a non-empty string")
  end
  local b, err = page_buffer(args[2])
  if not b then return nil, err end
  local out = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    local init = 1
    while true do
      local s, e = line:find(term, init, true)
      if not s then break end
      -- columns are characters, 1-based; the end is the last character's column
      out[#out + 1] = { i, (vim.str_utfindex(line, "utf-32", s - 1)) + 1, i, (vim.str_utfindex(line, "utf-32", e)) }
      init = e + 1
    end
  end
  return out
end }

verbs["editor.open"] = { grant = "commands", fn = function(_, args)
  local path = args[1]
  if type(path) ~= "string" or path == "" then
    return nil, rpc_error(M.CODE_INVALID_PARAMS, "param 2: the path to open, a non-empty string")
  end
  if path:sub(1, 1) ~= "/" then path = vim.fs.joinpath(vim.fn.getcwd(), path) end
  local ok, cerr = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
  if not ok then return nil, rpc_error(M.CODE_REFUSED, tostring(cerr)) end
  return { opening = path }
end }

-- the mailbox commands that act in Neovim, served through their own registered handlers
local bridged = { peek = "peek", diff_queue = "review", ["review.create"] = "review", ["review.list"] = "review",
  ["review.show"] = "review", ["review.validate"] = "review" }

local function bridge(name, agent, args, msgid)
  local ok, commands = pcall(function() return require("auto-core").mailbox.commands end)
  local spec = ok and commands and commands.get(name) or nil
  if not spec or type(spec.handler) ~= "function" then
    return nil, rpc_error(M.CODE_METHOD_NOT_FOUND, name .. " is not registered in this Neovim")
  end
  local a = args[1]
  if a == nil or a == vim.NIL then a = {} end
  if type(a) ~= "table" then return nil, rpc_error(M.CODE_INVALID_PARAMS, "param 2: the command's arguments, an object") end
  if spec.schema and commands.validate_args then
    local vok, verr = commands.validate_args(a, spec.schema)
    if not vok then return nil, rpc_error(M.CODE_INVALID_PARAMS, tostring(verr)) end
  end
  local hok, res = pcall(spec.handler, a, { sender = "agent:" .. agent, sender_bare = agent,
    correlation_id = "editor:" .. tostring(msgid), via = "editor" })
  if not hok then return nil, rpc_error(M.CODE_INTERNAL, tostring(res)) end
  if type(res) == "table" and res.ok == false then
    return nil, rpc_error(M.CODE_REFUSED, ("%s: %s"):format(tostring(res.code or "refused"), tostring(res.error)))
  end
  if type(res) == "table" and res.ok == true then return res.value == nil and vim.NIL or res.value end
  return res == nil and vim.NIL or res
end

for name, grant in pairs(bridged) do
  verbs[name] = { grant = grant, bridged = name }
end

-- ── dispatch ────────────────────────────────────────────────────────────────

---handle answers one request (on the main loop): its result, or nil and an error {code, message}.
---@param method string
---@param params table
---@param msgid integer
---@return any result, table|nil err
function M.handle(method, params, msgid)
  if not _s then return nil, rpc_error(M.CODE_INTERNAL, "the editor socket is not serving") end
  local v = verbs[method]
  if not v then return nil, rpc_error(M.CODE_METHOD_NOT_FOUND, ("no verb %s on Neovim's editor socket"):format(tostring(method))) end
  local token = type(params) == "table" and params[1] or nil
  local agent = type(token) == "string" and _s.tokens[token] or nil
  if not agent then
    return nil, rpc_error(M.CODE_ACCESS_DENIED,
      "param 1 is not an agent's token: only the agents this Neovim started reach it ($AUTODOC_EDITOR_TOKEN)")
  end
  if v.grant and not (_s.grants[agent] or {})[v.grant] then
    return nil, rpc_error(M.CODE_ACCESS_DENIED,
      ("needs %s: not granted to %s (its roster entry's editor_grants)"):format(v.grant, agent))
  end
  local args = {}
  for i = 2, #params do args[i - 1] = params[i] end
  if v.bridged then return bridge(v.bridged, agent, args, msgid) end
  local ok, res, err = pcall(v.fn, agent, args)
  if not ok then return nil, rpc_error(M.CODE_INTERNAL, tostring(res)) end
  if err then return nil, err end
  return res == nil and vim.NIL or res
end

-- serve_client reads msgpack-RPC requests from one connection and answers each on the main loop.
local function serve_client(client)
  -- libmpack's unpacker keeps a partial message's state between calls: each chunk is fed once
  local unpack = vim.mpack.Unpacker()
  local pending = 0 -- bytes of the message not yet complete
  local function close()
    if not client:is_closing() then client:close() end
  end
  local function respond(msgid, err, result)
    if client:is_closing() then return end
    client:write(vim.mpack.encode({ 1, msgid, err or vim.NIL, err and vim.NIL or (result == nil and vim.NIL or result) }))
  end
  client:read_start(function(rerr, chunk)
    if rerr or not chunk then return close() end
    local pos = 1
    while pos <= #chunk do
      local start = pos
      local ok, msg, nextpos = pcall(unpack, chunk, pos)
      if not ok or type(nextpos) ~= "number" or nextpos <= start then return close() end -- not msgpack
      pos = nextpos
      if msg == nil then -- the rest of the chunk began a message: wait for more, within the bound
        pending = pending + (#chunk - start + 1)
        if pending > M.MAX_REQUEST then return close() end
        return
      end
      pending = 0
      if type(msg) == "table" and msg[1] == 0 and type(msg[2]) == "number" and type(msg[3]) == "string" then
        local msgid, method, params = msg[2], msg[3], type(msg[4]) == "table" and msg[4] or {}
        vim.schedule(function()
          local res, err = M.handle(method, params, msgid)
          respond(msgid, err, res)
        end)
      else
        return close() -- not a request: closed, as golib's transport does
      end
    end
  end)
end

---start serves the socket. opts (tests): dir.
---@param opts table|nil
---@return string|nil path, string|nil err
function M.start(opts)
  opts = opts or {}
  if _s then return _s.path end
  local dir = opts.dir or M.socket_dir()
  local made = pcall(vim.fn.mkdir, dir, "p", tonumber("700", 8))
  local st = vim.uv.fs_lstat(dir)
  if not made or not st or st.type ~= "directory" or st.uid ~= vim.uv.getuid()
    or bit.band(st.mode, tonumber("077", 8)) ~= 0 then
    return nil, "no socket folder only this user can reach: " .. dir
  end
  local path = vim.fs.joinpath(dir, ("editor-%d.sock"):format(vim.uv.os_getpid()))
  vim.uv.fs_unlink(path) -- this pid's own, left by a process that held it before
  local server = vim.uv.new_pipe(false)
  local ok, berr = server:bind(path)
  if not ok then
    server:close()
    return nil, "editor socket: " .. tostring(berr)
  end
  vim.uv.fs_chmod(path, tonumber("600", 8))
  server:listen(16, function(lerr)
    if lerr then return end
    local client = vim.uv.new_pipe(false)
    if server:accept(client) then serve_client(client) else client:close() end
  end)
  _s = { path = path, server = server, tokens = {}, grants = {}, spawn_ws = {} }
  return path
end

---stop closes the socket and forgets every token.
function M.stop()
  if not _s then return end
  if not _s.server:is_closing() then _s.server:close() end
  vim.uv.fs_unlink(_s.path)
  _s = nil
end

---agent_env mints agent's token (replacing an older one), records its grants, and answers the
---env its process starts with; nil when the socket isn't serving.
---@param agent string the codename
---@param grants string[]|nil its roster entry's editor_grants; DEFAULT_GRANTS when nil
---@return table<string,string>|nil
function M.agent_env(agent, grants)
  if not _s or type(agent) ~= "string" or agent == "" then return nil end
  M.forget(agent)
  local token = require("auto-agents.crew").run_token()
  local set = {}
  for _, g in ipairs(grants or M.DEFAULT_GRANTS) do set[g] = true end
  _s.tokens[token], _s.grants[agent], _s.spawn_ws[agent] = agent, set, in_use()
  return { AUTODOC_EDITOR = _s.path, AUTODOC_EDITOR_TOKEN = token, AUTODOC_AGENT = agent }
end

---forget drops agent's token: its process ended, so nothing reaches the page in its name.
---@param agent string
function M.forget(agent)
  if not _s then return end
  for t, a in pairs(_s.tokens) do
    if a == agent then _s.tokens[t] = nil end
  end
  _s.grants[agent], _s.spawn_ws[agent] = nil, nil
end

return M
