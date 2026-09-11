#!/usr/bin/env bash
# Unit tests for bin/optimus-stats's project-directory resolution.
#
# Does not touch the real ~/.claude — builds its own throwaway
# CLAUDE_CONFIG_DIR under a temp directory, populates it with small
# synthetic session transcripts, and runs bin/optimus-stats with
# CLAUDE_CONFIG_DIR pointed at that throwaway root and CLAUDE_PROJECT_DIR
# pointed at a fake target cwd. Asserts on the actual reported numbers /
# the presence-or-absence of the "no data" message, not just exit codes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATS="$ROOT/bin/optimus-stats"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0

# Computes the slug the way the FIXED code is supposed to (every
# non-alphanumeric character -> dash). Used by tests to build fixtures
# for the fast path; deliberately reimplemented here rather than sourced
# from bin/optimus-stats so the test doesn't just echo the implementation
# back at itself.
correct_slug() {
  printf '%s' "$1" | sed -E 's/[^a-zA-Z0-9]/-/g'
}

# Appends one synthetic assistant-turn transcript line to $1.
write_assistant_line() {
  local file="$1" cwd="$2" model="$3" input="$4" output="$5" cache_write="$6" cache_read="$7"
  printf '{"cwd":"%s","type":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$cwd" "$model" "$input" "$output" "$cache_write" "$cache_read" >>"$file"
}

# Appends an assistant turn whose content carries a Task dispatch
# tool_use block, plus that turn's own usage. This is the "cache write on
# dispatch" turn -- the orchestrator paying to hand context to a subagent.
write_tool_use_line() {
  local file="$1" cwd="$2" model="$3" tool_use_id="$4" subagent_model="$5" cache_write="$6"
  printf '{"cwd":"%s","type":"assistant","message":{"model":"%s","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":%s,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"%s","name":"Task","input":{"model":"%s","prompt":"go"}}]}}\n' \
    "$cwd" "$model" "$cache_write" "$tool_use_id" "$subagent_model" >>"$file"
}

# Appends the user-role turn carrying the paired tool_result: the subagent's
# summary coming back into the orchestrator's context.
write_tool_result_line() {
  local file="$1" cwd="$2" tool_use_id="$3"
  printf '{"cwd":"%s","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"done"}]}}\n' \
    "$cwd" "$tool_use_id" >>"$file"
}

# Appends a non-JSON garbage line (simulates a half-written/corrupt line).
write_garbage_line() {
  local file="$1"
  printf 'not valid json at all {{{\n' >>"$file"
}

# Writes a one-line synthetic subagent transcript at
# "$1/agent-$2.jsonl" reporting $3 as the (actual, resolved) model of its
# only assistant turn -- what optimus-stats' existing firstModelIn()/
# dispatchesByModel accounting reads, independent of anything the ledger
# recorded as the *requested* alias.
write_subagent_transcript() {
  local subdir="$1" agent_id="$2" model="$3"
  mkdir -p "$subdir"
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
    "$model" >"$subdir/agent-$agent_id.jsonl"
}

# Appends one raw ledger event line verbatim (caller supplies the full JSON
# object as a string) to $1. Used to build synthetic
# .optimus/state/events.jsonl / events.jsonl.1 fixtures directly, since
# these tests exercise optimus-stats' *reader*, not optimus-ledger.js's
# writer (that module already has its own dedicated, passing test suite).
write_ledger_event() {
  local file="$1" json="$2"
  printf '%s\n' "$json" >>"$file"
}

run_stats() {
  local config_dir="$1" target_cwd="$2"
  CLAUDE_CONFIG_DIR="$config_dir" CLAUDE_PROJECT_DIR="$target_cwd" node "$STATS"
}

# check NAME CONFIG_DIR TARGET_CWD  MUST_CONTAIN... -- (grep patterns that must all be present)
# Usage: check NAME CONFIG_DIR TARGET_CWD MUST_CONTAIN MUST_NOT_CONTAIN
check_contains() {
  local name="$1" config_dir="$2" target_cwd="$3" must_contain="$4" must_not_contain="$5"
  local out rc=0
  out="$(run_stats "$config_dir" "$target_cwd")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name (optimus-stats exited non-zero: $rc) -- output: $out"
    fail=$((fail+1))
    return
  fi
  if [ -n "$must_contain" ] && ! echo "$out" | grep -qF "$must_contain"; then
    echo "FAIL: $name (expected output to contain '$must_contain') -- output: $out"
    fail=$((fail+1))
    return
  fi
  if [ -n "$must_not_contain" ] && echo "$out" | grep -qF "$must_not_contain"; then
    echo "FAIL: $name (expected output NOT to contain '$must_not_contain') -- output: $out"
    fail=$((fail+1))
    return
  fi
  echo "PASS: $name"
  pass=$((pass+1))
}

NO_DATA="No Optimus usage data yet"

echo "== Optimus stats resolution tests =="

