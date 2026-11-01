#!/usr/bin/env bash
# tests/crew_inbox_mutants.sh — every rule of auto-agents.crew_inbox, the human's crew inbox in
# Neovim (ADR 1793271500 §4.8), must be load-bearing in tests/crew_inbox_spec.lua.
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to
# FAIL. The unmutated copy must pass first, and each mutation must match
# exactly once (a no-op mutant would read as killed on an unrelated red).
#
# crew_inbox.lua needs no auto-core: the spec fakes autodoc.session. Run on VM43:
#   bash tests/crew_inbox_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_suite() { (cd "$1" && timeout 180 nvim --headless -u NONE -l tests/crew_inbox_spec.lua 2>&1); }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

C=lua/auto-agents/crew_inbox.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$C|a notify storm: the first snapshot announced|  if not self.known then|  if false then"
  "$C|the known set forgotten at a reconnect|  self.cursor, self.retry, self.parts = 0, 0, nil|  self.cursor, self.retry, self.parts = 0, 0, nil\n  self.open = { requests = {}, reports = {}, attention = {} }"
  "$C|a change not read again|  if again then self.cursor = 0 end|  local _ = again"
  "$C|peer text not inert|  s = tostring(s or \"\"):gsub(\"%c\", \" \"):gsub(\"%s+\", \" \")|  s = tostring(s or \"\")"
  "$C|the subject not capped|  if max and #s > max then|  if false then"
  "$C|the answer handled in the fast event|    self.schedule(function()\n      if gen ~= self.gen then return end -- a newer connection's loop runs|    (function(f) f() end)(function()\n      if gen ~= self.gen then return end -- a newer connection's loop runs"
  "$C|an earlier connection's loop goes on|      if gen ~= self.gen then return end -- a newer connection's loop runs|      local _ = gen"
  "$C|a retry's reply under a new key|  self.keys[k] = self.keys[k] or random_key()|  self.keys[k] = random_key()"
  "$C|a snapshot's next page not read|      return self:watch(gen, snap.next) -- the snapshot's next part, at its first page's cursor|      local _ = snap.next"
  "$C|the backoff not doubled|    self.retry = math.min(2 * wait, M.RETRY_MAX_MS)|    self.retry = wait"
  "$C|a refused watch asked again|    if c == CODE_INVALID_PARAMS or c == CODE_ACCESS_DENIED then|    if false then"
  "$C|a permission prompt not counted|  for _, a in pairs(self.open.attention) do if a.what == \"permission\" then k = k + 1 end end|  local _ = k"
  "$C|a focus ignored|      self.focus(ch.ref) -- the user asked for this agent: raised when it is this Neovim's|      local _ = ch.ref"
  "$C|the winbar segment shown at 0|  if n <= 0 then return \"\" end|  if n < 0 then return \"\" end"
  "$C|the body float reads modelines|  vim.bo[buf].modeline = false|  local _ = buf"
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
