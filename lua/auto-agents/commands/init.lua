---auto-agents.commands: the command verbs auto-agents serves from Neovim, registered on
---auto-core's command registry (`auto-core.commands`).
---
---  peek        the last lines of a slot's terminal, read-only
---  say         text typed into a slot's prompt (the send_slot chokepoint)
---  diff_queue  a diff into the review panel's queue
---
---The editor socket (`autodoc --editor`, auto-agents.editor_socket) serves them to the agents this
---Neovim started, its grants checked; admin `run` and the todos (auto-agents.commands.todos) and
---review (auto-agents.commands.review) verbs share the same registry. No file envelope reaches
---them.
---
---@module 'auto-agents.commands'

local M = {}

---@type table<string, boolean>
local _registered = {}

---Build a structured error response.
---@param code string
---@param message string
---@return table
local function err(code, message)
  return { ok = false, code = code, error = message }
end

---`peek` handler. `args = { slot: number, lines: number? }`. Returns
---the last N lines (default 20) of the target slot's terminal
---buffer. Read-only — does not switch focus, does not modify
---buffer state. Trailing empty lines are stripped so the response
---contains real terminal output, not the post-cursor padding nvim
---reserves at the end of every term buffer.
---@param args table
---@param _ctx table
---@return table
local function handle_peek(args, _ctx)
  args = type(args) == "table" and args or {}
  local slot = tonumber(args.slot)
  if not slot then
    return err("invalid_args", "args.slot (integer) required")
  end
  local aa = require("auto-agents")
  if slot < 1 or slot > (aa.MAX_SLOT or 5) then
    return err("slot_out_of_range",
      string.format("slot %d outside 1..%d", slot, aa.MAX_SLOT or 5))
  end
  local term = aa.state and aa.state.slot_terminals and aa.state.slot_terminals[slot]
  if not term then
    return err("no_terminal",
      string.format("slot %d has no live terminal", slot))
  end
  local alive = false
  if type(term.is_alive) == "function" then
    local ok_a, a = pcall(term.is_alive, term)
    alive = ok_a and a == true
  end
  local bufnr
  if type(term.get_bufnr) == "function" then
    local ok_b, b = pcall(term.get_bufnr, term)
    if ok_b and type(b) == "number" then bufnr = b end
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return err("buffer_unavailable",
      string.format("slot %d terminal has no readable buffer", slot))
  end

  local n_total = vim.api.nvim_buf_line_count(bufnr)
  local n_want = tonumber(args.lines) or 20
  if n_want < 1 then n_want = 1 end
  if n_want > 200 then n_want = 200 end  -- defensive cap

  -- Terminal buffers keep blank padding after the cursor; counting
  -- that toward `n_want` would surface noise as "output". Probe up
  -- to (cap + n_want) lines from the end, find the last non-blank,
  -- and slice the N lines BEFORE that point.
  local probe_n = math.min(n_total, 200 + n_want)
  local probe_lines = vim.api.nvim_buf_get_lines(
    bufnr, math.max(0, n_total - probe_n), n_total, false)
  local trailing_blanks = 0
  for i = #probe_lines, 1, -1 do
    if probe_lines[i] == "" or probe_lines[i]:match("^%s*$") then
      trailing_blanks = trailing_blanks + 1
    else
      break
    end
  end
  local effective_end = n_total - trailing_blanks
  local start_line = math.max(0, effective_end - n_want)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, effective_end, false)

  return {
    ok = true,
    value = {
      slot           = slot,
      lines          = lines,
      line_count     = #lines,
      terminal_alive = alive,
      buffer_total   = n_total,
    },
  }
end

