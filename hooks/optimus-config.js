'use strict';

/**
 * Shared config/state helpers for Optimus hooks and commands.
 *
 * Design constraints (see README "Hard-enforced vs advisory" and the
 * research this plugin was built from):
 *  - Activation state is REPO-LOCAL, not global. A `.optimus/config.json`
 *    file living in (or above) the project directory, resolved by walking
 *    up from cwd the same way `caveman`'s *default*-mode config works.
 *    We deliberately do NOT mirror caveman's *active*-mode mechanism,
 *    which is a single global flag file — that leaks state across
 *    concurrent projects, which is exactly the failure mode Optimus
 *    exists to avoid for its own policy.
 *  - Every read/write here must fail closed to "do nothing harmful":
 *    a missing/corrupt config means "not enabled" (never silently enabled),
 *    and a filesystem error while checking must never throw out of a hook
 *    (callers wrap these calls too, but these functions are defensive on
 *    their own).
 *  - Writes refuse to follow a pre-existing symlink at the target path
 *    (a cheap defense against a local symlink-plant attack aimed at
 *    tricking Optimus into writing through a symlink elsewhere), and are
 *    atomic (write to a temp file, then rename).
 */

const fs = require('fs');
const path = require('path');

const KILL_SWITCH_ENV = 'OPTIMUS_DISABLED';
const CONFIG_DIRNAME = '.optimus';
const CONFIG_FILENAME = 'config.json';
const MAX_WALK_LEVELS = 20;
const MAX_CONFIG_BYTES = 4096;
const DEFAULT_INLINE_ALLOWANCE_PER_TURN = 2;

/** The set of tools treated as "work" the orchestrator must delegate. */
const WORK_TOOLS = new Set([
  'Read',
  'Edit',
  'Write',
  'Grep',
  'Glob',
  'WebFetch',
  'WebSearch',
  'NotebookEdit',
]);

/** Matches a model string naming the expensive tier Optimus routes work off. */
const EXPENSIVE_MODEL_RE = /opus/i;

function isKillSwitchActive(env) {
  const e = env || process.env;
  const v = e[KILL_SWITCH_ENV];
  return v === '1' || v === 'true' || v === 'yes' || v === 'on';
}

