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

---Build the default wake nudge text.
---
---A wake is a NUDGE, not a command — the agent's bootstrap-mailbox.md
---is the protocol, so we only point. Two codex composer hazards shape
---the wording for codex-backed peers:
---
---  1. Leading `[`: codex treats a leading `[...]` as a bracketed /
---     queued composer entry and refuses to auto-submit. The leading
---     `ATTENTION:` sidesteps it (also handled defensively in
---     send_slot's leading-`[` dodge).
---  2. Path-like tokens: an earlier default ended in the literal
---     `$AUTO_AGENTS_MAILBOX_DIR/<kind>/`. Codex reacts to that path
---     token by opening a fuzzy path-completion popup ("no matches /
---     Press enter to insert or esc to close") even for bracketed-paste
---     input. Because `wake` submits with a bare `<CR>` (no `Esc` — Esc
---     would cancel in-flight generation, see init.lua send_slot), that
---     `<CR>` is swallowed by the popup and the nudge never submits
---     (confirmed via `peek` on a codex slot). Keep the text prose-only
---     — no `$VAR`, no `/` path separator, no `@` mention token — so no
---     popup opens and the bare `<CR>` submits cleanly. The agent knows
---     where its mailbox lives from bootstrap-mailbox.md; the path was
---     never load-bearing.
---
---Who `origin` is: the SENDER of the arriving file (`ctx.arrival_from`,
---auto-core's wake ctx) or, for an explicit `wake`, the agent that asked
---for it. It used to be `ctx.mailbox`, the mailbox the hook fired for: the
---recipient, so every notice named the agent it was typed into (KB todo
---2026-10-13). Notices are now built and gated in
---`auto-agents.mailbox.notices`; this function is the single-arrival form.
---@param kind string          -- arrival kind ("inbox" | "responses")
---@param origin string        -- who sent it (bare mailbox id)
---@param arrival_path string? -- full path of the new message file
---@return string
function M.default_wake_nudge(kind, origin, arrival_path)
  -- ADR-0036: when the router supplies the arriving message's full
  -- PATH, point the agent straight at it so it Read-tools the message
  -- directly instead of `ls`-ing the dir to find it (the recurring
  -- permission prompt we want gone). The path appears MID-LINE (the
  -- nudge leads with "ATTENTION:"), so it never triggers the codex
  -- fuzzy-path-completion popup — that hazard only fires when a token
  -- *starts* a line with `/`. VERIFY on a live codex slot (peek/say)
  -- before relying on it.
  if type(arrival_path) == "string" and arrival_path ~= "" then
    return string.format(
      "ATTENTION: [auto-agents] new %s from %s — read it with the Read tool: %s",
      kind, origin, arrival_path)
  end
  return string.format(
    "ATTENTION: [auto-agents] new %s from %s — check your %s.",
    kind, origin, kind)
end

---`wake` handler. `args = { slot: string, text: string?, submit: boolean? }`.
---`ctx` carries `mailbox`, `mailbox_full`, `arrival_kind`, `arrival_id`,
---`arrival_path` and (auto-core with arrival facts) `arrival_from`,
---`arrival_subject`, `arrival_ok`, `arrival_code`, `arrival_error`,
---`arrival_command` when fired by the router as a wake hook (see auto-core
---router.lua:dispatch_wake); `sender` / `sender_bare` when an agent sends
---`wake` through the executioner.
---
---Without `args.text` the wake no longer types at once. It hands an item to
---`auto-agents.mailbox.notices`, which:
---  * stays silent for a successful response, an arrival already archived,
---    and an explicit wake when the target's inbox has nothing unread;
---  * waits `notices.config.coalesce_ms`, folding further arrivals for the
---    slot into one line, then re-checks that each file is still there;
---  * logs every notice, typed or suppressed, with the reason.
---The response is `{ ok = true, value = { slot, queued = true } }` or
---`{ ok = true, value = { slot, suppressed = true, reason } }`.
---
---With `args.text` the caller's text is typed immediately, as before: that
---is a deliberate message, not a "you have mail" notice.
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

  local submit = args.submit
  if submit == nil then submit = true end

  local term = aa.state and aa.state.slot_terminals and aa.state.slot_terminals[slot]
  local alive = false
  if term and type(term.is_alive) == "function" then
    local ok_a, a = pcall(term.is_alive, term)
    alive = ok_a and a == true
  end
  local function unavailable()
    return err("terminal_unavailable",
      "wake failed for slot " .. tostring(slot)
        .. " (terminal dead or out of range)")
  end

  local text = args.text
  if type(text) == "string" and text ~= "" then
    -- v0.2.45 (follow-up #1): a wake is a NUDGE, not a command — it
    -- must never interrupt the agent's in-flight work. send_slot's
    -- default submit sequence for codex is `Esc` + `CR` (Esc closes
    -- the composer picker so CR submits). But if codex is mid-
    -- generation, that Esc CANCELS the generation — the reported
    -- bug. Force `submit_keys = { "<CR>" }` for wake so only a bare
    -- Enter is sent, regardless of kind. The leading-`[` codex
    -- bracketed-entry hazard is already dodged by the `ATTENTION:`
    -- prefix of the default nudge, so the Esc isn't needed for the
    -- nudge to land. notices.flush sends with the same keys.
    local ok = aa.send_slot(slot, text, {
      submit      = submit == true,
      submit_keys = { "<CR>" },
    })
    if not ok then return unavailable() end
    return { ok = true, value = { slot = slot, text = text, submit = submit == true } }
  end

  local notices = require("auto-agents.mailbox.notices")
  local item, why, info = notices.item_from_wake(args, ctx)
  if not item then
    notices._audit("suppressed", slot, args.slot, info or {
      kind    = ctx and ctx.arrival_kind or "wake",
      from    = ctx and (ctx.arrival_from_bare or ctx.arrival_from or ctx.sender_bare) or nil,
      subject = ctx and ctx.arrival_subject or nil,
      path    = ctx and ctx.arrival_path or nil,
      command = ctx and ctx.arrival_command or nil,
      code    = ctx and ctx.arrival_code or nil,
      error   = ctx and ctx.arrival_error or nil,
    }, why)
    return { ok = true, value = { slot = slot, suppressed = true, reason = why } }
  end
  if not alive then return unavailable() end
  notices.enqueue(slot, item, { submit = submit == true, agent = args.slot })
  return { ok = true, value = { slot = slot, queued = true, submit = submit == true } }
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

  local ok_c, commands = pcall(require, "auto-core.commands")
  if not ok_c or type(commands.list) ~= "function" then
    return err("auto_core_unavailable", "auto-core.commands.list missing")
  end

  local all = commands.list()
  local commands = {}
  for _, entry in ipairs(all) do
    if filter_owner == nil or entry.owner == filter_owner then
      commands[#commands + 1] = {
        name        = entry.name,
        owner       = entry.owner,
        description = entry.description,
        -- v0.2.43: relay the per-command arg schema (auto-core
        -- v0.1.45+) so agents discover exactly which args each
        -- verb takes — no guessing, no bad_args.
        schema      = entry.schema,
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

  -- ADR 0029 Decision #3 — single seam owns mailbox-root resolution
  -- (per-kind via matched_spec.kind, not host_fallback_root),
  -- mailbox registration, and sidecar identity write. Bug pre-fix:
  -- refresh_agent_id derived tool_root from host_fallback_root(),
  -- which mis-located the sidecar's bootstrap-doc path for agents
  -- registered under per-kind roots.
  local identity_ok, identity = pcall(require, "auto-agents.runtime.identity")
  if not identity_ok then
    return err("runtime_identity_unavailable",
      "require('auto-agents.runtime.identity') failed")
  end
  local result = identity.reconcile({
    slot        = matched_slot,
    agent_name  = matched_agent_name,
    kind        = matched_spec.kind,
    diff_review = matched_spec.diff_review,
    agent_pid   = actor_pid,
    stamped_by  = "auto-agents.refresh_agent_id",
    wake        = { command = "wake", args = { slot = matched_agent_name } },
  })
  if not result.ok then
    return err(result.error or "identity_reconcile_failed",
      tostring(result.detail or "identity reconcile failed"))
  end
  local record = result.sidecar_record
  local path = result.sidecar_path

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
      local ok_p, primary = pcall(kb.primary)
      local cwd = matched_spec.cwd
                  or (aa.state and (aa.state.session_project_root
                                     or aa.state.session_cwd))
      local ok_e, err_e = pcall(instr.ensure, matched_spec,
        ok_p and primary or nil, cwd)
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
    description = "Wake an auto-agents slot terminal by agent name. Used by the router as the default inbox/responses wake hook. Without `text` the notice is coalesced and typed only if something is unread (a successful response, an archived arrival or an empty inbox stays silent: value.suppressed + reason); with `text` the text is typed at once.",
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
}

---Register every auto-agents-owned mailbox command. Idempotent —
---safe to call on every setup (auto-core allows re-register from the
---same owner). Returns `{ registered = string[], skipped = string[] }`.
---@return { registered: string[], skipped: string[] }
function M.register_all()
  local commands = require("auto-core.commands")
  local out = { registered = {}, skipped = {} }
  -- Routing failures are announced to the sender (successful routing is
  -- silent); see auto-agents.mailbox.notices.
  pcall(function() require("auto-agents.mailbox.notices").attach() end)
  for name, spec in pairs(SPECS) do
    local ok, regerr = commands.register(name, spec)
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

---Unregister every command owned by auto-agents. Does NOT touch
---commands owned by other plugins.
function M.unregister_all()
  pcall(function() require("auto-agents.mailbox.notices").detach() end)
  local ok, commands = pcall(require, "auto-core.commands")
  if not ok then return end
  for name in pairs(_registered) do
    pcall(commands.unregister, name)
  end
  _registered = {}
end

---Test-only alias retained for existing specs.
function M._reset_for_tests()
  M.unregister_all()
end

return M
