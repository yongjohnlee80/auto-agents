---Step-by-step wizard runner inside the admin prompt buffer (M6).
---
---Replaces the floating-window form (panel/form.lua, removed). The
---wizard is a state machine: each step asks one question, the user's
---input feeds into accumulated values, and `<C-c>` aborts at any point.
---
---Used by:
---  agent.add / agent.edit
---  kb.new / kb.scope
---  project.import (when no selector arg)
---
---Lifecycle:
---  start({ steps, on_complete, banner }) — render banner + first prompt
---  feed(input)                            — admin dispatch routes here
---                                            while is_active() is true
---  cancel()                               — abort; clears state
---  is_active()                            — admin checks this on each
---                                            <CR> before normal dispatch
---
---@module 'auto-agents.panel.wizard'

local M = {}

---@class AutoAgentsWizardStep
---@field field string                                 -- key to set in values
---@field prompt string                                -- shown above the input
---@field default string|nil                           -- prepopulated default
---@field choices string[]|nil                         -- shown after prompt as " (a|b|c)"
---@field placeholder string|nil                       -- shown as "[<placeholder>]"
---@field validate (fun(value: string, values: table): boolean, string?)|nil
---@field parse (fun(value: string): any)|nil          -- transforms input → final value
---@field skip (fun(values: table): boolean)|nil       -- skip step if true

---@class AutoAgentsWizardSpec
---@field name string                                  -- for log/error context
---@field banner string|nil                            -- one-line intro
---@field steps AutoAgentsWizardStep[]
---@field on_complete fun(values: table, emit: fun(string[]))
---@field on_cancel (fun(emit: fun(string[])))|nil

---@class AutoAgentsWizardState
---@field active boolean
---@field spec AutoAgentsWizardSpec|nil
---@field index integer                                -- 1-based step pointer
---@field values table                                 -- accumulated answers
---@field emit fun(lines: string[])|nil

local _state = {
  active = false,
  spec = nil,
  index = 0,
  values = {},
  emit = nil,
}

-- Exposed for tests + admin's <C-c> binding.
M._state = _state

local function reset()
  _state.active = false
  _state.spec = nil
  _state.index = 0
  _state.values = {}
  _state.emit = nil
end

local function compose_question(step, values)
  local default = step.default
  if type(default) == "function" then default = default(values) end
  local placeholder = step.placeholder
    or (default ~= nil and default ~= "" and tostring(default) or nil)
  local hint = ""
  if step.choices and #step.choices > 0 then
    hint = " (" .. table.concat(step.choices, "|") .. ")"
  end
  local default_hint = placeholder and ("  [" .. placeholder .. "]") or ""
  return step.prompt .. hint .. default_hint .. ":"
end

local function render_step()
  local emit = _state.emit
  local step = _state.spec.steps[_state.index]
  if not step then return end
  emit({ "  " .. compose_question(step, _state.values) })
end

local function advance()
  while true do
    _state.index = _state.index + 1
    local step = _state.spec.steps[_state.index]
    if not step then
      -- Done.
      local emit = _state.emit
      local values = _state.values
      local on_complete = _state.spec.on_complete
      reset()
      pcall(on_complete, values, emit)
      return
    end
    if step.skip and step.skip(_state.values) then
      -- Apply default for skipped step (if any) so on_complete sees it.
      if step.default ~= nil then _state.values[step.field] = step.default end
    else
      render_step()
      return
    end
  end
end

---Is a wizard currently waiting for input? Admin checks this on each
---<CR> before falling through to normal verb dispatch.
---@return boolean
function M.is_active() return _state.active end

---Start a wizard. The admin prompt buffer's <CR> callback should route
---input through M.feed() while M.is_active() is true.
---@param spec AutoAgentsWizardSpec
---@param emit fun(lines: string[])
function M.start(spec, emit)
  if _state.active then
    emit({ "wizard: a previous wizard is still active — <C-c> to cancel" })
    return
  end
  _state.active = true
  _state.spec = spec
  _state.values = {}
  _state.index = 0
  _state.emit = emit
  if spec.banner then emit({ "", spec.banner, "  <C-c> to cancel." }) end
  advance()
end

---Feed one line of user input. Validates against the current step,
---records the value (or default if blank), and renders the next step.
---@param input string
function M.feed(input)
  if not _state.active then return end
  local step = _state.spec.steps[_state.index]
  if not step then reset(); return end

  local emit = _state.emit
  local raw = input or ""

  -- Blank input → use default if any. If default is also empty, store "".
  local value
  if raw == "" then
    local d = step.default
    if type(d) == "function" then d = d(_state.values) end
    value = d
  else
    value = raw
  end

  if step.parse then
    local ok, parsed = pcall(step.parse, value)
    if not ok then
      emit({ "  ! " .. tostring(parsed) })
      render_step()
      return
    end
    value = parsed
  end

  if step.validate then
    local ok, err = step.validate(value, _state.values)
    if not ok then
      emit({ "  ! " .. (err or "invalid value") })
      render_step()
      return
    end
  end

  _state.values[step.field] = value
  advance()
end

---Cancel the active wizard. Safe to call when inactive.
function M.cancel()
  if not _state.active then return end
  local emit = _state.emit
  local on_cancel = _state.spec.on_cancel
  reset()
  if emit then emit({ "  (wizard cancelled)" }) end
  if on_cancel then pcall(on_cancel, emit) end
end

return M
