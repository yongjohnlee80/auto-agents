---Winbar tab-strip for the main panel window (D10, M2.3). Renders all
---five main slots (0..4) side by side with the focused one bracketed.
---Each slot is wrapped in a clickable region — left-click on a slot
---focuses it, no keyboard required.
---@module 'auto-agents.panel.winbar'

local M = {}

---Click handler invoked by `%N@v:lua.require'…winbar'.click@…%X` regions.
---The slot number is encoded in the statusline `minwid` field, which vim
---passes as the first argument.
---@param minwid integer  -- the slot number 0..4
---@param _clicks integer
---@param _button string
---@param _mods string
function M.click(minwid, _clicks, _button, _mods)
  require("auto-agents").focus_slot(minwid)
end

---@param slot integer
---@return string
local function slot_label(slot)
  if slot == 0 then return "admin" end
  local cfg = require("auto-agents").state.config
  if not cfg then return "shell" end
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  for _, e in ipairs(bs) do
    if e.slot == slot then
      return e.title or e.name or e.kind or "agent"
    end
  end
  return "shell"
end

---Build the winbar string. Adaptive: tries to render every slot with
---its label; if the result wouldn't fit in `available_width`, falls
---back to a compact format where only the focused slot keeps its label
---and others show just the number.
---@param focused_slot integer  -- 0..MAIN_SLOT_MAX
---@param available_width integer|nil  -- panel window width; nil disables the fit check
---@return string
function M.render(focused_slot, available_width)
  local main_max = require("auto-agents").MAIN_SLOT_MAX or 5

  -- Plain-text length (excluding %<minwid>@..%X click markup and %#hl#..%*
  -- highlight markup, which contribute zero displayed width). Each slot
  -- renders as either ' N: Label ' (10 + #label, the surrounding spaces
  -- are the inter-slot gap) or '[N: Label]' for focused (4 + #label).
  -- Separators between slots are single spaces.
  local labels = {}
  local full_len = 0
  for slot = 0, main_max do
    local label = slot_label(slot)
    labels[slot] = label
    if slot == focused_slot then
      full_len = full_len + 4 + #tostring(slot) + #label
    else
      full_len = full_len + 4 + #tostring(slot) + #label  -- ' N: label '
    end
  end
  full_len = full_len + main_max  -- inter-slot single spaces

  local use_compact = available_width and available_width > 0 and full_len > available_width

  local parts = {}
  for slot = 0, main_max do
    local label = labels[slot]
    local text
    if slot == focused_slot then
      text = string.format("%%#AutoAgentsSlotActive#[%d: %s]%%*", slot, label)
    elseif use_compact then
      text = string.format(" %d ", slot)
    else
      text = string.format(" %d: %s ", slot, label)
    end
    table.insert(
      parts,
      string.format("%%%d@v:lua.require'auto-agents.panel.winbar'.click@%s%%X", slot, text)
    )
  end
  return table.concat(parts, " ")
end

---Ensure default highlight links for the winbar slot groups exist.
---Idempotent — safe to call repeatedly. Users can override these in
---their colorscheme; we link rather than set explicit colors so they
---inherit theme-friendly defaults.
function M.ensure_highlights()
  -- Only set defaults if the user hasn't already defined the group.
  if vim.fn.hlexists("AutoAgentsSlotActive") == 0 then
    vim.api.nvim_set_hl(0, "AutoAgentsSlotActive", { link = "Title", default = true })
  end
end

return M
