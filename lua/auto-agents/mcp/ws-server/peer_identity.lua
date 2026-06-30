--- auto-agents.mcp.ws-server.peer_identity
---
--- Resolve "which auto-agents slot owns this TCP connection?" given a
--- ws-server `client` object (which carries a `vim.uv` TCP handle).
---
--- Why this exists: the diff-review MCP server is a single shared port
--- across every `diff_review = true` slot. Stock Claude Code does not
--- inject an agent identifier into openDiff payloads, so the server
--- can't tell which slot's claude process made a given tool call —
--- it ends up with `agent_name = "?"` in the queue and the panel
--- renders `[unattributed]` (post Patch 1). This module closes the
--- attribution gap by reverse-mapping at the OS level:
---
---   1. `vim.uv.tcp_getpeername(client.tcp_handle)` → peer source port.
---   2. Walk `/proc/net/tcp` (+ `tcp6`) for the row whose local_address
---      matches the listening port AND rem_address matches the peer's
---      source port. That row has an `inode` field.
---   3. For each spawned slot's PID (from
---      `auto-agents.spawned_agents_with_pid()` — ALL live slots, not just
---      `diff_review` ones, per ADR-0046 D-A), list `/proc/<pid>/fd/*` and
---      look for a symlink target `socket:[<inode>]`. The matching PID is
---      the originator.
---
--- Linux-only. On macOS/BSD this falls back to nil (the caller treats
--- that as "unattributed" — same as the existing display predicate).
--- A non-Linux fallback via `lsof` is a follow-up if/when needed.
---
--- Cached per-connection. `client.id` is the cache key. The cache is
--- invalidated lazily — if a stale entry returns nil on a subsequent
--- call (e.g. the slot restarted and the PID changed), the lookup
--- re-runs.
---
--- @module 'auto-agents.mcp.ws-server.peer_identity'

local M = {}

-- @type table<string, string|false>   client.id → slot_name (or false = "looked up, nothing")
local _cache = {}

--- Read the connection's peer (source) port from the client's TCP handle.
--- @param client table  WebSocketClient with a `tcp_handle` field
--- @return integer?
local function peer_port(client)
  if not client or not client.tcp_handle then return nil end
  local ok, peer = pcall(function()
    return vim.uv.tcp_getpeername(client.tcp_handle)
  end)
  if not ok or type(peer) ~= "table" then return nil end
  return type(peer.port) == "number" and peer.port or nil
end

--- Hex-encode an integer port in the lowercase 4-hex form `/proc/net/tcp` uses.
--- @param port integer
--- @return string
local function port_hex_lc(port)
  return string.format("%04X", port):lower()
end

