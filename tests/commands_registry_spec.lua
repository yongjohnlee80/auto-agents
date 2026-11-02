-- Headless tests for auto-agents' command verbs on auto-core's command registry
-- (auto-core.commands, auto-core v0.6.0), with no file mailbox. Run:
--   AUTO_CORE_ROOT=<auto-core with auto-core.commands> nvim --headless -u NONE -l tests/commands_registry_spec.lua
--
--   [1] setup's registration (auto-agents.commands.register_every) puts every verb on
--       auto-core.commands, owned by auto-agents, while auto-core.mailbox can't even load
--   [2] a module that fails to load takes only its own verbs down, and says so once
--   [3] admin `run` lists and completes from the same registry
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

-- $AUTO_CORE_ROOT overrides the sibling resolution (see tests/run-all.sh); /main first, never a
-- feature worktree lying around.
local function pick(rel)
  if rel == "auto-core.nvim" and vim.env.AUTO_CORE_ROOT then return vim.env.AUTO_CORE_ROOT end
  for _, wt in ipairs({ "/main", "" }) do
    local p = plugins_root .. "/" .. rel .. wt
    if vim.fn.isdirectory(p .. "/lua") == 1 then return p end
  end
end
for _, p in ipairs({ project_root, pick("auto-core.nvim"), pick("worktree.nvim") }) do
  if p then
    vim.opt.runtimepath:append(p)
    package.path = p .. "/lua/?.lua;" .. p .. "/lua/?/init.lua;" .. package.path
  end
end

local sb = vim.fn.tempname() .. "-cmdreg"
vim.env.XDG_STATE_HOME = sb .. "/state"
vim.env.XDG_CONFIG_HOME = sb .. "/config"
vim.env.XDG_CACHE_HOME = sb .. "/cache"

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

-- No file mailbox: anything that still reaches for it fails loudly here.
for _, m in ipairs({ "auto-core.mailbox", "auto-core.mailbox.commands", "auto-core.mailbox.router",
                     "auto-core.mailbox.transport" }) do
  package.loaded[m] = nil
  package.preload[m] = function() error(m .. " is retired (auto-core v0.6.0)") end
end

local registry = require("auto-core.commands")
local cmds = require("auto-agents.commands")

local TODOS = { "todos.list", "todos.show", "todos.list_dirs", "todos.get_dir", "todos.add", "todos.update",
  "todos.status", "todos.assign", "todos.archive", "todos.remove", "todos.refresh", "todos.set_dir" }
local REVIEW = { "review.create", "review.list", "review.show", "review.validate" }
local ALL = vim.list_extend(vim.list_extend({ "peek", "say", "diff_queue" }, TODOS), REVIEW)

local function listed()
  local by = {}
  for _, e in ipairs(registry.list() or {}) do by[e.name] = e end
  return by
end

local function unregister_every()
  for _, name in ipairs(ALL) do pcall(registry.unregister, name) end
end

io.stdout:write("\n[1] every verb on auto-core.commands, with no mailbox\n")
do
  unregister_every()
  local failed = cmds.register_every()
  ok("[1] no module failed", next(failed) == nil, vim.inspect(failed))
  local by, missing, foreign = listed(), {}, {}
  for _, name in ipairs(ALL) do
    if not by[name] then missing[#missing + 1] = name
    elseif by[name].owner ~= "auto-agents" then foreign[#foreign + 1] = name end
  end
  ok("[1] all 19 verbs are registered", #ALL == 19 and #missing == 0, vim.inspect(missing))
  ok("[1] each is owned by auto-agents", #foreign == 0, vim.inspect(foreign))
  ok("[1] a handler is reached through the registry: peek refuses a bad slot",
    (function()
      local spec = registry.get("peek")
      local r = spec and spec.handler({}, {})
      return type(r) == "table" and r.ok == false and r.code == "invalid_args"
    end)())
  ok("[1] the mailbox never loaded", package.loaded["auto-core.mailbox"] == nil
    and package.loaded["auto-core.mailbox.commands"] == nil)
end

io.stdout:write("\n[2] one module that can't load takes only its own verbs\n")
do
  unregister_every()
  -- a stand-in log: the real one loads auto-core whole, which this cell doesn't need
  local real_log, errors = package.loaded["auto-agents.log"], {}
  package.loaded["auto-agents.log"] = {
    error = function(scope, msg) errors[#errors + 1] = { scope = scope, msg = msg } end,
    warn = function() end, info = function() end, debug = function() end,
  }
  local real_todos = package.loaded["auto-agents.commands.todos"]
  package.loaded["auto-agents.commands.todos"] = nil
  package.preload["auto-agents.commands.todos"] = function() error("todos verbs broken for this cell") end
  local failed = cmds.register_every()
  package.preload["auto-agents.commands.todos"] = nil
  package.loaded["auto-agents.commands.todos"] = real_todos
  package.loaded["auto-agents.log"] = real_log
  local by = listed()
  ok("[2] only the todos module failed", failed["auto-agents.commands.todos"] ~= nil
    and failed["auto-agents.commands"] == nil and failed["auto-agents.commands.review"] == nil, vim.inspect(failed))
  ok("[2] the other modules' verbs are registered", by.peek ~= nil and by.say ~= nil and by.diff_queue ~= nil
    and by["review.list"] ~= nil)
  ok("[2] no todos verb is registered", by["todos.list"] == nil)
  ok("[2] it was said once, naming the module", #errors == 1
    and errors[1].msg:find("auto-agents.commands.todos", 1, true) ~= nil, vim.inspect(errors))
end

io.stdout:write("\n[3] admin run reads the same registry\n")
do
  unregister_every()
  cmds.register_every()
  local admin = require("auto-agents.panel.admin")
  local _, cands = admin._complete_at("run ", 4)
  ok("[3] `run ` completes the registry's verbs", vim.tbl_contains(cands, "peek")
    and vim.tbl_contains(cands, "todos.list") and vim.tbl_contains(cands, "review.show"), vim.inspect(cands))
end

unregister_every()
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
