---KB-aware spawn (M6, "double-down" approach).
---
---Each agent kind auto-loads a per-project instruction file from its
---cwd: claude reads `CLAUDE.md`, codex/copilot/generic read `AGENTS.md`,
---gemini reads `GEMINI.md`, junie reads `.junie/guidelines.md`. We
---inject a delimited "auto-agents" block into that file so the agent
---learns its KB location and read/write convention without us having
---to send anything via stdin (which TUIs would treat as a prompt).
---
---The block is bounded by `<!-- auto-agents:begin -->` /
---`<!-- auto-agents:end -->`. Re-running `ensure()` rewrites just the
---block — the user's surrounding content is preserved.
---
---@module 'auto-agents.kb.instruct'

local M = {}

local BEGIN = "<!-- auto-agents:begin -->"
local END   = "<!-- auto-agents:end -->"

---Map an agent kind to the filename it auto-loads at its cwd. Some
---kinds (junie) use a multi-segment path; the writer mkdirs the parent
---before writing.
---@param kind string
---@return string filename
function M.filename_for(kind)
  if kind == "claude"  then return "CLAUDE.md"  end
  if kind == "gemini"  then return "GEMINI.md"  end
  if kind == "junie"   then return ".junie/guidelines.md"  end
  return "AGENTS.md"  -- codex, copilot, generic, anything else
end

---Kinds the auto-injected sections (Model preference, Status reporting)
---apply to. claude/codex/gemini/junie all accept a `--model <id>` flag
---*and* can run shell tools to invoke `nvim --server "$NVIM" --remote-expr ...`
---themselves. copilot is a recommender, not a runner; generic is a plain
---shell — neither has the same self-instrumentation surface, so the
---sections are skipped for them.
local INTERACTIVE_KINDS = { claude = true, codex = true, gemini = true, junie = true }

---Render the auto-agents block content for a slot.
---@param spec table  -- { kind, name, slot, kb_scope, model }
---@param kb_root string
---@return string
local function render_block(spec, kb_root)
  local scope = spec.kb_scope or "shared"
  local agent_name = spec.name or ("agent" .. tostring(spec.slot or "?"))
  local aa_state = (require("auto-agents").state or {}).config or {}
  local kb_type = (aa_state.kb or {}).type or "general"
  local lines = {
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
  }

  if INTERACTIVE_KINDS[spec.kind] then
    local current = (spec.model and spec.model ~= "") and ("`" .. spec.model .. "`")
      or "(none — CLI default)"
    local set_cmd = "nvim --server \"$NVIM\" --remote-expr 'execute(\"AutoAgentsModel "
      .. agent_name .. " <new-model>\")'"
    local clear_cmd = "nvim --server \"$NVIM\" --remote-expr 'execute(\"AutoAgentsModel "
      .. agent_name .. " -\")'"
    vim.list_extend(lines, {
      "### Model preference",
      "",
      "Your preferred model is " .. current .. ". This is persisted in",
      "auto-agents' TOML config and passed to the CLI as `--model <id>` on",
      "every spawn.",
      "",
      "If the user asks you to switch models mid-session — switch first, then",
      "ask: \"Should I persist this as your preferred model for me ("
        .. agent_name .. ") going forward?\" If yes, write it to the config",
      "yourself by running this in any shell tool you have:",
      "",
      "    " .. set_cmd,
      "",
      "Replace `<new-model>` with the model id (e.g. `claude-opus-4-7`).",
      "`$NVIM` is set automatically inside this terminal and points at the",
      "parent nvim's socket — the command runs `:AutoAgentsModel " .. agent_name,
      "<new-model>` in that nvim, which updates the TOML and saves it.",
      "",
      "To clear the preference (back to CLI default):",
      "",
      "    " .. clear_cmd,
      "",
      "The change takes effect on the **next** agent restart, not the current",
      "session. Tell the user to restart this slot when convenient.",
      "",
    })

    -- No status-reporting block: status is observed passively by
    -- auto-agents.status.observer at the spawn path, no agent
    -- cooperation needed. The cooperative `:AutoAgentsStatus` ex-
    -- command still exists as an override for advanced cases, but we
    -- don't surface it in the agent's instructions to avoid drift
    -- between the observer's reading and the agent's self-report.
  end

  lines[#lines + 1] = END
  return table.concat(lines, "\n")
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

  -- Ensure parent dir exists for kinds whose filename is multi-segment
  -- (e.g. junie's `.junie/guidelines.md`). mkdir -p is idempotent.
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and parent ~= cwd then
    pcall(vim.fn.mkdir, parent, "p")
  end

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
