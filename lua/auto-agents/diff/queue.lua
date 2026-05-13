--- auto-agents.diff.queue — Manages the state of queued diff requests
---
--- @module 'auto-agents.diff.queue'

local M = {}

--- @class AutoAgentsDiffRequest
--- @field id string Unique ID for the request
--- @field agent_name string The name/ID of the agent proposing the diff
--- @field file_path string Target file path
--- @field old_contents string Current contents of the file
--- @field new_contents string Proposed new contents
--- @field tab_name string? MCP tab name from the originating openDiff call — used to
---                         match a later close_tab call against this entry when the
---                         agent dismisses the diff by other means (e.g. user
---                         answered yes/no in the CLI terminal).
--- @field callback fun(result: table) Coroutine resume callback
--- @field status "pending"|"resolved"|"rejected" State of the request
--- @field created_at integer Timestamp of creation

--- @type AutoAgentsDiffRequest[]
local _queue = {}
local _next_id = 1

--- Enqueue a new diff request.
--- @param req table Table containing agent_name, file_path, old_contents, new_contents, callback
--- @return string id The generated request ID
function M.enqueue(req)
  assert(req.agent_name, "agent_name is required")
  assert(req.file_path, "file_path is required")
  assert(req.new_contents, "new_contents is required")
  assert(req.callback, "callback is required")

  local id = "diff_" .. tostring(_next_id)
  _next_id = _next_id + 1

  local request = {
    id = id,
    agent_name = req.agent_name,
    file_path = req.file_path,
    old_contents = req.old_contents or "",
    new_contents = req.new_contents,
    tab_name = req.tab_name,
    callback = req.callback,
    status = "pending",
    created_at = os.time(),
  }

  table.insert(_queue, request)

  -- Publish an event so the UI can auto-refresh if open
  local ok, events = pcall(require, "auto-core.events")
  if ok and events.publish then
    events.publish("auto-agents:diff_queued", request)
  end

  return id
end

--- Get all currently pending requests.
--- @return AutoAgentsDiffRequest[]
function M.get_pending()
  local pending = {}
  for _, req in ipairs(_queue) do
    if req.status == "pending" then
      table.insert(pending, req)
    end
  end
  return pending
end

--- Get a request by ID.
--- @param id string
--- @return AutoAgentsDiffRequest?
function M.get(id)
  for _, req in ipairs(_queue) do
    if req.id == id then
      return req
    end
  end
  return nil
end

--- Find the first pending request matching the given MCP `tab_name`.
--- Used by the `close_tab` MCP tool: when the agent dismisses a diff
--- by other means (e.g. the user answered yes/no in the CLI terminal
--- while the panel was hidden), Claude Code sends `close_tab` with the
--- same `tab_name` it passed to `openDiff`. We look up the pending
--- entry here so we can reject it and unblock the coroutine.
--- @param tab_name string?
--- @return AutoAgentsDiffRequest?
function M.find_by_tab_name(tab_name)
  if not tab_name then return nil end
  for _, req in ipairs(_queue) do
    if req.status == "pending" and req.tab_name == tab_name then
      return req
    end
  end
  return nil
end

--- Remove a request from the queue (usually after resolution).
--- @param id string
function M.remove(id)
  for i, req in ipairs(_queue) do
    if req.id == id then
      table.remove(_queue, i)
      
      local ok, events = pcall(require, "auto-core.events")
      if ok and events.publish then
        events.publish("auto-agents:diff_removed", { id = id })
      end
      return
    end
  end
end

--- Resolve a diff request (called when user saves the split).
--- @param id string
--- @param final_contents string The accepted content
function M.resolve(id, final_contents)
  local req = M.get(id)
  if not req or req.status ~= "pending" then return end
  
  req.status = "resolved"
  
  -- Create MCP-compliant result format
  local result = {
    content = {
      { type = "text", text = "FILE_SAVED" },
      { type = "text", text = final_contents },
    }
  }
  
  -- Resume the blocked coroutine
  req.callback(result)
  M.remove(id)
end

--- Reject a diff request (called when user quits the split without saving).
--- @param id string
function M.reject(id)
  local req = M.get(id)
  if not req or req.status ~= "pending" then return end
  
  req.status = "rejected"
  
  -- Create MCP-compliant result format
  local result = {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = "User rejected the diff." },
    }
  }
  
  -- Resume the blocked coroutine
  req.callback(result)
  M.remove(id)
end

--- Clear the entire queue (mostly for testing/cleanup)
function M.clear()
  _queue = {}
  _next_id = 1
end

return M
