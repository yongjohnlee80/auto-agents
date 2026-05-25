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

-- Hardcoded fallback bounds for `panel resize`. Mirrors
-- auto-agents.config.PANEL_OVERRIDE_MIN/MAX. We resolve the live
-- values from the config module per call (in case it's been
-- updated), but fall back to these literals when the cached config
-- module is stale — which happens when lazy.nvim hot-reloads
-- admin.lua after a `:Lazy sync` but doesn't re-require config.lua,
-- leaving cfg_mod.PANEL_OVERRIDE_MIN/MAX as nil and crashing the
-- range comparison. Belt-and-suspenders.
local PANEL_FALLBACK_MIN = 25
local PANEL_FALLBACK_MAX = 160
local function panel_min()
  return require("auto-agents.config").PANEL_OVERRIDE_MIN or PANEL_FALLBACK_MIN
end
local function panel_max()
  return require("auto-agents.config").PANEL_OVERRIDE_MAX or PANEL_FALLBACK_MAX
end

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
    "  help, ?, :h                    show this help",
    "  status                         list agent slots and state",
    "  agent focus <N>                focus slot N (0..9)",
    "  agent list                     list configured agents",
    "  agent add                      open new-agent form (D14)",
    "  agent edit <N>                 open edit form for slot N",
    "  agent remove <N>               kill slot N and delete its bootstrap entry",
    "  agent kill <N>                 stop the agent in slot N (keep entry)",
    "  agent restart <N>              kill and re-spawn slot N",
    "  agent rename <N> <new-name>    rename the bootstrap entry",
    "  agent send <N> <text...>       write <text> to agent N's stdin",
    "  agent attach <N> [<paths>]     send paths (or tree selection) to slot N",
    "  agent move <F> <T> [--swap]    relocate (or swap) a slot's content",
    "  agent task add <N> <text>      add a task to slot N's list",
    "  agent task done <N> <index>    mark task #<index> done (removes it)",
    "  agent task list [<N>]          show tasks for slot N (or all)",
    "  agent mem                      report RSS per running agent",
    "  kb init [<type> [<seed>]]      seed kb (coding|wiki|research|ops|general|custom)",
    "  kb ingest [--attach <N>]       diff raw/ vs ingested source pages; optionally hand worklist to slot N",
    "  kb path                        print kb root + ensure layout",
    "  kb scope <N> <mode>            change kb_scope (shared|private|isolated)",
    "  kb sync                        regenerate manifest.json per namespace",
    "  kb new <relative>              create + open a kb file in the editor",
    "  kb open <relative>             open a kb file in the editor",
    "  kb attach <N> <relative>       send a kb-relative path to slot N",
    "  kb tail                        open log.md in editor (autoread)",
    "  kb log                         print path of kb log.md",
    "  kb obsidian-init               scaffold .obsidian/ in kb root",
    "  resource grant <N> <path>      grant a path to slot N (AUTO_AGENTS_ALLOWED_PATHS)",
    "  resource revoke <N> <path>     revoke a previously-granted path",
    "  resource cwd <N> [<path>]      set/clear explicit cwd for slot N",
    "  resource list [<N>]            list grants (all or for slot N)",
    "  resource manager set <S> <M>   designate slot M as manager of S",
    "  resource manager show          show manager → subordinate map",
    "  project init                   create a per-project TOML for this cwd",
    "  project import [<key|path|cwd>] duplicate agents from another project",
    "  project remove                 delete the per-project TOML (KB survives)",
    "  project list                   list known config files",
    "  project show                   print active resolution",
    "  config save                    write current bootstrap to active TOML",
    "  config reset                   alias of 'project remove'",
    "  config show                    show effective config + paths",
    "  config path                    print path of the active TOML",
    "  term focus <N>                 open/focus/hide playground terminal T<N> (1..4)",
    "  term send <N> <text>           paste-safe send to T<N>'s stdin",
    "  term list                      list T1..T4 state (alive/visible/focused)",
    "  term kill <N>                  stop T<N> and wipe its buffer",
    "  term hide                      hide every T1..T4 float",
    "  slot add <N>                   grow main panel by N slots (cap 9)",
    "  slot remove <N>                shrink main panel by N (floor 2; rejects if any to-be-removed slot has an agent)",
    "  slot show                      show slot_count + agent assignments per slot",
    "  clear                          wipe history above the prompt",
    "  quit                           close the auto-agents panel",
    "",
    "Per-command help:",
    "  <verb> ?                       same as 'help <verb>'",
    "  <verb> <sub> ?                 contextual help for that subcommand",
    "  help open <verb> [<sub>]       open the help md in the editor",
    "",
    "Kinds: claude | codex | antigravity | junie | goose | opencode | copilot | generic",
    "Config: project file at <stdpath('config')>/.auto-agents-config/<key>.toml,",
    "        falls back to global.toml in that dir, else empty.",
    "        :cd does not move the project — boundary is cached at startup.",
    "",
  }
end

local function status_lines()
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  local by_slot = {}
  for _, e in ipairs(bs) do by_slot[e.slot] = e end
  local max_slot = aa.MAX_SLOT or 5

  local lines = { "", "Agent slots:" }
  for slot = 0, max_slot do
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
      local term = aa.state.slot_terminals[slot]
      state = (term and term:is_alive()) and "running" or "-"
    end
    local marker = (slot == aa.state.focused_slot) and "→" or " "
    local where = (slot == 0) and "admin" or "main"
    local entry = by_slot[slot]
    local task_count = (entry and entry.tasks) and #entry.tasks or 0
    local task_suffix = task_count > 0 and string.format("  [%d task%s]", task_count, task_count == 1 and "" or "s") or ""
    table.insert(lines, string.format(" %s %d  %-22s  %-5s  %s%s", marker, slot, label, where, state, task_suffix))
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

---True if `tok` is a help-trigger token.
local function is_help_token(tok)
  return tok == "help" or tok == "?" or tok == ":h"
end

