#!/usr/bin/env node
'use strict';

/**
 * Cursor sessionStart adapter — one-shot policy injection.
 *
 * Cursor has no UserPromptSubmit/additionalContext equivalent, so the
 * Claude Code build's per-turn reinjection (hooks/optimus-reinforce.js)
 * cannot be ported directly. beforeSubmitPrompt returns only
 * {continue, user_message} — a gate, not an injector — and must not be
 * repurposed. Coverage on Cursor is therefore split:
 *   turn 1        -> this hook's additional_context
 *   every turn    -> the alwaysApply rule at .cursor/rules/optimus.mdc
 *
 * The text comes from cursor/optimus.mdc, frontmatter stripped, so the
 * rule and this hook can never drift apart.
 *
 * Enforces nothing. Emits {} when Optimus is inactive or the kill switch
 * is on. Never throws.
 */

const fs = require('fs');
const path = require('path');
const { isKillSwitchActive, getConfig } = require(
  path.join(__dirname, 'optimus-config.js')
);
const { clearStale } = require(path.join(__dirname, 'optimus-sidecar.js'));
const { recordAgentEvent } = require(path.join(__dirname, 'optimus-ledger.js'));

const RULE_PATH = path.join(__dirname, '..', 'cursor', 'optimus.mdc');

/** Strips a leading `---`-delimited YAML frontmatter block, if present. */
function stripFrontmatter(text) {
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/.exec(text);
  return (match ? text.slice(match[0].length) : text).trim();
}

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

  // sessionStart is the safest proactive cleanup point for abandoned markers.
  // This must never affect the hook protocol output.
  try {
    clearStale(payload.cwd);
  } catch (e) {
    // best effort only; keep emitting additional_context
  }

  // Agent-map stream: the orchestrator root row. The sessionStart field
  // set is unverified (Stage-0 fallback accepted): write whatever id
  // exists, include model only if the payload carries one, and skip the
  // row entirely when there is no id at all — the extension then
  // synthesizes the root from the shared session_id of dispatch rows.
  try {
    const rootId = payload.conversation_id || payload.session_id;
    if (rootId) {
      recordAgentEvent(payload.cwd, {
        ev: 'session_started',
        session_id: rootId,
        model: payload.model || payload.model_id,
      });
    }
  } catch (e) {
    // best effort only; keep emitting additional_context
  }

  let text;
  try {
    text = stripFrontmatter(fs.readFileSync(RULE_PATH, 'utf8'));
  } catch (e) {
    return emit({}); // the rule file is the only source; no fallback copy
  }
  if (text === '') return emit({});

  return emit({ additional_context: text });
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
