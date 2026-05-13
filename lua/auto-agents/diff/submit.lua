---External diff submission helpers.
---
---Agent runtimes normally reach the queue through the IDE bridge's
---openDiff tool. This module covers runtimes that can prepare a proposed
---file image but need a local Neovim pipeline to review it before anything
---is written to disk.
---
---@module 'auto-agents.diff.submit'

local M = {}

local queue = require("auto-agents.diff.queue")

local function normalize_path(path)
  if not path or path == "" then return nil end
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content or "", nil
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "w")
  if not f then return false, err end
  local ok, werr = f:write(content)
  local close_ok, cerr = f:close()
  if not ok then return false, werr end
  if not close_ok then return false, cerr end
  return true, nil
end

local function result_text(result, idx)
  if type(result) ~= "table" or type(result.content) ~= "table" then return nil end
  local item = result.content[idx]
  return type(item) == "table" and item.text or nil
end

local function notify(level, message)
  vim.schedule(function()
    vim.notify(message, level, { title = "auto-agents diff" })
  end)
end

local function make_callback(file_path, fallback_contents, on_done)
  return function(result)
    local status = result_text(result, 1)
    if status ~= "FILE_SAVED" then
      local reason = result_text(result, 2) or "User rejected the diff."
      notify(
        vim.log.levels.INFO,
        "Diff rejected for " .. vim.fn.fnamemodify(file_path, ":t") .. ": " .. reason
      )
      on_done({
        status = "rejected",
        file_path = file_path,
        reason = reason,
      })
      return
    end

    local accepted = result_text(result, 2)
    if accepted == nil then accepted = fallback_contents end

    local ok, write_err = write_file(file_path, accepted)
    if ok then
      notify(vim.log.levels.INFO, "Accepted diff written: " .. file_path)
      vim.schedule(function()
        pcall(vim.cmd, "checktime")
      end)
      on_done({
        status = "accepted",
        file_path = file_path,
        content = accepted,
      })
    else
      notify(vim.log.levels.ERROR, "Failed to write accepted diff: " .. tostring(write_err))
      on_done({
        status = "error",
        file_path = file_path,
        error = tostring(write_err),
      })
    end
  end
end

local function submit(opts, on_done)
  opts = opts or {}
  on_done = on_done or function() end

  local agent_name = opts.agent_name
  if not agent_name or agent_name == "" then
    return nil, "agent_name is required"
  end

  local file_path = normalize_path(opts.file_path)
  if not file_path then
    return nil, "file_path is required"
  end

  local new_contents = opts.new_contents
  if new_contents == nil then
    local proposal_path = normalize_path(opts.proposal_path)
    if not proposal_path then
      return nil, "proposal_path or new_contents is required"
    end
    local content, read_err = read_file(proposal_path)
    if content == nil then
      return nil, "failed to read proposal file: " .. tostring(read_err)
    end
    new_contents = content
  end

  local old_contents = read_file(file_path)
  if old_contents == nil then old_contents = "" end

  local id = queue.enqueue({
    agent_name = agent_name,
    file_path = file_path,
    old_contents = old_contents,
    new_contents = new_contents,
    tab_name = opts.tab_name,
    callback = make_callback(file_path, new_contents, on_done),
  })

  if opts.open_ui ~= false then
    vim.schedule(function()
      local ok, ui = pcall(require, "auto-agents.diff.ui")
      if ok then ui.open() end
    end)
  end

  return id, nil
end

---Queue a proposed file image and return immediately.
---
---@param opts {agent_name:string, file_path:string, proposal_path:string?, new_contents:string?, tab_name:string?, open_ui:boolean?}
---@return string? id
---@return string? err
function M.enqueue_file(opts)
  return submit(opts)
end

---Queue a proposed file image and wait until the user accepts or rejects it.
---
---This is intended for remote-expr pipelines. `vim.wait()` keeps Neovim's
---event loop alive while the caller is blocked, so the diff queue remains
---interactive and the caller receives the user's decision.
---
---@param opts {agent_name:string, file_path:string, proposal_path:string?, new_contents:string?, tab_name:string?, open_ui:boolean?, timeout_ms:integer?}
---@return table result
function M.submit_file_and_wait(opts)
  opts = opts or {}
  local outcome = nil
  local id, err = submit(opts, function(result)
    outcome = result
  end)

  if not id then
    return {
      status = "error",
      error = err,
    }
  end

  local timeout_ms = tonumber(opts.timeout_ms) or 0
  local started = vim.uv and vim.uv.now() or vim.loop.now()

  while not outcome do
    local wait_ms = 100
    if timeout_ms > 0 then
      local now = vim.uv and vim.uv.now() or vim.loop.now()
      local remaining = timeout_ms - (now - started)
      if remaining <= 0 then
        queue.reject(id, "Timed out waiting for diff review response.")
        break
      end
      wait_ms = math.max(1, math.min(wait_ms, remaining))
    end
    vim.wait(wait_ms, function() return outcome ~= nil end, 20)
  end

  outcome = outcome or {
    status = "timeout",
    file_path = normalize_path(opts.file_path),
  }
  outcome.id = id
  return outcome
end

return M
