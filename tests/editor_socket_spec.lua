--- Tests for auto-agents.editor_socket, Neovim's editor socket (ADR 1793271500 phase 5, Q5-1 (a)).
--- Run with: nvim --headless -u NONE -l tests/editor_socket_spec.lua
---
--- A real unix socket and a real msgpack-RPC client over vim.uv, as `autodoc --editor` speaks it;
--- auto-core's command registry is a stub, so the bridged verbs run a handler the test owns.
---   [1] the socket: a 0600 file in a 0700 folder of this user's; a folder others can reach is refused
---   [2] a verb's first param is the agent's token: an unknown one is refused (access denied), a minted
---       one answers, and a forgotten one is refused again
---   [3] grants: the defaults read the page and review; editor.open needs commands; a roster's own
---       list replaces the defaults
---   [4] editor.read and editor.find on a buffer: text and revision; 1-based character positions
---   [5] the bridged mailbox commands: the registered handler runs with the args and the agent as
---       sender; ok answers its value, a refusal is the editor's refused code, bad args are invalid
---       params, an unregistered one is method-not-found
---   [6] framing: a request split across writes is answered once, two in one write both, and bytes
---       that aren't msgpack close the connection
---   [7] an unknown verb is method-not-found
---   [8] a restart: the old process's late forget, by its own token, leaves the new process's
---       token and grants alone (Juliet #7 r0 F1)

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

-- a stub of auto-core's command registry, for the bridged verbs
local registry, seen = {}, {}
package.loaded["auto-core"] = { mailbox = { commands = {
  get = function(name) return registry[name] end,
  validate_args = function(args, schema)
    for k, t in pairs(schema) do
      if t == "string" and type(args[k]) ~= "string" then return false, "args." .. k .. " must be a string" end
    end
    return true
  end,
} } }

local es = require("auto-agents.editor_socket")

-- conversation sends frames (one string each, written in turn, 30 ms apart when split) and collects
-- every response until want of them came or the connection closed.
local function conversation(path, frames, want)
  local pipe = vim.uv.new_pipe(false)
  local unpack = vim.mpack.Unpacker()
  local got, closed, cerr = {}, false, nil
  pipe:connect(path, function(err)
    if err then cerr, closed = err, true return end
    pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then closed = true return end
      local pos = 1
      while pos <= #chunk do
        local msg, nextpos = unpack(chunk, pos)
        pos = nextpos
        if msg == nil then break end
        got[#got + 1] = msg
      end
    end)
    local i = 0
    local function next_frame()
      i = i + 1
      if not frames[i] then return end
      pipe:write(frames[i])
      local t = vim.uv.new_timer()
      t:start(30, 0, function() t:close(); next_frame() end)
    end
    next_frame()
  end)
  vim.wait(3000, function() return closed or #got >= (want or 1) end, 10)
  if not pipe:is_closing() then pipe:close() end
  return got, closed, cerr
end

local function call(path, method, params)
  local got = conversation(path, { vim.mpack.encode({ 0, 7, method, params }) }, 1)
  local r = got[1]
  if not r then return nil, "no answer" end
  local err = r[3] ~= vim.NIL and r[3] or nil
  local res = r[4] ~= vim.NIL and r[4] or nil
  return res, err
end

local dir = vim.fn.tempname()
local path, serr = es.start({ dir = dir })

-- ── [1] the socket ──────────────────────────────────────────────────────────

do
  local st, dst = path and vim.uv.fs_stat(path), vim.uv.fs_stat(dir)
  ok("[1] the socket is served in its folder", path ~= nil and st ~= nil, tostring(serr))
  ok("[1] the socket is 0600 and its folder 0700",
    st and bit.band(st.mode, 511) == tonumber("600", 8) and dst and bit.band(dst.mode, 511) == tonumber("700", 8),
    st and string.format("%o %o", bit.band(st.mode, 511), bit.band(dst.mode, 511)))
  es.stop()
  local open = vim.fn.tempname()
  vim.fn.mkdir(open, "p", tonumber("755", 8))
  local p2, e2 = es.start({ dir = open })
  ok("[1] a folder others can reach is refused, and nothing is served", p2 == nil and e2 ~= nil and es.path() == nil)
  path = es.start({ dir = dir })
end

-- ── [2] tokens ──────────────────────────────────────────────────────────────

do
  local _, err = call(path, "editor.workspace", { "not-a-token" })
  ok("[2] an unknown token is refused, access denied", err and err.code == es.CODE_ACCESS_DENIED, vim.inspect(err))
  local env = es.agent_env("gold")
  ok("[2] a minted token's env names the socket, the token and the agent",
    env and env.AUTODOC_EDITOR == path and #env.AUTODOC_EDITOR_TOKEN == 64 and env.AUTODOC_AGENT == "gold", vim.inspect(env))
  local res, err2 = call(path, "editor.workspace", { env.AUTODOC_EDITOR_TOKEN })
  ok("[2] it answers editor.workspace", err2 == nil and type(res) == "table" and res.workspace_in_use ~= nil, vim.inspect({ res, err2 }))
  es.forget("gold")
  local _, err3 = call(path, "editor.workspace", { env.AUTODOC_EDITOR_TOKEN })
  ok("[2] a forgotten agent's token is refused", err3 and err3.code == es.CODE_ACCESS_DENIED)
  local again = es.agent_env("gold")
  local _, err4 = call(path, "editor.workspace", { env.AUTODOC_EDITOR_TOKEN })
  ok("[2] a new token for the agent replaces the old one", again.AUTODOC_EDITOR_TOKEN ~= env.AUTODOC_EDITOR_TOKEN
    and err4 and err4.code == es.CODE_ACCESS_DENIED)
end

-- ── [3] grants ──────────────────────────────────────────────────────────────

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha beta", "gamma alpha", "héllo alpha" })

do
  local tok = es.agent_env("dflt").AUTODOC_EDITOR_TOKEN
  local _, err = call(path, "editor.read", { tok })
  ok("[3] the default grants read the page", err == nil, vim.inspect(err))
  local _, oerr = call(path, "editor.open", { tok, "x.md" })
  ok("[3] editor.open needs commands, not granted by default", oerr and oerr.code == es.CODE_ACCESS_DENIED
    and oerr.message:find("commands", 1, true) ~= nil, vim.inspect(oerr))
  local tok2 = es.agent_env("ro", { "commands" }).AUTODOC_EDITOR_TOKEN
  local _, rerr = call(path, "editor.read", { tok2 })
  ok("[3] a roster's own list replaces the defaults", rerr and rerr.code == es.CODE_ACCESS_DENIED)
end

-- ── [4] read and find ───────────────────────────────────────────────────────

do
  local tok = es.agent_env("reader").AUTODOC_EDITOR_TOKEN
  local res = call(path, "editor.read", { tok, 2, 3, buf })
  ok("[4] editor.read answers the lines asked and the buffer's revision",
    res and res.text == "gamma alpha\nhéllo alpha" and res.revision == vim.api.nvim_buf_get_changedtick(buf), vim.inspect(res))
  local all = call(path, "editor.read", { tok })
  ok("[4] with no lines and no buffer: the whole page", all and all.text == "alpha beta\ngamma alpha\nhéllo alpha")
  local _, berr = call(path, "editor.read", { tok, 1, 1, 99999 })
  ok("[4] an unknown buffer is refused", berr and berr.code == es.CODE_REFUSED)
  local found = call(path, "editor.find", { tok, "alpha", buf })
  ok("[4] editor.find answers 1-based character ranges, past a multibyte character",
    found and vim.deep_equal(found, { { 1, 1, 1, 5 }, { 2, 7, 2, 11 }, { 3, 7, 3, 11 } }), vim.inspect(found))
  local _, ferr = call(path, "editor.find", { tok, "" })
  ok("[4] an empty term is invalid params", ferr and ferr.code == es.CODE_INVALID_PARAMS)
end

-- ── [5] the bridged mailbox commands ────────────────────────────────────────

do
  local tok = es.agent_env("reviewer").AUTODOC_EDITOR_TOKEN
  registry["review.list"] = { schema = { repo = "string" }, handler = function(args, ctx)
    seen[#seen + 1] = { args = args, ctx = ctx }
    if args.repo == "nope" then return { ok = false, code = "no_repo", error = "no such repo" } end
    return { ok = true, value = { revisions = { 1, 2 } } }
  end }
  local res, err = call(path, "review.list", { tok, { repo = "golib" } })
  ok("[5] the registered handler answers its value", err == nil and res and vim.deep_equal(res.revisions, { 1, 2 }), vim.inspect({ res, err }))
  ok("[5] it ran with the args and the agent as sender", seen[1] and seen[1].args.repo == "golib"
    and seen[1].ctx.sender == "agent:reviewer" and seen[1].ctx.via == "editor")
  local _, rerr = call(path, "review.list", { tok, { repo = "nope" } })
  ok("[5] a refusal is the editor's refused code, with the command's code and message",
    rerr and rerr.code == es.CODE_REFUSED and rerr.message == "no_repo: no such repo", vim.inspect(rerr))
  local _, verr = call(path, "review.list", { tok, { repo = 3 } })
  ok("[5] args the schema refuses are invalid params", verr and verr.code == es.CODE_INVALID_PARAMS, vim.inspect(verr))
  local _, nerr = call(path, "review.show", { tok, {} })
  ok("[5] a command not registered here is method-not-found", nerr and nerr.code == es.CODE_METHOD_NOT_FOUND)
  local tok2 = es.agent_env("nopeek", { "editor.read" }).AUTODOC_EDITOR_TOKEN
  local _, gerr = call(path, "review.list", { tok2, { repo = "golib" } })
  ok("[5] a bridged verb needs its grant", gerr and gerr.code == es.CODE_ACCESS_DENIED)
end

-- ── [6] framing ─────────────────────────────────────────────────────────────

do
  local tok = es.agent_env("framer").AUTODOC_EDITOR_TOKEN
  local frame = vim.mpack.encode({ 0, 11, "editor.workspace", { tok } })
  local got = conversation(path, { frame:sub(1, 5), frame:sub(6) }, 1)
  ok("[6] a request split across two writes is answered once", #got == 1 and got[1][2] == 11, vim.inspect(got))
  local two = vim.mpack.encode({ 0, 21, "editor.workspace", { tok } }) .. vim.mpack.encode({ 0, 22, "editor.workspace", { tok } })
  local got2 = conversation(path, { two }, 2)
  local ids = {}
  for _, r in ipairs(got2) do ids[#ids + 1] = r[2] end
  table.sort(ids)
  ok("[6] two requests in one write are both answered", vim.deep_equal(ids, { 21, 22 }), vim.inspect(ids))
  local got3, closed = conversation(path, { "\193\193\193 not msgpack" }, 1)
  ok("[6] bytes that aren't msgpack close the connection, unanswered", closed and #got3 == 0)
end

-- ── [7] unknown verbs ───────────────────────────────────────────────────────

do
  local tok = es.agent_env("x").AUTODOC_EDITOR_TOKEN
  local _, err = call(path, "editor.nope", { tok })
  ok("[7] an unknown verb is method-not-found", err and err.code == es.CODE_METHOD_NOT_FOUND)
end

-- ── [8] a restart's late forget (Juliet #7 r0 F1) ───────────────────────────

do
  local t1 = es.agent_env("gold", { "editor.read", "commands" }).AUTODOC_EDITOR_TOKEN
  local t2 = es.agent_env("gold", { "editor.read", "commands" }).AUTODOC_EDITOR_TOKEN -- the restart's
  es.forget("gold", t1) -- the old process's exit, reaped after the new one started
  local res, err = call(path, "editor.read", { t2 })
  ok("[8] the old process's forget leaves the new token working", err == nil and res ~= nil, vim.inspect(err))
  local _, oerr = call(path, "editor.open", { t2, "nowhere-that-exists.md" })
  ok("[8] and its grants", not oerr or oerr.code ~= es.CODE_ACCESS_DENIED, vim.inspect(oerr))
  es.forget("gold", t2)
  local _, gerr = call(path, "editor.read", { t2 })
  ok("[8] its own forget, by its token, revokes it", gerr and gerr.code == es.CODE_ACCESS_DENIED)
end

es.stop()
ok("[1] stop removes the socket", vim.uv.fs_stat(path) == nil)
vim.fn.delete(dir, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
