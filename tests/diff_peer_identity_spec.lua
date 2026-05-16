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