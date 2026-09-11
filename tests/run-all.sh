#!/usr/bin/env bash
# Runs every Optimus test suite and reports the result of each. All ten
# suites listed below — including the Cursor sidecar suite, which the probe
# made the permanent shipped mechanism rather than a conditional fallback,
# and the PATH install suite covering hooks/install-path.js — are
# unconditionally present in this repo, so the per-suite existence check
# should never actually trigger. It stays in place as a backstop: if a
# suite is ever missing, this reports that suite as SKIPPED instead of
# silently doing nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUITES=(
  run-core-tests.sh
  run-config-tests.sh
  run-allowance-tests.sh
  run-gate-tests.sh
  run-ledger-tests.sh
  run-stats-tests.sh
  run-probe-report-tests.sh
  run-gate-cursor-tests.sh
  run-session-cursor-tests.sh
  run-install-tests.sh
  run-path-install-tests.sh
  run-sidecar-tests.sh
)

failed=()
skipped=()

for suite in "${SUITES[@]}"; do
  if [ ! -x "$ROOT/tests/$suite" ]; then
    skipped+=("$suite (not present)")
    continue
  fi
  echo ""
  echo "################ $suite ################"
  if ! "$ROOT/tests/$suite"; then
    failed+=("$suite")
  fi
done

echo ""
echo "######## summary ########"
for s in "${skipped[@]:-}"; do [ -n "$s" ] && echo "SKIP: $s"; done
if [ ${#failed[@]} -eq 0 ]; then
  echo "ALL SUITES PASSED"
  exit 0
fi
for f in "${failed[@]}"; do echo "FAILED: $f"; done
exit 1