# -- (a) regression: cwd containing '@' and '.' must resolve via the fast
#    path and report real usage, not "no data". This is the exact bug:
#    the old slugForCwd() only replaced '/', so it would look for a
#    directory that never existed.
CFG_A="$WORKDIR/cfg-a"
mkdir -p "$CFG_A/projects"
CWD_A="/Users/someone@example.com/Documents/PAM/optimus"
SLUG_A="$(correct_slug "$CWD_A")"
mkdir -p "$CFG_A/projects/$SLUG_A"
write_assistant_line "$CFG_A/projects/$SLUG_A/session-a.jsonl" "$CWD_A" "claude-sonnet-5" 1234 567 10 20
check_contains "(a) '@'/'.' cwd resolves via fast path" "$CFG_A" "$CWD_A" "input=1234" "$NO_DATA"

# -- (b) underscore path resolves via the fast path.
CFG_B="$WORKDIR/cfg-b"
mkdir -p "$CFG_B/projects"
CWD_B="/tmp/x/rnd_agent_base"
SLUG_B="$(correct_slug "$CWD_B")"
mkdir -p "$CFG_B/projects/$SLUG_B"
write_assistant_line "$CFG_B/projects/$SLUG_B/session-b.jsonl" "$CWD_B" "claude-sonnet-5" 2222 333 5 7
check_contains "(b) underscore cwd resolves via fast path" "$CFG_B" "$CWD_B" "input=2222" "$NO_DATA"

# -- (c) fallback: a project directory whose NAME does not match the
#    computed slug at all, but whose transcript's top-level `cwd` field
#    matches the target exactly, must still resolve. Proves layer 2
#    (the transcript-cwd fallback) works independently of the slug guess.
CFG_C="$WORKDIR/cfg-c"
mkdir -p "$CFG_C/projects"
CWD_C="/Users/fallback-tester/Documents/PAM/optimus-fallback-case"
mkdir -p "$CFG_C/projects/this-name-does-not-match-any-slug-rule"
write_assistant_line "$CFG_C/projects/this-name-does-not-match-any-slug-rule/session-c.jsonl" "$CWD_C" "claude-haiku-4-5" 4444 111 1 2
check_contains "(c) mismatched dir name resolves via transcript-cwd fallback" "$CFG_C" "$CWD_C" "input=4444" "$NO_DATA"

# -- (d) genuinely absent project: no projects root at all. Must exit 0
#    with the "no data" message, and must not crash even though the
#    fallback's own readdir target doesn't exist.
CFG_D="$WORKDIR/cfg-d"
mkdir -p "$CFG_D"
CWD_D="/Users/nobody/Nothing/Here"
check_contains "(d) absent project reports no-data, no crash" "$CFG_D" "$CWD_D" "$NO_DATA" ""

# -- (e) a malformed/unparseable .jsonl line present among valid ones
#    must not crash the run, in either the fallback directory-scan
#    (which peeks at the first few lines of a candidate transcript) or
#    the full usage-accounting pass. Uses a mismatched directory name
#    (forcing the fallback scan) whose transcript starts with garbage,
#    followed by a valid line carrying the matching cwd, followed by
#    more garbage mixed with valid usage lines.
CFG_E="$WORKDIR/cfg-e"
mkdir -p "$CFG_E/projects"
CWD_E="/Users/malformed-tester/Documents/PAM/optimus-broken-case"
mkdir -p "$CFG_E/projects/some-other-legacy-dir-name"
TRANSCRIPT_E="$CFG_E/projects/some-other-legacy-dir-name/session-e.jsonl"
write_garbage_line "$TRANSCRIPT_E"
write_assistant_line "$TRANSCRIPT_E" "$CWD_E" "claude-sonnet-5" 999 88 3 4
write_garbage_line "$TRANSCRIPT_E"
write_assistant_line "$TRANSCRIPT_E" "$CWD_E" "claude-sonnet-5" 111 22 0 0
check_contains "(e) malformed line among valid ones does not crash" "$CFG_E" "$CWD_E" "input=1110" "$NO_DATA"

echo ""
echo "== Optimus stats: dispatch cycle parsing =="

CFG_DISPATCH="$WORKDIR/cfg-dispatch-parse"
mkdir -p "$CFG_DISPATCH/projects"
TARGET_CWD="$WORKDIR/dispatch-parse-project"
SLUG_DISPATCH="$(correct_slug "$TARGET_CWD")"
PROJECTS="$CFG_DISPATCH/projects"
mkdir -p "$PROJECTS/$SLUG_DISPATCH"

SESSION="$PROJECTS/$SLUG_DISPATCH/session-a.jsonl"
write_assistant_line   "$SESSION" "$TARGET_CWD" "claude-opus-5" 100 50 0 0
write_tool_use_line    "$SESSION" "$TARGET_CWD" "claude-opus-5" "tu-1" "claude-haiku-4-5" 4000
write_tool_result_line "$SESSION" "$TARGET_CWD" "tu-1"
write_assistant_line   "$SESSION" "$TARGET_CWD" "claude-opus-5" 0 20 0 8000

if node -e '
  const s = require(process.argv[1]);
  const cycles = s.parseOrchestratorDispatches(process.argv[2]);
  if (cycles.length !== 1) throw new Error("expected 1 cycle, got " + cycles.length);
  if (cycles[0].toolUseId !== "tu-1") throw new Error("wrong tool_use_id");
  if (cycles[0].endIndex <= cycles[0].startIndex) throw new Error("result not paired");
  console.log("ok");
' "$STATS" "$SESSION" | grep -q ok; then
  echo "PASS: pairs a Task tool_use with its tool_result"; pass=$((pass+1))