--- Walk `/proc/net/tcp` and `/proc/net/tcp6` for the **client-side** row
--- of an established TCP connection between our server (`server_port`)
--- and an agent process (whose connect-side ephemeral port is
--- `client_port`). Returns the client-side socket inode as a string, or
--- nil if no match.
---
--- Why client-side: for a localhost connection, /proc/net/tcp contains
--- BOTH endpoints — the server-accept row and the client-connect row.
--- The server-accept row's inode belongs to THIS nvim process; matching
--- against agent PIDs always misses. The client-connect row's inode
--- belongs to the agent process — the row we actually need.
---
--- Server-accept row : local = SERVER:port  rem = CLIENT:port   (nvim owns this inode)
--- Client-connect row: local = CLIENT:port  rem = SERVER:port   (agent owns this inode) ← THIS
---
--- The pre-round-2 implementation matched the wrong direction. Caught
--- by agent:lector in the round-2 review of ADR 0011.
---
--- /proc/net/tcp row format (header line first):
---   sl  local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode ...
---   0:  0100007F:9F4D 0100007F:A82A 01 ...                                              123456
---
--- We only care about ESTABLISHED (state 01).
--- @param server_port integer  our ws-server listening port
--- @param client_port integer  agent's connect-side ephemeral port (from getpeername)
--- @return string?  inode of the AGENT-SIDE socket, or nil
local function find_agent_inode(server_port, client_port)
  local sp = port_hex_lc(server_port)
  local cp = port_hex_lc(client_port)
  for _, proc_file in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
    local fh = io.open(proc_file, "r")
    if fh then
      local first = true
      for line in fh:lines() do
        if first then
          first = false
        else
          -- local_address and rem_address are the 2nd and 3rd whitespace-
          -- separated fields. Each is `<HEXADDR>:<HEXPORT>`.
          local fields = {}
          for field in line:gmatch("%S+") do
            fields[#fields + 1] = field
            if #fields >= 12 then break end
          end
          local local_ap = fields[2]   -- "addr:port"
          local rem_ap   = fields[3]
          local state    = fields[4]
          if state == "01" and type(local_ap) == "string" and type(rem_ap) == "string" then
            local local_port_hex  = (local_ap:match(":([%xX]+)$") or ""):lower()
            local remote_port_hex = (rem_ap:match(":([%xX]+)$") or ""):lower()
            -- Client-connect row: local = client_port, rem = server_port.
            if local_port_hex == cp and remote_port_hex == sp then
              local inode = fields[10]  -- after uid (8) and timeout (9), inode is 10th
              -- The /proc/net/tcp column order is documented but the
              -- spacing varies on some kernels. Search the line for a
              -- "socket:[<inode>]"-shaped number close to the end as a
              -- secondary heuristic if the indexed lookup fails.
              if type(inode) ~= "string" or not inode:match("^%d+$") then
                inode = line:match("%s(%d+)%s+%d+%s*$")
              end
              fh:close()
              return type(inode) == "string" and inode or nil
            end
          end
        end
      end
      fh:close()
    end
  end
  return nil
end

--- Check whether any of `/proc/<pid>/fd/*` symlinks point to
--- `socket:[<inode>]`. Returns true on first match.
--- @param pid integer
--- @param inode string
--- @return boolean
local function pid_owns_socket(pid, inode)
  local target = "socket:[" .. inode .. "]"
  local fd_dir = "/proc/" .. tostring(pid) .. "/fd"
  local handle = vim.uv.fs_scandir(fd_dir)
  if not handle then return false end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local link = vim.uv.fs_readlink(fd_dir .. "/" .. name)
    if link == target then return true end
  end
  return false
end

--- @class PeerIdentityStatus
--- @field name      string?  resolved slot name, or nil if unattributable
--- @field attempted boolean  was a live peer present to attribute? `false`
---                           ONLY when no client was passed — the caller
---                           may then keep its legacy bootstrap fallback.
---                           With a live client it is always `true`, so a
---                           nil `name` means "live peer, could not
---                           attribute" → caller MUST treat as
---                           unattributed, NOT guess from the bootstrap.
--- @field reason    string?  diagnostic for a nil `name`

--- Public API (ADR-0046 D-A + D-B). Given a ws-server `client` and the
--- listening port, return an attribution STATUS. The candidate set is
--- ALL spawned slots (`spawned_agents_with_pid`), not just `diff_review`
--- ones — any spawned agent can reach the single shared bridge via
--- lockfile auto-discovery. `attempted` lets the caller distinguish
--- "no live peer to attribute" (keep legacy fallback) from "live peer
--- that matched no slot" (must be unattributed).
---
--- @param client      table?   WebSocketClient with `id` + `tcp_handle`
--- @param listen_port integer? the ws-server's listening port
--- @return PeerIdentityStatus
function M.resolve_status(client, listen_port)
  if not client or type(client.id) ~= "string" then
    return { name = nil, attempted = false, reason = "no_client" }
  end

  -- From here a live peer is present → `attempted = true` on every path.
  -- Cache hit (positive only — negative results re-probe in case the
  -- slot has since come up).
  local cached = _cache[client.id]
  if type(cached) == "string" and cached ~= "" then
    return { name = cached, attempted = true }
  end

  -- Linux-only path. uv stat /proc to feature-detect.
  if not vim.uv.fs_stat("/proc/net/tcp") then
    return { name = nil, attempted = true, reason = "not_linux" }
  end

  local pp = peer_port(client)
  if not pp or not listen_port then
    return { name = nil, attempted = true, reason = "no_peer_port" }
  end

  local inode = find_agent_inode(listen_port, pp)
  if not inode then
    return { name = nil, attempted = true, reason = "no_inode" }
  end

  local ok, aa = pcall(require, "auto-agents")
  if not ok or type(aa.spawned_agents_with_pid) ~= "function" then
    return { name = nil, attempted = true, reason = "no_slots_api" }
  end

  for _, entry in ipairs(aa.spawned_agents_with_pid()) do
    if pid_owns_socket(entry.pid, inode) then
      _cache[client.id] = entry.name
      return { name = entry.name, attempted = true }
    end
  end

  return { name = nil, attempted = true, reason = "no_pid_match" }
end

--- Back-compat string wrapper around `resolve_status`. Returns just the
--- resolved name (or nil). Kept for callers/specs that only need the name.
--- @param client      table?
--- @param listen_port integer?
--- @return string?
function M.resolve(client, listen_port)
  return M.resolve_status(client, listen_port).name
end

--- Drop the cache entry for a disconnecting client. Called by the
--- ws-server on `on_disconnect` so stale entries don't accumulate.
--- @param client_id string
function M.forget(client_id)
  if type(client_id) == "string" then _cache[client_id] = nil end
end

--- Test helpers — expose the cache + low-level lookups so headless
--- specs can drive each branch independently. Not part of the public
--- contract.
M._test_cache             = _cache
M._test_peer_port         = peer_port
M._test_port_hex_lc       = port_hex_lc
M._test_find_agent_inode = find_agent_inode
M._test_pid_owns_socket   = pid_owns_socket

return M