-- Adapted from coder/claudecode.nvim lua/claudecode/cwd.lua (MIT, 2025 Coder Technologies Inc.)

---Working directory resolution helpers for auto-agents.nvim
---@module 'auto-agents.cwd'

local M = {}

---@param dir string|nil
---@return string|nil
local function normalize_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  local expanded = vim.fn.expand(dir)
  local isdir = 1
  if vim.fn.isdirectory then
    isdir = vim.fn.isdirectory(expanded)
  end
  if isdir == 1 then
    return expanded
  end
  return nil
end

---@param start_dir string|nil
---@return string|nil
function M.git_root(start_dir)
  start_dir = normalize_dir(start_dir)
  if not start_dir then
    return nil
  end

  local result
  if vim.fn.systemlist then
    local ok, _ = pcall(function()
      local _ = vim.fn.systemlist({ "git", "-C", start_dir, "rev-parse", "--show-toplevel" })
    end)
    if ok then
      result = vim.fn.systemlist({ "git", "-C", start_dir, "rev-parse", "--show-toplevel" })
    else
      local cmd = "git -C " .. vim.fn.shellescape(start_dir) .. " rev-parse --show-toplevel"
      result = vim.fn.systemlist(cmd)
    end
  end

  if vim.v.shell_error == 0 and result and #result > 0 then
    local root = normalize_dir(result[1])
    if root then
      return root
    end
  end

  if vim.fn.finddir then
    local git_dir = vim.fn.finddir(".git", start_dir .. ";")
    if type(git_dir) == "string" and git_dir ~= "" then
      local parent = vim.fn.fnamemodify(git_dir, ":h")
      return normalize_dir(parent)
    end
  end

  return nil
end

---Resolve the effective working directory based on terminal config and context
---@param term_cfg AutoAgentsTerminalConfig
---@param ctx AutoAgentsCwdContext
---@return string|nil
function M.resolve(term_cfg, ctx)
  if type(term_cfg) ~= "table" then
    return nil
  end

  local provider = term_cfg.cwd_provider
  if type(provider) == "function" then
    local ok, res = pcall(provider, ctx)
    if ok then
      local p = normalize_dir(res)
      if p then
        return p
      end
    end
  end

  local static_cwd = normalize_dir(term_cfg.cwd)
  if static_cwd then
    return static_cwd
  end

  if term_cfg.git_repo_cwd then
    local start_dir = ctx and (ctx.file_dir or ctx.cwd) or vim.fn.getcwd()
    local root = M.git_root(start_dir)
    if root then
      return root
    end
  end

  return nil
end

return M
