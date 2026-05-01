---Admin slot 0 — interactive prompt buffer with command DSL (D7, M2.2).
---
---Replaces the M2.1 nofile placeholder. The buffer is a real prompt
---buffer (`buftype = "prompt"`); pressing <CR> on the prompt line
---fires our dispatch callback. Output is appended above the prompt
---like a REPL — the user always types at the bottom.
---
---Initial verb set: help/?/:h, status, agent focus N, agent list,
---clear, quit. M2.4 layers tab completion; M2.5 layers the form
---buffer for `agent add`/`agent edit`. Resource/kb verbs land in M5/M4.
---@module 'auto-agents.panel.admin'

local M = {}

M._bufnr = nil

-- ── helpers ─────────────────────────────────────────────────────────────────

local function buf_valid()
  return M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr)
end

---Insert lines just above the prompt (always the last line of the buffer).
---@param lines string[]
local function emit(lines)
  if not buf_valid() or #lines == 0 then return end
  local count = vim.api.nvim_buf_line_count(M._bufnr)
  vim.api.nvim_buf_set_lines(M._bufnr, count - 1, count - 1, false, lines)
end

-- ── command outputs ─────────────────────────────────────────────────────────

local function help_lines()
  return {
    "",
    "Commands:",
    "  help, ?, :h        show this help",
    "  status             list agent slots and their state",
    "  agent focus <N>    focus slot N (0..9)",
    "  agent list         list configured agents (alias for status)",
    "  clear              wipe history above the prompt",
    "  quit               close the auto-agents panel",
    "",
    "Future: agent add/edit/kill/move, kb *, resource *, config * (M2.5+).",
    "",
  }
end

local function status_lines()
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  local by_slot = {}
  for _, e in ipairs(bs) do by_slot[e.slot] = e end

  local lines = { "", "Agent slots:" }
  for slot = 0, 9 do
    local label, state
    if slot == 0 then
      label = "admin"
      state = "active"
    else
      local entry = by_slot[slot]
      if entry then
        label = entry.title or entry.name or entry.kind or "agent"
      else
        label = "(empty → shell)"
      end
      if slot >= 5 then
        local float = require("auto-agents.float")
        local fb = float.get_bufnr(slot)
        state = (fb and vim.api.nvim_buf_is_valid(fb)) and "running" or "-"
      else
        local term = aa.state.slot_terminals[slot]
        state = (term and term:is_alive()) and "running" or "-"
      end
    end
    local marker = (slot == aa.state.focused_slot) and "→" or " "
    table.insert(lines, string.format(" %s %d  %-22s %s", marker, slot, label, state))
  end
  table.insert(lines, "")
  return lines
end

-- ── dispatch ────────────────────────────────────────────────────────────────

local function tokenize(input)
  local toks = {}
  for tok in input:gmatch("%S+") do table.insert(toks, tok) end
  return toks
end

local function dispatch(input)
  input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return end

  local toks = tokenize(input)
  local verb = toks[1]

  if verb == "help" or verb == "?" or verb == ":h" then
    emit(help_lines())

  elseif verb == "status" then
    emit(status_lines())

  elseif verb == "clear" then
    if buf_valid() then
      local last = vim.api.nvim_buf_line_count(M._bufnr)
      if last > 1 then
        vim.api.nvim_buf_set_lines(M._bufnr, 0, last - 1, false, {})
      end
    end

  elseif verb == "quit" then
    emit({ "Closing panel." })
    vim.schedule(function() require("auto-agents").close() end)

  elseif verb == "agent" then
    local sub = toks[2]
    if sub == "focus" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent focus: missing slot number (0..9)" })
      else
        emit({ "Focusing slot " .. n .. "..." })
        vim.schedule(function() require("auto-agents").focus_slot(n) end)
      end
    elseif sub == "list" then
      emit(status_lines())
    elseif sub == "add" then
      emit({ "Opening new-agent form…" })
      vim.schedule(function() require("auto-agents.panel.form").open_add() end)
    elseif sub == "edit" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent edit: missing slot number (1..9)" })
      else
        emit({ "Opening edit form for slot " .. n .. "…" })
        vim.schedule(function() require("auto-agents.panel.form").open_edit(n) end)
      end
    else
      emit({ "agent: unknown subverb '" .. tostring(sub) .. "' (try '?')" })
    end

  else
    emit({ "unknown command '" .. verb .. "' — type ? for help" })
  end
