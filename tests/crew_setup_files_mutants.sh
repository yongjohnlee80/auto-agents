#!/usr/bin/env bash
# tests/crew_setup_files_mutants.sh — a crew setup's file that can't be written refuses the spawn
# (aa._apply_setup_files, crew.begin's refusal, crew.lua's write_private): every rule must be
# load-bearing in tests/crew_sessions_spec.lua [24].
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to FAIL. The unmutated copy
# must pass first, and each mutation must match exactly once (a no-op mutant would read as killed on
# an unrelated red).
#
# AUTO_CORE_ROOT, as for tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/crew_setup_files_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

run_suite() {
  out="$(cd "$1" && timeout 300 nvim --headless -u NONE -l tests/crew_sessions_spec.lua 2>&1)"
  printf '%s\n' "$out" | grep -E '^  FAIL' | head -3
  printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1 | sed "s/^/crew_sessions_spec: /"
  printf '%s\n' "$out" | grep -qE '[0-9]+ passed, [0-9]+ failed' || echo "crew_sessions_spec: aborted"
}
green() { [ "$(printf '%s\n' "$1" | grep -cE ': [0-9]+ passed, 0 failed$')" = 1 ]; }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
if ! green "$out"; then
  echo "BASELINE NOT GREEN:"; printf '%s\n' "$out"; exit 1
fi
echo "baseline: $(printf '%s\n' "$out" | grep passed | tr '\n' ' ')"

I=lua/auto-agents/init.lua
C=lua/auto-agents/crew.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$I|a setup file's write error ignored: the spawn goes on|  if not why then return true end\n  crew.finish(crew_session, \"start_failed\")|  if true then return true end\n  crew.finish(crew_session, \"start_failed\")"
  "$I|the refused spawn keeps its session|  if not why then return true end\n  crew.finish(crew_session, \"start_failed\")|  if not why then return true end"
  "$I|the refusal says nothing|  vim.notify((\"%s did not start: its setup's files could not be written: %s\"):format(spec.name, why), vim.log.levels.ERROR,\n    { title = \"auto-agents\" })\n  return false|  local _ = why\n  return false"
  "$C|the error doesn't name the file|    if why then return path .. \": \" .. why end|    if why then return why end"
  "$C|the temporary file left after a failed rename|  vim.uv.fs_unlink(tmp)\n  return tostring(werr)\nend|  return tostring(werr)\nend"
  "$C|a context file that can't be written deferred, not refused|    return nil, \"its session context could not be written: \" .. tostring(werr), true -- here, not the daemon: refused|    return nil, \"its session context could not be written: \" .. tostring(werr)"
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
