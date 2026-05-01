---No-op terminal provider. Used in headless tests; never spawns a real process.
---Allocates a regular buffer so callers can place it in a window.
---@module 'auto-agents.terminal.none'

local M = {}

local Instance = {}
Instance.__index = Instance

function Instance:start()
  if self.state == "running" then
    return self.bufnr
  end
  self.bufnr = vim.api.nvim_create_buf(true, false)
  self.state = "running"
  return self.bufnr
end

---@param text string
---@return boolean
function Instance:send(text)
  table.insert(self.sent, text)
  return true
end

function Instance:kill(_signal)
  if self.state ~= "running" then
    return
  end
  self.state = "exited"
  self.exit_code = 0
  if self.spec.on_exit then
    vim.schedule(function() self.spec.on_exit(0) end)
  end
end

---@return boolean
function Instance:is_alive()
  return self.state == "running"
end

function Instance:get_bufnr() return self.bufnr end
function Instance:get_jobid() return nil end

---@param spec AutoAgentsTerminalSpec
---@return AutoAgentsTerminalInstance
function M.new(spec)
  return setmetatable({
    spec = spec,
    bufnr = nil,
    jobid = nil,
    state = "idle",
    exit_code = nil,
    sent = {},
  }, Instance)
end

return M
