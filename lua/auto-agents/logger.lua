-- Adapted from coder/claudecode.nvim lua/claudecode/logger.lua (MIT, 2025 Coder Technologies Inc.)
-- Namespace renamed to [AutoAgents]; type aliases renamed.

---@brief Centralized logger for auto-agents.nvim. Provides level-based logging.
---@module 'auto-agents.logger'
local M = {}

M.levels = {
  ERROR = 1,
  WARN = 2,
  INFO = 3,
  DEBUG = 4,
  TRACE = 5,
}

local level_values = {
  error = M.levels.ERROR,
  warn = M.levels.WARN,
  info = M.levels.INFO,
  debug = M.levels.DEBUG,
  trace = M.levels.TRACE,
}

local current_log_level_value = M.levels.INFO

---Setup the logger module
---@param plugin_config AutoAgentsConfig
function M.setup(plugin_config)
  local conf = plugin_config

  if conf and conf.log_level and level_values[conf.log_level] then
    current_log_level_value = level_values[conf.log_level]
  else
    vim.notify(
      "AutoAgents Logger: Invalid or missing log_level in configuration (received: "
        .. tostring(conf and conf.log_level)
        .. "). Defaulting to INFO.",
      vim.log.levels.WARN
    )
    current_log_level_value = M.levels.INFO
  end
end

local function log(level, component, message_parts)
  if level > current_log_level_value then
    return
  end

  local prefix = "[AutoAgents]"
  if component then
    prefix = prefix .. " [" .. component .. "]"
  end

  local level_name = "UNKNOWN"
  for name, val in pairs(M.levels) do
    if val == level then
      level_name = name
      break
    end
  end
  prefix = prefix .. " [" .. level_name .. "]"

  local message = ""
  for i, part in ipairs(message_parts) do
    if i > 1 then
      message = message .. " "
    end
    if type(part) == "table" or type(part) == "boolean" then
      message = message .. vim.inspect(part)
    else
      message = message .. tostring(part)
    end
  end

  vim.schedule(function()
    if level == M.levels.ERROR then
      vim.notify(prefix .. " " .. message, vim.log.levels.ERROR, { title = "AutoAgents Error" })
    elseif level == M.levels.WARN then
      vim.notify(prefix .. " " .. message, vim.log.levels.WARN, { title = "AutoAgents Warning" })
    else
      vim.api.nvim_echo({ { prefix .. " " .. message, "Normal" } }, true, {})
    end
  end)
end

---@param component string|nil
---@param ... any
function M.error(component, ...)
  if type(component) ~= "string" then
    log(M.levels.ERROR, nil, { component, ... })
  else
    log(M.levels.ERROR, component, { ... })
  end
end

---@param component string|nil
---@param ... any
function M.warn(component, ...)
  if type(component) ~= "string" then
    log(M.levels.WARN, nil, { component, ... })
  else
    log(M.levels.WARN, component, { ... })
  end
end

---@param component string|nil
---@param ... any
function M.info(component, ...)
  if type(component) ~= "string" then
    log(M.levels.INFO, nil, { component, ... })
  else
    log(M.levels.INFO, component, { ... })
  end
end

---@param level_name AutoAgentsLogLevel
---@return boolean
function M.is_level_enabled(level_name)
  local level_value = level_values[level_name]
  if not level_value then
    return false
  end
  return level_value <= current_log_level_value
end

---@param component string|nil
---@param ... any
function M.debug(component, ...)
  if type(component) ~= "string" then
    log(M.levels.DEBUG, nil, { component, ... })
  else
    log(M.levels.DEBUG, component, { ... })
  end
end

---@param component string|nil
---@param ... any
function M.trace(component, ...)
  if type(component) ~= "string" then
    log(M.levels.TRACE, nil, { component, ... })
  else
    log(M.levels.TRACE, component, { ... })
  end
end

return M
