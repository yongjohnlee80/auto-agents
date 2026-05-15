--- Tests for Codex adapter argv (post-v0.2.5: no -c MCP override).
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

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
