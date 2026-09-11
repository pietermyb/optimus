#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.join(__dirname, '..');
const cfg = require(path.join(root, 'hooks', 'optimus-config.js'));
const core = require(path.join(root, 'hooks', 'optimus-core.js'));

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); console.log('PASS: ' + name); pass++; }
  catch (e) { console.log('FAIL: ' + name + ' -- ' + e.message); fail++; }
}

/** A project whose .optimus/config.json is exactly `body`. */
function project(body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-cfg-'));
  fs.mkdirSync(path.join(dir, '.optimus'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.optimus', 'config.json'), JSON.stringify(body));
  return dir;
}

const BASE = { enabled: true, updatedAt: '2026-09-11T00:00:00.000Z' };

// --- expensiveModelPattern ---------------------------------------------
t('defaults to /opus/i when the key is absent', () => {
  const re = cfg.getExpensiveModelRe(project(BASE));
  assert.strictEqual(re.test('claude-opus-5'), true);
  assert.strictEqual(re.test('claude-sonnet-5'), false);
});
t('honours an override pattern', () => {
  const re = cfg.getExpensiveModelRe(project(Object.assign({}, BASE, { expensiveModelPattern: 'gpt-5|opus' })));
  assert.strictEqual(re.test('gpt-5-pro'), true);
  assert.strictEqual(re.test('claude-opus-5'), true);
});
t('an override is always case-insensitive', () => {
  const re = cfg.getExpensiveModelRe(project(Object.assign({}, BASE, { expensiveModelPattern: 'OPUS' })));
  assert.strictEqual(re.test('claude-opus-5'), true);
});
t('an invalid regex falls back to the default, it does not throw', () => {
  const re = cfg.getExpensiveModelRe(project(Object.assign({}, BASE, { expensiveModelPattern: '([unclosed' })));
  assert.strictEqual(re.test('claude-opus-5'), true);
  assert.strictEqual(re.test('claude-haiku-4-5'), false);
});
t('a non-string pattern falls back to the default', () => {
  const re = cfg.getExpensiveModelRe(project(Object.assign({}, BASE, { expensiveModelPattern: 42 })));
  assert.strictEqual(re.test('claude-opus-5'), true);
});

// --- gatedTools ---------------------------------------------------------
t('defaults to the built-in work tools', () => {
  const tools = cfg.getGatedTools(project(BASE));
  assert.strictEqual(tools.has('Read'), true);
  assert.strictEqual(tools.has('NotebookEdit'), true);
  assert.strictEqual(tools.has('Bash'), false);
});
t('honours an override list', () => {
  const tools = cfg.getGatedTools(project(Object.assign({}, BASE, { gatedTools: ['Read'] })));
  assert.deepStrictEqual([...tools], ['Read']);
});
t('an empty override list means "gate nothing", not "use defaults"', () => {
  const tools = cfg.getGatedTools(project(Object.assign({}, BASE, { gatedTools: [] })));
  assert.strictEqual(tools.size, 0);
});
t('a non-array falls back to the defaults', () => {
  const tools = cfg.getGatedTools(project(Object.assign({}, BASE, { gatedTools: 'Read' })));
  assert.strictEqual(tools.has('Read'), true);
  assert.strictEqual(tools.has('Write'), true);
});
t('non-string entries are dropped', () => {
  const tools = cfg.getGatedTools(project(Object.assign({}, BASE, { gatedTools: ['Read', 7, null] })));
  assert.deepStrictEqual([...tools], ['Read']);
});
t('the returned set is not the module constant', () => {
  const tools = cfg.getGatedTools(project(BASE));
  tools.add('Mutated');
  assert.strictEqual(cfg.WORK_TOOLS.has('Mutated'), false);
});

// The default must be the FULL effective gated set, Delete included, so
// that an adapter can hand the result straight to decide() without
// topping it up. That top-up used to live in both gate adapters; these
// three tests are what stops it coming back.
t('the default gated set includes Cursor Delete', () => {
  assert.strictEqual(cfg.getGatedTools(project(BASE)).has('Delete'), true);
});
t('the default gated set is exactly what decide() gates with no policy', () => {
  assert.deepStrictEqual(
    [...cfg.getGatedTools(project(BASE))].sort(),
    [...core.WORK_TOOLS].sort()
  );
});
t('an explicit override is returned verbatim, NOT unioned with Delete', () => {
  const tools = cfg.getGatedTools(project(Object.assign({}, BASE, { gatedTools: ['Read'] })));
  assert.deepStrictEqual([...tools], ['Read']);
  assert.strictEqual(tools.has('Delete'), false);
});
t('an override naming Delete alone gates only Delete', () => {
  const tools = cfg.getGatedTools(project(Object.assign({}, BASE, { gatedTools: ['Delete'] })));
  assert.deepStrictEqual([...tools], ['Delete']);
});
t('WORK_TOOLS itself stays host-neutral: no Delete', () => {
  assert.strictEqual(cfg.WORK_TOOLS.has('Delete'), false);
  assert.strictEqual(cfg.DEFAULT_GATED_TOOLS.has('Delete'), true);
});

// --- shellBypassPatterns ------------------------------------------------
const matchesAny = (pats, cmd) => pats.some((p) => p.test(cmd));

t('defaults to the built-in bypass patterns', () => {
  const pats = cfg.getShellBypassPatterns(project(BASE));
  assert.strictEqual(matchesAny(pats, 'cat src/index.js'), true);
  assert.strictEqual(matchesAny(pats, 'git status'), false);
});
t('honours an override list', () => {
  const pats = cfg.getShellBypassPatterns(project(Object.assign({}, BASE, { shellBypassPatterns: ['^\\s*bat\\s+'] })));
  assert.strictEqual(matchesAny(pats, 'bat src/index.js'), true);
  assert.strictEqual(matchesAny(pats, 'cat src/index.js'), false);
});
t('an invalid entry is skipped, the valid ones survive', () => {
  const pats = cfg.getShellBypassPatterns(project(Object.assign({}, BASE, { shellBypassPatterns: ['([unclosed', '^\\s*bat\\s+'] })));
  assert.strictEqual(pats.length, 1);
  assert.strictEqual(matchesAny(pats, 'bat x'), true);
});
t('an all-invalid list falls back to the defaults', () => {
  const pats = cfg.getShellBypassPatterns(project(Object.assign({}, BASE, { shellBypassPatterns: ['([unclosed'] })));
  assert.strictEqual(matchesAny(pats, 'cat src/index.js'), true);
});
t('an empty override list means "bypass check off"', () => {
  const pats = cfg.getShellBypassPatterns(project(Object.assign({}, BASE, { shellBypassPatterns: [] })));
  assert.deepStrictEqual(pats, []);
});

// --- gatedToolPatterns --------------------------------------------------
const matchesAnyName = (pats, name) => pats.some((p) => p.test(name));

t('absent by default: no patterns, so nothing extra is gated', () => {
  assert.deepStrictEqual(cfg.getGatedToolPatterns(project(BASE)), []);
});
t('mcp__* matches every MCP tool but no built-in tool', () => {
  const pats = cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: ['mcp__*'] })));
  assert.strictEqual(matchesAnyName(pats, 'mcp__grafana-multi__query_loki_logs'), true);
  assert.strictEqual(matchesAnyName(pats, 'mcp__github__list_issues'), true);
  assert.strictEqual(matchesAnyName(pats, 'Read'), false);
  assert.strictEqual(matchesAnyName(pats, 'Bash'), false);
});
t('* is the only wildcard: a . in a tool name is a literal, not any-char', () => {
  const pats = cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: ['mcp__foo.bar__*'] })));
  assert.strictEqual(matchesAnyName(pats, 'mcp__foo.bar__do'), true);
  assert.strictEqual(matchesAnyName(pats, 'mcp__fooXbar__do'), false);
});
t('the glob is anchored: a prefix match alone does not gate', () => {
  const pats = cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: ['mcp__github'] })));
  assert.strictEqual(matchesAnyName(pats, 'mcp__github'), true);
  assert.strictEqual(matchesAnyName(pats, 'mcp__github__list_issues'), false);
});
t('the match is case-sensitive', () => {
  const pats = cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: ['Read'] })));
  assert.strictEqual(matchesAnyName(pats, 'Read'), true);
  assert.strictEqual(matchesAnyName(pats, 'read'), false);
});
t('a non-string entry is skipped, the valid ones survive', () => {
  const pats = cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: [7, null, 'mcp__*'] })));
  assert.strictEqual(pats.length, 1);
  assert.strictEqual(matchesAnyName(pats, 'mcp__x__y'), true);
});
t('a non-array value yields no patterns', () => {
  assert.deepStrictEqual(cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: 'mcp__*' }))), []);
});
t('globToRegExp escapes regex metacharacters other than *', () => {
  const re = cfg.globToRegExp('a+b(*)');
  assert.strictEqual(re.test('a+b(zzz)'), true);
  assert.strictEqual(re.test('aab(z)'), false);
});

// --- no project ---------------------------------------------------------
t('a directory with no .optimus still yields defaults, never throws', () => {
  const bare = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-bare-'));
  assert.strictEqual(cfg.getExpensiveModelRe(bare).test('claude-opus-5'), true);
  assert.strictEqual(cfg.getGatedTools(bare).has('Read'), true);
  assert.strictEqual(cfg.getGatedTools(bare).has('Delete'), true);
  assert.deepStrictEqual(cfg.getGatedToolPatterns(bare), []);
  assert.strictEqual(cfg.getShellBypassPatterns(bare).length > 0, true);
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
