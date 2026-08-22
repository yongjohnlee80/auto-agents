--- Integration tests for the first-party MCP server.
---
--- The transport is the vendored WebSocket stack (`auto-agents.mcp.ws-server`).
--- The original SSE/HTTP bridge this spec was written against was removed by
--- 87e4da4 (2026-05-13, "swap SSE/HTTP bridge for vendored WebSocket stack");
--- the SSE-specific sections were pruned and their still-real invariants —
--- a client can connect, and a tools/call round-trips into the diff queue —
--- reimplemented against the WebSocket handshake + tools dispatch below.
---
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

-- [2]/[3] reimplement the two invariants the pruned SSE/HTTP sections
-- ([2] initialize handshake, [3] tools/call openDiff, [4] Streamable HTTP
-- /mcp) were really guarding — "a client can connect" and "a tools/call
-- round-trips into the diff queue" — against the WebSocket transport that
-- replaced them. Both run in-process against the production modules the
-- ws message loop uses, so they are deterministic (no real sockets, no
-- 2s polling races) and can never silently pass over a dead transport.

print("\n[2] WebSocket handshake — client connects; deleted SSE/HTTP transport stays gone")
do
  local handshake = require("auto-agents.mcp.ws-server.handshake")

  -- POSITIVE — the live "a client can connect" invariant: a well-formed
  -- RFC 6455 upgrade is accepted with a 101 + Sec-WebSocket-Accept.
  local upgrade = table.concat({
    "GET /mcp HTTP/1.1",
    "Host: 127.0.0.1",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version: 13",
    "", "",
  }, "\r\n")
  local up_ok, up_resp = handshake.process_handshake(upgrade)
  ok("valid WebSocket upgrade is accepted", up_ok == true, tostring(up_resp))
  ok("handshake returns 101 Switching Protocols",
    type(up_resp) == "string" and up_resp:find("101 Switching Protocols", 1, true) ~= nil,
    tostring(up_resp))
  ok("handshake returns a Sec-WebSocket-Accept header",
    type(up_resp) == "string" and up_resp:find("Sec%-WebSocket%-Accept:") ~= nil,
    tostring(up_resp))

  -- P6 GUARD — the deleted transport must STAY gone. The exact plain-GET
  -- requests the old spec sent (GET /sse, /message, /mcp with no Upgrade
  -- header) must be rejected at the handshake, never answered with an
  -- event-stream — so a silent reintroduction fails loudly right here.
  for _, path in ipairs({ "/sse", "/message", "/mcp" }) do
    local plain = "GET " .. path .. " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    local ok_plain, resp_plain = handshake.process_handshake(plain)
    ok("plain GET " .. path .. " (old transport) is rejected, not upgraded",
      ok_plain == false
        and type(resp_plain) == "string"
        and resp_plain:find("event%-stream") == nil,
      type(resp_plain) == "string" and resp_plain:match("^[^\r\n]+") or tostring(resp_plain))
  end
end

print("\n[3] tools/call dispatch — openDiff round-trips into the diff queue")
do
  local tools = require("auto-agents.mcp.ws-server.tools.init")
  tools.register_all()
  local queue = require("auto-agents.diff.queue")
  queue.clear()

  -- Keep the enqueue path's scheduled UI pop-up out of a headless run:
  -- stub diff.ui.open() to a no-op so this section stays hermetic.
  local saved_ui = package.loaded["auto-agents.diff.ui"]
  package.loaded["auto-agents.diff.ui"] = { open = function() end }

  -- Drive the REAL tools/call dispatch (handle_invoke) — what the ws
  -- message loop calls — not the handler directly. openDiff is a blocking
  -- tool, so its coroutine yields: a `_deferred` marker is the success
  -- shape, and the queue is populated synchronously before the yield.
  local res = tools.handle_invoke({ id = "fake-client" }, {
    name = "openDiff",
    arguments = {
      old_file_path     = "/tmp/old.txt",
      new_file_path     = "/tmp/new.txt",
      new_file_contents = "new standard content",
      tab_name          = "test-tab",
      _auto_agents_name = "tester-standard",
    },
  })
  ok("tools/call openDiff dispatches as a deferred (blocking) invocation",
    type(res) == "table" and res._deferred == true, vim.inspect(res))

  local pending = queue.get_pending()
  ok("openDiff enqueued exactly one diff", #pending == 1, "count=" .. tostring(#pending))
  ok("queued item carries the tools/call contents",
    pending[1] ~= nil and pending[1].new_contents == "new standard content",
    pending[1] and tostring(pending[1].new_contents))
  ok("queued item is attributed to the explicit agent name",
    pending[1] ~= nil and pending[1].agent_name == "tester-standard",
    pending[1] and tostring(pending[1].agent_name))

  queue.clear()
  package.loaded["auto-agents.diff.ui"] = saved_ui
end

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
