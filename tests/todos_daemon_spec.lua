-- tests/todos_daemon_spec.lua — the todos.* mailbox verbs against a REAL AutoDoc
-- daemon of this suite's own (ADR 1791532020 §3 step 4).
--
-- The verbs call AutoDoc's todos.* verbs themselves (auto-agents.todos.store),
-- not auto-core.todo, which auto-core v0.4.1 removes. auto-core only says where
-- the project's store is (auto-core.todo.where). The daemon's config names a
-- socket, a state dir and a data dir under this suite's sandbox, so no cell
-- reaches a live store or a daemon another run started.
--
-- Where autodoc comes from, first match wins:
--   1. AA_TEST_AUTODOC (a checkout) and AA_TEST_AUTODOC_BIN (its binary);
--   2. the sibling checkout <plugins>/autodoc/main and its bin/autodoc
--      (what .github/install-deps.sh builds).
--
--   nvim --headless -u NONE -l tests/todos_daemon_spec.lua
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

local function pick(rel)
  -- $AUTO_CORE_ROOT overrides the sibling resolution (see tests/run-all.sh).
  if rel == "auto-core.nvim" and vim.env.AUTO_CORE_ROOT then return vim.env.AUTO_CORE_ROOT end
  for _, wt in ipairs({ "/main", "" }) do
    local p = plugins_root .. "/" .. rel .. wt
    if vim.fn.isdirectory(p .. "/lua") == 1 then return p end
  end
end
local autodoc = vim.env.AA_TEST_AUTODOC
if not (autodoc and autodoc ~= "") then autodoc = plugins_root .. "/autodoc/main" end
local bin = vim.env.AA_TEST_AUTODOC_BIN
if not (bin and bin ~= "") then bin = autodoc .. "/bin/autodoc" end
for _, p in ipairs({ project_root, pick("auto-core.nvim"), autodoc }) do
  if p then
    vim.opt.runtimepath:prepend(p)
    package.path = p .. "/lua/?.lua;" .. p .. "/lua/?/init.lua;" .. package.path
  end
end

local passed, failed = 0, 0
local function ok(name, cond, detail)
  if cond then passed = passed + 1 else failed = failed + 1 end
  local line = (cond and "  PASS  " or "  FAIL  ") .. name
  if not cond and detail ~= nil then line = line .. "  — " .. tostring(detail) end
  -- Start on a line of our own: run-all counts "^  FAIL".
  io.stdout:write("\n", (line:gsub("[\r\n]+", " ")), "\n")
end
local function section(t) io.stdout:write("\n", t, "\n") end

-- ── the sandbox ──────────────────────────────────────────────
local sb = vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/")) .. "/aa-todos-" .. vim.uv.os_getpid()
vim.fn.mkdir(sb .. "/state", "p")
vim.fn.mkdir(sb .. "/ad/state", "p")
vim.fn.mkdir(sb .. "/ad/data", "p")
require("auto-core.state").configure({ persist_dir = sb .. "/state" })
local sock = string.format("/tmp/aa-ad-%d.sock", vim.uv.os_getpid())
local cfg = sb .. "/ad/config.toml"
vim.fn.writefile({
  "[server]",
  string.format("socket = %q", sock),
  string.format("state_dir = %q", sb .. "/ad/state"),
  string.format("data_dir = %q", sb .. "/ad/data"),
}, cfg)

local setup_ok, setup_err = false, nil
if vim.fn.isdirectory(autodoc .. "/lua/autodoc") ~= 1 then
  setup_err = "autodoc.nvim not found (set AA_TEST_AUTODOC, or install-deps.sh): " .. autodoc
elseif vim.fn.executable(bin) ~= 1 then
  setup_err = "the autodoc binary is not executable (set AA_TEST_AUTODOC_BIN): " .. bin
else
  setup_ok, setup_err = pcall(function()
    require("autodoc").setup({ bin = bin, config = cfg, preview = false,
      offer_restart = false, offer_link = false })
  end)
end
ok("AutoDoc is set up", setup_ok, setup_err)

