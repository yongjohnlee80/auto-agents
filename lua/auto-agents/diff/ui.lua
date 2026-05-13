--- auto-agents.diff.ui — Multi-pane float UI for reviewing queued diffs
---
--- @module 'auto-agents.diff.ui'

local M = {}

local queue = require("auto-agents.diff.queue")

--- @type AutoCoreMultiFloat?
local _mfloat = nil

--- @type integer|string|nil
local _event_handle = nil

--- @type AutoAgentsDiffRequest[]
local _render_list = {}
local _selected_idx = 1

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
          vim.notify("Error saving file: " .. tostring(write_err), vim.log.levels.ERROR)
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

-- Declaration for mutually recursive calls
local render_left, update_preview

update_preview = function()
  if not _mfloat or not _mfloat:is_open() then return end
  
  local req = _render_list[_selected_idx]
  if not req then
    set_buf_lines(_mfloat:bufnr("middle"), { "No pending diffs." })
    set_buf_lines(_mfloat:bufnr("preview"), { "No pending diffs." })
    return
  end
  
  local middle_buf = _mfloat:bufnr("middle")
  local preview_buf = _mfloat:bufnr("preview")
  
  set_buf_lines(middle_buf, vim.split(req.old_contents, "\n", { plain = true }))
  set_buf_lines(preview_buf, vim.split(req.new_contents, "\n", { plain = true }))
  
  -- Attempt to setup diff mode inside the floating windows
  local middle_win = _mfloat:winid("middle")
  local preview_win = _mfloat:winid("preview")
  
  if middle_win and vim.api.nvim_win_is_valid(middle_win) then
    vim.api.nvim_win_call(middle_win, function() vim.cmd("diffthis") end)
  end
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_call(preview_win, function() vim.cmd("diffthis") end)
  end
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
  for i, req in ipairs(_render_list) do
    local marker = (i == _selected_idx) and "▶" or " "
    local filename = vim.fn.fnamemodify(req.file_path, ":t")
    -- Requirement: [N] {title} selection format
    lines[#lines + 1] = string.format("%s [%d] %s [%s]", marker, i, filename, req.agent_name)
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
    vim.notify("auto-core not available", vim.log.levels.ERROR)
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
      footer = { height = 1, content = " A/D/M Accept/Deny/Modify • [1-9] Select • Tab Cycle • hjkl in diff • q Close " }
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
          if req then
            queue.resolve(req.id, req.new_contents)
            render_left()
            update_preview()
          end
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
        -- Slot resolution prefers the queue entry's agent_name (when
        -- the MCP bridge injects _auto_agents_name) and falls back to
        -- the focused slot otherwise — single-agent setups always
        -- have one focused slot and the user is reviewing its diff.
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
              local ok_aa, aa = pcall(require, "auto-agents")
              if not ok_aa then return end
              local slot = aa.slot_for_name and aa.slot_for_name(req.agent_name)
              if not slot and aa.state then slot = aa.state.focused_slot end
              if not slot or slot < 1 then return end
              aa.send_slot(slot, "REQUEST CHANGE: " .. input, { submit = true })
            end, 150)
          end)
        end)
      end

      for _, pane in ipairs({ "left", "middle", "preview" }) do
        bind_actions(self:bufnr(pane))
      end

      -- Selection keymaps (j/k row movement, 1-9 jump, <CR> open) are
      -- scoped to the LEFT pane only. The middle and preview panes
      -- hold the diff content; shadowing j/k/digits there would break
      -- Vim's native motions (hjkl scrolling, 5j / 10G counts,
      -- w/b/e/f/F/t/T/$/^/0/gg/G/% — everything the user asked for).
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

        map("<CR>", function()
          local req = _render_list[_selected_idx]
          if req then
            open_native_diff(req)
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
          vim.wo[win].number = true
        end
      end
    end,
    on_close = function()
      _mfloat = nil
      -- Finding 5: unsubscribe from events on close
      local ok_ev, events = pcall(require, "auto-core.events")
      if ok_ev and events.unsubscribe and _event_handle then
        events.unsubscribe(_event_handle)
        _event_handle = nil
      end
    end,
  })
  
  _mfloat:open()
  
  render_left()
  update_preview()
end

--- Test helper: expose the live multi-float instance so headless specs
--- can introspect pane winid/bufnr and assert window options + keymaps.
--- Not part of the public contract.
--- @return AutoCoreMultiFloat?
function M._test_get_mfloat()
  return _mfloat
end

--- Subscribe to diff events (auto-refresh + auto-close)
local ok_ev, events = pcall(require, "auto-core.events")
if ok_ev and events.subscribe then
  events.subscribe("auto-agents:diff_queued", function()
    vim.schedule(function()
      if _mfloat and _mfloat:is_open() then
        render_left()
        update_preview()
      end
    end)
  end, { id = "auto_agents_diff_ui_refresh" })

  -- Auto-close the panel when the queue drains. Listening on diff_removed
  -- (rather than wiring this into the A/D handlers) means every removal
  -- path triggers it: panel A/D, the native split's save/close
  -- autocmds, and the close_tab MCP call from the agent side. If a new
  -- diff arrives moments later the openDiff handler's vim.schedule
  -- M.open() reopens us, so there's no race.
  events.subscribe("auto-agents:diff_removed", function()
    vim.schedule(function()
      if _mfloat and _mfloat:is_open() and #queue.get_pending() == 0 then
        _mfloat:close()
      end
    end)
  end, { id = "auto_agents_diff_ui_autoclose" })
end

return M
