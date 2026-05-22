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
    -- Must NOT start with `[`: codex-backed peers treat a leading `[...]`
    -- as a bracketed/queued composer entry and silently refuse to submit
    -- until the user hits ESC + ENTER. Leading "ATTENTION:" sidesteps it.
    local origin = ctx and ctx.mailbox or "?"
    local kind   = ctx and ctx.arrival_kind or "inbox"
    text = string.format("ATTENTION: [auto-agents] new %s from %s — check $AUTO_AGENTS_MAILBOX_DIR/%s/",
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

  -- ADR 0023 §3.4 — runtime_identity field on every addressbook
  -- response gives the caller a single point at which to compare
  -- their cached identity (env vars / sidecar) against the host's
  -- authoritative state. Mismatch → caller invokes refresh_agent_id.
  local expected_bare_id
  if type(caller_full) == "string" then
    local mb_path_ok, mb_path = pcall(require, "auto-core.mailbox.path")
    if mb_path_ok and type(mb_path.bare_id) == "function" then
      expected_bare_id = mb_path.bare_id(caller_full)
    end
  end

  return {
    ok = true,
    value = {
      instance_id = core.mailbox.get_instance_id(),
      caller      = caller_full,
      runtime_identity = {
        expected_instance_id = core.mailbox.get_instance_id(),
        expected_mailbox_id  = caller_full,
        expected_bare_id     = expected_bare_id,
        hint                  = "Compare against your env / sidecar identity. "
                                .. "If different, call `refresh_agent_id` to reconcile. "
                                .. "See bootstrap-mailbox.md §Resumed-agent identity reconciliation.",
      },
      count       = #addresses,
      addresses   = addresses,
    },
  }
end

---`diff_queue` handler. Enqueue a diff into the unified diff
---queue UI. The synchronous response (auto-core executor path) acks
---the enqueue with `{ ok = true, value = { id, agent_name, ... } }`
---and lands in the sender's `responses/<correlation_id>.json`. The
---user's accept/reject verdict is delivered as a SECOND, follow-up
---message (`kind="message"`, same `correlation_id`) into the
---sender's `inbox/` when the panel resolves — the agent correlates
---via `correlation_id` and reads the verdict from `args.verdict`
---("accepted" / "rejected") plus `args.comment`. Wake fires for the
---inbox arrival via auto-core's router.
---
---For the blocking-coroutine flow used by Claude / Codex (the MCP
---websocket bridge) see `lua/auto-agents/mcp/ws-server/tools/open_diff.lua`.
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

  -- Resolve the agent name in priority order:
  --   1. `args.agent_name` — explicit override (caller knows best).
  --   2. `ctx.sender_bare` — the sender's bare mailbox id, surfaced
  --      by auto-core v0.1.11+ on the executor-path ctx (auto-core
  --      ADR §D3). Strip the `agent:` prefix to get the agent name.
  --      This is the CORRECT field for "who sent this command" —
  --      `ctx.mailbox` is the EXECUTOR (always `nvim`).
  --   3. `ctx.mailbox` — legacy fallback for older auto-core that
  --      doesn't ship ctx.sender_bare. Will incorrectly resolve to
  --      `nvim` but the resolver below will reject it later via the
  --      bootstrap scan.
  --   4. `resolve_diff_agent_name` — last-resort bootstrap scan;
  --      only resolves when exactly one bootstrap entry has
  --      `diff_review = true`.
  --   5. `"?"` literal — the panel maps this to `[unattributed]`.
  local agent_name = args.agent_name
  if type(agent_name) ~= "string" or agent_name == "" then
    local sender_bare = ctx and ctx.sender_bare or nil
    if type(sender_bare) == "string" and sender_bare ~= "" then
      agent_name = sender_bare:match("^agent:(.+)$") or sender_bare
    else
      -- Legacy fallback (pre-0.1.11 auto-core). ctx.mailbox is the
      -- executor (`nvim`), so the agent: match will fail and we'll
      -- end up with the literal "nvim" — which then falls through
      -- to the bootstrap resolver below.
      local from = ctx and ctx.mailbox or nil
      if type(from) == "string" then
        agent_name = from:match("^agent:(.+)$") or from
      end
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

  -- Stash the originator's full mailbox id + the command's
  -- correlation_id so `queue.resolve` / `queue.reject` can emit a
  -- follow-up `kind="message"` verdict back via the standard router
  -- when the user accepts / rejects in the panel. ctx.sender lands
  -- on the executor path via auto-core v0.1.12+; ctx.correlation_id
  -- lands via v0.1.23+. Both are nil-tolerant — without them the
  -- queue entry is fire-and-forget (legacy behavior).
  local originator_mailbox_id
  do
    local s = ctx and ctx.sender or nil
    if type(s) == "string" and s ~= "" then originator_mailbox_id = s end
  end
  local correlation_id
  do
    local c = ctx and ctx.correlation_id or nil
    if type(c) == "string" and c ~= "" then correlation_id = c end
  end

  local diff_queue = require("auto-agents.diff.queue")
  local id = diff_queue.enqueue({
    agent_name            = agent_name,
    file_path             = args.old_file_path,
    old_contents          = old_contents,
    new_contents          = args.new_file_contents,
    tab_name              = args.tab_name,
    originator_mailbox_id = originator_mailbox_id,
    correlation_id        = correlation_id,
    -- The mailbox-routed verdict goes through `emit_verdict` in
    -- queue.lua (best-effort outbound message); the coroutine
    -- callback here stays a no-op because no MCP coroutine is
    -- blocked on this entry.
    callback              = function(_) end,
  })

  -- Trigger UI popup.
  vim.schedule(function()
    local ui_ok, diff_ui = pcall(require, "auto-agents.diff.ui")
    if ui_ok and type(diff_ui.open) == "function" then diff_ui.open() end
  end)

  -- `blocking=false` is the executor-path contract — this command's
  -- own response lands immediately. `verdict_follow_up` advertises
  -- that a SECOND mailbox arrival (kind="message", same
  -- correlation_id) will appear in the sender's inbox/ when the user
  -- accepts/rejects, IF we captured the originator on enqueue.
  -- Agents that want the verdict should keep listening for new
  -- inbox arrivals carrying this correlation_id.
  return {
    ok = true,
    value = {
      id                = id,
      agent_name        = agent_name,
      file_path         = args.old_file_path,
      tab_name          = args.tab_name,
      blocking          = false,
      verdict_follow_up = originator_mailbox_id ~= nil
                            and correlation_id ~= nil,
      correlation_id    = correlation_id,
      note              = "Initial response is the enqueue ack. When the user "
                          .. "accepts/rejects in the panel, a kind=\"message\" "
                          .. "with this correlation_id lands in your inbox/ "
                          .. "carrying args.verdict (\"accepted\"|\"rejected\") "
                          .. "+ args.comment. Use the MCP openDiff transport "
                          .. "instead if you need a blocking coroutine.",
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

---`refresh_agent_id` handler. ADR 0023 §3.2. Self-service recovery
---for agents whose `AUTO_AGENTS_*` env vars were frozen at fork and
---are now stale (typically after `claude --resume` or equivalent).
---
---Resolution: match `args.actor_pid` against
---`state.slot_terminals[<slot>]:pid()` to find which slot owns the
---calling process. Build the canonical identity record + write the
---sidecar file + return the preamble. On failure, return
---`unknown_actor_pid` with the live-slots enumeration so the agent
---can surface to the user.
---@param args table
---@param _ctx table
---@return table
local function handle_refresh_agent_id(args, _ctx)
  args = type(args) == "table" and args or {}
  local actor_pid = tonumber(args.actor_pid)
  if not actor_pid then
    return err("missing_actor_pid",
      "args.actor_pid (integer) required — pass your process PID so the host can match it to a slot.")
  end

  local aa_ok, aa = pcall(require, "auto-agents")
  if not aa_ok then
    return err("auto_agents_unavailable",
      "require('auto-agents') failed")
  end

  -- Walk the slot table for a match. Collect every live slot
  -- along the way so we can return the diagnostic enumeration
  -- on miss.
  local slot_term = aa.state and aa.state.slot_terminals or {}
  local live_slots = {}
  local matched_slot
  local matched_term
  for slot, term in pairs(slot_term) do
    local pid = nil
    if type(term) == "table" and type(term.pid) == "function" then
      local pok, p = pcall(term.pid, term)
      if pok and type(p) == "number" then pid = p end
    end
    local cfg = aa.state.config or {}
    local agents = (cfg.agents and cfg.agents.bootstrap) or {}
    -- Look up agent name from config — falls back to slot for diagnostics.
    local agent_name
    for _, a in ipairs(agents) do
      if tonumber(a.slot) == tonumber(slot) then
        agent_name = a.name
        break
      end
    end
    live_slots[#live_slots + 1] = {
      slot = tonumber(slot), name = agent_name, pid = pid,
    }
    if pid and pid == actor_pid then
      matched_slot = tonumber(slot)
      matched_term = term
    end
  end

  if not matched_slot then
    -- err() returns the standard shape; we extend it with
    -- live_slots so the agent can surface the enumeration to the
    -- user verbatim. ADR 0023 §3.2 specifies this diagnostic shape.
    local out = err("unknown_actor_pid",
      ("PID %d isn't owned by any registered slot in this nvim instance. "
        .. "This nvim may not be the right host for your resumed transcript — "
        .. "try `:AutoAgentsAdoptResumedAgent` in the host that spawned you, "
        .. "or restart your slot."):format(actor_pid))
    out.live_slots = live_slots
    return out
  end

  -- Resolve the slot's bootstrap spec so we can build the sidecar
  -- (need the agent name + the per-agent diff_review flag, v0.2.26).
  local matched_spec
  local agents_cfg = aa.state.config and aa.state.config.agents
                       and aa.state.config.agents.bootstrap or {}
  for _, a in ipairs(agents_cfg) do
    if tonumber(a.slot) == matched_slot then
      matched_spec = a
      break
    end
  end
  if not matched_spec or not matched_spec.name then
    return err("slot_without_agent_name",
      "Found PID " .. actor_pid .. " on slot " .. matched_slot
        .. " but the slot has no registered agent name. "
        .. "This usually means the slot config was edited mid-session — "
        .. "re-run :AutoAgentsSetup or restart the slot.")
  end
  local matched_agent_name = matched_spec.name

  -- Build + write the sidecar identity record.
  local ri_ok, ri = pcall(require, "auto-agents.runtime_identity")
  if not ri_ok then
    return err("runtime_identity_unavailable",
      "require('auto-agents.runtime_identity') failed")
  end
  local core_ok, core = pcall(require, "auto-core")
  if not core_ok then
    return err("auto_core_unavailable",
      "require('auto-core') failed")
  end
  local tool_root = core.mailbox.host_fallback_root()  -- approximation; agent's tool root may differ
  local record = ri.build_record(
    matched_slot, matched_agent_name, tool_root, nil,
    "auto-agents.refresh_agent_id", actor_pid,
    matched_spec.diff_review)
  local path = ri.path_for(matched_slot)
  local wok, werr = ri.write(path, record)
  if not wok then
    return err("sidecar_write_failed",
      "Failed to atomic-write sidecar identity file at " .. path .. ": " .. tostring(werr))
  end

  -- v0.2.25: re-render the per-kind instruction file (CLAUDE.md /
  -- AGENTS.md / GEMINI.md / …) so the resumed agent sees the current
  -- diff_review state and any other roster/protocol changes the
  -- moment it re-reads its on-disk instructions. Idempotent — a no-op
  -- when nothing changed. Soft-fail; identity reconciliation itself
  -- already succeeded.
  do
    local kb_ok, kb = pcall(require, "auto-agents.kb")
    local instr_ok, instr = pcall(require, "auto-agents.kb.instruct")
    if kb_ok and instr_ok then
      local kb_root = kb.root()
      local cwd = matched_spec.cwd
                  or (aa.state and (aa.state.session_project_root
                                     or aa.state.session_cwd))
      local ok_e, err_e = pcall(instr.ensure, matched_spec, kb_root, cwd)
      if not ok_e then
        require("auto-agents.log").warn("refresh_agent_id",
          "kb.instruct.ensure failed on resume: " .. tostring(err_e))
      end
    end
  end

  return {
    ok = true,
    value = {
      preamble = "Your context was overwritten by a `/resume` (or equivalent). "
        .. "Your runtime identity is now the values below — REPLACE every cached "
        .. "AUTO_AGENTS_* reference in your in-context memory and use the sidecar "
        .. "file at `runtime_identity_path` for all future mailbox traffic. "
        .. "See bootstrap-mailbox.md §Resumed-agent identity reconciliation.",
      runtime_identity_path = path,
      instance_id           = record.instance_id,
      mailbox_id            = record.mailbox_id,
      bare_id               = record.bare_id,
      mailbox_dir           = record.mailbox_dir,
      mailbox_bootstrap_doc = record.mailbox_bootstrap_doc,
      slot                  = record.slot,
      agent_name            = record.agent_name,
      diff_review           = record.diff_review,
      stamped_at            = record.stamped_at,
      stamped_by            = record.stamped_by,
    },
  }
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
  refresh_agent_id = {
    owner       = "auto-agents",
    description = "ADR 0023 self-service identity reconciliation for resumed agents. Pass your process PID via args.actor_pid; the host resolves which slot owns the PID and returns your canonical runtime identity (writing a sidecar JSON file the agent reads as authoritative). Call this whenever ctx.identity_hint or addressbook's value.runtime_identity disagrees with your env / cached identity. On unknown_actor_pid the response carries `live_slots` for diagnostics.",
    schema      = {
      claimed_instance_id = "string?",
      claimed_mailbox_id  = "string?",
      actor_pid           = "number",
    },
    handler     = handle_refresh_agent_id,
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