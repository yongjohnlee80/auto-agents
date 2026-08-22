#!/usr/bin/env bash
# tests/run-all.sh — run every auto-agents test suite and turn a silent
# abort into a loud failure.
#
#   tests/run-all.sh                 # every suite
#   tests/run-all.sh diff_queue_spec # one suite (basename, no .lua)
#
# Why this exists (2026-08-23 runner-hardening):
#
# There was NO runner and NO CI — each of the 12 suites was invoked by
# hand from its header comment. That is how mcp_server_spec sat RED for
# 103 commits: nothing ran it. Every suite exits non-zero on failure
# (the Lua error propagates through `nvim -l`), so even an exit-code-only
# runner would have caught it — the signal was never swallowed, it was
# just never read.
#
# This runner reads it. For each suite it parses the summary line and
# treats its ABSENCE — or a non-zero exit with zero counted failures — as
# a hard failure (an abort before the summary is a silent partial run).
#
# TWO summary formats coexist in this repo, so the sentinel matches both:
#   "<P> passed, <F> failed"     and     "Passed: <P>, Failed: <F>"
# In both, the failed count is the LAST integer on the line.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

overall=0
only="${1:-}"

run_suite() {
  local name="$1" file="$2"
  local out rc summary fail_n
  echo "── $name ──────────────────────────────────"
  out="$(nvim --headless -u NONE -l "$file" 2>&1)"
  rc=$?
  summary="$(printf '%s\n' "$out" \
    | grep -oE "([0-9]+ passed, [0-9]+ failed|Passed: [0-9]+, Failed: [0-9]+)" \
    | tail -1 || true)"
  printf '%s\n' "$out" | grep -E "^  FAIL" | head -10

  # Summary-presence: absence == aborted before the summary line.
  if [ -z "$summary" ]; then
    echo "   ✗ $name: NO SUMMARY LINE — aborted mid-run (silent partial run)"
    echo "     ── tail of output ──"
    printf '%s\n' "$out" | tail -15 | sed 's/^/     /'
    overall=1
    return
  fi
  echo "   $name: $summary (exit=$rc)"

  # Failed count = last integer in either summary format.
  fail_n="$(printf '%s' "$summary" | grep -oE "[0-9]+" | tail -1)"
  if [ "${fail_n:-0}" -gt 0 ]; then
    echo "   ✗ $name: $fail_n failed"
    overall=1
    return
  fi
  # Clean summary but non-zero exit = crash after the assertions ran.
  if [ "$rc" -ne 0 ]; then
    echo "   ✗ $name: exit=$rc despite '$summary' — crashed after the summary"
    overall=1
    return
  fi
  echo "   ✓ $name OK"
}

for f in tests/*.lua; do
  name="$(basename "$f" .lua)"
  if [ -n "$only" ] && [ "$name" != "$only" ]; then continue; fi
  run_suite "$name" "$f"
done

echo "────────────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK"
else
  echo "run-all: FAILED"
fi
exit "$overall"
