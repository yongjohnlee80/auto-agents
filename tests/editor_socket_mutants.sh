#!/usr/bin/env bash
# tests/editor_socket_mutants.sh — every rule of the editor socket's start-up
# sweep must be load-bearing in tests/editor_socket_spec.lua.
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to
# FAIL. The unmutated copy must pass first, and each mutation must match
# exactly once (a no-op mutant would read as killed on an unrelated red).
#
# Needs AUTO_CORE_ROOT, as for tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/editor_socket_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

run_suite() { (cd "$1" && timeout 180 nvim --headless -u NONE -l tests/editor_socket_spec.lua 2>&1); }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

E=lua/auto-agents/editor_socket.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$E|start: no sweep|  M.sweep(dir)\n  local path|  local path"
  "$E|held: a live pid is enough, whatever it runs|  return comm:match(\"^nvim\") ~= nil|  return true"
  "$E|held: a dead pid still holds its socket|  if name == \"ESRCH\" then return false end|  if false then return false end"
  "$E|held: nothing holds a socket|  local _, _, name = vim.uv.kill(pid, 0)|  do return false end\n  local _, _, name = vim.uv.kill(pid, 0)"
  "$E|sweep: any file, not only sockets|    if pid and pid ~= own and kind == \"socket\" and not held(pid) then|    if pid and pid ~= own and not held(pid) then"
  "$E|sweep: any name|    local pid = tonumber(name:match(\"^editor%-(%d+)%.sock$\"))|    local pid = tonumber(name:match(\"(%d+)\")) or 1"
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
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name  (${summary:-aborted})"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -3 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
