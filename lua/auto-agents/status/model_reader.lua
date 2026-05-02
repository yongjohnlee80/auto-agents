---Parse the currently-active model from an agent's terminal buffer.
---
---Each TUI agent renders its active model somewhere in the visible
---status area (typically the bottom 1-3 lines). We capture it with a
---per-kind regex, then normalise the display name to an API model ID
---so it can be compared against (and written back to) the TOML spec.
---
---Supported kinds: claude, codex, gemini.
---Others return nil — callers should treat nil as "cannot read".
---
---@module 'auto-agents.status.model_reader'

local M = {}

-- ── display-name → API ID maps ────────────────────────────────────────────
-- Keyed by the normalised display string we extract from the terminal.
-- Where a model has a date-stamped API ID, the exact ID is listed;
-- otherwise we derive it from the family+version pattern below.

---@type table<string, string>
M.claude_id_map = {
  -- 4.x family (no date suffix in API ID)
  ["opus 4.7"]    = "claude-opus-4-7",
  ["sonnet 4.6"]  = "claude-sonnet-4-6",
  ["opus 4.5"]    = "claude-opus-4-5",
  ["sonnet 4.5"]  = "claude-sonnet-4-5-20241022",
  ["haiku 4.5"]   = "claude-haiku-4-5-20251001",
  -- 3.x family
  ["opus 3.5"]    = "claude-opus-3-5",
  ["sonnet 3.5"]  = "claude-sonnet-3-5-20241022",
  ["haiku 3.5"]   = "claude-haiku-3-5-20241022",
  ["opus 3"]      = "claude-opus-3",
  ["sonnet 3"]    = "claude-sonnet-3",
  ["haiku 3"]     = "claude-haiku-3",
}

---Derive an API ID for claude models not in the explicit map.
---Falls back to `claude-<family>-<major>-<minor>` (lowercase, no date).
---@param family string  e.g. "Opus"
---@param version string  e.g. "4.7"
---@return string
local function claude_fallback_id(family, version)
  local ver = version:gsub("%.", "-")
  return "claude-" .. family:lower() .. "-" .. ver
end

-- ── per-kind readers ──────────────────────────────────────────────────────

---@class AutoAgentsModelInfo
---@field display string   Human-readable name, e.g. "Sonnet 4.6 (1M context)"
---@field api_id  string   Canonical API model ID, e.g. "claude-sonnet-4-6"

---Extract model info from a Claude Code terminal buffer.
---Status-bar line format (bottom ~3 lines):
---  "  …/path  branch  <Model Name>  ctx:NN%  ..."
---@param lines string[]
---@return AutoAgentsModelInfo|nil
local function read_claude(lines)
  for i = #lines, 1, -1 do
    local line = lines[i]
    -- Match "  Opus 4.7 (…) " or "  Sonnet 4.6 " etc. in the status bar.
    -- The model display is always preceded by two or more spaces and
    -- followed by spaces + "ctx:".
    local family, version = line:match("%s+(Opus)%s+(%d+%.%d+)%s")
    if not family then
      family, version = line:match("%s+(Sonnet)%s+(%d+%.%d+)%s")
    end
    if not family then
      family, version = line:match("%s+(Haiku)%s+(%d+%.%d+)%s")
    end
    if family and version then
      local display = family .. " " .. version
      -- Capture optional parenthetical suffix for the human label.
      local suffix = line:match(family .. "%s+" .. version .. "%s+(%b())")
      local full_display = suffix and (display .. " " .. suffix) or display
      local key = display:lower()
      local api_id = M.claude_id_map[key] or claude_fallback_id(family, version)
      return { display = full_display, api_id = api_id }
    end
  end
  return nil
end

---Extract model info from a Codex terminal buffer.
---Status-bar line format:
---  "  <model-id> <effort> · <path> · Context NN% left · ..."
---  e.g. "  gpt-5.5 xhigh · ~/.config/nvim · Context 56% left"
---@param lines string[]
---@return AutoAgentsModelInfo|nil
local function read_codex(lines)
  for i = #lines, 1, -1 do
    local line = lines[i]
    -- Codex status line starts with two spaces then the model id.
    local model = line:match("^%s+([%a%d%.%-]+)%s+%a+%s+·")
    if not model then
      -- Alternate: "  model · path · ..."
      model = line:match("^%s+([%a%d%.%-]+)%s+·")
    end
    if model and model ~= "" then
      return { display = model, api_id = model }
    end
  end
  return nil
end

---Extract model info from a Gemini CLI terminal buffer.
---Gemini CLI typically shows the model in the status area as
---"gemini-2.5-pro" or "gemini-2.5-flash".
---@param lines string[]
---@return AutoAgentsModelInfo|nil
local function read_gemini(lines)
  for i = #lines, 1, -1 do
    local line = lines[i]
    local model = line:match("(gemini%-[%d%.%-a-z]+)")
    if model and model ~= "" then
      return { display = model, api_id = model }
    end
  end
  return nil
end

-- ── public API ────────────────────────────────────────────────────────────

---Read the currently-active model from an agent's terminal buffer.
---Returns nil when the kind is unsupported or the pattern doesn't match
---(e.g. agent is mid-scroll, or the status line isn't visible yet).
---@param bufnr integer
---@param kind  string
---@return AutoAgentsModelInfo|nil
function M.read(bufnr, kind)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil end
  local n = vim.api.nvim_buf_line_count(bufnr)
  if n == 0 then return nil end
  local lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, n - 6), n, false)

  if kind == "claude"  then return read_claude(lines)  end
  if kind == "codex"   then return read_codex(lines)   end
  if kind == "gemini"  then return read_gemini(lines)  end
  return nil
end

return M