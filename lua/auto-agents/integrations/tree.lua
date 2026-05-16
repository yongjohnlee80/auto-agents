---Tree integration module — detects the active tree explorer (neo-tree,
---nvim-tree, oil.nvim, mini.files, netrw) and returns the user's
---current selection as a list of absolute paths. Used by the
---`agent attach <slot> [<paths>]` admin verb to feed file context
---into an agent without manual typing.
---
---Adapted from coder/claudecode.nvim's lua/claudecode/integrations.lua
---(MIT, 2025 Coder Technologies Inc.). The require for
---claudecode.visual_commands is replaced with an inlined
---`get_visual_range()` helper so we don't need to vendor the entire
---visual_commands module.
---@module 'auto-agents.integrations.tree'

local M = {}
local logger = require("auto-agents.log")

---Return the [start, end] line range of the current visual selection
---(or the cursor line if not in visual mode). Inlined from claudecode's
---visual_commands.lua to keep this module self-contained.
---@return integer start_line
---@return integer end_line
local function get_visual_range()
  local start_pos, end_pos = 1, 1
  pcall(function()
    local mode = vim.api.nvim_get_mode().mode
    local is_visual = mode == "v" or mode == "V" or mode == "\22"
    if is_visual then
      local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
      local anchor_pos = vim.fn.getpos("v")[2]
      if anchor_pos > 0 then
        start_pos = math.min(cursor_pos, anchor_pos)
        end_pos = math.max(cursor_pos, anchor_pos)
      else
        start_pos = cursor_pos
        end_pos = cursor_pos
      end
    else
      local mark_start = vim.fn.getpos("'<")[2]
      local mark_end = vim.fn.getpos("'>")[2]
      if mark_start > 0 and mark_end > 0 then
        start_pos = mark_start
        end_pos = mark_end
      else
        local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
        start_pos = cursor_pos
        end_pos = cursor_pos
      end
    end
  end)
  if end_pos < start_pos then start_pos, end_pos = end_pos, start_pos end
  return math.max(1, start_pos), math.max(1, end_pos)
end

---Get selected files from the current tree explorer.
---@return table|nil files List of file paths, or nil if error
---@return string|nil error Error message if operation failed
function M.get_selected_files_from_tree()
  local current_ft = vim.bo.filetype
  if current_ft == "NvimTree" then
    return M._get_nvim_tree_selection()
  elseif current_ft == "neo-tree" then
    return M._get_neotree_selection()
  elseif current_ft == "oil" then
    return M._get_oil_selection()
  elseif current_ft == "minifiles" then
    return M._get_mini_files_selection()
  elseif current_ft == "netrw" then
    return M._get_netrw_selection()
  else
    return nil, "Not in a supported tree buffer (current filetype: " .. current_ft .. ")"
  end
end

-- ── nvim-tree ───────────────────────────────────────────────────────────────

function M._get_nvim_tree_selection()
  local success, nvim_tree_api = pcall(require, "nvim-tree.api")
  if not success then return {}, "nvim-tree not available" end
  local files = {}
  local marks = nvim_tree_api.marks.list()
  if marks and #marks > 0 then
    for _, mark in ipairs(marks) do
      if mark.type == "file" and mark.absolute_path and mark.absolute_path ~= "" then
        if not string.match(mark.absolute_path, "^/[^/]*$") then
          table.insert(files, mark.absolute_path)
        end
      end
    end
    if #files > 0 then return files, nil end
  end
  local node = nvim_tree_api.tree.get_node_under_cursor()
  if node then
    if node.type == "file" and node.absolute_path and node.absolute_path ~= "" then
      if not string.match(node.absolute_path, "^/[^/]*$") then
        return { node.absolute_path }, nil
      else
        return {}, "Cannot add root-level file. Please select a file in a subdirectory."
      end
    elseif node.type == "directory" and node.absolute_path and node.absolute_path ~= "" then
      return { node.absolute_path }, nil
    end
  end
  return {}, "No file found under cursor"
end

-- ── neo-tree ────────────────────────────────────────────────────────────────

