#!/usr/bin/env bash
# Direct unit tests for the host-agnostic policy core. No fixtures, no
# subprocess-per-case — see tests/core-tests.js for why.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "== Optimus core tests =="
exec node "$ROOT/tests/core-tests.js"
