#!/usr/bin/env bash
# Tests for the Cursor sessionStart reminder hook.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/optimus-session-cursor.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

payload() {
  printf '{"hook_event_name":"sessionStart","conversation_id":"c1","cwd":"%s","model":"Claude Opus 5"}' "$PROJECT"
}

expect() {
  local name="$1" needle="$2" present="$3" extra_env="${4:-}"
  local out
  out="$(payload | env $extra_env node "$HOOK")"
  if echo "$out" | grep -qF "$needle"; then
    if [ "$present" == "yes" ]; then echo "PASS: $name"; pass=$((pass+1));
    else echo "FAIL: $name (unexpectedly found: $needle) -- $out"; fail=$((fail+1)); fi
  else
    if [ "$present" == "no" ]; then echo "PASS: $name"; pass=$((pass+1));
    else echo "FAIL: $name (missing: $needle) -- $out"; fail=$((fail+1)); fi
  fi
}

echo "== Optimus Cursor sessionStart tests =="
expect "inactive project injects nothing" "additional_context" no

echo ""
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on >/dev/null
expect "active project injects context"        "additional_context"                    yes
expect "context carries the orchestrator line" "you are the orchestrator, not the worker" yes
expect "context uses generic model tiers"      "cheap/fast model"                      yes
expect "frontmatter is stripped"               "alwaysApply"                           no
expect "kill switch injects nothing"           "additional_context"                    no  "OPTIMUS_DISABLED=1"

echo ""
echo "-- output is always valid JSON --"
if payload | node "$HOOK" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s);console.log("ok")})' | grep -q ok; then
  echo "PASS: emits valid JSON"; pass=$((pass+1))
else
  echo "FAIL: emitted invalid JSON"; fail=$((fail+1))
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
