--- Tests for Codex adapter argv: no -c MCP override (post-v0.2.5) and no
--- --model (codex rejects the configured ids, so the flag was dropped).
--- Run with: nvim --headless -u NONE -l tests/adapter_codex_spec.lua

-- Find our own path to derive project roots
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

for _, p in ipairs({
  project_root,
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

local codex = require("auto-agents.agent.adapters.codex")

local pass_count = 0
local fail_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

print("\n[1] Codex Adapter Argv — no -c MCP override (v0.2.5)")

-- v0.2.5: codex adapter no longer injects `-c mcp_servers.auto-agents=...`.
-- The CLI-side registration caused codex to error out on spawn when the
-- bridge wasn't reachable; users register the bridge in ~/.codex/config.toml
-- themselves if they want it. Both diff_review modes should now produce
-- argv with no `mcp_servers` entry and no `-c` flag pointing at one.

local function has_mcp(argv)
  for i, v in ipairs(argv) do
    if v:find("mcp_servers") then return true end
    if v == "-c" and argv[i + 1] and argv[i + 1]:find("mcp_servers") then return true end
  end
  return false
end

local argv1 = codex.cmd({ kind = "codex", diff_review = false })
ok("diff_review=false does not include MCP config", not has_mcp(argv1))

local argv2 = codex.cmd({ kind = "codex", diff_review = true })
ok("diff_review=true does not include MCP config", not has_mcp(argv2))

print("\n[2] Codex Adapter Argv — no --model injection")

-- Codex rejects the model ids this config carries, so the adapter passes no
-- --model at all: a `model` in the TOML is roster metadata for a codex slot.
-- A model is pinned with an explicit `cmd` instead.

local function index_of(argv, want)
  for i, v in ipairs(argv) do
    if v == want then return i end
  end
  return nil
end

local bare = codex.cmd({ kind = "codex", name = "virtue" })
ok("bare spec is exactly {codex}",
  #bare == 1 and bare[1] == "codex",
  "got: " .. table.concat(bare, " "))

for _, model in ipairs({ "gpt-5-codex", "GPT-5-Codex", "o3" }) do
  local argv = codex.cmd({ kind = "codex", name = "virtue", model = model })
  ok("model=" .. model .. " adds no --model",
    index_of(argv, "--model") == nil and index_of(argv, "-m") == nil,
    "got: " .. table.concat(argv, " "))
  ok("model=" .. model .. " does not leak the id into argv",
    index_of(argv, model) == nil,
    "got: " .. table.concat(argv, " "))
end

-- An explicit cmd is the supported way to pin a model, and is returned
-- verbatim (and copied, so the config-owned table cannot be mutated).
local override = { "codex", "-m", "gpt-5-codex" }
local argv_override = codex.cmd({ kind = "codex", cmd = override, model = "ignored" })
ok("explicit cmd is returned verbatim",
  table.concat(argv_override, " ") == "codex -m gpt-5-codex",
  "got: " .. table.concat(argv_override, " "))
argv_override[#argv_override + 1] = "mutated"
ok("explicit cmd is copied, not aliased", #override == 3, "override was mutated")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
