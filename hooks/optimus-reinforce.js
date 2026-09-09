#!/usr/bin/env node
'use strict';

/**
 * UserPromptSubmit hook — continuous reinforcement.
 *
 * A one-shot SessionStart injection decays across a long session,
 * especially past compaction or once other plugins add their own
 * competing instructions (this is exactly why `caveman` added its own
 * per-turn reminder on top of its SessionStart injection — see the
 * research notes this plugin was built from). This hook re-injects a
 * short reminder of Optimus's policy on every user turn, but only when
 * Optimus is actually active for the project and the kill switch is off.
 *
 * This hook is advisory only — it does not enforce anything by itself.
 * Enforcement lives entirely in optimus-gate.js (PreToolUse).
 */

const path = require('path');
const { isKillSwitchActive, getConfig } = require(path.join(__dirname, 'optimus-config.js'));

const REMINDER = [
  'Optimus is active for this project: you are the orchestrator, not the worker.',
  'Read, Edit, Write, Grep, Glob, WebFetch, WebSearch, and NotebookEdit are blocked in this session — delegate them via the Agent tool.',
  'Every Agent dispatch must name a model explicitly: model="haiku" for simple/mechanical work, model="sonnet" for anything needing real judgement. Never omit model, never dispatch on opus.',
  'Bash stays open for orchestration (git, builds, tests, process control/flashing) — but prefer a delegated subagent over cat/grep/head/find for reading or searching files.',
].join(' ');

function main(raw) {
  if (isKillSwitchActive()) return process.exit(0);

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    return process.exit(0);
  }
  if (!payload || typeof payload !== 'object') return process.exit(0);

  // Subagents get their own prompts; they don't need the orchestrator reminder.
  if (payload.agent_id || payload.agent_type) return process.exit(0);

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return process.exit(0);
  }
  if (!cfg.enabled) return process.exit(0);

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'UserPromptSubmit',
        additionalContext: REMINDER,
      },
    })
  );
  process.exit(0);
}

let raw = '';
process.stdin.on('data', (d) => {
  raw += d;
});
process.stdin.on('end', () => {
  try {
    main(raw);
  } catch (e) {
    process.exit(0);
  }
});