---Parse positional / k=v args for a `run <verb>` invocation. Pure
---function — no side effects — exposed as `M._parse_run_args` for
---tests. Per-verb positional shortcuts:
---  * `peek <slot> [lines]`   → { slot, lines? }
---  * `say  <slot> <text...>` → { slot, text }
---  * `wake <slot-num-or-name> [text...]` → { slot=name, text? }
---      (resolves a numeric slot to the bootstrap entry's name)
---  * `send_user <body...>`   → { body }
---  * any other verb          → generic `k=v` parsing with
---      auto-coercion (number / true / false / string)
---@param cmd_name string
---@param toks string[]   tokens of the full input ("run", cmd, args...)
---@return table args
local function _parse_run_args(cmd_name, toks)
  local args = {}
  if cmd_name == "peek" then
    args.slot = tonumber(toks[3])
    if toks[4] then args.lines = tonumber(toks[4]) end
  elseif cmd_name == "say" then
    args.slot = tonumber(toks[3])
    if #toks >= 4 then
      local rest = {}
      for i = 4, #toks do rest[#rest + 1] = toks[i] end
      args.text = table.concat(rest, " ")
    end
  elseif cmd_name == "wake" then
    -- wake's `slot` arg is the agent NAME (string). Admin UX
    -- accepts either a slot NUMBER (resolved to the bootstrap
    -- entry's name) or a literal agent name string. Trailing
    -- tokens become the optional `text`.
    local first = toks[3]
    if first then
      local as_num = tonumber(first)
      if as_num then
        local cfg = (require("auto-agents").state or {}).config or {}
        local bs = (cfg.agents and cfg.agents.bootstrap) or {}
        for _, e in ipairs(bs) do
          if tonumber(e.slot) == as_num then
            args.slot = e.name; break
          end
        end
        if not args.slot then args.slot = tostring(first) end
      else
        args.slot = first
      end
    end
    if #toks >= 4 then
      local rest = {}
      for i = 4, #toks do rest[#rest + 1] = toks[i] end
      args.text = table.concat(rest, " ")
    end
  elseif cmd_name == "send_user" then
    if #toks >= 3 then
      local rest = {}
      for i = 3, #toks do rest[#rest + 1] = toks[i] end
      args.body = table.concat(rest, " ")
    end
  else
    for i = 3, #toks do
      local k, v = toks[i]:match("^([^=]+)=(.*)$")
      if k and v then
        local n = tonumber(v)
        if n ~= nil then args[k] = n
        elseif v == "true" then args[k] = true
        elseif v == "false" then args[k] = false
        else args[k] = v end
      end
    end
  end
  return args
end

local function dispatch(input)
  input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return end

  local toks = tokenize(input)
  local verb = toks[1]

  -- Help routing (M6). Help opens in a scrollable floating window so
  -- long content (whole-file views especially) stays readable. The
  -- admin REPL itself doesn't get cluttered with dozens of help lines
  -- the user has to scroll past. q / <Esc> closes the popup.
  --
  --   help [<verb> [<sub>]]    → help.popup(verb, sub)
  --   ? [<verb> [<sub>]]       → help.popup(verb, sub)
  --   help open <verb> [<sub>] → help.open(verb, sub)  (in editor for editing)
  --   <verb> [<sub>] help      → help.popup(verb, sub) (contextual)
  --   <verb> [<sub>] ?         → same as 'help'
  if is_help_token(verb) then
    if toks[2] == "open" then
      require("auto-agents.help").open(toks[3], toks[4])
    else
      require("auto-agents.help").popup(toks[2], toks[3])
    end
    return
  elseif #toks >= 2 and is_help_token(toks[#toks]) then
    require("auto-agents.help").popup(toks[1], toks[2] ~= "" and toks[2] or nil)
    return
  end

  if verb == "status" then
    emit(status_lines())

  elseif verb == "clear" then
    if buf_valid() then
      local last = vim.api.nvim_buf_line_count(M._bufnr)
      if last > 1 then
        vim.api.nvim_buf_set_lines(M._bufnr, 0, last - 1, false, {})
      end
    end

  elseif verb == "project" then
    local sub = toks[2]
    local args = {}
    for i = 3, #toks do args[#args + 1] = toks[i] end
    require("auto-agents.project").dispatch(sub, args, function(lines) emit(lines) end)

  elseif verb == "term" then
    local sub = toks[2]
    local term_mod = require("auto-agents.term")
    local focus = require("auto-agents.term.focus")
    if sub == "focus" then
      local slot = tonumber(toks[3])
      if not slot then emit({ "term focus: needs slot 1..4" })
      else focus.focus_or_hide(slot); emit({ "term focus → T" .. slot }) end
    elseif sub == "send" then
      local slot = tonumber(toks[3])
      if not slot then
        emit({ "term send: usage 'term send <slot> <text>'" })
      else
        local text = input:match("^term%s+send%s+%S+%s*(.*)$") or ""
        if text == "" then emit({ "term send: text is empty" })
        else
          local ok = term_mod.send(slot, text)
          emit({ ok and ("Sent to T" .. slot) or ("T" .. slot .. " send failed") })
        end
      end
    elseif sub == "list" then
      local lines = { "", "Playground terminals (T1..T4):" }
      for _, e in ipairs(term_mod.list()) do
        local state = e.alive and (e.visible and (e.focused and "focused" or "visible") or "hidden") or "-"
        table.insert(lines, string.format("  T%d  %-8s  buf=%s",
          e.slot, state, tostring(e.bufnr or "-")))
      end
      table.insert(lines, "")
      emit(lines)
    elseif sub == "kill" then
      local slot = tonumber(toks[3])
      if not slot then emit({ "term kill: needs slot 1..4" })
      else
        emit({ term_mod.kill(slot) and ("killed T" .. slot) or ("T" .. slot .. " has no terminal") })
      end
    elseif sub == "hide" then
      term_mod.hide_all()
      emit({ "Hid all T1..T4 floats." })
    else
      emit({ "term: unknown subverb '" .. tostring(sub) .. "' — try focus|send|list|kill|hide" })
    end

  elseif verb == "run" then
    -- Dispatch any registered mailbox command from the admin REPL.
    -- Shares one source of truth (auto-core.mailbox.commands) with
    -- the agent-facing `commands_list` registry — admin and peer
    -- agents invoke the same handlers with the same arg shape.
    --
    -- Usage:
    --   run                      → list registered commands
    --   run <verb>               → invoke with no args
    --   run peek <slot> [lines]  → positional shortcut
    --   run say  <slot> <text>   → positional shortcut (text = rest of input)
    --   run <verb> k=v k2=v2 ... → generic key=value args
    local cmd_name = toks[2]
    local ok_core, core = pcall(require, "auto-core")
    if not ok_core then
      emit({ "run: require('auto-core') failed" })
      return
    end

    if not cmd_name then
      -- List the live registry.
      local entries = core.mailbox.commands.list() or {}
      table.sort(entries, function(a, b) return tostring(a.name) < tostring(b.name) end)
      local lines = { "Registered commands (run <verb> args...):" }
      for _, e in ipairs(entries) do
        lines[#lines + 1] = string.format("  %-22s [%s]  %s",
          e.name, e.owner or "?", e.description or "")
      end
      emit(lines)
      return
    end

    local spec = core.mailbox.commands.get(cmd_name)
    if not spec then
      emit({ "run: unknown command '" .. cmd_name
             .. "' (type 'run' for the live list)" })
      return
    end

    local args = _parse_run_args(cmd_name, toks)

    local ok_call, result = pcall(spec.handler, args, { admin = true })
    if not ok_call then
      emit({ "run: handler raised: " .. tostring(result) })
      return
    end
    if type(result) ~= "table" then
      emit({ "run: handler returned non-table: " .. tostring(result) })
      return
    end
    if result.ok == false then
      emit({ string.format("run %s: ERROR (%s) %s",
        cmd_name, tostring(result.code or "?"),
        tostring(result.error or "")) })
      return
    end
    -- Render value. For peek specifically, surface the lines
    -- directly (humans want to read terminal output, not JSON).
    if cmd_name == "peek" and type(result.value) == "table"
       and type(result.value.lines) == "table" then
      local v = result.value
      local lines = {
        string.format("peek slot=%d (alive=%s, %d/%d lines):",
          v.slot, tostring(v.terminal_alive),
          v.line_count or 0, v.buffer_total or 0),
      }
      for _, line in ipairs(v.lines) do
        lines[#lines + 1] = "  " .. line
      end
      emit(lines)
    else
      -- vim.inspect returns a multi-line string for nested tables;
      -- nvim_buf_set_lines (in emit) rejects any element containing
      -- `\n`. Split into separate lines AND scrub any stray CRs the
      -- handler may have stuffed into a value field.
      local out = { string.format("run %s: OK", cmd_name) }
      for line in (vim.inspect(result.value or {})):gmatch("([^\n]*)\n?") do
        if line ~= "" or #out == 1 then
          out[#out + 1] = "  " .. line
        end
      end
      -- Drop trailing empty line if gmatch produced one.
      if out[#out] == "  " then out[#out] = nil end
      emit(out)
    end

  elseif verb == "quit" then
    emit({ "Closing panel." })
    vim.schedule(function() require("auto-agents").close() end)

  elseif verb == "resource" then
    local sub = toks[2]
    local resources = require("auto-agents.resources")
    if sub == "grant" then
      local n = tonumber(toks[3])
      local path = toks[4]
      if not n or not path then
        emit({ "resource grant: usage 'resource grant <slot> <path>'" })
      else
        local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        local added = resources.grants.add(n, "path", abs)
        emit({ added and ("Granted path '" .. abs .. "' to slot " .. n .. " (effective at next spawn)")
                    or ("resource grant: already granted") })
      end
    elseif sub == "revoke" then
      local n = tonumber(toks[3])
      local path = toks[4]
      if not n or not path then
        emit({ "resource revoke: usage 'resource revoke <slot> <path>'" })
      else
        local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        local removed = resources.grants.remove(n, "path", abs)
        emit({ removed and ("Revoked path '" .. abs .. "' from slot " .. n)
                      or ("resource revoke: no matching grant") })
      end
    elseif sub == "cwd" then
      local n = tonumber(toks[3])
      local path = toks[4]
      if not n then
        emit({ "resource cwd: usage 'resource cwd <slot> <path>' (omit path to clear)" })
      elseif not path then
        local removed = resources.grants.remove(n, "cwd", nil)
        emit({ removed and ("Cleared cwd grant for slot " .. n)
                      or ("resource cwd: slot " .. n .. " had no cwd grant") })
      else
        local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        resources.grants.add(n, "cwd", abs)
        emit({ "Set cwd of slot " .. n .. " to '" .. abs .. "' (effective at next spawn)" })
      end
    elseif sub == "list" then
      local filter = {}
      local n = tonumber(toks[3])
      if n then filter.slot = n end
      local items = resources.grants.list(filter)
      local lines = { "", n and ("Grants for slot " .. n .. ":") or "Grants:" }
      if #items == 0 then
        table.insert(lines, "  (none)")
      else
        for _, g in ipairs(items) do
          table.insert(lines, string.format("  slot %d  %-5s  %s", g.slot, g.kind, g.value))
        end
      end
      table.insert(lines, "")
      emit(lines)
    elseif sub == "manager" then
      local action = toks[3]
      if action == "set" then
        local subordinate = tonumber(toks[4])
        local mgr = tonumber(toks[5])
        if not subordinate then
          emit({ "resource manager set: usage 'resource manager set <subordinate> <manager>' (omit manager to clear)" })
        else
          local ok, err = resources.manager.set(subordinate, mgr)
          if ok then
            if mgr then
              emit({ "Slot " .. subordinate .. " is now managed by slot " .. mgr })
            else
              emit({ "Cleared manager designation for slot " .. subordinate })
            end
          else
            emit({ "resource manager set: " .. (err or "failed") })
          end
        end
      elseif action == "show" or action == nil then
        local chains = resources.manager.list_chains()
        local lines = { "", "Manager → Subordinate(s):" }
        local count = 0
        for mgr, subs in pairs(chains) do
          count = count + 1
          table.insert(lines, string.format("  slot %d → { %s }", mgr, table.concat(vim.tbl_map(tostring, subs), ", ")))
        end
        if count == 0 then table.insert(lines, "  (none)") end
        table.insert(lines, "")
        emit(lines)
      else
        emit({ "resource manager: unknown action '" .. tostring(action) .. "' — try 'set' / 'show'" })
      end
    else
      emit({ "resource: unknown subverb '" .. tostring(sub) .. "' — try grant/revoke/cwd/list/manager" })
    end

  elseif verb == "kb" then
    local sub = toks[2]
    local kb = require("auto-agents.kb")
    if sub == "path" then
      local root = kb.root()
      kb.ensure_layout(root)
      emit({ "kb root: " .. root })
    elseif sub == "init" then
      local kb_types = require("auto-agents.kb.types")
      local type = toks[3]
      if not type then
        local lines = { "kb init: pick a type", "" }
        for _, t in ipairs(kb_types.list()) do
          table.insert(lines, string.format("  %-9s %s", t.name, t.description))
        end
        table.insert(lines, "  custom    (provide a path: 'kb init custom <path>')")
        table.insert(lines, "")
        emit(lines)
      else
        local cfg2 = require("auto-agents").state.config
        cfg2.kb = cfg2.kb or {}
        local seed_path
        if type == "custom" then
          seed_path = toks[4] and vim.fn.expand(toks[4]) or nil
          if not seed_path or vim.fn.filereadable(seed_path) ~= 1 then
            emit({ "kb init custom: needs a readable .md path — got '" .. tostring(toks[4]) .. "'" })
            return
          end
          cfg2.kb.seed_path = seed_path
        else
          if not kb_types.seed_path(type) then
            emit({ "kb init: unknown type '" .. type .. "'. try 'kb init' to list." })
            return
          end
          cfg2.kb.seed_path = nil
        end
        cfg2.kb.type = type
        local root = kb.root()
        kb.ensure_layout(root, { type = type, seed_path = seed_path, force_schema = true })
        require("auto-agents.config.store").save_current()
        emit({ "kb init (" .. type .. "): ensured at " .. root, "  AGENTS.md refreshed from seed." })
      end
    elseif sub == "scope" then
      local n = tonumber(toks[3])
      local specs = require("auto-agents.panel.wizard_specs")
      require("auto-agents.panel.wizard").start(specs.kb_scope(n), function(lines) emit(lines) end)
    elseif sub == "new" then
      local rel = toks[3]
      if rel and rel ~= "" then
        -- Power-user form: 'kb new <relative>' bypasses the wizard.
        local path = kb.resolve(rel)
        local dir = vim.fn.fnamemodify(path, ":h")
        vim.fn.mkdir(dir, "p")
        if vim.fn.filereadable(path) == 0 then
          local f = io.open(path, "w"); if f then f:close() end
          kb.log("new: " .. rel)
        end
        emit({ "Opening " .. path })
        vim.schedule(function()
          local panel = require("auto-agents").state.panel_winid
          local target_win
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_is_valid(w) and w ~= panel then
              local cfg2 = vim.api.nvim_win_get_config(w)
              if cfg2.relative == "" or cfg2.relative == nil then target_win = w; break end
            end
          end
          if target_win then pcall(vim.api.nvim_set_current_win, target_win) end
          vim.cmd("edit " .. vim.fn.fnameescape(path))
        end)
      else
        local specs = require("auto-agents.panel.wizard_specs")
        require("auto-agents.panel.wizard").start(specs.kb_new(), function(lines) emit(lines) end)
      end
    elseif sub == "open" then
      local rel = toks[3]
      if not rel then
        emit({ "kb open: usage 'kb open <relative-path>' (e.g. shared/notes/foo.md)" })
      else
        local path = kb.resolve(rel)
        emit({ "Opening " .. path })
        vim.schedule(function()
          local panel = require("auto-agents").state.panel_winid
          local target_win
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_is_valid(w) and w ~= panel then
              local cfg = vim.api.nvim_win_get_config(w)
              if cfg.relative == "" or cfg.relative == nil then target_win = w; break end
            end
          end
          if target_win then pcall(vim.api.nvim_set_current_win, target_win) end
          vim.cmd("edit " .. vim.fn.fnameescape(path))
        end)
      end
    elseif sub == "log" then
      emit({ "kb log: " .. kb.root() .. "/log.md" })
    elseif sub == "ingest" then
      local ingest = require("auto-agents.kb.ingest")
      local diff = ingest.diff(kb.root())
      local report = ingest.format_report(diff)
      emit(report)
      -- Optional --attach <N> dispatches the worklist to slot N's
      -- stdin so the agent can act on it without a manual hand-off.
      local attach_to
      for i = 3, #toks - 1 do
        if toks[i] == "--attach" then attach_to = tonumber(toks[i + 1]) end
      end
      if attach_to then
        local n_actionable = #diff.new + #diff.edited + #diff.orphan
        if n_actionable == 0 then
          emit({ "(no new/edited/orphan items — nothing to attach)" })
        else
          local lines = {
            "auto-agents kb ingest worklist (please synthesize per AGENTS.md):",
            "",
          }
          for _, l in ipairs(report) do lines[#lines + 1] = l end
          local payload = table.concat(lines, "\n")
          local ok = require("auto-agents").send_slot(attach_to, payload)
          emit({ ok and ("Sent worklist to slot " .. attach_to)
                    or ("send to slot " .. attach_to .. " failed (no running agent?)") })
        end
      end
    elseif sub == "sync" then
      local summary = require("auto-agents.kb.sync").sync_all(kb.root())
      local lines = { "", "kb sync: " .. summary.kb_root }
      if #summary.namespaces == 0 then
        table.insert(lines, "  (no namespaces)")
      else
        for _, ns in ipairs(summary.namespaces) do
          if ns.error then
            table.insert(lines, string.format("  %-22s ERROR: %s", ns.name, ns.error))
          else
            local broken = ns.broken or 0
            local broken_suffix = broken > 0 and string.format("  (%d broken link%s)", broken, broken == 1 and "" or "s") or ""
            table.insert(lines, string.format("  %-22s %d entries%s", ns.name, ns.count, broken_suffix))
          end
        end
        if summary.total_broken > 0 then
          table.insert(lines, "")
          table.insert(lines, string.format("  total broken wikilinks: %d", summary.total_broken))
        end
      end
      table.insert(lines, "")
      emit(lines)
    elseif sub == "obsidian-init" then
      local result = require("auto-agents.kb.obsidian").init(kb.root())
      local lines = { "", "kb obsidian-init: " .. result.dir }
      for _, p in ipairs(result.written_files) do
        table.insert(lines, "  wrote   " .. p)
      end
      for _, p in ipairs(result.skipped_files) do
        table.insert(lines, "  skipped " .. p .. " (already exists)")
      end
      table.insert(lines, "")
      table.insert(lines, "Open " .. kb.root() .. " in Obsidian as a vault.")
      table.insert(lines, "")
      emit(lines)
    elseif sub == "attach" then
      local n = tonumber(toks[3])
      local rel = toks[4]
      if not n or not rel then
        emit({ "kb attach: usage 'kb attach <slot> <relative-path>'" })
      else
        local abs = kb.resolve(rel)
        local ok, err = require("auto-agents").attach_slot(n, { abs })
        if ok then
          emit({ "Attached " .. abs .. " → slot " .. n })
        else
          emit({ "kb attach: " .. (err or "failed") })
        end
      end
    elseif sub == "tail" then
      -- Open log.md in the editor area (non-panel non-float window).
      local log_path = kb.root() .. "/log.md"
      kb.ensure_layout(kb.root())
      emit({ "Opening " .. log_path .. " (autoread on)" })
      vim.schedule(function()
        local panel = require("auto-agents").state.panel_winid
        local target_win
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_win_is_valid(w) and w ~= panel then
            local cfg = vim.api.nvim_win_get_config(w)
            if cfg.relative == "" or cfg.relative == nil then
              target_win = w; break
            end
          end
        end
        if target_win then pcall(vim.api.nvim_set_current_win, target_win) end
        vim.cmd("edit " .. vim.fn.fnameescape(log_path))
        vim.bo.autoread = true
        vim.cmd("normal! G")
      end)
    else
      emit({ "kb: unknown subverb '" .. tostring(sub) .. "' — try path/scope/sync/new/open/attach/tail/log" })
    end

  elseif verb == "panel" then
    local sub = toks[2]
    local aa = require("auto-agents")
    local cfg_mod = require("auto-agents.config")
    if sub == "show" then
      local cfg = aa.state.config or {}
      local p = cfg.panel or {}
      local effective = cfg_mod.resolve_panel_width(cfg, vim.o.columns)
      local override = p.width_override
      local lo, hi = panel_min(), panel_max()
      emit({
        "",
        "Panel width:",
        "  effective       = " .. tostring(effective) .. "  (current columns = " .. tostring(vim.o.columns) .. ")",
        "  override        = " .. (override and tostring(override) or "<none>"),
        "  percentage      = " .. tostring(p.percentage),
        "  min_width       = " .. tostring(p.min_width),
        "  max_width       = " .. tostring(p.max_width),
        "  allowed range   = " .. tostring(lo) .. ".." .. tostring(hi) .. "  (for `panel resize`)",
        "",
      })
    elseif sub == "resize" then
      local arg = toks[3]
      if arg then
        -- One-shot form: `panel resize 85`. No wizard.
        local n = tonumber(arg)
        local lo, hi = panel_min(), panel_max()
        if not n or n ~= math.floor(n) then
          emit({ "panel resize: '" .. tostring(arg) .. "' is not an integer" })
        elseif n < lo or n > hi then
          emit({ string.format("panel resize: %d out of range (allowed %d..%d)", n, lo, hi) })
        else
          M._apply_panel_width(n, emit)
        end
      else
        local specs = require("auto-agents.panel.wizard_specs")
        require("auto-agents.panel.wizard").start(specs.panel_resize(), function(lines) emit(lines) end)
      end
    elseif sub == "reset" then
      M._apply_panel_width(nil, emit)
    else
      emit({ "panel: unknown subverb '" .. tostring(sub) .. "' — try resize/reset/show" })
    end

  elseif verb == "slot" then
    -- `slot add N`     — grow slot_count by N (cap 9).
    -- `slot remove N`  — shrink slot_count by N (floor 2). Refuses if
    --                    any of the to-be-removed (highest-indexed)
    --                    slots have a bootstrap entry assigned.
    -- `slot show`      — print current slot_count + which slots have agents.
    local sub = toks[2]
    local aa = require("auto-agents")
    local cfg_mod = require("auto-agents.config")
    local store = require("auto-agents.config.store")
    local cfg = aa.state.config or {}
    cfg.panel = cfg.panel or {}
    local current = cfg.panel.slot_count or 5

    local function find_assignments(low, high)
      -- Return a sorted list of slots in [low, high] that have a
      -- bootstrap entry. cfg.agents.bootstrap is the active agent
      -- registry; entries with `slot = N` claim slot N.
      local hits = {}
      local bs = (cfg.agents and cfg.agents.bootstrap) or {}
      for _, e in ipairs(bs) do
        local s = e and e.slot
        if type(s) == "number" and s >= low and s <= high then
          hits[#hits + 1] = s
        end
      end
      table.sort(hits)
      return hits
    end

    local function persist_and_sync(new_count)
      -- v0.2.0: write through auto-agents.state, which writes the
      -- auto-core namespace + fires the watcher (cfg.panel.slot_count
      -- update + aa.sync_slot_count() side-effect happen there). The
      -- json-backend persist is debounced by auto-core; no longer
      -- needs a synchronous TOML save.
      local state_mod = require("auto-agents.state")
      local ok, err = state_mod.set_slot_count(new_count)
      if ok then
        emit({ ("Persisted slot_count = %d → auto-core (json ns 'auto-agents')")
          :format(new_count) })
      else
        emit({ ("slot_count = %d rejected: %s")
          :format(new_count, tostring(err)) })
      end
    end

    if sub == "add" then
      local n = tonumber(toks[3])
      if not n or n ~= math.floor(n) or n < 1 then
        emit({ "slot add: N must be a positive integer; got '" .. tostring(toks[3]) .. "'" })
      else
        local target = current + n
        if target > cfg_mod.SLOT_COUNT_MAX then
          emit({ ("slot add %d: slot_count %d + %d = %d exceeds maximum %d")
            :format(n, current, n, target, cfg_mod.SLOT_COUNT_MAX) })
        else
          persist_and_sync(target)
        end
      end
    elseif sub == "remove" then
      local n = tonumber(toks[3])
      if not n or n ~= math.floor(n) or n < 1 then
        emit({ "slot remove: N must be a positive integer; got '" .. tostring(toks[3]) .. "'" })
      else
        local target = current - n
        if target < cfg_mod.SLOT_COUNT_MIN then
          emit({ ("slot remove %d: slot_count %d - %d = %d below minimum %d")
            :format(n, current, n, target, cfg_mod.SLOT_COUNT_MIN) })
        else
          local hits = find_assignments(target + 1, current)
          if #hits > 0 then
            local labels = {}
            for _, s in ipairs(hits) do labels[#labels + 1] = tostring(s) end
            emit({
              ("slot remove %d: cannot shrink — slot%s %s %s assigned. Run `agent remove <N>` first.")
                :format(n, #hits == 1 and "" or "s",
                        table.concat(labels, ", "),
                        #hits == 1 and "is" or "are"),
            })
          else
            persist_and_sync(target)
          end
        end
      end
    elseif sub == "show" or sub == nil then
      local lines = {
        "",
        ("slot_count = %d  (range %d..%d)"):format(current,
          cfg_mod.SLOT_COUNT_MIN, cfg_mod.SLOT_COUNT_MAX),
      }
      local bs = (cfg.agents and cfg.agents.bootstrap) or {}
      local by_slot = {}
      for _, e in ipairs(bs) do
        if e and type(e.slot) == "number" then
          by_slot[e.slot] = e
        end
      end
      for s = 1, current do
        local e = by_slot[s]
        if e then
          local label = e.title or e.name or e.kind or "(unnamed)"
          lines[#lines + 1] = ("  slot %d  %s"):format(s, label)
        else
          lines[#lines + 1] = ("  slot %d  -"):format(s)
        end
      end
      lines[#lines + 1] = ""
      emit(lines)
    else
      emit({ "slot: unknown subverb '" .. tostring(sub) .. "' — try add/remove/show" })
    end

  elseif verb == "config" then
    local sub = toks[2]
    local store = require("auto-agents.config.store")
    local aa = require("auto-agents")
    if sub == "save" then
      local ok, path = store.save_current()
      emit({ ok and ("Saved → " .. path) or "Failed to save config" })
    elseif sub == "reset" then
      local key = aa.state.session_project_key
      if not key then
        emit({ "config reset: session not initialized" })
      else
        local removed, path = store.remove_project(key)
        emit({ removed
          and ("Removed " .. path .. " (next read falls back to global)")
          or  ("No per-project config to remove (" .. path .. " did not exist)") })
      end
    elseif sub == "show" then
      local cfg = aa.state.config or {}
      local key = aa.state.session_project_key or "?"
      local active_path, target = store.active_path(key)
      local lines = {
        "",
        "Effective config:",
        "  config_source     = " .. tostring(aa.state.config_source),
        "  active_target     = " .. target .. "  → " .. active_path,
        "  project_path      = " .. store.project_path(key),
        "  global_path       = " .. store.global_path(),
        "  session_cwd       = " .. tostring(aa.state.session_cwd),
        "  session_project   = " .. tostring(aa.state.session_project_root),
        "  panel.percentage  = " .. tostring(((cfg.panel or {}).percentage)),
        "  panel.min_width   = " .. tostring(((cfg.panel or {}).min_width)),
        "  panel.max_width   = " .. tostring(((cfg.panel or {}).max_width)),
        "  panel.width_override = " .. tostring(((cfg.panel or {}).width_override) or "<none>"),
        "  panel.side        = " .. tostring(((cfg.panel or {}).side)),
        "  log_level         = " .. tostring(cfg.log_level),
        "",
      }
      emit(lines)
    elseif sub == "path" then
      local key = aa.state.session_project_key or "?"
      local active_path, target = store.active_path(key)
      emit({ "active config (" .. target .. "): " .. active_path })
    else
      emit({ "config: unknown subverb '" .. tostring(sub) .. "' — try 'save', 'reset', 'show', 'path'" })
    end

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
      local specs = require("auto-agents.panel.wizard_specs")
      require("auto-agents.panel.wizard").start(specs.agent("add"), function(lines) emit(lines) end)
    elseif sub == "edit" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent edit: missing slot number (1..9)" })
      else
        local specs = require("auto-agents.panel.wizard_specs")
        require("auto-agents.panel.wizard").start(specs.agent("edit", n), function(lines) emit(lines) end)
      end
    elseif sub == "remove" or sub == "rm" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent remove: usage 'agent remove <slot>'" })
      else
        local ok, note = require("auto-agents").remove_slot(n)
        if ok and not note then
          emit({ "Removed slot " .. n })
        elseif ok and note then
          emit({ "agent remove: slot " .. n .. " " .. note })
        else
          emit({ "agent remove: " .. (note or "failed") })
        end
      end
    elseif sub == "kill" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent kill: missing slot number (1..9)" })
      else
        local ok = require("auto-agents").kill_slot(n)
        emit({ ok and ("Killed slot " .. n) or ("Slot " .. n .. " has no running agent") })
      end
    elseif sub == "restart" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent restart: missing slot number (1..9)" })
      else
        emit({ "Restarting slot " .. n .. "…" })
        vim.schedule(function() require("auto-agents").restart_slot(n) end)
      end
    elseif sub == "rename" then
      local n = tonumber(toks[3])
      local new_name = toks[4]
      if not n or not new_name then
        emit({ "agent rename: usage 'agent rename <slot> <new-name>'" })
      else
        local ok = require("auto-agents").rename_slot(n, new_name)
        emit({ ok and ("Renamed slot " .. n .. " → " .. new_name)
                  or ("Slot " .. n .. " has no bootstrap entry to rename") })
      end
    elseif sub == "send" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent send: usage 'agent send <slot> <text>'" })
      else
        -- Capture everything after "agent send <N>" verbatim — preserves
        -- quoting, multiple spaces, etc.
        local send_text = input:match("^agent%s+send%s+%S+%s*(.*)$") or ""
        if send_text == "" then
          emit({ "agent send: text is empty" })
        else
          local ok = require("auto-agents").send_slot(n, send_text)
          emit({ ok and ("Sent to slot " .. n)
                    or ("Slot " .. n .. " has no running agent or send failed") })
        end
      end
    elseif sub == "mem" then
      emit(require("auto-agents").mem_report())
    elseif sub == "move" then
      local from = tonumber(toks[3])
      local to = tonumber(toks[4])
      local swap = false
      for i = 5, #toks do if toks[i] == "--swap" then swap = true end end
      if not from or not to then
        emit({ "agent move: usage 'agent move <from> <to> [--swap]'" })
      else
        local ok, err = require("auto-agents").move_slot(from, to, swap)
        if ok then
          emit({ string.format("Moved slot %d → %d%s", from, to, swap and " (swap)" or "") })
        else
          emit({ "agent move: " .. (err or "failed") })
        end
      end
    elseif sub == "attach" then
      local n = tonumber(toks[3])
      if not n then
        emit({ "agent attach: usage 'agent attach <slot> [<path1> <path2> ...]'" })
      else
        local paths = {}
        for i = 4, #toks do table.insert(paths, toks[i]) end
        local ok, err = require("auto-agents").attach_slot(n, #paths > 0 and paths or nil)
        if ok then
          emit({ "Attached " .. (#paths > 0 and (#paths .. " path(s)") or "tree selection") .. " to slot " .. n })
        else
          emit({ "agent attach: " .. (err or "failed") })
        end
      end
    elseif sub == "task" then
      local action = toks[3]
      if action == "add" then
        local n = tonumber(toks[4])
        if not n then
          emit({ "agent task add: usage 'agent task add <slot> <text...>'" })
        else
          local task_text = input:match("^agent%s+task%s+add%s+%S+%s*(.*)$") or ""
          if task_text == "" then
            emit({ "agent task add: text is empty" })
          else
            local ok = require("auto-agents").task_add(n, task_text)
            emit({ ok and ("Added task to slot " .. n .. ": " .. task_text)
                      or ("Slot " .. n .. " has no bootstrap entry") })
          end
        end
      elseif action == "done" then
        local n = tonumber(toks[4])
        local idx = tonumber(toks[5])
        if not n or not idx then
          emit({ "agent task done: usage 'agent task done <slot> <index>'" })
        else
          local ok, removed = require("auto-agents").task_done(n, idx)
          emit({ ok and ("Done task " .. idx .. " of slot " .. n .. ": " .. tostring(removed))
                    or ("agent task done: invalid slot or index") })
        end
      elseif action == "list" or action == nil then
        local n = tonumber(toks[4])
        if action == nil and not n then
          -- print all slots' tasks
          local lines = { "", "Tasks:" }
          local saw_any = false
          for slot = 1, require("auto-agents").MAX_SLOT do
            local tasks = require("auto-agents").task_list(slot)
            if #tasks > 0 then
              saw_any = true
              table.insert(lines, "  slot " .. slot .. ":")
              for i, t in ipairs(tasks) do
                table.insert(lines, string.format("    %d. %s", i, t))
              end
            end
          end
          if not saw_any then table.insert(lines, "  (no tasks)") end
          table.insert(lines, "")
          emit(lines)
        else
          if not n then
            emit({ "agent task list: usage 'agent task list <slot>' or 'agent task'" })
          else
            local tasks = require("auto-agents").task_list(n)
            local lines = { "", "Tasks for slot " .. n .. ":" }
            if #tasks == 0 then
              table.insert(lines, "  (none)")
            else
              for i, t in ipairs(tasks) do
                table.insert(lines, string.format("  %d. %s", i, t))
              end
            end
            table.insert(lines, "")
            emit(lines)
          end
        end
      else
        emit({ "agent task: unknown action '" .. tostring(action) .. "' — try 'add' / 'done' / 'list'" })
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
    candidates = { "help", "?", ":h", "status", "agent", "kb", "resource", "project", "config", "panel", "slot", "term", "run", "clear", "quit" }
  elseif #prev_toks == 1 and prev_toks[1] == "run" then
    -- Pull the live registry rather than a hardcoded list — adding
    -- a new command via `mailbox.commands.register` makes it
    -- tab-complete here without touching this module.
    local core_ok, core = pcall(require, "auto-core")
    if core_ok then
      candidates = {}
      for _, e in ipairs(core.mailbox.commands.list() or {}) do
        candidates[#candidates + 1] = e.name
      end
      table.sort(candidates)
    else
      candidates = {}
    end
  elseif #prev_toks == 2 and prev_toks[1] == "run"
    and (prev_toks[2] == "peek" or prev_toks[2] == "say"
         or prev_toks[2] == "wake") then
    -- Offer live slot numbers for peek/say.
    local aa_ok, aa = pcall(require, "auto-agents")
    candidates = {}
    if aa_ok and aa.state and aa.state.slot_terminals then
      for n in pairs(aa.state.slot_terminals) do
        if type(n) == "number" and n >= 1 then
          candidates[#candidates + 1] = tostring(n)
        end
      end
      table.sort(candidates, function(a, b) return tonumber(a) < tonumber(b) end)
    end
  elseif #prev_toks == 1 and prev_toks[1] == "panel" then
    candidates = { "resize", "reset", "show" }
  elseif #prev_toks == 2 and prev_toks[1] == "panel" and prev_toks[2] == "resize" then
    -- Offer the current effective width plus a few common round-number
    -- widths spanning the allowed range. Prefix-filter (further down)
    -- narrows them as the user types — e.g. typing "1" surfaces 100,
    -- 120, 140; typing "8" surfaces 80. Out-of-range typed values
    -- still pass through; the dispatcher rejects them.
    local cfg_mod = require("auto-agents.config")
    local aa = require("auto-agents")
    local cfg = aa.state.config or {}
    local effective = cfg_mod.resolve_panel_width(cfg, vim.o.columns)
    local seen = {}
    candidates = {}
    local function push(v)
      local s = tostring(v)
      if not seen[s] then seen[s] = true; table.insert(candidates, s) end
    end
    push(effective)
    for _, v in ipairs({ 40, 60, 80, 100, 120, 140 }) do push(v) end
  elseif #prev_toks == 1 and prev_toks[1] == "resource" then
    candidates = { "grant", "revoke", "cwd", "list", "manager" }
  elseif #prev_toks == 2 and prev_toks[1] == "resource"
    and (prev_toks[2] == "grant" or prev_toks[2] == "revoke"
         or prev_toks[2] == "cwd" or prev_toks[2] == "list") then
    candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 2 and prev_toks[1] == "resource" and prev_toks[2] == "manager" then
    candidates = { "set", "show" }
  elseif #prev_toks == 3 and prev_toks[1] == "resource" and prev_toks[2] == "manager"
    and prev_toks[3] == "set" then
    candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 4 and prev_toks[1] == "resource" and prev_toks[2] == "manager"
    and prev_toks[3] == "set" then
    candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 1 and prev_toks[1] == "slot" then
    candidates = { "add", "remove", "show" }
  elseif #prev_toks == 2 and prev_toks[1] == "slot"
    and (prev_toks[2] == "add" or prev_toks[2] == "remove") then
    candidates = { "1", "2", "3", "4" }
  elseif #prev_toks == 1 and prev_toks[1] == "config" then
    candidates = { "save", "reset", "show", "path" }
  elseif #prev_toks == 1 and prev_toks[1] == "project" then
    candidates = { "init", "import", "remove", "list", "show" }
  elseif #prev_toks == 1 and prev_toks[1] == "term" then
    candidates = { "focus", "send", "list", "kill", "hide" }
  elseif #prev_toks == 2 and prev_toks[1] == "term"
    and (prev_toks[2] == "focus" or prev_toks[2] == "send" or prev_toks[2] == "kill") then
    candidates = { "1", "2", "3", "4" }
  elseif #prev_toks == 1 and prev_toks[1] == "help" then
    candidates = { "open", "agent", "kb", "project", "resource", "term", "config", "panel", "general" }
  elseif #prev_toks == 2 and prev_toks[1] == "help" and prev_toks[2] == "open" then
    candidates = { "index", "agent", "kb", "project", "resource", "term", "config", "panel", "general" }
  elseif #prev_toks == 1 and prev_toks[1] == "kb" then
    candidates = { "init", "ingest", "path", "scope", "sync", "new", "open", "attach", "tail", "log", "obsidian-init" }
  elseif #prev_toks == 2 and prev_toks[1] == "kb" and prev_toks[2] == "init" then
    candidates = { "coding", "wiki", "research", "ops", "general", "custom" }
  elseif #prev_toks == 2 and prev_toks[1] == "kb" and prev_toks[2] == "ingest" then
    candidates = { "--attach" }
  elseif #prev_toks == 3 and prev_toks[1] == "kb" and prev_toks[2] == "ingest"
      and prev_toks[3] == "--attach" then
    candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 2 and prev_toks[1] == "kb"
    and (prev_toks[2] == "scope" or prev_toks[2] == "attach") then
    candidates = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 3 and prev_toks[1] == "kb" and prev_toks[2] == "scope" then
    candidates = { "shared", "private", "isolated" }
  elseif #prev_toks == 1 and prev_toks[1] == "agent" then
    candidates = { "focus", "list", "add", "edit", "kill", "restart", "rename", "send", "attach", "move", "task", "mem" }
  elseif #prev_toks == 2 and prev_toks[1] == "agent" and prev_toks[2] == "task" then
    candidates = { "add", "done", "list" }
  elseif #prev_toks == 3 and prev_toks[1] == "agent" and prev_toks[2] == "task"
    and (prev_toks[3] == "add" or prev_toks[3] == "done" or prev_toks[3] == "list") then
    candidates = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 2 and prev_toks[1] == "agent"
    and (prev_toks[2] == "focus" or prev_toks[2] == "edit"
         or prev_toks[2] == "kill" or prev_toks[2] == "restart"
         or prev_toks[2] == "rename" or prev_toks[2] == "send"
         or prev_toks[2] == "attach" or prev_toks[2] == "move") then
    candidates = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 3 and prev_toks[1] == "agent" and prev_toks[2] == "move" then
    candidates = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  elseif #prev_toks == 4 and prev_toks[1] == "agent" and prev_toks[2] == "move" then
    candidates = { "--swap" }
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
M._parse_run_args = _parse_run_args

---Apply a `panel.width_override` mutation: update live cfg, persist to
---the active TOML, and trigger a live width refresh on the open panel
---+ a SIGWINCH on every running TUI. Pass `n = nil` to clear (the
---`panel reset` path). Called from the dispatcher and from the
---wizard's on_complete via `wizard_specs.panel_resize`.
---@param n integer|nil
---@param emit fun(lines: string[])
function M._apply_panel_width(n, emit)
  local aa = require("auto-agents")
  local cfg_mod = require("auto-agents.config")
  local cfg = aa.state.config
  if not cfg then
    emit({ "panel: config not initialized" })
    return
  end
  if n ~= nil then
    if type(n) ~= "number" or n ~= math.floor(n) then
      emit({ "panel: width must be an integer" }); return
    end
    local lo, hi = panel_min(), panel_max()
    if n < lo or n > hi then
      emit({ string.format("panel: %d out of range (allowed %d..%d)", n, lo, hi) })
      return
    end
  end
  -- v0.2.0: width_override goes through auto-agents.state, which
  -- writes the auto-core namespace + fires the watcher
  -- (cfg.panel.width_override mirror + aa.refresh_panel_width
  -- side-effect happen there). The json-backend persist is debounced
  -- by auto-core; no longer needs a synchronous TOML save.
  local state_mod = require("auto-agents.state")
  local set_ok, set_err = state_mod.set_width_override(n)
  if not set_ok then
    emit({ "panel: " .. tostring(set_err) })
    return
  end
  local effective = cfg_mod.resolve_panel_width(cfg, vim.o.columns)
  if n then
    emit({ string.format("panel width override = %d  (effective=%d, saved → auto-core json)",
      n, effective) })
  else
    emit({ string.format("panel width override cleared  (effective=%d, saved → auto-core json)",
      effective) })
  end
end

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
    -- Defer so vim has time to add the new prompt line. Without this,
    -- emit() would land between the user's input and the new prompt
    -- rather than above the new prompt.
    vim.schedule(function()
      local wizard = require("auto-agents.panel.wizard")
      if wizard.is_active() then
        wizard.feed(input or "")
      else
        dispatch(input)
      end
    end)
  end)

  -- <C-c> aborts an active wizard (terminal-style interrupt). When no
  -- wizard is running, the keymap is a no-op so the prompt buffer's
  -- usual behavior is preserved (^C cancels current input).
  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    local wizard = require("auto-agents.panel.wizard")
    if wizard.is_active() then
      wizard.cancel()
    else
      -- Fall through to default — feed a literal <C-c> to vim.
      local termcoded = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
      vim.api.nvim_feedkeys(termcoded, "n", false)
    end
  end, { buffer = bufnr, silent = true })

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

  -- F-key passthrough: insert mode in a prompt buffer otherwise eats the
  -- F-key sequence and submits it as a garbage command on <CR>. Exit
  -- insert and re-feed so the global normal-mode F-key mapping fires
  -- (e.g. F5/F6/F12 → AutoAgents panel/dock; F1-F4 → snacks helpers).
  for i = 1, 12 do
    local lhs = "<F" .. i .. ">"
    local termcoded = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.keymap.set("i", lhs, function()
      vim.cmd("stopinsert")
      -- "m" mode = remap-allowed, so the global mapping fires.
      vim.api.nvim_feedkeys(termcoded, "m", false)
    end, { buffer = bufnr, silent = true })
  end

  -- Normal-mode 0..9 → focus that slot. Lets the user navigate slots
  -- from inside admin without typing 'agent focus N <CR>'. Buffer-local
  -- so the rest of vim's normal-mode 0..9 (line jumps, count prefix)
  -- isn't disturbed elsewhere.
  for i = 0, 9 do
    vim.keymap.set("n", tostring(i), function()
      require("auto-agents").focus_slot(i)
    end, { buffer = bufnr, silent = true, desc = "Focus slot " .. i })
  end

  -- Banner: written before the auto-generated prompt line at index 0.
  local banner = {
    "auto-agents v0.1.0-pre.1 — orchestration admin (slot 0)",
    "Type ? for help. Try 'status' to see slot states.",
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, banner)

  M._bufnr = bufnr

  -- First-run auto-engage (M6): if the resolved config has zero agents,
  -- proactively start the agent.add wizard so a fresh nvim begins with
  -- a creation flow instead of an empty admin REPL. Defer with schedule
  -- so the prompt line is fully rendered before the wizard emits.
  vim.schedule(function()
    if not buf_valid() then return end
    local aa = require("auto-agents")
    local cfg = aa.state.config or {}
    local count = ((cfg.agents and cfg.agents.bootstrap) and #cfg.agents.bootstrap) or 0
    if count > 0 then return end
    local wizard = require("auto-agents.panel.wizard")
    if wizard.is_active() then return end
    emit({
      "",
      "(no agents configured — starting 'agent add' wizard)",
      "(<C-c> to cancel; type 'project init' first if you want a per-project config)",
    })
    local specs = require("auto-agents.panel.wizard_specs")
    wizard.start(specs.agent("add"), function(lines) emit(lines) end)
  end)

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
