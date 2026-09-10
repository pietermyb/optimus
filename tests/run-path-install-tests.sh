#!/usr/bin/env bash
# Tests for hooks/install-path.js and `optimus-cli install path`.
#
# Every scenario here injects homeDir/env/platform/execFn (directly into the
# module, or via a pinned HOME for the CLI integration checks) rather than
# touching this machine's real home directory or shelling out to
# powershell.exe — that keeps the whole suite portable on macOS (the dev
# machine) while still exercising the Windows branch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/optimus-cli"
MODULE="$ROOT/hooks/install-path.js"

pass=0
fail=0

ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

echo "== Optimus PATH install tests =="

# =========================================================================
# Module-level tests: hooks/install-path.js, pure logic with injected deps.
# =========================================================================

# --- darwin: fresh home, nothing exists -> falls back to ~/.profile,
# regardless of $SHELL (the spec's explicit last-resort rule) -------------
W="$(mktemp -d)"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: {},
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q '"changed":true' && ok "darwin fresh home: changed=true" || bad "darwin fresh home: $OUT"
echo "$OUT" | grep -q "$W/.profile" && ok "darwin fresh home: falls back to ~/.profile" || bad "darwin fresh home wrong profile: $OUT"
[ -f "$W/.profile" ] && ok "darwin fresh home: ~/.profile created" || bad "no ~/.profile created"
grep -q '# Optimus CLI' "$W/.profile" && ok "darwin fresh home: marker written" || bad "no marker in profile"
grep -q 'export PATH="/opt/optimus/bin:\$PATH"' "$W/.profile" && ok "darwin fresh home: PATH line written" || bad "wrong PATH line: $(cat "$W/.profile")"
rm -rf "$W"

# --- darwin: fresh home + $SHELL=zsh -> still falls back to ~/.profile,
# not .zshrc, when nothing exists on disk yet ------------------------------
W="$(mktemp -d)"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: { SHELL: "/bin/zsh" },
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q "$W/.profile" && ok "darwin zsh + fresh home: still falls back to ~/.profile" || bad "darwin zsh fresh home: $OUT"
rm -rf "$W"

# --- darwin: $SHELL=zsh with an existing .zshrc -> .zshrc is picked ------
W="$(mktemp -d)"
: > "$W/.zshrc"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: { SHELL: "/bin/zsh" },
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q "$W/.zshrc" && ok "darwin zsh: picks existing .zshrc" || bad "darwin zsh: wrong profile: $OUT"
grep -q '# Optimus CLI' "$W/.zshrc" && ok "darwin zsh: marker written to .zshrc" || bad "darwin zsh: no marker"
rm -rf "$W"

# --- darwin: $SHELL=bash with an existing .bash_profile -> it is picked --
W="$(mktemp -d)"
: > "$W/.bash_profile"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: { SHELL: "/bin/bash" },
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q "$W/.bash_profile" && ok "darwin bash: picks existing .bash_profile" || bad "darwin bash: wrong profile: $OUT"
rm -rf "$W"

# --- darwin: unknown shell + only .bashrc exists -> general fallback -----
W="$(mktemp -d)"
: > "$W/.bashrc"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: { SHELL: "/usr/bin/fish" },
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q "$W/.bashrc" && ok "darwin fallback: picks first existing profile" || bad "darwin fallback: $OUT"
rm -rf "$W"

# --- darwin: already present in profile -> no-op, alreadyPresent -------
W="$(mktemp -d)"
mkdir -p "$W"
printf '# Optimus CLI\nexport PATH="/opt/optimus/bin:$PATH"\n' > "$W/.zshrc"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: { SHELL: "/bin/zsh" },
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q '"changed":false' && echo "$OUT" | grep -q '"alreadyPresent":true' && ok "darwin: idempotent when already present" || bad "darwin idempotency: $OUT"
LINES_BEFORE=$(wc -l < "$W/.zshrc")
node -e '
  const { installCliPath } = require(process.argv[1]);
  installCliPath({ binDir: "/opt/optimus/bin", platform: "darwin", homeDir: process.argv[2], env: { SHELL: "/bin/zsh" } });
' "$MODULE" "$W"
LINES_AFTER=$(wc -l < "$W/.zshrc")
[ "$LINES_BEFORE" -eq "$LINES_AFTER" ] && ok "darwin: re-run does not duplicate the block" || bad "darwin: profile grew on re-run ($LINES_BEFORE -> $LINES_AFTER)"
rm -rf "$W"

# --- darwin: dryRun does not write anything ------------------------------
W="$(mktemp -d)"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "darwin",
    homeDir: process.argv[2],
    env: { SHELL: "/bin/zsh" },
    dryRun: true,
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q '"changed":false' && ok "darwin dryRun: changed=false" || bad "darwin dryRun: $OUT"
[ -f "$W/.profile" ] && bad "darwin dryRun: created a file" || ok "darwin dryRun: wrote nothing"
rm -rf "$W"

