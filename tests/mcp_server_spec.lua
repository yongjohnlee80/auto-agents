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

print("\n[2] SSE Connection & openDiff Tool")
port = mcp.start()
queue.clear()

local client = vim.loop.new_tcp()
local sse_connected = false
local tool_call_received = false

client:connect("127.0.0.1", port, function(err)
  if err then
    print("  FAIL  connect error: " .. err)
    return
  end

  -- Perform GET /sse
  client:write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

  client:read_start(function(read_err, data)
    if read_err or not data then return end
    
    if data:find("Content%-Type: text/event%-stream") then
      sse_connected = true
    end

    if data:find("notifications/initialized") then
      -- Now perform POST /message to call openDiff
      local params = {
        old_file_path = "/tmp/old.txt",
        new_file_path = "/tmp/new.txt",
        new_file_contents = "new content",
        tab_name = "test-tab",
        _auto_agents_name = "tester"
      }
      local payload = vim.json.encode({
        jsonrpc = "2.0",
        id = 1,
        method = "tools/call/openDiff",
        params = params
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
ok("diff enqueued via tool call", #queue.get_pending() == 1)
ok("queued item has correct agent", queue.get_pending()[1].agent_name == "tester")

-- Cleanup
client:close()
mcp.stop()

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
