'use strict';

/**
 * OS-specific PATH setup for `optimus-cli`.
 *
 * Claude Code adds every loaded plugin's own `bin/` directory to `PATH` for
 * the duration of the session (see README, "The bin/ + PATH mechanism").
 * Cursor does no such thing: a user who installs Optimus into a Cursor
 * project and runs `optimus-cli install cursor` still has no `optimus-cli`
 * on `PATH` afterwards, and either has to type `./bin/optimus-cli` or dig up
 * a long cached plugin path. This module is the fix — it is invoked from
 * `bin/optimus-cli`'s `install cursor` and `install path` subcommands so the
 * one-time install step also makes the CLI reachable by bare name in new
 * shells.
 *
 * Design constraints, mirroring the rest of this plugin:
 *  - Never throw out to the caller. `installCliPath()` catches everything
 *    and reports failure via the returned `message` — a PATH setup problem
 *    must never abort `optimus-cli install cursor`.
 *  - Idempotent. Re-running with the same `binDir` after it already took
 *    effect reports `alreadyPresent: true` and changes nothing.
 *  - macOS/Linux: append a single marked block to a shell profile, guarded
 *    by a fixed comment marker (`# Optimus CLI`) so re-runs can detect it
 *    was already done (a substring check on `binDir` is enough, since we
 *    control the exact text written).
 *  - Windows: edit the User-scope PATH environment variable directly via
 *    PowerShell's `[Environment]::GetEnvironmentVariable`/`SetEnvironmentVariable`,
 *    NOT `setx` — `setx` truncates PATH at 1024 characters and silently
 *    corrupts it on machines with a long PATH already.
 *  - Every OS-specific and I/O dependency (`platform`, `homeDir`, `env`,
 *    `execFn`) is injectable so tests can exercise all branches from a
 *    single macOS dev machine without touching the real PATH or shelling
 *    out to PowerShell.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const MARKER = '# Optimus CLI';

function fileExists(p) {
  try {
    return fs.statSync(p).isFile();
  } catch (e) {
    return false;
  }
}

function dedupe(arr) {
  const seen = new Set();
  const out = [];
  for (const item of arr) {
    if (!seen.has(item)) {
      seen.add(item);
      out.push(item);
    }
  }
  return out;
}

/**
 * Normalize a PATH entry (or any filesystem path) for a case- and
 * trailing-separator-insensitive comparison. Windows PATH entries and
 * drive letters are case-insensitive; this is deliberately loose rather
 * than trying to be a full path-equivalence check.
 */
function normalizeForCompare(p) {
  return String(p || '')
    .trim()
    .replace(/[\\/]+$/, '')
    .toLowerCase();
}

/**
 * Pick the shell profile file to edit on macOS/Linux.
 *
 * Order: the file matching the user's actual login shell ($SHELL's
 * basename — `.zshrc` for zsh, `.bash_profile` otherwise), then `.profile`,
 * then `.zshrc` and `.bashrc` as a general fallback — the first of those
 * that EXISTS wins. If none of them exist yet, returns `~/.profile` — the
 * caller creates it.
 *
 * `homeDir`/`env` are injectable so tests can point this at a temp
 * directory instead of the real home directory / real $SHELL.
 */
function getShellProfilePath(homeDir, env) {
  const home = homeDir || os.homedir();
  const e = env || process.env;
  const shell = (e.SHELL || '').trim();
  const shellName = shell ? path.basename(shell) : '';
  const preferred = shellName === 'zsh' ? '.zshrc' : '.bash_profile';

  const names = dedupe([preferred, '.profile', '.zshrc', '.bashrc']);
  for (const name of names) {
    const candidate = path.join(home, name);
    if (fileExists(candidate)) return candidate;
  }
  return path.join(home, '.profile');
}

function buildProfileBlock(binDir) {
  return MARKER + '\nexport PATH="' + binDir + ':$PATH"\n';
}

/**
 * We control the exact text we append, so a substring match on `binDir`
 * is a sufficient (and cheap) idempotency check — it also catches the case
 * where a user already added the same directory to PATH by hand.
 */
function pathAlreadyInProfile(content, binDir) {
  return !!content && content.indexOf(binDir) !== -1;
}

function installUnixPath(binDir, dryRun, homeDir, env) {
  const profilePath = getShellProfilePath(homeDir, env);

  let existingContent = '';
  try {
    existingContent = fs.readFileSync(profilePath, 'utf8');
  } catch (e) {
    if (e.code !== 'ENOENT') {
      return {
        changed: false,
        alreadyPresent: false,
        profilePath: profilePath,
        message: 'Optimus: could not read ' + profilePath + ' — ' + (e && e.message ? e.message : e),
      };
    }
    // ENOENT: profile doesn't exist yet, we'll create it below.
  }

  if (pathAlreadyInProfile(existingContent, binDir)) {
    return {
      changed: false,
      alreadyPresent: true,
      profilePath: profilePath,
      message: 'Optimus: ' + binDir + ' is already referenced in ' + profilePath + '.',
    };
  }

  if (dryRun) {
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: profilePath,
      message: 'Optimus: would append a PATH entry for ' + binDir + ' to ' + profilePath + ' (dry run).',
    };
  }

  const block = buildProfileBlock(binDir);
  const separator = existingContent && !existingContent.endsWith('\n') ? '\n' : '';

  try {
    fs.mkdirSync(path.dirname(profilePath), { recursive: true });
    fs.appendFileSync(profilePath, separator + block);
  } catch (e) {
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: profilePath,
      message: 'Optimus: failed to update ' + profilePath + ' — ' + (e && e.message ? e.message : e),
    };
  }

  return {
    changed: true,
    alreadyPresent: false,
    profilePath: profilePath,
    message:
      'Optimus: added ' +
      binDir +
      ' to PATH via ' +
      profilePath +
      '. Restart your shell (or run `source ' +
      profilePath +
      '`) for it to take effect.',
  };
}

