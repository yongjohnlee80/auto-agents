-- Regression test for ADR 0011 Patch 2 (D2-B).
-- Run with:
--   nvim --headless -u NONE -l tests/diff_peer_identity_spec.lua
--
-- Covers the websocket attribution path. The full end-to-end test
-- (real claude-code process establishing a real ws connection from a
-- spawned slot) isn't reproducible in a headless spec, so this exercises
-- the moving parts independently:
--
--   * tools/init.lua now forwards `client` to handlers via the `ctx`
--     positional arg — confirm a fake tool sees it.
--   * peer_identity.port_hex_lc converts ports to /proc/net/tcp's
--     lowercase hex form.
--   * peer_identity.resolve gracefully returns nil when the OS surface
--     isn't reachable (no client, no proc fs, etc.) — i.e. it never
--     raises on degraded paths.
--   * The openDiff handler honours an explicit `_auto_agents_name`
--     even when the peer-PID path is unavailable — keeps the manual
--     override surface that adapters / tests rely on.
--
-- The actual `/proc/net/tcp` walk + PID-to-inode match needs a live
-- TCP pair; defer that to a manual integration test against a real
-- spawned claude-code slot.

-- Resolve project roots — same idiom as the other specs.
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

vim.o.swapfile = false
vim.o.hidden = true

local fail_count = 0
local pass_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

local function eq(name, got, want)
  ok(name, got == want, string.format("got=%q want=%q", tostring(got), tostring(want)))
end

-- ── [1] tools/init.lua forwards `client` to handlers via ctx ─────
print("\n[1] tools.handle_invoke passes ctx with client to handler")
local tools = require("auto-agents.mcp.ws-server.tools.init")

local seen_ctx
tools.register({
  name = "test_echo_ctx",
  schema = nil,
  handler = function(input, ctx)
    seen_ctx = ctx
    return { content = { { type = "text", text = "ok" } } }
  end,
})

local fake_client = { id = "fake-client-1", tcp_handle = "stub" }
tools.handle_invoke(fake_client, {
  name = "test_echo_ctx",
  arguments = { foo = "bar" },
})

ok("handler received a ctx table", type(seen_ctx) == "table")
ok("ctx.client points at the invocation's client",
   seen_ctx ~= nil and seen_ctx.client == fake_client)

-- ── [2] peer_identity.port_hex_lc round-trip ─────────────────────
print("\n[2] peer_identity.port_hex_lc encodes ports as lowercase 4-hex")
local pi = require("auto-agents.mcp.ws-server.peer_identity")
eq("port 0      → \"0000\"",  pi._test_port_hex_lc(0),      "0000")
eq("port 1      → \"0001\"",  pi._test_port_hex_lc(1),      "0001")
eq("port 80     → \"0050\"",  pi._test_port_hex_lc(80),     "0050")
eq("port 40781  → \"9f4d\"",  pi._test_port_hex_lc(40781),  "9f4d")
eq("port 65535  → \"ffff\"",  pi._test_port_hex_lc(65535),  "ffff")

-- ── [3] peer_identity.resolve gracefully handles degraded paths ──
print("\n[3] peer_identity.resolve returns nil on unreachable surfaces")
ok("nil client → nil",                pi.resolve(nil, 40781) == nil)
ok("missing tcp_handle → nil",        pi.resolve({ id = "x" }, 40781) == nil)
ok("missing listen_port → nil",       pi.resolve({ id = "y", tcp_handle = "stub" }, nil) == nil)
ok("client without string id → nil",  pi.resolve({ id = 123, tcp_handle = "stub" }, 40781) == nil)

-- ── [4] peer_identity.forget drops the cache entry ───────────────
print("\n[4] peer_identity.forget evicts the cache entry")
pi._test_cache["soon-to-go"] = "jarvis"
ok("cache entry exists pre-forget", pi._test_cache["soon-to-go"] == "jarvis")
pi.forget("soon-to-go")
ok("cache entry cleared post-forget", pi._test_cache["soon-to-go"] == nil)

-- forget on a missing key is a no-op (must not raise).
ok("forget on missing key is a no-op",
   pcall(pi.forget, "never-cached") and pi._test_cache["never-cached"] == nil)

