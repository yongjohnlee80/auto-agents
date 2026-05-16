---Editor-window-floor invariant for the AutoVim three-column layout.
---
---AutoVim runs `AutoFinder | Editor | AutoAgents`. When the user issues
---`:q` on the last editor window, both side panels (winfixwidth) stretch
---to fill the freed columns and the layout becomes unusable — claudecode
---diff requests can't find a target editor window and either fail with
---E1513 (winfixbuf on auto-finder) or manufacture a split inside the
---auto-agents panel column.
---
---This module enforces "an editor window must exist whenever the
---auto-agents panel is open." Two enforcement points:
---
---  1. `WinClosed` handler — after a window closes, if only panels
---     remain, materialize a scratch buffer in a new vsplit between the
---     panels (default behavior,
---     `cfg.layout.editor_window_strategy = "create_scratch"`).
---     Configurable to `"warn"` (log only) or `"off"` (no enforcement).
---
---  2. Diff-route gate — when claudecode opens a diff buffer (BufWinEnter
---     with `b:claudecode_diff_tab_name`), check if any editor window
---     existed outside the diff itself. If not AND
---     `cfg.diff.editor_floor_strategy = "warn"` (default), close the
---     freshly-opened diff and log a warning. The user wanted
---     "log warning rather than opening a new one" — we close after
---     the fact because claudecode opens the diff before we see it.
---
---NB: do not confuse `cfg.layout.editor_window_strategy` with
---`cfg.panel.editor_floor` — the latter is a pre-existing column-count
---guard ("minimum columns reserved for the editor side before the
---panel may open"), not a layout invariant.
---
---SoC note: this module enforces the invariant. It does NOT decide what
---a panel is — that's the panels' own job, identified via window-local
---markers (`w:auto_agents_panel`, `w:auto_finder_panel`) plus filetype
---fallbacks for older versions or third-party panels.
---@module 'auto-agents.integrations.editor_floor'

local M = {}

---Filetypes we treat as panels for the purposes of the editor-floor
---check. Window-local markers are the primary signal; this set is the
---fallback for older panel versions or third-party plugins. Keep small
---— the marker route should cover our own panels.
local PANEL_FILETYPES = {
  ["auto-finder"] = true,
  ["auto-finder-config"] = true,
  ["auto-agents-admin"] = true,
}

---Predicate: is `winid` a regular editor window?
---Returns false for floats, our own panels (by marker), known panel
---filetypes, terminal/prompt buftypes, and invalid windows.
---@param winid integer
---@return boolean
function M.is_editor_window(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return false end
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative and cfg.relative ~= "" then return false end

  local ok_aa, aa_marker = pcall(vim.api.nvim_win_get_var, winid, "auto_agents_panel")
  if ok_aa and aa_marker == 1 then return false end
  local ok_af, af_marker = pcall(vim.api.nvim_win_get_var, winid, "auto_finder_panel")
  if ok_af and af_marker == 1 then return false end

  local buf = vim.api.nvim_win_get_buf(winid)
  if not vim.api.nvim_buf_is_valid(buf) then return false end

  local ft = vim.bo[buf].filetype
  if PANEL_FILETYPES[ft] then return false end

  local bt = vim.bo[buf].buftype
  if bt == "terminal" or bt == "prompt" then return false end

  return true
end

---Find any editor window in the current tab, or nil if none.
---@return integer|nil
function M.find_editor_window()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_editor_window(w) then return w end
  end
  return nil
end

---Count editor windows in the current tab.
---@return integer
function M.count_editor_windows()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_editor_window(w) then n = n + 1 end
  end
  return n
end

---Materialize a scratch buffer in a new vsplit between the panels.
---Strategy: focus the auto-agents panel, then `leftabove vnew` opens a
---new vsplit immediately to its left. The new window inherits no
---panel-class options.
---
---Returns the new winid, or nil if the panel isn't open (we fall back
---to a plain `vsplit` from wherever we are).
---@return integer|nil
function M.materialize_editor_scratch()
  local aa = require("auto-agents")
  local panel = aa.state and aa.state.panel_winid
  local prev_win = vim.api.nvim_get_current_win()

  -- Suppress autocmds during the split. `:leftabove vnew` from inside a
  -- panel briefly displays the panel's buffer in the new sibling before
  -- `:enew` swaps in a fresh one. Auto-core's panel-buffer leak guard
  -- (BufWinEnter/WinEnter) sees that transient panel buffer in a
  -- non-panel window and bounces the new window — leaving the fresh
  -- buffer dropped back into the panel itself. Disabling autocmds for
  -- the split keeps the guard out of the inner stages of the command.
  local saved_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"

  if panel and vim.api.nvim_win_is_valid(panel) then
    pcall(vim.api.nvim_set_current_win, panel)
    local ok = pcall(vim.cmd, "leftabove vnew")
    if not ok then
      vim.o.eventignore = saved_eventignore
      pcall(vim.api.nvim_set_current_win, prev_win)
      return nil
    end
  else
    -- No panel anchor; just split where we are.
    local ok = pcall(vim.cmd, "vnew")
    if not ok then
      vim.o.eventignore = saved_eventignore
      return nil
    end
  end

  vim.o.eventignore = saved_eventignore

  local winid = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_set_option_value, "winfixwidth", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { win = winid })

  -- Re-clamp the AutoAgents panel back to its configured width.
  -- Issue: after `:q` on the last editor window, both side panels
  -- (winfixwidth) absorb the freed columns despite winfixwidth — that
  -- option only blocks `:wincmd =` style equalize, not the natural
  -- redistribution that follows a window close. Our `leftabove vnew`
  -- created the scratch from the panel's current (oversized) width, so
  -- the panel is still wider than the user configured.
  --
  -- Calling refresh_panel_width re-issues nvim_win_set_width on the
  -- panel, sized from cfg.panel.width_override / percentage. The
  -- scratch and any auto-finder panel absorb whatever's left.
  if type(aa.refresh_panel_width) == "function" then
    pcall(aa.refresh_panel_width)
  end

  return winid
