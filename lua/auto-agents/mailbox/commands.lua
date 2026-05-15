---auto-agents.mailbox.commands — register auto-agents-owned commands
---into auto-core's mailbox command whitelist.
---
---auto-core's `mailbox.commands` registry (security boundary for
---inbound `kind = "command"` messages, also used by the router's
---wake-hook dispatch) is generic — plugins opt in by registering
---names + handlers. This module is auto-agents' contribution to that
---whitelist.
---
---Three commands ship in v0.2.8:
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
---Other plugins (md-harpoon for `harpoon`, the diff MCP for an
---`openDiff` mirror, etc.) own their own `commands.register` calls.
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
    vim.notify(message, level, { title = "auto-agents.mailbox" })
  end)
  return { ok = true, value = { delivered_to = "vim.notify" } }
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
  send_user = {
    owner       = "auto-agents",
    description = "Surface a short message to the user via vim.notify.",
    schema      = { subject = "string?", body = "string?", level = "string?" },
    handler     = handle_send_user,
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
      require("auto-agents.logger").warn("mailbox.commands",
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