# --- linux: same profile-selection logic as darwin, existing .bash_profile
W="$(mktemp -d)"
: > "$W/.bash_profile"
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({
    binDir: "/opt/optimus/bin",
    platform: "linux",
    homeDir: process.argv[2],
    env: { SHELL: "/bin/bash" },
  });
  console.log(JSON.stringify(r));
' "$MODULE" "$W")"
echo "$OUT" | grep -q "$W/.bash_profile" && ok "linux bash: picks existing .bash_profile" || bad "linux bash: $OUT"
[ -f "$W/.bash_profile" ] && grep -q '# Optimus CLI' "$W/.bash_profile" && ok "linux: marker written" || bad "linux: no marker"
rm -rf "$W"

# --- linux: appended block does not clobber existing profile content ----
W="$(mktemp -d)"
printf 'export EDITOR=vim\n' > "$W/.bash_profile"
node -e '
  const { installCliPath } = require(process.argv[1]);
  installCliPath({ binDir: "/opt/optimus/bin", platform: "linux", homeDir: process.argv[2], env: { SHELL: "/bin/bash" } });
' "$MODULE" "$W"
grep -q 'EDITOR=vim' "$W/.bash_profile" && ok "linux: preserves existing profile content" || bad "linux: clobbered existing content"
grep -q '# Optimus CLI' "$W/.bash_profile" && ok "linux: appends the marked block" || bad "linux: block missing"
rm -rf "$W"

# --- getShellProfilePath: exported and directly testable ----------------
W="$(mktemp -d)"
: > "$W/.profile"
OUT="$(node -e '
  const { getShellProfilePath } = require(process.argv[1]);
  console.log(getShellProfilePath(process.argv[2], { SHELL: "/usr/bin/tcsh" }));
' "$MODULE" "$W")"
[ "$OUT" = "$W/.profile" ] && ok "getShellProfilePath: falls back to existing .profile" || bad "getShellProfilePath: $OUT"
rm -rf "$W"

# --- win32: not already on PATH -> SetEnvironmentVariable called --------
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const calls = [];
  const execFn = (args) => {
    calls.push(args.join(" "));
    const cmd = args[args.length - 1];
    if (cmd.indexOf("GetEnvironmentVariable") !== -1) return "C:\\Windows\\System32;C:\\Tools";
    return "";
  };
  const r = installCliPath({ binDir: "C:\\Users\\me\\optimus\\bin", platform: "win32", execFn });
  console.log(JSON.stringify({ r, calls }));
' "$MODULE")"
echo "$OUT" | grep -q '"changed":true' && ok "win32: reports changed=true" || bad "win32 change: $OUT"
echo "$OUT" | grep -q 'SetEnvironmentVariable' && ok "win32: calls SetEnvironmentVariable" || bad "win32: did not call Set: $OUT"
echo "$OUT" | grep -q 'setx' && bad "win32: used setx" || ok "win32: never uses setx"
echo "$OUT" | grep -q 'optimus' && ok "win32: new path mentions the bin dir" || bad "win32: bin dir missing from call: $OUT"
echo "$OUT" | grep -q 'C:\\\\Tools' && ok "win32: preserves existing PATH entries" || bad "win32: dropped existing entries: $OUT"

# --- win32: already present (case-insensitive) -> no-op -----------------
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  let setCalled = false;
  const execFn = (args) => {
    const cmd = args[args.length - 1];
    if (cmd.indexOf("GetEnvironmentVariable") !== -1) return "C:\\Windows;c:\\users\\me\\optimus\\bin\\";
    setCalled = true;
    return "";
  };
  const r = installCliPath({ binDir: "C:\\Users\\me\\optimus\\bin", platform: "win32", execFn });
  console.log(JSON.stringify({ r, setCalled }));
' "$MODULE")"
echo "$OUT" | grep -q '"alreadyPresent":true' && ok "win32: case/trailing-slash-insensitive match" || bad "win32 already-present: $OUT"
echo "$OUT" | grep -q '"setCalled":false' && ok "win32: does not call Set when already present" || bad "win32: called Set unnecessarily: $OUT"

# --- win32: dryRun never calls Set ----------------------------------------
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  let setCalled = false;
  const execFn = (args) => {
    const cmd = args[args.length - 1];
    if (cmd.indexOf("GetEnvironmentVariable") !== -1) return "C:\\Windows";
    setCalled = true;
    return "";
  };
  const r = installCliPath({ binDir: "C:\\Users\\me\\optimus\\bin", platform: "win32", execFn, dryRun: true });
  console.log(JSON.stringify({ r, setCalled }));
' "$MODULE")"
echo "$OUT" | grep -q '"changed":false' && echo "$OUT" | grep -q '"setCalled":false' && ok "win32 dryRun: no mutation" || bad "win32 dryRun: $OUT"

# --- win32: PowerShell failure is reported, not thrown -------------------
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const execFn = () => { throw new Error("powershell.exe not found"); };
  const r = installCliPath({ binDir: "C:\\bin", platform: "win32", execFn });
  console.log(JSON.stringify(r));
