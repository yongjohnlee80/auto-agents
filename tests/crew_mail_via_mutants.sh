#!/usr/bin/env bash
# tests/crew_mail_via_mutants.sh — every rule of a session's mail mode (crew.register's mail_via,
# `crew setup --mail-via mcp`, protocol 43) must be load-bearing in tests/crew_sessions_spec.lua.
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to
# FAIL. The unmutated copy must pass first, and each mutation must match
# exactly once (a no-op mutant would read as killed on an unrelated red).
#
# AUTO_CORE_ROOT, as for tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/crew_mail_via_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

run_suite() { (cd "$1" && timeout 180 nvim --headless -u NONE -l tests/crew_sessions_spec.lua 2>&1); }

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
  "$C|mail_via dropped at registration|    params[9], params[10] = r.prompts == true, r.mail_via|    params[9] = r.prompts == true"
  "$C|mail_via sent to an older daemon|  local mail_via = (opts.mail_via == \"cli\" or opts.mail_via == \"mcp\") and (tonumber(h.protocol) or 0) >= M.PROTOCOL_MAIL_VIA|  local mail_via = (opts.mail_via == \"cli\" or opts.mail_via == \"mcp\")"
  "$C|prompts dropped when mail_via goes|    params[9], params[10] = r.prompts == true, r.mail_via|    params[9], params[10] = r.prompts or nil, r.mail_via"
  "$C|--mail-via never passed|  if mail_via == \"mcp\" then vim.list_extend(argv, { \"--mail-via\", \"mcp\" }) end|  if false then vim.list_extend(argv, { \"--mail-via\", \"mcp\" }) end"
  "$C|the answer's mail_via not kept|    notices = list(s.notices), after = list(s.after), mail_via = mv }|    notices = list(s.notices), after = list(s.after) }"
  "$C|offered from any daemon|  return (tonumber(h.protocol) or 0) >= M.PROTOCOL_MAIL_VIA|  return true"
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
