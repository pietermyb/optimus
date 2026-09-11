#!/usr/bin/env bash
# Tests for the Cursor sessionStart reminder hook.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/optimus-session-cursor.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
cleanup() {
  if [ -n "${MARKERS_RESTORE_DIR:-}" ] && [ -d "$MARKERS_RESTORE_DIR" ]; then
    chmod "${MARKERS_RESTORE_MODE:-700}" "$MARKERS_RESTORE_DIR" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

payload() {
  printf '{"hook_event_name":"sessionStart","conversation_id":"c1","cwd":"%s","model":"Claude Opus 5"}' "$PROJECT"
}

stale_touch_time() {
  date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M
}

write_stale_marker() {
  local markers="$1" name="$2" parent="$3"
  printf '%s' "$parent" >"$markers/$name"
  touch -t "$(stale_touch_time)" "$markers/$name"
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
echo "-- output contract when nothing to sweep --"
empty_out="$(payload | node "$HOOK")"
expected_out="$(node - "$ROOT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const rulePath = path.join(root, 'cursor', 'optimus.mdc');
const text = fs.readFileSync(rulePath, 'utf8');
const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/.exec(text);
const stripped = (match ? text.slice(match[0].length) : text).trim();
process.stdout.write(JSON.stringify({ additional_context: stripped }));
NODE
)"
if [ "$empty_out" = "$expected_out" ]; then
  echo "PASS: additional_context JSON is unchanged with no markers"; pass=$((pass+1))
else
  echo "FAIL: additional_context JSON changed with no markers -- $empty_out"; fail=$((fail+1))
fi

expect "active project injects context"        "additional_context"                    yes
expect "context carries the orchestrator line" "you are the orchestrator, not the worker" yes
expect "context uses generic model tiers"      "cheap/fast model"                      yes
expect "frontmatter is stripped"               "alwaysApply"                           no
expect "kill switch injects nothing"           "additional_context"                    no  "OPTIMUS_DISABLED=1"

echo ""
echo "-- stale marker sweep on sessionStart --"
MARKERS="$PROJECT/.optimus/state/active-subagents"
mkdir -p "$MARKERS"
write_stale_marker "$MARKERS" "tooluse-old" "conv-abandoned"
printf 'conv-live' >"$MARKERS/tooluse-new"

out="$(payload | node "$HOOK")"
if [ ! -e "$MARKERS/tooluse-old" ]; then
  echo "PASS: sessionStart sweeps the stale marker"; pass=$((pass+1))
else
  echo "FAIL: stale marker survived sessionStart"; fail=$((fail+1))
fi
if [ -e "$MARKERS/tooluse-new" ]; then
  echo "PASS: sessionStart leaves the fresh marker"; pass=$((pass+1))
else
  echo "FAIL: fresh marker was swept"; fail=$((fail+1))
fi
if echo "$out" | grep -qF "additional_context"; then
  echo "PASS: context output survives the sweep"; pass=$((pass+1))
else
  echo "FAIL: sweep broke the context output"; fail=$((fail+1))
fi

echo ""
echo "-- short-circuit paths do not sweep --"
write_stale_marker "$MARKERS" "tooluse-inactive" "conv-inactive"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" off >/dev/null
inactive_out="$(payload | node "$HOOK")"
if [ -e "$MARKERS/tooluse-inactive" ]; then
  echo "PASS: inactive project short-circuits before sweep"; pass=$((pass+1))
else
  echo "FAIL: inactive path swept markers"; fail=$((fail+1))
fi
if ! echo "$inactive_out" | grep -qF "additional_context"; then
  echo "PASS: inactive project emits empty JSON"; pass=$((pass+1))
else
  echo "FAIL: inactive project emitted context"; fail=$((fail+1))
fi
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on >/dev/null
rm -f "$MARKERS/tooluse-inactive"

write_stale_marker "$MARKERS" "tooluse-killswitch" "conv-killswitch"
killswitch_out="$(payload | OPTIMUS_DISABLED=1 node "$HOOK")"
if [ -e "$MARKERS/tooluse-killswitch" ]; then
  echo "PASS: kill switch short-circuits before sweep"; pass=$((pass+1))
else
  echo "FAIL: kill switch path swept markers"; fail=$((fail+1))
fi
if ! echo "$killswitch_out" | grep -qF "additional_context"; then
  echo "PASS: kill switch emits empty JSON"; pass=$((pass+1))
else
  echo "FAIL: kill switch emitted context"; fail=$((fail+1))
fi
rm -f "$MARKERS/tooluse-killswitch"

echo ""
echo "-- unsweepable stale marker fails safe --"
write_stale_marker "$MARKERS" "tooluse-stale-lock-baseline" "conv-baseline"
payload | node "$HOOK" >/dev/null
write_stale_marker "$MARKERS" "tooluse-stale-locked" "conv-locked"
MARKERS_RESTORE_DIR="$MARKERS"
MARKERS_RESTORE_MODE="$(stat -f %Mp%Lp "$MARKERS" 2>/dev/null || stat -c %a "$MARKERS")"
chmod 0500 "$MARKERS"
locked_out="$(payload | node "$HOOK")"
locked_status=$?
chmod "$MARKERS_RESTORE_MODE" "$MARKERS" 2>/dev/null || true
unset MARKERS_RESTORE_DIR MARKERS_RESTORE_MODE
if echo "$locked_out" | grep -qF "additional_context"; then
  echo "PASS: unsweepable stale marker still emits context"; pass=$((pass+1))
else
  echo "FAIL: unsweepable stale marker broke context output -- $locked_out"; fail=$((fail+1))
fi
if [ "$locked_status" -eq 0 ]; then
  echo "PASS: unsweepable stale marker exits zero"; pass=$((pass+1))
else
  echo "FAIL: unsweepable stale marker exited non-zero ($locked_status)"; fail=$((fail+1))
fi
if [ -e "$MARKERS/tooluse-stale-locked" ]; then
  echo "PASS: stale marker survives unlink failure (fail-safe)"; pass=$((pass+1))
else
  echo "FAIL: stale marker missing after unsweepable run"; fail=$((fail+1))
fi
rm -f "$MARKERS/tooluse-stale-locked" "$MARKERS/tooluse-stale-lock-baseline" "$MARKERS/tooluse-new"

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
