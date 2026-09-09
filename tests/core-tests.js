#!/usr/bin/env node
'use strict';

/**
 * Direct unit tests for hooks/optimus-core.js.
 *
 * These are deliberately fast and in-process: unlike run-gate-tests.sh,
 * which spawns a node subprocess per fixture to exercise the whole
 * stdin/stdout hook contract, these call decide() with plain objects.
 * Policy regressions should be caught here; shape/plumbing regressions
 * are caught by the per-host adapter suites.
 */

const assert = require('assert');
const path = require('path');
const core = require(path.join(__dirname, '..', 'hooks', 'optimus-core.js'));

const { AGENT_DISPATCH, SHELL, REASON, decide, ledgerEventFor, cmdHead } = core;

const ON = { enabled: true };
const OFF = { enabled: false };

let pass = 0;
let fail = 0;

function t(name, fn) {
  try {
    fn();
    console.log('PASS: ' + name);
    pass++;
  } catch (e) {
    console.log('FAIL: ' + name + ' -- ' + e.message);
    fail++;
  }
}

function d(over) {
  return decide(Object.assign({
    tool: 'Read',
    toolInput: {},
    isSubagent: false,
    sessionModel: null,
    config: ON,
  }, over));
}

// --- activation ---------------------------------------------------------
t('inactive project allows a work tool', () => {
  assert.deepStrictEqual(d({ config: OFF }), { allow: true, reason: null });
});
t('inactive project allows a model-less dispatch', () => {
  assert.strictEqual(d({ tool: AGENT_DISPATCH, config: OFF }).allow, true);
});

// --- subagent exemption (load-bearing, must win over everything) --------
t('subagent work tool is allowed', () => {
  assert.deepStrictEqual(d({ isSubagent: true }), { allow: true, reason: null });
});
t('subagent model-less dispatch is allowed', () => {
  assert.strictEqual(d({ tool: AGENT_DISPATCH, isSubagent: true }).allow, true);
});

// --- dispatch model rules ----------------------------------------------
t('dispatch with no model is denied', () => {
  const r = d({ tool: AGENT_DISPATCH, toolInput: {} });
  assert.strictEqual(r.allow, false);
  assert.strictEqual(r.reason, REASON.NO_MODEL_SET);
});
t('dispatch with whitespace-only model is denied', () => {
  assert.strictEqual(d({ tool: AGENT_DISPATCH, toolInput: { model: '   ' } }).reason, REASON.NO_MODEL_SET);
});
t('dispatch with non-string model is denied', () => {
  assert.strictEqual(d({ tool: AGENT_DISPATCH, toolInput: { model: 3 } }).reason, REASON.NO_MODEL_SET);
});
t('dispatch on an opus model is denied and echoes the model', () => {
  const r = d({ tool: AGENT_DISPATCH, toolInput: { model: 'claude-opus-5' } });
  assert.strictEqual(r.allow, false);
  assert.strictEqual(r.reason, REASON.EXPENSIVE_MODEL_DISPATCH);
  assert.strictEqual(r.model, 'claude-opus-5');
});
t('dispatch on haiku is allowed', () => {
  assert.deepStrictEqual(d({ tool: AGENT_DISPATCH, toolInput: { model: 'haiku' } }), { allow: true, reason: null });
});

// --- work tools ---------------------------------------------------------
for (const tool of ['Read', 'Edit', 'Write', 'Grep', 'Glob', 'WebFetch', 'WebSearch', 'NotebookEdit']) {
  t('work tool ' + tool + ' is denied in the orchestrator', () => {
    const r = d({ tool: tool });
    assert.strictEqual(r.allow, false);
    assert.strictEqual(r.reason, REASON.WORK_TOOL_IN_ORCHESTRATOR);
    assert.strictEqual(r.tool, tool);
  });
}
t('Cursor Delete is a work tool', () => {
  assert.strictEqual(d({ tool: 'Delete' }).reason, REASON.WORK_TOOL_IN_ORCHESTRATOR);
});
t('an unrecognized tool name is allowed (fail open on vocabulary)', () => {
  assert.deepStrictEqual(d({ tool: 'MCP:atlassian_search' }), { allow: true, reason: null });
});

// --- shell speed bump ---------------------------------------------------
t('shell git status is allowed', () => {
  assert.strictEqual(d({ tool: SHELL, toolInput: { command: 'git status' } }).allow, true);
});
t('shell cat is denied', () => {
  assert.strictEqual(d({ tool: SHELL, toolInput: { command: 'cat work.txt' } }).reason, REASON.SHELL_READ_BYPASS);
});
t('shell grep --help is allowed', () => {
  assert.strictEqual(d({ tool: SHELL, toolInput: { command: 'grep --help' } }).allow, true);
});
t('shell with a missing command is allowed', () => {
  assert.strictEqual(d({ tool: SHELL, toolInput: {} }).allow, true);
});

