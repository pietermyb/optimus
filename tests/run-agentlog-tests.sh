#!/usr/bin/env bash
# Tests for the Agent-map stream (hooks/optimus-ledger.js recordAgentEvent
# and its four hook callers). Mirrors tests/run-ledger-tests.sh conventions:
# throwaway project dirs under a temp directory, activated via optimus-cli,
# fixture payloads fed to the hooks on stdin, assertions against
# <project>/.optimus/state/agents.jsonl. The enforcement ledger keeps its
# own suites — this one also asserts the two streams stay independent
# (agentMap:false silences agents.jsonl but never events.jsonl).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
GATE="$ROOT/hooks/optimus-gate.js"
GATE_CURSOR="$ROOT/hooks/optimus-gate-cursor.js"
SUBHOOK="$ROOT/hooks/optimus-subagent-cursor.js"
SESSIONHOOK="$ROOT/hooks/optimus-session-cursor.js"
LEDGER="$ROOT/hooks/optimus-ledger.js"
CLI="$ROOT/bin/optimus-cli"

# Prompt-side sentinel: must never reach agents.jsonl (titles come from
# description, which is a sanctioned field — see the dedicated privacy case).
SENTINEL="OPTIMUS_SENTINEL_9f3a1b"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"
AGENTLOG="$PROJECT/.optimus/state/agents.jsonl"

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

# Feeds a root fixture (with __PROJECT__ substituted) to a hook on stdin
# and prints stdout. Extra env can be passed as arg 3.
feed() {
  local hook="$1" fixture="$2" cwd="$3" extra_env="${4:-}"
  local payload
  payload="$(sed "s#__PROJECT__#$cwd#" "$fixture")"
  env $extra_env node "$hook" <<<"$payload"
}

feed_cursor() {
  local hook="$1" fixture="$2" cwd="$3" extra_env="${4:-}"
  local payload
  payload="$(sed "s#__PROJECT__#$cwd#" "$FIXTURES/cursor/$fixture")"
  env $extra_env node "$hook" <<<"$payload"
}

last_line() {
  if [ -f "$1" ]; then
    tail -n 1 "$1"
  else
    echo ""
  fi
}

# Reads a top-level JSON field out of a line via node (no jq dependency).
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

assert_no_field() {
  local label="$1" line="$2" key="$3"
  local got
  got="$(field "$line" "$key")"
  if [ -z "$got" ]; then
    ok "$label"
  else
    bad "$label (expected no $key, got: $line)"
  fi
}

# Direct call to recordAgentEvent against a project (bypasses the hooks).
direct_agent_event() {
  local cwd="$1" json="$2" extra_env="${3:-}"
  env $extra_env node -e '
    const { recordAgentEvent } = require(process.argv[1]);
    recordAgentEvent(process.argv[2], JSON.parse(process.argv[3]));
  ' "$LEDGER" "$cwd" "$json"
}

echo "== Optimus agent-log (agents.jsonl) tests =="

echo ""
echo "-- activating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on >/dev/null

echo ""
echo "-- case 1: recordAgentEvent writes the exact expected line --"
direct_agent_event "$PROJECT" \
  '{"ev":"agent_started","session_id":"sess-1","agent_conversation_id":"conv-sub-1","subagent_id":"toolu_1","agent_type":"explore","model":"gpt-5"}'
line="$(last_line "$AGENTLOG")"
assert_field "agent_started: ev"           "$line" ev                    "agent_started"
assert_field "agent_started: v==1"         "$line" v                     "1"
assert_field "agent_started: session_id"   "$line" session_id            "sess-1"
assert_field "agent_started: agent_conversation_id" "$line" agent_conversation_id "conv-sub-1"
assert_field "agent_started: subagent_id"  "$line" subagent_id           "toolu_1"
assert_field "agent_started: agent_type"   "$line" agent_type            "explore"
assert_field "agent_started: model"        "$line" model                 "gpt-5"
if [ -n "$(field "$line" ts)" ]; then ok "agent_started: ts present"; else bad "agent_started: ts missing (got: $line)"; fi

echo ""
echo "-- case 2: enforcement gate — allow writes agent_dispatch, deny writes nothing --"
rm -f "$AGENTLOG"
feed "$GATE" "$FIXTURES/ledger-agent-allowed.json" "$PROJECT" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "claude allow: ev"            "$line" ev          "agent_dispatch"
assert_field "claude allow: session_id"    "$line" session_id  "test-session"
assert_field "claude allow: tool_use_id"   "$line" tool_use_id "toolu_ledger_allowed"
assert_field "claude allow: model"         "$line" model       "haiku"
assert_field "claude allow: agent_type"    "$line" agent_type  "general-purpose"
assert_field "claude allow: title from description" "$line" title "Investigate findings"
assert_no_field "claude allow: prompt not recorded"  "$line" prompt

