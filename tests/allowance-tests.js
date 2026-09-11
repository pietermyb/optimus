#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const {
  consumeAllowance,
  hashConversationId,
  STATE_DIR,
  LOCK_MAX_ATTEMPTS,
  LOCK_RETRY_SLEEP_MS,
  STALE_LOCK_MS,
} = require(path.join(__dirname, '..', 'hooks', 'optimus-allowance.js'));

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

function withProject(fn) {
  const projectRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-allowance-'));
  const nestedCwd = path.join(projectRoot, 'work', 'dir');
  fs.mkdirSync(nestedCwd, { recursive: true });

  const optimusDir = path.join(projectRoot, '.optimus');
  fs.mkdirSync(optimusDir, { recursive: true });
  fs.writeFileSync(
    path.join(optimusDir, 'config.json'),
    JSON.stringify({ enabled: true }, null, 2) + '\n',
    'utf8'
  );

  try {
    fn({ projectRoot, nestedCwd });
  } finally {
    fs.rmSync(projectRoot, { recursive: true, force: true });
  }
}

function statePath(projectRoot, conversationId) {
  return path.join(projectRoot, STATE_DIR, hashConversationId(conversationId) + '.json');
}

function lockPath(projectRoot, conversationId) {
  return statePath(projectRoot, conversationId) + '.lock';
}

t('fresh conversation initializes allowance and consumes one unit', () => {
  withProject(({ projectRoot, nestedCwd }) => {
    const res = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convA',
      generationId: 'gen1',
      inlineAllowancePerTurn: 2,
    });

    assert.deepStrictEqual(res, { allowed: true, remaining: 1 });

    const stored = JSON.parse(fs.readFileSync(statePath(projectRoot, 'convA'), 'utf8'));
    assert.strictEqual(stored.conversationId, 'convA');
    assert.strictEqual(stored.lastGenerationId, 'gen1');
    assert.strictEqual(stored.remaining, 1);
    assert.ok(typeof stored.updatedAt === 'string' && stored.updatedAt.length > 0);
  });
});

t('same generation decrements until zero, then denies', () => {
  withProject(({ nestedCwd }) => {
    const one = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convB',
      generationId: 'genX',
      inlineAllowancePerTurn: 2,
    });
    const two = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convB',
      generationId: 'genX',
      inlineAllowancePerTurn: 2,
    });
    const three = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convB',
      generationId: 'genX',
      inlineAllowancePerTurn: 2,
    });

    assert.deepStrictEqual(one, { allowed: true, remaining: 1 });
    assert.deepStrictEqual(two, { allowed: true, remaining: 0 });
    assert.deepStrictEqual(three, { allowed: false, remaining: 0 });
  });
});

t('new generation resets allowance and consumes from fresh budget', () => {
  withProject(({ nestedCwd }) => {
    const g1a = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convC',
      generationId: 'gen1',
      inlineAllowancePerTurn: 2,
    });
    const g1b = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convC',
      generationId: 'gen1',
      inlineAllowancePerTurn: 2,
    });
    const g2a = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convC',
      generationId: 'gen2',
      inlineAllowancePerTurn: 2,
    });

    assert.deepStrictEqual(g1a, { allowed: true, remaining: 1 });
    assert.deepStrictEqual(g1b, { allowed: true, remaining: 0 });
    assert.deepStrictEqual(g2a, { allowed: true, remaining: 1 });
  });
});

t('state persists and reloads by conversation-specific filename', () => {
  withProject(({ projectRoot, nestedCwd }) => {
    consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convD',
      generationId: 'gen1',
      inlineAllowancePerTurn: 3,
    });

    const file = statePath(projectRoot, 'convD');
    assert.ok(fs.existsSync(file));

    const loaded = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convD',
      generationId: 'gen1',
      inlineAllowancePerTurn: 3,
    });
    assert.deepStrictEqual(loaded, { allowed: true, remaining: 1 });
  });
});

t('malicious conversation id is sanitized and cannot escape state dir', () => {
  withProject(({ projectRoot, nestedCwd }) => {
    const res = consumeAllowance({
      cwd: nestedCwd,
      conversationId: '../../etc/x',
      generationId: 'gen1',
      inlineAllowancePerTurn: 1,
    });

    assert.deepStrictEqual(res, { allowed: true, remaining: 0 });

    const stateDir = path.join(projectRoot, STATE_DIR);
    const files = fs.readdirSync(stateDir);
    assert.strictEqual(files.length, 1);
    assert.ok(!files[0].includes('/'));
    assert.ok(!files[0].includes('..'));
    assert.ok(fs.existsSync(path.join(stateDir, files[0])));
  });
});

