--- Tests for spawn-time permission argv (auto-agents.permissions).
--- Run with: nvim --headless -u NONE -l tests/permissions_spec.lua
---
--- The codex case is the reason this suite exists: `--add-dir` alone is
--- SILENTLY DISCARDED by codex unless the sandbox policy allows extra
--- writable roots, so the grant must ship `-s workspace-write` with it —
--- except where the user's own `cmd` already chose a policy.

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
if vim.fn.isdirectory(project_root) == 1 then
  vim.opt.runtimepath:prepend(project_root)
end

local perms = require("auto-agents.permissions")

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

local MB = "/tmp/mb/agent"
local KB = "/tmp/kb"

local function joined(argv) return table.concat(argv, " ") end

local function contains(argv, want)
  for _, v in ipairs(argv) do
    if v == want then return true end
  end
  return false
end

local function count(argv, want)
  local n = 0
  for _, v in ipairs(argv) do
    if v == want then n = n + 1 end
  end
  return n
end

print("\n[1] codex — the grant carries the policy that enables it")

local g = perms.argv_for_kind("codex", { MB, KB })
ok("sandbox policy comes first, then every dir",
  joined(g) == "-s workspace-write --add-dir " .. MB .. " --add-dir " .. KB,
  "got: " .. joined(g))
ok("one -s only", count(g, "-s") == 1, "got: " .. joined(g))

print("\n[2] codex — an explicit sandbox choice in cmd wins")

for _, cmd in ipairs({
  { "codex", "-s", "workspace-write" },
  { "codex", "--sandbox", "danger-full-access" },
  { "codex", "-s", "read-only" },
  { "codex", "--dangerously-bypass-approvals-and-sandbox" },
  { "codex", "-c", "sandbox_mode=workspace-write" },
  { "codex", "-c", "sandbox_permissions=[\"disk-full-read-access\"]" },
}) do
  local out = perms.argv_for_kind("codex", { MB }, cmd)
  ok("cmd '" .. joined(cmd) .. "' gets no added policy",
    joined(out) == "--add-dir " .. MB,
    "got: " .. joined(out))
end

local plain = perms.argv_for_kind("codex", { MB }, { "codex", "--model", "o3" })
ok("a cmd with no sandbox flag still gets the policy",
  joined(plain) == "-s workspace-write --add-dir " .. MB,
  "got: " .. joined(plain))

print("\n[3] nothing granted — nothing widened")

ok("no dirs → empty argv (no bare -s)",
  #perms.argv_for_kind("codex", {}) == 0,
  "got: " .. joined(perms.argv_for_kind("codex", {})))
ok("nil dirs → empty argv",
  #perms.argv_for_kind("codex", nil) == 0)
ok("dirs of only empty strings → empty argv",
  #perms.argv_for_kind("codex", { "", "" }) == 0)

print("\n[4] the other kinds are untouched")

local c = perms.argv_for_kind("claude", { MB, KB })
ok("claude: --add-dir pairs only",
  joined(c) == "--add-dir " .. MB .. " --add-dir " .. KB,
  "got: " .. joined(c))
ok("claude: no sandbox flag", not contains(c, "-s"), "got: " .. joined(c))

local a = perms.argv_for_kind("antigravity", { MB })
ok("antigravity: --add-dir pair only",
  joined(a) == "--add-dir " .. MB, "got: " .. joined(a))

ok("unsupported kind → empty argv", #perms.argv_for_kind("goose", { MB }) == 0)
ok("nil kind → empty argv", #perms.argv_for_kind(nil, { MB }) == 0)
ok("supported() still reports the three", perms.supported("codex")
  and perms.supported("claude") and perms.supported("antigravity")
  and not perms.supported("goose"))
ok("supported_kinds() is sorted",
  joined(perms.supported_kinds()) == "antigravity claude codex",
  "got: " .. joined(perms.supported_kinds()))

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