else
  echo "FAIL: dispatch cycle not parsed"; fail=$((fail+1))
fi


CFG_DISPATCH_NON="$WORKDIR/cfg-dispatch-parse-non"
mkdir -p "$CFG_DISPATCH_NON/projects"
TARGET_CWD_NON="$WORKDIR/dispatch-parse-non-project"
SLUG_DISPATCH_NON="$(correct_slug "$TARGET_CWD_NON")"
PROJECTS_NON="$CFG_DISPATCH_NON/projects"
mkdir -p "$PROJECTS_NON/$SLUG_DISPATCH_NON"
SESSION_NON="$PROJECTS_NON/$SLUG_DISPATCH_NON/session-non.jsonl"
printf '{"cwd":"%s","type":"assistant","message":{"model":"%s","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":2000,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"%s","name":"Read","input":{"path":"README.md"}}]}}\n' \
  "$TARGET_CWD_NON" "claude-opus-5" "tu-non-1" >>"$SESSION_NON"

if node -e '
  const s = require(process.argv[1]);
  const cycles = s.parseOrchestratorDispatches(process.argv[2]);
  if (cycles.length !== 0) throw new Error("expected 0 cycles, got " + cycles.length);
  console.log("ok");
' "$STATS" "$SESSION_NON" | grep -q ok; then
  echo "PASS: a non-dispatch tool_use is ignored"; pass=$((pass+1))
else
  echo "FAIL: non-dispatch tool_use was not ignored"; fail=$((fail+1))
fi

CFG_DISPATCH_GARBAGE="$WORKDIR/cfg-dispatch-parse-garbage"
mkdir -p "$CFG_DISPATCH_GARBAGE/projects"
TARGET_CWD_GARBAGE="$WORKDIR/dispatch-parse-garbage-project"
SLUG_DISPATCH_GARBAGE="$(correct_slug "$TARGET_CWD_GARBAGE")"
PROJECTS_GARBAGE="$CFG_DISPATCH_GARBAGE/projects"
mkdir -p "$PROJECTS_GARBAGE/$SLUG_DISPATCH_GARBAGE"
SESSION_GARBAGE="$PROJECTS_GARBAGE/$SLUG_DISPATCH_GARBAGE/session-garbage.jsonl"
write_garbage_line "$SESSION_GARBAGE"
write_tool_use_line "$SESSION_GARBAGE" "$TARGET_CWD_GARBAGE" "claude-opus-5" "tu-garbage-1" "claude-haiku-4-5" 1234
write_garbage_line "$SESSION_GARBAGE"
write_tool_result_line "$SESSION_GARBAGE" "$TARGET_CWD_GARBAGE" "tu-garbage-1"
write_garbage_line "$SESSION_GARBAGE"

if node -e '
  const s = require(process.argv[1]);
  const cycles = s.parseOrchestratorDispatches(process.argv[2]);
  if (cycles.length !== 1) throw new Error("expected 1 cycle, got " + cycles.length);
  if (cycles[0].endIndex === -1) throw new Error("expected paired cycle endIndex, got -1");
  console.log("ok");
' "$STATS" "$SESSION_GARBAGE" | grep -q ok; then
  echo "PASS: garbage lines do not abort parsing"; pass=$((pass+1))
else
  echo "FAIL: garbage lines broke dispatch parsing"; fail=$((fail+1))
fi

CFG_DISPATCH_UNPAIRED="$WORKDIR/cfg-dispatch-parse-unpaired"
mkdir -p "$CFG_DISPATCH_UNPAIRED/projects"
TARGET_CWD_UNPAIRED="$WORKDIR/dispatch-parse-unpaired-project"
SLUG_DISPATCH_UNPAIRED="$(correct_slug "$TARGET_CWD_UNPAIRED")"
PROJECTS_UNPAIRED="$CFG_DISPATCH_UNPAIRED/projects"
mkdir -p "$PROJECTS_UNPAIRED/$SLUG_DISPATCH_UNPAIRED"
SESSION_UNPAIRED="$PROJECTS_UNPAIRED/$SLUG_DISPATCH_UNPAIRED/session-unpaired.jsonl"
write_tool_use_line "$SESSION_UNPAIRED" "$TARGET_CWD_UNPAIRED" "claude-opus-5" "tu-unpaired-1" "claude-haiku-4-5" 2222

if node -e '
  const s = require(process.argv[1]);
  const cycles = s.parseOrchestratorDispatches(process.argv[2]);
  if (cycles.length !== 1) throw new Error("expected 1 cycle, got " + cycles.length);
  if (cycles[0].endIndex !== -1) throw new Error("expected endIndex -1, got " + cycles[0].endIndex);
  console.log("ok");
' "$STATS" "$SESSION_UNPAIRED" | grep -q ok; then
  echo "PASS: an unpaired dispatch is reported with endIndex === -1"; pass=$((pass+1))
else
  echo "FAIL: unpaired dispatch was not reported with endIndex === -1"; fail=$((fail+1))
fi

REQ_OUT="$(node -e 'require(process.argv[1])' "$STATS")"
if [ -z "$REQ_OUT" ]; then
  echo "PASS: requiring bin/optimus-stats as a module does not run the CLI"; pass=$((pass+1))
