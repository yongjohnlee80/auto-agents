---auto-agents.mailbox.todos_commands — register the 13 mailbox
---verbs that expose `auto-core.todo` to peer agents (ADR-0031 §5).
---
---Each verb is a thin wrapper around the corresponding Lua API in
---`auto-core.todo`. The verbs share the `todos.` namespace prefix
---so they group visually distinct from the existing `wake` / `say`
---/ `addressbook` / `commands_list` / `diff_queue` etc. surface in
---`commands_list` output.
---
---Verb roster (13 total):
---
---  Read:
---    todos.list       — list tasks (optional status filter)
---    todos.show       — fetch one task by id
---    todos.list_dirs  — list every known `.todo-list/` directory
---    todos.get_dir    — return the active `.todo-list/` path
---
---  Write content:
---    todos.add        — create a new task
---    todos.update     — patch a task's hand-editable fields
---
---  Write status / lifecycle:
---    todos.status     — transition open/completed/deferred/archived
---    todos.assign     — set assignee + side-effect notify recipient
---    todos.archive    — alias for status=archived
---    todos.remove     — hard-delete a task file
---
---  Reconcile / configure:
---    todos.refresh    — full reconciliation pass
---    todos.set_dir    — point this workspace at a different .todo-list/
---    todos.import     — bulk import from a KB-format source
---
---**Side effect**: `todos.assign` (and direct `auto-core.todo.assign`
---calls) emit `core.todo.assignee:changed`; this module subscribes
---and delivers a one-shot mailbox message to the recipient agent's
---`inbox/` so they wake up about the assignment. Direct YAML
---`assignee:` edits stay metadata-only by design.
---
---@module 'auto-agents.mailbox.todos_commands'

local M = {}

-- Track registration so we don't double-subscribe on repeated
-- setup calls (same idempotency guarantee as commands.register_all).
local _registered = {}
local _assignee_sub_handle = nil

---Build an OK response envelope matching the existing mailbox
---commands convention.
---@param value any
---@return table
local function ok_response(value)
  return { ok = true, value = value }
end

---Build an error envelope. `code` is a short stable string;
---`message` is the human-readable description.
---@param code string
---@param message string
---@return table
local function err_response(code, message)
  return { ok = false, error = message, code = code }
end

