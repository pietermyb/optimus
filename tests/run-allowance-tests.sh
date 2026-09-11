#!/usr/bin/env bash
# Direct unit tests for turn-scoped inline allowance persistence and
# consume semantics. Fast, in-process, no fixture subprocesses.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "== Optimus allowance tests =="
exec node "$ROOT/tests/allowance-tests.js"