else
  echo "FAIL: requiring bin/optimus-stats produced CLI output: $REQ_OUT"; fail=$((fail+1))
fi

echo ""
echo "== Optimus stats: coordinator token attribution =="

CFG_COORD_UNPAIRED="$WORKDIR/cfg-coord-unpaired"
mkdir -p "$CFG_COORD_UNPAIRED/projects"
TARGET_CWD_COORD_UNPAIRED="$WORKDIR/coord-unpaired-project"
SLUG_COORD_UNPAIRED="$(correct_slug "$TARGET_CWD_COORD_UNPAIRED")"
PROJECTS_COORD_UNPAIRED="$CFG_COORD_UNPAIRED/projects"
mkdir -p "$PROJECTS_COORD_UNPAIRED/$SLUG_COORD_UNPAIRED"
SESSION_COORD_UNPAIRED="$PROJECTS_COORD_UNPAIRED/$SLUG_COORD_UNPAIRED/session-coord-unpaired.jsonl"
write_tool_use_line "$SESSION_COORD_UNPAIRED" "$TARGET_CWD_COORD_UNPAIRED" "claude-opus-5" "tu-coord-unpaired-1" "claude-haiku-4-5" 3000

if node -e '
  const s = require(process.argv[1]);
  const c = s.coordinatorUsageFor(process.argv[2]);
  if (c.cycles !== 1) throw new Error("expected 1 cycle, got " + c.cycles);
  if (c.unresolved !== 1) throw new Error("expected 1 unresolved, got " + c.unresolved);
  const u = c.byModel["claude-opus-5"];
  if (!u) throw new Error("dispatch-side model missing from byModel");
  if (u.cache_creation_input_tokens !== 3000) throw new Error("dispatch cache write not attributed, got " + u.cache_creation_input_tokens);
  console.log("ok");
' "$STATS" "$SESSION_COORD_UNPAIRED" | grep -q ok; then
  echo "PASS: an unpaired dispatch is reported as unresolved"; pass=$((pass+1))
else
  echo "FAIL: unpaired dispatch not reported as unresolved by coordinatorUsageFor"; fail=$((fail+1))
fi

if node -e '
  const s = require(process.argv[1]);
  const c = s.coordinatorUsageFor(process.argv[2]);
  const u = c.byModel["claude-opus-5"];
  if (u.cache_creation_input_tokens !== 4000) throw new Error("dispatch cache write not attributed");
  if (u.cache_read_input_tokens !== 8000) throw new Error("summary cache read not attributed");
  const cost = s.costFor("claude-opus-5", u);
  if (Math.abs(cost - 0.0290) > 1e-6) throw new Error("coordinator cost " + cost);
  console.log("ok");
' "$STATS" "$SESSION" | grep -q ok; then
  echo "PASS: coordinator tokens priced at the orchestrator rate"; pass=$((pass+1))
else
  echo "FAIL: coordinator attribution wrong"; fail=$((fail+1))
fi

CFG_COORD_NONE="$WORKDIR/cfg-coord-none"
mkdir -p "$CFG_COORD_NONE/projects"
TARGET_CWD_COORD_NONE="$WORKDIR/coord-none-project"
SLUG_COORD_NONE="$(correct_slug "$TARGET_CWD_COORD_NONE")"
PROJECTS_COORD_NONE="$CFG_COORD_NONE/projects"
mkdir -p "$PROJECTS_COORD_NONE/$SLUG_COORD_NONE"
SESSION_COORD_NONE="$PROJECTS_COORD_NONE/$SLUG_COORD_NONE/session-coord-none.jsonl"
write_assistant_line "$SESSION_COORD_NONE" "$TARGET_CWD_COORD_NONE" "claude-opus-5" 100 50 0 0
write_assistant_line "$SESSION_COORD_NONE" "$TARGET_CWD_COORD_NONE" "claude-sonnet-5" 10 5 0 0

if node -e '
  const s = require(process.argv[1]);
  const c = s.coordinatorUsageFor(process.argv[2]);
  if (c.cycles !== 0) throw new Error("expected 0 cycles, got " + c.cycles);
  if (Object.keys(c.byModel).length !== 0) throw new Error("expected empty byModel, got " + JSON.stringify(c.byModel));
  console.log("ok");
' "$STATS" "$SESSION_COORD_NONE" | grep -q ok; then
  echo "PASS: a transcript with no dispatches has no coordinator cost"; pass=$((pass+1))
else
  echo "FAIL: no-dispatch transcript reported a nonzero coordinator cost"; fail=$((fail+1))
fi

