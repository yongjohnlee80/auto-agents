---Concrete wizard specs (M6). Each function returns an
---AutoAgentsWizardSpec ready to feed `wizard.start(spec, emit)`.
---
---Edits pre-populate every field's default from the existing entry, so
---the user can see the current value next to each prompt and Enter to
---keep it. Adds use sensible defaults (kind=claude, kb_scope=shared).
---
---@module 'auto-agents.panel.wizard_specs'

local M = {}

local VALID_KINDS  = { claude = true, codex = true, gemini = true, junie = true, aider = true, goose = true, opencode = true, copilot = true, generic = true }
-- Kinds that take model + (sometimes provider/api_base) at spawn time.
-- The wizard prompts for these only when kind matches.
local MODEL_KINDS    = { aider = true, goose = true, opencode = true }
local PROVIDER_KINDS = { goose = true }
local API_BASE_KINDS = { aider = true, goose = true }
local VALID_SCOPES = { shared = true, private = true, isolated = true }

local function find_entry(slot)
  local cfg = require("auto-agents").state.config or {}
  local bs = (cfg.agents and cfg.agents.bootstrap) or {}
  for _, e in ipairs(bs) do
    if e.slot == slot then return e end
  end
  return nil
end

local function parse_int_or_nil(v)
  if v == nil or v == "" or v == "none" or v == "inherit" then return nil end
  if type(v) == "number" then return v end
  local n = tonumber(v)
  if not n or n ~= math.floor(n) then
    error("must be an integer (got '" .. tostring(v) .. "')")
  end
  return n
end