# Deny on a FRESH project: zero agent lines, enforcement ledger untouched.
DENYPROJECT="$WORKDIR/deny-project"
mkdir -p "$DENYPROJECT"
CLAUDE_PROJECT_DIR="$DENYPROJECT" node "$CLI" on >/dev/null
feed "$GATE" "$FIXTURES/ledger-agent-no-model.json" "$DENYPROJECT" >/dev/null
if [ ! -e "$DENYPROJECT/.optimus/state/agents.jsonl" ]; then
  ok "claude deny: no agents.jsonl created"
else
  bad "claude deny: agents.jsonl should not exist (got: $(last_line "$DENYPROJECT/.optimus/state/agents.jsonl"))"
fi
dline="$(last_line "$DENYPROJECT/.optimus/state/events.jsonl")"
assert_field "claude deny: enforcement still records dispatch_denied" "$dline" ev "dispatch_denied"

echo ""
echo "-- case 3: Cursor gate — allow/deny --"
rm -f "$AGENTLOG"
feed_cursor "$GATE_CURSOR" "task-cheap-model.json" "$PROJECT" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "cursor allow: ev"          "$line" ev          "agent_dispatch"
assert_field "cursor allow: session_id"  "$line" session_id  "probe-conv-main"
assert_field "cursor allow: tool_use_id" "$line" tool_use_id "toolu_bdrk_probe_task_cheap"
assert_field "cursor allow: title"       "$line" title       "read work.txt"
assert_field "cursor allow: agent_type"  "$line" agent_type  "explore"
assert_field "cursor allow: model"       "$line" model       "claude-haiku-4-5"

CURSOR_DENY="$WORKDIR/cursor-deny-project"
mkdir -p "$CURSOR_DENY"
CLAUDE_PROJECT_DIR="$CURSOR_DENY" node "$CLI" on >/dev/null
feed_cursor "$GATE_CURSOR" "task-no-model.json" "$CURSOR_DENY" >/dev/null
if [ ! -e "$CURSOR_DENY/.optimus/state/agents.jsonl" ]; then
  ok "cursor deny: no agents.jsonl created"
else
  bad "cursor deny: agents.jsonl should not exist"
fi

echo ""
echo "-- case 4: subagent hook — agent_started / agent_finished --"
rm -f "$AGENTLOG"
feed_cursor "$SUBHOOK" "subagent-start.json" "$PROJECT" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "start: ev"            "$line" ev                     "agent_started"
assert_field "start: session_id"    "$line" session_id             "probe-conv-main"
assert_field "start: agent_conversation_id" "$line" agent_conversation_id "probe-conv-sub"
assert_field "start: subagent_id"   "$line" subagent_id            "toolu_bdrk_probe_task_1"
assert_field "start: agent_type"    "$line" agent_type             "explore"
# Subagent hook must still emit its allow verdict regardless of the stream.
# (feed already captured stdout above without asserting; run again and check.)
sout="$(feed_cursor "$SUBHOOK" "subagent-start.json" "$PROJECT")"
if echo "$sout" | grep -q '"permission":"allow"'; then
  ok "start: hook still emits permission allow"
else
  bad "start: hook stdout broken -- $sout"
fi

# Sidecar marker still written alongside the stream row.
if [ -f "$PROJECT/.optimus/state/active-subagents/probe-conv-sub" ]; then
  ok "start: sidecar marker still written"
else
  bad "start: sidecar marker missing"
fi

feed_cursor "$SUBHOOK" "subagent-stop.json" "$PROJECT" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "stop: ev"            "$line" ev                     "agent_finished"
assert_field "stop: session_id"    "$line" session_id             "probe-conv-main"
assert_field "stop: agent_conversation_id" "$line" agent_conversation_id "probe-conv-sub"
assert_field "stop: subagent_id"   "$line" subagent_id            "toolu_bdrk_probe_task_1"
assert_field "stop: status"        "$line" status                 "completed"
assert_field "stop: agent_type"    "$line" agent_type             "explore"
# Success-path payload shape unverified (Stage-0 fallback): duration_ms
# absent on the shipped fixture must be omitted, not fabricated.
assert_no_field "stop: duration_ms omitted when absent" "$line" duration_ms
if [ ! -f "$PROJECT/.optimus/state/active-subagents/probe-conv-sub" ]; then
  ok "stop: sidecar marker still cleared"
else
  bad "stop: sidecar marker should have been cleared"
fi

