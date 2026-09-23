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
t('compileGlobPattern treats regex metacharacters as literals', () => {
  const re = cfg.compileGlobPattern('a+b(*)');
  assert.strictEqual(re.test('a+b(zzz)'), true);
  assert.strictEqual(re.test('aab(z)'), false);
});

// --- matchGlob: full metacharacter safety, anchoring, *, case -----------
// The old implementation only had test coverage for `+()` (the case
// above). Every other regex metacharacter needs its own proof that it is
// a plain literal now, not an operator: a glob containing it must match
// ONLY the literal string, never over-match the way an un-escaped regex
// special would.
t('every regex metacharacter is a literal, not an operator', () => {
  const literalGlobs = ['.', '+', '?', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\'];
  for (const ch of literalGlobs) {
    const m = cfg.matchGlob(ch, ch);
    assert.strictEqual(m, true, 'glob ' + JSON.stringify(ch) + ' should match its own literal character');
    assert.strictEqual(cfg.matchGlob(ch, 'X'), false, 'glob ' + JSON.stringify(ch) + ' should not match an unrelated character');
  }
  // All of them together in one glob, mixed with a wildcard.
  const mixed = '.+?()[]{}^$|\\*end';
  assert.strictEqual(cfg.matchGlob(mixed, '.+?()[]{}^$|\\anythingHEREend'), true);
  assert.strictEqual(cfg.matchGlob(mixed, '.+?()[]{}^$|\\end'), true); // * matches empty
  assert.strictEqual(cfg.matchGlob(mixed, 'X'), false);
});
t('dot is a literal dot: "a.b" does not match "axb"', () => {
  assert.strictEqual(cfg.matchGlob('a.b', 'a.b'), true);
  assert.strictEqual(cfg.matchGlob('a.b', 'axb'), false);
});
t('a bracket class is not special: "[ab]" matches only that literal string', () => {
  assert.strictEqual(cfg.matchGlob('[ab]', '[ab]'), true);
  assert.strictEqual(cfg.matchGlob('[ab]', 'a'), false);
  assert.strictEqual(cfg.matchGlob('[ab]', 'b'), false);
});
t('anchored at both ends: neither a prefix nor a suffix match counts', () => {
  assert.strictEqual(cfg.matchGlob('abc', 'abc'), true);
  assert.strictEqual(cfg.matchGlob('abc', 'abcd'), false); // prefix only
  assert.strictEqual(cfg.matchGlob('abc', 'xabc'), false); // suffix only
  assert.strictEqual(cfg.matchGlob('abc', 'xabcd'), false); // substring only
});
t('* matches the empty string', () => {
  assert.strictEqual(cfg.matchGlob('*', ''), true);
  assert.strictEqual(cfg.matchGlob('a*b', 'ab'), true);
  assert.strictEqual(cfg.matchGlob('*', 'anything'), true);
});
t('* matches a non-empty run, including one that looks like more stars', () => {
  assert.strictEqual(cfg.matchGlob('a*b', 'a***b'), true);
  assert.strictEqual(cfg.matchGlob('mcp__*', 'mcp__grafana-multi__query_loki_logs'), true);
});
t('multiple and adjacent stars behave the same as one star', () => {
  assert.strictEqual(cfg.matchGlob('a**b', 'ab'), true);
  assert.strictEqual(cfg.matchGlob('a**b', 'aXXXb'), true);
  assert.strictEqual(cfg.matchGlob('*a*b*', 'zzzaZZbzz'), true);
  assert.strictEqual(cfg.matchGlob('*a*b*', 'zzz'), false); // no a followed by a b at all
  assert.strictEqual(cfg.matchGlob('***', 'anything at all'), true);
  assert.strictEqual(cfg.matchGlob('***', ''), true);
});
t('matching is case-sensitive', () => {
  assert.strictEqual(cfg.matchGlob('Read', 'Read'), true);
  assert.strictEqual(cfg.matchGlob('Read', 'read'), false);
  assert.strictEqual(cfg.matchGlob('mcp__*', 'MCP__github__list'), false);
});

// --- perf: no catastrophic backtracking ----------------------------------
// This is the regression test for the actual bug: the OLD implementation
// built `new RegExp('^a' + '(?:.*a)'.repeat(12) ...)`-shaped patterns
// (every `*` became an unanchored `.*`), and a regex engine backtracks
// over every way to split a non-matching subject across that many stars
// -- exponential in the star count. Verified against the pre-fix
// implementation before this fix landed: this exact case took ~396ms
// (well over the 50ms budget here, and this only gets worse for longer
// subjects or one more star). The new linear two-pointer matcher has no
// backtracking search at all, so it stays far under budget regardless.
t('a pathological many-star glob does not blow up against a non-matching subject', () => {
  const glob = 'a' + '*a'.repeat(12) + 'X';
  const subject = 'a'.repeat(30); // no 'X' anywhere -> forces failure only after a full scan
  const start = Date.now();
  const result = cfg.matchGlob(glob, subject);
  const elapsedMs = Date.now() - start;
  assert.strictEqual(result, false);
  assert.strictEqual(elapsedMs < 50, true, 'expected well under 50ms, took ' + elapsedMs + 'ms');
});
t('the same pathological glob is just as fast through getGatedToolPatterns end-to-end', () => {
  const glob = 'a' + '*a'.repeat(12) + 'X';
  const subject = 'a'.repeat(30);
  const pats = cfg.getGatedToolPatterns(project(Object.assign({}, BASE, { gatedToolPatterns: [glob] })));
  const start = Date.now();
  const result = matchesAnyName(pats, subject);
  const elapsedMs = Date.now() - start;
  assert.strictEqual(result, false);
  assert.strictEqual(elapsedMs < 50, true, 'expected well under 50ms, took ' + elapsedMs + 'ms');
});

// --- union-with-defaults, end to end through decide() --------------------
// getGatedToolPatterns() now returns matcher objects, not RegExp
// instances. This is the guard against a regression where decide()'s
// `instanceof RegExp` check (pre-fix) would silently make every pattern
// inert -- gatedToolPatterns would stop gating anything, and the only
// thing still gating would be gatedTools' defaults. Proves the union
// still holds end-to-end: the resolver's real output reaches an actual
// deny through the shared core, and defaults keep gating alongside it.
t('getGatedToolPatterns output still gates through decide(): union, not replace', () => {
  const dir = project(Object.assign({}, BASE, { gatedToolPatterns: ['mcp__*'] }));
  const policy = {
    gatedTools: cfg.getGatedTools(dir),
    gatedToolPatterns: cfg.getGatedToolPatterns(dir),
  };
  const mcpDecision = core.decide({ tool: 'mcp__github__list_issues', policy: policy, config: { enabled: true } });
  assert.strictEqual(mcpDecision.allow, false);
  const readDecision = core.decide({ tool: 'Read', policy: policy, config: { enabled: true } });
  assert.strictEqual(readDecision.allow, false); // the default gated set still applies too
  const otherDecision = core.decide({ tool: 'SomeRandomTool', policy: policy, config: { enabled: true } });
  assert.strictEqual(otherDecision.allow, true);
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

// --- config file cache ---------------------------------------------------
// Covers hooks/optimus-config.js's process-lifetime configFileCache: it
// must never hand back a stale read, never let a caller corrupt the
// cached object, and never let two projects collide on it.

t('setConfig then getConfig in the same process sees the new value immediately', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-cache-'));
  cfg.setConfig(dir, true);
  const file = path.join(dir, '.optimus', 'config.json');

  // Pin the mtime to a fixed, whole-millisecond Date of our own choosing
  // both times below. Re-using a stat's own (possibly sub-millisecond)
  // mtimeMs through `new Date(...)` would round-trip lossily -- fs
  // timestamps only take whole milliseconds -- so a value read back
  // could silently fail to match the one just written. Starting from a
  // value we picked ourselves sidesteps that.
  const fixedMtime = new Date('2020-01-01T00:00:00.000Z');
  fs.utimesSync(file, fixedMtime, fixedMtime);
  cfg.getConfig(dir); // primes the cache at the fixed mtime

  // A second setConfig() with the SAME `enabled` value rewrites the file
  // with only `updatedAt` changed -- an ISO-8601 timestamp is always the
  // same length, so the file comes out byte-identical in size. Pinning
  // the mtime back to the same fixed value removes every incidental
  // (mtime, size) signal a cache-validity check could notice on its own
  // -- what's left is setConfig()'s own explicit
  // invalidateConfigFileCache() call, which is exactly what this test is
  // proving matters (see the comment on configFileCache in
  // hooks/optimus-config.js).
  cfg.setConfig(dir, true);
  fs.utimesSync(file, fixedMtime, fixedMtime);
  const onDisk = JSON.parse(fs.readFileSync(file, 'utf8'));

  assert.strictEqual(cfg.getConfig(dir).raw.updatedAt, onDisk.updatedAt);
});

t('an external write with a different size is picked up', () => {
  const dir = project(BASE);
  assert.strictEqual(cfg.getConfig(dir).enabled, true); // primes the cache

  const file = path.join(dir, '.optimus', 'config.json');
  fs.writeFileSync(file, JSON.stringify(Object.assign({}, BASE, { enabled: false, note: 'x'.repeat(40) })));

  assert.strictEqual(cfg.getConfig(dir).enabled, false);
});

t('an external same-size rewrite with a changed mtime is picked up', () => {
  const dir = project(Object.assign({}, BASE, { inlineAllowancePerTurn: 2 }));
  assert.strictEqual(cfg.getConfig(dir).inlineAllowancePerTurn, 2); // primes the cache

  const file = path.join(dir, '.optimus', 'config.json');
  const before = fs.readFileSync(file, 'utf8');
  const after = before.replace('"inlineAllowancePerTurn":2', '"inlineAllowancePerTurn":5');
  assert.strictEqual(before.length, after.length, 'test setup bug: rewrite must be byte-identical in size');
  fs.writeFileSync(file, after);
  // Same size as before, so only an mtime change can invalidate the
  // cache -- force one explicitly rather than hoping the write above
  // landed in a new mtime tick on its own.
  const st = fs.statSync(file);
  fs.utimesSync(file, new Date(st.atimeMs), new Date(st.mtimeMs + 1000));

  assert.strictEqual(cfg.getConfig(dir).inlineAllowancePerTurn, 5);
});

t('mutating the object returned by getConfig().raw does not affect the next getConfig call', () => {
  const dir = project(Object.assign({}, BASE, { gatedTools: ['Read'] }));
  const first = cfg.getConfig(dir);
  assert.throws(() => { first.raw.gatedTools.push('Mutated'); }, TypeError);
  assert.throws(() => { first.raw.enabled = false; }, TypeError);

  const second = cfg.getConfig(dir);
  assert.strictEqual(second.enabled, true);
  assert.deepStrictEqual(second.raw.gatedTools, ['Read']);
});

t('two different project dirs do not share cache entries', () => {
  const dirA = project(Object.assign({}, BASE, { enabled: true }));
  const dirB = project(Object.assign({}, BASE, { enabled: false }));
  assert.strictEqual(cfg.getConfig(dirA).enabled, true);
  assert.strictEqual(cfg.getConfig(dirB).enabled, false);
  assert.strictEqual(cfg.getConfig(dirA).enabled, true); // dirB's read didn't clobber dirA's
});

t('a missing config file is not negatively cached', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-nocfg-'));
  assert.strictEqual(cfg.getConfig(dir).enabled, false); // no .optimus/config.json yet

  fs.mkdirSync(path.join(dir, '.optimus'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.optimus', 'config.json'), JSON.stringify(BASE));

  assert.strictEqual(cfg.getConfig(dir).enabled, true);
});

// --- writeFileAtomicRefusingSymlink -------------------------------------
t('writes a normal file atomically in a writable directory', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-write-'));
  const target = path.join(dir, 'out.json');
  cfg.writeFileAtomicRefusingSymlink(target, 'hello');
  assert.strictEqual(fs.readFileSync(target, 'utf8'), 'hello');
  // no leftover tmp file
  assert.deepStrictEqual(fs.readdirSync(dir), ['out.json']);
});
t('refuses to write through a pre-existing symlink at the target', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-write-'));
  const real = path.join(dir, 'real.json');
  const link = path.join(dir, 'link.json');
  fs.writeFileSync(real, 'original');
  fs.symlinkSync(real, link);
  assert.throws(
    () => cfg.writeFileAtomicRefusingSymlink(link, 'new'),
    /refusing to write through a symlink/
  );
  assert.strictEqual(fs.readFileSync(real, 'utf8'), 'original'); // untouched
});
t('a permission-denied directory raises a clear Optimus error, not a raw EPERM/EACCES', () => {
  if (process.getuid && process.getuid() === 0) return; // root bypasses dir perms; skip
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'optimus-write-'));
  const target = path.join(dir, 'out.json');
  fs.chmodSync(dir, 0o500); // read+execute only, no write
  try {
    assert.throws(
      () => cfg.writeFileAtomicRefusingSymlink(target, 'new'),
      (e) => e instanceof Error && /Optimus: cannot write to/.test(e.message) && /not writable/.test(e.message)
    );
  } finally {
    fs.chmodSync(dir, 0o700); // restore so the test runner can clean up
  }
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
