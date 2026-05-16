---Native Neovim terminal provider for auto-agents.nvim.
---Refactored from coder/claudecode.nvim's lua/claudecode/terminal/native.lua
---(MIT, 2025 Coder Technologies Inc.) — module-singleton state lifted into a
---per-instance factory so each agent slot owns its own terminal.
---@module 'auto-agents.terminal.native'

local logger = require("auto-agents.log")

local M = {}

local Instance = {}
Instance.__index = Instance

---Spawn the agent process in a new buffer. If `winid` is supplied, the
---buffer is placed in that window BEFORE termopen so the terminal
---inherits the window's dimensions immediately (avoiding a TUI render
---at default 80×24 followed by a misaligned redraw on later placement).
---Without a winid, the buffer is created window-less and the caller is
---responsible for placing it + calling Instance:resize_to(winid).
---@param winid integer|nil
---@return integer|nil bufnr
function Instance:start(winid)
  if self.state == "running" then
    return self.bufnr
  end

  local buf = vim.api.nvim_create_buf(false, false)  -- listed=false — see flag block below
  local self_ref = self
  local jobid

  -- Place buffer in target window FIRST so termopen sees its dimensions.
  -- This is the same flow snacks.terminal uses (see lua/snacks/terminal.lua
  -- line ~160: terminal:show() → vim.api.nvim_buf_call(terminal.buf, jobstart)).
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_buf(winid, buf)
  end

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
  vim.bo[buf].buflisted = false  -- hide from bufferline + :bnext/:bprev (issue #4/#5)
  vim.bo[buf].swapfile = false

  -- Buffer-local terminal-mode keymaps so the user can escape the agent
  -- window without reaching for the mouse (issue #3). These exit terminal
  -- mode and switch windows in one keystroke.
  --
  -- KNOWN ISSUE (2026-05-09): pressing `<C-l>` from the rightmost agent
  -- slot (no window to the right) leaves the user in terminal-normal
  -- mode rather than staying in terminal-insert. Two attempted fixes
  -- (intra-callback mode dance + pre-check `winnr(<dir>)` with
  -- feedkeys) didn't work — see
  -- ~/Source/Documents/knowledge-base/projects/auto-agents/known-issues.md
  -- for the diagnosis backlog.
  local kopts = { buffer = buf, silent = true }
  vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], kopts)
  vim.keymap.set("t", "<C-j>", [[<C-\><C-n><C-w>j]], kopts)
  vim.keymap.set("t", "<C-k>", [[<C-\><C-n><C-w>k]], kopts)
  vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], kopts)

  -- Auto-enter terminal mode whenever this buffer is entered via window
  -- navigation (e.g. <C-l> from the editor). Cursor lands at the agent's
  -- input position without requiring a manual `i`.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer = buf,
    callback = function()
      if vim.bo[buf].buftype == "terminal" then
        vim.cmd("startinsert")
      end
    end,
  })

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

---Resize the terminal to the given window's dimensions. Sends SIGWINCH
---to the underlying process so TUIs (claude, codex, etc.) redraw at
---the correct size. Cheap to call defensively after every buffer/window
---swap.
---@param winid integer
---@param opts { bottom_margin: integer|nil }|nil  -- subtract N rows from height
function Instance:resize_to(winid, opts)
  if not self.jobid or self.jobid <= 0 then return end
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local margin = (opts and opts.bottom_margin) or 0
  local w = vim.api.nvim_win_get_width(winid)
  local h = vim.api.nvim_win_get_height(winid) - margin
  if h < 1 then h = 1 end
  pcall(vim.fn.jobresize, self.jobid, w, h)
end

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
