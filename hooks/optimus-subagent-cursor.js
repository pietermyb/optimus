#!/usr/bin/env node
'use strict';

/**
 * Cursor subagentStart / subagentStop adapter.
 *
 * Maintains the sidecar the Cursor gate consults to tell a subagent's own
 * tool calls apart from the orchestrator's (see hooks/optimus-sidecar.js
 * and docs/cursor-probe-findings.md). One executable serves both events;
 * it branches on hook_event_name.
 *
 * Enforces nothing. Always emits an explicit allow and exits 0 — on
 * Cursor, "no output" is not defined as allow the way it is on Claude
 * Code, and exit code 2 means deny.
 */

const path = require('path');
const { isKillSwitchActive, getConfig } = require(
  path.join(__dirname, 'optimus-config.js')
);
const { markActive, clearActive } = require(path.join(__dirname, 'optimus-sidecar.js'));

function done() {
  process.stdout.write(JSON.stringify({ permission: 'allow' }));
  process.exit(0);
}

function main(raw) {
  if (isKillSwitchActive()) return done();

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    return done();
  }
  if (!payload || typeof payload !== 'object') return done();

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return done();
  }
  if (!cfg.enabled) return done();

  // conversation_id is the marker's KEY (it identifies the subagent
  // itself) — do not confuse it with parentConversationId below, which is
  // the marker's VALUE (it identifies the subagent's dispatcher).
  //
  // conversation_id is the one field docs/cursor-probe-findings.md
  // confirms is present on every hook event, subagentStart and
  // subagentStop alike, and that identifies the same subagent on both.
  // subagent_id was rejected for this role: the probe only ever observed
  // it on subagentStart, where it is the parent's tool_use_id for the
  // Task call (not the subagent's own id), and a successful
  // subagentStop's raw payload was never captured, so whether it repeats
  // that same value there is an unverified assumption, not a confirmed
  // fact. Fall back through the rest so a renamed/missing field still
  // degrades to a still-unique key rather than to no marker at all.
  const id = payload.conversation_id || payload.subagent_id || payload.tool_call_id || payload.generation_id;

  if (payload.hook_event_name === 'subagentStart') {
    markActive(payload.cwd, id, payload.parent_conversation_id);
  } else if (payload.hook_event_name === 'subagentStop') {
    clearActive(payload.cwd, id);
  }
  return done();
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
      process.stdout.write(JSON.stringify({ permission: 'allow' }));
    } catch (e2) {
      // nothing left to do
    }
    process.exit(0);
  }
});
