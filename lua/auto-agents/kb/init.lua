---Knowledge-base path resolution + scaffolding (D4/D16, M4 chunk A).
---
---Default layout (D16):
---  <kb_root>/
---  ├── shared/
---  │   ├── notes/
---  │   └── synthesis/
---  ├── agents/
---  │   └── <agent-name>/
---  └── log.md
---
---kb_root resolution:
---  1. cfg.kb.path (user override; expanded for ~)
---  2. <git-root>/.auto-agents/kb     (if in a git repo)
---  3. <cwd>/.auto-agents/kb          (otherwise)
---@module 'auto-agents.kb'

local M = {}

---@return string
function M.root()
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local kb_cfg = cfg.kb or {}
  if kb_cfg.path and kb_cfg.path ~= "" then
    return vim.fn.expand(kb_cfg.path)
  end
  local cwd_mod = require("auto-agents.cwd")
  local base = cwd_mod.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  return base .. "/.auto-agents/kb"
end

---Ensure the canonical directory layout exists. Idempotent.
---@param root string|nil  -- defaults to M.root()
function M.ensure_layout(root)
  root = root or M.root()
  vim.fn.mkdir(root,                  "p")
  vim.fn.mkdir(root .. "/shared",     "p")
  vim.fn.mkdir(root .. "/shared/notes", "p")
  vim.fn.mkdir(root .. "/shared/synthesis", "p")
  vim.fn.mkdir(root .. "/agents",     "p")
  -- log.md as an empty append-only stub
  local log = root .. "/log.md"
  if vim.fn.filereadable(log) == 0 then
    local f = io.open(log, "w")
    if f then
      f:write("# auto-agents knowledge-base log\n\n")
      f:close()
    end
  end
  return root
end

---Append a one-line entry to log.md (timestamp + message).
---@param msg string
function M.log(msg)
  local root = M.root()
  M.ensure_layout(root)
  local f = io.open(root .. "/log.md", "a")
  if not f then return end
  f:write(string.format("- %s — %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
  f:close()
end

---Resolve a relative path against the KB root.
---@param relative string
---@return string
function M.resolve(relative)
  local root = M.root()
  -- Strip a leading slash so users can write either "shared/foo" or "/shared/foo".
  relative = relative:gsub("^/+", "")
  return root .. "/" .. relative
end

return M