// --- model-conditional enforcement (opt-in, default off) ---------------
t('modelConditional off: cheap session model still enforces', () => {
  assert.strictEqual(d({ tool: 'Read', sessionModel: 'claude-haiku-4-5', config: { enabled: true } }).allow, false);
});
t('modelConditional on: cheap session model is exempt', () => {
  assert.strictEqual(d({ tool: 'Read', sessionModel: 'claude-haiku-4-5', config: { enabled: true, modelConditional: true } }).allow, true);
});
t('modelConditional on: expensive session model still enforces', () => {
  assert.strictEqual(d({ tool: 'Read', sessionModel: 'claude-opus-5', config: { enabled: true, modelConditional: true } }).allow, false);
});
t('modelConditional on with no session model still enforces', () => {
  assert.strictEqual(d({ tool: 'Read', sessionModel: null, config: { enabled: true, modelConditional: true } }).allow, false);
});
t('modelConditional on: a cheap session model does NOT waive the dispatch rule', () => {
  const cfg = { enabled: true, modelConditional: true };
  assert.strictEqual(d({ tool: AGENT_DISPATCH, toolInput: { model: 'claude-opus-5' }, sessionModel: 'claude-haiku-4-5', config: cfg }).reason, REASON.EXPENSIVE_MODEL_DISPATCH);
  assert.strictEqual(d({ tool: AGENT_DISPATCH, toolInput: {}, sessionModel: 'claude-haiku-4-5', config: cfg }).reason, REASON.NO_MODEL_SET);
});
t('modelConditional on: a cheap session model still allows a cheap dispatch', () => {
  assert.strictEqual(d({ tool: AGENT_DISPATCH, toolInput: { model: 'haiku' }, sessionModel: 'claude-haiku-4-5', config: { enabled: true, modelConditional: true } }).allow, true);
});
t('modelConditional on: a cheap session model still exempts the shell speed bump', () => {
  assert.strictEqual(d({ tool: SHELL, toolInput: { command: 'cat work.txt' }, sessionModel: 'claude-haiku-4-5', config: { enabled: true, modelConditional: true } }).allow, true);
});

// --- ledger event mapping ----------------------------------------------
t('allowed dispatch maps to dispatch_allowed with model and agent_type', () => {
  const toolInput = { model: 'haiku', subagent_type: 'general-purpose' };
  const decision = decide({ tool: AGENT_DISPATCH, toolInput, isSubagent: false, sessionModel: null, config: ON });
  assert.deepStrictEqual(ledgerEventFor({ tool: AGENT_DISPATCH, toolInput, decision }), {
    ev: 'dispatch_allowed',
    model: 'haiku',
    agent_type: 'general-purpose',
  });
});
t('model-less dispatch maps to dispatch_denied/no_model', () => {
  const toolInput = {};
  const decision = decide({ tool: AGENT_DISPATCH, toolInput, isSubagent: false, sessionModel: null, config: ON });
  assert.deepStrictEqual(ledgerEventFor({ tool: AGENT_DISPATCH, toolInput, decision }), {
    ev: 'dispatch_denied',
    reason: 'no_model',
  });
});
t('opus dispatch maps to dispatch_denied/expensive_model', () => {
  const toolInput = { model: 'claude-opus-5' };
  const decision = decide({ tool: AGENT_DISPATCH, toolInput, isSubagent: false, sessionModel: null, config: ON });
  assert.deepStrictEqual(ledgerEventFor({ tool: AGENT_DISPATCH, toolInput, decision }), {
    ev: 'dispatch_denied',
    reason: 'expensive_model',
    model: 'claude-opus-5',
  });
});
t('work tool denial maps to work_tool_denied', () => {
  const decision = decide({ tool: 'Read', toolInput: {}, isSubagent: false, sessionModel: null, config: ON });
  assert.deepStrictEqual(ledgerEventFor({ tool: 'Read', toolInput: {}, decision }), {
    ev: 'work_tool_denied',
    tool: 'Read',
  });
});
t('shell bypass maps to bash_nudge with a reduced cmd_head', () => {
  const toolInput = { command: 'cat /etc/passwd' };
  const decision = decide({ tool: SHELL, toolInput, isSubagent: false, sessionModel: null, config: ON });
  assert.deepStrictEqual(ledgerEventFor({ tool: SHELL, toolInput, decision }), {
    ev: 'bash_nudge',
    cmd_head: 'cat',
  });
});
t('an allow with no policy interest maps to null', () => {
  const decision = { allow: true, reason: null };
  assert.strictEqual(ledgerEventFor({ tool: SHELL, toolInput: { command: 'git status' }, decision }), null);
});

// --- cmdHead ------------------------------------------------------------
t('cmdHead keeps only the first token, word chars only', () => {
  assert.strictEqual(cmdHead('  sed -n 1,5p file.txt'), 'sed');
  assert.strictEqual(cmdHead('./scripts/deploy.sh --now'), 'scriptsdeploysh');
  assert.strictEqual(cmdHead(''), '');
  assert.strictEqual(cmdHead(undefined), '');
});
t('cmdHead truncates at 32 chars', () => {
  assert.strictEqual(cmdHead('a'.repeat(50)).length, 32);
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
