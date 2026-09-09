#!/usr/bin/env bash
# Runs every Optimus test suite. Suites that belong to an optional build
# path (the Cursor sidecar fallback) are skipped when their code is absent
# rather than failing — and the skip is printed, never silent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUITES=(
  run-core-tests.sh
  run-gate-tests.sh
  run-ledger-tests.sh
  run-stats-tests.sh
  run-probe-report-tests.sh
  run-gate-cursor-tests.sh
  run-session-cursor-tests.sh
  run-install-tests.sh
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
