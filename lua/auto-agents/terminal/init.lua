---Terminal provider dispatch. Resolves `config.terminal.provider` to a concrete
---module and exposes a uniform `new(spec) → instance` factory.
---@module 'auto-agents.terminal'

local M = {}

---Resolve the provider name to a concrete module name.
---"auto" picks snacks if available, else native. (Snacks support lands in a
---later milestone — until then, "auto" always resolves to "native".)
---@param config AutoAgentsConfig
---@return "snacks"|"native"|"none"
function M.resolve_provider(config)
  local p = config.terminal.provider
  if p == "snacks" or p == "native" or p == "none" then
    return p
  end
  -- p == "auto"
  -- TODO: when terminal/snacks.lua lands, prefer it via pcall(require, "snacks")
  return "native"
end

---Get the resolved provider module.
---@param config AutoAgentsConfig
---@return AutoAgentsTerminalProvider
function M.get(config)
  local resolved = M.resolve_provider(config)
  return require("auto-agents.terminal." .. resolved)
end

---Create a new terminal instance using the resolved provider.
---@param config AutoAgentsConfig
---@param spec AutoAgentsTerminalSpec
---@return AutoAgentsTerminalInstance
function M.new(config, spec)
  return M.get(config).new(spec)
end

return M
