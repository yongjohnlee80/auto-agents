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

---Build the winbar string.
---@param focused_slot integer  -- 0..4
---@return string
function M.render(focused_slot)
  local parts = {}
  for slot = 0, 4 do
    local label = slot_label(slot)
    local text
    if slot == focused_slot then
      -- Bracketed + highlighted via the AutoAgentsSlotActive group. The
      -- group is defined lazily via M.ensure_highlights so users can
      -- override colors via their colorscheme.
      text = string.format("%%#AutoAgentsSlotActive#[%d: %s]%%*", slot, label)
    else
      text = string.format(" %d: %s ", slot, label)
    end
    -- %<minwid>@<func>@<text>%X  → click region. The slot number rides
    -- in `minwid` and surfaces as the first arg of M.click.
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
