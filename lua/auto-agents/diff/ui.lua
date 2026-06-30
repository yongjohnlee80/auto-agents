--- auto-agents.diff.ui — Multi-pane float UI for reviewing queued diffs
---
--- @module 'auto-agents.diff.ui'

local M = {}

local queue = require("auto-agents.diff.queue")

--- @type AutoCoreMultiFloat?
local _mfloat = nil

--- Live event-subscription handles. Owned by the panel — registered
--- in `M.open()` and released in the `on_close` callback. Wired this
--- way (rather than at module-load) so the auto-close contract
--- survives `events._reset_for_tests` / `:Lazy reload` mid-session:
--- each panel open re-subscribes, so a stale events bus can't leave
--- us with a panel that refuses to close after the user drains the
--- queue via A/D. See `tests/diff_ui_spec.lua` section [5b] for the
--- regression contract.
--- @type table<string, AutoCoreSubHandle?>
local _event_handles = { refresh = nil, autoclose = nil }

--- @type AutoAgentsDiffRequest[]
local _render_list = {}
local _selected_idx = 1

--- In-progress edits keyed by req.id. Populated by a TextChanged autocmd
--- on the preview buffer whenever the user types in edit mode; consumed
--- by `update_preview` (so switching selection and back restores the
--- edits) and by the A handler (so Accept commits the edited content
--- rather than `req.new_contents`). Cleared per-id by the
--- `auto-agents:diff_removed` subscriber.
--- @type table<string, string[]>
local _edits_by_id = {}

--- Panel-wide edit-mode flag. `E` on the preview pane toggles it; affects
--- whether the preview buffer is modifiable and which footer hint shows.
--- @type boolean
local _edit_mode = false

--- ID of the autocmd that syncs preview-buffer text into `_edits_by_id`.
--- Owned by the live float; cleared on close.
--- @type integer?
local _edits_autocmd_id = nil

