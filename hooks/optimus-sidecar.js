'use strict';

/**
 * Subagent attribution for the Cursor build.
 *
 * Cursor's preToolUse payload carries no field marking a call as a
 * subagent's (spec Section 5.1 decision-matrix row 2, confirmed
 * empirically in docs/cursor-probe-findings.md). What it does carry is
 * conversation_id, and the probe established that a subagent's tool
 * calls carry the SUBAGENT's own conversation_id while subagentStart
 * carries the parent's as parent_conversation_id — and fires before the
 * subagent's first tool call.
 *
 * So: record the parent's conversation id for the lifetime of each
 * dispatch, and the gate's question becomes "is this call's conversation
 * one of the recorded parents?" A recorded parent is the orchestrator;
 * anything else, while a dispatch is outstanding, is a subagent. That is
 * exact per-call attribution with no race against parallel subagents,
 * because every payload carries its own originating conversation.
 *
 * One marker FILE per outstanding subagent — filename is keyed on the
 * subagent's own conversation_id (see the key-selection comment in
 * hooks/optimus-subagent-cursor.js for the exact fallback chain),
 * contents are the parent's conversation id. Never one shared JSON
 * document: that would need read-modify-write, reopening exactly the
 * concurrency race hooks/optimus-ledger.js's append-only design avoids.
 * Two writers never touch the same path here.
 *
 * The filename is only a unique key so subagentStop can clear the right
 * entry; markActive()/clearActive() below never interpret it as data.
 * conversation_id is used for it because the probe confirms it is
 * present, and identical, on both subagentStart and subagentStop for a
 * given subagent. subagentStart.subagent_id was rejected for this role:
 * the probe only ever observed it on subagentStart — it is the parent's
 * tool_use_id for the Task call, not the subagent's own id — and a
 * successful subagentStop's raw payload was never captured, so whether
 * it repeats that value there is unverified.
 *
 * Never throws. parentConversations() sits on the gate's hot path.
 */

const fs = require('fs');
const path = require('path');
const { findProjectRoot } = require(path.join(__dirname, 'optimus-config.js'));

const SIDECAR_DIRNAME = 'active-subagents';
/** A marker older than this is treated as abandoned (missed subagentStop). */
const STALE_MS = 30 * 60 * 1000;
/** Defensive cap on the parent id written into a marker. */
const MAX_ID_LEN = 200;

/** Reduces an id to a single safe path segment. Never returns ''. */
function safeId(id) {
  const cleaned = String(id == null ? '' : id).replace(/[^\w.-]/g, '_').slice(0, 128);
  return cleaned === '' || cleaned === '.' || cleaned === '..' ? 'unknown' : cleaned;
}

function sidecarDir(cwd) {
  const root = findProjectRoot(cwd);
  if (!root) return null;
  return path.join(root, '.optimus', 'state', SIDECAR_DIRNAME);
}

/**
 * Record that a subagent identified by `subagentId` is outstanding, and
 * that the conversation which dispatched it is `parentConversationId`.
 */
function markActive(cwd, subagentId, parentConversationId) {
  try {
    const dir = sidecarDir(cwd);
    if (!dir) return;
    const parent = String(parentConversationId == null ? '' : parentConversationId)
      .trim()
      .slice(0, MAX_ID_LEN);
    if (parent === '') return; // without a parent id the marker carries no signal
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, safeId(subagentId)), parent, { mode: 0o600 });
  } catch (e) {
    // Best effort. A failure here means the subagent's calls are treated
    // as the orchestrator's and get enforced — the safe direction to fail
    // on a host where the caller cannot otherwise be identified.
  }
}

function clearActive(cwd, subagentId) {
  try {
    const dir = sidecarDir(cwd);
    if (!dir) return;
    fs.unlinkSync(path.join(dir, safeId(subagentId)));
  } catch (e) {
    // Already gone, or never written. The probe observed a real case: a
    // dispatch that fails validation fires subagentStop with no preceding
    // subagentStart.
  }
}

/**
 * The set of conversation ids that currently have at least one subagent
 * outstanding. Stale markers are unlinked as they are found, so a missed
 * subagentStop cannot keep a parent recorded indefinitely.
 */
function parentConversations(cwd) {
  const parents = new Set();
  try {
    const dir = sidecarDir(cwd);
    if (!dir) return parents;
    const cutoff = Date.now() - STALE_MS;
    for (const name of fs.readdirSync(dir)) {
      const file = path.join(dir, name);
      try {
        if (fs.statSync(file).mtimeMs < cutoff) {
          fs.unlinkSync(file);
          continue;
        }
        const parent = fs.readFileSync(file, 'utf8').trim();
        if (parent !== '') parents.add(parent);
      } catch (e) {
        // vanished mid-scan, or unreadable — carries no signal
      }
    }
  } catch (e) {
    // no sidecar dir, unreadable, or not an Optimus project
  }
  return parents;
}

/**
 * True if `conversationId` belongs to a dispatched subagent rather than
 * the orchestrator.
 *
 * With no dispatch outstanding there are no subagent calls either, so an
 * empty parent set means "everything is the orchestrator". A payload with
 * no conversation id is treated as the orchestrator's — enforcing on an
 * unidentifiable call is the safer direction than exempting it, and every
 * payload the probe observed carried one.
 */
function isSubagentConversation(cwd, conversationId) {
  if (typeof conversationId !== 'string' || conversationId.trim() === '') return false;
  const parents = parentConversations(cwd);
  if (parents.size === 0) return false;
  return !parents.has(conversationId);
}

module.exports = {
  markActive,
  clearActive,
  parentConversations,
  isSubagentConversation,
  SIDECAR_DIRNAME,
  STALE_MS,
};