/** Default `execFn`: shells out to real PowerShell. Overridden in tests. */
function runPowerShell(args) {
  return execFileSync('powershell.exe', args, { encoding: 'utf8' });
}

function getWindowsUserPath(execFn) {
  const out = execFn([
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "[Environment]::GetEnvironmentVariable('Path','User')",
  ]);
  return (out || '').toString().trim();
}

function setWindowsUserPath(execFn, newPath) {
  // Single-quoted PowerShell string: the only character that needs
  // escaping is a literal single quote, doubled per PowerShell syntax.
  const escaped = newPath.replace(/'/g, "''");
  execFn([
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "[Environment]::SetEnvironmentVariable('Path', '" + escaped + "', 'User')",
  ]);
}

function installWindowsPath(binDir, dryRun, execFn) {
  // binDir has already been resolved with path.win32 semantics by the
  // caller; normalize once more here purely to strip a trailing separator.
  const normalizedBinDir = binDir.replace(/[\\/]+$/, '');

  let currentPath;
  try {
    currentPath = getWindowsUserPath(execFn);
  } catch (e) {
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: null,
      message: 'Optimus: could not read the Windows User PATH via PowerShell — ' + (e && e.message ? e.message : e),
    };
  }

  const entries = currentPath ? currentPath.split(';').filter(Boolean) : [];
  const already = entries.some(function (entry) {
    return normalizeForCompare(entry) === normalizeForCompare(normalizedBinDir);
  });

  if (already) {
    return {
      changed: false,
      alreadyPresent: true,
      profilePath: null,
      message: 'Optimus: ' + normalizedBinDir + ' is already on the Windows User PATH.',
    };
  }

  if (dryRun) {
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: null,
      message: 'Optimus: would add ' + normalizedBinDir + ' to the Windows User PATH (dry run).',
    };
  }

  const newPath = entries.concat([normalizedBinDir]).join(';');
  try {
    setWindowsUserPath(execFn, newPath);
  } catch (e) {
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: null,
      message: 'Optimus: failed to update the Windows User PATH via PowerShell — ' + (e && e.message ? e.message : e),
    };
  }

  return {
    changed: true,
    alreadyPresent: false,
    profilePath: null,
    message:
      'Optimus: added ' + normalizedBinDir + ' to the Windows User PATH. Open a new terminal for it to take effect.',
  };
}

/**
 * Make `binDir` reachable by bare command name in new shells/terminals.
 *
 * Returns `{ changed, alreadyPresent, profilePath, message }`:
 *  - `changed`: true only if a file/env var was actually modified this run.
 *  - `alreadyPresent`: true if `binDir` was already set up (nothing to do).
 *  - `profilePath`: the shell profile touched (macOS/Linux only; null on
 *    Windows, where there is no profile file — the User PATH env var is
 *    edited directly).
 *  - `message`: a single human-readable line describing what happened
 *    (or the reason nothing happened), suitable for printing as-is.
 *
 * Never throws: any unexpected failure is caught and reported through
 * `message` with `changed: false`, so callers can print the result and
 * move on rather than treating PATH setup as fatal to installation.
 *
 * `options`:
 *  - `binDir` (required): path to add to PATH (absolute path expected;
 *    resolved with the path flavor matching `platform`).
 *  - `dryRun`: report what would happen without writing anything.
 *  - `platform`, `homeDir`, `env`, `execFn`: injectable for tests; default
 *    to `os.platform()`, `os.homedir()`, `process.env`, and real
 *    `powershell.exe` respectively.
 */
function installCliPath(options) {
  const opts = options || {};
  if (!opts.binDir) {
    throw new Error('installCliPath: binDir is required');
  }

  try {
    const dryRun = !!opts.dryRun;
    const platform = opts.platform || os.platform();

    // Resolve with the path flavor matching the TARGET platform, not the
    // host running this code: `path.resolve` follows the host OS's own
    // separator rules, which mangles a Windows-style binDir (backslashes
    // are not separators on POSIX) when simulating win32 from a test on
    // macOS/Linux. `path.win32`/`path.posix` are always available and
    // platform-correct regardless of host, so tests can exercise every
    // branch from one machine.
    if (platform === 'win32') {
      const binDir = path.win32.resolve(opts.binDir);
      return installWindowsPath(binDir, dryRun, opts.execFn || runPowerShell);
    }
    if (platform === 'darwin' || platform === 'linux') {
      const binDir = path.posix.resolve(opts.binDir);
      return installUnixPath(binDir, dryRun, opts.homeDir, opts.env);
    }
    const binDir = path.resolve(opts.binDir);
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: null,
      message:
        'Optimus: PATH setup is not implemented for platform "' + platform + '" — add ' + binDir + ' to PATH manually.',
    };
  } catch (e) {
    return {
      changed: false,
      alreadyPresent: false,
      profilePath: null,
      message: 'Optimus: PATH setup failed — ' + (e && e.message ? e.message : e),
    };
  }
}

module.exports = {
  installCliPath,
  getShellProfilePath,
  MARKER,
};
