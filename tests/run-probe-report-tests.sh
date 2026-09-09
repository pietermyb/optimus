#!/usr/bin/env bash
# Tests for bin/optimus-probe-report against synthetic probe logs.
# The real probe log can only be produced by a human driving Cursor
# (see cursor/probe/README.md); these fixtures stand in for the two
# outcomes that change the design, so the analyser itself is testable
# without a Cursor install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT/bin/optimus-probe-report"
FIX="$ROOT/tests/fixtures/probe"

pass=0
fail=0

expect_contains() {
  local name="$1" logfile="$2" needle="$3"
  local out
  out="$(node "$REPORT" "$FIX/$logfile")"
  if echo "$out" | grep -qF "$needle"; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name (missing: $needle)"
    echo "---- output ----"
    echo "$out"
    fail=$((fail+1))
  fi
}

echo "== Optimus probe-report tests =="
expect_contains "distinguishable: flags the extra key"    distinguishable.log   "CANDIDATE SUBAGENT FIELD: subagent_id"
expect_contains "distinguishable: verdict row 1"          distinguishable.log   "UNKNOWN 1 VERDICT: distinguishing field present"
expect_contains "distinguishable: reports model drift"    distinguishable.log   "model differs across preToolUse entries"
expect_contains "indistinguishable: no candidate keys"    indistinguishable.log "CANDIDATE SUBAGENT FIELD: (none)"
expect_contains "indistinguishable: verdict row 2"        indistinguishable.log "UNKNOWN 1 VERDICT: no distinguishing field"
expect_contains "unknown 2: reports env resolution"       distinguishable.log   "CURSOR_PLUGIN_ROOT : (unset/empty)"
expect_contains "unknown 2: verdict"                      distinguishable.log   "UNKNOWN 2 VERDICT: no plugin-root variable resolved"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