echo ""
echo "-- case 5: orphan stop (error payload, no parent id) --"
ORPHAN_PAYLOAD='{"hook_event_name":"subagentStop","conversation_id":"conv-orphan","subagent_type":"unknown","status":"error","duration_ms":0,"error_message":"validation failed","cwd":"'"$PROJECT"'"}'
rm -f "$AGENTLOG"
printf '%s' "$ORPHAN_PAYLOAD" | node "$SUBHOOK" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "orphan: ev"        "$line" ev          "agent_finished"
assert_field "orphan: no parent — session_id falls back to conversation_id" "$line" session_id "conv-orphan"
assert_field "orphan: agent_conversation_id" "$line" agent_conversation_id "conv-orphan"
assert_field "orphan: status"    "$line" status      "error"
assert_field "orphan: duration_ms from payload" "$line" duration_ms "0"
assert_field "orphan: error_message" "$line" error_message "validation failed"
assert_field "orphan: agent_type preserved as unknown" "$line" agent_type "unknown"

echo ""
echo "-- case 6: session hook — session_started --"
rm -f "$AGENTLOG"
SESSION_PAYLOAD='{"hook_event_name":"sessionStart","conversation_id":"sess-root","model":"Claude Opus 5","cwd":"'"$PROJECT"'"}'
printf '%s' "$SESSION_PAYLOAD" | node "$SESSIONHOOK" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "session: ev"       "$line" ev         "session_started"
assert_field "session: session_id" "$line" session_id "sess-root"
assert_field "session: model"    "$line" model      "Claude Opus 5"

echo ""
echo "-- case 7: guards — kill switch, deactivated, agentMap key --"
GUARDPROJECT="$WORKDIR/guard-project"
mkdir -p "$GUARDPROJECT"
CLAUDE_PROJECT_DIR="$GUARDPROJECT" node "$CLI" on >/dev/null

rm -f "$GUARDPROJECT/.optimus/state/agents.jsonl"
direct_agent_event "$GUARDPROJECT" '{"ev":"agent_started","session_id":"s"}' "OPTIMUS_DISABLED=1"
if [ ! -e "$GUARDPROJECT/.optimus/state/agents.jsonl" ]; then
  ok "kill switch: no agents.jsonl"
else
  bad "kill switch: agents.jsonl written despite OPTIMUS_DISABLED=1"
fi

OFFPROJECT="$WORKDIR/off-project"
mkdir -p "$OFFPROJECT"
CLAUDE_PROJECT_DIR="$OFFPROJECT" node "$CLI" off >/dev/null
direct_agent_event "$OFFPROJECT" '{"ev":"agent_started","session_id":"s"}'
if [ ! -e "$OFFPROJECT/.optimus/state/agents.jsonl" ]; then
  ok "deactivated project: no agents.jsonl"
else
  bad "deactivated project: agents.jsonl written"
fi

# agentMap: false — stream off, enforcement untouched (rewritten below via setConfig too).
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  cfg.agentMap = false;
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
' "$GUARDPROJECT/.optimus/config.json"

rm -f "$GUARDPROJECT/.optimus/state/agents.jsonl" "$GUARDPROJECT/.optimus/state/events.jsonl"
feed "$GATE" "$FIXTURES/ledger-agent-allowed.json" "$GUARDPROJECT" >/dev/null
if [ ! -e "$GUARDPROJECT/.optimus/state/agents.jsonl" ]; then
  ok "agentMap:false: no agents.jsonl written"
else
  bad "agentMap:false: agents.jsonl written anyway"
fi
gline="$(last_line "$GUARDPROJECT/.optimus/state/events.jsonl")"
assert_field "agentMap:false: enforcement ledger unaffected" "$gline" ev "dispatch_allowed"

# Non-boolean agentMap is treated as absent (on).
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  cfg.agentMap = "false";
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
' "$GUARDPROJECT/.optimus/config.json"
rm -f "$GUARDPROJECT/.optimus/state/agents.jsonl"
direct_agent_event "$GUARDPROJECT" '{"ev":"agent_started","session_id":"s"}'
if [ -f "$GUARDPROJECT/.optimus/state/agents.jsonl" ]; then
  ok "agentMap non-boolean: treated as absent (stream on)"
else
  bad "agentMap non-boolean: stream should be on"
fi

echo ""
echo "-- case 8: setConfig preserves an explicit agentMap opt-out --"
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  cfg.agentMap = false;
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
' "$GUARDPROJECT/.optimus/config.json"
CLAUDE_PROJECT_DIR="$GUARDPROJECT" node "$CLI" on >/dev/null
preserved="$(node -e 'const c=require(process.argv[1]); process.stdout.write(String(c.agentMap));' "$GUARDPROJECT/.optimus/config.json")"
if [ "$preserved" = "false" ]; then
  ok "setConfig: agentMap:false survives optimus-cli on"
else
  bad "setConfig: agentMap lost on rewrite (got: $preserved)"
fi

