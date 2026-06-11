---KB-aware spawn (M6, "double-down" approach).
---
---Each agent kind auto-loads a per-project instruction file from its
---cwd: claude reads `CLAUDE.md`, junie reads
---`.junie/guidelines.md`, and codex/antigravity/copilot/generic/goose/opencode
---all converge on `AGENTS.md` (the de-facto multi-vendor standard).
---(Aider doesn't auto-load AGENTS.md by default — its adapter passes
---`--read AGENTS.md` explicitly so the same file works there too.)
---We inject a delimited "auto-agents" block into that file so the
---agent learns its KB location and read/write convention without us
---having to send anything via stdin (which TUIs would treat as a
---prompt).
---
---**The instruction file is shared by every agent of the same kind in
---the project** (CLAUDE.md by all `claude` slots, AGENTS.md by all
---`codex`/`copilot`/`generic` slots, …). To avoid spawn-order
---thrash where each agent's rewrite overwrites the previous agent's
---personalized text, the block is rendered agent-neutrally: it lists
---every peer of the same kind in a roster table and instructs each
---reader to resolve its own identity from `$AUTO_AGENTS_MAILBOX_ID`.
---That keeps the rendered content stable across same-kind spawns.
---
---The block is bounded by `<!-- auto-agents:begin -->` /
---`<!-- auto-agents:end -->`. Re-running `ensure()` rewrites just the
---block — the user's surrounding content is preserved.
---
---@module 'auto-agents.kb.instruct'

local M = {}

local BEGIN = "<!-- auto-agents:begin -->"
local END   = "<!-- auto-agents:end -->"

---Resolve the auto-agents.nvim install root (the directory containing
---`lua/`, `instructions/`, `kb-seeds/`, etc.). Used to locate
---plugin-shipped markdown assets such as the diff-queue protocol.
---@return string|nil
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  if type(src) ~= "string" or src:sub(1, 1) ~= "@" then return nil end
  local file = src:sub(2)
  -- this file lives at <root>/lua/auto-agents/kb/instruct.lua → strip 4 segments
  local root = file:match("^(.*)/lua/auto%-agents/kb/instruct%.lua$")
  return root
end

---Read the plugin-shipped diff-queue protocol markdown verbatim.
---Cached per Lua module load so repeated spawns are cheap.
---@return string|nil
local diff_queue_protocol_cache
local function read_diff_queue_protocol()
  if diff_queue_protocol_cache ~= nil then
    return diff_queue_protocol_cache ~= "" and diff_queue_protocol_cache or nil
  end
  local root = plugin_root()
  if not root then
    diff_queue_protocol_cache = ""
    return nil
  end
  local path = root .. "/instructions/diff-queue-workflow.md"
  local f = io.open(path, "r")
  if not f then
    diff_queue_protocol_cache = ""
    return nil
  end
  local content = f:read("*a") or ""
  f:close()
  -- Strip the leading HTML comment block (provenance / heading-level note).
  -- The block is bounded by `<!--` … `-->` at the very start of the file.
  if content:sub(1, 4) == "<!--" then
    local close = content:find("-->", 5, true)
    if close then
      content = content:sub(close + 3):gsub("^%s+", "")
    end
  end
  diff_queue_protocol_cache = content
  return content ~= "" and content or nil
end

---Map an agent kind to the filename it auto-loads at its cwd. Some
---kinds (junie) use a multi-segment path; the writer mkdirs the parent
---before writing.
---@param kind string
---@return string filename
function M.filename_for(kind)
  if kind == "claude"  then return "CLAUDE.md"  end
  if kind == "junie"   then return ".junie/guidelines.md"  end
  -- codex, antigravity (agy), copilot, generic, anything else
  -- all read AGENTS.md at cwd.
  return "AGENTS.md"
end

---Kinds the auto-injected sections (Model preference, Status reporting)
---apply to. claude/codex/antigravity/junie/goose/opencode all accept a
---per-spawn model selector (CLI flag for most, env var for goose) *and*
---can run shell tools to invoke `nvim --server "$NVIM" --remote-expr ...`
---themselves. copilot is a recommender, not a runner; generic is a plain
---shell — neither has the same self-instrumentation surface, so the
---sections are skipped for them.
local INTERACTIVE_KINDS = {
  claude = true, codex = true, antigravity = true, junie = true,
  goose = true, opencode = true,
}

