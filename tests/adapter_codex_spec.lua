--- Tests for Codex adapter MCP consumption
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

print("\n[1] Codex Adapter Argv")

-- Test case 1: diff_review = false
local spec_no_review = {
  kind = "codex",
  diff_review = false
}
local argv1 = codex.cmd(spec_no_review)
local has_mcp1 = false
for _, v in ipairs(argv1) do
  if v:find("mcp_servers") then has_mcp1 = true end
end
ok("diff_review=false does not include MCP config override", not has_mcp1)

-- Test case 2: diff_review = true
local spec_review = {
  kind = "codex",
  diff_review = true
}
local argv2 = codex.cmd(spec_review)
local has_mcp2 = false
for _, v in ipairs(argv2) do
  if v:find("mcp_servers") then has_mcp2 = true end
end
ok("diff_review=true uses env/lockfile, not -c MCP override", not has_mcp2)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
