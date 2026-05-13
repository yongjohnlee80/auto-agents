---@brief [[
--- Lock file management for Codex CLI Neovim integration.
---
--- Codex.nvim writes the same lockfile shape as claudecode.nvim, but
--- under ~/.codex/ide (or $CODEX_CONFIG_DIR/ide). Codex then pairs that
--- discovery file with CODEX_CODE_SSE_PORT and Codex-specific auth env
--- vars when launching the terminal.
---@brief ]]
---@module 'auto-agents.mcp.codex_lockfile'

local M = {}

local function get_lock_dir()
  local codex_config_dir = os.getenv("CODEX_CONFIG_DIR")
  if codex_config_dir and codex_config_dir ~= "" then
    return vim.fn.expand(codex_config_dir .. "/ide")
  end
  return vim.fn.expand("~/.codex/ide")
end

M.lock_dir = get_lock_dir()

function M.config_dir()
  return vim.fn.fnamemodify(M.lock_dir, ":h")
end

local function get_workspace_folders()
  local folders = {}
  local cwd = vim.fn.getcwd()
  if cwd and cwd ~= "" then
    folders[#folders + 1] = {
      uri = "file://" .. cwd,
      name = vim.fn.fnamemodify(cwd, ":t"),
    }
  end
  return folders
end

function M.create(port, auth_token)
  if type(port) ~= "number" or port < 1 or port > 65535 then
    return false, "Invalid port number"
  end
  if type(auth_token) ~= "string" or #auth_token < 10 then
    return false, "Authentication token too short"
  end

  local ok, err = pcall(function()
    return vim.fn.mkdir(M.lock_dir, "p")
  end)
  if not ok then
    return false, "Failed to create lock directory: " .. tostring(err)
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"
  local payload = {
    pid = vim.fn.getpid(),
    workspaceFolders = get_workspace_folders(),
    ideName = "Neovim",
    transport = "ws",
    authToken = auth_token,
  }

  local file = io.open(lock_path, "w")
  if not file then
    return false, "Failed to create lock file: " .. lock_path
  end

  local write_ok, write_err = pcall(function()
    file:write(vim.json.encode(payload))
    file:close()
  end)
  if not write_ok then
    pcall(function()
      file:close()
    end)
    return false, "Failed to write lock file: " .. tostring(write_err)
  end

  return true, lock_path
end

function M.remove(port)
  if type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"
  if vim.fn.filereadable(lock_path) == 0 then
    return false, "Lock file does not exist: " .. lock_path
  end

  local ok, err = pcall(os.remove, lock_path)
  if not ok then
    return false, "Failed to remove lock file: " .. tostring(err)
  end
  return true
end

return M
