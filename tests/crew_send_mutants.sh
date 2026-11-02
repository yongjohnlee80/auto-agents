#!/usr/bin/env bash
# tests/crew_send_mutants.sh — every rule of auto-agents' crew send (phase 7: the todo notifier's crew
# hook, and todos.assign's "Assigned by") must be load-bearing in its spec.
#
# Copies the tree, applies ONE mutation, runs the mutation's spec, and requires it to FAIL. Each
# spec's unmutated copy must pass first, and each mutation must match exactly once (a no-op mutant
# would read as killed on an unrelated red).
#
# crew_send_spec fakes the daemon; todos_daemon_spec runs a real one (AA_TEST_AUTODOC and
# AA_TEST_AUTODOC_BIN, as tests/run-all.sh) and auto-core (AUTO_CORE_ROOT). Run on VM43:
#   AUTO_CORE_ROOT=<auto-core> AA_TEST_AUTODOC=<autodoc> AA_TEST_AUTODOC_BIN=<bin> bash tests/crew_send_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

run_suite() { (cd "$1" && timeout 300 nvim --headless -u NONE -l "tests/$2.lua" 2>&1); }
green() { [ -n "$1" ] && [ "${1##*, }" = "0 failed" ]; }

cp -r "$SRC" "$WORK/base"
for spec in crew_send_spec todos_daemon_spec; do
  out="$(run_suite "$WORK/base" "$spec")"
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if ! green "$summary"; then
    echo "BASELINE NOT GREEN ($spec): ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
  fi
  echo "baseline $spec: $summary"
done

C=lua/auto-agents/crew.lua
T=lua/auto-agents/commands/todos.lua
# spec|file|name|old|new — literal strings (\n = newline); old must occur exactly once.
mutants=(
  "crew_send_spec|$C|the hook never registered|    pcall(notifier.set_crew_recipient, M.crew_send)|    local _ = notifier"
  "crew_send_spec|$C|handed over counted not sent|  if c == M.CODE_HANDED_OVER then return true end|  if c == M.CODE_HANDED_OVER then return false end"
  "crew_send_spec|$C|a certain refusal retried|  if certain(c) then return false end|  if false then return false end"
  "crew_send_spec|$C|an unknown answer counted refused|  return \"retry\"\nend\n\n---_run_for_tests|  return false\nend\n\n---_run_for_tests"
  "crew_send_spec|$C|unscoped sent by the bare name|  if type(how) == \"table\" and how.unscoped then|  if false then"
  "crew_send_spec|$C|two live profiles: one picked|    if #found ~= 1 then return false end|    if #found == 0 then return false end"
  "crew_send_spec|$C|an offline profile counted live|e.codename == name and e.presence == \"live\" and|e.codename == name and"
  "crew_send_spec|$C|a fresh key, not mid|{ to }, msg.body, mid, msg.kind|{ to }, msg.body, mid .. tostring(vim.uv.hrtime()), msg.kind"
  "crew_send_spec|$C|a crew.list refusal retried|      if certain(code(lerr)) then return false end|      local _ = lerr"
  "crew_send_spec|$C|sent with no scope held|  if not st or not scope or type(name)|  if not st or type(name)"
  "todos_daemon_spec|$T|Assigned by dropped|  local by = who ~= \"\" and assigned_by(ctx) or nil|  local by = nil"
)

killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  spec="${m%%|*}"; rest="${m#*|}"
  file="${rest%%|*}"; rest="${rest#*|}"
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
  out="$(run_suite "$dir" "$spec")"
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if green "$summary"; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name  (${summary:-aborted})"
    printf '%s\n' "$out" | grep -aE '^ *FAIL' | head -3 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
