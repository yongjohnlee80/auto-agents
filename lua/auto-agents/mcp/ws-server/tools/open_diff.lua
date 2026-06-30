--- Generic openDiff tool handler for auto-agents
--- Intended to be exposed via adapters that provide an MCP server or similar tool-call mechanism

local schema = {
  description = "Open a diff view comparing old file content with new file content",
  inputSchema = {
    type = "object",
    properties = {
      old_file_path = {
        type = "string",
        description = "Path to the old file to compare",
      },
      new_file_path = {
        type = "string",
        description = "Path to the new file to compare",
      },
      new_file_contents = {
        type = "string",
        description = "Contents for the new file version",
      },
      tab_name = {
        type = "string",
        description = "Name for the diff tab/view",
      },
    },
    required = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Resolve the originating agent name for an openDiff request (ADR-0046).
---
---Order (most authoritative first):
---  1. `params._auto_agents_name` — explicit; agent self-identified.
---  2. Peer-PID attribution status (`peer_identity.resolve_status`) when a
---     live ws client is present — maps the connection's source port back
---     to its owning slot across ALL spawned slots (D-A).
---  3. If a live ws peer existed but could NOT be attributed → the
---     `"unattributed"` sentinel. We must NOT fall through to the lone
---     `diff_review` agent here — that is the misattribution+misrouting
---     bug ADR-0046 fixes (D-B).
---  4. Only when there was NO live ws peer (adapter / legacy caller) do we
---     use the bootstrap `resolve_diff_agent_name` fallback, which still
---     resolves the genuine single-`diff_review`-agent case.
---
---The panel's `agent_for` maps `"unattributed"` (and nil/""/"agent"/"?")
---to one displayed sentinel, and `slot_for_name("unattributed")` is nil so
---the request-change action refuses to misroute (diff/ui.lua, D-C).
---@param params table
---@param ctx    table?  ws-server context with `client`
---@return string agent_name
local function resolve_agent_name(params, ctx)
  local function is_valid(n)
    return type(n) == "string" and n ~= "" and n ~= "agent"
  end

  local explicit = params and params._auto_agents_name
  if is_valid(explicit) then return explicit end

  local aa_ok, aa = pcall(require, "auto-agents")

  -- Peer-PID attribution — only meaningful when a live ws client exists.
  local had_ws_peer = false
  local listen_port
  if aa_ok and aa.state and type(aa.state.diff_review_port) == "number" then
    listen_port = aa.state.diff_review_port
  end
  if ctx and ctx.client and listen_port then
    had_ws_peer = true
    local pi_ok, pi = pcall(require, "auto-agents.mcp.ws-server.peer_identity")
    if pi_ok and type(pi.resolve_status) == "function" then
      local status = pi.resolve_status(ctx.client, listen_port)
      if type(status) == "table" and is_valid(status.name) then
        return status.name
      end
      -- status.attempted is true here (live client); fall through to the
      -- had_ws_peer branch below → "unattributed".
    end
  end

  -- D-B: a live ws peer that couldn't be attributed must NOT collapse to
  -- the lone `diff_review` agent — mark it unattributed instead.
  if had_ws_peer then return "unattributed" end

  -- No live ws peer (adapter / legacy caller) → historical bootstrap
  -- fallback (resolves the genuine single-`diff_review`-agent case).
  if aa_ok and type(aa.resolve_diff_agent_name) == "function" then
    local resolved = aa.resolve_diff_agent_name(explicit)
    if is_valid(resolved) then return resolved end
  end
  return "unattributed"
end

---Handles the openDiff tool invocation.
---Uses the unified diff queue and blocks until user interaction (save/close).
---@param params table The input parameters for the tool
---@param ctx    table? Optional ws-server context (`{ client = WebSocketClient }`).
---                     Used by the peer-PID identity resolver when the
---                     agent doesn't self-identify via `_auto_agents_name`.
---@return table response MCP-compliant response with content array
local function handler(params, ctx)
  -- Validate required parameters
  local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }
  for _, param_name in ipairs(required_params) do
    if not params[param_name] then
      error({
        code = -32602, -- Invalid params
        message = "Invalid params",
        data = "Missing required parameter: " .. param_name,
      })
    end
  end

  -- Ensure we're running in a coroutine context for blocking operation
  local co, is_main = coroutine.running()
  if not co or is_main then
    error({
      code = -32000,
      message = "Internal server error",
      data = "openDiff must run in coroutine context",
    })
  end

  local diff_queue = require("auto-agents.diff.queue")

  -- Get old file contents
  local old_contents = ""
  local f_read = io.open(params.old_file_path, "r")
  if f_read then
    old_contents = f_read:read("*a")
    f_read:close()
  end

  local agent_name = resolve_agent_name(params, ctx)

  -- Using the unified diff queue
  local success, result_or_err = pcall(function()
    diff_queue.enqueue({
      agent_name = agent_name,
      file_path = params.old_file_path,
      old_contents = old_contents,
      new_contents = params.new_file_contents,
      tab_name = params.tab_name,
      callback = function(result)
        local resume_success, resume_err = coroutine.resume(co, result)
        if resume_success then
          -- If there is a global response mechanism, we handle it
          local co_key = tostring(co)
          if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
            _G.claude_deferred_responses[co_key](result)
            _G.claude_deferred_responses[co_key] = nil
          end
        else
          local co_key = tostring(co)
          if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
            _G.claude_deferred_responses[co_key]({
              error = {
                code = -32603,
                message = "Internal error",
                data = "Coroutine failed: " .. tostring(resume_err),
              },
            })
            _G.claude_deferred_responses[co_key] = nil
          end
        end
      end
    })
    
    -- Tell the UI to pop up if it's not open
    vim.schedule(function()
      local ui_ok, diff_ui = pcall(require, "auto-agents.diff.ui")
      if ui_ok then
        diff_ui.open()
      end
    end)
    
    -- Yield the coroutine, it will be resumed by the callback
    return coroutine.yield()
  end)

  if not success then
    if type(result_or_err) == "table" and result_or_err.code then
      error(result_or_err)
    else
      error({
        code = -32000,
        message = "Error enqueuing diff",
        data = tostring(result_or_err),
      })
    end
  end

  return result_or_err
end

return {
  name = "openDiff",
  schema = schema,
  handler = handler,
  requires_coroutine = true,
  -- Test hook (not part of the public contract): the pure agent-name
  -- resolver, so specs can drive the ADR-0046 D-B branches without a
  -- live coroutine / diff_queue.
  _test_resolve_agent_name = resolve_agent_name,
}
