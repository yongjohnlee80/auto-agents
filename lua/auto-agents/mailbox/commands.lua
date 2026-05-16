---auto-agents.mailbox.commands — register auto-agents-owned commands
---into auto-core's mailbox command whitelist.
---
---auto-core's `mailbox.commands` registry (security boundary for
---inbound `kind = "command"` messages, also used by the router's
---wake-hook dispatch) is generic — plugins opt in by registering
---names + handlers. This module is auto-agents' contribution to that
---whitelist.
---
---Five commands ship (v0.2.8 originals + openDiff + commands_list):
---
---  * `wake` — the wake hook the router fires on every
---    inbox/responses arrival (registered as `wake` so the
---    `rec.wake = { command = "wake", ... }` config reads
---    mnemonically). Resolves a slot by agent name and nudges its
---    terminal so the agent self-reflects per its
---    `bootstrap-mailbox.md` protocol. Without this registration
---    the wake silently no-ops (router.lua:208-212).
---
---  * `addressbook` — query the live mailbox registry so an agent
---    can discover every reachable address (peer agents, the
---    `nvim` executioner, the virtual `user` sink) without
---    guessing. Always up-to-date because the underlying registry
---    is populated by `mailbox.register` at agent spawn time. The
---    book is dynamic by construction — every fresh agent spawn
---    inserts itself, every nvim restart starts a clean per-
---    instance book.
---
---  * `send_user` — bridge to `vim.notify` so agents can surface
---    short messages to the user without going through stdin / a
---    panel send. Useful for "I'm done" / "blocked" pings.
---
---  * `diff_queue` (v0.2.10+) — enqueue a diff into the unified
---    diff queue UI. Fire-and-forget — the user's accept/reject
---    verdict is NOT returned through the mailbox response. For
---    the blocking flow (agent waits for verdict), use the MCP
---    openDiff transport instead.
---
---  * `commands_list` — return the live whitelisted command surface
---    (name, owner, description) by querying auto-core's registry.
---    Sibling of `addressbook`: peer discovery vs verb discovery.
---    Optional `owner` filter narrows results to one plugin.
---
---Other plugins (md-harpoon for `harpoon_attach/view/render_browser`,
---etc.) own their own `commands.register` calls.
---
---@module 'auto-agents.mailbox.commands'

local M = {}

---@type table<string, boolean>
local _registered = {}

---@param level any
---@return integer
local function notify_level(level)
  if level == "warn"  then return vim.log.levels.WARN end
  if level == "error" then return vim.log.levels.ERROR end
  if level == "debug" then return vim.log.levels.DEBUG end
  return vim.log.levels.INFO
end

---Build a structured error response.
---@param code string
---@param message string
---@return table
local function err(code, message)
  return { ok = false, code = code, error = message }
end

---`wake` handler. `args = { slot: string, text: string?, submit: boolean? }`.
---`ctx` carries `mailbox`, `mailbox_full`, `arrival_kind`, `arrival_id`
---when fired by the router as a wake hook (see auto-core
---router.lua:dispatch_wake).
---@param args table
---@param ctx  table
---@return table
local function handle_wake(args, ctx)
  if type(args) ~= "table" or type(args.slot) ~= "string" or args.slot == "" then
    return err("invalid_args", "args.slot (non-empty string) required")
  end
  local aa = require("auto-agents")
  local slot = aa.slot_for_name(args.slot)
  if not slot then
    return err("slot_not_found", "no bootstrap entry for slot name '" .. args.slot .. "'")
  end

  local text = args.text
  if type(text) ~= "string" or text == "" then
    -- Default nudge: short directive that fits in one terminal line.
    -- The agent's bootstrap-mailbox.md is the protocol — we just point.
    local origin = ctx and ctx.mailbox or "?"
    local kind   = ctx and ctx.arrival_kind or "inbox"
    text = string.format("[auto-agents] new %s from %s — check $AUTO_AGENTS_MAILBOX_DIR/%s/",
      kind, origin, kind)
  end

  local submit = args.submit
  if submit == nil then submit = true end

  local ok = aa.send_slot(slot, text, { submit = submit == true })
  if not ok then
    return err("terminal_unavailable",
      "wake failed for slot " .. tostring(slot)
        .. " (terminal dead or out of range)")
  end
  return { ok = true, value = { slot = slot, text = text, submit = submit == true } }
end