--- ADR-0028 / ADR-0039 C1: window options must be written scope-local.
--- Bare `vim.wo[win].x = v` uses `:set` semantics on global-local
--- options and pollutes the global default for every subsequently
--- created window (the family's winfixbuf-class bug).
--- @param win integer
--- @param name string
--- @param value any
local function set_winlocal(win, name, value)
  vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

--- Best-effort filetype detection — originally lifted from the legacy
--- `mcp/ws-server/diff.lua` (retired in ADR-0039 Batch B; this is now
--- the sole copy) so the diff panes can carry syntax highlighting that
--- matches the underlying file. Falls through:
--- vim.filetype.match → extension table → nil.
--- @param path string
--- @return string?
local function detect_filetype(path)
  if vim.filetype and type(vim.filetype.match) == "function" then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    if ok and ft and ft ~= "" then return ft end
  end
  local ext = path:match("%.([%w_%-]+)$") or ""
  local map = {
    lua = "lua", ts = "typescript", js = "javascript",
    jsx = "javascriptreact", tsx = "typescriptreact",
    py = "python", go = "go", rs = "rust", c = "c", h = "c",
    cpp = "cpp", hpp = "cpp", md = "markdown", sh = "sh",
    zsh = "zsh", bash = "bash", json = "json", yaml = "yaml",
    yml = "yaml", toml = "toml",
  }
  return map[ext]
end

--- Open the native split diff view for a specific request.
--- Closes the float UI.
--- @param req AutoAgentsDiffRequest
local function open_native_diff(req)
  if _mfloat then
    _mfloat:close()
    _mfloat = nil
  end

  -- Finding 2: Resolve a safe editor window instead of using the current window
  -- (which might be the auto-agents panel).
  local floor = require("auto-agents.integrations.editor_floor")
  local target_win = floor.find_editor_window() or floor.materialize_editor_scratch()

  vim.api.nvim_win_call(target_win, function()
    -- Load the original file
    local old_path = req.file_path
    local old_exists = vim.fn.filereadable(old_path) == 1
    
    vim.cmd("edit " .. vim.fn.fnameescape(old_path))
    
    if not old_exists then
      -- It's a new file, make sure the buffer is empty
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    end
    
    local old_win = vim.api.nvim_get_current_win()
    local old_buf = vim.api.nvim_get_current_buf()
    
    vim.cmd("diffthis")
    
    -- Create the proposed buffer
    vim.cmd("vnew")
    local new_win = vim.api.nvim_get_current_win()
    local new_buf = vim.api.nvim_create_buf(false, true)
    
    -- Name the proposed buffer so it's clear
    local new_name = req.agent_name .. " proposed: " .. vim.fn.fnamemodify(old_path, ":t")
    vim.api.nvim_buf_set_name(new_buf, new_name)
    
    -- Set contents
    local lines = vim.split(req.new_contents, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)
    
    -- Configure the new buffer for saving
    vim.bo[new_buf].buftype = "acwrite"
    vim.bo[new_buf].bufhidden = "wipe"
    vim.bo[new_buf].swapfile = false
    
    -- Copy filetype if possible
    vim.bo[new_buf].filetype = vim.bo[old_buf].filetype
    
    vim.api.nvim_win_set_buf(new_win, new_buf)
    vim.cmd("diffthis")

    -- `diffthis` sets foldmethod=diff + closes folds for every equal
    -- region. We want the full file end-to-end (the whole point of the
    -- editor-floor view vs the in-panel preview), so unfold both
    -- windows. winid is set per-window — `wo` instead of `o` matters
    -- because foldenable is window-local.
    for _, w in ipairs({ old_win, new_win }) do
      if vim.api.nvim_win_is_valid(w) then
        set_winlocal(w, "foldenable", false)
      end
    end

    -- Land the cursor on the first diff hunk in both windows so the
    -- user opens straight onto the first change instead of line 1 (or
    -- wherever viminfo left them last time the file was edited). `]c`
    -- is vim's native diff motion; from line 1 it advances to the
    -- start of the first changed region, or no-ops on identical files.
    -- pcall guards the no-op case (E387: 'No more items to find').
    for _, w in ipairs({ old_win, new_win }) do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_call(w, function()
          pcall(vim.api.nvim_win_set_cursor, w, { 1, 0 })
          pcall(vim.cmd, "normal! ]c")
        end)
      end
    end

    -- Handle Save (:w)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = new_buf,
      callback = function()
        -- Save accepted changes
        local final_lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
        local final_content = table.concat(final_lines, "\n")
        
        -- Finding 3: Also actually write the file to disk, with durable success check.
        local write_ok, write_err = pcall(function()
          local f, err = io.open(old_path, "w")
          if not f then error(err) end
          local _, werr = f:write(final_content)
          if werr then 
            f:close()
            error(werr) 
          end
          f:close()
        end)
        
        if not write_ok then
          require("auto-agents.log").error("diff.ui",
            "Error saving file: " .. tostring(write_err))
          return false
        end
        
        -- Reload the old buffer
        vim.api.nvim_buf_call(old_buf, function() vim.cmd("edit!") end)
        
        -- Notify the queue
        queue.resolve(req.id, final_content)
        
        -- Clean up the split
        pcall(vim.api.nvim_win_close, new_win, true)
        
        -- Remove diff mode from old window
        if vim.api.nvim_win_is_valid(old_win) then
          vim.api.nvim_win_call(old_win, function() vim.cmd("diffoff") end)
        end
        
        -- Re-open float if there are more pending
        if #queue.get_pending() > 0 then
          vim.schedule(M.open)
        end
        
        return true
      end,
      desc = "Save accepted agent diff",
    })
    
    -- Handle Close (:q without save)
    vim.api.nvim_create_autocmd({"BufDelete", "BufWipeout"}, {
      buffer = new_buf,
      callback = function()
        -- If it's still pending, it means it wasn't resolved by BufWriteCmd
        if queue.get(req.id) and queue.get(req.id).status == "pending" then
          queue.reject(req.id)
        end
        
        -- Clean up the old window's diff mode
        if vim.api.nvim_win_is_valid(old_win) then
          vim.api.nvim_win_call(old_win, function() vim.cmd("diffoff") end)
        end
      end,
      desc = "Reject agent diff on close",
    })
  end)
end

local function set_buf_lines(buf, lines)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
end