local proj = sb .. "/proj"
vim.fn.mkdir(proj, "p")
local worktree = require("auto-core.git.worktree")
worktree.set_workspace_root(proj)

local todos = require("auto-agents.mailbox.todos_commands")
local SPECS = todos._SPECS
local function run(verb, args)
  local spec = SPECS[verb]
  if not spec then return { ok = false, code = "no_such_verb", error = verb } end
  local okc, res = pcall(spec.handler, args or {}, {})
  if not okc then return { ok = false, code = "raised", error = tostring(res) } end
  return res
end

-- spies: the daemon verbs sent, the events published, the notifier's pokes
local ad_todos = require("autodoc.todos")
local real_call = ad_todos.call
local sent, last_params = {}, {}
ad_todos.call = function(verb, params, cb)
  sent[#sent + 1] = verb
  last_params[verb] = vim.deepcopy(params)
  real_call(verb, params, cb)
end
local function count(verb)
  local n = 0
  for _, v in ipairs(sent) do if v == verb then n = n + 1 end end
  return n
end
local events = require("auto-core.events")
local seen = {}
for _, topic in ipairs({ "core.todo:changed", "core.todo.status:changed", "core.todo:refreshed" }) do
  seen[topic] = {}
  events.subscribe(topic, function(p) table.insert(seen[topic], p or {}) end)
end
local pokes = 0
package.loaded["auto-core.todo.notifier"] = { poll_soon = function() pokes = pokes + 1 end }

-- ─────────────────────────────────────────────────────────────
section("the surface: twelve verbs, no import")
do
  local names = {}
  for name in pairs(SPECS) do names[#names + 1] = name end
  table.sort(names)
  ok("twelve todos.* verbs", #names == 12, vim.inspect(names))
  ok("todos.import is gone (D3)", SPECS["todos.import"] == nil)
  ok("the assignee-routing subscriber is gone (the notifier is auto-core's)",
    todos.install_assignee_routing == nil and todos.uninstall_assignee_routing == nil)
end

-- ─────────────────────────────────────────────────────────────
section("a new project: add scaffolds the store, then writes the task")
local id
do
  ok("no store yet", vim.fn.isdirectory(proj .. "/.todo-list") == 0)
  local r = run("todos.list")
  ok("list on a project with no store is empty, not an error",
    r.ok == true and r.value.count == 0, vim.inspect(r))
  local before = #seen["core.todo:changed"]
  r = run("todos.add", { title = "First task", priority = "low" })
  ok("add answers the id", r.ok == true and type(r.value.id) == "string", vim.inspect(r))
  id = r.value and r.value.id
  ok("AutoDoc made the store (scaffold) and the task file",
    vim.fn.isdirectory(proj .. "/.todo-list/open") == 1, vim.inspect(sent))
  ok("… through todos.scaffold", count("scaffold") == 1, vim.inspect(sent))
  ok("add published core.todo:changed", #seen["core.todo:changed"] == before + 1)
  ok("the store is claimed and marked", vim.uv.fs_stat(proj .. "/.todo-list/.autodoc-owner") ~= nil)
end

-- ─────────────────────────────────────────────────────────────
section("reads: list, show, get_dir, list_dirs")
do
  local r = run("todos.list")
  local t = r.ok and r.value.tasks[1]
  ok("list defaults to open, slim", r.ok and r.value.status == "open" and r.value.count == 1
    and t and t.id == id and t.title == "First task" and t.priority == nil, vim.inspect(r))
  ok("… with each task's absolute file_path, which exists",
    t and type(t.file_path) == "string" and vim.uv.fs_stat(t.file_path) ~= nil, t and t.file_path)
  r = run("todos.list", { full = true })
  ok("full=true returns the whole task, with its rev",
    r.ok and r.value.tasks[1] and r.value.tasks[1].priority == "low"
      and type(r.value.tasks[1].rev) == "string", vim.inspect(r))
  r = run("todos.list", { status = "automated" })
  ok("an unknown status is invalid_args", r.ok == false and r.code == "invalid_args", vim.inspect(r))

  r = run("todos.show", { id = id })
  ok("show answers the task with rev, path and file_path",
    r.ok and r.value.id == id and type(r.value.rev) == "string" and type(r.value.path) == "string"
      and r.value.file_path == proj .. "/.todo-list/" .. r.value.path, vim.inspect(r))
  r = run("todos.show", { id = "2026-01-01-no-such-task" })
  ok("show of an unknown id is not_found", r.ok == false and r.code == "not_found", vim.inspect(r))

  r = run("todos.get_dir")
  ok("get_dir answers the store", r.ok and r.value.todo_dir == proj .. "/.todo-list", vim.inspect(r))
  r = run("todos.list_dirs")
  local found
  for _, s in ipairs(r.ok and r.value or {}) do
    if s.todo_dir == proj .. "/.todo-list" then found = s end
  end
  ok("list_dirs lists the store, claimed", found ~= nil and found.claimed == true, vim.inspect(r))
end

-- ─────────────────────────────────────────────────────────────
section("update: hand-editable fields only")
do
  local r = run("todos.update", { id = id, patch = { priority = "high", tags = { "a", "b" } } })
  ok("update changes the fields", r.ok and r.value.priority == "high"
    and vim.deep_equal(r.value.tags, { "a", "b" }), vim.inspect(r))
  r = run("todos.update", { id = id, patch = { assignee = "agent:x" } })
  ok("a patch naming assignee is refused (todos.assign notifies)",
    r.ok == false and r.code == "invalid_args" and r.error:find("todos.assign", 1, true), vim.inspect(r))
  r = run("todos.update", { id = id, patch = { status = "completed" } })
  ok("a patch naming status is refused, pointing at todos.status (the mailbox verb, which the daemon cannot name)",
    r.ok == false and r.code == "invalid_args" and r.error:find("todos.status", 1, true), vim.inspect(r))
  ok("… before anything reaches the daemon", last_params["update"] == nil or
    last_params["update"][4].status == nil, vim.inspect(last_params["update"]))
  local kb = sb .. "/kb"
  vim.fn.mkdir(kb .. "/adrs", "p")
  vim.fn.writefile({ "# adr" }, kb .. "/adrs/0001-x.md")
  r = run("todos.update", { id = id, patch = { adr = { kb .. "/adrs/0001-x.md" } } })
  ok("an absolute adr ref is accepted", r.ok, vim.inspect(r))
  -- A $VAR ref is written with Neovim's meaning of the var: it crosses the
  -- wire absolute, and AutoDoc symbolizes it its own way.
  local home = vim.uv.os_homedir()
  r = run("todos.update", { id = id, patch = { review = { "$HOME/aa-review-x.md" } } })
  local sent_patch = last_params["update"] and last_params["update"][4]
  ok("a $VAR ref crosses the wire absolute (Neovim's vars resolve it)",
    r.ok and sent_patch and sent_patch.review and sent_patch.review[1] == home .. "/aa-review-x.md",
    vim.inspect({ r, sent_patch }))
end

-- ─────────────────────────────────────────────────────────────
section("assign: D1, the notifier is poked, buffers follow")
do
  local cur = run("todos.show", { id = id }).value
  vim.cmd("edit " .. vim.fn.fnameescape(cur.file_path))
  local buf = vim.api.nvim_get_current_buf()
  local s_before, pokes_before = #seen["core.todo.status:changed"], pokes
  sent = {}
  local r = run("todos.assign", { id = id, assignee = "agent:someone", reason = "start here" })
  ok("assign answers the task, assigned", r.ok and r.value.assignee == "agent:someone", vim.inspect(r))
  ok("D1: an open task becomes in-progress in the same write", r.ok and r.value.status == "in-progress")
  ok("… in one todos.assign at the rev just read (get, then assign; no status)",
    count("get") == 1 and count("assign") == 1 and count("status") == 0, vim.inspect(sent))
  ok("the status move was published", #seen["core.todo.status:changed"] == s_before + 1)
  ok("the notifier was asked to poll now", pokes == pokes_before + 1)
  ok("the open buffer follows the file into in-progress/",
    vim.api.nvim_buf_get_name(buf) == r.value.file_path, vim.api.nvim_buf_get_name(buf))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  r = run("todos.assign", { id = id })
  ok("assign with no assignee clears it, and pokes nobody",
    r.ok and r.value.assignee == nil and pokes == pokes_before + 1, vim.inspect(r))
end

-- ─────────────────────────────────────────────────────────────
section("an assignment carries this project's scope (ADR 1791532020 §2.5a)")
do
  -- as auto-agents' setup sets it, from the project key
  local sc = require("auto-core.todo.scope")
  sc.set("auto-agents:spec")
  ok("AutoDoc and auto-core carry a scope here", sc.scoped(), "autodoc.nvim protocol " .. tostring(sc.protocol()))
  local r = run("todos.assign", { id = id, assignee = "agent:someone", reason = "scoped" })
  local p = last_params["assign"]
  ok("assign sends the bare name, the reason and this project's scope, and the daemon takes it",
    r.ok and p and p[4] == "agent:someone" and p[5] == "scoped" and p[6] == "auto-agents:spec", vim.inspect({ r, p }))
  r = run("todos.assign", { id = id, assignee = "agent:someone" })
  p = last_params["assign"]
  ok("… with no reason, an empty one holds the scope's place",
    r.ok and p and p[5] == "" and p[6] == "auto-agents:spec", vim.inspect({ r, p }))
  r = run("todos.add", { title = "Created assigned, scoped", assignee = "agent:someone" })
  p = last_params["add"]
  ok("add with an assignee is an assignment: it sends the scope", r.ok and p and p[3] == "auto-agents:spec",
    vim.inspect({ r, p }))
  r = run("todos.add", { title = "Created unassigned" })
  p = last_params["add"]
  ok("add without one sends none", r.ok and p and p[3] == nil, vim.inspect({ r, p }))
  run("todos.assign", { id = id }) -- cleared, as the sections after expect it
  sc.set(nil)
end

-- ─────────────────────────────────────────────────────────────
section("status, archive, refresh, remove")
do
  local r = run("todos.status", { id = id, status = "automated" })
  ok("status automated is invalid_args (automation was removed)",
    r.ok == false and r.code == "invalid_args", vim.inspect(r))
  sent = {}
  r = run("todos.status", { id = id, status = "in-progress" })
  ok("the same status is a no-op: no write", r.ok and count("status") == 0, vim.inspect(sent))
  r = run("todos.status", { id = id, status = "completed" })
  ok("status completed moves it", r.ok and r.value.status == "completed"
    and r.value.file_path:find("/completed/", 1, true), vim.inspect(r))
  r = run("todos.archive", { id = id })
  ok("archive moves it to archived/YYYY/MM", r.ok and r.value.status == "archived"
    and r.value.file_path:find("/archived/%d%d%d%d/%d%d/") ~= nil, vim.inspect(r))
  r = run("todos.list", { status = "archived" })
  ok("list status=archived reads the archive by month", r.ok and r.value.count == 1
    and r.value.tasks[1].id == id, vim.inspect(r))
  run("todos.add", { title = "Second task" })
  r = run("todos.list", { status = "all" })
  ok("list status=all spans the active buckets and the archive", r.ok and r.value.count == 2, vim.inspect(r))

  local before = #seen["core.todo:refreshed"]
  r = run("todos.refresh")
  ok("refresh answers the daemon's summary", r.ok and type(r.value.scanned) == "number"
    and type(r.value.malformed) == "number", vim.inspect(r))
  ok("refresh published core.todo:refreshed", #seen["core.todo:refreshed"] == before + 1)

  r = run("todos.remove", { id = id })
  ok("remove answers {removed}", r.ok and r.value.removed == id, vim.inspect(r))
  ok("… and the task is gone", run("todos.show", { id = id }).code == "not_found")
end

-- ─────────────────────────────────────────────────────────────
section("an agent's rev: a task changed since the agent read it is refused (Lector #26 r0 P2 1)")
do
  local sid = run("todos.add", { title = "Stale target" }).value.id
  local seen_by_agent = run("todos.show", { id = sid }).value
  -- another client changes the task after the agent read it
  local other = run("todos.update", { id = sid, patch = { priority = "high" } })
  ok("fixture: another client changed the task", other.ok and other.value.rev ~= seen_by_agent.rev,
    vim.inspect(other))
  local r = run("todos.update", { id = sid, rev = seen_by_agent.rev,
    patch = { review = { sb .. "/agents-review.md" } } })
  ok("an update at the agent's old rev is refused as stale", r.ok == false and r.code == "stale",
    vim.inspect(r))
  local now = run("todos.show", { id = sid }).value
  ok("… and the other client's change survived, the stale patch did not land",
    now.priority == "high" and (now.review == nil or #now.review == 0), vim.inspect(now))
  r = run("todos.status", { id = sid, rev = seen_by_agent.rev, status = "deferred" })
  ok("a status at the old rev is refused as stale too", r.ok == false and r.code == "stale", vim.inspect(r))
  r = run("todos.update", { id = sid, rev = now.rev, patch = { priority = "low" } })
  ok("at the current rev the update lands", r.ok and r.value.priority == "low", vim.inspect(r))
  r = run("todos.update", { id = sid, patch = { priority = "normal" } })
  ok("without a rev it still works (the no-rev convenience)", r.ok and r.value.priority == "normal",
    vim.inspect(r))
  r = run("todos.update", { id = sid, rev = 42, patch = { priority = "low" } })
  ok("a rev that is not a string is invalid_args", r.ok == false and r.code == "invalid_args", vim.inspect(r))
  run("todos.remove", { id = sid })
end

-- ─────────────────────────────────────────────────────────────
section("a project switch during any wait: the handler's whole sequence stays on its store (Lector #26 r0 P2 2, r1 P2)")
---switch_during runs fn while a spy switches the workspace root to `to` the
---moment `hook_verb` answers, and records the `at` of every verb sent after it.
local function switch_during(hook_verb, to, fn)
  local switched, after = false, {}
  local spy = ad_todos.call
  ad_todos.call = function(verb, params, cb)
    if switched then after[#after + 1] = { verb = verb, at = params[1] } end
    spy(verb, params, function(r, e)
      if verb == hook_verb and not switched then
        switched = true
        worktree.set_workspace_root(to) -- the user switched projects meanwhile
      end
      cb(r, e)
    end)
  end
  local okr, r = pcall(fn)
  ad_todos.call = spy
  if not okr then r = { ok = false, code = "raised", error = tostring(r) } end
  return r, switched, after
end
---stayed says every verb sent after the switch named `root`'s store.
local function stayed(after, root)
  if #after == 0 then return false end
  for _, a in ipairs(after) do
    if type(a.at) ~= "table" or a.at.root ~= root then return false end
  end
  return true
end
do
  local proj2 = sb .. "/proj-switched"
  vim.fn.mkdir(proj2, "p")
  local function cases(name, hook, fn, check)
    local r, switched, after = switch_during(hook, proj2, fn)
    worktree.set_workspace_root(proj)
    ok(name .. ": fixture — the project switched while " .. hook .. " waited", switched)
    ok(name .. ": the handler answered", r.ok, vim.inspect(r))
    ok(name .. ": every later verb went to the store it started on", stayed(after, proj), vim.inspect(after))
    ok(name .. ": the new project got no store", vim.fn.isdirectory(proj2 .. "/.todo-list") == 0)
    if check then check(r) end
  end

  local sid = run("todos.add", { title = "Bound to its store" }).value.id
  cases("update", "get", function() return run("todos.update", { id = sid, patch = { priority = "high" } }) end,
    function(r) ok("update: … and it landed", r.value and r.value.priority == "high") end)
  cases("status", "get", function() return run("todos.status", { id = sid, status = "deferred" }) end,
    function(r) ok("status: … and it moved", r.value and r.value.status == "deferred") end)
  cases("archive", "get", function() return run("todos.archive", { id = sid }) end,
    function(r) ok("archive: … and it archived", r.value and r.value.status == "archived") end)

  -- add on a project with no store yet: the switch lands as the daemon answers
  -- not_a_store, between the add and the scaffold
  local proj3 = sb .. "/proj-new"
  vim.fn.mkdir(proj3, "p")
  worktree.set_workspace_root(proj3)
  local r, switched, after = switch_during("add", proj2, function()
    return run("todos.add", { title = "Made in proj-new" })
  end)
  worktree.set_workspace_root(proj)
  ok("add: fixture — the project switched after the first add answered", switched)
  ok("add: the handler answered", r.ok, vim.inspect(r))
  ok("add: the scaffold and the retried add went to proj-new's store", stayed(after, proj3)
    and #after == 2, vim.inspect(after))
  ok("add: proj-new has its store and the task", vim.fn.isdirectory(proj3 .. "/.todo-list/open") == 1)
  ok("add: the project switched to got no store", vim.fn.isdirectory(proj2 .. "/.todo-list") == 0)
end

-- ─────────────────────────────────────────────────────────────
section("set_dir: another existing store, then back")
do
  local other = sb .. "/other-store"
  vim.fn.mkdir(other, "p")
  local r = run("todos.set_dir", { path = other })
  ok("set_dir points the project there", r.ok and r.value.todo_dir == other, vim.inspect(r))
  r = run("todos.list")
  ok("… and lists that store (empty)", r.ok and r.value.count == 0, vim.inspect(r))
  -- a project switch while set_dir waits for the daemon: the answer (and the
  -- store it resolves and claims) is the starting project's (Lector #26 r2 P2)
  local proj4 = sb .. "/proj-set-dir-switched"
  vim.fn.mkdir(proj4, "p")
  local r4, switched4, after4 = switch_during("set_dir", proj4, function()
    return run("todos.set_dir", { path = other })
  end)
  worktree.set_workspace_root(proj)
  ok("set_dir: fixture — the project switched while set_dir waited", switched4)
  ok("set_dir: it answers the starting project's store", r4.ok and r4.value.todo_dir == other, vim.inspect(r4))
  local touched = false
  for _, a in ipairs(after4) do
    if a.verb == "register" or (type(a.at) == "table" and a.at.root == proj4) then touched = true end
  end
  ok("set_dir: nothing was resolved, registered or claimed for the project switched to",
    not touched, vim.inspect(after4))
  ok("set_dir: the project switched to got no store", vim.fn.isdirectory(proj4 .. "/.todo-list") == 0)
  r = run("todos.set_dir", { path = sb .. "/does-not-exist" })
  ok("a directory that does not exist is refused", r.ok == false, vim.inspect(r))
  r = run("todos.set_dir", { path = "" })
  ok("an empty path goes back to <root>/.todo-list", r.ok and r.value.todo_dir == proj .. "/.todo-list",
    vim.inspect(r))
end

-- ─────────────────────────────────────────────────────────────
section("without AutoDoc, or with an older auto-core: no fallback")
do
  local real = package.loaded["autodoc.todos"]
  package.loaded["autodoc.todos"] = "unavailable"
  local r = run("todos.list")
  ok("no autodoc.nvim: dependency_unavailable, \"AutoDoc required\"",
    r.ok == false and r.code == "dependency_unavailable" and r.error:find("AutoDoc required", 1, true),
    vim.inspect(r))
  package.loaded["autodoc.todos"] = real

  local real_where = package.loaded["auto-core.todo.where"]
  package.loaded["auto-core.todo.where"] = {}
  r = run("todos.add", { title = "never written" })
  ok("an auto-core without the store resolution: \"update auto-core\"",
    r.ok == false and r.code == "dependency_unavailable" and r.error:find("update auto-core", 1, true),
    vim.inspect(r))
  package.loaded["auto-core.todo.where"] = real_where
end

ok("auto-core.todo was never required (auto-core v0.4.1 removes it)",
  package.loaded["auto-core.todo"] == nil)

ad_todos.call = real_call
pcall(function() require("autodoc.session").stop() end)
vim.system({ "pkill", "-f", "--", "--config " .. cfg }):wait()
vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failed))
io.stdout:flush()
vim.cmd(failed == 0 and "qa!" or "cquit")
