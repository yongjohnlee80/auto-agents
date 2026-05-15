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
---@return table response MCP-compliant response with content array
local function handler(params)
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

  -- Determine agent name. Prefer the explicit `_auto_agents_name`
  -- param if the caller injected it; otherwise resolve via the
  -- bootstrap config (works when exactly one agent has
  -- diff_review = true, which is the common case).
  local aa_ok, aa = pcall(require, "auto-agents")
  local resolved
  if aa_ok and type(aa.resolve_diff_agent_name) == "function" then
    resolved = aa.resolve_diff_agent_name(params._auto_agents_name)
  end
  local agent_name = resolved or params._auto_agents_name or "?"

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
          if _G.auto_agents_deferred_responses and _G.auto_agents_deferred_responses[co_key] then
            _G.auto_agents_deferred_responses[co_key](result)
            _G.auto_agents_deferred_responses[co_key] = nil
          end
        else
          local co_key = tostring(co)
          if _G.auto_agents_deferred_responses and _G.auto_agents_deferred_responses[co_key] then
            _G.auto_agents_deferred_responses[co_key]({
              error = {
                code = -32603,
                message = "Internal error",
                data = "Coroutine failed: " .. tostring(resume_err),
              },
            })
            _G.auto_agents_deferred_responses[co_key] = nil
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