function M._get_neotree_selection()
  local success, manager = pcall(require, "neo-tree.sources.manager")
  if not success then
    logger.debug("integrations/tree", "neo-tree not available")
    return {}, "neo-tree not available"
  end

  local state = manager.get_state("filesystem")
  if not state then return {}, "neo-tree filesystem state not available" end

  local files = {}
  local mode = vim.fn.mode()
  local current_win = vim.api.nvim_get_current_win()

  if mode == "V" or mode == "v" or mode == "\22" then
    if state.winid and state.winid == current_win then
      local start_pos = vim.fn.getpos("'<")[2]
      local end_pos = vim.fn.getpos("'>")[2]
      if start_pos == 0 or end_pos == 0 then
        local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
        local anchor_pos = vim.fn.getpos("v")[2]
        if anchor_pos > 0 then
          start_pos = math.min(cursor_pos, anchor_pos)
          end_pos = math.max(cursor_pos, anchor_pos)
        else
          start_pos = cursor_pos
          end_pos = cursor_pos
        end
      end
      if end_pos < start_pos then start_pos, end_pos = end_pos, start_pos end

      for line = start_pos, end_pos do
        local node = state.tree:get_node(line)
        if node and node.type and node.type ~= "message" then
          local depth = (node.get_depth and node:get_depth()) and node:get_depth() or 0
          if (node.type == "file" or node.type == "directory") and node.path and node.path ~= "" and depth > 1 then
            table.insert(files, node.path)
          end
        end
      end
      if #files > 0 then return files, nil end
    end
  end

  if state.tree then
    local selection = nil
    if state.tree.get_selection then selection = state.tree:get_selection() end
    if (not selection or #selection == 0) and state.selected_nodes then
      selection = state.selected_nodes
    end
    if selection and #selection > 0 then
      for _, node in ipairs(selection) do
        if node.type == "file" and node.path then table.insert(files, node.path) end
      end
      if #files > 0 then return files, nil end
    end
  end

  if state.tree then
    local node = state.tree:get_node()
    if node then
      if node.type == "file" and node.path then return { node.path }, nil
      elseif node.type == "directory" and node.path then return { node.path }, nil end
    end
  end
  return {}, "No file found under cursor"
end

-- ── oil.nvim ────────────────────────────────────────────────────────────────

function M._get_oil_selection()
  local success, oil = pcall(require, "oil")
  if not success then return {}, "oil.nvim not available" end

  local bufnr = vim.api.nvim_get_current_buf()
  local files = {}
  local mode = vim.fn.mode()
  if mode == "V" or mode == "v" or mode == "\22" then
    local start_line, end_line = get_visual_range()
    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if not dir_ok or not current_dir then return {}, "Failed to get current directory" end
    for line = start_line, end_line do
      local entry_ok, entry = pcall(oil.get_entry_on_line, bufnr, line)
      if entry_ok and entry and entry.name and entry.name ~= ".." and entry.name ~= "." then
        local full_path = current_dir .. entry.name
        if entry.type == "directory" then
          full_path = full_path:match("/$") and full_path or full_path .. "/"
        end
        table.insert(files, full_path)
      end
    end
    if #files > 0 then return files, nil end
  else
    local ok, entry = pcall(oil.get_cursor_entry)
    if not ok or not entry then return {}, "Failed to get cursor entry" end
    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if not dir_ok or not current_dir then return {}, "Failed to get current directory" end
    if entry.name and entry.name ~= ".." and entry.name ~= "." then
      local full_path = current_dir .. entry.name
      if entry.type == "directory" then
        full_path = full_path:match("/$") and full_path or full_path .. "/"
      end
      return { full_path }, nil
    end
  end
  return {}, "No file found under cursor"
end

-- ── mini.files ──────────────────────────────────────────────────────────────

function M._get_mini_files_selection()
  local success, mini_files = pcall(require, "mini.files")
  if not success then return {}, "mini.files not available" end
  local bufnr = vim.api.nvim_get_current_buf()
  local entry_ok, entry = pcall(mini_files.get_fs_entry, bufnr)
  if not entry_ok or not entry then return {}, "Failed to get entry from mini.files" end
  if entry.path and entry.path ~= "" then
    local real_path = entry.path
    if real_path:match("^minifiles://") then
      real_path = real_path:gsub("^minifiles://[^/]*/", "")
    end
    if vim.fn.filereadable(real_path) == 1 or vim.fn.isdirectory(real_path) == 1 then
      return { real_path }, nil
    else
      return {}, "Invalid file or directory path: " .. real_path
    end
  end
  return {}, "No file found under cursor"
end

-- ── netrw ───────────────────────────────────────────────────────────────────

function M._get_netrw_selection()
  local has_call = (vim.fn.exists("*netrw#Call") == 1)
  local has_expose = (vim.fn.exists("*netrw#Expose") == 1)
  if not (has_call and has_expose) then return {}, "netrw not available" end

  local function resolve(word)
    if type(word) ~= "string" or word == "" or word == "." or word == ".." or word == "../" then
      return nil
    end
    local curdir = vim.b.netrw_curdir or vim.fn.getcwd()
    return vim.fn.fnamemodify(curdir .. "/" .. word, ":p")
  end

  local mf_ok, mf_result = pcall(function()
    return vim.fn.call("netrw#Expose", { "netrwmarkfilelist" })
  end)
  local marked = {}
  if mf_ok and type(mf_result) == "table" then
    for _, p in ipairs(mf_result) do
      if vim.fn.filereadable(p) == 1 or vim.fn.isdirectory(p) == 1 then
        table.insert(marked, vim.fn.fnamemodify(p, ":p"))
      end
    end
  end
  if #marked > 0 then return marked, nil end

  local path_ok, path_result = pcall(function()
    local word = vim.fn.call("netrw#Call", { "NetrwGetWord" })
    return resolve(word)
  end)
  if not path_ok or not path_result or path_result == "" then
    return {}, "Failed to get path from netrw"
  end
  if vim.fn.filereadable(path_result) == 1 or vim.fn.isdirectory(path_result) == 1 then
    return { path_result }, nil
  end
  return {}, "Invalid file or directory path: " .. path_result
end

return M
