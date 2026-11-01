#!/usr/bin/env bash
# tests/crew_fallback_mutants.sh — every rule of auto-agents.crew's part in AutoDoc's fallback
# (r15 P4) must be load-bearing in tests/crew_fallback_spec.lua.
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to
# FAIL. The unmutated copy must pass first, and each mutation must match
# exactly once (a no-op mutant would read as killed on an unrelated red).
#
# The spec fakes the file mailbox, but crew.lua loads beside auto-core: AUTO_CORE_ROOT, as for
# tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/crew_fallback_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

run_suite() { (cd "$1" && timeout 180 nvim --headless -u NONE -l tests/crew_fallback_spec.lua 2>&1); }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

C=lua/auto-agents/crew.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$C|filed twice: the file not read as the record|  if transport.message_state(to, job.id) then return \"delivered\" end|  if false then return \"delivered\" end"
  "$C|an older daemon asked: the protocol gate dropped|  return (tonumber(h.protocol) or 0) >= M.FALLBACK_PROTOCOL and (not c.can or c:can(\"mail.fallbacks\"))|  return true"
  "$C|silent on delivery|    st.notify((\"%s couldn't be woken: AutoDoc put %s's message in its mailbox\"):format(job.codename, tostring(job.from)),\n      vim.log.levels.INFO)|    local _ = job.from"
  "$C|a failed filing reported delivered|  if err then return \"unknown\", tostring(err) end|  if err then return \"delivered\" end"
  "$C|a lost epoch asked again|      if c == M.CODE_METHOD_NOT_FOUND or c == M.CODE_STALE_EPOCH then return end|      if c == M.CODE_METHOD_NOT_FOUND then return end"
  "$C|never asked again after a job|    later(st, a, 0, function() poll_fallbacks(st, a) end) -- off this answer: the next poll waits on the daemon|    local _ = a"
  "$C|filed under a new id, not the job's|  local _, err = transport.send({ id = job.id, from = M.FALLBACK_FROM, to = to, kind = \"message\",|  local _, err = transport.send({ from = M.FALLBACK_FROM, to = to, kind = \"message\","
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
