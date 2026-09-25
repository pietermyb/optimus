#!/usr/bin/env node
'use strict';

/**
 * Claude Code SessionStart adapter — the Agent map's orchestrator root
 * row. Payload verified by CP3 in docs/claude-probe-findings.md:
 * {session_id, transcript_path, cwd, hook_event_name, source} — no
 * model/model_id field, so session_started.model is omitted on this host
 * and the extension falls back to the session_id shared by dispatch rows.
 * Duplicate rows across resume/clear/compact firings are legal (spec
 * §4.1) — the fold takes the latest.
 *
 * Also the proactive sidecar-marker sweep point, mirroring the Cursor
 * session hook: abandoned markers from a crashed window are best-effort
 * cleaned here too (clearStale only removes markers past STALE_MS).
 *
 * Enforces nothing and injects no policy text — UserPromptSubmit
 * reinforce owns per-turn reminders on this host. Emits {} and exits 0.
 * Never throws.
 */

const path = require('path');
const {
  isKillSwitchActive,
  getConfig,
} = require(path.join(__dirname, 'optimus-config.js'));
const { clearStale } = require(path.join(__dirname, 'optimus-sidecar.js'));
const { recordAgentEvent } = require(path.join(__dirname, 'optimus-ledger.js'));

function emit(obj) {
  process.stdout.write(JSON.stringify(obj));
  process.exit(0);
}

function main(raw) {
  if (isKillSwitchActive()) return emit({});

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    return emit({});
  }
  if (!payload || typeof payload !== 'object') return emit({});

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return emit({});
  }
  if (!cfg.enabled) return emit({});

  // Best effort only; never affects the hook protocol output.
  try {
    clearStale(payload.cwd);
  } catch (e) {
    // ignore — sweep is hygiene, not correctness
  }

  // Root row. CP3: the id field is session_id (conversation_id kept as a
  // fallback for shape parity with the Cursor handler); model is absent
  // on Claude Code and simply omitted when the payload carries none.
  try {
    const rootId = payload.session_id || payload.conversation_id;
    if (rootId) {
      const event = { ev: 'session_started', session_id: rootId };
      const model = payload.model || payload.model_id;
      if (model) event.model = model;
      recordAgentEvent(payload.cwd, event);
    }
  } catch (e) {
    // best effort only
  }

  return emit({});
}

let raw = '';
process.stdin.on('data', (d) => {
  raw += d;
});
process.stdin.on('end', () => {
  try {
    main(raw);
  } catch (e) {
    try {
      process.stdout.write('{}');
    } catch (e2) {
      // nothing left to do
    }
    process.exit(0);
  }
});
