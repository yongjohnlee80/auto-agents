---Native Neovim terminal provider for auto-agents.nvim.
---Refactored from coder/claudecode.nvim's lua/claudecode/terminal/native.lua
---(MIT, 2025 Coder Technologies Inc.) — module-singleton state lifted into a
---per-instance factory so each agent slot owns its own terminal.
---@module 'auto-agents.terminal.native'

local logger = require("auto-agents.logger")

local M = {}

local Instance = {}
Instance.__index = Instance

---Spawn the agent process in a new buffer. Does not create a window —
---the panel is responsible for placing the buffer into its slot window.
---@return integer|nil bufnr
function Instance:start()
  if self.state == "running" then
    return self.bufnr
  end

  local buf = vim.api.nvim_create_buf(true, false)
  local self_ref = self
  local jobid

  vim.api.nvim_buf_call(buf, function()
    jobid = vim.fn.termopen(self_ref.spec.cmd, {
      cwd = self_ref.spec.cwd,
      env = self_ref.spec.env,
      on_exit = function(_, code, _)
        vim.schedule(function()
          self_ref.state = "exited"
          self_ref.exit_code = code
          logger.debug("terminal/native", "job exited code=" .. tostring(code))
          if self_ref.spec.on_exit then
            self_ref.spec.on_exit(code)
          end
        end)
      end,
    })
  end)

  if not jobid or jobid <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    self.state = "errored"
    logger.error("terminal/native", "failed to spawn", self.spec.cmd)
    return nil
  end

  vim.bo[buf].bufhidden = "hide"
  self.bufnr = buf
  self.jobid = jobid
  self.state = "running"
  return buf
end

---@param text string
---@return boolean
function Instance:send(text)
  if self.state ~= "running" or not self.jobid then
    return false
  end
  vim.api.nvim_chan_send(self.jobid, text)
  return true
end

function Instance:kill(_signal)
  if self.state ~= "running" or not self.jobid then
    return
  end
  vim.fn.jobstop(self.jobid)
end

---@return boolean
function Instance:is_alive()
  if self.state ~= "running" or not self.jobid then
    return false
  end
  return vim.fn.jobwait({ self.jobid }, 0)[1] == -1
end

function Instance:get_bufnr() return self.bufnr end
function Instance:get_jobid() return self.jobid end

---@param spec AutoAgentsTerminalSpec
---@return AutoAgentsTerminalInstance
function M.new(spec)
  return setmetatable({
    spec = spec,
    bufnr = nil,
    jobid = nil,
    state = "idle",
    exit_code = nil,
  }, Instance)
end

return M
