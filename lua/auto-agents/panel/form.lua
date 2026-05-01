---Form buffer for `agent add` / `agent edit` (D14, M2.5). A small
---floating window with labeled fields the user edits in place.
---<C-s> validates and applies; <Esc>/q cancels.
---
---Schema-side this mutates `state.config.agents.bootstrap` in-memory.
---TOML write-back lands when D12 config-loader is implemented (M3+).
---@module 'auto-agents.panel.form'

local M = {}

---@class AutoAgentsFormField
---@field name string
---@field default string
---@field width integer

local FIELDS = {
  { name = "kind",          default = "claude" },
  { name = "slot",          default = "" },
  { name = "name",          default = "" },
  { name = "title",         default = "" },
  { name = "role",          default = "" },
  { name = "cwd",           default = "" },
  { name = "allowed_paths", default = "" },
  { name = "manager",       default = "" },
  { name = "kb_scope",      default = "shared" },
  { name = "bottom_margin", default = "" },  -- empty = inherit panel default
}

local LABEL_WIDTH = 16  -- " allowed_paths: " padding column

local _state = { winid = nil, bufnr = nil, mode = "add", target_slot = nil }

-- ── helpers ─────────────────────────────────────────────────────────────────

local function format_field_line(name, value)
  return string.format("  %-" .. LABEL_WIDTH .. "s%s", name .. ":", value or "")
end

local function build_lines(values)
  local lines = { "" }
  for _, f in ipairs(FIELDS) do
    table.insert(lines, format_field_line(f.name, values[f.name] or f.default))
  end
  table.insert(lines, "")
  table.insert(lines, "  <C-s> save   <Esc> cancel")
  return lines
end

local function parse_form()
  if not (_state.bufnr and vim.api.nvim_buf_is_valid(_state.bufnr)) then return {} end
  local lines = vim.api.nvim_buf_get_lines(_state.bufnr, 0, -1, false)
  local values = {}
  for _, line in ipairs(lines) do
    -- Match "  fieldname:   value"
    local n, v = line:match("^%s*([%w_]+):%s*(.-)%s*$")
    if n then values[n] = v end
  end
  return values
end

local function close()
  if _state.winid and vim.api.nvim_win_is_valid(_state.winid) then
    pcall(vim.api.nvim_win_close, _state.winid, true)
  end
  if _state.bufnr and vim.api.nvim_buf_is_valid(_state.bufnr) then
    pcall(vim.api.nvim_buf_delete, _state.bufnr, { force = true })
  end
  -- Mutate, don't reassign — M._state holds a reference to this table.
  _state.winid = nil
  _state.bufnr = nil
  _state.mode = "add"
  _state.target_slot = nil
end

---Validate and apply the form. Mutates the in-memory bootstrap list.
---@return boolean ok
---@return string|nil err
local function apply()
  local v = parse_form()
  local slot = tonumber(v.slot)
  if not slot or slot < 1 or slot > 9 then
    return false, "slot must be 1..9 (got '" .. tostring(v.slot) .. "')"
  end
  local valid_kinds = { claude = true, codex = true, gemini = true, copilot = true, generic = true }
  if v.kind ~= "" and not valid_kinds[v.kind] then
    return false, "kind must be claude|codex|gemini|generic (got '" .. v.kind .. "')"
  end
  local valid_scopes = { shared = true, private = true, isolated = true, [""] = true }
  if not valid_scopes[v.kb_scope] then
    return false, "kb_scope must be shared|private|isolated (got '" .. v.kb_scope .. "')"
  end

  local entry = {
    slot = slot,
    kind = (v.kind ~= "" and v.kind) or "generic",
    name = (v.name ~= "" and v.name) or nil,
    title = (v.title ~= "" and v.title) or nil,
    role = (v.role ~= "" and v.role) or nil,
    cwd = (v.cwd ~= "" and v.cwd) or nil,
    manager = (v.manager ~= "" and v.manager) or nil,
    kb_scope = (v.kb_scope ~= "" and v.kb_scope) or nil,
  }
  if v.bottom_margin and v.bottom_margin ~= "" then
    local n = tonumber(v.bottom_margin)
    if not n or n < 0 or n ~= math.floor(n) then
      return false, "bottom_margin must be a non-negative integer (got '" .. v.bottom_margin .. "')"
    end
    entry.bottom_margin = n
  end
  if v.allowed_paths and v.allowed_paths ~= "" then
    local paths = {}
    for p in v.allowed_paths:gmatch("[^,]+") do
      local trimmed = p:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed ~= "" then table.insert(paths, trimmed) end
    end
    entry.allowed_paths = paths
  end

  local cfg = require("auto-agents").state.config
  if not cfg then return false, "auto-agents.setup() must be called first" end
  cfg.agents = cfg.agents or {}
  cfg.agents.bootstrap = cfg.agents.bootstrap or {}
  -- Remove any existing entry for this slot, then append.
  for i = #cfg.agents.bootstrap, 1, -1 do
    if cfg.agents.bootstrap[i].slot == slot then
      table.remove(cfg.agents.bootstrap, i)
    end
  end
  table.insert(cfg.agents.bootstrap, entry)
  return true, nil
