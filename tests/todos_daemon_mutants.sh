#!/usr/bin/env bash
# tests/todos_daemon_mutants.sh — each rule of the todos.* verbs' direct client
# (ADR 1791532020 §3 step 4) must be load-bearing in tests/todos_daemon_spec.lua:
# one mutation at a time, and the suite must FAIL.
#
# Copies the tree NEXT TO this checkout (the spec finds auto-core and autodoc
# two directories up), applies ONE mutation, runs the spec, and requires it to
# fail. The unmutated copy must be green first, and each mutation must match
# exactly once. Needs what the spec needs (.github/install-deps.sh).
# Run on VM43: bash tests/todos_daemon_mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
PARENT="$(dirname "$SRC")"
copies=()
cleanup() { for c in "${copies[@]}"; do rm -rf "$c"; done; }
trap cleanup EXIT

copy() { local d="$PARENT/mutant-$$-$1"; rm -rf "$d"; cp -r "$SRC" "$d"; copies+=("$d"); echo "$d"; }
run_suite() { (cd "$1" && timeout 600 nvim --headless -u NONE -l tests/todos_daemon_spec.lua 2>&1); }
summary_of() { printf '%s\n' "$1" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1; }
red() {
  local s; s="$(summary_of "$1")"
  [ -z "$s" ] || [ "${s##*, }" != "0 failed" ] || printf '%s\n' "$1" | grep -qE '  FAIL  '
}

base="$(copy base)"
out="$(run_suite "$base")"
if red "$out"; then echo "BASELINE NOT GREEN: $(summary_of "$out")"; printf '%s\n' "$out" | grep FAIL; exit 1; fi
echo "baseline: $(summary_of "$out")"

H=lua/auto-agents/mailbox/todos_commands.lua
D=lua/auto-agents/todos/store.lua
# file|name|old|new — literal strings; old must occur exactly once.
mutants=(
  "$H|assign no longer pokes the notifier|  if who ~= \"\" then store.poke_notifier() end|  local _ = who"
  "$H|update lets a patch assign (no notice)|  if args.patch.assignee ~= nil then|  if false then"
  "$H|update lets a patch change status|  if args.patch.status ~= nil then|  if false then"
  "$H|a new project's add does not scaffold|  if err and err.code == store.NOT_A_STORE then\n    -- a new project's store|  if false then\n    -- a new project's store"
  "$H|the same status writes anyway|  if cur.status == args.status and (args.rev == nil or args.rev == cur.rev) then|  if false then"
  "$H|list defaults to every bucket|    status_filter = \"open\"|    status_filter = \"all\""
  "$H|the assignee-routing subscriber comes back|---Return the absolute filesystem path to the bundled|function M.install_assignee_routing() end\n\n---Return the absolute filesystem path to the bundled"
  "$D|AutoDoc missing becomes an internal_error|      envelope = \"dependency_unavailable\"|      envelope = \"internal_error\""
  "$D|open buffers stay on the old path|  if from ~= to then pcall(buffers.retarget, from, to) else pcall(buffers.reload, to) end|  local _ = buffers"
  "$H|the caller's rev is ignored (a stale patch overwrites)|  local t, err = store.call_at(ctx, verb, id, rev or cur.rev, ...)|  local t, err = store.call_at(ctx, verb, id, cur.rev, ...)"
  "$H|the write re-resolves the project after the read|  local t, err = store.call_at(ctx, verb, id, rev or cur.rev, ...)|  local t, err = store.call(verb, id, rev or cur.rev, ...)"
  "$H|status re-resolves the project after its no-op read|  local failure, _, task = move(ctx, \"status\", args.id, args.rev, args.status)|  local failure, _, task = move(store.context(), \"status\", args.id, args.rev, args.status)"
  "$H|add re-resolves the project for the scaffold|    local _, serr = store.call_at(ctx, \"scaffold\")|    local _, serr = store.call_at(store.context(), \"scaffold\")"
  "$D|refs go to AutoDoc with Neovim's vars unresolved|  local ok, vars = pcall(require, \"auto-core.todo.vars\")\n  if not ok or type(vars.resolve_path) ~= \"function\" then return end|  do return end\n  local ok, vars = pcall(require, \"auto-core.todo.vars\")"
)

killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  file="${m%%|*}"; rest="${m#*|}"
  name="${rest%%|*}"; rest="${rest#*|}"
  old="${rest%%|*}"; new="${rest#*|}"
  i=$((i + 1)); dir="$(copy "m$i")"
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
  if red "$out"; then
    echo "KILLED       $name ($(summary_of "$out"))"
    printf '%s\n' "$out" | grep -oE '  FAIL  .*' | head -3 | cut -c1-160 | sed 's/^/               /'
    killed=$((killed + 1))
  else
    echo "SURVIVED     $name"; survived=$((survived + 1))
  fi
  rm -rf "$dir"
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
