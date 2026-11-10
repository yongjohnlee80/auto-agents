#!/usr/bin/env bash
# tests/crew_fallback_mutants.sh — every rule of the fallback (auto-agents.crew's part in AutoDoc's
# fallback, r15 P4, and auto-agents.fallback's typing, v0.4.0) must be load-bearing in
# tests/crew_fallback_spec.lua or tests/fallback_spec.lua (or tests/crew_sessions_spec.lua, for the
# session's prompts the guard reads).
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

# the three specs; the summary is the worst of them (a mutant is killed by any)
run_suite() {
  (cd "$1" && for spec in tests/crew_fallback_spec.lua tests/fallback_spec.lua tests/crew_sessions_spec.lua; do
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
I=lua/auto-agents/crew_inbox.lua
# file|name|old|new — literal strings (\n = newline); must occur exactly once.
mutants=(
  "$C|an older daemon asked: the protocol gate dropped|  return (tonumber(h.protocol) or 0) >= M.FALLBACK_PROTOCOL and (not c.can or c:can(\"mail.fallbacks\"))|  return true"
  "$C|silent on delivery|      st.notify((\"%s couldn't be woken: AutoDoc's message from %s was typed into its terminal\"):format(job.codename,\n        tostring(job.from)), vim.log.levels.INFO)|      local _ = job.from"
  "$C|a failed typing reported delivered|    if not ok then return done(\"unknown\", why) end|    if not ok then return done(\"delivered\") end"
  "$C|typed under another key than the job's id|  type_once(job.codename, job.id, job.text, { guard = true, done = function(ok, why, how)|  type_once(job.codename, job.lease, job.text, { guard = true, done = function(ok, why, how)"
  "$C|a lost epoch asked again|      if c == M.CODE_METHOD_NOT_FOUND or c == M.CODE_STALE_EPOCH then return end|      if c == M.CODE_METHOD_NOT_FOUND then return end"
  "$C|never asked again after a job|    later(st, a, 0, function() poll_fallbacks(st, a) end) -- off this answer: the next poll waits on the daemon|    local _ = a"
  "$F|typed twice: a typed key not read|  return seen[key]\nend|  return nil\nend"
  "$F|the key not kept: a restart types again|  mine[#mine + 1] = line_of(key, guard and M.NOT_SENT or \"sent\")\n  if not save() then|  if false then"
  "$F|no slot keeps the key|  if not slot then return finish(false, (\"no slot runs %s\"):format(tostring(codename))) end|  if not slot then mine[#mine + 1] = key; save(); return finish(false, \"no slot\") end"
  "$F|a refused key kept|    forget(key) -- nothing was typed: it may be typed later\n    save()|    local _ = nil"
  "$F|Esc may follow: the submit keys dropped|  local send = { submit = true, submit_keys = { \"<CR>\" } }|  local send = { submit = true }"
  "$F|no hazard prefix|  if s:match(\"^[%[/%\$]\") then s = M.PREFIX .. s end|  local _ = s"
  "$F|not sanitized: line breaks and controls typed|  local s = require(\"auto-agents.sanitize\").sanitize(text, M.MAX_TEXT)|  local s = type(text) == \"string\" and text ~= \"\" and text or nil"
  "$F|another instance's agent typed|    if ok and inst ~= instance then return false, \"another Neovim's agent\" end|    local _ = inst"
  "$F|pruning keeps the oldest|keys = vim.list_slice(keys, #keys - M.MAX_KEYS + 1)|keys = vim.list_slice(keys, 1, M.MAX_KEYS)"
  "$F|the guard dropped: typed into an open prompt|  if state == \"waits\" then return finish(false, (\"%s waits on the user's answer to a prompt\"):format(codename), \"waits\") end|  local _ = state"
  "$F|prompts unreported, sent with Enter|  if state == \"unreported\" then return finish(true, nil, M.NOT_SENT) end -- an Enter could approve a prompt unseen|  local _ = state"
  "$F|a todo notice unguarded|  return M.type_once(name, delivery.key, text, { guard = true })|  return M.type_once(name, delivery.key, text)"
  "$F|the session's prompts ignored|  if not s or s.prompts ~= true then return \"unreported\" end|  if not s then return \"unreported\" end"
  "$F|an inbox that says nothing read as clear|  if waits == nil then return \"unreported\" end|  local _ = waits"
  "$I|a stale inbox trusted: no snapshot yet read as clear|  if not self.known then return self:serves() and true or nil end|  local _ = self.known"
  "$C|a job unguarded|  type_once(job.codename, job.id, job.text, { guard = true, done = function(ok, why, how)|  type_once(job.codename, job.id, job.text, { done = function(ok, why, how)"
  "$C|a waiting job reported|    return -- no report: its lease lapses and the daemon offers it again|    local _ = nil"
  "$C|typed_not_sent reported delivered|    if how == \"typed_not_sent\" then return done(\"typed_not_sent\") end|    local _ = how"
  "$C|the user not told to press Enter|    st.notify((\"AutoDoc's message from %s is typed into %s's terminal but not sent: press Enter there to send it\")|    local _ = (function(...) end)((\"\")"
  "$C|the session's prompts not kept|        codename = r.codename, prompts = r.prompts == true }|        codename = r.codename }"
  "$F|the Enter not read again: a prompt opened since the paste answered|    if same and M.prompt_state(codename) == \"clear\" and aa.send_keypress(slot, \"<CR>\") then|    if aa.send_keypress(slot, \"<CR>\") then"
  "$F|the session not compared at the Enter|    local same = aa.slot_for_name(codename) == slot and (now and now.id) == session|    local same = aa.slot_for_name(codename) == slot"
  "$F|the terminal not compared at the Enter|      and (not term or (aa.state.slot_terminals[slot] == term and term:is_alive()))|      and true"
  "$F|a kept key's outcome dropped: every key read as sent|    local k, state = parse(line)\n    seen[k] = state|    local k = parse(line)\n    seen[k] = \"sent\""
  "$F|a guarded line written as sent before its Enter|  mine[#mine + 1] = line_of(key, guard and M.NOT_SENT or \"sent\")|  mine[#mine + 1] = line_of(key, \"sent\")"
  "$F|a sent line kept as not sent|        if (parse(l)) == key then _mine[i] = key end -- sent now|        local _ = l"
  "$F|done heard before the Enter is decided|  return true -- typed; its Enter is decided once the delay is over|  if done then done(true, nil, \"sent\") end\n  return true"
  "$C|a job settled after the crew stopped reported|    if not live(st) then return end -- released or stopped meanwhile: the lease lapses with it|    local _ = live"
  "$I|a coming snapshot read as nothing said: pasted before it|  if not self.known then return self:serves() and true or nil end|  if not self.known then return nil end"
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
