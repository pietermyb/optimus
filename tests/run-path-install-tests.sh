#!/usr/bin/env bash
# Tests for hooks/install-path.js and optimus-cli install path/cursor integration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/optimus-cli"
MODULE="$ROOT/hooks/install-path.js"

pass=0
fail=0

ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

echo "== Optimus PATH install tests =="

# --- darwin/linux zsh: picks .zshrc, appends once, idempotent -----------
W1="$(mktemp -d)"
OUT1="$(SHELL=/bin/zsh node - <<'NODE' "$MODULE" "$W1"
const fs = require('fs');
const path = require('path');
const mod = require(process.argv[2]);
const home = process.argv[3];
const binDir = path.join(home, 'bin');
const first = mod.installCliPath({ binDir, homeDir: home, platform: 'darwin' });
const second = mod.installCliPath({ binDir, homeDir: home, platform: 'darwin' });
const profile = path.join(home, '.zshrc');
const content = fs.readFileSync(profile, 'utf8');
const exportLine = 'export PATH="' + path.resolve(binDir) + ':$PATH"';
const count = content.split(exportLine).length - 1;
console.log(JSON.stringify({ first, second, profile, count }));
NODE
)"
if node - <<'NODE' "$OUT1"
const data = JSON.parse(process.argv[2]);
const ok = data.first.changed === true &&
  data.first.alreadyPresent === false &&
  data.first.profilePath === data.profile &&
  data.second.changed === false &&
  data.second.alreadyPresent === true &&
  data.count === 1;
process.exit(ok ? 0 : 1);
NODE
then
  ok "zsh picks .zshrc and is idempotent"
else
  bad "zsh picks .zshrc and is idempotent"
fi
rm -rf "$W1"

# --- bash + no existing profiles: picks .bash_profile --------------------
W2="$(mktemp -d)"
OUT2="$(node - <<'NODE' "$MODULE" "$W2"
const mod = require(process.argv[2]);
const home = process.argv[3];
console.log(mod.getShellProfilePath(home, 'linux', '/bin/bash'));
NODE
)"
if [ "$OUT2" = "$W2/.bash_profile" ]; then
  ok "bash without profiles picks .bash_profile"
else
  bad "bash without profiles profile selection"
fi
rm -rf "$W2"

# --- bash + existing .profile and no .bash_profile: picks .profile -------
W3="$(mktemp -d)"
: > "$W3/.profile"
OUT3="$(node - <<'NODE' "$MODULE" "$W3"
const mod = require(process.argv[2]);
const home = process.argv[3];
console.log(mod.getShellProfilePath(home, 'linux', '/bin/bash'));
NODE
)"
if [ "$OUT3" = "$W3/.profile" ]; then
  ok "bash falls back to existing .profile"
else
  bad "bash .profile fallback"
fi
rm -rf "$W3"

# --- unknown shell + only .bashrc exists: picks .bashrc ------------------
W4="$(mktemp -d)"
: > "$W4/.bashrc"
OUT4="$(node - <<'NODE' "$MODULE" "$W4"
const mod = require(process.argv[2]);
const home = process.argv[3];
console.log(mod.getShellProfilePath(home, 'darwin', ''));
NODE
)"
if [ "$OUT4" = "$W4/.bashrc" ]; then
  ok "unknown shell picks existing .bashrc"
else
  bad "unknown shell .bashrc selection"
fi
rm -rf "$W4"

# --- unknown shell + none existing: defaults to .profile -----------------
W5="$(mktemp -d)"
OUT5="$(node - <<'NODE' "$MODULE" "$W5"
const mod = require(process.argv[2]);
const home = process.argv[3];
console.log(mod.getShellProfilePath(home, 'linux', ''));
NODE
)"
if [ "$OUT5" = "$W5/.profile" ]; then
  ok "unknown shell defaults to .profile"
else
  bad "unknown shell default profile"
fi
rm -rf "$W5"