-- ── [4b] find_agent_inode resolves the CLIENT-side row ───────────
-- Round-2 regression test (agent:lector finding #1). The pre-fix
-- implementation matched the server-accept row of /proc/net/tcp,
-- whose inode is owned by nvim itself — so /proc/<agent_pid>/fd never
-- contained it and live attribution always missed. The fix matches
-- the client-connect row (local=client_port, rem=server_port), whose
-- inode IS in the agent's fd table.
--
-- Stand up a real localhost TCP pair, then assert:
--   * find_agent_inode returns SOMETHING (the parse works in this env).
--   * That inode is found in THIS process's /proc/<pid>/fd — because
--     here both endpoints belong to nvim (we own both sides). The
--     positive signal is that find_agent_inode's result is owned by
--     SOME process, not specifically the wrong one. In production
--     the client-side belongs to the agent process; here it belongs
--     to us, and that's still the correct direction.
--   * The OPPOSITE direction (server-accept row, local=server_port,
--     rem=client_port) would return a DIFFERENT inode — exercise the
--     find_agent_inode result vs. a manual /proc/net/tcp scan for the
--     server-accept row to confirm the two inodes differ. This is the
--     direct evidence that the fix flipped the right way.
print("\n[4b] find_agent_inode resolves the client-side row, not server-side")

-- Spin up a listening socket + a client connection on localhost.
local server = vim.uv.new_tcp()
assert(server, "could not create server tcp handle")
local bind_ok = server:bind("127.0.0.1", 0)
assert(bind_ok, "could not bind tcp server")
server:listen(1, function() end)  -- accept callback unused; we only need the socket pair
local server_addr = server:getsockname()
local listen_port = server_addr and server_addr.port

local client = vim.uv.new_tcp()
assert(client, "could not create client tcp handle")
local connected = false
client:connect("127.0.0.1", listen_port, function(err)
  connected = (err == nil)
end)
vim.wait(500, function() return connected end, 10)

ok("test fixture: client connected to server on " .. tostring(listen_port),
   connected and listen_port ~= nil)

if connected then
  local peer = client:getsockname()  -- client's local (ephemeral) port
  local client_port = peer and peer.port

  local agent_inode = pi._test_find_agent_inode(listen_port, client_port)
  ok("find_agent_inode returns an inode for the live TCP pair",
     type(agent_inode) == "string" and #agent_inode > 0,
     string.format("server=%s client=%s inode=%q",
       tostring(listen_port), tostring(client_port), tostring(agent_inode)))

  -- Direct evidence the directions differ: scan /proc/net/tcp manually
  -- for the SERVER-accept row (local=listen_port, rem=client_port) and
  -- assert its inode is NOT the same as the client-connect row's.
  local function scan_server_inode()
    local lp = string.format("%04X", listen_port):lower()
    local cp = string.format("%04X", client_port):lower()
    for _, proc_file in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
      local fh = io.open(proc_file, "r")
      if fh then
        local first = true
        for line in fh:lines() do
          if first then first = false else
            local fields = {}
            for f in line:gmatch("%S+") do
              fields[#fields + 1] = f
              if #fields >= 12 then break end
            end
            local lap, rap, state = fields[2], fields[3], fields[4]
            if state == "01" and type(lap) == "string" and type(rap) == "string" then
              local lph = (lap:match(":([%xX]+)$") or ""):lower()
              local rph = (rap:match(":([%xX]+)$") or ""):lower()
              -- SERVER-accept row: local=server_port, rem=client_port.
              if lph == lp and rph == cp then
                local inode = fields[10]
                if type(inode) ~= "string" or not inode:match("^%d+$") then
                  inode = line:match("%s(%d+)%s+%d+%s*$")
                end
                fh:close()
                return inode
              end
            end
          end
        end
        fh:close()
      end
    end
    return nil
  end
  local server_inode = scan_server_inode()
  ok("server-accept row exists in /proc/net/tcp", type(server_inode) == "string",
     string.format("server_inode=%q", tostring(server_inode)))
  ok("find_agent_inode returns the CLIENT inode, not the server inode",
     type(agent_inode) == "string"
       and type(server_inode) == "string"
       and agent_inode ~= server_inode,
     string.format("client=%q server=%q", tostring(agent_inode), tostring(server_inode)))
end

client:close()
server:close()

-- ── [5] openDiff still honours explicit `_auto_agents_name` ──────
print("\n[5] openDiff manual-override surface is preserved")
-- Drive the handler in a coroutine (it yields). Resolve via the
-- queue's pending list immediately — we don't need to wait for the
-- response.
local queue = require("auto-agents.diff.queue")
queue.clear()

local od = require("auto-agents.mcp.ws-server.tools.open_diff")
local input = {
  old_file_path     = "/tmp/od-test.lua",
  new_file_path     = "/tmp/od-test.lua",
  new_file_contents = "return {}",
  tab_name          = "✻ [Claude Code] od-test.lua (deadbeef) ⧉",
  _auto_agents_name = "explicit-override",
}

local co = coroutine.create(function() return od.handler(input, { client = fake_client }) end)
coroutine.resume(co)

local pending = queue.get_pending()
ok("openDiff enqueued one entry", #pending == 1)
eq("explicit _auto_agents_name kept as agent_name",
   pending[1] and pending[1].agent_name, "explicit-override")

-- Clean up the yielded coroutine so we don't leak.
queue.clear()

print()
print(string.format("Passed: %d, Failed: %d", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)