-- Resolve the file's containing git repo for the left-column label.
-- See `render_left` for the layout taxonomy this implements.
-- @param path string
-- @return string
local function repo_for(path)
  -- `git -C <p>` requires a directory; queue entries always carry a
  -- file path, so probe through the parent dir.
  local probe_dir = vim.fn.fnamemodify(path, ":h")
  local repo_mod_ok, repo_mod = pcall(require, "auto-core.git.repo")
  if repo_mod_ok and type(repo_mod.common_dir) == "function" then
    local cd = repo_mod.common_dir(probe_dir)
    if type(cd) == "string" and cd ~= "" then
      local base = vim.fn.fnamemodify(cd, ":t")
      if base == ".git" or base == ".bare" then
        return vim.fn.fnamemodify(cd, ":h:t")
      end
      return base
    end
  end
  -- Non-git: parent-dir basename. The earlier draft consulted
  -- `fs_path.project_root` (markers: go.mod / package.json / pyproject /
  -- etc.) before this fallback, but that introduced a non-determinism
  -- in tests: when the tmpdir happened to be a descendant of a path
  -- containing any of those markers (review-round-2 found this on
  -- agent:lector's machine where `/tmp` had `.luarc.json`), `repo_for`
  -- returned the surprising ancestor name instead of the file's own
  -- parent. The diff panel label is meant to identify *this file's
  -- locality*, not "the nearest project marker anywhere up the tree"
  -- — so skip project_root and go straight to `:h:t`.
  return vim.fn.fnamemodify(path, ":h:t")
end

-- Normalise the agent column. Treats every known "unattributed" sentinel
-- (nil / "" / "agent" / "?" / "unknown" / "unattributed") as one displayed
-- string so future regressions surface a less ambiguous failure mode.
-- The real attribution fix lives upstream (ADR 0011 §D2/D3).
-- @param name any
-- @return string
local function agent_for(name)
  if type(name) == "string"
      and name ~= ""
      and name ~= "agent"
      and name ~= "?"
      and name ~= "unknown"
      and name ~= "unattributed" then
    return name
  end
  return "unattributed"
end

-- ADR-0046 D-C: resolve the slot a request-change reason should be
-- delivered to. Returns the AUTHOR's slot, or nil when the diff is
-- unattributed / its name maps to no live slot. Callers MUST NOT fall
-- back to `focused_slot` on nil — the focused slot is a UI accident, not
-- evidence of authorship, so injecting the request there is the exact
-- wrong-TUI misrouting this ADR fixes. On nil, refuse + notify instead.
---@param agent_name string?
---@return integer? slot
local function request_change_target(agent_name)
  local ok_aa, aa = pcall(require, "auto-agents")
  if not ok_aa or type(aa.slot_for_name) ~= "function" then return nil end
  local slot = aa.slot_for_name(agent_name)
  if type(slot) == "number" and slot >= 1 then return slot end
  return nil
end

-- Declaration for mutually recursive calls
local render_left, update_preview

update_preview = function()
  if not _mfloat or not _mfloat:is_open() then return end

  local req = _render_list[_selected_idx]
  if not req then
    set_buf_lines(_mfloat:bufnr("middle"), { "No pending diffs." })
    set_buf_lines(_mfloat:bufnr("preview"), { "No pending diffs." })
    -- Clear the winbar when nothing is selected so we don't leave a
    -- stale path from a previous selection on screen.
    for _, p in ipairs({ "middle", "preview" }) do
      local w = _mfloat:winid(p)
      if w and vim.api.nvim_win_is_valid(w) then
        pcall(set_winlocal, w, "winbar", "")
      end
    end
    return
  end

  local middle_buf = _mfloat:bufnr("middle")
  local preview_buf = _mfloat:bufnr("preview")

  -- Preview content: edit cache wins, otherwise the agent's proposed
  -- new_contents. Switching selection and back restores in-progress
  -- edits exactly as the user left them.
  local preview_lines = _edits_by_id[req.id]
    or vim.split(req.new_contents, "\n", { plain = true })

  set_buf_lines(middle_buf, vim.split(req.old_contents, "\n", { plain = true }))
  set_buf_lines(preview_buf, preview_lines)

  -- Propagate filetype so syntax highlighting kicks in while reviewing
  -- AND while editing in edit mode.
  local ft = detect_filetype(req.file_path)
  if ft and ft ~= "" then
    pcall(function() vim.bo[middle_buf].filetype = ft end)
    pcall(function() vim.bo[preview_buf].filetype = ft end)
    -- Treesitter is the right tool for *viewing* — grammar-driven
    -- highlighting is more accurate than regex syntax, especially for
    -- nested languages. Most setups attach treesitter via FileType
    -- autocmds, but some skip `buftype = "nofile"` buffers (which
    -- auto-core's _scratch_buf uses for the float panes). Call
    -- vim.treesitter.start explicitly so the diff panes get grammar
    -- highlighting regardless of the user's plugin setup. pcall'd so
    -- missing parsers are a silent no-op rather than an error.
    pcall(vim.treesitter.start, middle_buf, ft)
    pcall(vim.treesitter.start, preview_buf, ft)
  end

  -- Preview pane is modifiable iff edit mode is on. set_buf_lines just
  -- finished with modifiable=false, so re-flip when needed.
  pcall(function() vim.bo[preview_buf].modifiable = _edit_mode end)

  -- Attempt to setup diff mode inside the floating windows
  local middle_win = _mfloat:winid("middle")
  local preview_win = _mfloat:winid("preview")

  if middle_win and vim.api.nvim_win_is_valid(middle_win) then
    vim.api.nvim_win_call(middle_win, function() vim.cmd("diffthis") end)
  end
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_call(preview_win, function() vim.cmd("diffthis") end)
  end

  -- v0.2.41: stamp the file path on the middle + preview panes'
  -- winbar so the user always knows which file is under review.
  -- Updates on every selection change because this whole function
  -- re-runs on `[1-9]` / `<CR>` / `Tab` cycle. Pre-v0.2.41 only
  -- the basename appeared in the left list — easy to confuse when
  -- two repos share a filename (e.g. tests/smoke.lua).
  --
  -- v0.2.44: shorten the displayed path to its portable `$VAR/...`
  -- symbolic form (`$WORKSPACE/...`, `$KB_ROOT/...`, etc.) via
  -- auto-core.todo.vars.symbolize_path (v0.1.47+). Far more
  -- legible than a deep absolute path, and consistent with how
  -- todo refs are stored. pcall-guarded so an older auto-core
  -- (no symbolize_path) just shows the raw path.
  --
  -- Truncation strategy: if still wider than the pane, trim from
  -- the LEFT so the basename + immediate parent stay visible.
  local function _display_path(path)
    local ok_v, vars = pcall(require, "auto-core.todo.vars")
    if ok_v and type(vars.symbolize_path) == "function" then
      local ok_s, sym = pcall(vars.symbolize_path, path)
      if ok_s and type(sym) == "string" and sym ~= "" then return sym end
    end
    return path
  end
  local function _path_winbar(win, path)
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    local width = vim.api.nvim_win_get_width(win)
    local label = " " .. _display_path(path)
    if #label > width then
      label = " …" .. label:sub(#label - width + 4)
    end
    pcall(set_winlocal, win, "winbar", label)
  end
  _path_winbar(middle_win,  req.file_path or "(no file_path)")
  _path_winbar(preview_win, req.file_path or "(no file_path)")
end

render_left = function()
  if not _mfloat or not _mfloat:is_open() then return end
  
  local buf = _mfloat:bufnr("left")
  if not buf then return end
  
  _render_list = queue.get_pending()
  
  if _selected_idx > #_render_list then
    _selected_idx = math.max(1, #_render_list)
  end
  
  local lines = { " Pending Diffs (" .. #_render_list .. ")", "" }
  -- Left-column format: `{repo}/{filename}  [{agent_name}]`.
  -- Repo resolution taxonomy:
  --   bare repo + linked worktree  →  basename of the dir hosting the common dir
  --     <...>/auto-agents.nvim/<branch>/lua/foo.lua
  --     common_dir = <...>/auto-agents.nvim/.git  →  "auto-agents.nvim"
  --   plain clone                  →  basename of the dir hosting the common dir
  --     <...>/kb/log.md
  --     common_dir = <...>/kb/.git  →  "kb"
  --   bare without .git/.bare subdir (common_dir IS the bare itself)
  --     <...>/auto-agents.nvim     →  "auto-agents.nvim"
  --   non-git project              →  `fs.path.project_root({start=path})` basename
  --   none of the above            →  parent dir basename (`:h:t`)
  -- See `repo_for` at file scope. Agent column normalises every
  -- "unattributed" sentinel to one displayed string (`agent_for`).
  for i, req in ipairs(_render_list) do
    local marker = (i == _selected_idx) and "▶" or " "
    local filename = vim.fn.fnamemodify(req.file_path, ":t")
    local repo = repo_for(req.file_path)
    local agent = agent_for(req.agent_name)
    lines[#lines + 1] = string.format("%s [%d] %s/%s [%s]",
      marker, i, repo, filename, agent)
  end
  
  set_buf_lines(buf, lines)
  
  -- Restore cursor
  local win = _mfloat:winid("left")
  if win and vim.api.nvim_win_is_valid(win) then
    local row = _selected_idx + 2
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  end
end

--- Toggle the diff queue float UI
function M.toggle()
  if _mfloat and _mfloat:is_open() then
    _mfloat:close()
    return
  end
  M.open()
end

--- Open the diff queue float UI
function M.open()
  if _mfloat and _mfloat:is_open() then
    _mfloat:focus("left")
    return
  end
  
  local ok, auto_core = pcall(require, "auto-core")
  if not ok or not auto_core.ui or not auto_core.ui.float.multi then
    require("auto-agents.log").error("diff.ui", "auto-core not available")
    return
  end
  
  _mfloat = auto_core.ui.float.multi.new({
    name = "auto_agents_diff_queue",
    outer = {
      title = " Agent Diff Queue ",
      width_pct = 0.9,
      height_pct = 0.9,
    },
    panes = {
      left = { width = 0.2, cursorline = true },
      middle = { title = " Current ", cursorline = true },
      preview = { width = 0.4, title = " Proposed ", cursorline = true },
      footer = { height = 1, content = " A/D/M Accept/Deny/Modify • E Edit (preview) • O Open (full file) • [1-9]/<CR> Select • Tab Cycle • hjkl in diff • q Close " }
    },
    initial_focus = "left",
    on_open = function(self)
      -- Pane cycling: bound on every pane so the user can Tab/Shift-Tab
      -- (or <C-h>/<C-l>) between the list and the diff panes. q/<Esc>
      -- to close is auto-stamped by auto-core.ui.float.multi on every
      -- pane bufnr — we don't need to re-bind that here.
      local function bind_cycle(buf)
        if not buf then return end
        local function map(lhs, fn)
          vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
        end
        map("<Tab>",   function() self:cycle("forward")  end)
        map("<S-Tab>", function() self:cycle("backward") end)
        map("<C-l>",   function() self:cycle("forward")  end)
        map("<C-h>",   function() self:cycle("backward") end)
      end

      for _, pane in ipairs({ "left", "middle", "preview" }) do
        bind_cycle(self:bufnr(pane))
      end

      -- Accept / Deny / Modify stay on every focusable pane: it's
      -- natural to review the diff in the preview pane and then hit
      -- A/D/M without having to Tab back to the list first. The
      -- middle/preview buffers are non-modifiable, so A (append),
      -- D (delete-to-EOL), M (move-to-middle) don't have meaningful
      -- native semantics to clash with — same precedent as
      -- worktree.graph mapping D on every pane.
      local function bind_actions(buf)
        if not buf then return end
        local function map(lhs, fn)
          vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
        end
        map("A", function()
          local req = _render_list[_selected_idx]
          if not req then return end
          -- If the user has been editing in the preview pane, the
          -- edit cache (kept in sync by the TextChanged autocmd
          -- installed below) holds their latest content. Otherwise
          -- accept the agent's proposed new_contents verbatim.
          local edited = _edits_by_id[req.id]
          local final = edited and table.concat(edited, "\n") or req.new_contents
          queue.resolve(req.id, final)
          render_left()
          update_preview()
        end)
        map("D", function()
          local req = _render_list[_selected_idx]
          if req then
            queue.reject(req.id)
            render_left()
            update_preview()
          end
        end)
        -- M (Modify): prompt for a user message, reject the diff with
        -- that text as the reason, AND inject the same reason as a
        -- follow-up prompt into the agent's terminal so the agent
        -- actually iterates on the feedback. Two channels:
        --   1. queue.reject(id, reason) → openDiff returns
        --      DIFF_REJECTED + reason. (Claude Code's CLI currently
        --      drops content[2] from this reply and surfaces only a
        --      generic "user rejected" message to the agent, so on
        --      its own this channel doesn't get the reason through.)
        --   2. send_slot(slot, "REQUEST CHANGE: <reason>", { submit
        --      = true }) → types the reason into the agent's TUI as
        --      a normal user prompt, then a deferred CR submits it.
        --      This is the channel that actually conveys the reason
        --      today; channel 1 will start working when Claude Code
        --      forwards content[2].
        -- Slot resolution (ADR-0046 D-C): route to the diff's ATTRIBUTED
        -- author via request_change_target(req.agent_name). If the diff is
        -- unattributed (the name maps to no live slot), REFUSE + notify
        -- rather than fall back to the focused slot — the focused slot is a
        -- UI accident, not evidence of authorship, so injecting the request
        -- there is the exact wrong-TUI misroute this ADR fixes.
        -- O (Open): drop the float and open the full-file native diff
        -- view for the currently-selected entry. Bound on every pane so
        -- the user can hit O without first jumping back to the list.
        -- Cursor in the native view lands on the first changed hunk
        -- (see open_native_diff) — same target regardless of where O
        -- was pressed.
        map("O", function()
          local req = _render_list[_selected_idx]
          if req then
            open_native_diff(req)
          end
        end)
        map("M", function()
          local req = _render_list[_selected_idx]
          if not req then return end
          vim.ui.input({ prompt = "REQUEST CHANGE: " }, function(input)
            if not input or input == "" then return end
            queue.reject(req.id, input)
            render_left()
            update_preview()
            -- Schedule the terminal injection so the openDiff
            -- response has time to land + Claude's TUI returns to the
            -- input prompt before we type into it. 150ms is plenty
            -- for a local MCP round-trip + Claude's TUI redraw.
            vim.defer_fn(function()
              local slot = request_change_target(req.agent_name)
              if not slot then
                -- ADR-0046 D-C: unattributed diff → do NOT inject into
                -- focused_slot (wrong-TUI misroute). Refuse + notify.
                vim.notify(
                  "auto-agents: diff is unattributed ("
                    .. tostring(req.agent_name)
                    .. ") — can't route the change request to an author. "
                    .. "Open the author's TUI and paste it manually.",
                  vim.log.levels.WARN)
                return
              end
              local ok_aa, aa = pcall(require, "auto-agents")
              if ok_aa then
                aa.send_slot(slot, "REQUEST CHANGE: " .. input, { submit = true })
              end
            end, 150)
          end)
        end)
      end

      for _, pane in ipairs({ "left", "middle", "preview" }) do
        bind_actions(self:bufnr(pane))
      end

      -- E (Edit) is preview-only — the right pane is the only place
      -- the user would edit. Uppercase to avoid shadowing the native
      -- `e` word-motion in the diff panes. Toggles modifiable on the
      -- preview buffer, focuses it, and enters insert mode on first
      -- entry. Subsequent E presses leave the buffer's content as-is
      -- (kept in _edits_by_id) and flip modifiable=false again so
      -- accidental keystrokes in view mode don't change the buffer.
      local preview_buf = self:bufnr("preview")
      if preview_buf then
        vim.keymap.set("n", "E", function()
          _edit_mode = not _edit_mode
          pcall(function() vim.bo[preview_buf].modifiable = _edit_mode end)
          if _edit_mode then
            self:focus("preview")
            pcall(vim.cmd, "startinsert")
            require("auto-agents.log").notify(
              "Edit mode — press A to save your edits, E to exit",
              { component = "diff.ui", title = "auto-agents diff" })
          else
            require("auto-agents.log").notify(
              "View mode",
              { component = "diff.ui", title = "auto-agents diff" })
          end
          render_left()
        end, { buffer = preview_buf, silent = true, nowait = true,
              desc = "auto-agents.diff: toggle edit mode on preview" })

        -- TextChanged / TextChangedI on the preview buffer captures
        -- the user's edits into _edits_by_id keyed by the currently-
        -- selected entry's id. When the user switches to another entry
        -- (j/k/digit) and back, update_preview consults this cache
        -- before falling back to req.new_contents — so edits survive
        -- selection swaps until the entry is accepted (A reads from
        -- the cache), denied (D drops it), or removed by close_tab.
        _edits_autocmd_id = vim.api.nvim_create_autocmd(
          { "TextChanged", "TextChangedI" },
          {
            buffer = preview_buf,
            callback = function()
              if not _edit_mode then return end
              local req = _render_list[_selected_idx]
              if not req then return end
              local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
              _edits_by_id[req.id] = lines
            end,
            desc = "auto-agents.diff: capture preview edits into edit cache",
          }
        )
      end

      -- Selection keymaps (j/k row movement, 1-9 jump, <CR> commit
      -- cursor row) are scoped to the LEFT pane only. The middle and
      -- preview panes hold the diff content; shadowing j/k/digits
      -- there would break Vim's native motions (hjkl scrolling, 5j /
      -- 10G counts, w/b/e/f/F/t/T/$/^/0/gg/G/% — everything the user
      -- asked for). O (open full-file diff) is bound in bind_actions
      -- on every pane — the native `O` (open line above) is shadowed
      -- on the diff panes too, but those buffers are non-modifiable
      -- so the loss is theoretical.
      local left_buf = self:bufnr("left")
      if left_buf then
        local function map(lhs, fn)
          vim.keymap.set("n", lhs, fn, { buffer = left_buf, silent = true, nowait = true })
        end

        for i = 1, 9 do
          map(tostring(i), function()
            if i <= #_render_list then
              _selected_idx = i
              render_left()
              update_preview()
            end
          end)
        end

        -- <CR>: commit whichever row the cursor is currently on to the
        -- middle/preview panes. Redundant when the user got here via
        -- j/k (those already auto-refresh), but the only way to pick
        -- entries beyond #9 without iterating — `1..9` cap out before
        -- big queues, and the cursor can land on row 10+ via G / arrow
        -- keys / mouse. Header takes the first two lines, so entry i
        -- sits on cursor line i + 2.
        map("<CR>", function()
          local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
          local idx = cursor_line - 2
          if idx >= 1 and idx <= #_render_list then
            _selected_idx = idx
            render_left()
            update_preview()
          end
        end)

        map("j", function()
          if _selected_idx < #_render_list then
            _selected_idx = _selected_idx + 1
            render_left()
            update_preview()
          end
        end)
        map("k", function()
          if _selected_idx > 1 then
            _selected_idx = _selected_idx - 1
            render_left()
            update_preview()
          end
        end)
      end

      -- Line numbers on the diff panes so the user can correlate
      -- positions with the on-disk file. cursorline is already set
      -- via the pane config; number is set here because auto-core's
      -- multi-float doesn't expose it as a first-class pane option
      -- yet (the option set is cursorline / wrap / winhighlight).
      for _, pane in ipairs({ "middle", "preview" }) do
        local win = self:winid(pane)
        if win and vim.api.nvim_win_is_valid(win) then
          set_winlocal(win, "number", true)
        end
      end
    end,
    on_close = function()
      _mfloat = nil
      -- Reset edit-mode flag so the next open starts in view mode.
      _edit_mode = false
      -- Drop the TextChanged autocmd that was syncing preview edits
      -- into _edits_by_id; the preview buffer is about to be wiped.
      -- Edits themselves stay in _edits_by_id across opens — if the
      -- entry is still pending when the panel reopens, the user
      -- resumes exactly where they left off.
      if _edits_autocmd_id then
        pcall(vim.api.nvim_del_autocmd, _edits_autocmd_id)
        _edits_autocmd_id = nil
      end
      -- Release the auto-close + refresh subscriptions registered in
      -- M.open(). Doing this on close (rather than at module unload,
      -- which never happens in practice) means panels stop receiving
      -- events the instant they're dismissed — no leaked subscribers
      -- when the user toggles the panel repeatedly.
      local ok_ev, events = pcall(require, "auto-core.events")
      if ok_ev and events.unsubscribe then
        if _event_handles.refresh   then events.unsubscribe(_event_handles.refresh)   end
        if _event_handles.autoclose then events.unsubscribe(_event_handles.autoclose) end
        _event_handles.refresh   = nil
        _event_handles.autoclose = nil
      end
    end,
  })
  
  _mfloat:open()

  -- Register the refresh + auto-close subscriptions for THIS panel
  -- instance. Re-subscribing on every open means the contract is
  -- robust against `events._reset_for_tests`, `:Lazy reload`, or any
  -- other mid-session bus reset that would otherwise leave us with a
  -- panel that refuses to close after the user drains the queue via
  -- A/D. The handles are released in on_close above.
  local ok_ev2, events2 = pcall(require, "auto-core.events")
  if ok_ev2 and events2.subscribe then
    -- Defensive: clear any previous handles in case open() is called
    -- twice without a close in between (the early-return at the top
    -- of M.open should prevent this, but the cost of being safe is
    -- two nil-checks).
    if _event_handles.refresh   then pcall(events2.unsubscribe, _event_handles.refresh)   end
    if _event_handles.autoclose then pcall(events2.unsubscribe, _event_handles.autoclose) end

    _event_handles.refresh = events2.subscribe(
      "auto-agents:diff_queued",
      function()
        vim.schedule(function()
          if _mfloat and _mfloat:is_open() then
            render_left()
            update_preview()
          end
        end)
      end
    )

    -- Auto-close the panel when the queue drains. Listening on
    -- diff_removed (rather than wiring this into A/D handlers) means
    -- every removal path triggers it: panel A/D, the native split's
    -- save/close autocmds, and the close_tab MCP call from the agent
    -- side. If a new diff arrives moments later the openDiff handler's
    -- vim.schedule M.open() reopens us, so there's no race.
    _event_handles.autoclose = events2.subscribe(
      "auto-agents:diff_removed",
      function(payload)
        -- Drop any in-progress edits for the removed entry — once
        -- it's accepted (A reads the edits, then resolves), denied
        -- (D), or closed via close_tab, the edits no longer have
        -- a target.
        if payload and payload.id then
          _edits_by_id[payload.id] = nil
        end
        vim.schedule(function()
          if _mfloat and _mfloat:is_open()
              and #queue.get_pending() == 0
          then
            _mfloat:close()
          end
        end)
      end
    )
  end

  render_left()
  update_preview()
end

--- Whether the diff queue panel is currently displayed. Public so other
--- modules — notably the `close_tab` MCP tool — can treat the panel as
--- the authoritative source of resolution for pending queue entries
--- while it's up. See the cascade-drain fix note in `close_tab.lua`.
--- @return boolean
function M.is_open()
  return _mfloat ~= nil and _mfloat:is_open()
end

--- Test helper: expose the live multi-float instance so headless specs
--- can introspect pane winid/bufnr and assert window options + keymaps.
--- Not part of the public contract.
--- @return AutoCoreMultiFloat?
function M._test_get_mfloat()
  return _mfloat
end

--- Test helpers: expose the pure label-resolution functions so the panel
--- regression specs can drive them on synthetic file paths without
--- standing up the float UI. Not part of the public contract.
M._test_repo_for  = repo_for
M._test_agent_for = agent_for
M._test_request_change_target = request_change_target

-- Subscriptions to `auto-agents:diff_queued` and `:diff_removed`
-- are intentionally registered INSIDE `M.open()` (not at module
-- load) so the auto-close contract survives a mid-session events
-- bus reset. See the `_event_handles` doc-comment near the top of
-- the file + the `on_close` callback for the lifecycle.

return M