CFG_COORD_GARBAGE="$WORKDIR/cfg-coord-garbage"
mkdir -p "$CFG_COORD_GARBAGE/projects"
TARGET_CWD_COORD_GARBAGE="$WORKDIR/coord-garbage-project"
SLUG_COORD_GARBAGE="$(correct_slug "$TARGET_CWD_COORD_GARBAGE")"
PROJECTS_COORD_GARBAGE="$CFG_COORD_GARBAGE/projects"
mkdir -p "$PROJECTS_COORD_GARBAGE/$SLUG_COORD_GARBAGE"
SESSION_COORD_GARBAGE="$PROJECTS_COORD_GARBAGE/$SLUG_COORD_GARBAGE/session-coord-garbage.jsonl"
write_garbage_line "$SESSION_COORD_GARBAGE"
write_tool_use_line "$SESSION_COORD_GARBAGE" "$TARGET_CWD_COORD_GARBAGE" "claude-opus-5" "tu-coord-garbage-1" "claude-haiku-4-5" 1500
write_garbage_line "$SESSION_COORD_GARBAGE"
write_tool_result_line "$SESSION_COORD_GARBAGE" "$TARGET_CWD_COORD_GARBAGE" "tu-coord-garbage-1"
write_garbage_line "$SESSION_COORD_GARBAGE"
write_assistant_line "$SESSION_COORD_GARBAGE" "$TARGET_CWD_COORD_GARBAGE" "claude-opus-5" 0 10 0 2500
write_garbage_line "$SESSION_COORD_GARBAGE"

if node -e '
  const s = require(process.argv[1]);
  const c = s.coordinatorUsageFor(process.argv[2]);
  if (c.cycles !== 1) throw new Error("expected 1 cycle, got " + c.cycles);
  if (c.unresolved !== 0) throw new Error("expected 0 unresolved, got " + c.unresolved);
  const u = c.byModel["claude-opus-5"];
  if (!u) throw new Error("byModel missing claude-opus-5");
  if (u.cache_creation_input_tokens !== 1500) throw new Error("dispatch cache write not attributed, got " + u.cache_creation_input_tokens);
  if (u.cache_read_input_tokens !== 2500) throw new Error("summary cache read not attributed, got " + u.cache_read_input_tokens);
  console.log("ok");
' "$STATS" "$SESSION_COORD_GARBAGE" | grep -q ok; then
  echo "PASS: garbage lines do not abort coordinator attribution"; pass=$((pass+1))
else
  echo "FAIL: garbage lines broke coordinator attribution"; fail=$((fail+1))
fi

echo ""
echo "== Optimus stats: gross/coordinator/net savings output =="

CFG_NET="$WORKDIR/cfg-net-savings"
mkdir -p "$CFG_NET/projects"
TARGET_CWD_NET="$WORKDIR/net-savings-project"
SLUG_NET="$(correct_slug "$TARGET_CWD_NET")"
PROJECTS_NET="$CFG_NET/projects"
mkdir -p "$PROJECTS_NET/$SLUG_NET"
SESSION_NET="$PROJECTS_NET/$SLUG_NET/session-net.jsonl"
write_assistant_line   "$SESSION_NET" "$TARGET_CWD_NET" "claude-opus-5" 100 50 0 0
write_tool_use_line    "$SESSION_NET" "$TARGET_CWD_NET" "claude-opus-5" "tu-net-1" "claude-haiku-4-5" 4000
write_tool_result_line "$SESSION_NET" "$TARGET_CWD_NET" "tu-net-1"
write_assistant_line   "$SESSION_NET" "$TARGET_CWD_NET" "claude-opus-5" 0 20 0 8000
write_subagent_transcript "$PROJECTS_NET/$SLUG_NET/session-net/subagents" "1" "claude-haiku-4-5"

out_net="$(run_stats "$CFG_NET" "$TARGET_CWD_NET")"
for needle in \
  "estimated saving (gross)" \
  "coordinator overhead" \
  "estimated saving (net)" \
  "ESTIMATE, not a fact: assumes opus would have used the same token volume for the same work." \
  "Real savings may differ — a bigger model can sometimes solve a task in fewer turns/tokens," \
  "or a smaller model may need more turns to reach the same result." \
  "net figure additionally assumes"
do
  if echo "$out_net" | grep -qF "$needle"; then
    echo "PASS: output contains '$needle'"; pass=$((pass+1))
  else
    echo "FAIL: output missing '$needle'"; fail=$((fail+1))
  fi
done

gross_net="$(echo "$out_net" | sed -n 's/.*estimated saving (gross) *: \$//p')"
coord_net="$(echo "$out_net" | sed -n 's/.*coordinator overhead *: \$//p')"
net_net="$(echo "$out_net" | sed -n 's/.*estimated saving (net) *: \$//p')"
if node -e 'const [g,c,n]=process.argv.slice(1).map(Number); if (Math.abs((g-c)-n) > 1e-4) process.exit(1)' "$gross_net" "$coord_net" "$net_net"; then
  echo "PASS: net saving equals gross minus coordinator"; pass=$((pass+1))
else
  echo "FAIL: net saving arithmetic ($gross_net - $coord_net != $net_net)"; fail=$((fail+1))
fi

CFG_NET_NONE="$WORKDIR/cfg-net-savings-none"
mkdir -p "$CFG_NET_NONE/projects"
TARGET_CWD_NET_NONE="$WORKDIR/net-savings-none-project"
SLUG_NET_NONE="$(correct_slug "$TARGET_CWD_NET_NONE")"
PROJECTS_NET_NONE="$CFG_NET_NONE/projects"
mkdir -p "$PROJECTS_NET_NONE/$SLUG_NET_NONE"
SESSION_NET_NONE="$PROJECTS_NET_NONE/$SLUG_NET_NONE/session-net-none.jsonl"
write_assistant_line "$SESSION_NET_NONE" "$TARGET_CWD_NET_NONE" "claude-opus-5" 100 50 0 0
write_subagent_transcript "$PROJECTS_NET_NONE/$SLUG_NET_NONE/session-net-none/subagents" "1" "claude-haiku-4-5"