' "$MODULE")"
echo "$OUT" | grep -q '"changed":false' && ok "win32 exec failure: changed=false, not thrown" || bad "win32 exec failure: $OUT"
echo "$OUT" | grep -qi 'powershell' && ok "win32 exec failure: message names the cause" || bad "win32 exec failure message: $OUT"

# --- unsupported platform -> reported, not thrown -------------------------
OUT="$(node -e '
  const { installCliPath } = require(process.argv[1]);
  const r = installCliPath({ binDir: "/opt/x", platform: "sunos" });
  console.log(JSON.stringify(r));
' "$MODULE")"
echo "$OUT" | grep -q '"changed":false' && ok "unsupported platform: changed=false" || bad "unsupported platform: $OUT"

# --- missing binDir throws, as documented ---------------------------------
if node -e '
  const { installCliPath } = require(process.argv[1]);
  installCliPath({});
' "$MODULE" >/dev/null 2>&1; then
  bad "missing binDir did not throw"
else
  ok "missing binDir throws"
fi

# =========================================================================
# Integration: `optimus-cli install cursor` / `install path`, real CLI.
# HOME is pinned to a temp dir throughout so nothing touches this
# machine's actual shell profile. Each temp home starts with an empty
# .zshrc, matching a realistic zsh dev machine, so the profile picked is
# deterministic (.zshrc) rather than the no-dotfiles-at-all fallback.
# =========================================================================

# --- install cursor mentions PATH when the profile gets updated ---------
W="$(mktemp -d)"; P="$W/project"; mkdir -p "$P"; : > "$W/.zshrc"
CURSOR_PROJECT_DIR="$P" HOME="$W" SHELL="/bin/zsh" node "$CLI" install cursor >"$W/out.txt" 2>&1 || bad "install cursor exited non-zero"
grep -qi 'PATH' "$W/out.txt" && ok "install cursor: output mentions PATH" || bad "install cursor: no PATH mention: $(cat "$W/out.txt")"
grep -q '# Optimus CLI' "$W/.zshrc" && ok "install cursor: wrote the marked PATH block" || bad "install cursor: no PATH block written"
grep -q "$ROOT/bin" "$W/.zshrc" && ok "install cursor: PATH block references bin/" || bad "install cursor: wrong bin dir in profile"
rm -rf "$W"

# --- install cursor run twice is idempotent for PATH too -----------------
W="$(mktemp -d)"; P="$W/project"; mkdir -p "$P"; : > "$W/.zshrc"
CURSOR_PROJECT_DIR="$P" HOME="$W" SHELL="/bin/zsh" node "$CLI" install cursor >/dev/null 2>&1
LINES_BEFORE=$(wc -l < "$W/.zshrc")
CURSOR_PROJECT_DIR="$P" HOME="$W" SHELL="/bin/zsh" node "$CLI" install cursor >"$W/out2.txt" 2>&1
LINES_AFTER=$(wc -l < "$W/.zshrc")
[ "$LINES_BEFORE" -eq "$LINES_AFTER" ] && ok "install cursor twice: profile does not grow" || bad "install cursor twice: grew ($LINES_BEFORE -> $LINES_AFTER)"
grep -qi 'already' "$W/out2.txt" && ok "install cursor twice: reports already-present" || bad "install cursor twice: $(cat "$W/out2.txt")"
rm -rf "$W"

# --- `optimus-cli install path` does PATH setup only --------------------
W="$(mktemp -d)"; : > "$W/.zshrc"
HOME="$W" SHELL="/bin/zsh" node "$CLI" install path >"$W/out.txt" 2>&1
grep -qi 'PATH' "$W/out.txt" && ok "install path: mentions PATH" || bad "install path: $(cat "$W/out.txt")"
grep -q '# Optimus CLI' "$W/.zshrc" && ok "install path: writes the profile block" || bad "install path: no profile written"
[ -f "$W/.cursor/hooks.json" ] && bad "install path: also touched Cursor hooks" || ok "install path: does not touch Cursor hooks"
rm -rf "$W"

# --- `optimus-cli install path` is idempotent on exit code ---------------
W="$(mktemp -d)"; : > "$W/.zshrc"
HOME="$W" SHELL="/bin/zsh" node "$CLI" install path >/dev/null 2>&1
if HOME="$W" SHELL="/bin/zsh" node "$CLI" install path >"$W/out2.txt" 2>&1; then
  ok "install path: second run exits 0"
else
  bad "install path: second run exited non-zero: $(cat "$W/out2.txt")"
fi
grep -qi 'already' "$W/out2.txt" && ok "install path: second run reports already-present" || bad "install path: $(cat "$W/out2.txt")"
rm -rf "$W"

# --- usage strings mention the new subcommand -----------------------------
W="$(mktemp -d)"
HOME="$W" node "$CLI" install >"$W/out.txt" 2>&1 || true
grep -q 'install path' "$W/out.txt" && ok "usage: install path is documented" || bad "usage missing install path: $(cat "$W/out.txt")"
rm -rf "$W"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