---`addressbook` handler. `args = { include_self: boolean? }` —
---defaults to `true`. Returns every mailbox registered with
---auto-core (peers, `nvim`) plus a virtual `user` entry telling
---the caller how to reach the user via `send_user`.
---
---Used by agents to discover who they can talk to without
---hardcoding peer names. The registry is the source of truth, so
---results stay accurate as agents spawn/despawn over the lifetime
---of this nvim instance.
---@param args table
---@param ctx  table
---@return table
local function handle_addressbook(args, ctx)
  args = type(args) == "table" and args or {}
  local include_self = args.include_self
  if include_self == nil then include_self = true end

  local ok, core = pcall(require, "auto-core")
  if not ok then
    return err("auto_core_unavailable", "require('auto-core') failed")
  end
  local records = core.mailbox.registry.records()

  local caller_full = ctx and ctx.mailbox_full or nil

  local addresses = {}
  for _, rec in ipairs(records) do
    local is_self = caller_full ~= nil and rec.id == caller_full
    if include_self or not is_self then
      local kind = "agent"
      if rec.bare_id == "nvim" then kind = "host" end
      addresses[#addresses + 1] = {
        id           = rec.id,
        bare_id      = rec.bare_id,
        kind         = kind,
        dir          = rec.dir,
        tool_root    = rec.tool_root,
        executioner  = rec.executioner == true,
        wake_command = rec.wake and rec.wake.command or nil,
        is_self      = is_self,
      }
    end
  end

  -- Virtual `user` entry — not a real mailbox, but a reachable
  -- "address" via the send_user command. Surfaced so agents
  -- don't have to special-case knowing the user is reachable.
  addresses[#addresses + 1] = {
    id          = "user",
    bare_id     = "user",
    kind        = "virtual",
    description = "Not a mailbox. Reach by sending kind='command' command='send_user' addressed to 'nvim'.",
    is_self     = false,
  }

  table.sort(addresses, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)

  return {
    ok = true,
    value = {
      instance_id = core.mailbox.get_instance_id(),
      caller      = caller_full,
      count       = #addresses,
      addresses   = addresses,
    },
  }
end

---`diff_queue` handler. Enqueue a diff into the unified diff
---queue UI. Fire-and-forget — auto-core's executor returns the
---response immediately; the user's accept/reject does NOT flow
---back through the mailbox transport. For a blocking verdict use
---the MCP openDiff handler at
---`lua/auto-agents/mcp/ws-server/tools/open_diff.lua`.
---@param args table
---@param ctx  table
---@return table
local function handle_diff_queue(args, ctx)
  if type(args) ~= "table" then
    return err("invalid_args", "args (table) required")
  end
  local required = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }
  for _, k in ipairs(required) do
    if type(args[k]) ~= "string" or args[k] == "" then
      return err("invalid_args", "args." .. k .. " (non-empty string) required")
    end
  end

  -- Resolve the agent name. Prefer an explicit arg; otherwise derive
  -- from the sender (`ctx.mailbox` is the bare id, e.g. "agent:lector").
  local agent_name = args.agent_name
  if type(agent_name) ~= "string" or agent_name == "" then
    local from = ctx and ctx.mailbox or nil
    if type(from) == "string" then
      agent_name = from:match("^agent:(.+)$") or from
    end
  end
  local aa = require("auto-agents")
  if type(aa.resolve_diff_agent_name) == "function" then
    agent_name = aa.resolve_diff_agent_name(agent_name) or agent_name or "?"
  end
  agent_name = agent_name or "?"

  -- Read existing file contents (best-effort; empty if missing — new file).
  local old_contents = ""
  local f = io.open(args.old_file_path, "r")
  if f then
    old_contents = f:read("*a") or ""
    f:close()
  end

  local diff_queue = require("auto-agents.diff.queue")
  local id = diff_queue.enqueue({
    agent_name   = agent_name,
    file_path    = args.old_file_path,
    old_contents = old_contents,
    new_contents = args.new_file_contents,
    tab_name     = args.tab_name,
    -- Fire-and-forget: noop callback. The verdict event still
    -- publishes on the auto-core bus (`auto-agents:diff_*`) so
    -- the UI works normally; we just don't route it back through
    -- the mailbox to the sender.
    callback     = function(_) end,
  })

  -- Trigger UI popup.
  vim.schedule(function()
    local ui_ok, diff_ui = pcall(require, "auto-agents.diff.ui")
    if ui_ok and type(diff_ui.open) == "function" then diff_ui.open() end
  end)

  return {
    ok = true,
    value = {
      id           = id,
      agent_name   = agent_name,
      file_path    = args.old_file_path,
      tab_name     = args.tab_name,
      blocking     = false,
      note         = "Fire-and-forget. Use the MCP openDiff transport to block for the user's accept/reject verdict.",
    },
  }
end

