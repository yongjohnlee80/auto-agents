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

  -- Agent-name resolution chain (most authoritative first):
  --
  --   1. `params._auto_agents_name` (explicit; agent self-identified)
  --   2. Peer-PID lookup: map the ws connection's source port back to
  --      its owning slot via /proc/net/tcp + /proc/<pid>/fd. Closes
  --      the multi-`diff_review` ambiguity reported by the user — see
  --      ADR 0011 §D2-B and `peer_identity.lua` for the OS-level walk.
  --   3. Bootstrap resolver: works only when EXACTLY ONE bootstrap
  --      entry has `diff_review = true` — kept as last-resort.
  --   4. Literal "?" sentinel (panel maps to "unattributed").
  local aa_ok, aa = pcall(require, "auto-agents")
  local agent_name = params._auto_agents_name

  if not (type(agent_name) == "string" and agent_name ~= "" and agent_name ~= "agent") then
    -- Try peer-PID identity. Requires the ws-server's context block.
    local listen_port
    if aa_ok and aa.state and type(aa.state.diff_review_port) == "number" then
      listen_port = aa.state.diff_review_port
    end
    if ctx and ctx.client and listen_port then
      local pi_ok, pi = pcall(require, "auto-agents.mcp.ws-server.peer_identity")
      if pi_ok and type(pi.resolve) == "function" then
        local resolved_by_peer = pi.resolve(ctx.client, listen_port)
        if type(resolved_by_peer) == "string" and resolved_by_peer ~= "" then
          agent_name = resolved_by_peer
        end
      end
    end
  end

  -- Final bootstrap-resolver fallback. Returns `agent_name` unchanged
  -- when it's already a valid explicit name; resolves the
  -- one-`diff_review`-agent case for setups that haven't grown
  -- multi-agent yet.
  if aa_ok and type(aa.resolve_diff_agent_name) == "function" then
    local resolved = aa.resolve_diff_agent_name(agent_name)
    agent_name = resolved or agent_name or "?"
  end
  if type(agent_name) ~= "string" or agent_name == "" then agent_name = "?" end

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
}
