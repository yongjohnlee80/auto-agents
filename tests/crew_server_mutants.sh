#!/usr/bin/env bash
# tests/crew_server_mutants.sh — every rule of a crew agent's own folder and server (`crew setup
# --agent-dir`, auto-agents.crew_server: a Codex agent's own app-server, run as AutoDoc's window runs
# it) must be load-bearing in tests/crew_server_spec.lua or tests/crew_sessions_spec.lua [20].
#
# Copies the tree, applies ONE mutation, runs both specs, and requires one to FAIL. The unmutated
# copy must pass first, and each mutation must match exactly once (a no-op mutant would read as
# killed on an unrelated red).
#
# AUTO_CORE_ROOT, as for tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/crew_server_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

# both suites' summaries, one line each
run_suite() {
  for s in crew_server_spec crew_sessions_spec; do
    out="$(cd "$1" && timeout 300 nvim --headless -u NONE -l tests/$s.lua 2>&1)"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -3
    printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1 | sed "s/^/$s: /"
    printf '%s\n' "$out" | grep -qE '[0-9]+ passed, [0-9]+ failed' || echo "$s: aborted"
  done
}
green() { [ "$(printf '%s\n' "$1" | grep -cE ': [0-9]+ passed, 0 failed$')" = 2 ]; }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
if ! green "$out"; then
  echo "BASELINE NOT GREEN:"; printf '%s\n' "$out"; exit 1
fi
echo "baseline: $(printf '%s\n' "$out" | grep passed | tr '\n' ' ')"

C=lua/auto-agents/crew.lua
S=lua/auto-agents/crew_server.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$S|the server in Neovim's own group|    detached = true, -- its own session and process group: stopped whole, never Neovim's|    detached = false,"
  "$S|no SIGKILL to the group after its leader ends|  -- the leader's end isn't its group's: a child that outlived the SIGTERM is killed too\n  vim.uv.kill(-h.pid, \"sigkill\")\n|"
  "$S|a stale pid stopped whatever it now is|    if cmdline and cmdline:find(socket, 1, true) then|    if true then"
  "$S|no stale server stopped|  M.stop_stale(pid_file, socket)\n  local h = { pid_file = pid_file, exited = false }|  local h = { pid_file = pid_file, exited = false }"
  "$S|the server's end kills nothing|  h.on_exit = function() kill() end|  h.on_exit = function() end"
  "$S|a stopped server's end still kills|  h.on_exit = nil -- its end, from here on, is this stop's|  local _ = nil"
  "$S|an early end waited out as no listening|  if h.exited then\n    M.stop(h)\n    return nil, (\"the agent's server (%s) ended before it listened on %s\"):format(argv[1], socket)\n  end|"
  "$S|the pid file kept after a stop|  vim.uv.fs_unlink(h.pid_file)\nend|end"
  "$S|the grants left on the agent's command|  return vim.list_slice(cmd, 1, n - g), out|  return cmd, out"
  "$S|the writable roots not given the server|    vim.list_extend(out, { \"-c\", \"sandbox_workspace_write.writable_roots=[\" .. table.concat(items, \", \") .. \"]\" })|    local _ = items"
  "$S|the sandbox mode not given the server|  if mode then vim.list_extend(out, { \"-c\", \"sandbox_mode=\" .. toml_string(mode) }) end|"
  "$S|a quote in a path left unescaped|    if c == '\"' then return '\\\\\"' end|    if c == '\"' then return '\"' end"
  "$C|--agent-dir never passed|  if type(agent_dir) == \"string\" and agent_dir ~= \"\" then vim.list_extend(argv, { \"--agent-dir\", agent_dir }) end|"
  "$C|the setup kept across folders|    mail_via or \"\", agent_dir or \"\" }, \"\\0\")|    mail_via or \"\" }, \"\\0\")"
  "$C|the server not kept|    server = list(s.server), server_socket|    server = {}, server_socket"
  "$C|a folder with no scope held|  if not scope then return nil, \"no crew scope held\" end|  scope = scope or \"none\""
  "$C|a setup file's path out of the folder written|    if type(rel) ~= \"string\" or rel == \"\" or rel:sub(1, 1) == \"/\" or vim.list_contains(vim.split(rel, \"/\", { plain = true }), \"..\") then|    if type(rel) ~= \"string\" or rel == \"\" then"
)

killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  file="${m%%|*}"; rest="${m#*|}"
  name="${rest%%|*}"; rest="${rest#*|}"
  old="${rest%%|*}"; new="${rest#*|}"
  i=$((i + 1)); dir="$WORK/m$i"
  cp -r "$SRC" "$dir"
  if ! python3 - "$dir/$file" "$old" "$new" <<'PY'
import sys
p = sys.argv[1]
old = sys.argv[2].replace("\\n", "\n")
new = sys.argv[3].replace("\\n", "\n")
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir")"
  if green "$out"; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name"
    printf '%s\n' "$out" | grep -E '^  FAIL|aborted' | head -3 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
