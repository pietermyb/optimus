#!/usr/bin/env bash
# Unit tests for hooks/optimus-ledger.js, exercised through hooks/optimus-gate.js
# (the ledger's only caller). Mirrors tests/run-gate-tests.sh conventions:
# does not touch ~/.claude — creates its own throwaway project dirs under a
# temp directory, activates Optimus via optimus-cli (the same code path
# `/optimus on` uses), feeds fixture PreToolUse payloads to the gate hook on
# stdin, then inspects the resulting <project>/.optimus/state/events.jsonl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
GATE="$ROOT/hooks/optimus-gate.js"
CLI="$ROOT/bin/optimus-cli"

# Distinctive sentinel baked into fixture prompt/file_path/command fields.
# Case 7 greps every ledger produced by this run for it and asserts absence
# — the whole point being that prompts, paths and full commands must never
# reach the ledger, only the whitelisted event-specific fields (e.g. the
# reduced cmd_head for Bash).
SENTINEL="OPTIMUS_SENTINEL_9f3a1b"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"
LEDGER="$PROJECT/.optimus/state/events.jsonl"

pass=0
fail=0

ok() {
  echo "PASS: $1"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL: $1"
  fail=$((fail + 1))
}

# Feeds a fixture (with __PROJECT__ substituted) to the gate on stdin and
# prints its stdout. Same shape as run-gate-tests.sh's `check` helper.
run_gate() {
  local fixture="$1" cwd="$2" extra_env="${3:-}"
  local payload
  payload="$(sed "s#__PROJECT__#$cwd#" "$FIXTURES/$fixture")"
  env $extra_env node "$GATE" <<<"$payload"
}

# Prints the last line of a ledger file, or "" if the file doesn't exist —
# guarded so a not-yet-created ledger produces a clean assertion failure
# instead of aborting the script under `set -e`.
ledger_last_line() {
  if [ -f "$1" ]; then
    tail -n 1 "$1"
  else
    echo ""
  fi
}

# Reads a top-level JSON field out of a line via node (no jq dependency;
# this repo has neither package.json nor npm). Prints "" if the line is
# empty or not valid JSON, or if the field is absent.
field() {
  local line="$1" key="$2"
  node -e '
    let o;
    try { o = JSON.parse(process.argv[1]); } catch (e) { process.stdout.write(""); process.exit(0); }
    const v = o[process.argv[2]];
    process.stdout.write(v === undefined ? "" : String(v));
  ' "$line" "$key" 2>/dev/null || true
}

assert_field() {
  local label="$1" line="$2" key="$3" expected="$4"
  local got
  got="$(field "$line" "$key")"
  if [ "$got" = "$expected" ]; then
    ok "$label"
  else
    bad "$label (expected $key=$expected, got: $line)"
  fi
}

echo "== Optimus ledger tests =="

echo "-- activating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on >/dev/null

echo ""
echo "-- case 1+2: each event type is recorded with correct ev + fields --"

run_gate ledger-agent-allowed.json "$PROJECT" >/dev/null
line="$(ledger_last_line "$LEDGER")"
assert_field "dispatch_allowed: ev"                    "$line" ev         "dispatch_allowed"
assert_field "dispatch_allowed: model is raw 'haiku'"  "$line" model     "haiku"
assert_field "dispatch_allowed: agent_type"            "$line" agent_type "general-purpose"
assert_field "dispatch_allowed: tool_use_id"           "$line" tool_use_id "toolu_ledger_allowed"
assert_field "dispatch_allowed: v==1"                  "$line" v          "1"
if [ -n "$(field "$line" ts)" ]; then ok "dispatch_allowed: ts present"; else bad "dispatch_allowed: ts missing (got: $line)"; fi
assert_field "dispatch_allowed: session_id"            "$line" session_id "test-session"

run_gate ledger-agent-no-model.json "$PROJECT" >/dev/null
line="$(ledger_last_line "$LEDGER")"
assert_field "dispatch_denied(no_model): ev"           "$line" ev "dispatch_denied"
assert_field "dispatch_denied(no_model): reason"       "$line" reason "no_model"
assert_field "dispatch_denied(no_model): tool_use_id"  "$line" tool_use_id "toolu_ledger_nomodel"

run_gate ledger-agent-opus.json "$PROJECT" >/dev/null
line="$(ledger_last_line "$LEDGER")"
assert_field "dispatch_denied(expensive_model): ev"     "$line" ev "dispatch_denied"
assert_field "dispatch_denied(expensive_model): reason" "$line" reason "expensive_model"
assert_field "dispatch_denied(expensive_model): model"  "$line" model "opus"

run_gate ledger-work-tool-denied.json "$PROJECT" >/dev/null
line="$(ledger_last_line "$LEDGER")"
assert_field "work_tool_denied: ev"   "$line" ev "work_tool_denied"
assert_field "work_tool_denied: tool" "$line" tool "Read"

run_gate ledger-bash-nudge.json "$PROJECT" >/dev/null
line="$(ledger_last_line "$LEDGER")"
assert_field "bash_nudge: ev"       "$line" ev "bash_nudge"
assert_field "bash_nudge: cmd_head" "$line" cmd_head "cat"