t('missing conversation id fails closed as not allowed', () => {
  withProject(({ nestedCwd }) => {
    const res = consumeAllowance({
      cwd: nestedCwd,
      generationId: 'gen1',
      inlineAllowancePerTurn: 2,
    });
    assert.deepStrictEqual(res, { allowed: false, remaining: 0 });
  });
});

t('inlineAllowancePerTurn zero never allows', () => {
  withProject(({ nestedCwd }) => {
    const res = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convZero',
      generationId: 'gen1',
      inlineAllowancePerTurn: 0,
    });
    assert.deepStrictEqual(res, { allowed: false, remaining: 0 });
  });
});

t('conversation ids that previously collided under sanitization get separate state', () => {
  withProject(({ projectRoot, nestedCwd }) => {
    // Under the old sanitizer both ids reduced to the same 'abc_def'
    // filename and would have shared one budget. They must not anymore.
    const a = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'abc/def',
      generationId: 'gen1',
      inlineAllowancePerTurn: 1,
    });
    const b = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'abc:def',
      generationId: 'gen1',
      inlineAllowancePerTurn: 1,
    });

    assert.deepStrictEqual(a, { allowed: true, remaining: 0 });
    assert.deepStrictEqual(b, { allowed: true, remaining: 0 });

    const fileA = statePath(projectRoot, 'abc/def');
    const fileB = statePath(projectRoot, 'abc:def');
    assert.notStrictEqual(fileA, fileB);
    assert.ok(fs.existsSync(fileA));
    assert.ok(fs.existsSync(fileB));

    const storedA = JSON.parse(fs.readFileSync(fileA, 'utf8'));
    const storedB = JSON.parse(fs.readFileSync(fileB, 'utf8'));
    assert.strictEqual(storedA.conversationId, 'abc/def');
    assert.strictEqual(storedB.conversationId, 'abc:def');

    // 'abc/def' already spent its budget of 1 above; a second call for it
    // must be denied rather than silently pulling from 'abc:def's separate,
    // untouched budget.
    const aAgain = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'abc/def',
      generationId: 'gen1',
      inlineAllowancePerTurn: 1,
    });
    assert.deepStrictEqual(aAgain, { allowed: false, remaining: 0 });
  });
});

t('stale lock directory is recovered rather than wedging the conversation forever', () => {
  withProject(({ projectRoot, nestedCwd }) => {
    fs.mkdirSync(path.join(projectRoot, STATE_DIR), { recursive: true });

    const ld = lockPath(projectRoot, 'convStaleLock');
    fs.mkdirSync(ld);
    const staleTime = (Date.now() - STALE_LOCK_MS - 1000) / 1000;
    fs.utimesSync(ld, staleTime, staleTime);

    const res = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convStaleLock',
      generationId: 'gen1',
      inlineAllowancePerTurn: 2,
    });

    assert.deepStrictEqual(res, { allowed: true, remaining: 1 });
    // The lock this call acquired (after clearing the stale one) must be
    // released again once the write completes.
    assert.ok(!fs.existsSync(ld));
  });
});

t('a currently-held fresh lock denies promptly instead of throwing or hanging', () => {
  withProject(({ projectRoot, nestedCwd }) => {
    fs.mkdirSync(path.join(projectRoot, STATE_DIR), { recursive: true });

    const ld = lockPath(projectRoot, 'convFreshLock');
    fs.mkdirSync(ld); // fresh mtime — must NOT be treated as stale

    const start = Date.now();
    const res = consumeAllowance({
      cwd: nestedCwd,
      conversationId: 'convFreshLock',
      generationId: 'gen1',
      inlineAllowancePerTurn: 2,
    });
    const elapsed = Date.now() - start;

    assert.deepStrictEqual(res, { allowed: false, remaining: 0 });

    // The retry loop's own budget is LOCK_MAX_ATTEMPTS attempts with
    // LOCK_RETRY_SLEEP_MS between them; allow generous overhead margin but
    // this must stay a hot-path number of milliseconds, nowhere near
    // seconds.
    const maxBudgetMs = LOCK_MAX_ATTEMPTS * LOCK_RETRY_SLEEP_MS + 500;
    assert.ok(
      elapsed < maxBudgetMs,
      'expected a prompt deny under the lock retry budget, took ' + elapsed + 'ms'
    );

    fs.rmSync(ld, { recursive: true, force: true });
  });
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