end

local function save()
  local ok, err = apply()
  if not ok then
    vim.notify("auto-agents form: " .. err, vim.log.levels.ERROR)
    return
  end
  local v = parse_form()
  local slot = tonumber(v.slot)
  close()
  -- Refresh <leader>a[0..9] descriptions so which-key reflects the new
  -- agent label.
  pcall(function() require("auto-agents").refresh_keymaps() end)
  -- Persist mutation so it survives nvim restart (M3.4).
  pcall(function() require("auto-agents.agent.persist").save_current() end)
  if slot then
    vim.schedule(function() require("auto-agents").focus_slot(slot) end)
  end
end

-- ── public API ──────────────────────────────────────────────────────────────

---@param opts { mode: "add"|"edit", slot: integer|nil }|nil
function M.open(opts)
  opts = opts or { mode = "add" }
  local mode = opts.mode or "add"
  local target_slot = opts.slot

  -- Close any existing form first.
  if _state.winid and vim.api.nvim_win_is_valid(_state.winid) then close() end

  -- Pre-populate from existing bootstrap entry if editing.
  local values = {}
  if mode == "edit" and target_slot then
    local cfg = require("auto-agents").state.config
    local bs = (cfg and cfg.agents and cfg.agents.bootstrap) or {}
    for _, e in ipairs(bs) do
      if e.slot == target_slot then
        for _, f in ipairs(FIELDS) do
          local val = e[f.name]
          if f.name == "allowed_paths" and type(val) == "table" then
            values[f.name] = table.concat(val, ", ")
          elseif val ~= nil then
            values[f.name] = tostring(val)
          end
        end
        break
      end
    end
    if not values.slot then values.slot = tostring(target_slot) end
  end

  local lines = build_lines(values)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "auto-agents-form"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local width = 56
  local height = #lines
  local title_text = (mode == "edit")
    and string.format(" Edit Agent (slot %s) ", tostring(target_slot or "?"))
    or " New Agent "

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title_text,
    title_pos = "center",
    focusable = true,
    zindex = 250,
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })

  -- Position cursor on the first editable field's value column.
  pcall(vim.api.nvim_win_set_cursor, winid, { 2, LABEL_WIDTH + 2 })

  _state.winid = winid
  _state.bufnr = bufnr
  _state.mode = mode
  _state.target_slot = target_slot

  -- Keymaps. <C-s> saves from normal OR insert; <Esc>/q cancel from normal.
  -- Insert-mode <Esc> still does its vim default (exit to normal).
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    save()
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "q",     close, { buffer = bufnr, silent = true })

  -- F-key passthrough so summoning the dock or snacks helpers from inside
  -- the form (in insert mode) works without dropping the keys as garbage.
  for i = 1, 12 do
    local lhs = "<F" .. i .. ">"
    local termcoded = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.keymap.set("i", lhs, function()
      vim.cmd("stopinsert")
      vim.api.nvim_feedkeys(termcoded, "m", false)
    end, { buffer = bufnr, silent = true })
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr,
    once = true,
    callback = function() vim.schedule(close) end,
  })
end

function M.open_add()  M.open({ mode = "add" }) end

function M.open_edit(slot)  M.open({ mode = "edit", slot = slot }) end

-- Test hooks (not part of public surface).
M._parse = parse_form
M._apply = apply
M._state = _state

return M
