---KB-aware spawn (M6, "double-down" approach).
---
---Each agent kind auto-loads a per-project instruction file from its
---cwd: claude reads `CLAUDE.md`, codex/copilot/generic read `AGENTS.md`,
---gemini reads `GEMINI.md`. We inject a delimited "auto-agents" block
---into that file so the agent learns its KB location and read/write
---convention without us having to send anything via stdin (which TUIs
---would treat as a prompt).
---
---The block is bounded by `<!-- auto-agents:begin -->` /
---`<!-- auto-agents:end -->`. Re-running `ensure()` rewrites just the
---block — the user's surrounding content is preserved.
---
---@module 'auto-agents.kb.instruct'

local M = {}

local BEGIN = "<!-- auto-agents:begin -->"
local END   = "<!-- auto-agents:end -->"

---Map an agent kind to the filename it auto-loads at its cwd.
---@param kind string
---@return string filename
function M.filename_for(kind)
  if kind == "claude"  then return "CLAUDE.md"  end
  if kind == "gemini"  then return "GEMINI.md"  end
  return "AGENTS.md"  -- codex, copilot, generic, anything else
end

---Render the auto-agents block content for a slot.
---@param spec table  -- { kind, name, slot, kb_scope }
---@param kb_root string
---@return string
local function render_block(spec, kb_root)
  local scope = spec.kb_scope or "shared"
  local agent_name = spec.name or ("agent" .. tostring(spec.slot or "?"))
  local aa_state = (require("auto-agents").state or {}).config or {}
  local kb_type = (aa_state.kb or {}).type or "general"
  return table.concat({
    BEGIN,
    "## auto-agents knowledge base",
    "",
    "This project uses [auto-agents.nvim](https://github.com/yongjohnlee80/auto-agents)",
    "for multi-agent orchestration. The agent in slot " .. tostring(spec.slot or "?")
      .. " (kind: " .. (spec.kind or "?") .. ", name: " .. agent_name .. ") has the",
    "following knowledge-base configured:",
    "",
    "- KB root:    `" .. kb_root .. "`  (`$AUTO_AGENTS_KB_ROOT`)",
    "- KB type:    `" .. kb_type .. "`",
    "- KB scope:   `" .. scope .. "`",
    "- Read from:  `$AUTO_AGENTS_KB_READ`  (colon-separated)",
    "- Write to:   `$AUTO_AGENTS_KB_WRITE` (single directory)",
    "",
    "### Read this first",
    "",
    "**The canonical schema for this KB is at `" .. kb_root .. "/AGENTS.md`.**",
    "Read it before any non-trivial KB operation. It defines the directory",
    "layout, the required frontmatter, the operations (ingest / review / lint /",
    "etc.), the immutability rule for `raw/`, and the things to avoid.",
    "",
    "Each KB type has its own contract — `coding`, `wiki`, `research`, `ops`,",
    "or `general`. The `AGENTS.md` at the KB root is authoritative for this",
    "specific KB; this file (auto-injected at the agent's cwd) is a minimal",
    "pointer with the env vars and a one-line convention summary.",
    "",
    "### Quick conventions",
    "",
    "- **`raw/` is immutable.** Read it; never edit or delete its contents.",
    "- **Read before writing.** Consult `shared/` for durable conventions and",
    "  your own `agents/" .. agent_name .. "/` for prior operational notes.",
    "- **Append, don't overwrite.** Use `[[wikilinks]]` to cross-reference.",
    "- **Audit trail.** Append a one-line entry to `log.md` after each",
    "  meaningful KB write (e.g. `## [2026-05-01 14:00] op | summary`).",
    "",
    END,
  }, "\n")
end

---Ensure the instruction file at `cwd/<kind-file>` contains an up-to-date
---auto-agents block. Idempotent. User content outside the block is
---preserved verbatim.
---
---@param spec table       -- { kind, name, slot, kb_scope, cwd }
---@param kb_root string
---@param cwd string|nil   -- defaults to spec.cwd or the session project root
---@return string|nil written_path
function M.ensure(spec, kb_root, cwd)
  cwd = cwd or spec.cwd
  if not cwd or cwd == "" then
    local aa = require("auto-agents")
    cwd = aa.state.session_project_root or aa.state.session_cwd
  end
  if not cwd or cwd == "" then return nil end

  local filename = M.filename_for(spec.kind or "generic")
  local path = cwd .. "/" .. filename
  local block = render_block(spec, kb_root)

  local f = io.open(path, "r")
  local existing = f and f:read("*a") or ""
  if f then f:close() end

  local new_content
  if existing == "" then
    new_content = block .. "\n"
  else
    local b_idx = existing:find(BEGIN, 1, true)
    local e_idx = existing:find(END,   1, true)
    if b_idx and e_idx and e_idx > b_idx then
      -- Replace the existing block (keep one trailing newline).
      local before = existing:sub(1, b_idx - 1)
      local after  = existing:sub(e_idx + #END)
      -- Trim leftover blank lines at the join points to avoid stacking.
      before = before:gsub("\n\n+$", "\n")
      after  = after:gsub("^\n+", "\n")
      new_content = before .. block .. after
    else
      -- Append (with a separator if the file doesn't already end in a newline).
      local sep = existing:sub(-1) == "\n" and "" or "\n"
      new_content = existing .. sep .. "\n" .. block .. "\n"
    end
  end

  if new_content == existing then return path end  -- no-op

  local out, err = io.open(path, "w")
  if not out then
    require("auto-agents.logger").warn("kb.instruct",
      "failed to write " .. path .. ": " .. tostring(err))
    return nil
  end
  out:write(new_content)
  out:close()
  return path
end

return M
