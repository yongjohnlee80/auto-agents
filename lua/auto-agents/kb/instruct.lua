---KB-aware spawn (M6, "double-down" approach).
---
---Each agent kind auto-loads a per-project instruction file from its
---cwd: claude reads `CLAUDE.md`, junie reads
---`.junie/guidelines.md`, and codex/antigravity/copilot/generic/goose/opencode
---all converge on `AGENTS.md` (the de-facto multi-vendor standard).
---(Aider doesn't auto-load AGENTS.md by default — its adapter passes
---`--read AGENTS.md` explicitly so the same file works there too.)
---We inject a delimited "auto-agents" block into that file so the
---agent learns its roster, its crew mail and the todo protocol and where the
---project's primary KB is, without us having to send anything via
---stdin (which TUIs would treat as a prompt).
---
---The KB part is three lines (ADR 1791209946 §2.4): the root, the
---AutoDoc workspace, and "read `<root>/AGENTS.md`". The KB's own
---AGENTS.md is the contract; this block never restates it. A project
---without a primary KB gets a line telling the agent to ask the user.
---
---**The instruction file is shared by every agent of the same kind in
---the project** (CLAUDE.md by all `claude` slots, AGENTS.md by all
---`codex`/`copilot`/`generic` slots, …). To avoid spawn-order
---thrash where each agent's rewrite overwrites the previous agent's
---personalized text, the block is rendered agent-neutrally: it lists
---every peer of the same kind in a roster table and instructs each
---reader to resolve its own identity with `autodoc crew whoami`.
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

---Interactive kinds that nonetheless have no model to configure here.
local NO_MODEL_OPTION = { codex = true }