echo ""
echo "-- case 3: no ledger file when Optimus is deactivated --"
OFFPROJECT="$WORKDIR/off-project"
mkdir -p "$OFFPROJECT"
CLAUDE_PROJECT_DIR="$OFFPROJECT" node "$CLI" off >/dev/null
run_gate ledger-agent-allowed.json "$OFFPROJECT" >/dev/null
if [ -e "$OFFPROJECT/.optimus/state/events.jsonl" ]; then
  bad "deactivated: no ledger file should have been created"
else
  ok "deactivated: no ledger file created"
fi

echo ""
echo "-- case 4: gate's permission decision is unaffected when the ledger is unwritable --"
UNWRITABLE="$WORKDIR/unwritable-project"
mkdir -p "$UNWRITABLE"
CLAUDE_PROJECT_DIR="$UNWRITABLE" node "$CLI" on >/dev/null

# 4a: .optimus/state exists but is a read-only directory.
mkdir -p "$UNWRITABLE/.optimus/state"
chmod 500 "$UNWRITABLE/.optimus/state"
set +e
out="$(run_gate ledger-work-tool-denied.json "$UNWRITABLE")"
rc=$?
set -e
chmod 700 "$UNWRITABLE/.optimus/state"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"deny"'; then
  ok "read-only state dir: gate still denies Read correctly, exit 0"
else
  bad "read-only state dir: gate broke (rc=$rc, out=$out)"
fi

# 4b: .optimus/state is a plain file where a directory should be.
rm -rf "$UNWRITABLE/.optimus/state"
: >"$UNWRITABLE/.optimus/state"
set +e
out="$(run_gate ledger-agent-allowed.json "$UNWRITABLE")"
rc=$?
set -e
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -q '"permissionDecision":"deny"'; then
  ok "state path is a file, not a dir: gate still allows dispatch correctly, exit 0"
else
  bad "state path is a file, not a dir: gate broke (rc=$rc, out=$out)"
fi
rm -f "$UNWRITABLE/.optimus/state"

echo ""
echo "-- case 5: rotation at the 1 MB cap --"
ROTPROJECT="$WORKDIR/rotation-project"
mkdir -p "$ROTPROJECT/.optimus/state"
CLAUDE_PROJECT_DIR="$ROTPROJECT" node "$CLI" on >/dev/null
ROTLEDGER="$ROTPROJECT/.optimus/state/events.jsonl"
dd if=/dev/zero of="$ROTLEDGER" bs=1024 count=1024 >/dev/null 2>&1
run_gate ledger-work-tool-denied.json "$ROTPROJECT" >/dev/null
if [ -f "$ROTLEDGER.1" ] && [ -f "$ROTLEDGER" ]; then
  old_size=$(wc -c <"$ROTLEDGER.1" | tr -d ' ')
  new_size=$(wc -c <"$ROTLEDGER" | tr -d ' ')
  if [ "$old_size" -ge 1048576 ] && [ "$new_size" -lt 1000 ]; then
    ok "rotation: events.jsonl.1 holds the old ~1MB content, events.jsonl reset small"
  else
    bad "rotation: unexpected sizes (old=$old_size new=$new_size)"
  fi
else
  bad "rotation: events.jsonl.1 and/or events.jsonl missing after rotating append"
fi

echo ""
echo "-- case 6: concurrency - 20 parallel gate processes, one ledger --"
CONCPROJECT="$WORKDIR/concurrency-project"
mkdir -p "$CONCPROJECT"
CLAUDE_PROJECT_DIR="$CONCPROJECT" node "$CLI" on >/dev/null
CONCLEDGER="$CONCPROJECT/.optimus/state/events.jsonl"

for i in $(seq 1 20); do
  run_gate ledger-work-tool-denied.json "$CONCPROJECT" >/dev/null &
done
wait

if [ -f "$CONCLEDGER" ]; then
  lines=$(wc -l <"$CONCLEDGER" | tr -d ' ')
else
  lines=0
fi
if [ "$lines" -eq 20 ]; then
  ok "concurrency: ledger contains exactly 20 lines"
else
  bad "concurrency: expected 20 lines, got $lines"
fi

bad_json=0
if [ -f "$CONCLEDGER" ]; then
  while IFS= read -r l; do
    if ! node -e 'JSON.parse(process.argv[1])' "$l" >/dev/null 2>&1; then
      bad_json=$((bad_json + 1))
    fi
  done <"$CONCLEDGER"
fi
if [ "$bad_json" -eq 0 ]; then
  ok "concurrency: every line parses as JSON"
else
  bad "concurrency: $bad_json line(s) failed to parse as JSON"
fi

echo ""
echo "-- case 7: no prompt/path/command text ever reaches any ledger --"
if grep -rq "$SENTINEL" "$WORKDIR" 2>/dev/null; then
  bad "privacy: sentinel string leaked into a ledger under $WORKDIR"
else
  ok "privacy: sentinel string (prompt/file_path/command text) absent from every ledger"
fi

echo ""
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
