#!/usr/bin/env bash
# tests/crew_fallback_mutants.sh — every rule of the fallback (auto-agents.crew's part in AutoDoc's
# fallback, r15 P4, and auto-agents.fallback's typing, v0.4.0) must be load-bearing in
# tests/crew_fallback_spec.lua or tests/fallback_spec.lua.
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to
# FAIL. The unmutated copy must pass first, and each mutation must match
# exactly once (a no-op mutant would read as killed on an unrelated red).
#
# The specs fake the typing and the terminals, but crew.lua loads beside auto-core: AUTO_CORE_ROOT, as for
# tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/crew_fallback_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

# both specs; the summary is the worse of the two (a mutant is killed by either)
run_suite() {
  (cd "$1" && for spec in tests/crew_fallback_spec.lua tests/fallback_spec.lua; do
    timeout 180 nvim --headless -u NONE -l "$spec" 2>&1 || echo "0 passed, 1 failed (exit $?)"
  done) | awk '/[0-9]+ passed, [0-9]+ failed/ { split($0, a, ", "); n = a[2] + 0; if (n > worst) worst = n; seen = 1; next } { print }
    END { if (seen) printf "%d passed, %d failed\n", 0, worst }'
}

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

C=lua/auto-agents/crew.lua
F=lua/auto-agents/fallback.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$C|an older daemon asked: the protocol gate dropped|  return (tonumber(h.protocol) or 0) >= M.FALLBACK_PROTOCOL and (not c.can or c:can(\"mail.fallbacks\"))|  return true"
  "$C|silent on delivery|    st.notify((\"%s couldn't be woken: AutoDoc's message from %s was typed into its terminal\"):format(job.codename,\n      tostring(job.from)), vim.log.levels.INFO)|    local _ = job.from"
  "$C|a failed typing reported delivered|  if not ok then return \"unknown\", why end|  if not ok then return \"delivered\" end"
  "$C|typed under another key than the job's id|  local ok, why = type_once(job.codename, job.id, job.text)|  local ok, why = type_once(job.codename, job.lease, job.text)"
  "$C|a lost epoch asked again|      if c == M.CODE_METHOD_NOT_FOUND or c == M.CODE_STALE_EPOCH then return end|      if c == M.CODE_METHOD_NOT_FOUND then return end"
  "$C|never asked again after a job|    later(st, a, 0, function() poll_fallbacks(st, a) end) -- off this answer: the next poll waits on the daemon|    local _ = a"
  "$F|typed twice: a typed key not read|  if seen[key] then return true end|  if false then return true end"
  "$F|the key not kept: a restart types again|  seen[key] = true\n  _order[#_order + 1] = key\n  if not save() then|  if false then"
  "$F|no slot keeps the key|  if not slot then return false, (\"no slot runs %s\"):format(tostring(codename)) end|  if not slot then seen[key] = true; _order[#_order + 1] = key; save(); return false, \"no slot\" end"
  "$F|a refused key kept|    seen[key] = nil -- nothing was typed: it may be typed later\n    save()|    local _ = nil"
  "$F|Esc may follow: the submit keys dropped|  if not aa.send_slot(slot, line, { submit = true, submit_keys = { \"<CR>\" } }) then|  if not aa.send_slot(slot, line, { submit = true }) then"
  "$F|no hazard prefix|  if s:match(\"^[%[/%\$]\") then s = M.PREFIX .. s end|  local _ = s"
  "$F|not sanitized: line breaks and controls typed|  local s = require(\"auto-agents.sanitize\").sanitize(text, M.MAX_TEXT)|  local s = type(text) == \"string\" and text ~= \"\" and text or nil"
  "$F|another instance's agent typed|    if ok and inst ~= instance then return false, \"another Neovim's agent\" end|    local _ = inst"
  "$F|pruning keeps the oldest|    keys = vim.list_slice(keys, #keys - M.MAX_KEYS + 1)|    keys = vim.list_slice(keys, 1, M.MAX_KEYS)"
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
