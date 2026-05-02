---Per-kind regex patterns for passive status detection.
---
---Activity-based working/idle detection is the load-bearing path; these
---patterns just refine it with a `waiting` (needs-user-input) signal that
---activity alone can't infer — when the agent is stopped at a permission
---prompt, no output is being produced, so pure activity detection would
---call it "idle".
---
---Each kind has two pattern lists:
---  - `working`: transient indicators that the agent is mid-turn (e.g.
---    "esc to interrupt"). Used as a confirming signal alongside recent
---    output. Helps when an agent prints a long blocking message that
---    happens to land on a quiet sub-second.
---  - `waiting`: yes/no permission prompts and similar "user must answer"
---    UI. Conservative on purpose — false positives (red sigil that's
---    wrong) are worse than false negatives (which the user can override
---    via `:AutoAgentsStatus <slot> waiting`).
---
---Patterns are matched against the bottom ~12 lines of the terminal
---buffer (where TUI prompts live). Plain Lua patterns, not vim regex.
---
---@module 'auto-agents.status.patterns'

local M = {}

---@class AutoAgentsStatusPatterns
---@field working string[]
---@field waiting string[]

---@type table<string, AutoAgentsStatusPatterns>
M.by_kind = {
  claude = {
    working = {
      "esc to interrupt",
      "ctrl%-c to interrupt",
      "Thinking%.%.%.",
    },
    waiting = {
      -- Yes/No permission prompts: "Do you want to proceed?" with
      -- numbered choices like "❯ 1. Yes" / "  2. No".
      "Do you want to[^\n]*",
      "❯%s+%d+%.%s+Yes",
      -- Plan-mode acknowledgements
      "Would you like to proceed",
    },
  },
  codex = {
    working = {
      "esc to interrupt",
      "%(working[%.…]*%)",
      "%(thinking[%.…]*%)",
    },
    waiting = {
      -- "Allow this command? (y/n)" / "Approve? [y/N]" style.
      "%[y/N%]",
      "%(y/n%)",
      "Allow this[^\n]*%?",
      "Approve[^\n]*%?",
    },
  },
  gemini = {
    working = {
      "esc to interrupt",
      "Thinking[%.…]*",
    },
    waiting = {
      "%(y/n%)",
      "%[y/N%]",
    },
  },
}

---Match the bottom-of-buffer lines against a pattern list.
---@param lines string[]
---@param patterns string[]
---@return boolean
local function any_match(lines, patterns)
  if not patterns or #patterns == 0 then return false end
  for _, line in ipairs(lines) do
    for _, pat in ipairs(patterns) do
      if line:find(pat) then return true end
    end
  end
  return false
end

---Inspect the tail of a terminal buffer and return any inferred state,
---or nil if the patterns don't match anything (caller falls back to
---activity-based decision).
---@param bufnr integer
---@param kind string
---@return "working"|"waiting"|nil
function M.classify(bufnr, kind)
  local pats = M.by_kind[kind]
  if not pats then return nil end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, n - 12), n, false)
  if any_match(lines, pats.waiting) then return "waiting" end
  if any_match(lines, pats.working) then return "working" end
  return nil
end

return M