# --- dryRun makes no filesystem changes ----------------------------------
W6="$(mktemp -d)"
OUT6="$(SHELL=/bin/zsh node - <<'NODE' "$MODULE" "$W6"
const fs = require('fs');
const path = require('path');
const mod = require(process.argv[2]);
const home = process.argv[3];
const result = mod.installCliPath({
  binDir: path.join(home, 'bin'),
  dryRun: true,
  homeDir: home,
  platform: 'darwin'
});
console.log(JSON.stringify({ result, profileExists: fs.existsSync(path.join(home, '.zshrc')) }));
NODE
)"
if node - <<'NODE' "$OUT6"
const data = JSON.parse(process.argv[2]);
const ok = data.result.changed === false && data.profileExists === false;
process.exit(ok ? 0 : 1);
NODE
then
  ok "dryRun performs no writes"
else
  bad "dryRun performs no writes"
fi
rm -rf "$W6"

# --- helper: create fake pwsh executable ---------------------------------
make_fake_pwsh() {
  local dir="$1"
  cat > "$dir/pwsh" <<'PWSH'
#!/usr/bin/env bash
LOGFILE="${OPTIMUS_TEST_PWSH_LOG:-/tmp/optimus-test-pwsh.log}"
GET_PATH_VALUE="${OPTIMUS_TEST_GET_PATH_VALUE:-}"
echo "$*" >> "$LOGFILE"
cmd="${*: -1}"
if [[ "$cmd" == *"GetEnvironmentVariable"* ]]; then
  printf '%s\n' "$GET_PATH_VALUE"
  exit 0
fi
if [[ "$cmd" == *"SetEnvironmentVariable"* ]]; then
  exit 0
fi
exit 0
PWSH
  chmod +x "$dir/pwsh"
}

# --- win32 not present: changed=true and SetEnvironmentVariable called ----
W7="$(mktemp -d)"
PWLOG="$W7/pwsh.log"
make_fake_pwsh "$W7"
OUT7="$(PATH="$W7:$PATH" OPTIMUS_TEST_PWSH_LOG="$PWLOG" OPTIMUS_TEST_GET_PATH_VALUE='C:\Windows\System32;C:\Tools' node - <<'NODE' "$MODULE"
const mod = require(process.argv[2]);
const r = mod.installCliPath({ binDir: 'C:\\Users\\me\\optimus\\bin', platform: 'win32' });
console.log(JSON.stringify(r));
NODE
)"
if echo "$OUT7" | grep -q '"changed":true'; then
  ok "win32 add reports changed=true"
else
  bad "win32 add changed flag"
fi
if grep -q 'SetEnvironmentVariable' "$PWLOG"; then
  ok "win32 add calls SetEnvironmentVariable"
else
  bad "win32 add did not call SetEnvironmentVariable"
fi
if grep -qi 'setx' "$PWLOG"; then
  bad "win32 add used setx"
else
  ok "win32 add never uses setx"
fi
rm -rf "$W7"

# --- win32 already present (case/trailing slash insensitive): no Set -----
W8="$(mktemp -d)"
PWLOG2="$W8/pwsh.log"
make_fake_pwsh "$W8"
TARGET8="$(node - <<'NODE'
const path = require('path');
const input = 'C:\\Users\\ME\\Optimus\\bin';
const target = path.win32.normalize(path.resolve(input)).replace(/[\\/]+$/, '');
process.stdout.write(target.toLowerCase() + '\\');
NODE
)"
OUT8="$(PATH="$W8:$PATH" OPTIMUS_TEST_PWSH_LOG="$PWLOG2" OPTIMUS_TEST_GET_PATH_VALUE="$TARGET8" node - <<'NODE' "$MODULE"
const mod = require(process.argv[2]);
const r = mod.installCliPath({ binDir: 'C:\\Users\\ME\\Optimus\\bin', platform: 'win32' });
console.log(JSON.stringify(r));
NODE
)"
if echo "$OUT8" | grep -q '"alreadyPresent":true'; then
  ok "win32 already-present detected case-insensitively"
else
  bad "win32 already-present detection"
fi
if grep -q 'SetEnvironmentVariable' "$PWLOG2"; then
  bad "win32 already-present still called SetEnvironmentVariable"
else
  ok "win32 already-present does not call SetEnvironmentVariable"
fi
rm -rf "$W8"

