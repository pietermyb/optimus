#!/usr/bin/env bash
# Shape tests for hooks/optimus-gate-cursor.js.
#
# Deliberately shallow: the policy these payloads exercise already has
# direct coverage in tests/core-tests.js, and the sidecar has its own
# suite. These exist to catch parsing and shape-translation bugs at the
# Cursor boundary — a wrong tool-name mapping, a wrong tool_input key, a
# malformed permission JSON, a role decision read from the wrong place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/cursor"
GATE="$ROOT/hooks/optimus-gate-cursor.js"
SUBHOOK="$ROOT/hooks/optimus-subagent-cursor.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

render() { sed "s#__PROJECT__#$PROJECT#g" "$FIXTURES/$1"; }

check() {
  local name="$1" expect="$2" fixture="$3" extra_env="${4:-}"
  local out decision
  out="$(render "$fixture" | env $extra_env node "$GATE")"
  decision="unparseable"
  if echo "$out" | grep -q '"permission":"deny"'; then
    decision="deny"
  elif echo "$out" | grep -q '"permission":"allow"'; then
    decision="allow"
  fi
  if [ "$decision" == "$expect" ]; then
    echo "PASS: $name (got $decision)"
    pass=$((pass+1))
  else
    echo "FAIL: $name (expected $expect, got $decision) -- output: $out"
    fail=$((fail+1))
  fi
}

echo "== Optimus Cursor gate tests =="
echo "-- inactive project: everything allows, with explicit allow JSON --"
check "inactive: main Read allowed"     allow main-read.json
check "inactive: Task no-model allowed" allow task-no-model.json

echo ""
echo "-- activating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on

echo ""
echo "-- active, no dispatch outstanding: per-turn inline allowance applies before deny --"
check "active: main Read ALLOWED (allowance #1)"                     allow main-read.json
check "active: subagent-shaped Read ALLOWED (allowance #1, own convo)" allow subagent-read.json
check "active: subagent-shaped Read ALLOWED (allowance #2, own convo)" allow subagent-read.json
check "active: Task w/o model DENIED"                                deny  task-no-model.json
check "active: Task model=inherit DENIED"                            deny  task-inherit-model.json
check "active: Task model=opus DENIED"                               deny  task-opus-model.json
check "active: Task cheap model ALLOWED"                             allow task-cheap-model.json
check "active: Shell git status ALLOWED"                             allow main-shell-git.json
check "active: Shell cat ALLOWED (allowance #2 shared bucket)"       allow main-shell-cat.json
check "active: Delete DENIED (allowance exhausted)"                  deny  main-delete.json
check "active: Shell cat DENIED once allowance exhausted"            deny  main-shell-cat.json

echo ""
echo "-- with a dispatch outstanding: the subagent's conversation is exempt --"
render subagent-start.json | node "$SUBHOOK" >/dev/null
check "outstanding: subagent Read ALLOWED (exempt)" allow subagent-read.json
check "outstanding: orchestrator Read still DENIED" deny  main-read.json
render subagent-stop.json | node "$SUBHOOK" >/dev/null
check "after stop: subagent-shaped Read DENIED again" deny subagent-read.json

echo ""
echo "-- the deny payload carries both message fields --"
out="$(render main-read.json | node "$GATE")"
for field in user_message agent_message; do
  if echo "$out" | grep -q "\"$field\""; then
    echo "PASS: deny carries $field"; pass=$((pass+1))
  else
    echo "FAIL: deny is missing $field -- output: $out"; fail=$((fail+1))
  fi
done
if echo "$out" | grep -qF 'cheap/fast model'; then
  echo "PASS: deny text uses generic model tiers"; pass=$((pass+1))
else
  echo "FAIL: deny text should not name Anthropic tiers -- output: $out"; fail=$((fail+1))
fi
if render task-inherit-model.json | node "$GATE" | grep -qF 'inherit'; then
  echo "PASS: the inherit deny names the offending value"; pass=$((pass+1))
else
  echo "FAIL: the inherit deny does not mention inherit"; fail=$((fail+1))
fi

echo ""
echo "-- ledger: conversation_id maps onto session_id, shared event names --"
LEDGER="$PROJECT/.optimus/state/events.jsonl"
if grep -q '"session_id":"probe-conv-main"' "$LEDGER"; then
  echo "PASS: ledger session_id came from conversation_id"; pass=$((pass+1))
else
  echo "FAIL: ledger session_id not mapped"; fail=$((fail+1))
fi
for ev in work_tool_denied work_tool_inline_allowed bash_nudge dispatch_denied dispatch_allowed; do
  if grep -q "\"ev\":\"$ev\"" "$LEDGER"; then
    echo "PASS: ledger wrote $ev"; pass=$((pass+1))
  else
    echo "FAIL: ledger never wrote $ev"; fail=$((fail+1))
  fi
done
if grep -q '"generation_id":"probe-gen-1"' "$LEDGER"; then
  echo "PASS: inline-allowance event carries generation_id"; pass=$((pass+1))
else
  echo "FAIL: generation_id missing from inline-allowance event"; fail=$((fail+1))
fi
if grep -q '"model":"claude-haiku-4-5"' "$LEDGER"; then
  echo "PASS: dispatch_allowed recorded the requested model verbatim"; pass=$((pass+1))
else
  echo "FAIL: requested model not recorded"; fail=$((fail+1))
fi
if grep -q '"user_email"' "$LEDGER"; then
  echo "FAIL: ledger recorded user_email"; fail=$((fail+1))
else
  echo "PASS: ledger did not record user_email"; pass=$((pass+1))
fi

echo ""
echo "-- malformed stdin fails OPEN with an explicit allow --"
out="$(echo 'not json at all' | node "$GATE")"
if echo "$out" | grep -q '"permission":"allow"'; then
  echo "PASS: malformed payload allows"; pass=$((pass+1))
else
  echo "FAIL: malformed payload did not fail open -- output: $out"; fail=$((fail+1))
fi

echo ""
echo "-- an unrecognized tool name fails open --"
if printf '{"hook_event_name":"preToolUse","conversation_id":"probe-conv-main","cwd":"%s","tool_name":"MCP:atlassian_search","tool_input":{}}' "$PROJECT" | node "$GATE" | grep -q '"permission":"allow"'; then
  echo "PASS: unknown tool allowed"; pass=$((pass+1))
else
  echo "FAIL: unknown tool was not allowed"; fail=$((fail+1))
fi

echo ""
echo "-- kill switch forces allow --"
check "kill switch: main Read ALLOWED" allow main-read.json "OPTIMUS_DISABLED=1"

echo ""
echo "-- deactivating --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" off
check "deactivated: main Read allowed again" allow main-read.json

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