local function parse_paths(v)
  if v == nil or v == "" then return nil end
  if type(v) == "table" then return v end
  local out = {}
  for p in string.gmatch(v, "[^,]+") do
    local trimmed = p:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then table.insert(out, trimmed) end
  end
  return (#out > 0) and out or nil
end

local function parse_cmd(v)
  if v == nil or v == "" then return nil end
  if type(v) == "table" then return v end
  local out = {}
  for tok in string.gmatch(v, "%S+") do table.insert(out, tok) end
  return (#out > 0) and out or nil
end

local function blank_to_nil(v)
  if v == nil or v == "" then return nil end
  return v
end

---Build the agent.add / agent.edit wizard spec. Edit pre-fills every
---field from the existing entry so the user can Enter to keep.
---
---@param mode "add"|"edit"
---@param slot integer|nil  -- required for edit
---@return table  -- AutoAgentsWizardSpec
function M.agent(mode, slot)
  local existing = (mode == "edit" and slot) and find_entry(slot) or nil
  local default = function(field, fallback)
    if existing and existing[field] ~= nil then
      local v = existing[field]
      if type(v) == "table" then return table.concat(v, ", ") end
      return tostring(v)
    end
    return fallback
  end

  local title = (mode == "edit")
    and ("auto-agents: edit slot " .. tostring(slot or "?"))
    or  "auto-agents: new agent"

  local steps = {
    {
      field = "slot",
      prompt = "slot",
      default = (mode == "edit" and slot and tostring(slot)) or nil,
      placeholder = (mode == "edit" and slot and tostring(slot)) or "1..9",
      parse = function(v)
        local n = tonumber(v)
        if not n then error("slot must be a number") end
        return n
      end,
      validate = function(n)
        if not n or n < 1 or n > 9 then return false, "slot must be 1..9" end
        if mode == "add" and find_entry(n) then
          return false, "slot " .. n .. " is already taken (use 'agent edit " .. n .. "' instead)"
        end
        return true
      end,
    },
    {
      field = "kind",
      prompt = "kind",
      choices = { "claude", "codex", "gemini", "junie", "aider", "goose", "opencode", "copilot", "generic" },
      default = default("kind", "claude"),
      validate = function(v)
        if not VALID_KINDS[v] then
          return false, "kind must be one of claude|codex|gemini|junie|aider|goose|opencode|copilot|generic"
        end
        return true
      end,
    },
    {
      field = "name",
      prompt = "name (handle, used for KB dir + grants)",
      default = default("name", ""),
      placeholder = (existing and existing.name) or "(blank to auto-generate)",
      parse = blank_to_nil,
    },
    {
      field = "title",
      prompt = "title (shown in winbar / float title)",
      default = default("title", ""),
      placeholder = (existing and existing.title) or "(blank to inherit name)",
      parse = blank_to_nil,
    },
    {
      field = "role",
      prompt = "role (free-text prompt hint, optional)",
      default = default("role", ""),
      placeholder = (existing and existing.role) or "(blank to skip)",
      parse = blank_to_nil,
    },
    {
      field = "cwd",
      prompt = "cwd",
      default = default("cwd", ""),
      placeholder = (existing and existing.cwd) or "(blank → session project root)",
      parse = blank_to_nil,
    },
    {
      field = "cmd",
      prompt = "cmd (override binary + flags)",
      default = default("cmd", ""),
      placeholder = (existing and existing.cmd and table.concat(existing.cmd, " ")) or "(blank → adapter default)",
      parse = parse_cmd,
    },
    {
      field = "allowed_paths",
      prompt = "allowed_paths (comma-separated)",
      default = default("allowed_paths", ""),
      placeholder = "(blank to skip)",
      parse = parse_paths,
    },
    {
      field = "manager",
      prompt = "manager (slot number or 'none')",
      default = default("manager", ""),
      placeholder = (existing and existing.manager and tostring(existing.manager)) or "none",
      parse = parse_int_or_nil,
    },
    {
      field = "kb_scope",
      prompt = "kb_scope",
      choices = { "shared", "private", "isolated" },
      default = default("kb_scope", "shared"),
      validate = function(v)
        if not VALID_SCOPES[v] then
          return false, "kb_scope must be shared|private|isolated"
        end
        return true
      end,
    },
    {
      -- aider/goose/opencode take the model id at spawn (CLI flag for
      -- aider+opencode, GOOSE_MODEL env for goose). Other kinds use
      -- :AutoAgentsModel after the fact and infer api endpoints from
      -- their own auth flow, so the wizard doesn't ask them here.
      field = "model",
      prompt = "model (e.g. ollama_chat/llama3 for aider, llama3.1 for goose, ollama/llama3.1 for opencode)",
      default = default("model", ""),
      placeholder = (existing and existing.model) or "(blank → CLI default)",
      skip = function(values) return not MODEL_KINDS[values.kind] end,
      parse = blank_to_nil,
    },
    {
      -- goose-only: goose separates provider from model id (unlike aider/
      -- opencode which embed it). GOOSE_PROVIDER env var.
      field = "provider",
      prompt = "provider (ollama / anthropic / openai / openrouter / ...)",
      default = default("provider", ""),
      placeholder = (existing and existing.provider) or "(blank → goose configure default)",
      skip = function(values) return not PROVIDER_KINDS[values.kind] end,
      parse = blank_to_nil,
    },
    {
      -- aider: --api-base flag. goose: GOOSE_PROVIDER__HOST env var.
      -- opencode has no CLI surface for this — users edit opencode.json.
      field = "api_base",
      prompt = "api_base URL (e.g. http://192.168.1.10:11434 for ollama)",
      default = default("api_base", ""),
      placeholder = (existing and existing.api_base) or "(blank to skip; needed for ollama/openrouter/lm-studio)",
      skip = function(values) return not API_BASE_KINDS[values.kind] end,
      parse = blank_to_nil,
    },
    {
      field = "bottom_margin",
      prompt = "bottom_margin (integer, 'inherit' to use panel default)",
      default = default("bottom_margin", "inherit"),
      placeholder = (existing and existing.bottom_margin and tostring(existing.bottom_margin)) or "inherit",
      parse = function(v)
        if v == "inherit" or v == "" or v == nil then return nil end
        local n = tonumber(v)
        if not n or n < 0 or n ~= math.floor(n) then
          error("bottom_margin must be a non-negative integer or 'inherit'")
        end
        return n
      end,
    },
    {
      -- diff_review (claudecode.nvim bridge). When y, the agent gets
      -- CLAUDE_CODE_SSE_PORT at spawn so Claude Code CLI's openDiff
      -- tool routes to a diff split in your editor for review/edit/
      -- accept. When N, Claude Code falls back to its TUI confirm
      -- prompt — useful for sub-agents whose diffs you don't want
      -- popping at you alongside your main coding agent's.
      field = "diff_review",
      prompt = "Show diff views from this agent in your editor?",
      choices = { "y", "N" },
      default = function(values)
        if existing and existing.diff_review ~= nil then
          return existing.diff_review and "y" or "N"
        end
        return values.kind == "claude" and "y" or "N"
      end,
      skip = function(values) return values.kind ~= "claude" end,
      parse = function(v)
        if type(v) == "boolean" then return v end
        v = (v or ""):lower()
        return v == "y" or v == "yes" or v == "true"
      end,
    },
  }

  -- Add-only: KB type picker. Picks one of the built-in types,
  -- supplies a custom seed path, or skips KB init.
  if mode == "add" then
    local kb_types = require("auto-agents.kb.types")
    local choices = vim.list_extend(vim.list_slice(kb_types.BUILTIN, 1, #kb_types.BUILTIN),
      { "custom", "none" })
    table.insert(steps, {
      field = "_kb_type",
      prompt = "KB type",
      choices = choices,
      default = "coding",  -- nvim users skew coding, so it's the sensible default
      validate = function(v)
        for _, c in ipairs(choices) do if c == v then return true end end
        return false, "must be one of " .. table.concat(choices, "|")
      end,
    })
    table.insert(steps, {
      field = "_kb_seed_path",
      prompt = "path to your custom seed .md",
      placeholder = "(absolute or ~/relative)",
      skip = function(values) return values._kb_type ~= "custom" end,
      parse = function(v)
        if v == nil or v == "" then return nil end
        local expanded = vim.fn.expand(v)
        if vim.fn.filereadable(expanded) ~= 1 then
          error("seed file not found: " .. expanded)
        end
        return expanded
      end,
      validate = function(v)
        if v == nil or v == "" then
          return false, "custom seed requires a readable .md file"
        end
        return true
      end,
    })
  end

  return {
    name = "agent." .. mode,
    banner = title,
    steps = steps,
    on_complete = function(values, emit)
      local entry = {
        slot = values.slot,
        kind = values.kind or "generic",
        name = values.name,
        title = values.title,
        role = values.role,
        cwd = values.cwd,
        cmd = values.cmd,
        allowed_paths = values.allowed_paths,
        manager = values.manager,
        kb_scope = values.kb_scope or "shared",
        bottom_margin = values.bottom_margin,
        diff_review = values.diff_review == true or nil,  -- omit when false to keep TOML clean
        -- Per-kind connection settings. The wizard only prompts when
        -- relevant (MODEL_KINDS / PROVIDER_KINDS / API_BASE_KINDS); other
        -- kinds get nil here. Below, we preserve `model` from the
        -- existing entry on edit so :AutoAgentsModel state survives an
        -- agent edit on non-MODEL_KINDS slots.
        model = values.model,
        provider = values.provider,
        api_base = values.api_base,
      }
      if not MODEL_KINDS[values.kind] and existing and existing.model then
        entry.model = existing.model
      end
      -- Preserve any tasks list from the existing entry on edit.
      if existing and existing.tasks then entry.tasks = existing.tasks end

      local cfg = require("auto-agents").state.config
      cfg.agents = cfg.agents or {}
      cfg.agents.bootstrap = cfg.agents.bootstrap or {}
      -- Replace any existing entry at this slot.
      for i = #cfg.agents.bootstrap, 1, -1 do
        if cfg.agents.bootstrap[i].slot == entry.slot then
          table.remove(cfg.agents.bootstrap, i)
        end
      end
      table.insert(cfg.agents.bootstrap, entry)

      -- KB init (add-only). Persist type/seed in cfg.kb so save_current
      -- writes them into [kb] alongside any [kb].root override.
      local kb_init_msg
      if mode == "add" and values._kb_type and values._kb_type ~= "none" then
        local cfg2 = require("auto-agents").state.config
        cfg2.kb = cfg2.kb or {}
        cfg2.kb.type = values._kb_type
        if values._kb_type == "custom" then
          cfg2.kb.seed_path = values._kb_seed_path
        else
          cfg2.kb.seed_path = nil  -- clear stale custom seed reference
        end
        local kb = require("auto-agents.kb")
        local root = kb.root()
        kb.ensure_layout(root, {
          type = values._kb_type,
          seed_path = values._kb_seed_path,
        })
        kb_init_msg = "  KB (" .. values._kb_type .. ") ensured at " .. root
      end

      local ok, path = require("auto-agents.config.store").save_current()
      pcall(function() require("auto-agents").refresh_keymaps() end)

      local lines = { "", "✓ Slot " .. entry.slot .. " " .. (mode == "edit" and "updated" or "added")
        .. " (" .. entry.kind .. (entry.name and ("/" .. entry.name) or "") .. ")" }
      if ok then table.insert(lines, "  saved → " .. path) end
      if kb_init_msg then table.insert(lines, kb_init_msg) end

      table.insert(lines, "")
      emit(lines)
      vim.schedule(function() require("auto-agents").focus_slot(entry.slot) end)
    end,
  }
end

---kb.new — create + open a KB file via wizard.
---@return table
function M.kb_new()
  return {
    name = "kb.new",
    banner = "auto-agents: new kb file",
    steps = {
      {
        field = "relative",
        prompt = "relative path (under kb root, e.g. shared/notes/foo.md)",
        validate = function(v)
          if v == nil or v == "" then return false, "path is required" end
          return true
        end,
      },
    },
    on_complete = function(values, emit)
      local kb = require("auto-agents.kb")
      local path = kb.resolve(values.relative)
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      if vim.fn.filereadable(path) == 0 then
        local f = io.open(path, "w"); if f then f:close() end
        kb.log("new: " .. values.relative)
      end
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
    end,
  }
end

---kb.scope — change a slot's kb_scope via wizard (pre-fills current).
---@param slot integer|nil
---@return table
function M.kb_scope(slot)
  return {
    name = "kb.scope",
    banner = "auto-agents: change kb_scope",
    steps = {
      {
        field = "slot",
        prompt = "slot (1..9)",
        default = slot and tostring(slot) or nil,
        placeholder = slot and tostring(slot) or "1..9",
        parse = function(v) return tonumber(v) end,
        validate = function(n)
          if not n or n < 1 or n > 9 then return false, "slot must be 1..9" end
          if not find_entry(n) then return false, "slot " .. n .. " has no bootstrap entry" end
          return true
        end,
      },
      {
        field = "scope",
        prompt = "scope",
        choices = { "shared", "private", "isolated" },
        default = function(values)
          local entry = find_entry(values.slot)
          return (entry and entry.kb_scope) or "shared"
        end,
        validate = function(v)
          if not VALID_SCOPES[v] then return false, "scope must be shared|private|isolated" end
          return true
        end,
      },
    },
    on_complete = function(values, emit)
      local entry = find_entry(values.slot)
      if not entry then
        emit({ "kb scope: slot " .. values.slot .. " has no bootstrap entry" })
        return
      end
      entry.kb_scope = values.scope
      require("auto-agents.config.store").save_current()
      emit({ "✓ kb_scope of slot " .. values.slot .. " set to " .. values.scope
        .. " (effective at next spawn)" })
    end,
  }
end

---project.import — interactive selector pick when called without arg.
---@return table|nil
function M.project_import()
  local store = require("auto-agents.config.store")
  local aa = require("auto-agents")
  local active = aa.state.session_project_key
  local known = {}
  for _, e in ipairs(store.list_known()) do
    if not e.is_global and e.key ~= active then table.insert(known, e) end
  end
  if #known == 0 then
    return nil  -- caller emits "(no other projects found)"
  end

  local placeholder_lines = { "available projects:" }
  local choices = {}
  for _, e in ipairs(known) do
    table.insert(placeholder_lines, "  " .. e.key .. "  " .. (e.cwd or "(no cwd)"))
    table.insert(choices, e.key)
  end

  return {
    name = "project.import",
    banner = "auto-agents: import agents from another project",
    steps = {
      {
        field = "_listing",
        prompt = "(see list above)",
        default = "",
        placeholder = "Press Enter to continue",
        skip = function() return true end,  -- only print listing via banner side-effect
      },
      {
        field = "selector",
        prompt = "key, path, or cwd of source project",
        choices = choices,
        validate = function(v)
          if v == nil or v == "" then return false, "selector is required" end
          return true
        end,
      },
    },
    on_complete = function(values, emit)
      require("auto-agents.project").import(emit, values.selector)
    end,
    -- Hack: the wizard's banner is one line; print the listing first by
    -- piggy-backing on the spec's prepass via the admin caller.
    _preamble = placeholder_lines,
  }
end

---panel.resize — single-step prompt for the panel width override.
---Default value is the current override if set, else the
---currently-resolved effective width (so Enter == "keep what's on
---screen now"). Caller is the `panel resize` admin verb (no arg).
---@return table  -- AutoAgentsWizardSpec
function M.panel_resize()
  local cfg_mod = require("auto-agents.config")
  local aa = require("auto-agents")
  local cfg = aa.state.config or {}
  local p = cfg.panel or {}
  local current = p.width_override
  -- Effective width: either the override, or the percentage-resolved
  -- value at the present terminal columns. We use this as the default
  -- so the user gets a sensible starting point even when no override
  -- is set yet.
  local effective = cfg_mod.resolve_panel_width(cfg, vim.o.columns)
  local default_val = current or effective
  local lo, hi = cfg_mod.PANEL_OVERRIDE_MIN, cfg_mod.PANEL_OVERRIDE_MAX

  local label = string.format("panel width override (%d..%d)", lo, hi)
  local placeholder
  if current then
    placeholder = string.format("%d (currently set; effective=%d)", current, effective)
  else
    placeholder = string.format("none (effective=%d)", effective)
  end

  return {
    name = "panel.resize",
    banner = "auto-agents: resize panel — `panel reset` clears the override.",
    steps = {
      {
        field = "width",
        prompt = label,
        default = tostring(default_val),
        placeholder = placeholder,
        parse = function(v)
          if type(v) == "number" then return v end
          local n = tonumber(v)
          if not n then error("must be an integer (got '" .. tostring(v) .. "')") end
          if n ~= math.floor(n) then error("must be a whole number") end
          return n
        end,
        validate = function(n)
          if type(n) ~= "number" then return false, "must be a number" end
          if n < lo or n > hi then
            return false, string.format("must be in %d..%d", lo, hi)
          end
          return true
        end,
      },
    },
    on_complete = function(values, emit)
      require("auto-agents.panel.admin")._apply_panel_width(values.width, emit)
    end,
  }
end

return M
