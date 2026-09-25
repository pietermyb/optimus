#!/usr/bin/env node
'use strict';

/**
 * Claude Code PostToolUse / PostToolUseFailure adapter (Agent tool) —
 * closes the agent-map row the PreToolUse gate opened with
 * agent_dispatch + agent_started. One executable serves both events; it
 * branches on hook_event_name. Payload shapes verified by CP1/CP2 in
 * docs/claude-probe-findings.md:
 *   - PostToolUse:         tool_use_id (join key), duration_ms,
 *                          tool_response.status / agentId / resolvedModel
 *   - PostToolUseFailure:  tool_use_id, error, duration_ms
 *
 * Same subagent exemption as the gate (agent_id/agent_type): a nested
 * dispatch's completion has no gate-authored start row to close, so a
 * finish row for it would be noise.
 *
 * Enforces nothing. Emits {} and exits 0 — probe-verified safe for both
 * events. Never throws; a write failure degrades to a missing row
 * (recordAgentEvent's contract), never to a wedged tool result. The raw
 * tool_input.prompt is never recorded.
 */

const path = require('path');
const {
  isKillSwitchActive,
  getConfig,
} = require(path.join(__dirname, 'optimus-config.js'));
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

  // Subagent exemption — same short-circuit position as the gate.
  if (payload.agent_id || payload.agent_type) return emit({});

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return emit({});
  }
  if (!cfg.enabled) return emit({});

  const toolUseId =
    typeof payload.tool_use_id === 'string' ? payload.tool_use_id : '';
  const sessionId =
    typeof payload.session_id === 'string' ? payload.session_id : '';
  if (toolUseId === '' || sessionId === '') return emit({});

  const toolInput = payload.tool_input || {};
  const response = payload.tool_response || {};
  const failed = payload.hook_event_name === 'PostToolUseFailure';

  const finished = {
    ev: 'agent_finished',
    session_id: sessionId,
    // Join key: the parent's tool_use_id, same as Cursor's stop rows and
    // the gate's started row. agent_conversation_id arrives below on the
    // success path only.
    subagent_id: toolUseId,
    status: failed
      ? 'error'
      : typeof response.status === 'string' && response.status !== ''
        ? response.status
        : 'completed',
  };

  if (
    typeof toolInput.subagent_type === 'string' &&
    toolInput.subagent_type.trim() !== ''
  ) {
    finished.agent_type = toolInput.subagent_type;
  }

  if (typeof payload.duration_ms === 'number' && Number.isFinite(payload.duration_ms)) {
    finished.duration_ms = payload.duration_ms;
  }

  if (failed) {
    // CP2: a validation failure means no subagent ever ran, but the gate
    // still wrote dispatch/started for this tool_use_id — this row is
    // what closes them as error. The writer caps error_message at 200.
    if (typeof payload.error === 'string' && payload.error.trim() !== '') {
      finished.error_message = payload.error;
    }
  } else {
    // Success path (CP1): agent_conversation_id and the subagent's actual
    // model are only learnable here, never at dispatch time.
    if (typeof response.agentId === 'string' && response.agentId.trim() !== '') {
      finished.agent_conversation_id = response.agentId;
    }
    if (
      typeof response.resolvedModel === 'string' &&
      response.resolvedModel.trim() !== ''
    ) {
      finished.model = response.resolvedModel;
    }
  }

  recordAgentEvent(payload.cwd, finished);
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