out_net_none="$(run_stats "$CFG_NET_NONE" "$TARGET_CWD_NET_NONE")"
if echo "$out_net_none" | grep -qF "coordinator overhead      : \$0.0000"; then
  echo "PASS: no-dispatch run reports zero coordinator overhead"; pass=$((pass+1))
else
  echo "FAIL: no-dispatch run did not report zero coordinator overhead"; fail=$((fail+1))
fi

gross_net_none="$(echo "$out_net_none" | sed -n 's/.*estimated saving (gross) *: \$//p')"
coord_net_none="$(echo "$out_net_none" | sed -n 's/.*coordinator overhead *: \$//p')"
net_net_none="$(echo "$out_net_none" | sed -n 's/.*estimated saving (net) *: \$//p')"
if node -e 'const [g,c,n]=process.argv.slice(1).map(Number); if (Math.abs((g-c)-n) > 1e-4 || Math.abs(c) > 1e-9) process.exit(1)' "$gross_net_none" "$coord_net_none" "$net_net_none"; then
  echo "PASS: no-dispatch net saving equals gross"; pass=$((pass+1))
else
  echo "FAIL: no-dispatch arithmetic ($gross_net_none - $coord_net_none != $net_net_none)"; fail=$((fail+1))
fi

echo ""
echo "== Optimus stats: enforcement ledger reporting =="

# Every case below needs a *real* target-project directory (not just a
# fabricated cwd string used purely for slug matching, as cases a-e above
# use) because the ledger section resolves its own project root via
# findProjectRoot() walking up from cwd looking for an actual
# .optimus/config.json file on disk -- same helper hooks/optimus-config.js
# and hooks/optimus-ledger.js already use. And every case (except the
# "no ledger" one) also needs at least one real transcript, since the new
# section is printed after the existing dispatch tallies in the script's
# normal full-output path -- it is not reachable from the early "no data
# yet" exits, which is a deliberate scope decision (see the write-up
# accompanying this change).

LEDGER_SECTION_MARKER="Enforcement ledger summary"

# -- (f) mix of all four event types produces correct, real-number counts.
CFG_F="$WORKDIR/cfg-ledger-mix"
PROJ_F="$WORKDIR/ledger-mix-project"
mkdir -p "$PROJ_F/.optimus/state"
echo '{"enabled":true}' >"$PROJ_F/.optimus/config.json"
mkdir -p "$CFG_F/projects"
SLUG_F="$(correct_slug "$PROJ_F")"
mkdir -p "$CFG_F/projects/$SLUG_F"
write_assistant_line "$CFG_F/projects/$SLUG_F/session-f.jsonl" "$PROJ_F" "claude-sonnet-5" 100 50 0 0

LEDGER_F="$PROJ_F/.optimus/state/events.jsonl"
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:00.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t1","model":"haiku","agent_type":"general-purpose"}'
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:01.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t2","model":"sonnet","agent_type":"general-purpose"}'
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:02.000Z","ev":"dispatch_denied","session_id":"s1","tool_use_id":"t3","reason":"no_model"}'
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:03.000Z","ev":"dispatch_denied","session_id":"s1","tool_use_id":"t4","reason":"expensive_model","model":"opus"}'
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:04.000Z","ev":"work_tool_denied","session_id":"s1","tool":"Read"}'
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:05.000Z","ev":"work_tool_denied","session_id":"s1","tool":"Read"}'
write_ledger_event "$LEDGER_F" '{"v":1,"ts":"2026-01-01T00:00:06.000Z","ev":"bash_nudge","session_id":"s1","cmd_head":"cat"}'

check_contains "(f) mix: dispatches allowed = 2"        "$CFG_F" "$PROJ_F" "dispatches allowed         : 2" ""
check_contains "(f) mix: denied reason no_model = 1"     "$CFG_F" "$PROJ_F" '"no_model":1' ""
check_contains "(f) mix: denied reason expensive_model=1" "$CFG_F" "$PROJ_F" '"expensive_model":1' ""
check_contains "(f) mix: work-tool denied Read = 2"      "$CFG_F" "$PROJ_F" '"Read":2' ""
check_contains "(f) mix: bash nudge cat = 1"             "$CFG_F" "$PROJ_F" '"cat":1' ""

# -- (g) no ledger at all -> section absent, and the rest of the output is
#    byte-for-byte unchanged. Captures output at three points: no
#    .optimus/ at all, .optimus/config.json present but no events file
#    yet, and finally with a real ledger -- asserting the section stays
#    absent through the first two and that adding the ledger only ever
#    *appends* to what was there before (the pre-existing output is an
#    exact prefix of the new output).
CFG_G="$WORKDIR/cfg-ledger-none"
PROJ_G="$WORKDIR/ledger-none-project"
mkdir -p "$PROJ_G"
mkdir -p "$CFG_G/projects"
SLUG_G="$(correct_slug "$PROJ_G")"
mkdir -p "$CFG_G/projects/$SLUG_G"
write_assistant_line "$CFG_G/projects/$SLUG_G/session-g.jsonl" "$PROJ_G" "claude-sonnet-5" 100 50 0 0