---Defer auto-core.todo loading per-handler (lazy + soft) so the
---module loads cleanly even when auto-core is absent at startup
---(matching the existing commands' pattern).
---@return table?  the auto-core.todo module, or nil + err table
local function todo_or_err()
  local ok, mod = pcall(require, "auto-core.todo")
  if not ok or type(mod) ~= "table" then
    return nil, err_response("dependency_unavailable",
      "auto-core.todo module is not available")
  end
  return mod
end

---Normalize a Lua-API two-value result `(value, err)` into a
---mailbox-response envelope. `value=nil + err` becomes a
---generic `internal_error` envelope; otherwise we wrap value.
---@param value any
---@param err string?
---@return table
local function wrap_two_value(value, err)
  if err ~= nil then return err_response("internal_error", tostring(err)) end
  return ok_response(value)
end

-- ─── handlers ─────────────────────────────────────────────────

---@param args table
local function h_list(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end

  -- v0.2.39: default to status=open (the most common ask is "what
  -- should I work on next?") and return a SLIM projection — id +
  -- title + file_path per task — so the response stays token-cheap
  -- for agents. Agents that need the full schema-v1 shape call
  -- `todos.show id=<x>` instead.
  --
  -- Args:
  --   status = "open" | "deferred" | "completed" | "archived"  -- bucket filter (default "open")
  --   status = "all"                                            -- return every bucket
  --   full   = true                                             -- opt back into full task tables
  local opts = {}
  local status_filter = args.status
  if status_filter == nil or status_filter == "" then
    status_filter = "open"
  end
  if status_filter ~= "all" then opts.status = status_filter end

  local ok, list = pcall(todo.list, opts)
  if not ok then return err_response("internal_error", tostring(list)) end

  if args.full == true then
    return ok_response({ count = #list, status = status_filter, tasks = list })
  end

  -- Compute file_path per task via the canonical paths resolver
  -- (same one the panel uses) so the value lines up across consumers.
  local td = todo.get_todo_dir()
  local ok_paths, paths = pcall(require, "auto-core.todo.paths")
  local slim = {}
  for _, t in ipairs(list) do
    local file_path
    if ok_paths and type(t) == "table" and t.id and t.status then
      local ok_p, p = pcall(paths.task_file_path, td, t.id, t.status, t.archived_at)
      if ok_p then file_path = p end
    end
    slim[#slim + 1] = {
      id        = t.id,
      title     = t.title,
      file_path = file_path,
    }
  end
  return ok_response({ count = #slim, status = status_filter, tasks = slim })
end

local function h_show(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  local task = todo.get(args.id)
  if not task then
    return err_response("not_found", "task '" .. args.id .. "' not found in active todo dir")
  end
  return ok_response(task)
end

local function h_list_dirs(_args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  local ok, dirs = pcall(todo.known_dirs)
  if not ok then return err_response("internal_error", tostring(dirs)) end
  return ok_response(dirs)
end

local function h_get_dir(_args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  local ok, dir = pcall(todo.get_todo_dir)
  if not ok then return err_response("internal_error", tostring(dir)) end
  return ok_response({ todo_dir = dir })
end

local function h_add(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.title) ~= "string" or args.title == "" then
    return err_response("invalid_args", "args.title must be a non-empty string")
  end
  -- Whitelist the hand-editable fields we let mailbox callers set
  -- at creation. Everything else (id, lifecycle timestamps,
  -- managed fields) is owned by auto-core.todo.
  local spec = { title = args.title }
  for _, k in ipairs({ "description", "priority", "due", "assignee", "tags", "adr", "review", "blocked" }) do
    if args[k] ~= nil then spec[k] = args[k] end
  end
  local ok, id = pcall(todo.add, spec)
  if not ok then return err_response("internal_error", tostring(id)) end
  return ok_response({ id = id })
end

local function h_update(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  if type(args.patch) ~= "table" then
    return err_response("invalid_args", "args.patch must be a table")
  end
  local task, err = todo.update(args.id, args.patch)
  return wrap_two_value(task, err)
end

local function h_status(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  if type(args.status) ~= "string" or args.status == "" then
    return err_response("invalid_args", "args.status must be one of open/completed/deferred/archived")
  end
  local task, err = todo.status(args.id, args.status)
  return wrap_two_value(task, err)
end

local function h_assign(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  -- `assignee` is allowed to be nil to clear; we just type-check.
  if args.assignee ~= nil and type(args.assignee) ~= "string" then
    return err_response("invalid_args", "args.assignee, when provided, must be a string")
  end
  if args.reason ~= nil and type(args.reason) ~= "string" then
    return err_response("invalid_args", "args.reason, when provided, must be a string")
  end
  local task, err = todo.assign(args.id, args.assignee, args.reason)
  return wrap_two_value(task, err)
end

local function h_archive(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  local task, err = todo.archive(args.id)
  return wrap_two_value(task, err)
end

local function h_remove(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  local ok, err = todo.remove(args.id)
  if ok then return ok_response({ removed = args.id }) end
  return err_response("internal_error", tostring(err))
end

local function h_refresh(_args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  local ok, summary = pcall(todo.refresh)
  if not ok then return err_response("internal_error", tostring(summary)) end
  return ok_response(summary)
end

local function h_set_dir(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  -- `path = nil | ""` clears the override (per the existing set_todo_dir contract).
  if args.path ~= nil and type(args.path) ~= "string" then
    return err_response("invalid_args", "args.path, when provided, must be a string")
  end
  local ok, err = pcall(todo.set_todo_dir, args.path)
  if not ok then return err_response("internal_error", tostring(err)) end
  return ok_response({ todo_dir = todo.get_todo_dir() })
end

local function h_import(args)
  local todo, errenv = todo_or_err(); if not todo then return errenv end
  if type(args.source) ~= "string" or args.source == "" then
    return err_response("invalid_args", "args.source must be a non-empty path")
  end
  if type(args.kind) ~= "string" or args.kind == "" then
    return err_response("invalid_args",
      "args.kind must be one of {kb-todo-list, legacy-todos-md, asana-json}")
  end
  local opts = { kind = args.kind }
  if args.dry_run ~= nil then opts.dry_run = args.dry_run == true end
  local ok, result = pcall(todo.import, args.source, opts)
  if not ok then return err_response("internal_error", tostring(result)) end
  return ok_response(result)
end

-- ─── command specs ────────────────────────────────────────────

---@type table<string, AutoCoreCommandSpec>
local SPECS = {
  ["todos.list"] = {
    owner       = "auto-agents",
    description = "List tasks. **Defaults to status=open** with a slim per-task projection `{id, title, file_path}` so the response is token-cheap. Pass `status` to filter to a different bucket (or `all` for every bucket). Pass `full=true` to return the full schema-v1 task tables.",
    schema      = { status = "string?", full = "boolean?" },
    handler     = h_list,
  },
  ["todos.show"] = {
    owner       = "auto-agents",
    description = "Fetch a single task by id. Returns the full schema-v1 frontmatter table.",
    schema      = { id = "string" },
    handler     = h_show,
  },
  ["todos.list_dirs"] = {
    owner       = "auto-agents",
    description = "Return every known .todo-list/ directory the host has touched, including which workspace roots share each dir.",
    schema      = {},
    handler     = h_list_dirs,
  },
  ["todos.get_dir"] = {
    owner       = "auto-agents",
    description = "Return the absolute path of the .todo-list/ directory active for the current workspace.",
    schema      = {},
    handler     = h_get_dir,
  },

  ["todos.add"] = {
    owner       = "auto-agents",
    description = "Create a new open task. `title` is required; other hand-editable fields (description, priority, due, assignee, tags, adr, review, blocked) accepted. Returns `{id}`.",
    schema      = {
      title       = "string",
      description = "string?",
      priority    = "string?",
      due         = "string?",
      assignee    = "string?",
      tags        = "any?",
      adr         = "any?",
      review      = "string?",
      blocked     = "any?",
    },
    handler     = h_add,
  },
  ["todos.update"] = {
    owner       = "auto-agents",
    description = "Patch a task's hand-editable fields. `patch` is a partial frontmatter table; managed fields (id, version, timestamps, errors) are silently ignored. Returns the updated task.",
    schema      = { id = "string", patch = "any" },
    handler     = h_update,
  },

  ["todos.status"] = {
    owner       = "auto-agents",
    description = "Transition a task between open/completed/deferred/archived. Fires `core.todo.status:changed` so the panel + subscribers update. Direct YAML `status:` edits change state on disk but do NOT fire this event — use this verb when other agents need to know.",
    schema      = { id = "string", status = "string" },
    handler     = h_status,
  },
  ["todos.assign"] = {
    owner       = "auto-agents",
    description = "Set the task's assignee. Fires `core.todo.assignee:changed`; auto-agents subscribes and routes a one-shot 'assigned to you' mailbox message to the recipient's inbox. Pass `assignee = nil` to clear. Direct YAML `assignee:` edits stay metadata-only by design — use this verb when you want the recipient to be notified.",
    schema      = { id = "string", assignee = "string?", reason = "string?" },
    handler     = h_assign,
  },
  ["todos.archive"] = {
    owner       = "auto-agents",
    description = "Move a task to archived/YYYY/MM/. Convenience alias for `todos.status` with status=archived; stamps archived_at + preserves completed_at when coming from completed.",
    schema      = { id = "string" },
    handler     = h_archive,
  },
  ["todos.remove"] = {
    owner       = "auto-agents",
    description = "Hard-delete a task. Irreversible. Auditable via auto-core.log. Returns `{removed: <id>}` on success.",
    schema      = { id = "string" },
    handler     = h_remove,
  },

  ["todos.refresh"] = {
    owner       = "auto-agents",
    description = "Reconcile the active .todo-list/: walks every file, fixes bucket placement per status, applies the 28-day auto-archive rule, runs reference validation, updates errors[]. Returns a summary table.",
    schema      = {},
    handler     = h_refresh,
  },
  ["todos.set_dir"] = {
    owner       = "auto-agents",
    description = "Point the current workspace at a different .todo-list/ directory. Pass `path = nil` or empty string to clear the override and resume the default <workspace_root>/.todo-list/.",
    schema      = { path = "string?" },
    handler     = h_set_dir,
  },
  ["todos.import"] = {
    owner       = "auto-agents",
    description = "Bulk import from an external source. `kind` ∈ {kb-todo-list, legacy-todos-md, asana-json}. `dry_run = true` skips writes. See ADR-0031 §3.4.",
    schema      = { source = "string", kind = "string", dry_run = "boolean?" },
    handler     = h_import,
  },
}

M._SPECS = SPECS  -- exposed for tests / introspection

---Register every todos.* command. Idempotent — safe to call on
---every setup. Mirrors the existing
---`auto-agents.mailbox.commands.register_all` pattern.
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
      pcall(function()
        require("auto-agents.log").warn("mailbox.commands",
          string.format("register('%s') failed: %s", name, tostring(regerr)))
      end)
    end
  end
  -- Sort for stable test output
  table.sort(out.registered)
  table.sort(out.skipped)
  return out
end

-- ─── assignee event → mailbox message ─────────────────────────

---Compose the one-shot mailbox message body for an assignment.
---Mirrors ADR §5 / 3.4: include task id, title, file path, and
---the optional one-line reason.
---@param payload table
---@return string body
local function format_assign_body(payload)
  local lines = {
    "You have been assigned a task.",
    "",
    string.format("  id        : %s", tostring(payload.id)),
    string.format("  title     : %s", tostring(payload.title or "(untitled)")),
    string.format("  file_path : %s", tostring(payload.file_path or "(unknown)")),
  }
  if payload.from and payload.from ~= "" then
    lines[#lines + 1] = string.format("  from      : %s", tostring(payload.from))
  end
  if payload.reason and payload.reason ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Reason: " .. tostring(payload.reason)
  end
  return table.concat(lines, "\n")
end

---Subscribe to `core.todo.assignee:changed` and deliver a
---mailbox message to the recipient agent's inbox. Idempotent —
---repeated calls are no-ops.
function M.install_assignee_routing()
  if _assignee_sub_handle then return end
  local ok_ev, events = pcall(require, "auto-core.events")
  if not (ok_ev and events and type(events.subscribe) == "function") then return end

  _assignee_sub_handle = events.subscribe("core.todo.assignee:changed", function(payload)
    -- Only react to assignments TO someone; clearing assignee
    -- (to = nil) is metadata-level + doesn't ping anyone.
    if type(payload) ~= "table" then return end
    local to = payload.to
    if to == nil or to == "" then return end

    -- Try to send via auto-core.mailbox.send. The recipient is
    -- the bare or full mailbox id (e.g. "agent:lector" or
    -- "agent:lector:<instance>"); the router resolves either form.
    local ok_core, ac = pcall(require, "auto-core")
    if not (ok_core and ac and ac.mailbox and ac.mailbox.send) then return end
    pcall(ac.mailbox.send, {
      to      = to,
      kind    = "notification",
      subject = "[todos] task assigned to you: "
        .. tostring(payload.title or payload.id or "(unknown)"),
      body    = format_assign_body(payload),
    })
  end)
end

---Tear down the assignee subscription. Used by tests; production
---callers don't normally need this since the subscription
---survives the plugin's lifetime.
function M.uninstall_assignee_routing()
  if not _assignee_sub_handle then return end
  local ok_ev, events = pcall(require, "auto-core.events")
  if ok_ev and events and type(events.unsubscribe) == "function" then
    pcall(events.unsubscribe, _assignee_sub_handle)
  end
  _assignee_sub_handle = nil
end

---Return the absolute filesystem path to the bundled
---bootstrap-todos.md doc. Useful for both `:AutoAgentsTodosDoc`
---(human reference) and agent-facing discovery: a spawned
---claude-style agent can read this doc to learn the
---`todos.*` command surface contract.
---@return string?
function M.bootstrap_doc_path()
  -- Find ourselves on the runtimepath so the resource path
  -- resolves regardless of where the plugin is installed.
  local sources = vim.api.nvim_get_runtime_file(
    "lua/auto-agents/templates/bootstrap-todos.md", false)
  if sources and sources[1] then return sources[1] end
  return nil
end

return M