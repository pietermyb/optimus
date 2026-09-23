'use strict';

/**
 * Per-project enforcement ledger — appends one JSON line per enforcement
 * event to `<projectRoot>/.optimus/state/events.jsonl`.
 *
 *   recordEvent(cwd, event)
 *     cwd:   directory to resolve the project root from, using the same
 *            walk-up logic `optimus-config.js` already implements
 *            (`findProjectRoot`) — never reimplemented here.
 *     event: plain object. `event.ev` (string) and `event.session_id`
 *            (string) are expected; every other own-enumerable key is
 *            treated as an event-specific field and copied through as-is.
 *            This function stamps `v: 1` and `ts` (ISO 8601) itself —
 *            callers must not set those.
 *   Returns undefined. Nothing is returned to distinguish "wrote a line"
 *   from "did nothing" — see the ABSOLUTE REQUIREMENT below for why.
 *
 * Design constraints (deliberate, see docs/cursor-support-spec.md stage 1
 * plan this was built from):
 *
 *  - Never write outside an activated project. Reuses `getConfig` and
 *    `isKillSwitchActive` from optimus-config.js — if Optimus isn't
 *    enabled for this project, or the kill switch is active, this is a
 *    silent no-op.
 *
 *  - Append-only, no read-modify-write. `fs.appendFileSync` opens with
 *    the `a` flag (O_APPEND), which makes each write's "seek to end of
 *    file, then write" step atomic at the OS level for local
 *    filesystems. That's the whole reason this is safe under the
 *    concurrency this plugin actually has: many gate processes (one per
 *    tool call, across the orchestrator and every subagent it dispatches)
 *    can run at the same moment against the same project, and each one's
 *    single line lands intact rather than clobbering another's. Reading
 *    the file first (to rotate, dedupe, whatever) before writing would
 *    reopen exactly that race, so rotation below deliberately stats
 *    rather than reads.
 *
 *  - ABSOLUTE REQUIREMENT: this function must never throw and must never
 *    write to stdout. The gate calls this on the hot path of every tool
 *    call, in between deciding and emitting its allow/deny verdict as
 *    JSON on stdout — a thrown error or a stray stdout write here would
 *    either wedge the session or corrupt that JSON protocol. Every
 *    fs/JSON operation is wrapped in try/catch; failures are swallowed
 *    (a stderr write is fine — stderr isn't part of the hook protocol).
 *
 *  - Privacy: this module has no idea what a "prompt" or "command" is —
 *    it just writes whatever fields the caller hands it. The privacy
 *    constraint (never log prompts, file paths, file contents, or full
 *    shell commands) is enforced by callers only ever passing reduced
 *    fields (e.g. optimus-gate.js's cmd_head, not the raw command). As a
 *    defensive backstop against a mistake on the caller's side, every
 *    string field is still capped at MAX_FIELD_LEN here before writing.
 */

const fs = require('fs');
const path = require('path');
const { findProjectRoot, getConfig, isKillSwitchActive, getAgentMap } = require(
  path.join(__dirname, 'optimus-config.js')
);

const STATE_DIRNAME = 'state';
const LEDGER_FILENAME = 'events.jsonl';
/** Agent lifecycle stream (Agent map) — separate file, same writer mechanics. */
const AGENT_LEDGER_FILENAME = 'agents.jsonl';
const ROTATED_SUFFIX = '.1';
/** Rotate once the ledger reaches this many bytes (before the next append). */
const ROTATE_MAX_BYTES = 1024 * 1024; // 1 MB
/** Defensive cap on any individual string field this module writes. */
const MAX_FIELD_LEN = 200;

function capString(value) {
  if (typeof value !== 'string') return value;
  return value.length > MAX_FIELD_LEN ? value.slice(0, MAX_FIELD_LEN) : value;
}

/**
 * Rename an over-cap ledger to its single rotated generation, replacing
 * any previous one. Best-effort: if anything here throws (file vanished
 * between stat and rename, permission error, whatever), the caller falls
 * through and just appends to the file as it currently stands.
 */
function rotateIfOverCap(file) {
  const st = fs.statSync(file); // throws ENOENT if no ledger yet — fine, caller catches it
  if (st.size >= ROTATE_MAX_BYTES) {
    fs.renameSync(file, file + ROTATED_SUFFIX); // atomically replaces an existing .1
  }
}

/**
 * Build one record line and append it to `filename` under the project's
 * state dir. Callers own the guard chain (kill switch, project root,
 * enabled, and — for the agent stream — the agentMap key); this owns
 * only the record shape, rotation, and the atomic append. Never called
 * without the guards already passed.
 */
function appendRecord(root, filename, event) {
  const record = {
    v: 1,
    ts: new Date().toISOString(),
    ev: capString(event && event.ev),
    session_id: capString(event && event.session_id),
  };
  if (event && typeof event === 'object') {
    for (const key of Object.keys(event)) {
      if (key === 'ev' || key === 'session_id') continue;
      record[key] = capString(event[key]);
    }
  }

  const line = JSON.stringify(record) + '\n';
  const dir = path.join(root, '.optimus', STATE_DIRNAME);
  const file = path.join(dir, filename);

  fs.mkdirSync(dir, { recursive: true });

  try {
    rotateIfOverCap(file);
  } catch (e) {
    // no ledger yet, or rotation failed for any reason — fall through
    // and append to (or create) the file as-is.
  }

  fs.appendFileSync(file, line, { mode: 0o600 });
}

/** Shared failure posture for both writers: never throw, never touch stdout. */
function swallowFailure(e) {
  try {
    process.stderr.write(
      'optimus-ledger: failed to record event: ' + (e && e.message) + '\n'
    );
  } catch (e2) {
    // even stderr can fail (EPIPE, etc.) — nothing more to do.
  }
}

/**
 * Append one enforcement event to the current project's ledger. See the
 * header comment for the full contract. Never throws, never writes to
 * stdout.
 */
function recordEvent(cwd, event) {
  try {
    if (isKillSwitchActive()) return;

    const root = findProjectRoot(cwd);
    if (!root) return;

    const cfg = getConfig(cwd);
    if (!cfg.enabled) return;

    appendRecord(root, LEDGER_FILENAME, event);
  } catch (e) {
    swallowFailure(e);
  }
}

/**
 * Append one agent lifecycle event to the Agent-map stream
 * (`agents.jsonl`). Same guards, shape, rotation, and silence as
 * `recordEvent`, plus the `agentMap` config key (absent/non-boolean =
 * on; only an explicit boolean false opts out). Observational only —
 * never throws, never writes to stdout, never reads the file back.
 */
function recordAgentEvent(cwd, event) {
  try {
    if (isKillSwitchActive()) return;

    const root = findProjectRoot(cwd);
    if (!root) return;

    const cfg = getConfig(cwd);
    if (!cfg.enabled) return;

    if (!getAgentMap(cwd)) return;

    appendRecord(root, AGENT_LEDGER_FILENAME, event);
  } catch (e) {
    swallowFailure(e);
  }
}

module.exports = {
  recordEvent,
  recordAgentEvent,
  ROTATE_MAX_BYTES,
  MAX_FIELD_LEN,
  STATE_DIRNAME,
  LEDGER_FILENAME,
  AGENT_LEDGER_FILENAME,
};
