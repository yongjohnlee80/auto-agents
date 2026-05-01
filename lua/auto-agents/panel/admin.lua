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
    "  help, ?, :h                    show this help",
    "  status                         list agent slots and state",
    "  agent focus <N>                focus slot N (0..9)",
    "  agent list                     list configured agents",
    "  agent add                      open new-agent form (D14)",
    "  agent edit <N>                 open edit form for slot N",
    "  agent kill <N>                 stop the agent in slot N",
    "  agent restart <N>              kill and re-spawn slot N",
    "  agent rename <N> <new-name>    rename the bootstrap entry",
    "  agent send <N> <text...>       write <text> to agent N's stdin",
    "  agent attach <N> [<paths>]     send paths (or tree selection) to slot N",
    "  agent move <F> <T> [--swap]    relocate (or swap) a slot's content",
    "  agent task add <N> <text>      add a task to slot N's list",
    "  agent task done <N> <index>    mark task #<index> done (removes it)",
    "  agent task list [<N>]          show tasks for slot N (or all)",
    "  agent mem                      report RSS per running agent",
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
    "  config save                    persist current bootstrap to JSON",
    "  config reset                   delete persisted JSON (revert to lazy spec)",
    "  config show                    show effective config + persistence path",
    "  clear                          wipe history above the prompt",
    "  quit                           close the auto-agents panel",
    "",
    "Kinds: claude | codex | gemini | copilot | generic",
    "Persistence: form save / agent rename / agent move auto-save",
    "             to <stdpath('data')>/auto-agents/<project>.json",
    "Future: kb *, resource * (M4/M5).",
    "",
  }
end

local function status_lines()
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  local by_slot = {}
  for _, e in ipairs(bs) do by_slot[e.slot] = e end
  local main_max = aa.MAIN_SLOT_MAX or 6
  local max_slot = aa.MAX_SLOT or 9

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
      if slot > main_max then
        local float = require("auto-agents.float")
        local fb = float.get_bufnr(slot)
        state = (fb and vim.api.nvim_buf_is_valid(fb)) and "running" or "-"
      else
        local term = aa.state.slot_terminals[slot]
        state = (term and term:is_alive()) and "running" or "-"
      end
    end
    local marker = (slot == aa.state.focused_slot) and "→" or " "
    local where = (slot == 0) and "admin" or (slot <= main_max and "main" or "float")
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
    elseif sub == "scope" then
      local n = tonumber(toks[3])
      local mode = toks[4]
      local valid = { shared = true, private = true, isolated = true }
      if not n or not mode or not valid[mode] then
        emit({ "kb scope: usage 'kb scope <slot> <shared|private|isolated>'" })
      else
        local cfg = require("auto-agents").state.config or {}
        cfg.agents = cfg.agents or {}
        cfg.agents.bootstrap = cfg.agents.bootstrap or {}
        local found
        for _, e in ipairs(cfg.agents.bootstrap) do
          if e.slot == n then e.kb_scope = mode; found = e; break end
        end
        if found then
          pcall(function() require("auto-agents.agent.persist").save_current() end)
          emit({ "Set kb_scope of slot " .. n .. " to " .. mode .. " (effective at next spawn)" })
        else
          emit({ "kb scope: slot " .. n .. " has no bootstrap entry" })
        end
      end
    elseif sub == "new" or sub == "open" then
      local rel = toks[3]
      if not rel then
        emit({ "kb " .. sub .. ": usage 'kb " .. sub .. " <relative-path>' (e.g. shared/notes/foo.md)" })
      else
        local path = kb.resolve(rel)
        if sub == "new" then
          local dir = vim.fn.fnamemodify(path, ":h")
          vim.fn.mkdir(dir, "p")
          if vim.fn.filereadable(path) == 0 then
            local f = io.open(path, "w"); if f then f:close() end
            kb.log("new: " .. rel)
          end
        end
        emit({ "Opening " .. path })
        vim.schedule(function()
          local target = M.get_bufnr() and require("auto-agents").state.panel_winid
          -- Open in a non-panel, non-float window so the file lands in
          -- the editor area, not in the panel.
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
          if target_win then
            pcall(vim.api.nvim_set_current_win, target_win)
            vim.cmd("edit " .. vim.fn.fnameescape(path))
          else
            vim.cmd("edit " .. vim.fn.fnameescape(path))
          end
        end)
      end
    elseif sub == "log" then
      emit({ "kb log: " .. kb.root() .. "/log.md" })
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

  elseif verb == "config" then
    local sub = toks[2]
    if sub == "save" then
      local persist = require("auto-agents.agent.persist")
      local ok = persist.save_current()
      emit({ ok and ("Saved bootstrap to " .. persist.file_path())
                or "Failed to save persisted state" })
    elseif sub == "reset" then
      local persist = require("auto-agents.agent.persist")
      local path = persist.file_path()
      local ok = persist.reset()
      emit({ ok and ("Reset persisted state at " .. path .. " (lazy-spec will be used on next setup)")
                or "Failed to reset persisted state" })
    elseif sub == "show" then
      local persist = require("auto-agents.agent.persist")
      local cfg = require("auto-agents").state.config or {}
      local lines = {
        "",
        "Effective config:",
        "  panel.percentage  = " .. tostring(((cfg.panel or {}).percentage)),
        "  panel.min_width   = " .. tostring(((cfg.panel or {}).min_width)),
        "  panel.max_width   = " .. tostring(((cfg.panel or {}).max_width)),
        "  panel.side        = " .. tostring(((cfg.panel or {}).side)),
        "  log_level         = " .. tostring(cfg.log_level),
        "  persist file      = " .. persist.file_path(),
        "  persisted exists  = " .. tostring(vim.uv.fs_stat(persist.file_path()) ~= nil),
        "",
      }
      emit(lines)
    elseif sub == "path" then
      emit({ "persist file: " .. require("auto-agents.agent.persist").file_path() })
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
    candidates = { "help", "?", ":h", "status", "agent", "kb", "resource", "config", "clear", "quit" }
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
  elseif #prev_toks == 1 and prev_toks[1] == "config" then
    candidates = { "save", "reset", "show", "path" }
  elseif #prev_toks == 1 and prev_toks[1] == "kb" then
    candidates = { "path", "scope", "sync", "new", "open", "attach", "tail", "log", "obsidian-init" }
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