BEFORE_G="$(run_stats "$CFG_G" "$PROJ_G")" || true
if echo "$BEFORE_G" | grep -qF "$LEDGER_SECTION_MARKER"; then
  echo "FAIL: (g) no .optimus/ at all: section should be absent"
  fail=$((fail+1))
else
  echo "PASS: (g) no .optimus/ at all: section absent"
  pass=$((pass+1))
fi

mkdir -p "$PROJ_G/.optimus"
echo '{"enabled":true}' >"$PROJ_G/.optimus/config.json"
AFTER_CONFIG_ONLY_G="$(run_stats "$CFG_G" "$PROJ_G")" || true
if echo "$AFTER_CONFIG_ONLY_G" | grep -qF "$LEDGER_SECTION_MARKER"; then
  echo "FAIL: (g) config.json but no events file: section should still be absent"
  fail=$((fail+1))
else
  echo "PASS: (g) config.json but no events file: section still absent"
  pass=$((pass+1))
fi
if [ "$BEFORE_G" = "$AFTER_CONFIG_ONLY_G" ]; then
  echo "PASS: (g) adding .optimus/config.json alone leaves output byte-identical"
  pass=$((pass+1))
else
  echo "FAIL: (g) adding .optimus/config.json alone changed pre-existing output"
  fail=$((fail+1))
fi

mkdir -p "$PROJ_G/.optimus/state"
write_ledger_event "$PROJ_G/.optimus/state/events.jsonl" '{"v":1,"ts":"2026-01-01T00:00:00.000Z","ev":"work_tool_denied","session_id":"s1","tool":"Read"}'
AFTER_WITH_LEDGER_G="$(run_stats "$CFG_G" "$PROJ_G")" || true
if echo "$AFTER_WITH_LEDGER_G" | grep -qF "$LEDGER_SECTION_MARKER"; then
  echo "PASS: (g) with a real ledger: section now present"
  pass=$((pass+1))
else
  echo "FAIL: (g) with a real ledger: section should now be present"
  fail=$((fail+1))
fi
# The new section is inserted right after the dispatch tallies but BEFORE
# the pre-existing "Estimated saving" block (per this feature's own spec:
# printed after the dispatch tallies, which is not the very end of the
# script's output) -- so BEFORE_G is not a literal string-prefix of
# AFTER_WITH_LEDGER_G as a whole. Split both outputs on that fixed anchor
# instead: everything *before* it must be an unchanged prefix (dispatch
# tallies, now followed by the new section instead of directly by the
# anchor); everything *from* the anchor onward must be byte-identical,
# proving the pre-existing "Estimated saving" block itself was neither
# altered nor reordered, only pushed later in the stream by an insertion.
ANCHOR_G="Estimated saving vs. running delegated work on the expensive (opus) tier:"
BEFORE_PREFIX_G="${BEFORE_G%%"$ANCHOR_G"*}"
AFTER_PREFIX_G="${AFTER_WITH_LEDGER_G%%"$ANCHOR_G"*}"
BEFORE_SUFFIX_G="${BEFORE_G#"$BEFORE_PREFIX_G"}"
AFTER_SUFFIX_G="${AFTER_WITH_LEDGER_G#"$AFTER_PREFIX_G"}"

case "$AFTER_PREFIX_G" in
  "$BEFORE_PREFIX_G"*)
    echo "PASS: (g) with a real ledger: everything before the insertion point is an unchanged prefix"
    pass=$((pass+1))
    ;;
  *)
    echo "FAIL: (g) with a real ledger: output before the insertion point changed"
    fail=$((fail+1))
    ;;
esac
if [ "$AFTER_SUFFIX_G" = "$BEFORE_SUFFIX_G" ]; then
  echo "PASS: (g) with a real ledger: the pre-existing 'Estimated saving' block is untouched, just pushed later"
  pass=$((pass+1))
else
  echo "FAIL: (g) with a real ledger: the pre-existing 'Estimated saving' block changed"
  fail=$((fail+1))
fi

# -- (h) malformed lines mixed with valid ones are skipped without crashing.
CFG_H="$WORKDIR/cfg-ledger-malformed"
PROJ_H="$WORKDIR/ledger-malformed-project"
mkdir -p "$PROJ_H/.optimus/state"
echo '{"enabled":true}' >"$PROJ_H/.optimus/config.json"
mkdir -p "$CFG_H/projects"
SLUG_H="$(correct_slug "$PROJ_H")"
mkdir -p "$CFG_H/projects/$SLUG_H"
write_assistant_line "$CFG_H/projects/$SLUG_H/session-h.jsonl" "$PROJ_H" "claude-sonnet-5" 100 50 0 0

LEDGER_H="$PROJ_H/.optimus/state/events.jsonl"
write_garbage_line "$LEDGER_H"
write_ledger_event "$LEDGER_H" '{"v":1,"ts":"2026-01-01T00:00:00.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t1","model":"haiku"}'
write_garbage_line "$LEDGER_H"
write_ledger_event "$LEDGER_H" '{"v":1,"ts":"2026-01-01T00:00:01.000Z","ev":"work_tool_denied","session_id":"s1","tool":"Edit"}'

