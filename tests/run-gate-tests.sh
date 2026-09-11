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


check_payload() {
  local name="$1" expect="$2" payload="$3" extra_env="${4:-}"
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
echo "-- configurable policy: per-project override changes outcomes --"
CUSTOM="$WORKDIR/project-custom"
mkdir -p "$CUSTOM/.optimus"
cat >"$CUSTOM/.optimus/config.json" <<'JSON'
{
  "enabled": true,
  "updatedAt": "2026-09-11T00:00:00.000Z",
  "inlineAllowancePerTurn": 2,
  "gatedTools": ["Read"],
  "expensiveModelPattern": "gpt-5",
  "shellBypassPatterns": ["^\\s*bat\\s+"]
}
JSON

check "default policy: Agent opus DENIED" deny agent-opus-model.json "$PROJECT"
check "custom policy: Agent opus ALLOWED" allow agent-opus-model.json "$CUSTOM"

custom_gpt5_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Read work.txt and report","prompt":"read work.txt","subagent_type":"general-purpose","model":"gpt-5"},"tool_use_id":"toolu_fixture_cfg_gpt5"}' "$CUSTOM")"
check_payload "custom policy: Agent gpt-5 DENIED" deny "$custom_gpt5_payload"

default_bat_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bat work.txt","description":"read work.txt"},"tool_use_id":"toolu_fixture_cfg_bat_default"}' "$PROJECT")"
custom_bat_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bat work.txt","description":"read work.txt"},"tool_use_id":"toolu_fixture_cfg_bat_custom"}' "$CUSTOM")"
check_payload "default policy: Bash bat ALLOWED" allow "$default_bat_payload"
check_payload "custom policy: Bash bat DENIED" deny "$custom_bat_payload"

# Delete is in the gated set by way of getGatedTools()'s default, not by
# this adapter topping the resolved set up afterwards. These two pin the
# end-to-end outcome either way round: gated by default, ungated the
# moment a project names its own gatedTools.
default_delete_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Delete","tool_input":{"path":"work.txt"},"tool_use_id":"toolu_fixture_delete_default"}' "$PROJECT")"
custom_delete_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Delete","tool_input":{"path":"work.txt"},"tool_use_id":"toolu_fixture_delete_custom"}' "$CUSTOM")"
check_payload "default policy: Delete DENIED (from the resolver default)" deny "$default_delete_payload"
check_payload "custom policy: Delete ALLOWED (override not unioned with Delete)" allow "$custom_delete_payload"

# gatedToolPatterns end to end: a follow-up to #3 hardened the glob
# matcher and the config cache underneath this key, but neither of those
# changes should be able to silently drop the WIRING itself. This project
# gates nothing by exact name (gatedTools: []) so a deny here can only
# have come from the pattern.
PATTERN="$WORKDIR/project-pattern"
mkdir -p "$PATTERN/.optimus"
cat >"$PATTERN/.optimus/config.json" <<'JSON'
{
  "enabled": true,
  "updatedAt": "2026-09-11T00:00:00.000Z",
  "gatedTools": [],
  "gatedToolPatterns": ["mcp__*"]
}
JSON
mcp_gated_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"mcp__github__list_issues","tool_input":{},"tool_use_id":"toolu_fixture_pattern_mcp"}' "$PATTERN")"
mcp_unmatched_payload="$(printf '{"session_id":"test-session","transcript_path":"/tmp/does-not-exist.jsonl","cwd":"%s","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"SomeOtherTool","tool_input":{},"tool_use_id":"toolu_fixture_pattern_other"}' "$PATTERN")"
check_payload "gatedToolPatterns: mcp__* reaches an actual deny through the Claude Code adapter" deny "$mcp_gated_payload"
check_payload "gatedToolPatterns: a non-matching tool is still allowed (gatedTools is empty here)" allow "$mcp_unmatched_payload"

echo ""
echo "-- no-policy-keys regression: behavior stays byte-identical --"
MINIMAL="$WORKDIR/project-minimal"
mkdir -p "$MINIMAL/.optimus"
cat >"$MINIMAL/.optimus/config.json" <<'JSON'
{
  "enabled": true,
  "updatedAt": "2026-09-11T00:00:00.000Z"
}
JSON
default_main_read_out="$(sed "s#__PROJECT__#$PROJECT#" "$FIXTURES/main-read.json" | node "$GATE")"
minimal_main_read_out="$(sed "s#__PROJECT__#$MINIMAL#" "$FIXTURES/main-read.json" | node "$GATE")"
if [ "$default_main_read_out" == "$minimal_main_read_out" ]; then
  echo "PASS: minimal config matches default output for Read deny"
  pass=$((pass+1))
else
  echo "FAIL: minimal config diverged for Read deny -- default: $default_main_read_out -- minimal: $minimal_main_read_out"
  fail=$((fail+1))
fi

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
