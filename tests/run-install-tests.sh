#!/usr/bin/env bash
# Tests for `optimus-cli install cursor`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/optimus-cli"

pass=0
fail=0

ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
check(){ if [ "$2" == "yes" ]; then ok "$1"; else bad "$1"; fi; }

echo "== Optimus install tests =="

# --- clean install ------------------------------------------------------
W="$(mktemp -d)"; P="$W/project"; mkdir -p "$P"
CURSOR_PROJECT_DIR="$P" node "$CLI" install cursor >"$W/out.txt" 2>&1 || bad "clean install exited non-zero"
[ -f "$P/.cursor/hooks.json" ] && ok "writes .cursor/hooks.json" || bad "no .cursor/hooks.json"
[ -f "$P/.cursor/rules/optimus.mdc" ] && ok "writes .cursor/rules/optimus.mdc" || bad "no rules/optimus.mdc"
grep -q '__OPTIMUS_ROOT__' "$P/.cursor/hooks.json" && bad "placeholder left unrendered" || ok "placeholder rendered"
grep -q "$ROOT/hooks/optimus-gate-cursor.js" "$P/.cursor/hooks.json" && ok "absolute gate path rendered" || bad "gate path missing"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$P/.cursor/hooks.json" && ok "hooks.json is valid JSON" || bad "hooks.json invalid"
grep -q 'alwaysApply: true' "$P/.cursor/rules/optimus.mdc" && ok "rule keeps alwaysApply" || bad "rule lost alwaysApply"
grep -q "$P" "$W/out.txt" && ok "prints where it wrote" || bad "did not print target"
# install must NOT activate
grep -q '"enabled": true' "$P/.optimus/config.json" 2>/dev/null && bad "install activated Optimus" || ok "install does not activate"

# --- refuses to clobber a foreign hooks.json ---------------------------
W2="$(mktemp -d)"; P2="$W2/project"; mkdir -p "$P2/.cursor"
echo '{"version":1,"hooks":{"preToolUse":[{"command":"node other.js"}]}}' > "$P2/.cursor/hooks.json"
if CURSOR_PROJECT_DIR="$P2" node "$CLI" install cursor >"$W2/out.txt" 2>&1; then
  bad "did not refuse an existing hooks.json"
else
  ok "refuses an existing hooks.json"
fi
grep -q 'other.js' "$P2/.cursor/hooks.json" && ok "left the existing file untouched" || bad "clobbered the existing file"
[ -f "$P2/.cursor/hooks.json.optimus-suggested" ] && ok "wrote the .optimus-suggested sidecar" || bad "no suggested file"

# --- --force overwrites -------------------------------------------------
CURSOR_PROJECT_DIR="$P2" node "$CLI" install cursor --force >/dev/null 2>&1 || bad "--force exited non-zero"
grep -q 'optimus-gate-cursor.js' "$P2/.cursor/hooks.json" && ok "--force overwrites" || bad "--force did not overwrite"

# --- re-install over our own file is idempotent, no --force needed -----
W3="$(mktemp -d)"; P3="$W3/project"; mkdir -p "$P3"
CURSOR_PROJECT_DIR="$P3" node "$CLI" install cursor >/dev/null 2>&1
if CURSOR_PROJECT_DIR="$P3" node "$CLI" install cursor >/dev/null 2>&1; then
  ok "re-installing over our own hooks.json succeeds"
else
  bad "re-install needed --force"
fi

# --- symlink defence ----------------------------------------------------
W4="$(mktemp -d)"; P4="$W4/project"; mkdir -p "$P4/.cursor"
: > "$W4/elsewhere.json"
ln -s "$W4/elsewhere.json" "$P4/.cursor/hooks.json"
CURSOR_PROJECT_DIR="$P4" node "$CLI" install cursor --force >/dev/null 2>&1 || true
[ -s "$W4/elsewhere.json" ] && bad "wrote through a symlink" || ok "refuses to write through a symlink"

# --- CURSOR_PROJECT_DIR wins over CLAUDE_PROJECT_DIR -------------------
W5="$(mktemp -d)"; mkdir -p "$W5/cursor-target" "$W5/claude-target"
CURSOR_PROJECT_DIR="$W5/cursor-target" CLAUDE_PROJECT_DIR="$W5/claude-target" node "$CLI" install cursor >/dev/null 2>&1
[ -f "$W5/cursor-target/.cursor/hooks.json" ] && ok "CURSOR_PROJECT_DIR takes precedence" || bad "wrong target dir"
[ -f "$W5/claude-target/.cursor/hooks.json" ] && bad "also wrote to CLAUDE_PROJECT_DIR" || ok "did not write to CLAUDE_PROJECT_DIR"

# --- unknown install target --------------------------------------------
W6="$(mktemp -d)"; P6="$W6/project"; mkdir -p "$P6"
if CURSOR_PROJECT_DIR="$P6" node "$CLI" install emacs >/dev/null 2>&1; then
  bad "accepted an unknown install target"
else
  ok "rejects an unknown install target"
fi

rm -rf "$W" "$W2" "$W3" "$W4" "$W5" "$W6"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