check_contains "(h) malformed lines skipped: no crash, exit 0" "$CFG_H" "$PROJ_H" "$LEDGER_SECTION_MARKER" ""
check_contains "(h) malformed lines skipped: dispatch_allowed=1 still counted" "$CFG_H" "$PROJ_H" "dispatches allowed         : 1" ""
check_contains "(h) malformed lines skipped: work_tool_denied Edit=1 still counted" "$CFG_H" "$PROJ_H" '"Edit":1' ""

# -- (i) a rotated events.jsonl.1 is included in the counts and triggers
#    the approximate-comparison caveat.
CFG_I="$WORKDIR/cfg-ledger-rotated"
PROJ_I="$WORKDIR/ledger-rotated-project"
mkdir -p "$PROJ_I/.optimus/state"
echo '{"enabled":true}' >"$PROJ_I/.optimus/config.json"
mkdir -p "$CFG_I/projects"
SLUG_I="$(correct_slug "$PROJ_I")"
mkdir -p "$CFG_I/projects/$SLUG_I"
write_assistant_line "$CFG_I/projects/$SLUG_I/session-i.jsonl" "$PROJ_I" "claude-sonnet-5" 100 50 0 0

write_ledger_event "$PROJ_I/.optimus/state/events.jsonl.1" '{"v":1,"ts":"2026-01-01T00:00:00.000Z","ev":"work_tool_denied","session_id":"s1","tool":"Read"}'
write_ledger_event "$PROJ_I/.optimus/state/events.jsonl"   '{"v":1,"ts":"2026-01-01T00:00:01.000Z","ev":"work_tool_denied","session_id":"s1","tool":"Write"}'

check_contains "(i) rotated: generation .1's event counted (Read=1)" "$CFG_I" "$PROJ_I" '"Read":1' ""
check_contains "(i) rotated: current generation's event counted (Write=1)" "$CFG_I" "$PROJ_I" '"Write":1' ""
check_contains "(i) rotated: approximate-comparison caveat present" "$CFG_I" "$PROJ_I" "rotated events.jsonl.1 generation was included" ""

# -- (j) drift case: ledger says 3x requested haiku, the only subagent
#    transcript reports an opus-family (actual) model -> the family-level
#    drift flag must appear.
CFG_J="$WORKDIR/cfg-ledger-drift"
PROJ_J="$WORKDIR/ledger-drift-project"
mkdir -p "$PROJ_J/.optimus/state"
echo '{"enabled":true}' >"$PROJ_J/.optimus/config.json"
mkdir -p "$CFG_J/projects"
SLUG_J="$(correct_slug "$PROJ_J")"
mkdir -p "$CFG_J/projects/$SLUG_J"
write_assistant_line "$CFG_J/projects/$SLUG_J/session-j.jsonl" "$PROJ_J" "claude-sonnet-5" 100 50 0 0
write_subagent_transcript "$CFG_J/projects/$SLUG_J/session-j/subagents" "1" "claude-opus-5-20260101"

LEDGER_J="$PROJ_J/.optimus/state/events.jsonl"
write_ledger_event "$LEDGER_J" '{"v":1,"ts":"2026-01-01T00:00:00.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t1","model":"haiku"}'
write_ledger_event "$LEDGER_J" '{"v":1,"ts":"2026-01-01T00:00:01.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t2","model":"haiku"}'
write_ledger_event "$LEDGER_J" '{"v":1,"ts":"2026-01-01T00:00:02.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t3","model":"haiku"}'

check_contains "(j) drift: haiku requested=3 actual=0"  "$CFG_J" "$PROJ_J" "requested=3 actual=0" ""
check_contains "(j) drift: opus requested=0 actual=1"   "$CFG_J" "$PROJ_J" "requested=0 actual=1" ""
check_contains "(j) drift: drift flag present"          "$CFG_J" "$PROJ_J" "counts differ for at least one family" ""

# -- (k) non-drift case: requested families match actual families exactly
#    -> no drift may be claimed.
CFG_K="$WORKDIR/cfg-ledger-nodrift"
PROJ_K="$WORKDIR/ledger-nodrift-project"
mkdir -p "$PROJ_K/.optimus/state"
echo '{"enabled":true}' >"$PROJ_K/.optimus/config.json"
mkdir -p "$CFG_K/projects"
SLUG_K="$(correct_slug "$PROJ_K")"
mkdir -p "$CFG_K/projects/$SLUG_K"
write_assistant_line "$CFG_K/projects/$SLUG_K/session-k.jsonl" "$PROJ_K" "claude-sonnet-5" 100 50 0 0
write_subagent_transcript "$CFG_K/projects/$SLUG_K/session-k/subagents" "1" "claude-haiku-4-5-20251001"

write_ledger_event "$PROJ_K/.optimus/state/events.jsonl" '{"v":1,"ts":"2026-01-01T00:00:00.000Z","ev":"dispatch_allowed","session_id":"s1","tool_use_id":"t1","model":"haiku"}'

check_contains "(k) non-drift: no-drift line present"     "$CFG_K" "$PROJ_K" "no drift indicated" ""
check_contains "(k) non-drift: no 'counts differ' claim"  "$CFG_K" "$PROJ_K" "" "counts differ"
check_contains "(k) non-drift: no approximate-caveat noise" "$CFG_K" "$PROJ_K" "" "CAVEAT"

echo ""
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
