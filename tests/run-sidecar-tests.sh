#!/usr/bin/env bash
# Lifecycle tests for the Cursor subagent sidecar.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"
CLAUDE_PROJECT_DIR="$PROJECT" node "$ROOT/bin/optimus-cli" on >/dev/null

echo "== Optimus sidecar tests =="
node - "$ROOT" "$PROJECT" <<'NODE'
const path = require('path');
const fs = require('fs');
const assert = require('assert');
const [root, project] = process.argv.slice(2);
const s = require(path.join(root, 'hooks', 'optimus-sidecar.js'));
const dir = path.join(project, '.optimus', 'state', s.SIDECAR_DIRNAME);

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); console.log('PASS: ' + name); pass++; }
  catch (e) { console.log('FAIL: ' + name + ' -- ' + e.message); fail++; }
}

t('no parents on a fresh project', () => {
  assert.strictEqual(s.parentConversations(project).size, 0);
});
t('with no parents recorded, nothing is a subagent', () => {
  assert.strictEqual(s.isSubagentConversation(project, 'conv-main'), false);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-anything'), false);
});
t('markActive records the parent conversation, not the subagent id', () => {
  s.markActive(project, 'tooluse-1', 'conv-main');
  assert.deepStrictEqual([...s.parentConversations(project)], ['conv-main']);
});
t('the parent conversation is NOT a subagent', () => {
  assert.strictEqual(s.isSubagentConversation(project, 'conv-main'), false);
});
t('any other conversation IS a subagent while one is outstanding', () => {
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), true);
});
t('a missing conversation id is treated as the orchestrator, not a subagent', () => {
  assert.strictEqual(s.isSubagentConversation(project, undefined), false);
  assert.strictEqual(s.isSubagentConversation(project, ''), false);
});
t('parallel subagents from one parent collapse to one parent entry', () => {
  s.markActive(project, 'tooluse-2', 'conv-main');
  assert.strictEqual(fs.readdirSync(dir).length, 2);
  assert.deepStrictEqual([...s.parentConversations(project)], ['conv-main']);
});
t('clearing one of two leaves the parent recorded', () => {
  s.clearActive(project, 'tooluse-1');
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), true);
});
t('clearing the last one empties the parent set', () => {
  s.clearActive(project, 'tooluse-2');
  assert.strictEqual(s.parentConversations(project).size, 0);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), false);
});
t('a subagentStop with no matching start is a no-op, not a throw', () => {
  s.clearActive(project, 'never-started');
  assert.strictEqual(s.parentConversations(project).size, 0);
});
t('two parents can be outstanding at once', () => {
  s.markActive(project, 'tooluse-3', 'conv-main');
  s.markActive(project, 'tooluse-4', 'conv-other');
  assert.deepStrictEqual([...s.parentConversations(project)].sort(), ['conv-main', 'conv-other']);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-main'), false);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-other'), false);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), true);
  s.clearActive(project, 'tooluse-3');
  s.clearActive(project, 'tooluse-4');
});
t('an id with path separators cannot escape the sidecar dir', () => {
  s.markActive(project, '../../escaped', 'conv-main');
  assert.strictEqual(fs.existsSync(path.join(project, '.optimus', 'escaped')), false);
  s.clearActive(project, '../../escaped');
  assert.strictEqual(s.parentConversations(project).size, 0);
});
t('a stale marker is ignored and swept', () => {
  s.markActive(project, 'stale-1', 'conv-main');
  const f = path.join(dir, 'stale-1');
  const old = new Date(Date.now() - s.STALE_MS - 60000);
  fs.utimesSync(f, old, old);
  assert.strictEqual(s.parentConversations(project).size, 0);
  assert.strictEqual(fs.existsSync(f), false);
});
t('a marker with no readable parent id is ignored', () => {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'empty-1'), '');
  assert.strictEqual(s.parentConversations(project).size, 0);
  fs.unlinkSync(path.join(dir, 'empty-1'));
});
t('a non-Optimus directory yields no parents, not a throw', () => {
  assert.strictEqual(s.parentConversations('/tmp').size, 0);
  assert.strictEqual(s.isSubagentConversation('/tmp', 'conv-sub'), false);
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
NODE

echo ""
echo "-- the subagentStart/subagentStop hook drives the same sidecar --"
HOOK="$ROOT/hooks/optimus-subagent-cursor.js"
DIR="$PROJECT/.optimus/state/active-subagents"
pass=0
fail=0

start_payload() {
  printf '{"hook_event_name":"subagentStart","conversation_id":"conv-sub","parent_conversation_id":"conv-main","subagent_id":"tooluse-9","tool_call_id":"tooluse-9","cwd":"%s"}' "$PROJECT"
}
stop_payload() {
  printf '{"hook_event_name":"subagentStop","conversation_id":"conv-sub","parent_conversation_id":"conv-main","subagent_id":"tooluse-9","cwd":"%s"}' "$PROJECT"
}

out="$(start_payload | node "$HOOK")"
if echo "$out" | grep -q '"permission":"allow"'; then
  echo "PASS: subagentStart emits allow"; pass=$((pass+1))
else
  echo "FAIL: subagentStart did not emit allow -- $out"; fail=$((fail+1))
fi
if [ "$(cat "$DIR/tooluse-9" 2>/dev/null)" == "conv-main" ]; then
  echo "PASS: subagentStart recorded the parent conversation"; pass=$((pass+1))
else
  echo "FAIL: marker missing or wrong -- $(ls -1 "$DIR" 2>/dev/null)"; fail=$((fail+1))
fi
stop_payload | node "$HOOK" >/dev/null
if [ ! -e "$DIR/tooluse-9" ]; then
  echo "PASS: subagentStop cleared the marker"; pass=$((pass+1))
else
  echo "FAIL: subagentStop left the marker behind"; fail=$((fail+1))
fi

echo ""
echo "-- an orphan subagentStop is harmless --"
if printf '{"hook_event_name":"subagentStop","subagent_id":"orphan-1","subagent_type":"unknown","status":"error","cwd":"%s"}' "$PROJECT" | node "$HOOK" | grep -q '"permission":"allow"'; then
  echo "PASS: orphan subagentStop allows"; pass=$((pass+1))
else
  echo "FAIL: orphan subagentStop misbehaved"; fail=$((fail+1))
fi

echo ""
echo "-- inactive project and kill switch write nothing --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$ROOT/bin/optimus-cli" off >/dev/null
start_payload | node "$HOOK" >/dev/null
if [ ! -e "$DIR/tooluse-9" ]; then
  echo "PASS: inactive project writes no marker"; pass=$((pass+1))
else
  echo "FAIL: wrote a marker while inactive"; fail=$((fail+1))
fi
CLAUDE_PROJECT_DIR="$PROJECT" node "$ROOT/bin/optimus-cli" on >/dev/null
start_payload | OPTIMUS_DISABLED=1 node "$HOOK" >/dev/null
if [ ! -e "$DIR/tooluse-9" ]; then
  echo "PASS: kill switch writes no marker"; pass=$((pass+1))
else
  echo "FAIL: wrote a marker with the kill switch on"; fail=$((fail+1))
fi

echo ""
echo "-- malformed stdin is harmless --"
if echo 'not json' | node "$HOOK" | grep -q '"permission":"allow"'; then
  echo "PASS: malformed payload allows"; pass=$((pass+1))
else
  echo "FAIL: malformed payload misbehaved"; fail=$((fail+1))
fi

echo ""
echo "== hook: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