echo ""
echo "-- case 9: field caps — 120-char title at the caller, 200-char writer cap --"
LONG_TITLE="$(node -e 'process.stdout.write("t".repeat(300))')"
rm -f "$AGENTLOG"
node -e '
  const { recordAgentEvent } = require(process.argv[1]);
  const title = process.argv[3];
  recordAgentEvent(process.argv[2], {
    ev: "agent_dispatch",
    session_id: "s",
    tool_use_id: "t1",
    title: title.length > 120 ? title.slice(0, 120) : title,
    agent_type: "x".repeat(300),
  });
' "$LEDGER" "$PROJECT" "$LONG_TITLE"
line="$(last_line "$AGENTLOG")"
title_len="$(node -e 'const o=JSON.parse(process.argv[1]); process.stdout.write(String(o.title.length));' "$line")"
type_len="$(node -e 'const o=JSON.parse(process.argv[1]); process.stdout.write(String(o.agent_type.length));' "$line")"
if [ "$title_len" = "120" ]; then ok "title truncated to 120 by the caller"; else bad "title length expected 120, got $title_len"; fi
if [ "$type_len" = "200" ]; then ok "writer caps string fields at 200"; else bad "agent_type length expected 200, got $type_len"; fi

echo ""
echo "-- case 10: rotation at the 1 MB cap --"
ROT="$WORKDIR/rotation-project"
mkdir -p "$ROT/.optimus/state"
CLAUDE_PROJECT_DIR="$ROT" node "$CLI" on >/dev/null
ROTLOG="$ROT/.optimus/state/agents.jsonl"
dd if=/dev/zero of="$ROTLOG" bs=1024 count=1024 >/dev/null 2>&1
direct_agent_event "$ROT" '{"ev":"session_started","session_id":"s"}'
if [ -f "$ROTLOG.1" ] && [ -f "$ROTLOG" ]; then
  old_size=$(wc -c <"$ROTLOG.1" | tr -d ' ')
  new_size=$(wc -c <"$ROTLOG" | tr -d ' ')
  if [ "$old_size" -ge 1048576 ] && [ "$new_size" -lt 1000 ]; then
    ok "rotation: agents.jsonl.1 holds the old ~1MB content, agents.jsonl reset small"
  else
    bad "rotation: unexpected sizes (old=$old_size new=$new_size)"
  fi
else
  bad "rotation: agents.jsonl.1 and/or agents.jsonl missing after rotating append"
fi

echo ""
echo "-- case 11: never throws, never writes to stdout under a read-only state dir --"
RO="$WORKDIR/readonly-project"
mkdir -p "$RO"
CLAUDE_PROJECT_DIR="$RO" node "$CLI" on >/dev/null
mkdir -p "$RO/.optimus/state"
chmod 500 "$RO/.optimus/state"
set +e
ro_out="$(node -e '
  const { recordAgentEvent } = require(process.argv[1]);
  recordAgentEvent(process.argv[2], { ev: "agent_started", session_id: "s" });
  process.stdout.write("NO_THROW");
' "$LEDGER" "$RO" 2>/dev/null)"
ro_rc=$?
# And the Cursor gate must still decide correctly with the stream unwritable.
payload="$(sed "s#__PROJECT__#$RO#" "$FIXTURES/cursor/task-cheap-model.json")"
gate_out="$(printf '%s' "$payload" | node "$GATE_CURSOR" 2>/dev/null)"
gate_rc=$?
set -e
chmod 700 "$RO/.optimus/state"
if [ "$ro_rc" -eq 0 ] && [ "$ro_out" = "NO_THROW" ]; then
  ok "read-only state dir: recordAgentEvent returns silently, exit 0, empty of stdout noise"
else
  bad "read-only state dir: recordAgentEvent broke (rc=$ro_rc out=$ro_out)"
fi
if [ "$gate_rc" -eq 0 ] && echo "$gate_out" | grep -q '"permission":"allow"'; then
  ok "read-only state dir: gate still allows dispatch, exit 0"
else
  bad "read-only state dir: gate broke (rc=$gate_rc out=$gate_out)"
fi

echo ""
echo "-- case 12: privacy — prompt text never reaches agents.jsonl; title is description only --"
PRIV_PAYLOAD='{"session_id":"priv-sess","cwd":"'"$PROJECT"'","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"safe title","prompt":"leaky '"$SENTINEL"' body","subagent_type":"general-purpose","model":"haiku"},"tool_use_id":"toolu_priv"}'
rm -f "$AGENTLOG"
printf '%s' "$PRIV_PAYLOAD" | node "$GATE" >/dev/null
line="$(last_line "$AGENTLOG")"
assert_field "privacy: title is the description" "$line" title "safe title"
if grep -q "$SENTINEL" "$AGENTLOG" 2>/dev/null; then
  bad "privacy: prompt sentinel leaked into agents.jsonl"
else
  ok "privacy: prompt sentinel absent from agents.jsonl"
fi

echo ""
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
