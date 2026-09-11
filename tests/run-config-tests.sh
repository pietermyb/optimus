#!/usr/bin/env bash
# Unit tests for the policy resolvers in hooks/optimus-config.js.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "== Optimus config policy tests =="
node "$ROOT/tests/config-tests.js"
