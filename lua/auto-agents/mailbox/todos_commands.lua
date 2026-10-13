---auto-agents.mailbox.todos_commands — register the 12 mailbox
---verbs that expose the project's todo store to peer agents (ADR-0031 §5).
---
---AutoDoc's daemon owns the store: its format, its rules and every write
---(ADR 1791532020). Each verb calls the daemon's `todos.*` verbs itself,
---through autodoc.nvim's client (`auto-agents.todos.store`, §3 step 4), and
---answers once the daemon has; auto-core only says where this project's
---store is. Without AutoDoc every verb answers `dependency_unavailable`
---("AutoDoc required"): there is no Lua fallback. The verbs share the
---`todos.` namespace prefix so they group visually distinct from the
---existing `wake` / `say` / `addressbook` / `commands_list` / `diff_queue`
---etc. surface in `commands_list` output.
---
---Verb roster (12 total):
---
---  Read:
---    todos.list       — list tasks (optional status filter)
---    todos.show       — fetch one task by id
---    todos.list_dirs  — list every store the daemon knows
---    todos.get_dir    — return the active `.todo-list/` path
---
---  Write content:
---    todos.add        — create a new task
---    todos.update     — patch a task's hand-editable fields
---
---  Write status / lifecycle:
---    todos.status     — transition open/in-progress/completed/deferred/archived
---    todos.assign     — set assignee; auto-core's notifier tells the recipient
---    todos.archive    — alias for status=archived
---    todos.remove     — hard-delete a task file
---
---  Reconcile / configure:
---    todos.refresh    — AutoDoc's reconciliation pass
---    todos.set_dir    — point this workspace at a different .todo-list/
---
---ADR-0035's automation verbs (`todos.fire`, `todos.automation_set`)
---went with automation, and `todos.import` with D3 (ADR 1791532020).
---
---This roster and the counts above are ASSERTED against `SPECS` by
---`tests/smoke.lua` [24l]. They were wrong from v0.2.49 (when ADR-0035
---added `todos.fire` and `todos.automation_set`) through v0.2.62 —
---fourteen tags — because the header enumerated 13 and stopped two
---entries above them, ten lines from the table it describes. A README
---then inherited the wrong count from it. A documented count with
---nothing checking it against the thing it counts is a claim, not a
---fact; the cell is the cheapest possible guard. (gold-man, #11 r0.)
---
---**Assignment notices** are auto-core's: its notifier reads AutoDoc's
---change log and mails the recipient for every `todos.assign` (ADR
---1791532020 §2.5). This module only asks it to poll at once. Direct YAML
---`assignee:` edits stay metadata-only by design.
---
---@module 'auto-agents.mailbox.todos_commands'

local M = {}

local store = require("auto-agents.todos.store")

-- Track registration so we don't double-subscribe on repeated
-- setup calls (same idempotency guarantee as commands.register_all).
local _registered = {}

-- The statuses AutoDoc accepts; `automated` went with automation.
local STATUSES = {
  open = true, ["in-progress"] = true, deferred = true, completed = true, archived = true,
}

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

---The envelope for a door error (auto-agents.todos.store): the daemon's
---code as a mailbox code (stale, not_found, invalid_args, unclaimed, …), or
---dependency_unavailable when AutoDoc or auto-core's store resolution is
---missing.
---@param err table
---@return table
local function failed(err)
  return err_response(err.envelope or "internal_error", err.message or tostring(err))
end

local function need_id(args)
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  if args.rev ~= nil and (type(args.rev) ~= "string" or args.rev == "") then
    return err_response("invalid_args", "args.rev, when provided, must be the task's rev (todos.show)")
  end
end

-- ONE STORE PER CALL. Every handler resolves the project's store once, at its
-- start (`resolve`), and sends every daemon verb of its sequence to that ctx
-- (`store.call_at`), never resolving again: the project can switch while any
-- of the handler's waits runs, and a later step must not land in the new
-- project's store (Lector #26 r0 P2 2, r1 P2). Handlers never use store.call.

---resolve is a handler's one store resolution.
---@return table|nil ctx, table|nil envelope  the error envelope when it failed
local function resolve()
  local ctx, err = store.context()
  if not ctx then return nil, err end
  return ctx
end

---current reads one task, with its rev and absolute file_path.
---@return table|nil task, table|nil err, table|nil ctx
local function current(ctx, id)
  local t, err = store.call_at(ctx, "get", id)
  if err then return nil, err end
  t.file_path = store.file_path(ctx, t)
  return t, nil, ctx
end

---mutate reads the task, then sends the write to the SAME store (the read's
---ctx, never a fresh resolution: a project switch while the read waited must
---not send this task's id and rev to another store).
---
---The write's rev is the caller's when it gave one (`args.rev`, from an
---earlier `todos.show` or `list full=true`): a task changed since the caller
---read it is then refused as `stale`, never overwritten. Without one, the
---rev just read is used: the change between the two reads is the caller's
---to accept (the no-rev convenience).
---@param rev string|nil the caller's rev
---@return table|nil before, table|nil after, table|nil err
local function mutate(ctx, verb, id, rev, ...)
  local cur, gerr = current(ctx, id)
  if not cur then return nil, nil, gerr end
  local t, err = store.call_at(ctx, verb, id, rev or cur.rev, ...)
  if err then return nil, nil, err end
  if type(t) == "table" then t.file_path = store.file_path(ctx, t) end
  return cur, t
end

---list_bucket lists one bucket, the archive month by month.
---@return table[]|nil tasks, table|nil err
local function list_bucket(ctx, status)
  local tasks = {}
  local function add(listing)
    for _, t in ipairs((listing and listing.tasks) or {}) do
      t.file_path = store.file_path(ctx, t)
      tasks[#tasks + 1] = t
    end
  end
  if status ~= "archived" then
    local opts = status and { buckets = { status } } or nil
    local l, err = store.call_at(ctx, "list", opts)
    if err and err.code == store.NOT_A_STORE then return tasks end -- no store yet: no tasks
    if err then return nil, err end
    add(l)
    return tasks
  end
  local months, merr = store.call_at(ctx, "list", { buckets = { "archived" } })
  if merr and merr.code == store.NOT_A_STORE then return tasks end
  if merr then return nil, merr end
  for _, p in ipairs((months and months.partitions) or {}) do
    if type(p) == "table" and type(p.month) == "string" then
      local l, err = store.call_at(ctx, "list", { buckets = { "archived/" .. p.month } })
      if err then return nil, err end
      add(l)
    end
  end
  return tasks
end

-- ─── handlers ─────────────────────────────────────────────────

---@param args table
local function h_list(args)
  -- v0.2.39: default to status=open (the most common ask is "what
  -- should I work on next?") and return a SLIM projection — id +
  -- title + file_path per task — so the response stays token-cheap
  -- for agents. Agents that need the full task call `todos.show id=<x>`
  -- instead.
  --
  -- Args:
  --   status = "open" | "in-progress" | "deferred" | "completed" | "archived"
  --   status = "all"     -- every bucket, the archive included
  --   full   = true      -- the full task tables
  local status_filter = args.status
  if status_filter == nil or status_filter == "" then
    status_filter = "open"
  end
  if status_filter ~= "all" and not STATUSES[status_filter] then
    return err_response("invalid_args", "args.status must be one of "
      .. "open, in-progress, deferred, completed, archived, all; got " .. tostring(status_filter))
  end

  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local list = {}
  if status_filter == "all" then
    local active, err = list_bucket(ctx, nil)
    if not active then return failed(err) end
    local archived, aerr = list_bucket(ctx, "archived")
    if not archived then return failed(aerr) end
    vim.list_extend(list, active)
    vim.list_extend(list, archived)
  else
    local got, err = list_bucket(ctx, status_filter)
    if not got then return failed(err) end
    list = got
  end

  if args.full == true then
    return ok_response({ count = #list, status = status_filter, tasks = list })
  end
  local slim = {}
  for _, t in ipairs(list) do
    slim[#slim + 1] = { id = t.id, title = t.title, file_path = t.file_path }
  end
  return ok_response({ count = #slim, status = status_filter, tasks = slim })
end

local function h_show(args)
  local bad = need_id(args); if bad then return bad end
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local task, err = current(ctx, args.id)
  if not task then
    if err.envelope == "not_found" then
      return err_response("not_found", "task '" .. args.id .. "' not found in active todo dir")
    end
    return failed(err)
  end
  return ok_response(task)
end

local function h_list_dirs(_args)
  local list, err = store.call_global("stores", {})
  if err then return failed(err) end
  local out = {}
  for _, s in ipairs(list or {}) do
    out[#out + 1] = {
      todo_dir        = s.path,
      workspace_roots = s.roots or {},
      last_touched    = s.last_use,
      claimed         = s.claimed == true,
      store_id        = s.id,
    }
  end
  table.sort(out, function(a, b) return tostring(a.todo_dir) < tostring(b.todo_dir) end)
  return ok_response(out)
end

local function h_get_dir(_args)
  local ctx, err = store.context()
  if not ctx then return failed(err) end
  return ok_response({ todo_dir = ctx.store })
end

local function h_add(args)
  if type(args.title) ~= "string" or args.title == "" then
    return err_response("invalid_args", "args.title must be a non-empty string")
  end
  -- Whitelist the hand-editable fields we let mailbox callers set
  -- at creation. Everything else (id, lifecycle timestamps,
  -- managed fields) is AutoDoc's.
  local spec = { title = args.title }
  for _, k in ipairs({ "description", "priority", "due", "assignee", "tags", "adr", "review", "blocked" }) do
    if args[k] ~= nil and args[k] ~= vim.NIL then spec[k] = vim.deepcopy(args[k]) end
  end
  store.absolute_refs(spec)
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local task, err = store.call_at(ctx, "add", spec)
  if err and err.code == store.NOT_A_STORE then
    -- a new project's store: auto-core registered and claimed it; scaffold it
    local _, serr = store.call_at(ctx, "scaffold")
    if serr then return failed(serr) end
    task, err = store.call_at(ctx, "add", spec)
  end
  if err then return failed(err) end
  store.publish("core.todo:changed", { kind = "add", id = task.id })
  -- With an assignee it is an assignment (D1): the notifier tells them.
  if type(task.assignee) == "string" and task.assignee ~= "" then store.poke_notifier() end
  return ok_response({ id = task.id })
end

local function h_update(args)
  local bad = need_id(args); if bad then return bad end
  if type(args.patch) ~= "table" then
    return err_response("invalid_args", "args.patch must be a table")
  end
  if args.patch.status ~= nil then
    return err_response("invalid_args", "status changes go through todos.status; refusing patch")
  end
  if args.patch.assignee ~= nil then
    return err_response("invalid_args",
      "an assignment goes through todos.assign (it notifies the assignee); refusing patch")
  end
  local patch = vim.deepcopy(args.patch)
  store.absolute_refs(patch)
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local before, task, err = mutate(ctx, "update", args.id, args.rev, patch)
  if err then return failed(err) end
  store.follow(before, task)
  store.publish("core.todo:changed", { kind = "update", id = args.id })
  return ok_response(task)
end

---move runs a status-changing write and its effects: open buffers follow the
---file, and the panel hears of the move.
local function move(ctx, verb, id, rev, ...)
  local before, task, err = mutate(ctx, verb, id, rev, ...)
  if err then return failed(err) end
  store.follow(before, task)
  if before.status ~= task.status then
    store.publish("core.todo.status:changed", {
      id = id, from = before.status, to = task.status, at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
  end
  return nil, before, task
end

local function h_status(args)
  local bad = need_id(args); if bad then return bad end
  if type(args.status) ~= "string" or not STATUSES[args.status] then
    return err_response("invalid_args",
      "args.status must be one of open/in-progress/completed/deferred/archived")
  end
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local cur, gerr = current(ctx, args.id)
  if not cur then return failed(gerr) end
  if cur.status == args.status and (args.rev == nil or args.rev == cur.rev) then
    return ok_response(cur) -- the same status is a no-op
  end
  local failure, _, task = move(ctx, "status", args.id, args.rev, args.status)
  if failure then return failure end
  return ok_response(task)
end

local function h_assign(args)
  local bad = need_id(args); if bad then return bad end
  -- `assignee` is allowed to be nil to clear; we just type-check.
  if args.assignee ~= nil and args.assignee ~= vim.NIL and type(args.assignee) ~= "string" then
    return err_response("invalid_args", "args.assignee, when provided, must be a string")
  end
  if args.reason ~= nil and type(args.reason) ~= "string" then
    return err_response("invalid_args", "args.reason, when provided, must be a string")
  end
  local who = type(args.assignee) == "string" and args.assignee or ""
  local extra = { who }
  if args.reason and args.reason ~= "" then extra[2] = args.reason end
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local failure, _, task = move(ctx, "assign", args.id, args.rev, unpack(extra))
  if failure then return failure end
  store.publish("core.todo:changed", { kind = "assign", id = args.id })
  if who ~= "" then store.poke_notifier() end
  return ok_response(task)
end

local function h_archive(args)
  return h_status({ id = args.id, rev = args.rev, status = "archived" })
end

local function h_remove(args)
  local bad = need_id(args); if bad then return bad end
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local _, _, err = mutate(ctx, "remove", args.id, args.rev)
  if err then return failed(err) end
  store.publish("core.todo:changed", { kind = "remove", id = args.id })
  return ok_response({ removed = args.id })
end

local function h_refresh(_args)
  local ctx, cerr = resolve()
  if not ctx then return failed(cerr) end
  local summary, err = store.call_at(ctx, "refresh")
  if err and err.code == store.NOT_A_STORE then summary, err = {}, nil end -- nothing yet
  if err then return failed(err) end
  store.publish("core.todo:refreshed", { summary = summary, at = os.date("!%Y-%m-%dT%H:%M:%SZ") })
  return ok_response(summary)
end

local function h_set_dir(args)
  -- `path = nil | ""` clears the override; a path must be an existing directory.
  if args.path ~= nil and type(args.path) ~= "string" then
    return err_response("invalid_args", "args.path, when provided, must be a string")
  end
  local dir = ""
  if type(args.path) == "string" and args.path ~= "" then
    dir = vim.fn.fnamemodify(vim.fn.expand(args.path), ":p"):gsub("/+$", "")
  end
  local ctx, err = store.set_dir(dir)
  if not ctx then return failed(err) end
  return ok_response({ todo_dir = ctx.store })
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
    description = "Fetch a single task by id. Returns the full task: its frontmatter, `rev`, `path` (store-relative), `file_path` (absolute) and `description` (the body).",
    schema      = { id = "string" },
    handler     = h_show,
  },
  ["todos.list_dirs"] = {
    owner       = "auto-agents",
    description = "Return every store AutoDoc's daemon knows (`todo_dir`, `workspace_roots`, `last_touched`, `claimed`, `store_id`).",
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
    -- NOTE: every list field of the task format (tags / adr / review /
    -- blocked) MUST be "any?" here — the list arrives as a Lua table and
    -- the gate's "string?" would reject it ("expected string, got
    -- table"). AutoDoc validates the lists; this mailbox gate only
    -- screens shape. Keep this mirror in sync.
    schema      = {
      title       = "string",
      description = "string?",
      priority    = "string?",
      due         = "string?",
      assignee    = "string?",
      tags        = "any?",
      adr         = "any?",
      review      = "any?",
      blocked     = "any?",
    },
    handler     = h_add,
  },
  ["todos.update"] = {
    owner       = "auto-agents",
    description = "Patch a task's hand-editable fields (title, description, priority, due, tags, adr, review, blocked). `status` goes through todos.status and `assignee` through todos.assign; a patch naming either is refused. Pass `rev` (from todos.show) to have a task changed since then refused as `stale` rather than overwritten. Returns the updated task.",
    schema      = { id = "string", rev = "string?", patch = "any" },
    handler     = h_update,
  },

  ["todos.status"] = {
    owner       = "auto-agents",
    description = "Transition a task between open/in-progress/completed/deferred/archived. Fires `core.todo.status:changed` so the panel + subscribers update. Direct YAML `status:` edits change state on disk but do NOT fire this event — use this verb when other agents need to know.",
    schema      = { id = "string", rev = "string?", status = "string" },
    handler     = h_status,
  },
  ["todos.assign"] = {
    owner       = "auto-agents",
    description = "Set the task's assignee. Assigning an `open` task makes it `in-progress` in the same write (D1). auto-core's notifier sends the recipient a one-shot 'assigned to you' mailbox message (its id makes a repeat a duplicate). Pass `assignee = nil` to clear. Direct YAML `assignee:` edits stay metadata-only by design — use this verb when you want the recipient to be notified.",
    schema      = { id = "string", rev = "string?", assignee = "string?", reason = "string?" },
    handler     = h_assign,
  },
  ["todos.archive"] = {
    owner       = "auto-agents",
    description = "Move a task to archived/YYYY/MM/. Convenience alias for `todos.status` with status=archived; stamps archived_at + preserves completed_at when coming from completed.",
    schema      = { id = "string", rev = "string?" },
    handler     = h_archive,
  },
  ["todos.remove"] = {
    owner       = "auto-agents",
    description = "Hard-delete a task. Irreversible; AutoDoc journals it. Returns `{removed: <id>}` on success.",
    schema      = { id = "string", rev = "string?" },
    handler     = h_remove,
  },

  ["todos.refresh"] = {
    owner       = "auto-agents",
    description = "AutoDoc reconciles the active buckets: bucket placement per status, the 28-day auto-archive rule, reference validation, errors[]. It never reads the archive. Returns `{scanned, moved, archived, errors_set, rewritten, malformed}`.",
    schema      = {},
    handler     = h_refresh,
  },
  ["todos.set_dir"] = {
    owner       = "auto-agents",
    description = "Point the current workspace at a different, EXISTING .todo-list/ directory. Pass `path = nil` or empty string to clear the override and resume the default <workspace_root>/.todo-list/.",
    schema      = { path = "string?" },
    handler     = h_set_dir,
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
      -- ADR-0039 C4: the warn was previously wrapped in a swallowed
      -- pcall — if logging failed, `regerr` vanished. auto-core is a
      -- hard dep already required at the top of this function, so the
      -- log wrapper (which only delegates to auto-core.log) cannot
      -- fail here; log unconditionally.
      require("auto-agents.log").warn("mailbox.commands",
        string.format("register('%s') failed: %s", name, tostring(regerr)))
    end
  end
  -- Sort for stable test output
  table.sort(out.registered)
  table.sort(out.skipped)
  return out
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