function isValidInlineAllowance(value) {
  return typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

function validatedInlineAllowance(rawValue) {
  return isValidInlineAllowance(rawValue)
    ? rawValue
    : DEFAULT_INLINE_ALLOWANCE_PER_TURN;
}

/**
 * Read a small JSON file, refusing symlinks and oversized files.
 * Returns null on any error (missing, not JSON, too big, symlink, etc.)
 * rather than throwing — callers treat null as "no usable config here".
 */
function safeReadJsonFile(filePath) {
  try {
    const lst = fs.lstatSync(filePath);
    if (lst.isSymbolicLink()) return null;
    if (!lst.isFile()) return null;
    if (lst.size > MAX_CONFIG_BYTES) return null;
    const raw = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (e) {
    return null;
  }
}

/**
 * Walk up from `startDir` looking for an existing `.optimus/config.json`.
 * Returns the directory that contains it, or null if none was found
 * within MAX_WALK_LEVELS (or before hitting the filesystem root).
 */
function findProjectRoot(startDir) {
  let dir = path.resolve(startDir || process.cwd());
  for (let i = 0; i < MAX_WALK_LEVELS; i++) {
    const candidate = path.join(dir, CONFIG_DIRNAME, CONFIG_FILENAME);
    try {
      const lst = fs.lstatSync(candidate);
      if (lst.isFile()) return dir;
    } catch (e) {
      // not found at this level — keep walking up
    }
    const parent = path.dirname(dir);
    if (parent === dir) break; // reached filesystem root
    dir = parent;
  }
  return null;
}

/**
 * Resolve the effective Optimus config for a given cwd.
 * Returns
 * { enabled: boolean, root: string|null, raw: object|null, inlineAllowancePerTurn: number }.
 * Never throws; a missing or unreadable config resolves to disabled.
 */
function getConfig(cwd) {
  const root = findProjectRoot(cwd);
  if (!root) {
    return {
      enabled: false,
      root: null,
      raw: null,
      inlineAllowancePerTurn: DEFAULT_INLINE_ALLOWANCE_PER_TURN,
    };
  }

  const cfg = safeReadJsonFile(path.join(root, CONFIG_DIRNAME, CONFIG_FILENAME));
  if (!cfg || typeof cfg !== 'object') {
    return {
      enabled: false,
      root,
      raw: null,
      inlineAllowancePerTurn: DEFAULT_INLINE_ALLOWANCE_PER_TURN,
    };
  }

  return {
    enabled: cfg.enabled === true,
    root,
    raw: cfg,
    inlineAllowancePerTurn: validatedInlineAllowance(cfg.inlineAllowancePerTurn),
  };
}

/**
 * Write `contents` to `target` atomically, refusing to follow a pre-existing
 * symlink there.
 *
 * The symlink check is a cheap defence against a local symlink-plant aimed at
 * tricking Optimus into writing through a link somewhere else; the temp-file-
 * then-rename makes the replacement atomic so a reader never sees a partial
 * file. Throws on a symlink at the target, and on any fs error other than the
 * target simply not existing yet — callers decide how to present that.
 *
 * The temp filename mixes in pid, a timestamp, AND a random component
 * because `flag: 'wx'` below means two writers landing on the same temp
 * name throw EEXIST instead of silently clobbering each other. pid+time
 * alone can still collide (two callers in the same process within the
 * same millisecond, e.g. a caller retrying its own prior collision), so
 * the random suffix is what actually makes a repeat collision
 * astronomically unlikely rather than merely "unlikely".
 *
 * Exported because `bin/optimus-cli install cursor` writes into a user's
 * project and needs exactly these two properties. It must never be duplicated:
 * this is the most security-relevant primitive in the plugin, and two copies
 * drift.
 */
function writeFileAtomicRefusingSymlink(target, contents, mode) {
  try {
    const lst = fs.lstatSync(target);
    if (lst.isSymbolicLink()) {
      throw new Error('Optimus: refusing to write through a symlink at ' + target);
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }

  const tmp =
    target +
    '.tmp-' +
    process.pid +
    '-' +
    Date.now() +
    '-' +
    Math.random().toString(36).slice(2, 8);
  fs.writeFileSync(tmp, contents, { mode: typeof mode === 'number' ? mode : 0o600, flag: 'wx' });
  fs.renameSync(tmp, target);
}

/**
 * Activate/deactivate Optimus for the project rooted at `cwd` (written
 * directly at that directory, not walked up — "this project", explicitly).
 * Atomic write; refuses to write through a pre-existing symlink.
 */
function setConfig(cwd, enabled) {
  const root = path.resolve(cwd || process.cwd());
  const dir = path.join(root, CONFIG_DIRNAME);
  fs.mkdirSync(dir, { recursive: true });
  const target = path.join(dir, CONFIG_FILENAME);

  const existing = safeReadJsonFile(target);
  const inlineAllowancePerTurn =
    existing && typeof existing === 'object' && isValidInlineAllowance(existing.inlineAllowancePerTurn)
      ? existing.inlineAllowancePerTurn
      : DEFAULT_INLINE_ALLOWANCE_PER_TURN;

  const payload =
    JSON.stringify(
      {
        enabled: !!enabled,
        inlineAllowancePerTurn: inlineAllowancePerTurn,
        updatedAt: new Date().toISOString(),
      },
      null,
      2
    ) + '\n';

  writeFileAtomicRefusingSymlink(target, payload);

  return { root, enabled: !!enabled, configPath: target };
}

module.exports = {
  isKillSwitchActive,
  getConfig,
  setConfig,
  findProjectRoot,
  writeFileAtomicRefusingSymlink,
  WORK_TOOLS,
  EXPENSIVE_MODEL_RE,
  CONFIG_DIRNAME,
  CONFIG_FILENAME,
  KILL_SWITCH_ENV,
  DEFAULT_INLINE_ALLOWANCE_PER_TURN,
};