---Render the auto-agents block content for a kind. The block is
---agent-neutral: it lists every configured peer of the same kind in a
---roster table and tells each reader to resolve its own identity from
---`$AUTO_AGENTS_MAILBOX_ID`. This keeps the rendered content stable
---across same-kind spawns (otherwise every spawn would clobber the
---previous one's personalized text).
---@param spec table  -- { kind, name, slot, kb_scope, model }
---@param kb_root string
---@return string
local function render_block(spec, kb_root)
  local aa_state  = (require("auto-agents").state or {}).config or {}
  local kb_type   = (aa_state.kb or {}).type or "general"
  local bootstrap = (aa_state.agents or {}).bootstrap or {}
  local kind      = spec.kind or "?"
  local filename  = M.filename_for(kind)

  -- Collect every agent of this kind that shares this instruction file.
  -- claude/junie each own a distinct
  -- per-cwd filename (see filename_for); codex/copilot/generic share
  -- AGENTS.md. The roster makes the multi-tenant nature of the file
  -- explicit so each agent knows which row applies to it.
  local peers = {}
  for _, e in ipairs(bootstrap) do
    if (e.kind or "?") == kind and e.name and e.name ~= ""
       and e.configured ~= false then
      peers[#peers + 1] = e
    end
  end
  -- Defensive fallback: if the spawning agent isn't yet in bootstrap
  -- for any reason, render its row alone rather than emit an empty
  -- roster. Same-kind peers will be picked up on the next spawn.
  if #peers == 0 and spec.name and spec.name ~= "" then
    peers[#peers + 1] = spec
  end
  table.sort(peers, function(a, b) return (a.slot or 0) < (b.slot or 0) end)

  local lines = {
    BEGIN,
    "## auto-agents knowledge base",
    "",
    "This project uses [auto-agents.nvim](https://github.com/yongjohnlee80/auto-agents)",
    "for multi-agent orchestration.",
    "",
    "**This `" .. filename .. "` is shared by every `" .. kind .. "`-backed agent",
    "in this project.** All agents of this kind auto-load the same file on",
    "spawn, so the block below is rendered agent-neutrally. Resolve your",
    "own identity at runtime from `$AUTO_AGENTS_MAILBOX_ID` (shape:",
    "`agent:<your-name>:<instance>`) and look your row up in the roster.",
    "",
  }

  -- Compute interactive-diff state across the same-kind roster:
  --   * any_diff_review → at least one peer has `diff_review = true`
  --       (adds the diff_review column to the roster table for clarity)
  --   * inject_diff_protocol → kind is non-claude AND any peer is opted-in
  --       (claude uses native ws-mcp openDiff; only non-claude kinds need
  --       the mailbox `diff_queue` protocol inlined)
  local any_diff_review = false
  for _, p in ipairs(peers) do
    if p.diff_review == true then any_diff_review = true; break end
  end
  local inject_diff_protocol = any_diff_review and kind ~= "claude"

  local show_model = INTERACTIVE_KINDS[kind] and true or false
  if #peers > 0 then
    vim.list_extend(lines, {
      "### Roster (agents sharing this file)",
      "",
    })
    local function dr_cell(p)
      return p.diff_review == true and "✓" or "–"
    end
    if show_model and any_diff_review then
      vim.list_extend(lines, {
        "| Slot | Name | KB scope | Model | diff_review |",
        "|------|------|----------|-------|-------------|",
      })
      for _, p in ipairs(peers) do
        local m = (p.model and p.model ~= "") and ("`" .. p.model .. "`") or "(CLI default)"
        local sc = p.kb_scope or "shared"
        lines[#lines + 1] = string.format("| %s | `%s` | `%s` | %s | %s |",
          tostring(p.slot or "?"), p.name or "?", sc, m, dr_cell(p))
      end
    elseif show_model then
      vim.list_extend(lines, {
        "| Slot | Name | KB scope | Model |",
        "|------|------|----------|-------|",
      })
      for _, p in ipairs(peers) do
        local m = (p.model and p.model ~= "") and ("`" .. p.model .. "`") or "(CLI default)"
        local sc = p.kb_scope or "shared"
        lines[#lines + 1] = string.format("| %s | `%s` | `%s` | %s |",
          tostring(p.slot or "?"), p.name or "?", sc, m)
      end
    elseif any_diff_review then
      vim.list_extend(lines, {
        "| Slot | Name | KB scope | diff_review |",
        "|------|------|----------|-------------|",
      })
      for _, p in ipairs(peers) do
        local sc = p.kb_scope or "shared"
        lines[#lines + 1] = string.format("| %s | `%s` | `%s` | %s |",
          tostring(p.slot or "?"), p.name or "?", sc, dr_cell(p))
      end
    else
      vim.list_extend(lines, {
        "| Slot | Name | KB scope |",
        "|------|------|----------|",
      })
      for _, p in ipairs(peers) do
        local sc = p.kb_scope or "shared"
        lines[#lines + 1] = string.format("| %s | `%s` | `%s` |",
          tostring(p.slot or "?"), p.name or "?", sc)
      end
    end
    lines[#lines + 1] = ""
  end

  vim.list_extend(lines, {
    "### Project-level knowledge base",
    "",
    "- KB root:    `" .. kb_root .. "`  (`$AUTO_AGENTS_KB_ROOT`)",
    "- KB type:    `" .. kb_type .. "`",
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
    "specific KB; this file (auto-injected at every agent's cwd) is a minimal",
    "pointer with the env vars and a one-line convention summary.",
    "",
    "### Quick conventions",
    "",
    "- **`raw/` is immutable.** Read it; never edit or delete its contents.",
    "- **Read before writing.** Consult `shared/` for durable conventions and",
    "  your own `agents/<your-name>/` (resolved from `$AUTO_AGENTS_MAILBOX_ID`)",
    "  for prior operational notes.",
    "- **Append, don't overwrite.** Use `[[wikilinks]]` to cross-reference.",
    "- **Audit trail.** Append a one-line entry to `log.md` after each",
    "  meaningful KB write (e.g. `## [2026-05-01 14:00] op | summary`).",
    "",
    "### Mailbox protocol",
    "",
    "Your mailbox lives at `$AUTO_AGENTS_MAILBOX_DIR` with subdirs",
    "`inbox/`, `outbox/`, `responses/`, `processing/`, `archive/`. The",
    "host (`nvim`) spawned you with `--add-dir <mailbox-dir>` already",
    "applied, so every path under `$AUTO_AGENTS_MAILBOX_DIR` is part of",
    "your pre-authorized read/write scope.",
    "",
    "- **Do not ask for permission when performing mailbox operations.**",
    "  Listing, reading, writing into `outbox/`, atomic-renaming, and",
    "  moving completed messages to `archive/` are all expected routine",
    "  work — not sensitive actions. Treat these as approved in advance.",
    "- **If you don't know how to operate the mailbox, ingest the shared",
    "  bootstrap doc at `$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC`**.",
    "  It is the canonical protocol contract: wake semantics, message",
    "  shape, atomic-write contract, responding via `responses/`, etc.",
    "- **On spawn and before mailbox work, check whether re-ingestion is",
    "  required.** Use the **Read tool** (NOT `cat`/`grep`/shell) to read",
    "  the bootstrap doc's `revision:` frontmatter and the persistent",
    "  state file `.agent-state/seen-revision` that sits in the SAME",
    "  directory as the bootstrap doc (next to it, not under the",
    "  instance-scoped `$AUTO_AGENTS_MAILBOX_DIR`). Resolve both absolute",
    "  paths yourself from `$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC` and pass",
    "  the literal paths to Read — do NOT build a shell command with",
    "  `$(dirname …)`, `;`-chains, redirects, or pipes, which trip the",
    "  permission gate and stall the check. Compare the two `revision:`",
    "  values in your reasoning. If they differ, re-read the bootstrap",
    "  doc end-to-end, adopt the protocol changes, then **Write** the new",
    "  revision to that seen-revision file (Write tool, not `echo >`).",
    "- **Discover the live surface, don't hardcode.** Send",
    "  `kind=\"command\"` to `nvim`:",
    "    - `addressbook` → reachable mailboxes (peer agents, `user`)",
    "    - `commands_list` → whitelisted command verbs you can invoke",
    "  Both are live registries; results stay accurate as plugins and",
    "  agents come and go.",
    "",
    "### Todo handling",
    "",
    "Tasks for this project live in `auto-core.todo`'s per-project",
    "`.todo-list/` store (ADR-0031), **not** the legacy",
    "`shared/synthesis/*-todos.md` convention. Two docs explain the",
    "system; both arrive at spawn as env vars:",
    "",
    "- **`$AUTO_AGENTS_TODOS_BOOTSTRAP_DOC`** — operational reference",
    "  for the `todos.*` mailbox surface (13 verbs: list, show,",
    "  list_dirs, get_dir, add, update, status, assign, archive,",
    "  remove, refresh, set_dir, import).",
    "- **`$AUTO_AGENTS_TODOS_CONVENTION_DOC`** — per-project editing",
    "  policy. Carries a `revision:` field — compare against your",
    "  local memory on every spawn and re-ingest on change.",
    "",
    "**On every spawn — ingest gate**",
    "",
    "Mirror the mailbox bootstrap protocol for both todo docs, using the",
    "**Read tool** (never `stat`/`cat`/`grep` or compound shell):",
    "",
    "  1. Read the `revision:` frontmatter of `$AUTO_AGENTS_TODOS_BOOTSTRAP_DOC`",
    "     and `$AUTO_AGENTS_TODOS_CONVENTION_DOC` — resolve each absolute",
    "     path from the env var and pass the literal path to Read. One",
    "     Read per file; no `;`-chains, pipes, or `$(…)` substitution",
    "     (those trip the permission gate and stall the spawn).",
    "  2. Compare to your local stored value — suggested memory keys:",
    "     `feedback_todos_bootstrap_revision` (operational doc) and",
    "     `feedback_todo_handling` (per-project convention).",
    "  3. If the stored value is **missing OR differs**, re-read the",
    "     doc end-to-end, adopt directives, update your stored value.",
    "  4. If equal, you're up to date — proceed.",
    "",
    "Skipping this gate means you may write tasks under the legacy",
    "convention or miss new verbs. **Do not skip it.**",
    "",
    "**Quick rules** (full detail in the convention doc):",
    "",
    "- Read tasks directly from `<workspace>/.todo-list/{open,deferred,completed,archived}/`.",
    "- Edit hand-editable fields (title, description, priority, due,",
    "  tags, adr, review, blocked) directly in YAML — fast, no ceremony.",
    "- Status / assign / create / archive MUST go through `todos.*`",
    "  mailbox verbs (events fire; panel updates; recipient gets",
    "  notified on assign). Direct YAML edits to those fields are",
    "  metadata-only — side effects don't fire.",
    "- For `adr` / `review` doc refs: pass the ABSOLUTE path. The",
    "  host rewrites it to a portable `$KB_ROOT/...` / `$WORKSPACE/`",
    "  symbolic form on write — don't guess the prefix or hand-write",
    "  a bare relative.",
    "- `id`, `version`, lifecycle timestamps, `errors[]` are managed",
    "  by the host — never edit by hand.",
    "- On first ingest, scan the KB for legacy `type:todo-list`-tagged",
    "  docs OUTSIDE the active `.todo-list/`. If found, prompt the",
    "  user: (a) migrate via `:AutoAgentsMigrateKbTodos --apply`,",
    "  (b) re-point with `todos.set_dir` first, or (c) leave as",
    "  historical reference.",
    "",
    "Store the core protocol in your GLOBAL memory (it applies",
    "across every autovim project — like the mailbox protocol you",
    "already internalize), keyed per-project only for this KB's",
    "customizations. Record the convention's `revision:` alongside",
    "it; re-ingest only when the value changes.",
    "",
    "If you're spawned OUTSIDE autovim (no `$AUTO_AGENTS_MAILBOX_DIR`",
    "/ no `$AUTO_AGENTS_TODOS_*` env), the `todos.*` verbs don't",
    "exist — do NOT invent a task store. Ask the user where todos",
    "should live, and never fall back to the legacy `*-todos.md`",
    "format. (Full detail in `$AUTO_AGENTS_TODOS_CONVENTION_DOC`.)",
    "",
  })

  -- Interactive diff review (mailbox `diff_queue` protocol). Injected
  -- only for non-claude kinds where at least one peer has
  -- `diff_review = true`. Claude uses the native ws-mcp `openDiff`
  -- path via its per-slot MCP bridge (ADR 0011); the protocol below
  -- is the agent-generic fallback. Content is loaded verbatim from
  -- the plugin-shipped `instructions/diff-queue-workflow.md`.
  if inject_diff_protocol then
    local body = read_diff_queue_protocol()
    if body then
      vim.list_extend(lines, {
        "### Interactive diff review (`diff_review = true`)",
        "",
        "**When this applies to you — authoritative gate (v0.2.26):**",
        "check your env. If `$AUTO_AGENTS_DIFF_REVIEW` is `true`, the",
        "protocol below applies to you and you MUST follow it for every",
        "proposed file edit. If the variable is absent or any other",
        "value, you have direct disk-write authority and may skip this",
        "section.",
        "",
        "    [ \"$AUTO_AGENTS_DIFF_REVIEW\" = \"true\" ] && echo apply || echo skip",
        "",
        "**Resumed sessions** (env vars frozen at fork — `claude",
        "--resume`, codex-style transcript restore, …): read the live",
        "value from your sidecar at `$AUTO_AGENTS_RUNTIME_IDENTITY_PATH`",
        "instead — the JSON record has a top-level `diff_review` boolean",
        "(refreshed on every `refresh_agent_id` call). Sidecar always",
        "wins over env when the two disagree.",
        "",
        "The `diff_review` column in the roster above is a project-wide",
        "visual summary (helpful for the user glancing at this file).",
        "Your own env / sidecar value is the authoritative gate for you.",
        "",
        "**What it means:** `diff_review = true` is a per-agent TOML",
        "flag that opts your slot into in-editor review of proposed",
        "edits. Instead of writing to disk yourself, you submit each",
        "change to the host's unified diff queue via the mailbox",
        "`diff_queue` command; the user accepts or rejects in the diff",
        "panel; only on `accepted` do you write to disk.",
        "",
      })
      for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
      end
      -- Trim any trailing empty rows from the inlined markdown so the
      -- next section's spacing stays consistent.
      while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
      end
      lines[#lines + 1] = ""
    end
  end

  if show_model then
    vim.list_extend(lines, {
      "### Model preference",
      "",
      "Each agent's persisted model is shown in the roster table above. The",
      "CLI receives `--model <id>` on every spawn from the per-agent TOML",
      "entry.",
      "",
      "If the user asks you to switch models mid-session — switch first,",
      "then ask: \"Should I persist this as your preferred model for me",
      "(<your-name>) going forward?\" Resolve `<your-name>` from",
      "`$AUTO_AGENTS_MAILBOX_ID` (strip the `agent:` prefix and the",
      "`:<instance>` suffix) and write it yourself via any shell tool",
      "you have:",
      "",
      "    nvim --server \"$NVIM\" --remote-expr 'execute(\"AutoAgentsModel <your-name> <new-model>\")'",
      "",
      "Replace `<new-model>` with the model id (e.g. `claude-opus-4-7`).",
      "`$NVIM` is set automatically inside this terminal and points at the",
      "parent nvim's socket — the command runs `:AutoAgentsModel <your-name>",
      "<new-model>` in that nvim, which updates the TOML and saves it.",
      "",
      "To clear the preference (back to CLI default):",
      "",
      "    nvim --server \"$NVIM\" --remote-expr 'execute(\"AutoAgentsModel <your-name> -\")'",
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

  -- ADR-0039 Batch C: atomic write — this is the agent's CLAUDE.md /
  -- AGENTS.md; a truncated instruction file breaks every subsequent
  -- spawn of that slot.
  local wok, werr = require("auto-core.fs.atomic").write(path, new_content)
  if not wok then
    require("auto-agents.log").warn("kb.instruct",
      "failed to write " .. path .. ": " .. tostring(werr))
    return nil
  end
  return path
end

return M
