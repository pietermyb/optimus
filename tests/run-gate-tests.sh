#!/usr/bin/env bash
# Unit tests for hooks/optimus-gate.js against fixture PreToolUse payloads.
# Does not touch ~/.claude — creates its own throwaway project dir under
# a temp directory, activates Optimus there via optimus-cli.js (the same
# code path `/optimus on` uses), then feeds each fixture to the gate hook
# on stdin and checks the outcome.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
GATE="$ROOT/hooks/optimus-gate.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

check() {
  local name="$1" expect="$2" fixture="$3" cwd="$4" extra_env="${5:-}"
  local payload
  payload="$(sed "s#__PROJECT__#$cwd#" "$FIXTURES/$fixture")"
  local out
  out="$(env $extra_env node "$GATE" <<<"$payload")"
  local decision="allow"
  if echo "$out" | grep -q '"permissionDecision":"deny"'; then
    decision="deny"
  fi
  if [ "$decision" == "$expect" ]; then
    echo "PASS: $name (got $decision)"
    pass=$((pass+1))
  else
    echo "FAIL: $name (expected $expect, got $decision) -- output: $out"
    fail=$((fail+1))
  fi
}

check_msg() {
  local name="$1" fixture="$2" cwd="$3" needle="$4"
  local payload out
  payload="$(sed "s#__PROJECT__#$cwd#" "$FIXTURES/$fixture")"
  out="$(node "$GATE" <<<"$payload")"
  if echo "$out" | grep -qF "$needle"; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name (message did not contain: $needle) -- output: $out"
    fail=$((fail+1))
  fi
}

echo "== Optimus gate tests =="
echo "-- with Optimus NOT activated: everything should allow --"
check "inactive: main Read allowed"        allow main-read.json        "$PROJECT"
check "inactive: Agent no-model allowed"   allow agent-no-model.json   "$PROJECT"

echo ""
echo "-- activating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on

echo ""
echo "-- with Optimus activated --"
check "active: main Read DENIED"                 deny  main-read.json        "$PROJECT"
check "active: subagent Read ALLOWED (exempt)"    allow subagent-read.json   "$PROJECT"
check "active: Agent w/o model DENIED"            deny  agent-no-model.json  "$PROJECT"
check "active: Agent model=opus DENIED"           deny  agent-opus-model.json "$PROJECT"
check "active: Agent model=haiku ALLOWED"         allow agent-haiku-model.json "$PROJECT"
check "active: Bash git status ALLOWED"           allow main-bash-git.json   "$PROJECT"
check "active: Bash cat work.txt DENIED (best-effort)" deny main-bash-cat.json "$PROJECT"

echo ""
echo "-- deny message wording (guards user-facing text against refactors) --"
check_msg "msg: work tool names the tool and the Agent tool" main-read.json "$PROJECT" \
  'the Read tool is blocked in the orchestrator session'
check_msg "msg: work tool points at /optimus off" main-read.json "$PROJECT" \
  'Run `/optimus off` if you'
check_msg "msg: no-model names tool_input.model" agent-no-model.json "$PROJECT" \
  'has no tool_input.model set'
check_msg "msg: opus dispatch echoes the model back" agent-opus-model.json "$PROJECT" \
  'the expensive tier'
check_msg "msg: bash nudge says best-effort, not a boundary" main-bash-cat.json "$PROJECT" \
  'best-effort'

echo ""
echo "-- kill switch: OPTIMUS_DISABLED=1 forces allow even though active --"
check "kill switch: main Read ALLOWED" allow main-read.json "$PROJECT" "OPTIMUS_DISABLED=1"

echo ""
echo "-- deactivating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" off
check "deactivated: main Read allowed again" allow main-read.json "$PROJECT"

echo ""
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