# --- win32 dryRun: no Set -------------------------------------------------
W9="$(mktemp -d)"
PWLOG3="$W9/pwsh.log"
make_fake_pwsh "$W9"
OUT9="$(PATH="$W9:$PATH" OPTIMUS_TEST_PWSH_LOG="$PWLOG3" OPTIMUS_TEST_GET_PATH_VALUE='C:\Windows' node - <<'NODE' "$MODULE"
const mod = require(process.argv[2]);
const r = mod.installCliPath({ binDir: 'C:\\Users\\me\\optimus\\bin', platform: 'win32', dryRun: true });
console.log(JSON.stringify(r));
NODE
)"
if echo "$OUT9" | grep -q '"changed":false'; then
  ok "win32 dryRun reports changed=false"
else
  bad "win32 dryRun changed flag"
fi
if grep -q 'SetEnvironmentVariable' "$PWLOG3"; then
  bad "win32 dryRun called SetEnvironmentVariable"
else
  ok "win32 dryRun does not call SetEnvironmentVariable"
fi
rm -rf "$W9"

# --- win32 exec failure: graceful error result, no throw -----------------
W10="$(mktemp -d)"
OUT10="$(PATH="$W10:$PATH" node - <<'NODE' "$MODULE"
const mod = require(process.argv[2]);
const r = mod.installCliPath({ binDir: 'C:\\Users\\me\\optimus\\bin', platform: 'win32' });
console.log(JSON.stringify(r));
NODE
)"
if echo "$OUT10" | grep -q '"changed":false' && echo "$OUT10" | grep -q '"error":'; then
  ok "win32 exec failure returns graceful error"
else
  bad "win32 exec failure handling"
fi
rm -rf "$W10"

# --- missing binDir: graceful error return (not throw) -------------------
OUT11="$(node - <<'NODE' "$MODULE"
const mod = require(process.argv[2]);
const r = mod.installCliPath({});
console.log(JSON.stringify(r));
NODE
)"
if echo "$OUT11" | grep -q '"error"' && echo "$OUT11" | grep -q '"changed":false'; then
  ok "missing binDir returns error object"
else
  bad "missing binDir handling"
fi

# --- install cursor integrates path setup (non-fatal) --------------------
W12="$(mktemp -d)"; P12="$W12/project"; mkdir -p "$P12"
if CURSOR_PROJECT_DIR="$P12" HOME="$W12" SHELL="/bin/zsh" node "$CLI" install cursor >"$W12/out.txt" 2>&1; then
  ok "install cursor exits successfully"
else
  bad "install cursor exited non-zero"
fi
if grep -qi 'PATH' "$W12/out.txt"; then
  ok "install cursor output mentions PATH"
else
  bad "install cursor output missing PATH mention"
fi
if [ -f "$W12/.zshrc" ] && grep -q '# Optimus CLI' "$W12/.zshrc"; then
  ok "install cursor writes PATH block"
else
  bad "install cursor PATH block missing"
fi
rm -rf "$W12"

# --- install path command only updates PATH ------------------------------
W13="$(mktemp -d)"
if HOME="$W13" SHELL="/bin/zsh" node "$CLI" install path >"$W13/out.txt" 2>&1; then
  ok "install path exits successfully"
else
  bad "install path exited non-zero"
fi
if [ -f "$W13/.zshrc" ] && grep -q '# Optimus CLI' "$W13/.zshrc"; then
  ok "install path writes PATH block"
else
  bad "install path did not write PATH block"
fi
if [ -f "$W13/.cursor/hooks.json" ]; then
  bad "install path should not create Cursor hooks"
else
  ok "install path does not touch Cursor hooks"
fi
rm -rf "$W13"

# --- install path idempotent second run ----------------------------------
W14="$(mktemp -d)"
HOME="$W14" SHELL="/bin/zsh" node "$CLI" install path >/dev/null 2>&1
if HOME="$W14" SHELL="/bin/zsh" node "$CLI" install path >"$W14/out2.txt" 2>&1; then
  ok "install path second run exits 0"
else
  bad "install path second run exited non-zero"
fi
if grep -qi 'already' "$W14/out2.txt"; then
  ok "install path second run reports already present"
else
  bad "install path second run message"
fi
rm -rf "$W14"

# --- usage text mentions install path ------------------------------------
W15="$(mktemp -d)"
HOME="$W15" node "$CLI" install >"$W15/out.txt" 2>&1 || true
if grep -q 'install path' "$W15/out.txt"; then
  ok "usage mentions install path"
else
  bad "usage missing install path"
fi
rm -rf "$W15"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
