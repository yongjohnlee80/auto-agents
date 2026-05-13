--- Integration tests for first-party MCP server facade.
--- Run with: nvim --headless -u NONE -l tests/mcp_server_spec.lua

-- Find our own path to derive project roots
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
local core_root = plugins_root .. "/auto-core.nvim/main"
if vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  project_root,
  core_root,
  LAZY .. "/plenary.nvim",
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

local mcp = require("auto-agents.mcp.server")
local queue = require("auto-agents.diff.queue")

local pass_count = 0
local fail_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

print("\n[1] Server Start/Stop")
local port = mcp.start()
ok("server started on port", type(port) == "number" and port > 0)
ok("ws port exposed", type(mcp.state.port) == "number" and mcp.state.port == port)
ok("codex lockfile exposed", type(mcp.state.codex_lock_path) == "string" and mcp.state.codex_lock_path:find(".codex/ide", 1, true) ~= nil)
mcp.stop()
ok("server stopped", mcp.state.server == nil)

print("\n[2] WS bridge rejects non-upgrade HTTP")
port = mcp.start()
local client_init = vim.loop.new_tcp()
local rejected = false
client_init:connect("127.0.0.1", port, function(err)
  if err then return end
  client_init:write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
  client_init:read_start(function(_, data)
    if not data then return end
    if data:find("400 Bad Request", 1, true) then
      rejected = true
    end
  end)
end)

-- Wait for async operations
local start_init = vim.loop.now()
while not rejected and (vim.loop.now() - start_init < 2000) do
  vim.wait(100)
end

ok("plain HTTP is rejected by WS bridge", rejected)
client_init:close()
mcp.stop()

print("\n[3] Tool registration still exposes openDiff")
local tools = require("auto-agents.mcp.ws-server.tools.init")
local list = tools.get_tool_list()
local has_open_diff = false
for _, item in ipairs(list) do
  if item.name == "openDiff" then
    has_open_diff = true
  end
end
ok("openDiff is registered", has_open_diff)

print("\n[4] Codex auth header is accepted")
local handshake = require("auto-agents.mcp.ws-server.handshake")
local token = "550e8400-e29b-41d4-a716-446655440000"
local request_with_codex_auth = table.concat({
  "GET /websocket HTTP/1.1",
  "Host: localhost:8080",
  "Upgrade: websocket",
  "Connection: upgrade",
  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
  "Sec-WebSocket-Version: 13",
  "x-codex-code-ide-authorization: " .. token,
  "",
  "",
}, "\r\n")
local auth_ok = handshake.validate_upgrade_request(request_with_codex_auth, token)
ok("Codex auth header passes WS handshake validation", auth_ok == true)

print("\n[5] Queue handler still blocks openDiff")
queue.clear()
local open_diff = require("auto-agents.mcp.ws-server.tools.open_diff")
local co = coroutine.create(function()
  return open_diff.handler({
    old_file_path = "/tmp/old.txt",
    new_file_path = "/tmp/new.txt",
    new_file_contents = "new standard content",
    tab_name = "test-tab",
    _auto_agents_name = "tester-standard",
  })
end)
local ok_resume = coroutine.resume(co)
ok("openDiff coroutine suspended", ok_resume and coroutine.status(co) == "suspended")
ok("diff enqueued via openDiff handler", #queue.get_pending() == 1)
ok("queued item has correct content", queue.get_pending()[1].new_contents == "new standard content")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
