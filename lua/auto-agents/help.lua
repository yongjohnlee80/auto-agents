---Markdown-backed help system (M6).
---
---Each top-level verb has a `docs/help/<verb>.md` shipped with the
---plugin. The file uses `## <subverb>` section headers; we extract a
---single section when the user asks for `<verb> <sub> help`, or emit
---the whole file for `<verb> help`.
---
---Files are real markdown — `help open <verb> [<sub>]` opens them in
---the editor for browsing or hand-editing. Edits persist (we never
---rewrite these files programmatically).
---
---@module 'auto-agents.help'

local M = {}

---Resolve the docs/help directory shipped with the plugin.
---@return string
function M.docs_dir()
  local source = debug.getinfo(1, "S").source:sub(2)  -- this file's path
  -- .../lua/auto-agents/help.lua → .../docs/help/
  local plugin_root = source:gsub("/lua/auto%-agents/help%.lua$", "")
  return plugin_root .. "/docs/help"
end

---Path to the help file for a given verb (or the index).
---@param verb string|nil  -- nil → index.md
---@return string|nil path  -- nil if no file exists
function M.path_for(verb)
  local dir = M.docs_dir()
  local path = dir .. "/" .. (verb or "index") .. ".md"
  if vim.fn.filereadable(path) == 1 then return path end
  return nil
end

---@return string[]  -- list of verbs that have help files
function M.known_verbs()
  local dir = M.docs_dir()
  local out = {}
  if vim.fn.isdirectory(dir) == 0 then return out end
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if name:match("%.md$") and name ~= "index.md" then
      table.insert(out, (name:gsub("%.md$", "")))
    end
  end
  table.sort(out)
  return out
end

---Read a file into a string.
---@param path string
---@return string|nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

---Extract the section of a markdown file under `## <heading>` (case
---sensitive). Returns the text from the heading line through (but not
---including) the next `^## ` heading.
---@param content string
---@param sub string
---@return string|nil
local function extract_section(content, sub)
  -- Match a line that starts with "## <sub>" optionally followed by
  -- whitespace or end-of-line. Anchor on word boundary so "## add"
  -- doesn't accidentally match "## additional".
  local heading_pat = "## " .. vim.pesc(sub)
  local lines = vim.split(content, "\n", { plain = true })
  local start_idx
  for i, line in ipairs(lines) do
    -- accept "## sub", "## sub ", "## sub<EOL>"
    if line == "## " .. sub or line:match("^## " .. vim.pesc(sub) .. "%s*$")
      or line:match("^## " .. vim.pesc(sub) .. "%s") then
      start_idx = i
      break
    end
  end
  if not start_idx then return nil end
  local end_idx = #lines
  for i = start_idx + 1, #lines do
    if lines[i]:match("^## ") then end_idx = i - 1; break end
  end
  -- Trim trailing blank lines.
  while end_idx > start_idx and lines[end_idx] == "" do end_idx = end_idx - 1 end
  return table.concat(vim.list_slice(lines, start_idx, end_idx), "\n")
end

---Emit help to the admin panel. Resolution:
---  show(nil, nil)        → index.md
---  show(verb, nil)       → <verb>.md whole file
---  show(verb, sub)       → <verb>.md, just the `## <sub>` section
---  show(verb, sub) miss  → fall back to whole file with a note
---
---@param verb string|nil
---@param sub string|nil
---@param emit fun(lines: string[])
function M.show(verb, sub, emit)
  local path = M.path_for(verb)
  if not path then
    emit({
      "help: no docs for '" .. tostring(verb) .. "' — known verbs: "
        .. table.concat(M.known_verbs(), ", "),
    })
    return
  end
  local content = read_file(path) or ""
  if sub and sub ~= "" then
    local section = extract_section(content, sub)
    if section then
      emit(vim.split("\n" .. section .. "\n", "\n", { plain = true }))
      emit({ "(`help open " .. verb .. " " .. sub .. "` to edit this in the editor)" })
      return
    end
    -- Fall back: emit the whole file with a note.
    emit({
      "help: no '## " .. sub .. "' section in " .. verb .. ".md — showing whole file:",
    })
  end
  emit(vim.split("\n" .. content, "\n", { plain = true }))
  emit({ "(`help open " .. (verb or "index") .. "` to edit this in the editor)" })
end

---Build the help text for a (verb, sub) pair as a single string.
---Mirrors `M.show` but returns instead of emitting, so the popup
---can drop it straight into a scratch buffer.
---@param verb string|nil
---@param sub string|nil
---@return string content
---@return string|nil note  -- short status line ("no '## sub' …") if applicable
local function resolve_text(verb, sub)
  local path = M.path_for(verb)
  if not path then
    return "", "help: no docs for '" .. tostring(verb) .. "' — known: "
      .. table.concat(M.known_verbs(), ", ")
  end
  local content = read_file(path) or ""
  if sub and sub ~= "" then
    local section = extract_section(content, sub)
    if section then return section, nil end
    return content, "no '## " .. sub .. "' section in " .. verb
      .. ".md — showing whole file"
  end
  return content, nil
end

---Open a scrollable floating window with the resolved help content.
---Standard vim navigation works (j/k, <C-u>/<C-d>, gg/G, /search/).
---q, <Esc>, or <C-c> closes.
---@param verb string|nil
---@param sub string|nil
function M.popup(verb, sub)
  local content, note = resolve_text(verb, sub)
  local lines = vim.split(content, "\n", { plain = true })
  if note then
    table.insert(lines, 1, "")
    table.insert(lines, 1, "(" .. note .. ")")
  end
  -- Trailing footer hint so users know how to close.
  local hint_label = "help open " .. (verb or "index") .. (sub and (" " .. sub) or "")
  table.insert(lines, "")
  table.insert(lines, "─── q / <Esc> to close · `" .. hint_label .. "` to edit ───")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines + 2, math.max(10, vim.o.lines - 6))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local title = " help: " .. (verb or "index") .. (sub and (" — " .. sub) or "") .. " "

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    zindex = 200,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.wo[win].conceallevel = 2  -- markdown headings render cleaner
  vim.wo[win].concealcursor = "n"

  -- Cursor at top so users see the heading first.
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, silent = true, nowait = true })
  end
  -- Auto-close if the user navigates away (e.g. clicks back into admin).
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })
end

---Open the help md in a non-panel editor window (so the user can read
---or edit it). For section-anchored opens, jumps to the heading.
---@param verb string|nil
---@param sub string|nil
function M.open(verb, sub)
  local path = M.path_for(verb)
  if not path then
    require("auto-agents.log").error("help",
      "no docs for '" .. tostring(verb) .. "'")
    return
  end
  -- Find a non-panel, non-float window to host the file.
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
  if sub and sub ~= "" then
    -- Jump to the section heading.
    pcall(vim.fn.search, "^## " .. vim.fn.escape(sub, "/\\") .. "\\>", "w")
    vim.cmd("normal! zt")
  end
end

return M