---`say` handler. `args = { slot: number, text: string, submit: boolean? }`.
---Inject text directly into the target slot's TUI input via the
---existing `send_slot` chokepoint — so the codex `[...]`-prefix
---dodge and bracketed-paste wrapping apply identically to a `say`
---call as to a `wake` call. `submit` defaults to true (most
---callers want the text to commit immediately).
---
---Distinct from `wake`: `say` is the "type at the agent" affordance.
---`wake` produces a generic "new inbox from X" nudge; `say` carries
---arbitrary caller-supplied text.
---@param args table
---@param _ctx table
---@return table
local function handle_say(args, _ctx)
  args = type(args) == "table" and args or {}
  local slot = tonumber(args.slot)
  if not slot then
    return err("invalid_args", "args.slot (integer) required")
  end
  if type(args.text) ~= "string" or args.text == "" then
    return err("invalid_args", "args.text (non-empty string) required")
  end
  local aa = require("auto-agents")
  if slot < 1 or slot > (aa.MAX_SLOT or 5) then
    return err("slot_out_of_range",
      string.format("slot %d outside 1..%d", slot, aa.MAX_SLOT or 5))
  end
  local submit = args.submit
  if submit == nil then submit = true end

  local sent = aa.send_slot(slot, args.text, { submit = submit == true })
  if not sent then
    return err("send_failed",
      string.format("send_slot(%d) refused — terminal dead, slot out of "
        .. "range, or send() returned false", slot))
  end
  return {
    ok = true,
    value = {
      slot   = slot,
      text   = args.text,
      submit = submit == true,
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

---@type table<string, AutoCoreCommandSpec>
local SPECS = {
  peek = {
    owner       = "auto-agents",
    description = "Peek at the last N lines (default 20, max 200) of the target slot's TUI buffer. Read-only — does not switch focus or perturb the buffer. Returns lines + line_count + terminal_alive.",
    schema      = { slot = "number", lines = "number?" },
    handler     = handle_peek,
  },
  say = {
    owner       = "auto-agents",
    description = "Inject text into the target slot's TUI input via the send_slot chokepoint (codex bracketed-paste dodge + submit-delay apply). `submit` defaults to true. Distinct from `wake` — say carries caller text; wake produces a generic 'new inbox' nudge.",
    schema      = { slot = "number", text = "string", submit = "boolean?" },
    handler     = handle_say,
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

---Register every verb of this module on auto-core's command registry. Idempotent: safe on every
---setup (auto-core allows a re-register from the same owner). Returns what it registered and
---what it skipped.
---@return { registered: string[], skipped: string[] }
function M.register_all()
  local commands = require("auto-core.commands")
  local out = { registered = {}, skipped = {} }
  for name, spec in pairs(SPECS) do
    local ok, regerr = commands.register(name, spec)
    if ok then
      _registered[name] = true
      out.registered[#out.registered + 1] = name
    else
      out.skipped[#out.skipped + 1] = name
      require("auto-agents.log").warn("commands",
        string.format("register('%s') failed: %s", name, tostring(regerr)))
    end
  end
  return out
end

---The modules whose verbs auto-agents registers: this one, the todos and the review verbs.
M.MODULES = { "auto-agents.commands", "auto-agents.commands.todos", "auto-agents.commands.review" }

---Register every module's verbs (M.MODULES), at setup. Each registers on its own, so one that
---fails to load or register takes only its own verbs down (ADR-0067 A3); a failure is logged as
---an error, never silent (ADR-0039 C4). Returns the modules that failed, by name, with why.
---@return table<string, string> failed
function M.register_every()
  local failed = {}
  for _, mod in ipairs(M.MODULES) do
    local ok_mod, m = pcall(require, mod)
    local ok_reg, reg_err = ok_mod, m
    if ok_mod then ok_reg, reg_err = pcall(m.register_all) end
    if not ok_reg then
      failed[mod] = tostring(reg_err)
      require("auto-agents.log").error("commands", mod .. "'s command verbs are DOWN: " .. tostring(reg_err))
    end
  end
  return failed
end

---Unregister every verb this module registered; other plugins' are left alone.
function M.unregister_all()
  local ok, commands = pcall(require, "auto-core.commands")
  if not ok then return end
  for name in pairs(_registered) do
    pcall(commands.unregister, name)
  end
  _registered = {}
end

return M