end

---WinClosed handler: after a window closes, defer one tick and check
---whether the layout invariant still holds. Acts per `strategy`:
---  - "create_scratch" → materialize a new scratch
---  - "warn"           → log a warning, no recovery
---  - "off"            → no-op
---@param strategy string
local function on_window_closed(strategy)
  vim.schedule(function()
    local aa = require("auto-agents")
    -- Only intervene when the auto-agents panel is currently open.
    -- Without the panel there's no layout invariant to defend.
    if not (aa.state and aa.state.panel_winid
        and vim.api.nvim_win_is_valid(aa.state.panel_winid)) then
      return
    end
    if M.find_editor_window() then return end

    local logger = require("auto-agents.log")
    if strategy == "create_scratch" then
      logger.info("editor-floor",
        "no editor window remains after :q; materializing scratch to preserve layout")
      M.materialize_editor_scratch()
    elseif strategy == "warn" then
      logger.warn("editor-floor",
        "no editor window remains after :q; layout may not be usable until you open a file")
    end
  end)
end

---BufWinEnter handler for claudecode diff buffers. If the diff was
---manufactured (i.e. no editor window existed outside the diff), close
---it and log a warning per `strategy`.
---
---"Manufactured" detection: at this point, the diff window IS an editor
---window per our predicate (buftype is set later by claudecode but the
---window itself is non-floating, non-panel). The signal is "before the
---diff opened, was there at least one OTHER non-panel non-float
---window?"  We can't know that retroactively, so we use a proxy: count
---editor windows that don't carry the `b:claudecode_diff_tab_name`
---marker. If zero, the diff stands alone and was manufactured.
---@param args table  -- nvim autocmd callback args
---@param strategy string
local function on_diff_buf_win_enter(args, strategy)
  if strategy == "off" then return end
  if not args.buf or not vim.api.nvim_buf_is_valid(args.buf) then return end
  if not vim.b[args.buf].claudecode_diff_tab_name then return end

  -- Defer one tick so claudecode finishes both halves of the diff
  -- (left = original file, right = proposed). Then count.
  vim.schedule(function()
    local non_diff_editor_count = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if M.is_editor_window(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if not vim.b[b].claudecode_diff_tab_name then
          non_diff_editor_count = non_diff_editor_count + 1
        end
      end
    end
    if non_diff_editor_count > 0 then return end

    local logger = require("auto-agents.log")
    if strategy == "warn" then
      -- Close every claudecode-marked diff buffer in the current tab
      -- and log. The user wanted "log warning rather than opening a
      -- new one" — we honor the intent by tearing down the
      -- manufactured diff.
      local closed = 0
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_is_valid(w) then
          local b = vim.api.nvim_win_get_buf(w)
          if vim.api.nvim_buf_is_valid(b) and vim.b[b].claudecode_diff_tab_name then
            pcall(vim.api.nvim_win_close, w, true)
            closed = closed + 1
          end
        end
      end
      logger.warn("editor-floor",
        ("no editor window exists; diff request refused (closed %d manufactured diff window%s). "
          .. "Open a buffer first, then re-trigger the diff.")
          :format(closed, closed == 1 and "" or "s"))
    end
  end)
end

---Patch `claudecode.diff.open_diff_blocking` so its internal
---`find_main_editor_window` skips auto-finder + auto-agents panels.
---
---Why: claudecode's hard-coded skip list covers neo-tree, NvimTree,
---oil, minifiles, etc. but not `auto-finder` / `auto-finder-config` /
---`auto-agents-admin`. In the AutoVim 3-column layout, claudecode's
---window iterator sees auto-finder's panel first (creation order) and
---picks it as `target_window`. Then it tries to `:edit` the diff
---target there, hits E1513 from `winfixbuf`, and falls back to
---`create_split` — manufacturing a new column inside the panel band.
---That's the screenshot the user reported.
---
---Mechanism: `find_main_editor_window` is module-local in claudecode/
---diff.lua (not exposed on M). We replace the upvalue via
---debug.setupvalue with our own finder, which reuses
---`editor_floor.find_editor_window` (already filters our panels via
---window-local marker + filetype + buftype).
---
---The actual call site is in `M._setup_blocking_diff` (line 1187 of
---claudecode/diff.lua at this writing), NOT `M.open_diff_blocking`
---(which is a thin wrapper around _setup_blocking_diff). Lua's upvalue
---scope is per-function, so we have to patch the function that
---directly references the upvalue. _setup_blocking_diff is
---`M.`-exposed which makes the patch possible.
---
---There's a second call site at `M._open_native_diff` (line 660) that
---we deliberately don't patch — it's the non-MCP fallback path used
---when claudecode is invoked directly without an agent. Patching only
---the MCP path keeps the surface minimal.
---
---Idempotent. Safe when claudecode isn't installed.
local function patch_claudecode_diff()
  local ok, diff = pcall(require, "claudecode.diff")
  if not ok or type(diff) ~= "table" then return end
  if diff._auto_agents_target_window_patched then return end

  local our_finder = function()
    return M.find_editor_window()
  end

  -- Try every M.-exposed function that might hold the upvalue. The
  -- canonical site is M._setup_blocking_diff but we list both the
  -- blocking and native paths so an upstream rename doesn't break us
  -- silently.
  local patch_targets = { "_setup_blocking_diff", "open_diff_blocking", "_open_native_diff", "open_diff" }
  local patched_any = false

  for _, fname in ipairs(patch_targets) do
    local fn = diff[fname]
    if type(fn) == "function" then
      local i = 1
      while true do
        local name, _value = debug.getupvalue(fn, i)
        if not name then break end
        if name == "find_main_editor_window" then
          debug.setupvalue(fn, i, our_finder)
          patched_any = true
          require("auto-agents.log").debug("editor-floor",
            "patched claudecode.diff." .. fname .. "#find_main_editor_window")
          break
        end
        i = i + 1
      end
    end
  end

  if patched_any then
    diff._auto_agents_target_window_patched = true
  else
    require("auto-agents.log").warn("editor-floor",
      "could not find `find_main_editor_window` upvalue on any of "
        .. table.concat(patch_targets, ", ")
        .. " — claudecode upstream may have changed; diff target-window patch skipped")
  end
end

---Install the editor-floor autocmds. Idempotent — re-call clears the
---augroup and re-registers.
---@param cfg AutoAgentsConfig
function M.install(cfg)
  local layout_strategy = ((cfg.layout or {}).editor_window_strategy) or "create_scratch"
  local diff_strategy = ((cfg.diff or {}).editor_floor_strategy) or "warn"

  -- Patch claudecode.diff at install time so the MCP openDiff path
  -- skips our panels. Idempotent + best-effort (silent if claudecode
  -- isn't installed).
  pcall(patch_claudecode_diff)

  local group = vim.api.nvim_create_augroup("AutoAgentsEditorFloor", { clear = true })

  if layout_strategy ~= "off" then
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      callback = function()
        on_window_closed(layout_strategy)
      end,
    })
  end

  if diff_strategy ~= "off" then
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      callback = function(args)
        on_diff_buf_win_enter(args, diff_strategy)
      end,
    })
  end
end

return M
