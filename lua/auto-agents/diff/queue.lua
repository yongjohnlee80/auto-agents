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
--- @field originator_mailbox_id string? Full mailbox id (e.g. `agent:juliet:<instance>`)
---                         of the agent that submitted this diff via the `diff_queue`
---                         mailbox command. Nil for entries that came in over the MCP
---                         websocket bridge (Claude / Codex via openDiff), where the
---                         agent unblocks via the coroutine callback instead of via a
---                         mailbox-routed verdict message. Stashed at enqueue time so
---                         `resolve` / `reject` can emit a follow-up `kind="message"`
---                         to the originator's inbox.
--- @field correlation_id string? `correlation_id` from the originating `diff_queue`
---                         mailbox command. Set on the verdict message so the agent
---                         can match the verdict back to its original request.
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
    -- Mailbox-routed entries (auto-agents `diff_queue` command) stash
    -- the originator's full mailbox id + the command's correlation_id
    -- so resolve/reject can emit a verdict back via the standard
    -- router. MCP openDiff entries (Claude/Codex via the websocket
    -- bridge) leave both nil — the coroutine callback is their reply
    -- channel.
    originator_mailbox_id = req.originator_mailbox_id,
    correlation_id        = req.correlation_id,
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

--- Emit a verdict message back to the originating mailbox agent. No-op
--- for entries without `originator_mailbox_id` (the MCP openDiff path
--- replies via the coroutine callback). Best-effort: any send failure
--- logs and returns false rather than throwing — the queue resolution
--- itself must not depend on the mailbox round-trip succeeding.
---
--- Verdict shape (lands in originator's `inbox/`, wake fires via the
--- standard router):
---
---   kind:           "message"
---   from:           "nvim"
---   to:             <req.originator_mailbox_id>
---   correlation_id: <req.correlation_id> — matches the original
---                   `diff_queue` command so the agent can correlate
---   subject:        "diff verdict for <tab_name>"
---   body:           human-readable summary
---   args:           { verdict = "accepted"|"rejected", comment, file_path, tab_name }
---
--- @param req AutoAgentsDiffRequest
--- @param verdict "accepted"|"rejected"
--- @param comment string? Optional user-supplied reason (rejection comment, or "" on accept)
--- @return boolean ok
local function emit_verdict(req, verdict, comment)
  if type(req.originator_mailbox_id) ~= "string"
      or req.originator_mailbox_id == ""
  then
    return false
  end

  local ok_transport, transport = pcall(require, "auto-core.mailbox.transport")
  if not ok_transport then return false end

  local label = req.tab_name or req.file_path or "<diff>"
  local body
  if verdict == "accepted" then
    body = "Diff accepted for " .. label
        .. (comment ~= nil and comment ~= "" and (": " .. comment) or "")
  else
    body = "Diff rejected for " .. label
        .. ((comment ~= nil and comment ~= "") and (": " .. comment) or "")
  end

  local _, send_err = transport.send({
    from           = "nvim",
    to             = req.originator_mailbox_id,
    kind           = "message",
    subject        = string.format("diff verdict (%s) for %s", verdict, label),
    body           = body,
    correlation_id = req.correlation_id,
    args = {
      verdict   = verdict,
      comment   = comment or "",
      file_path = req.file_path,
      tab_name  = req.tab_name,
    },
  })
  if send_err then
    local ok_log, log = pcall(require, "auto-agents.log")
    if ok_log then
      log.warn("diff.queue",
        "verdict emit failed: " .. tostring(send_err)
          .. " (to=" .. tostring(req.originator_mailbox_id)
          .. ", cor=" .. tostring(req.correlation_id) .. ")")
    end
    return false
  end
  return true
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
  -- Mailbox-routed entries also get a verdict message via the router.
  -- No-op for MCP openDiff entries (no originator_mailbox_id).
  emit_verdict(req, "accepted", nil)
  M.remove(id)
end

--- Reject a diff request (called when the user quits the split, presses
--- D in the panel, or sends a "request change" message via M).
--- The optional `reason` string is sent back to the agent as the
--- second text content of the DIFF_REJECTED response — Claude reads
--- it as part of the tool result and can act on the feedback.
--- @param id string
--- @param reason string? Optional user-supplied rejection message
function M.reject(id, reason)
  local req = M.get(id)
  if not req or req.status ~= "pending" then return end

  req.status = "rejected"

  local message = reason
  if not message or message == "" then
    message = "User rejected the diff."
  end

  -- Create MCP-compliant result format
  local result = {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = message },
    }
  }

  -- Resume the blocked coroutine
  req.callback(result)
  -- Mailbox-routed entries also get a verdict message via the router.
  -- The user comment (M) or the rejection placeholder (D, no input)
  -- is forwarded so the agent can iterate.
  emit_verdict(req, "rejected", reason)
  M.remove(id)
end

--- Clear the entire queue (mostly for testing/cleanup)
function M.clear()
  _queue = {}
  _next_id = 1
end

return M