---`commands_list` handler. `args = { owner: string? }`.
---
---Returns the full whitelisted command surface — names, owners,
---descriptions — by querying auto-core's command registry. Optional
---`owner` filter narrows results to a single plugin (e.g. only
---`md-harpoon` commands). Sibling of `addressbook`: peer discovery
---vs. verb discovery, both backed by the live registry so results
---stay accurate as plugins register / unregister.
---@param args table
---@return table
local function handle_commands_list(args)
  args = type(args) == "table" and args or {}
  local filter_owner = args.owner
  if filter_owner ~= nil
      and (type(filter_owner) ~= "string" or filter_owner == "") then
    return err("invalid_args", "args.owner, when provided, must be a non-empty string")
  end

  local ok, core = pcall(require, "auto-core")
  if not ok then
    return err("auto_core_unavailable", "require('auto-core') failed")
  end
  if not core.mailbox or not core.mailbox.commands
      or type(core.mailbox.commands.list) ~= "function" then
    return err("mailbox_unavailable", "auto-core mailbox.commands.list missing")
  end

  local all = core.mailbox.commands.list()
  local commands = {}
  for _, entry in ipairs(all) do
    if filter_owner == nil or entry.owner == filter_owner then
      commands[#commands + 1] = {
        name        = entry.name,
        owner       = entry.owner,
        description = entry.description,
      }
    end
  end

  return {
    ok = true,
    value = {
      count    = #commands,
      filter   = filter_owner,
      commands = commands,
    },
  }
end

---`send_user` handler. `args = { subject: string?, body: string?, level: "info"|"warn"|"error"|"debug"? }`.
---@param args table
---@param _ctx table
---@return table
local function handle_send_user(args, _ctx)
  args = type(args) == "table" and args or {}
  local subject = type(args.subject) == "string" and args.subject ~= "" and args.subject or "auto-agents"
  local body    = type(args.body)    == "string" and args.body    or ""
  local level   = notify_level(args.level)
  local message = body ~= "" and (subject .. ": " .. body) or subject
  vim.schedule(function()
    require("auto-agents.log").notify(message, {
      component = "mailbox.send_user",
      title     = "auto-agents.mailbox",
      level     = level,
    })
  end)
  return { ok = true, value = { delivered_to = "log.notify" } }
end

---@type table<string, AutoCoreCommandSpec>
local SPECS = {
  wake = {
    owner       = "auto-agents",
    description = "Wake an auto-agents slot terminal by agent name. Used by the router as the default inbox/responses wake hook.",
    schema      = { slot = "string", text = "string?", submit = "boolean?" },
    handler     = handle_wake,
  },
  addressbook = {
    owner       = "auto-agents",
    description = "Return every reachable mailbox address registered with auto-core, including the virtual `user` entry.",
    schema      = { include_self = "boolean?" },
    handler     = handle_addressbook,
  },
  commands_list = {
    owner       = "auto-agents",
    description = "Return the live whitelisted command surface (name, owner, description). Optional `owner` filter narrows to one plugin. Sibling of `addressbook` — peer discovery vs verb discovery.",
    schema      = { owner = "string?" },
    handler     = handle_commands_list,
  },
  send_user = {
    owner       = "auto-agents",
    description = "Surface a short message to the user via vim.notify.",
    schema      = { subject = "string?", body = "string?", level = "string?" },
    handler     = handle_send_user,
  },
  diff_queue = {
    owner       = "auto-agents",
    description = "Enqueue a diff into the unified diff queue UI (fire-and-forget; use MCP openDiff for blocking verdict).",
    schema      = {
      old_file_path     = "string",
      new_file_path     = "string",
      new_file_contents = "string",
      tab_name          = "string",
      agent_name        = "string?",
    },
    handler     = handle_diff_queue,
  },
}

---Register every auto-agents-owned mailbox command. Idempotent —
---safe to call on every setup (auto-core allows re-register from the
---same owner). Returns `{ registered = string[], skipped = string[] }`.
---@return { registered: string[], skipped: string[] }
function M.register_all()
  local mailbox = require("auto-core").mailbox
  local out = { registered = {}, skipped = {} }
  for name, spec in pairs(SPECS) do
    local ok, regerr = mailbox.commands.register(name, spec)
    if ok then
      _registered[name] = true
      out.registered[#out.registered + 1] = name
    else
      out.skipped[#out.skipped + 1] = name
      require("auto-agents.log").warn("mailbox.commands",
        string.format("register('%s') failed: %s", name, tostring(regerr)))
    end
  end
  return out
end

---Test-only — unregister every command we own. Does NOT touch
---commands owned by other plugins.
function M._reset_for_tests()
  local ok, core = pcall(require, "auto-core")
  if not ok then return end
  for name in pairs(_registered) do
    pcall(core.mailbox.commands.unregister, name)
  end
  _registered = {}
end

return M