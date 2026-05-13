--- Facade for the diff-review MCP bridge.
---
--- Boots the vendored claudecode.nvim WebSocket server
--- (`auto-agents.mcp.ws-server`) and writes IDE-discovery lockfiles so
--- Claude Code and Codex can attach to the same native diff queue bridge.
---
--- `M.start()` returns the bound WebSocket port, or nil on failure.
---
--- @module 'auto-agents.mcp.server'

local M = {}

local logger = require("auto-agents.logger")
local ws = require("auto-agents.mcp.ws-server")
local lockfile = require("auto-agents.mcp.lockfile")
local codex_lockfile = require("auto-agents.mcp.codex_lockfile")

--- @class MCPServerState
--- @field server any|nil Truthy while the WS server is running
--- @field port number|nil Bound port
--- @field lock_path string|nil Path of the Claude IDE-discovery lockfile
--- @field codex_lock_path string|nil Path of the Codex IDE-discovery lockfile
--- @field auth_token string|nil Auth token recorded in the lockfile
M.state = {
  server = nil,
  port = nil,
  lock_path = nil,
  codex_lock_path = nil,
  auth_token = nil,
}

-- Default config the vendored server expects. `port_range` is required
-- (tcp.find_available_port reads it); other fields are referenced by
-- the wider claudecode codebase but the slimmed-down vendored subset
-- only really needs port_range + log_level.
local DEFAULT_CONFIG = {
  port_range = { min = 10000, max = 65535 },
  log_level = "info",
}

--- Start the bridge. Idempotent if already running.
--- @return number|nil port
function M.start()
  if M.state.server then return M.state.port end

  local auth_ok, auth_token = pcall(lockfile.generate_auth_token)
  if not auth_ok or type(auth_token) ~= "string" or #auth_token < 10 then
    logger.error("mcp-server", "failed to generate auth token: " .. tostring(auth_token))
    return nil
  end

  local ok, port_or_err = ws.start(DEFAULT_CONFIG, auth_token)
  if not ok then
    logger.error("mcp-server",
      "ws-server failed to start: " .. tostring(port_or_err))
    return nil
  end
  local port = tonumber(port_or_err)
  if not port then
    logger.error("mcp-server", "ws-server returned non-numeric port")
    ws.stop()
    return nil
  end

  local lock_ok, lock_path = lockfile.create(port, auth_token)
  if not lock_ok then
    logger.error("mcp-server", "lockfile.create failed: " .. tostring(lock_path))
    ws.stop()
    return nil
  end

  local codex_lock_ok, codex_lock_path = codex_lockfile.create(port, auth_token)
  if not codex_lock_ok then
    logger.error("mcp-server", "codex lockfile.create failed: " .. tostring(codex_lock_path))
    pcall(lockfile.remove, port)
    ws.stop()
    return nil
  end

  M.state.server = ws
  M.state.port = port
  M.state.lock_path = lock_path
  M.state.codex_lock_path = codex_lock_path
  M.state.auth_token = auth_token

  logger.info("mcp-server",
    "diff-review bridge ready on ws://127.0.0.1:" .. port ..
    " (claude lockfile " .. lock_path ..
    ", codex lockfile " .. codex_lock_path .. ")")
  return port
end

--- Stop the bridge. Idempotent.
function M.stop()
  if not M.state.server then return end
  if M.state.port then pcall(lockfile.remove, M.state.port) end
  if M.state.port then pcall(codex_lockfile.remove, M.state.port) end
  pcall(ws.stop)
  M.state.server = nil
  M.state.port = nil
  M.state.lock_path = nil
  M.state.codex_lock_path = nil
  M.state.auth_token = nil
  logger.info("mcp-server", "diff-review bridge stopped")
end

return M
