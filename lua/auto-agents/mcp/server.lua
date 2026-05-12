--- Minimal first-party MCP server for auto-agents (SSE over HTTP)
--- Designed for compatibility with Claude Code and other MCP-aware agents.
---
--- @module 'auto-agents.mcp.server'

local M = {}

local logger = require("auto-agents.logger")

--- @class MCPServerState
--- @field server any|nil The TCP server handle (libuv)
--- @field port number|nil The port the server is listening on
--- @field clients table<any, MCPSSEClient> Connected SSE clients
--- @field handlers table<string, function> Registered tool/method handlers
M.state = {
  server = nil,
  port = nil,
  clients = {},
  handlers = {},
}

--- @class MCPSSEClient
--- @field tcp any The TCP connection handle
--- @field id string Unique ID for this client
--- @field response_started boolean Whether HTTP headers have been sent

--- Start the MCP server
--- @param port? number Port to listen on (0 for random)
--- @return number|nil port The actual port bound
function M.start(port)
  if M.state.server then
    return M.state.port
  end

  local server = vim.loop.new_tcp()
  local address = "127.0.0.1"
  port = port or 0

  local ok, err = server:bind(address, port)
  if not ok then
    logger.error("mcp-server", "Failed to bind to " .. address .. ":" .. port .. ": " .. err)
    return nil
  end

  local actual_port = server:getsockname().port

  server:listen(128, function(listen_err)
    if listen_err then
      logger.error("mcp-server", "Listen error: " .. listen_err)
      return
    end

    local client_tcp = vim.loop.new_tcp()
    server:accept(client_tcp)
    M._handle_connection(client_tcp)
  end)

  M.state.server = server
  M.state.port = actual_port
  M.state.clients = {}

  logger.info("mcp-server", "MCP bridge started on http://127.0.0.1:" .. actual_port)
  
  -- Register default tools
  M.register_tool(require("auto-agents.agent.adapters.tools.open_diff"))

  return actual_port
end

--- Stop the MCP server
function M.stop()
  if not M.state.server then return end

  for _, client in pairs(M.state.clients) do
    if client.tcp then
      client.tcp:close()
    end
  end
  M.state.clients = {}

  M.state.server:close()
  M.state.server = nil
  M.state.port = nil
  logger.info("mcp-server", "MCP bridge stopped")
end

--- Register a tool handler
--- @param tool table { name, schema, handler, requires_coroutine? }
function M.register_tool(tool)
  M.state.handlers["tools/call/" .. tool.name] = tool.handler
  -- Also register the tool discovery handler
  M.state.handlers["tools/list"] = function()
    return {
      tools = {
        {
          name = tool.name,
          description = tool.schema.description,
          inputSchema = tool.schema.inputSchema,
        }
      }
    }
  end
end

--- Handle a new TCP connection
--- @param tcp any
function M._handle_connection(tcp)
  local client_id = tostring(tcp)
  local client = {
    tcp = tcp,
    id = client_id,
    response_started = false,
    buffer = "",
  }

  tcp:read_start(function(err, data)
    if err or not data then
      M._remove_client(client_id)
      return
    end

    client.buffer = client.buffer .. data
    M._process_buffer(client)
  end)
end

--- Remove a client and close its connection
--- @param client_id string
function M._remove_client(client_id)
  local client = M.state.clients[client_id]
  if client then
    if client.tcp and not client.tcp:is_closing() then
      client.tcp:close()
    end
    M.state.clients[client_id] = nil
  end
end

--- Process the received data buffer for a client
--- @param client MCPSSEClient
function M._process_buffer(client)
  -- Simple HTTP request parsing
  local header_end = client.buffer:find("\r\n\r\n")
  if not header_end then return end

  local headers = client.buffer:sub(1, header_end)
  local body = client.buffer:sub(header_end + 4)

  local method, path = headers:match("^(%w+)%s+([^%s]+)%s+HTTP")
  
  if method == "GET" and path == "/sse" then
    -- Start SSE stream
    M.state.clients[client.id] = client
    client.response_started = true
    local response = "HTTP/1.1 200 OK\r\n" ..
                     "Content-Type: text/event-stream\r\n" ..
                     "Cache-Control: no-cache\r\n" ..
                     "Connection: keep-alive\r\n\r\n"
    client.tcp:write(response)
    -- Send initial connection event
    M._send_sse(client, { jsonrpc = "2.0", method = "notifications/initialized" })
    client.buffer = "" -- Clear buffer
  elseif method == "POST" and path == "/message" then
    -- Handle JSON-RPC message from client
    local content_length = tonumber(headers:match("Content%-Length:%s+(%d+)"))
    if content_length and #body >= content_length then
      local json_payload = body:sub(1, content_length)
      local ok, msg = pcall(vim.json.decode, json_payload)
      if ok then
        M._handle_jsonrpc(client, msg)
      end
      -- Send 202 Accepted
      client.tcp:write("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n")
      client.tcp:close() -- Client closes after POST
    end
  else
    -- Unsupported
    client.tcp:write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    client.tcp:close()
  end
end

--- Send a JSON-RPC message over SSE
--- @param client MCPSSEClient
--- @param msg table
function M._send_sse(client, msg)
  if not client.response_started then return end
  local json = vim.json.encode(msg)
  client.tcp:write("data: " .. json .. "\n\n")
end

--- Handle an incoming JSON-RPC message
--- @param client any (Not used for response since it's via SSE to all or specific)
--- @param msg table
function M._handle_jsonrpc(_, msg)
  if msg.method then
    local handler = M.state.handlers[msg.method]
    if handler then
      -- Run handler in a coroutine
      coroutine.wrap(function()
        local ok, result = pcall(handler, msg.params or {})
        if ok then
          M._broadcast_response(msg.id, result)
        else
          local err_msg = tostring(result)
          if type(result) == "table" then
            err_msg = vim.json.encode(result)
          end
          logger.error("mcp-server", "Handler error: " .. err_msg)
          M._broadcast_error(msg.id, -32603, "Internal error", result)
        end
      end)()
    else
      M._broadcast_error(msg.id, -32601, "Method not found: " .. msg.method)
    end
  end
end

--- Broadcast a JSON-RPC response to all SSE clients
--- @param id any
--- @param result any
function M._broadcast_response(id, result)
  local msg = {
    jsonrpc = "2.0",
    id = id,
    result = result,
  }
  for _, client in pairs(M.state.clients) do
    M._send_sse(client, msg)
  end
end

--- Broadcast a JSON-RPC error to all SSE clients
--- @param id any
--- @param code number
--- @param message string
--- @param data? any
function M._broadcast_error(id, code, message, data)
  local msg = {
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
      data = data,
    },
  }
  for _, client in pairs(M.state.clients) do
    M._send_sse(client, msg)
  end
end

return M
