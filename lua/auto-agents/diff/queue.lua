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
--- @field originator string? The agent (`agent:<name>`, as the editor socket names its
---                         caller) that submitted this diff with the `diff_queue` verb.
---                         Nil for entries that came in over the MCP websocket bridge
---                         (Claude / Codex via openDiff), where the agent unblocks via
---                         the coroutine callback instead. Stashed at enqueue time so
---                         `resolve` / `reject` can send the verdict to it as crew mail.
--- @field correlation_id string? The `diff_queue` call's correlation id, named in the
---                         verdict so the agent can match it to its request.
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
    -- `diff_queue` entries stash the agent that sent them and the call's
    -- correlation id, so resolve/reject can send it the verdict as crew
    -- mail. MCP openDiff entries (Claude/Codex via the websocket bridge)
    -- leave both nil — the coroutine callback is their reply channel.
    originator     = req.originator,
    correlation_id = req.correlation_id,
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

--- Unblock a still-pending entry that is about to be dropped without a
--- user verdict (direct remove of a pending entry, or queue clear).
--- Resuming the coroutine callback with DIFF_REJECTED lets the agent's
--- CLI stop waiting AND clears the matching `_G.claude_deferred_responses`
--- entry (open_diff's callback removes its own key on resume) — without
--- this, a dropped pending entry strands both until server stop
--- (ADR-0039 C3).
--- @param req AutoAgentsDiffRequest
--- @param why string
local function _drain_pending(req, why)
  if req.status ~= "pending" then return end
  req.status = "rejected"
  pcall(req.callback, {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = why },
    },
  })
end

--- Remove a request from the queue (usually after resolution).
--- @param id string
function M.remove(id)
  for i, req in ipairs(_queue) do
    if req.id == id then
      -- Resolution paths (resolve/reject) flip status before calling
      -- remove, so this only fires for direct removal of a pending
      -- entry — which must not strand the blocked coroutine.
      _drain_pending(req, "Diff entry removed from the queue.")
      table.remove(_queue, i)

      local ok, events = pcall(require, "auto-core.events")
      if ok and events.publish then
        events.publish("auto-agents:diff_removed", { id = id })
      end
      return
    end
  end
end

--- Send the verdict to the agent that queued the diff, as crew mail from the user (whose verdict it
--- is): AutoDoc's inbox.send under this Neovim's claim, keyed by this Neovim's instance and the
--- request's id, so a repeat is the same send (auto-agents.crew.crew_send, run in auto-core.todo.daemon.run). A no-op for entries
--- without an originator (the MCP openDiff path replies via the coroutine callback). Best-effort:
--- the queue's resolution never waits on it; a send that fails is logged.
---
--- The mail: subject "diff verdict (accepted|rejected) for <tab>", body the verdict, its comment and
--- the call's correlation id.
---
--- @param req AutoAgentsDiffRequest
--- @param verdict "accepted"|"rejected"
--- @param comment string? Optional user-supplied reason (rejection comment, or "" on accept)
--- @return boolean started
local function emit_verdict(req, verdict, comment)
  local name = type(req.originator) == "string" and req.originator:match("^agent:([^:]+)") or nil
  if not name then return false end
  local label = req.tab_name or req.file_path or "<diff>"
  local body = (verdict == "accepted" and "Diff accepted for " or "Diff rejected for ") .. label
    .. ((comment ~= nil and comment ~= "") and (": " .. comment) or "")
  if req.correlation_id then body = body .. " (correlation " .. req.correlation_id .. ")" end
  local msg = { kind = "message", subject = string.format("diff verdict (%s) for %s", verdict, label), body = body }
  local function warn(why)
    local ok_log, log = pcall(require, "auto-agents.log")
    if ok_log then
      log.warn("diff.queue", "verdict not sent to " .. name .. ": " .. tostring(why)
        .. " (cor=" .. tostring(req.correlation_id) .. ")")
    end
  end
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  if not ok_d then warn("auto-core.todo.daemon unavailable"); return false end
  -- request ids start again with each Neovim: the instance id makes the key this run's alone
  local ok_i, inst = pcall(function() return require("auto-core.instance").id() end)
  local key = ("diff-verdict-%s-%s"):format(ok_i and inst or tostring(req.created_at), tostring(req.id))
  daemon.run(function()
    return require("auto-agents.crew").crew_send(name, key, msg)
  end, function(ok, sent)
    if not ok then warn(sent) elseif sent ~= true then warn(sent == nil and "no crew scope held" or tostring(sent)) end
  end)
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
  -- A `diff_queue` entry's agent also gets the verdict as crew mail.
  -- No-op for MCP openDiff entries (no originator).
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
  -- A `diff_queue` entry's agent also gets the verdict as crew mail.
  -- The user comment (M) or the rejection placeholder (D, no input)
  -- is forwarded so the agent can iterate.
  emit_verdict(req, "rejected", reason)
  M.remove(id)
end

--- Clear the entire queue (mostly for testing/cleanup).
--- Pending entries are drained with DIFF_REJECTED first so their
--- blocked coroutines resume and the matching deferred-response
--- bookkeeping is released (ADR-0039 C3).
function M.clear()
  for _, req in ipairs(_queue) do
    _drain_pending(req, "Diff queue cleared.")
  end
  _queue = {}
  _next_id = 1
end

return M
