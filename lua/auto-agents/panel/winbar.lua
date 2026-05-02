---Winbar tab-strip for the main panel window (D10, M2.3). Renders all
---five main slots (0..4) side by side with the focused one bracketed.
---Each slot is wrapped in a clickable region — left-click on a slot
---focuses it, no keyboard required.
---
---Status sigils (added in v0.1.3): when an agent self-reports a
---non-idle status via `:AutoAgentsStatus`, a sigil precedes the label:
---`*` for waiting (user input expected), `+` for working. Idle agents
---render plain. Sigils get their own highlight group so a glance
---across the strip surfaces who needs attention without reading names.
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

---Resolve a slot to its display label and current status sigil.
---@param slot integer
---@return string label
---@return string sigil  "" | "*" (waiting) | "+" (working)
local function slot_render(slot)
  if slot == 0 then return "admin", "" end
  local aa = require("auto-agents")
  local cfg = aa.state.config
  if not cfg then return "shell", "" end
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  for _, e in ipairs(bs) do
    if e.slot == slot then
      local label = e.title or e.name or e.kind or "agent"
      local status = aa.state.agent_status[slot]
      local sigil = (status == "waiting" and "*")
        or (status == "working" and "+")
        or ""
      return label, sigil
    end
  end
  return "shell", ""
end

---@param sigil string
---@return string|nil hl_group
local function sigil_hl(sigil)
  if sigil == "*" then return "AutoAgentsStatusWaiting" end
  if sigil == "+" then return "AutoAgentsStatusWorking" end
  return nil
end

---Build the winbar string. Adaptive: tries to render every slot with
---its label; if the result wouldn't fit in `available_width`, falls
---back to a compact format where unfocused slots show only `N` (or
---`N<sigil>` when status is non-idle), and the focused slot keeps
---its label.
---@param focused_slot integer  -- 0..MAIN_SLOT_MAX
---@param available_width integer|nil  -- panel window width; nil disables the fit check
---@return string
function M.render(focused_slot, available_width)
  local main_max = require("auto-agents").MAIN_SLOT_MAX or 5

  -- Plain-text length (excluding %<minwid>@..%X click markup and
  -- %#hl#..%* highlight markup, which contribute zero displayed width).
  -- Each slot renders as ' N: <sigil>label ' (10 + #label + #sigil) or
  -- '[N: <sigil>label]' for focused (same length). Single-space separators.
  local labels, sigils = {}, {}
  local full_len = 0
  for slot = 0, main_max do
    local label, sigil = slot_render(slot)
    labels[slot] = label
    sigils[slot] = sigil
    full_len = full_len + 4 + #tostring(slot) + #label + #sigil
  end
  full_len = full_len + main_max  -- inter-slot single spaces

  local use_compact = available_width and available_width > 0 and full_len > available_width

  local parts = {}
  for slot = 0, main_max do
    local label, sigil = labels[slot], sigils[slot]
    local hl = sigil_hl(sigil)
    local text
    if slot == focused_slot then
      -- Focused row carries a single Title-linked highlight across the
      -- whole bracket. The sigil sits inside it and inherits — keeping
      -- the active row visually unified is more important than the
      -- sigil's own color when this slot already has the user's eye.
      text = string.format("%%#AutoAgentsSlotActive#[%d: %s%s]%%*",
        slot, sigil, label)
    elseif use_compact then
      if sigil == "" then
        text = string.format(" %d ", slot)
      else
        text = string.format(" %d%%#%s#%s%%* ", slot, hl, sigil)
      end
    else
      if sigil == "" then
        text = string.format(" %d: %s ", slot, label)
      else
        text = string.format(" %d: %%#%s#%s%%*%s ", slot, hl, sigil, label)
      end
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
  if vim.fn.hlexists("AutoAgentsSlotActive") == 0 then
    vim.api.nvim_set_hl(0, "AutoAgentsSlotActive", { link = "Title", default = true })
  end
  if vim.fn.hlexists("AutoAgentsStatusWaiting") == 0 then
    vim.api.nvim_set_hl(0, "AutoAgentsStatusWaiting", { link = "WarningMsg", default = true })
  end
  if vim.fn.hlexists("AutoAgentsStatusWorking") == 0 then
    vim.api.nvim_set_hl(0, "AutoAgentsStatusWorking", { link = "MoreMsg", default = true })
  end
end

return M
