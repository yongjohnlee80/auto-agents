---auto-agents.todos.store — the `todos.*` mailbox verbs' door to AutoDoc's daemon.
---
---AutoDoc owns the todo store: its format, its rules and every write (ADR
---1791532020). The mailbox verbs call the daemon's `todos.*` verbs themselves,
---through autodoc.nvim's client (`autodoc.todos`), rather than through
---auto-core.todo, which auto-core v0.4.1 removes (§3 steps 4 and 5).
---
---Where the store is still comes from auto-core: `auto-core.todo.where` maps
---this Neovim's project root to the daemon's `At` (a workspace name, or
---`{root}`) and claims the store once per root, with the rollback guard. That
---is the one copy of the rule (ADR r12); this module does not repeat it.
---
---A mailbox handler answers synchronously (auto-core's command registry), so
---each call here waits for the daemon, bounded, as autodoc's own registry
---verbs do (autodoc/verbs.lua). There is no Lua fallback (ADR §4).
---@module 'auto-agents.todos.store'

local M = {}

-- NOTE: deadline. The daemon is another process; a mailbox handler waits for
-- its answer, bounded, so a daemon that does not answer is an error and never
-- a hang. It covers a whole call: connecting (which may start the daemon), the
-- store's first resolution and claim, and the verb itself.
M.WAIT_MS = 15000

M.REQUIRED = "AutoDoc required: the todos.* verbs call AutoDoc's daemon (ADR 1791532020). "
  .. "Install autodoc.nvim (v0.1.39 or later) and its binary."

M.NEEDS_AUTOCORE = "the todos.* verbs need auto-core v0.4.0 or later (its store resolution, "
  .. "auto-core.todo.where): update auto-core"

-- The daemon's codes (autodoc core/todo/module.go) and the mailbox code each
-- becomes in a verb's error envelope.
M.STALE, M.NOT_FOUND, M.INVALID, M.NOT_A_STORE, M.UNCLAIMED = -32071, -32072, -32073, -32074, -32077
local ENVELOPE_CODES = {
  [-32071] = "stale",
  [-32072] = "not_found",
  [-32073] = "invalid_args",
  [-32075] = "exists",
  [-32076] = "not_writable",
  [-32077] = "unclaimed",
}

---deps loads what the door needs, or answers why it can't.
---@return { where: table, daemon: table, todos: table }|nil, string? why
local function deps()
  local ok_w, where = pcall(require, "auto-core.todo.where")
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  if not (ok_w and ok_d and type(where) == "table" and type(daemon) == "table"
      and type(where.ensure) == "function" and type(daemon.run) == "function") then
    return nil, M.NEEDS_AUTOCORE
  end
  local ok_t, todos = pcall(require, "autodoc.todos")
  if not ok_t or type(todos) ~= "table" or type(todos.call) ~= "function" then
    return nil, M.REQUIRED
  end
  return { where = where, daemon = daemon, todos = todos }
end

---Error is what every function here returns on failure.
---@class AutoAgentsTodosError
---@field code integer|nil  the daemon's code, when the daemon answered
---@field message string    "<code name>: <message>"
---@field envelope string   the mailbox envelope's code

---fail builds an error from a daemon error ({code, message}) or a string.
---@param err any
---@return AutoAgentsTodosError
local function fail(err)
  local code = type(err) == "table" and err.code or nil
  local message
  local ok_d, daemon = pcall(require, "auto-core.todo.daemon")
  if ok_d and type(daemon.format) == "function" then
    message = daemon.format(err)
  else
    message = type(err) == "table" and tostring(err.message) or tostring(err)
  end
  local envelope = ENVELOPE_CODES[code]
  if not envelope then
    if message:find("AutoDoc required", 1, true) or message:find("update auto-core", 1, true) then
      envelope = "dependency_unavailable"
    elseif message:find("did not answer", 1, true) then
      envelope = "timeout"
    else
      envelope = "internal_error"
    end
  end
  return { code = code, message = message, envelope = envelope }
end
M._fail = fail

---await runs start(done) and waits for done(...), bounded by WAIT_MS.
---@return any ...  done's arguments, or nil and an error
local function await(start)
  if vim.in_fast_event() then
    return nil, fail("auto-agents.todos: called from a fast event; vim.schedule the call")
  end
  local finished, res = false, nil
  start(function(...) res = { n = select("#", ...), ... }; finished = true end)
  if not finished then vim.wait(M.WAIT_MS, function() return finished end, 10) end
  if not finished then
    return nil, fail("AutoDoc did not answer within " .. M.WAIT_MS .. " ms")
  end
  return unpack(res, 1, res.n)
end

---context resolves (and, the first time, claims) this project's store.
---@return table|nil ctx { root, at, store, store_id, claimed, writable }
---@return AutoAgentsTodosError|nil err
function M.context()
  local d, why = deps()
  if not d then return nil, fail(why) end
  local root = d.where.root()
  return await(function(done)
    d.daemon.run(function() return d.where.ensure(root) end, function(ok, ctx)
      if ok then done(ctx) else done(nil, fail(ctx)) end
    end)
  end)
end

---call runs todos.<verb>(ctx.at, …) for this project's store and waits.
---@param verb string the verb's own name: "get", not "todos.get"
---@param ... any the params after `at`
---@return any result (vim.NIL normalized away)
---@return AutoAgentsTodosError|nil err
---@return table|nil ctx
function M.call(verb, ...)
  local ctx, cerr = M.context()
  if not ctx then return nil, cerr end
  local d = deps()
  if not d then return nil, fail(M.REQUIRED) end
  local params = { ctx.at, ... }
  local res, err = await(function(done)
    local ok, perr = pcall(d.todos.call, verb, params, function(r, e)
      done(d.daemon.normalize(r), d.daemon.normalize(e))
    end)
    if not ok then done(nil, { message = "autodoc: " .. tostring(perr) }) end
  end)
  if err then
    if type(err) == "table" and err.code == M.UNCLAIMED then d.where.reset(ctx.root) end
    if type(err) ~= "table" or err.envelope == nil then err = fail(err) end
    return nil, err, ctx
  end
  return res, nil, ctx
end

---call_global runs a verb that names no store (todos.stores) and waits.
---@param verb string
---@param params any[]
---@return any result, AutoAgentsTodosError|nil err
function M.call_global(verb, params)
  local d, why = deps()
  if not d then return nil, fail(why) end
  local res, err = await(function(done)
    local ok, perr = pcall(d.todos.call, verb, params or {}, function(r, e)
      done(d.daemon.normalize(r), d.daemon.normalize(e))
    end)
    if not ok then done(nil, { message = "autodoc: " .. tostring(perr) }) end
  end)
  if err then return nil, (type(err) == "table" and err.envelope) and err or fail(err) end
  return res
end

---file_path is a daemon task's absolute path in the store ctx names.
---@param ctx table
---@param task table
---@return string?
function M.file_path(ctx, task)
  if type(task) ~= "table" or type(task.path) ~= "string" or type(ctx) ~= "table"
      or type(ctx.store) ~= "string" then
    return nil
  end
  return ctx.store .. "/" .. task.path
end

---absolute_refs resolves `$VAR/…` in a spec's or patch's adr / review with
---Neovim's vars: an agent writes a ref with Neovim's meaning of a var, and the
---daemon symbolizes an absolute path its own way. An unresolved var and a bare
---relative ref (KB-relative, D2) pass through unchanged.
---@param t table spec or patch (modified in place)
function M.absolute_refs(t)
  local ok, vars = pcall(require, "auto-core.todo.vars")
  if not ok or type(vars.resolve_path) ~= "function" then return end
  for _, field in ipairs({ "adr", "review" }) do
    local v = t[field]
    if type(v) == "string" then v = { v }; t[field] = v end
    if type(v) == "table" then
      for i, p in ipairs(v) do
        if type(p) == "string" and p:sub(1, 1) == "$" then
          local r = vars.resolve_path(p)
          if r and r.ok and type(r.path) == "string" and r.path:sub(1, 1) == "/" then
            v[i] = r.path
          end
        end
      end
    end
  end
end

---follow keeps open buffers on a task the daemon moved or rewrote (auto-core's
---buffers): a buffer left on the old path would recreate the task in the
---bucket it left on its next :w.
---@param before table? the task before, with file_path
---@param after table? the task after, with file_path
function M.follow(before, after)
  if type(before) ~= "table" or type(after) ~= "table" then return end
  local ok, buffers = pcall(require, "auto-core.todo.buffers")
  if not ok or type(buffers) ~= "table" then return end
  local from, to = before.file_path, after.file_path
  if type(from) ~= "string" or type(to) ~= "string" then return end
  if from ~= to then pcall(buffers.retarget, from, to) else pcall(buffers.reload, to) end
end

---publish sends one of the core.todo:* events, which the todos panel and other
---subscribers re-read on.
---@param topic string
---@param payload table
function M.publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, topic, payload)
  end
end

---poke_notifier asks auto-core's assignment notifier to poll now: the
---assignee hears of it at once rather than at the next timer tick (ADR §2.5).
function M.poke_notifier()
  pcall(function() require("auto-core.todo.notifier").poll_soon() end)
end

---set_dir points this project at another existing store directory, or back at
---<root>/.todo-list with "". The override is per ROOT, so it goes to the
---daemon as {root}; auto-core's record and resolution are then refreshed, and
---the new store resolved (and claimed).
---@param dir string absolute, or ""
---@return table|nil ctx, AutoAgentsTodosError|nil err
function M.set_dir(dir)
  local d, why = deps()
  if not d then return nil, fail(why) end
  local root = d.where.root()
  local _, err = M.call_global("set_dir", { { root = root }, dir })
  if err then return nil, err end
  d.where.set_override(root, dir ~= "" and dir or nil)
  d.where.reset(root)
  return M.context()
end

return M
