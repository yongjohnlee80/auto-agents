#!/usr/bin/env bash
# tests/codex_daemon_mutants.sh — every rule of auto-agents.codex_daemon (item 14 B: a Codex agent
# with no crew setup is kept off Codex's shared daemon) must be load-bearing in
# tests/codex_daemon_spec.lua. Copies the tree, applies ONE mutation, runs the spec, and requires it
# to FAIL; the unmutated copy must pass first, and each mutation must match exactly once. VM43 only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
run_suite() { (cd "$1" && timeout 180 nvim --headless -u NONE -l tests/codex_daemon_spec.lua 2>&1); }
cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"
F=lua/auto-agents/codex_daemon.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$F|unknown taken as a Codex before the flag|  if has == nil then\n    return nil,|  if has == nil then\n    do return {} end\n    return nil,"
  "$F|a failure kept|  local help, why = run(bin, \"--help\", env, cwd)\n  if not help then return nil, why end|  local help, why = run(bin, \"--help\", env, cwd)\n  if not help then if key then _known[key] = false end return nil, why end"
  "$F|kept by the binary alone, not its version|    key = table.concat({ bin, tostring(st.mtime.sec), tostring(st.mtime.nsec), vim.trim(version) }, \"\\0\")|    key = table.concat({ bin, tostring(st.mtime.sec), tostring(st.mtime.nsec) }, \"\\0\")"
  "$F|the agent's env not used|    return vim.system({ bin, arg }, { cwd = cwd, env = env, text = true, timeout = M.TIMEOUT_MS }):wait()|    return vim.system({ bin, arg }, { cwd = cwd, text = true, timeout = M.TIMEOUT_MS }):wait()"
  "$F|unbounded|    return vim.system({ bin, arg }, { cwd = cwd, env = env, text = true, timeout = M.TIMEOUT_MS }):wait()|    return vim.system({ bin, arg }, { cwd = cwd, env = env, text = true }):wait()"
  "$F|--remote not skipped|    if a == M.FLAG or a == \"--remote\" or vim.startswith(a, \"--remote=\") then return {} end|    if a == M.FLAG then return {} end"
)
killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  file="${m%%|*}"; rest="${m#*|}"; name="${rest%%|*}"; rest="${rest#*|}"; old="${rest%%|*}"; new="${rest#*|}"
  i=$((i + 1)); dir="$WORK/m$i"; cp -r "$SRC" "$dir"
  if ! python3 - "$dir/$file" "$old" "$new" <<'PY'
import sys
p = sys.argv[1]; old = sys.argv[2].replace("\\n", "\n"); new = sys.argv[3].replace("\\n", "\n")
s = open(p).read(); n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue; fi
  out="$(run_suite "$dir")"
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then echo "SURVIVED     $name"; survived=$((survived + 1))
  else echo "KILLED       $name  (${summary:-aborted})"; killed=$((killed + 1)); fi
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
