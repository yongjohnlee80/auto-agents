--- Tests for status.observer's model-drift sync (auto-agents.status.observer).
--- Run with: AUTO_CORE_ROOT=<path> nvim --headless -u NONE -l tests/observer_model_drift_spec.lua
---
--- Why this suite exists: dropping codex's model option made agent.set_model
--- refuse a codex slot, and check_model_drift called it anyway on every model
--- tick (MODEL_CHECK_TICKS, ~7.5s). The call failed, "model sync failed" was
--- notified at WARN, and last_synced_model was never set — so it repeated for
--- the life of the session. Found by Virtue reviewing PR #28's addendum.

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")
local core_root = vim.env.AUTO_CORE_ROOT or (plugins_root .. "/auto-core.nvim/main")
if not vim.env.AUTO_CORE_ROOT and vim.fn.isdirectory(core_root) == 0 then
  core_root = plugins_root .. "/auto-core.nvim"
end
for _, p in ipairs({ project_root, core_root }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

local pass_count, fail_count = 0, 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

local observer = require("auto-agents.status.observer")

-- Stand in for the live roster: slot 2 is codex with no model (config.store
-- drops it), slot 1 is claude with a stale one.
package.loaded["auto-agents"] = {
  state = { config = { agents = { bootstrap = {
    { slot = 1, kind = "claude", name = "exia",   model = "claude-opus-4-7" },
    { slot = 2, kind = "codex",  name = "virtue", model = nil },
  } } } },
}

-- The TUI always parses as running gpt-6-sol / claude-opus-5.
local running_by_kind = { codex = "gpt-6-sol", claude = "claude-opus-5" }
package.loaded["auto-agents.status.model_reader"] = {
  read = function(_bufnr, kind) return { api_id = running_by_kind[kind] } end,
}

local notices = {}
package.loaded["auto-agents.log"] = {
  notify = function(msg, opts) notices[#notices + 1] = { msg = msg, level = (opts or {}).level } end,
  warn = function(_, msg) notices[#notices + 1] = { msg = msg, level = "warn" } end,
  info = function() end,
  debug = function() end,
}

local set_model_calls = {}
package.loaded["auto-agents.agent"] = {
  set_model = function(name, model)
    set_model_calls[#set_model_calls + 1] = { name = name, model = model }
    if name == "virtue" then
      return false, "virtue is a codex slot, which has no model option"
    end
    return true, name .. " → " .. model
  end,
}

local function warns()
  local n = 0
  for _, x in ipairs(notices) do if x.level == "warn" then n = n + 1 end end
  return n
end

print("\n[1] codex drift is observed, never synced, and never repeats")

local codex_obs = { slot = 2, bufnr = 1, kind = "codex", last_synced_model = nil }
observer._check_model_drift(codex_obs)

ok("set_model is not called for a codex slot", #set_model_calls == 0,
  vim.inspect(set_model_calls))
ok("no warning is emitted", warns() == 0, vim.inspect(notices))
ok("the observed model is recorded, so the check settles",
  codex_obs.last_synced_model == "gpt-6-sol", tostring(codex_obs.last_synced_model))
ok("the user is told once where the model comes from",
  #notices == 1 and notices[1].msg:find("codex has no model option", 1, true) ~= nil,
  vim.inspect(notices))

-- The regression was the REPEAT: 7.5s apart, forever.
local before = #notices
for _ = 1, 5 do observer._check_model_drift(codex_obs) end
ok("five further ticks emit nothing and call nothing",
  #notices == before and #set_model_calls == 0,
  string.format("notices %d→%d, set_model %d", before, #notices, #set_model_calls))

print("\n[2] the other kinds still sync, so the guard is not a blanket skip")

notices, set_model_calls = {}, {}
local claude_obs = { slot = 1, bufnr = 2, kind = "claude", last_synced_model = nil }
observer._check_model_drift(claude_obs)

ok("set_model is called for a claude slot",
  #set_model_calls == 1 and set_model_calls[1].name == "exia"
    and set_model_calls[1].model == "claude-opus-5",
  vim.inspect(set_model_calls))
ok("a successful sync records it", claude_obs.last_synced_model == "claude-opus-5",
  tostring(claude_obs.last_synced_model))
ok("and notifies without warning", warns() == 0 and #notices == 1, vim.inspect(notices))

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)