end

-- ── tab completion (D15) ───────────────────────────────────────────────────

local PROMPT = "auto-agents> "

---Compute completion candidates given the prompt text + cursor col.
---@param prompt string  -- line content after the prompt prefix
---@param cursor_col integer  -- 0-indexed cursor byte col within `prompt`
---@return integer token_start  -- 0-indexed start col of the current token
---@return string[] candidates  -- filtered, in display order
local function complete_at(prompt, cursor_col)
  local before = prompt:sub(1, cursor_col)
  local current = before:match("(%S*)$") or ""
  local token_start = #before - #current

  local prev_toks = {}
  for tok in before:sub(1, token_start):gmatch("%S+") do
    table.insert(prev_toks, tok)
  end

  local candidates
  if #prev_toks == 0 then
    candidates = { "help", "?", ":h", "status", "agent", "clear", "quit" }
  elseif #prev_toks == 1 and prev_toks[1] == "agent" then
    candidates = { "focus", "list", "add", "edit" }
  elseif #prev_toks == 2 and prev_toks[1] == "agent"
    and (prev_toks[2] == "focus" or prev_toks[2] == "edit") then
    candidates = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  else
    candidates = {}
  end

  if current ~= "" then
    local filtered = {}
    for _, c in ipairs(candidates) do
      if vim.startswith(c, current) then table.insert(filtered, c) end
    end
    candidates = filtered
  end

  return token_start, candidates
end

---Trigger completion for the current admin buffer prompt line.
local function trigger_complete()
  local line = vim.api.nvim_get_current_line()
  if not vim.startswith(line, PROMPT) then return end

  local col = vim.fn.col(".") - 1  -- 0-indexed byte col in line
  if col < #PROMPT then return end

  local prompt = line:sub(#PROMPT + 1)
  local token_start, candidates = complete_at(prompt, col - #PROMPT)
  if #candidates == 0 then return end

  -- vim.fn.complete uses 1-indexed buffer col
  vim.fn.complete(#PROMPT + token_start + 1, candidates)
end

-- Exposed for tests; not part of the public surface.
M._complete_at = complete_at

-- ── public API ──────────────────────────────────────────────────────────────

---Get or lazily create the singleton admin buffer (slot 0).
---@return integer bufnr
function M.get_or_create_buffer()
  if buf_valid() then return M._bufnr end

  local bufnr = vim.api.nvim_create_buf(false, false)
  -- buftype=prompt turns the last line into a prompt; <CR> in insert
  -- mode on that line fires the prompt_setcallback.
  vim.bo[bufnr].buftype = "prompt"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].filetype = "auto-agents-admin"
  vim.api.nvim_buf_set_name(bufnr, "auto-agents://admin")

  vim.fn.prompt_setprompt(bufnr, PROMPT)
  vim.fn.prompt_setcallback(bufnr, function(input)
    -- Defer dispatch so vim has time to add the new prompt line. Without
    -- this, our emit() (which inserts before the last/prompt line) would
    -- land in the wrong slot — between the user's input and the new
    -- prompt rather than above the new prompt.
    vim.schedule(function() dispatch(input) end)
  end)

  -- Tab completion (D15). Buffer-local so we don't interfere with <Tab>
  -- elsewhere. Falls through to <C-n> if the popup is already showing.
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then return "<C-n>" end
    vim.schedule(trigger_complete)
    return ""
  end, { buffer = bufnr, expr = true, silent = true })
  vim.keymap.set("i", "<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then return "<C-p>" end
    return "<S-Tab>"
  end, { buffer = bufnr, expr = true, silent = true })

  -- Banner: written before the auto-generated prompt line at index 0.
  local banner = {
    "auto-agents v0.1.0-pre.1 — orchestration admin (slot 0)",
    "Type ? for help. Try 'status' to see slot states.",
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, banner)

  M._bufnr = bufnr
  return bufnr
end

---@return integer|nil
function M.get_bufnr()
  if buf_valid() then return M._bufnr end
  return nil
end

---For tests / external callers that want to drive the DSL programmatically.
---@param input string
function M.dispatch(input)
  dispatch(input)
end

return M