---The agents that share spec's instruction file: every configured agent, of any kind, whose CLI
---reads the same file (codex, opencode, agy and the rest all read AGENTS.md), by slot; and their
---kinds, sorted, spec's own always among them. A file shared by several kinds is rendered for all
---of them, the same whichever of them spawned last.
---@param spec table
---@return table[] peers, string[] kinds, string filename
local function sharing(spec)
  local aa_state  = (require("auto-agents").state or {}).config or {}
  local bootstrap = (aa_state.agents or {}).bootstrap or {}
  local kind      = spec.kind or "?"
  local filename  = M.filename_for(kind)
  local peers = {}
  for _, e in ipairs(bootstrap) do
    if M.filename_for(e.kind or "?") == filename and e.name and e.name ~= ""
       and e.configured ~= false then
      peers[#peers + 1] = e
    end
  end
  -- Defensive fallback: if the spawning agent isn't yet in bootstrap
  -- for any reason, render its row alone rather than emit an empty
  -- roster. Same-file peers will be picked up on the next spawn.
  if #peers == 0 and spec.name and spec.name ~= "" then
    peers[#peers + 1] = spec
  end
  table.sort(peers, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
  local seen, kinds = { [kind] = true }, { kind }
  for _, p in ipairs(peers) do
    local k = p.kind or "?"
    if not seen[k] then seen[k], kinds[#kinds + 1] = true, k end
  end
  table.sort(kinds)
  return peers, kinds, filename
end
M._sharing = sharing

---Render the auto-agents block content for a spec's instruction file. The block is agent-neutral:
---it lists every configured agent that shares the file (sharing) in a roster table and tells each
---reader to resolve its own identity with `autodoc crew whoami`. This keeps the rendered content
---stable across spawns (otherwise every spawn would clobber the previous one's personalized text).
---@param spec table  -- { kind, name, slot, model }
---@param kb { root: string, workspace: string|nil }|nil  -- the primary KB
---@param crew { guides: table<string, string>|nil, editor: boolean }|nil  -- the daemon's crew
---  guide for each kind sharing the file, and whether Neovim's editor socket serves
---@return string
local function render_block(spec, kb, crew)
  local peers, kinds, filename = sharing(spec)
  local kind  = spec.kind or "?"
  local mixed = #kinds > 1

  local lines = {
    BEGIN,
    "## auto-agents",
    "",
    "This project uses [auto-agents.nvim](https://github.com/yongjohnlee80/auto-agents)",
    "for multi-agent orchestration.",
    "",
  }
  if mixed then
    local names = {}
    for _, k in ipairs(kinds) do names[#names + 1] = "`" .. k .. "`" end
    vim.list_extend(lines, {
      "**This `" .. filename .. "` is shared by every agent in this project whose",
      "CLI reads it: " .. table.concat(names, ", ") .. ".** All of them auto-load the",
      "same file on spawn, so the block below is rendered agent-neutrally.",
      "Resolve your own identity at runtime with `autodoc crew whoami` (its",
      "`codename`; the `crew_whoami` tool on MCP mail) and look your row up in",
      "the roster: its Kind says which of the parts below for one kind are",
      "yours.",
      "",
    })
  else
    vim.list_extend(lines, {
      "**This `" .. filename .. "` is shared by every `" .. kind .. "`-backed agent",
      "in this project.** All agents of this kind auto-load the same file on",
      "spawn, so the block below is rendered agent-neutrally. Resolve your",
      "own identity at runtime with `autodoc crew whoami` (its `codename`;",
      "the `crew_whoami` tool on MCP mail) and look your row up in the roster.",
      "",
    })
  end

  -- Interactive-diff state across the roster:
  --   * any_diff_review → at least one peer has `diff_review = true`
  --       (adds the diff_review column to the roster table for clarity)
  --   * inject_diff_protocol → a non-claude peer is opted in
  --       (claude uses native ws-mcp openDiff; only non-claude kinds need
  --       the `diff_queue` protocol inlined)
  local any_diff_review, inject_diff_protocol = false, false
  for _, p in ipairs(peers) do
    if p.diff_review == true then
      any_diff_review = true
      if (p.kind or kind) ~= "claude" then inject_diff_protocol = true end
    end
  end

  -- codex is the one interactive kind with NO model option: the adapter passes
  -- no --model, config.store drops the key and :AutoAgentsModel refuses it. So
  -- neither its Model cell nor the shared "Model preference" section applies to
  -- it; a short note takes their place below, so an agent asked to switch models
  -- knows where its model actually comes from.
  local model_kinds, no_model_kinds = false, false
  for _, k in ipairs(kinds) do
    if INTERACTIVE_KINDS[k] and not NO_MODEL_OPTION[k] then model_kinds = true end
    if INTERACTIVE_KINDS[k] and NO_MODEL_OPTION[k] then no_model_kinds = true end
  end
  local show_model = model_kinds
  if #peers > 0 then
    vim.list_extend(lines, {
      "### Roster (agents sharing this file)",
      "",
    })
    local cols = { { "Slot", function(p) return tostring(p.slot or "?") end },
      { "Name", function(p) return "`" .. (p.name or "?") .. "`" end } }
    if mixed then
      cols[#cols + 1] = { "Kind", function(p) return "`" .. (p.kind or "?") .. "`" end }
    end
    if show_model then
      cols[#cols + 1] = { "Model", function(p)
        if NO_MODEL_OPTION[p.kind or kind] then return "(codex's own config)" end
        return (p.model and p.model ~= "") and ("`" .. p.model .. "`") or "(CLI default)"
      end }
    end
    if any_diff_review then
      cols[#cols + 1] = { "diff_review", function(p) return p.diff_review == true and "✓" or "–" end }
    end
    local head, rule = {}, {}
    for _, c in ipairs(cols) do
      head[#head + 1], rule[#rule + 1] = c[1], string.rep("-", #c[1])
    end
    lines[#lines + 1] = "| " .. table.concat(head, " | ") .. " |"
    lines[#lines + 1] = "|" .. table.concat(rule, "|"):gsub("[^|]+", function(r) return "-" .. r .. "-" end) .. "|"
    for _, p in ipairs(peers) do
      local cells = {}
      for _, c in ipairs(cols) do cells[#cells + 1] = c[2](p) end
      lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
    lines[#lines + 1] = ""
  end

  -- The KB part: three lines, or one asking the user (ADR 1791209946 §2.4).
  vim.list_extend(lines, { "### Knowledge base", "" })
  if type(kb) == "table" and type(kb.root) == "string" and kb.root ~= "" then
    local ws = (type(kb.workspace) == "string" and kb.workspace ~= "")
      and ("`" .. kb.workspace .. "`  (`$AUTODOC_WORKSPACE`)")
      or "none named yet (`$AUTODOC_WORKSPACE` is unset)"
    vim.list_extend(lines, {
      "- KB root: `" .. kb.root .. "`  (`$AUTO_AGENTS_KB_ROOT`)",
      "- AutoDoc workspace: " .. ws,
      "- Read `" .. kb.root .. "/AGENTS.md` before any KB work.",
      "",
    })
  else
    vim.list_extend(lines, {
      "This project has no primary KB. Ask the user which KB to use before",
      "reading or writing one.",
      "",
    })
  end

  crew = crew or {}
  -- every message goes through AutoDoc's crew: the daemon's own guide for the kind follows when it
  -- was fetched (a slow or absent daemon leaves only the guide out, never the rules: Zen #8 F4)
  vim.list_extend(lines, {
    "### Crew mail (AutoDoc)",
    "",
    "Every message to you, from the user or a peer, goes through AutoDoc's",
    "daemon (its crew mail); there is no file mailbox. When",
    "`autodoc crew whoami` answers (your crew session), read and send mail",
    "as the daemon's guide below says. If it says there is no session",
    "context, you started before AutoDoc's daemon answered: Neovim joins",
    "you to the crew as soon as it does, so ask again in a minute. If it",
    "still fails, or says the context doesn't match, tell the user.",
    "",
  })
  -- Codex's Linux sandbox refuses every unix socket unless it opens the whole network (codex-cli
  -- 0.166: no per-socket allowance), so its shell's `autodoc mail|crew` stops for an approval
  if kind == "codex" or vim.tbl_contains(kinds, "codex") then
    vim.list_extend(lines, {
      (mixed and "A `codex` agent: " or "") .. "CLI mail from a sandboxed Codex asks for approval",
      "(its sandbox refuses AutoDoc's socket); use the MCP tools.",
      "",
    })
  end
  local guides = crew.guides or {}
  local function guide_lines(g)
    for line in (g:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  if not mixed then
    if guides[kind] then
      vim.list_extend(lines, { "The daemon's guide for your CLI:", "" })
      guide_lines(guides[kind])
    end
  else
    local any = false
    for _, k in ipairs(kinds) do any = any or guides[k] ~= nil end
    if any then
      vim.list_extend(lines, {
        "The daemon's guide for each CLI that reads this file. Follow the one",
        "for your own kind (your roster row's Kind) and none of the others:",
        "",
      })
      for _, k in ipairs(kinds) do
        if guides[k] then
          vim.list_extend(lines, { "#### For `" .. k .. "` agents", "" })
          guide_lines(guides[k])
        end
      end
    end
  end

  if crew.editor then
    vim.list_extend(lines, {
      "### Neovim's editor",
      "",
      "When `$AUTODOC_EDITOR` is set, Neovim answers `autodoc --editor <verb>",
      "'[…]'` directly, with no mail: `editor.workspace`, `editor.buffers`,",
      "`editor.read`, `editor.find`, `editor.open`, `peek`, `diff_queue`,",
      "`review.create` / `list` / `show` / `validate`, the `todos.*` verbs and",
      "auto-run's `run.*` verbs, as far as your grants allow (the roster entry's",
      "`editor_grants`; `run` only when it lists it; a verb outside them is",
      "refused, naming the grant).",
      "",
    })
  end

  vim.list_extend(lines, {
    "### Todo handling",
    "",
    "Tasks for this project live in a per-project `.todo-list/` store that",
    "AutoDoc's daemon owns (ADR-0031, ADR 1791532020), **not** the legacy",
    "`shared/synthesis/*-todos.md` convention. Two docs, named by env vars:",
    "",
    "- **`$AUTO_AGENTS_TODOS_CONVENTION_DOC`**: this project's editing policy.",
    "  On spawn, read its `revision:` (the Read tool, the path itself) and",
    "  compare it with the one in your memory (`feedback_todo_handling`). If",
    "  yours is missing or differs, read the doc whole, adopt it, and store",
    "  the new revision. That is the one check a spawn makes.",
    "- **`$AUTO_AGENTS_TODOS_BOOTSTRAP_DOC`**: the reference for the `todos.*`",
    "  verbs, which Neovim's editor socket serves you",
    "  (`autodoc --editor todos.<verb> '[{…}]'`, the `todos` grant). Read it",
    "  when you need a verb you don't know, not on every spawn.",
    "",
    "**Quick rules** (full detail in the convention doc):",
    "",
    "- Read tasks directly from `<workspace>/.todo-list/{open,deferred,completed,archived}/`.",
    "- Edit hand-editable fields (title, description, priority, due,",
    "  tags, adr, review, blocked) directly in YAML — fast, no ceremony.",
    "- Status / assign / create / archive MUST go through the `todos.*`",
    "  verbs on the editor socket (events fire; panel updates; the",
    "  recipient is notified on assign — a raw daemon `todos.assign`",
    "  carries no scope and notifies no one). Direct YAML edits to those",
    "  fields are metadata-only — side effects don't fire.",
    "- For `adr` / `review` doc refs: pass the ABSOLUTE path. The",
    "  host rewrites it to a portable `$KB_ROOT/...` / `$WORKSPACE/`",
    "  symbolic form on write — don't guess the prefix or hand-write",
    "  a bare relative.",
    "- `id`, `version`, lifecycle timestamps, `errors[]` are managed",
    "  by the host — never edit by hand.",
    "- On first ingest, scan the KB for legacy `type:todo-list`-tagged",
    "  docs OUTSIDE the active `.todo-list/`. If found, prompt the",
    "  user: (a) re-point with `todos.set_dir`, or (b) leave them as",
    "  historical reference. (Importing them was dropped, ADR 1791532020 D3.)",
    "",
    "If you're spawned OUTSIDE autovim (no `$AUTO_AGENTS_TODOS_*`",
    "env), the `todos.*` verbs don't",
    "exist — do NOT invent a task store. Ask the user where todos",
    "should live, and never fall back to the legacy `*-todos.md`",
    "format. (Full detail in `$AUTO_AGENTS_TODOS_CONVENTION_DOC`.)",
    "",
  })

  -- Interactive diff review (the `diff_queue` verb). Injected
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
        "--resume`, codex-style transcript restore, …): your row's",
        "`diff_review` column in the roster above is the live value (this",
        "block is rewritten on every spawn); it wins over a stale env.",
        "",
        "**What it means:** `diff_review = true` is a per-agent TOML",
        "flag that opts your slot into in-editor review of proposed",
        "edits. Instead of writing to disk yourself, you submit each",
        "change to the host's unified diff queue with the `diff_queue`",
        "verb (`autodoc --editor diff_queue`); the user accepts or rejects",
        "in the diff panel; only on `accepted` do you write to disk.",
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

  if no_model_kinds then
    vim.list_extend(lines, {
      mixed and "### Model (`codex` agents)" or "### Model",
      "",
      "There is no model setting for you here: auto-agents passes codex no",
      "`--model`, and a `model` in its TOML is ignored and dropped.",
      "",
      "A fresh spawn takes its default from codex's own configuration (`model`",
      "in `~/.codex/config.toml`), or from an explicit `-m`/`--model` in this",
      "slot's `cmd`, which is honoured verbatim. `/model` changes the model for",
      "the RUNNING session only — don't assume it carries into the next spawn;",
      "to change the default for every session, the user edits codex's config.",
      "Either way, don't reach for `:AutoAgentsModel`: it refuses a codex slot.",
      "",
    })
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
      "(<your-name>) going forward?\" Resolve `<your-name>` with",
      "`autodoc crew whoami` (its `codename`) and write it yourself via any",
      "shell tool you have:",
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

---ADR-0039 Batch D (P1): per-path bail-out cache. `ensure()` runs on
---every `refresh_agent_id` resume; before this cache each call paid a
---full read of the target CLAUDE.md/AGENTS.md even when nothing
---changed (the common case). Key: rendered-block sha256 + the file's
---size/mtime as of our last look. When both match, the splice result
---is provably identical to last time — skip the read entirely (one
---fs_stat instead). External edits bust the cache via the stat
---mismatch; config/roster changes bust it via the block sha.
local _ensure_cache = {}
M._ensure_cache_hits = 0   -- test hook
---@private test helper
function M._invalidate_ensure_cache() _ensure_cache = {} end

---@param path string
---@param sig string
local function _cache_store(path, sig)
  local st = vim.uv.fs_stat(path)
  if st then
    _ensure_cache[path] = {
      block_sha = sig,
      size = st.size,
      mtime_sec = st.mtime.sec,
      mtime_nsec = st.mtime.nsec,
    }
  end
end

---after_setup writes spec's instruction block again once its crew setup has answered a mail mode:
---the block was first written before the spawn's setup ran, so its guide was in the mode the kind had
---then (crew.answered_mode), and the agent must start reading the guide for the tools it is given.
---A spawn calls it after its setup and before its agent starts. It never raises: a block it can't
---write is logged, and the agent starts with the block as it was.
---@param spec table      -- the slot's spec, as ensure takes it
---@param setup table|nil -- crew.agent_setup's answer; nil or one without mail_via: nothing to do
---@param cwd string|nil
---@param kb table|string|nil
---@return string|nil written_path
function M.after_setup(spec, setup, cwd, kb)
  if type(setup) ~= "table" or not setup.mail_via then return nil end
  local ok, path = pcall(M.ensure, spec, kb, cwd)
  if not ok then
    require("auto-agents.log").warn("instruct", "the instruction block could not be written again: " .. tostring(path))
    return nil
  end
  return path
end

---Ensure the instruction file at `cwd/<kind-file>` contains an up-to-date
---auto-agents block. Idempotent. User content outside the block is
---preserved verbatim.
---
---@param spec table       -- { kind, name, slot, cwd }
---@param kb { root: string, workspace: string|nil }|string|nil
---                        -- the project's primary KB (`auto-agents.kb.primary()`);
---                        -- a bare root string is accepted; nil = no primary
---@param cwd string|nil   -- defaults to spec.cwd or the session project root
---@return string|nil written_path
function M.ensure(spec, kb, cwd)
  if type(kb) == "string" then kb = (kb ~= "") and { root = kb } or nil end
  cwd = cwd or spec.cwd
  if not cwd or cwd == "" then
    local aa = require("auto-agents")
    cwd = aa.state.session_project_root or aa.state.session_cwd
  end
  if not cwd or cwd == "" then return nil end

  local filename = M.filename_for(spec.kind or "generic")
  local path = cwd .. "/" .. filename
  local guides = {}
  local _, kinds = sharing(spec)
  for _, k in ipairs(kinds) do
    guides[k] = require("auto-agents.crew").guide(k)
  end
  local crew = {
    guides = guides,
    editor = require("auto-agents.editor_socket").path() ~= nil,
  }
  local block = render_block(spec, kb, crew)

  -- P1 bail-out: same rendered block + untouched file → identical
  -- outcome to the previous call; skip the file read and splice.
  local sig = vim.fn.sha256(block)
  local cached = _ensure_cache[path]
  if cached and cached.block_sha == sig then
    local st = vim.uv.fs_stat(path)
    if st and st.size == cached.size
        and st.mtime.sec == cached.mtime_sec
        and st.mtime.nsec == cached.mtime_nsec then
      M._ensure_cache_hits = M._ensure_cache_hits + 1
      return path
    end
  end

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

  if new_content == existing then
    _cache_store(path, sig)  -- prime the P1 bail-out for the next call
    return path  -- no-op
  end

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
  _cache_store(path, sig)  -- prime the P1 bail-out for the next call
  return path
end

return M
