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

# Appends a non-JSON garbage line (simulates a half-written/corrupt line).
write_garbage_line() {
  local file="$1"
  printf 'not valid json at all {{{\n' >>"$file"
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
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
