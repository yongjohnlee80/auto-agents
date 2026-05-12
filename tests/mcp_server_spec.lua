--- Integration tests for first-party MCP server (SSE over HTTP)
--- Run with: nvim --headless -u NONE -l auto-agents.nvim/unified-diff-queue/tests/mcp_server_spec.lua

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
mcp.stop()
ok("server stopped", mcp.state.server == nil)

print("\n[2] Standard MCP Handshake (initialize)")
port = mcp.start()
local client_init = vim.loop.new_tcp()
local init_received = false
client_init:connect("127.0.0.1", port, function(err)
  if err then return end
  client_init:write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
  client_init:read_start(function(_, data)
    if not data then return end
    if data:find("notifications/initialized") then
      local payload = vim.json.encode({
        jsonrpc = "2.0",
        id = "init-test",
        method = "initialize",
        params = { protocolVersion = "2024-11-05" }
      })
      local post = vim.loop.new_tcp()
      post:connect("127.0.0.1", port, function()
        post:write("POST /message HTTP/1.1\r\nContent-Length: " .. #payload .. "\r\n\r\n" .. payload, function() post:close() end)
      end)
    end
    if data:find("auto%-agents%-mcp") then
      init_received = true
    end
  end)
end)

-- Wait for async operations
local start_init = vim.loop.now()
while not init_received and (vim.loop.now() - start_init < 2000) do
  vim.wait(100)
end

ok("MCP initialize handshake successful", init_received)
client_init:close()
mcp.stop()

print("\n[3] Standard MCP tools/call (openDiff)")
port = mcp.start()
queue.clear()

local client = vim.loop.new_tcp()
local sse_connected = false
local tool_call_received = false

client:connect("127.0.0.1", port, function(err)
  if err then return end

  -- Perform GET /sse
  client:write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

  client:read_start(function(read_err, data)
    if read_err or not data then return end
    
    if data:find("Content%-Type: text/event%-stream") then
      sse_connected = true
    end

    if data:find("notifications/initialized") then
      -- Finding 2: Standard MCP tools/call shape
      local payload = vim.json.encode({
        jsonrpc = "2.0",
        id = 1,
        method = "tools/call",
        params = {
          name = "openDiff",
          arguments = {
            old_file_path = "/tmp/old.txt",
            new_file_path = "/tmp/new.txt",
            new_file_contents = "new standard content",
            tab_name = "test-tab",
            _auto_agents_name = "tester-standard"
          }
        }
      })
      
      local post_client = vim.loop.new_tcp()
      post_client:connect("127.0.0.1", port, function(post_err)
        if post_err then return end
        local request = "POST /message HTTP/1.1\r\n" ..
                        "Host: 127.0.0.1\r\n" ..
                        "Content-Length: " .. #payload .. "\r\n" ..
                        "\r\n" .. payload
        post_client:write(request, function()
          post_client:close()
        end)
      end)
    end

    if data:find("FILE_SAVED") or data:find("result") then
      tool_call_received = true
    end
  end)
end)

-- Wait for async operations
local timeout = 2000
local start_time = vim.loop.now()
while (not sse_connected or #queue.get_pending() == 0) and (vim.loop.now() - start_time < timeout) do
  vim.wait(100)
end

ok("SSE connected", sse_connected)
ok("diff enqueued via standard tools/call", #queue.get_pending() == 1)
ok("queued item has correct content", queue.get_pending()[1].new_contents == "new standard content")

-- Cleanup
client:close()
mcp.stop()

print("\n[4] Streamable HTTP /mcp (Unified Endpoint)")
port = mcp.start()
local mcp_received = false
local mcp_post_res = nil

local client_mcp = vim.loop.new_tcp()
client_mcp:connect("127.0.0.1", port, function(err)
  if err then return end
  -- Test GET /mcp (SSE)
  client_mcp:write("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
  client_mcp:read_start(function(_, data)
    if data and data:find("notifications/initialized") then
      mcp_received = true
      -- Test POST /mcp (Request-Response)
      local payload = vim.json.encode({
        jsonrpc = "2.0",
        id = "mcp-post-test",
        method = "tools/list"
      })
      local post = vim.loop.new_tcp()
      post:connect("127.0.0.1", port, function()
        post:write("POST /mcp HTTP/1.1\r\nContent-Length: " .. #payload .. "\r\n\r\n" .. payload)
        post:read_start(function(_, post_data)
          if post_data and post_data:find("tools") then
            mcp_post_res = post_data
          end
        end)
      end)
    end
  end)
end)

local start_mcp = vim.loop.now()
while (not mcp_received or not mcp_post_res) and (vim.loop.now() - start_mcp < 2000) do
  vim.wait(100)
end

ok("Streamable HTTP GET /mcp (SSE) successful", mcp_received)
ok("Streamable HTTP POST /mcp (Request-Response) successful", mcp_post_res ~= nil)
client_mcp:close()
mcp.stop()

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
