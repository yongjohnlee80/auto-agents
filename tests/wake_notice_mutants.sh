#!/usr/bin/env bash
# tests/wake_notice_mutants.sh — every rule in auto-agents.mailbox.notices and
# the `wake` handler must be load-bearing in tests/wake_notice_spec.lua.
#
# Copies the tree, applies ONE mutation, runs the spec, and requires it to
# FAIL. The unmutated copy must pass first, and each mutation must match
# exactly once (a no-op mutant would read as killed on an unrelated red).
#
# Needs an auto-core with the wake-ctx arrival facts: AUTO_CORE_ROOT, as for
# tests/run-all.sh. Run on VM43:
#   AUTO_CORE_ROOT=<auto-core checkout> bash tests/wake_notice_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: "${AUTO_CORE_ROOT:?set AUTO_CORE_ROOT to an auto-core checkout}"
export AUTO_CORE_ROOT

run_suite() { (cd "$1" && timeout 180 nvim --headless -u NONE -l tests/wake_notice_spec.lua 2>&1); }

cp -r "$SRC" "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep FAIL; exit 1
fi
echo "baseline: $summary"

N=lua/auto-agents/mailbox/notices.lua
C=lua/auto-agents/mailbox/commands.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$N|sender: the recipient again (the bug)|    local from = str(ctx.arrival_from_bare) or bare(ctx.arrival_from)|    local from = str(ctx.mailbox) or bare(ctx.arrival_from)"
  "$N|stale: archived arrivals still typed|    if file_exists(item.path) then return true end|    if true then return true end"
  "$N|coalesce: type every arrival at once|  if not p.timer then\n    local timer = vim.uv.new_timer()|  if true then M.flush(slot) return end\n  if not p.timer then\n    local timer = vim.uv.new_timer()"
  "$N|wake: typed with nothing unread|  if dir and not M.has_unread(dir) then|  if false then"
  "$N|responses: ok:true typed|      if not M.is_error_response(ok_v, code, err_v) then|      if false then"
  "$N|responses: ok:false alone is not an error|  if ok_v == false then return true end|  if false then return true end"
  "$N|routing failure: announced on every retry|  if _undeliverable_seen[key] ~= nil then return end|  if false then return end"
  "$N|log: stale drops not logged|      audit(\"suppressed\", slot, p.agent, it, why)|      local _ = why"
  "$N|sanitize: control bytes reach the terminal|  if type(s) ~= \"string\" then return nil end\n  s = s:gsub|  if type(s) ~= \"string\" then return nil end\n  do return s end\n  s = s:gsub"
  "$N|subject dropped from the notice|  if subj then head = head .. \" — \" .. subj end|  if false then head = head .. \" — \" .. subj end"
  "$N|compat: no fallback read for an older auto-core|    if not have_facts and path then doc = read_json(path) end|    if false then doc = read_json(path) end"
  "$N|error notice drops the command|  local what = item.command and (item.command .. \" failed\") or \"a command you sent failed\"|  local what = \"a command you sent failed\""
  "$N|burst: senders not listed|      #inbox, #inbox == 1 and \"message\" or \"messages\", senders(inbox))|      #inbox, #inbox == 1 and \"message\" or \"messages\", \"someone\")"
  "$C|wake: suppression not logged|    notices._audit(\"suppressed\", slot, args.slot, info or {|    (function() end)(\"suppressed\", slot, args.slot, info or {"
  "$N|wake: explicit wake names nvim again|  local origin = str(ctx.sender_bare)|  local origin = str(ctx.mailbox)"
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
