# Optimus Cursor Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Optimus's orchestrator-enforcement policy to Cursor by extracting a host-agnostic policy core, probing Cursor's two undocumented hook behaviours empirically, and then building a thin Cursor adapter plus a rules-based reinforcement surface — without changing any Claude Code behaviour.

**Architecture:** Policy (which tools are work tools, what counts as an expensive model, the shell-bypass patterns, the order of checks, the ledger event names) moves into one pure module `hooks/optimus-core.js` with no I/O. `hooks/optimus-gate.js` becomes a thin Claude Code adapter over it; `hooks/optimus-gate-cursor.js` becomes a thin Cursor adapter over the same core. `hooks/optimus-config.js` and `hooks/optimus-ledger.js` are imported unmodified by both. Cursor's missing per-turn injection point is replaced by a one-shot `sessionStart` hook plus an `alwaysApply` `.mdc` rule, both sourced from a single text file so they cannot drift.

**Tech Stack:** Node.js (CommonJS, zero dependencies, no `package.json`), bash test harnesses, JSON fixtures, Claude Code plugin hooks, Cursor hooks + rules.

**Spec:** [docs/cursor-support-spec.md](../../cursor-support-spec.md)

## Global Constraints

- **Zero dependencies, zero build step.** No `package.json` exists and none is to be added. Everything is CommonJS (`'use strict';` + `require`), runnable as `node <file>`.
- **Every hook fails OPEN.** JSON parse errors, config read errors, and any uncaught exception must result in allow. Verbatim from `hooks/optimus-gate.js`: "a bug in this hook must never wedge a session."
- **The subagent exemption stays first.** Verbatim from the existing gate header: getting this order wrong "blocks every worker Optimus dispatches and inverts the entire point of the plugin."
- **`hooks/optimus-config.js` and `hooks/optimus-ledger.js` are NOT to be modified** by any task in this plan. Both are already host-agnostic. If a task appears to need a change there, stop and raise it.
- **The ledger is append-only.** Never read-modify-write `.optimus/state/events.jsonl`. Rotation stats, never reads.
- **Privacy:** never log prompts, file paths, file contents, or full shell commands to the ledger. Only reduced fields (`cmd_head` = first token, word chars only, ≤32 chars).
- **Ledger event names are identical across hosts:** `dispatch_allowed`, `dispatch_denied`, `work_tool_denied`, `bash_nudge`. `bash_nudge` keeps its Claude-Code-era name on Cursor too, so `bin/optimus-stats` needs no host branching.
- **Claude Code behaviour must not change.** `tests/run-gate-tests.sh`, `tests/run-ledger-tests.sh` and `tests/run-stats-tests.sh` must pass unmodified in content-of-assertions terms (Task 2 only *adds* assertions, never relaxes one).
- **Cursor hook output shape:** allow is `{"permission":"allow"}`; deny is `{"permission":"deny","user_message":"…","agent_message":"…"}`. Always `process.exit(0)`. Exit code 2 means deny on Cursor — never exit 2.
- **Maintainer decisions locked for this plan** (spec Section 9 left these open):
  - (a) **Probe-first.** No Cursor adapter code is written before Task 4's findings are recorded.
  - (b) **Model-conditional enforcement: implemented as a `config.modelConditional` flag, default OFF.** Cursor ships role-based parity with Claude Code out of the box.
  - Cursor's **`Delete` tool IS a work tool** (denied in the orchestrator). Inert on Claude Code, which has no such tool.
  - `cursor/optimus.mdc` uses **generic model-tier wording** ("cheap/fast model", "stronger model"), not `haiku`/`sonnet`, because Cursor users may have non-Anthropic models configured.

---

## File Structure

**New files**

| Path | Responsibility |
|---|---|
| `hooks/optimus-core.js` | Pure policy: normalized tool vocabulary, `WORK_TOOLS`, shell-bypass patterns, `decide()`, `ledgerEventFor()`, `cmdHead()`. No I/O, no `process.exit`. |
| `hooks/optimus-gate-cursor.js` | Cursor `preToolUse` adapter. Parses Cursor stdin, normalizes tool name + input, determines `isSubagent`, calls `decide()`, emits Cursor JSON, writes the ledger. |
| `hooks/optimus-session-cursor.js` | Cursor `sessionStart` adapter. Emits `{"additional_context": …}` built from `cursor/optimus.mdc` with its frontmatter stripped. |
| `hooks/optimus-subagent-cursor.js` | Only built if Task 4 lands on the sidecar fallback. `subagentStart`/`subagentStop` adapter maintaining `.optimus/state/active-subagents.json`. |
| `cursor/optimus.mdc` | `alwaysApply: true` rule template, and the SINGLE source of the Cursor reminder text — `optimus-session-cursor.js` reads it and strips the frontmatter, so the rule and the one-shot injection cannot drift. |
| `cursor/hooks.json` | Cursor hook registration **template**, rendered by `optimus-cli install cursor`. `__OPTIMUS_ROOT__` placeholder. |
| `cursor/probe/*` | Probe kit for Task 3/4 (logger hook, plugin-root prober, test subagent, run procedure). |
| `bin/optimus-probe-report` | Reads a probe log and prints the Section 5.1/5.2 analysis deterministically. |
| `docs/cursor-probe-findings.md` | Written by the human in Task 4. The gate for Tasks 5–8. |
| `tests/core-tests.js`, `tests/run-core-tests.sh` | Direct unit tests of `decide()`/`ledgerEventFor()`. |
| `tests/fixtures/cursor/*.json` | Captured-shape Cursor `preToolUse` payloads. |
| `tests/run-gate-cursor-tests.sh` | Shape tests for the Cursor adapter. |
| `tests/run-install-tests.sh` | Tests for `optimus-cli install cursor`. |

**Modified files**

| Path | Change |
|---|---|
| `hooks/optimus-gate.js` | Becomes a thin adapter over `optimus-core.js`. Deny message wording unchanged, byte for byte. |
| `hooks/optimus-reinforce.js` | Untouched in Tasks 1–8; Task 9 only touches its header comment if it references moved code. |
| `bin/optimus-cli` | Adds `install cursor`; project-dir resolution gains `CURSOR_PROJECT_DIR` as first choice. |
| `tests/run-gate-tests.sh` | Gains deny-message substring assertions (additive only). |
| `README.md` | New Cursor section, updated architecture tree, updated limitations. |
| `.claude-plugin/plugin.json` | Version bump to `0.3.0`. |

**Untouched, by constraint:** `hooks/optimus-config.js`, `hooks/optimus-ledger.js`, `hooks/hooks.json`, `commands/*.md`, `bin/optimus-stats`.

---

## Task 1: Extract the host-agnostic policy core

**Files:**
- Create: `hooks/optimus-core.js`
- Create: `tests/core-tests.js`
- Create: `tests/run-core-tests.sh`

**Interfaces:**
- Consumes: `WORK_TOOLS` and `EXPENSIVE_MODEL_RE` from `hooks/optimus-config.js` (already exported there; do not redefine them).
- Produces, all from `hooks/optimus-core.js`:
  - `AGENT_DISPATCH: 'AGENT_DISPATCH'`, `SHELL: 'SHELL'` — the two normalized sentinel tool names.
  - `WORK_TOOLS: Set<string>` — config's base set plus `'Delete'`.
  - `REASON: {NO_MODEL_SET, EXPENSIVE_MODEL_DISPATCH, WORK_TOOL_IN_ORCHESTRATOR, SHELL_READ_BYPASS}` — stable string codes.
  - `decide({tool, toolInput, isSubagent, sessionModel, config}) -> {allow: boolean, reason: string|null, tool?: string, model?: string}`
  - `ledgerEventFor({tool, toolInput, decision}) -> {ev: string, …fields}|null` — the event body minus `session_id`/`tool_use_id`, which each adapter adds.
  - `cmdHead(command) -> string`
  - `isReadBypassCommand(command) -> boolean`
- **Normalized `toolInput` contract:** `decide()`/`ledgerEventFor()` read only `toolInput.model`, `toolInput.subagent_type`, `toolInput.command`. Each adapter is responsible for presenting its host's raw input under those three key names.

- [ ] **Step 1: Write the failing test**

Create `tests/core-tests.js`:

```js
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
```

Create `tests/run-core-tests.sh`:

```bash
#!/usr/bin/env bash
# Direct unit tests for the host-agnostic policy core. No fixtures, no
# subprocess-per-case — see tests/core-tests.js for why.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "== Optimus core tests =="
exec node "$ROOT/tests/core-tests.js"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x tests/run-core-tests.sh
./tests/run-core-tests.sh
```

Expected: FAIL — `Cannot find module '.../hooks/optimus-core.js'`.

- [ ] **Step 3: Write the implementation**

Create `hooks/optimus-core.js`:

```js
'use strict';

/**
 * Host-agnostic policy core.
 *
 * This module is PURE: no filesystem access, no stdin/stdout, no
 * process.exit, no knowledge of any host's payload shape. Every host
 * adapter (hooks/optimus-gate.js for Claude Code,
 * hooks/optimus-gate-cursor.js for Cursor) does its own parsing and
 * emitting and calls decide() in between.
 *
 * Everything that is *policy* lives here and nowhere else:
 *   - which tools count as work the orchestrator must delegate
 *   - what makes a model "expensive"
 *   - which shell commands are treated as a read-in-disguise
 *   - the ORDER the checks run in
 *   - the ledger event names and field sets
 * Duplicating any of that into an adapter is the specific failure this
 * module exists to prevent: two hosts silently enforcing different
 * policy.
 *
 * The check order below is inherited verbatim from the pre-extraction
 * hooks/optimus-gate.js and must not be rearranged:
 *   1. Subagent exemption — MUST be first. A subagent's own tool calls
 *      are allowed unconditionally. Getting this wrong blocks every
 *      worker Optimus dispatches and inverts the point of the plugin.
 *   2. Per-project activation.
 *   3. Optional model-conditional exemption (off by default).
 *   4. Dispatch must name a non-expensive model.
 *   5. Work tools denied.
 *   6. Shell read-bypass speed bump (explicitly NOT a security
 *      boundary — see README).
 *
 * The kill switch is NOT checked here. It is host plumbing: each adapter
 * checks isKillSwitchActive() before it ever builds a decide() call, so
 * that a disabled Optimus does no config I/O at all.
 */

const path = require('path');
const {
  WORK_TOOLS: WORK_TOOLS_BASE,
  EXPENSIVE_MODEL_RE,
} = require(path.join(__dirname, 'optimus-config.js'));

/**
 * Normalized tool vocabulary.
 *
 * Claude Code's own tool names ARE the normalized names for work tools.
 * That is deliberate rather than accidental: it means the Claude Code
 * adapter needs no mapping table for the common case, and the diff
 * introduced by this extraction stays small enough to review against the
 * original file. Two sentinels exist because the hosts disagree on
 * naming for the two tools whose *semantics* Optimus cares about:
 *
 *   AGENT_DISPATCH  <- Claude Code "Agent"  / Cursor "Task"
 *   SHELL           <- Claude Code "Bash"   / Cursor "Shell"
 */
const AGENT_DISPATCH = 'AGENT_DISPATCH';
const SHELL = 'SHELL';

/**
 * Work tools: optimus-config.js's set, plus Cursor's Delete.
 *
 * Cursor exposes a distinct Delete tool with no Claude Code equivalent.
 * Maintainer decision (spec Section 4): it is a work tool — the
 * orchestrator delegates file deletion like any other file mutation.
 * Adding it here rather than in the Cursor adapter keeps the set in one
 * place; it is inert on Claude Code, which has no tool by that name.
 */
const WORK_TOOLS = new Set([...WORK_TOOLS_BASE, 'Delete']);

/** Max length of the cmd_head field logged for a shell nudge. */
const CMD_HEAD_MAX_LEN = 32;

/**
 * Best-effort patterns for "this shell command is really just a file
 * read/search, dressed up to dodge the work-tool denial". Deliberately
 * narrow and conservative — false negatives are expected and accepted
 * (see README); the goal is raising the cost of the *casual, unprompted*
 * bypass observed during testing (a model's first instinct for "read a
 * file" was `cat`), not building a wall.
 */
const SHELL_READ_PATTERNS = [
  /^\s*cat\s+[^|>&;`$]+$/,
  /^\s*head\s+/,
  /^\s*tail\s+/,
  /^\s*(rg|grep)\s+(?!.*(--help|--version))[^|>&;`$]*$/,
  /^\s*find\s+\S+\s+.*-name\s/,
  /^\s*ls\s+/,
  /^\s*less\s+/,
  /^\s*more\s+\S/,
  /^\s*sed\s+-n\s/,
];

/** Stable machine-readable deny codes. Adapters render their own wording. */
const REASON = {
  NO_MODEL_SET: 'no-model-set',
  EXPENSIVE_MODEL_DISPATCH: 'expensive-model-dispatch',
  WORK_TOOL_IN_ORCHESTRATOR: 'work-tool-in-orchestrator',
  SHELL_READ_BYPASS: 'shell-read-bypass',
};

function isReadBypassCommand(command) {
  const cmd = typeof command === 'string' ? command : '';
  if (cmd === '') return false;
  return SHELL_READ_PATTERNS.some((pattern) => pattern.test(cmd));
}

/**
 * Reduces a shell command down to a privacy-safe fragment for the
 * ledger: the first whitespace-delimited token, stripped to word
 * characters only, truncated to CMD_HEAD_MAX_LEN. The full command is
 * never handed to the ledger — only this.
 */
function cmdHead(command) {
  const first = String(command || '').trim().split(/\s+/)[0] || '';
  return first.replace(/[^\w]/g, '').slice(0, CMD_HEAD_MAX_LEN);
}

const ALLOW = { allow: true, reason: null };

/**
 * @param {object}        input
 * @param {string}        input.tool         normalized tool name
 * @param {object}        input.toolInput    normalized input; only .model,
 *                                           .subagent_type and .command are read
 * @param {boolean}       input.isSubagent   true if this call originates inside a
 *                                           dispatched subagent. How an adapter
 *                                           determines this is host-specific.
 * @param {string|null}   input.sessionModel the live session model if the host
 *                                           provides one (Cursor does, Claude Code
 *                                           does not — pass null). Only consulted
 *                                           when config.modelConditional is true.
 * @param {{enabled: boolean, modelConditional?: boolean}} input.config
 * @returns {{allow: boolean, reason: string|null, tool?: string, model?: string}}
 */
function decide({ tool, toolInput, isSubagent, sessionModel, config }) {
  const cfg = config || {};
  const input = toolInput || {};

  // 1 — subagent exemption. Load-bearing; must stay first.
  if (isSubagent) return ALLOW;

  // 2 — per-project activation.
  if (!cfg.enabled) return ALLOW;

  // 3 — optional model-conditional exemption. Off unless a project opts
  // in, so both hosts enforce on the same (role-based) basis by default.
  // A missing/unknown sessionModel deliberately enforces rather than
  // exempts: "we could not tell" must not become "you are exempt".
  if (
    cfg.modelConditional &&
    typeof sessionModel === 'string' &&
    sessionModel.trim() !== '' &&
    !EXPENSIVE_MODEL_RE.test(sessionModel)
  ) {
    return ALLOW;
  }

  // 4 — dispatch must name a model, and it must not be the expensive tier.
  if (tool === AGENT_DISPATCH) {
    const model = input.model;
    if (typeof model !== 'string' || model.trim() === '') {
      return { allow: false, reason: REASON.NO_MODEL_SET };
    }
    if (EXPENSIVE_MODEL_RE.test(model)) {
      return { allow: false, reason: REASON.EXPENSIVE_MODEL_DISPATCH, model: model };
    }
    return ALLOW;
  }

  // 5 — work tools denied in the orchestrator while Optimus is active.
  if (WORK_TOOLS.has(tool)) {
    return { allow: false, reason: REASON.WORK_TOOL_IN_ORCHESTRATOR, tool: tool };
  }

  // 6 — shell: best-effort speed bump only, not a security boundary.
  if (tool === SHELL && isReadBypassCommand(input.command)) {
    return { allow: false, reason: REASON.SHELL_READ_BYPASS };
  }

  return ALLOW;
}

/**
 * Maps a decision onto the ledger event body for it, or null when the
 * decision is of no interest to the ledger (an ordinary allow).
 *
 * Lives here rather than in each adapter so that both hosts write
 * byte-identical event names and field sets — that is what lets
 * bin/optimus-stats read either host's ledger with zero host branching
 * (spec Section 1.6). `session_id` and `tool_use_id` are NOT set here;
 * each adapter adds them from its own payload's field names (Cursor
 * carries conversation_id where Claude Code carries session_id).
 */
function ledgerEventFor({ tool, toolInput, decision }) {
  const input = toolInput || {};
  const dec = decision || {};

  if (tool === AGENT_DISPATCH) {
    if (dec.allow) {
      return {
        ev: 'dispatch_allowed',
        model: input.model,
        agent_type: input.subagent_type,
      };
    }
    if (dec.reason === REASON.NO_MODEL_SET) {
      return { ev: 'dispatch_denied', reason: 'no_model' };
    }
    if (dec.reason === REASON.EXPENSIVE_MODEL_DISPATCH) {
      return { ev: 'dispatch_denied', reason: 'expensive_model', model: input.model };
    }
    return null;
  }

  if (dec.reason === REASON.WORK_TOOL_IN_ORCHESTRATOR) {
    return { ev: 'work_tool_denied', tool: tool };
  }
  if (dec.reason === REASON.SHELL_READ_BYPASS) {
    return { ev: 'bash_nudge', cmd_head: cmdHead(input.command) };
  }

  return null;
}

module.exports = {
  decide,
  ledgerEventFor,
  cmdHead,
  isReadBypassCommand,
  AGENT_DISPATCH,
  SHELL,
  WORK_TOOLS,
  REASON,
  SHELL_READ_PATTERNS,
  CMD_HEAD_MAX_LEN,
  EXPENSIVE_MODEL_RE,
};
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
./tests/run-core-tests.sh
```

Expected: every line `PASS:`, final line `== 34 passed, 0 failed ==` (the count is whatever the file above produces — the requirement is `0 failed` and a non-zero pass count).

- [ ] **Step 5: Confirm nothing else broke yet**

```bash
./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh && ./tests/run-stats-tests.sh
```

Expected: all three still pass. Nothing consumes the core yet, so this is purely a "the new file did not break `require` graphs" check.

- [ ] **Step 6: Commit**

```bash
git add hooks/optimus-core.js tests/core-tests.js tests/run-core-tests.sh
git commit -m "feat: extract host-agnostic policy core with direct unit tests"
```

---

## Task 2: Reduce `optimus-gate.js` to a Claude Code adapter

**Files:**
- Modify: `hooks/optimus-gate.js` (full rewrite — 214 lines becomes ~150)
- Modify: `tests/run-gate-tests.sh` (add a `check_msg` helper and five message assertions)

**Interfaces:**
- Consumes: `decide`, `ledgerEventFor`, `AGENT_DISPATCH`, `SHELL`, `REASON` from `hooks/optimus-core.js` (Task 1); `isKillSwitchActive`, `getConfig` from `hooks/optimus-config.js`; `recordEvent` from `hooks/optimus-ledger.js`.
- Produces: no new exports — this file stays an executable hook, not a module.

**Why the deny wording moves into the adapter, not the core:** the two hosts name the same tools differently (`Agent` vs `Task`, `Bash` vs `Shell`) and Claude Code's message names concrete model aliases while Cursor's must not (locked decision). A shared message would have to be templated into uselessness. What *is* shared is the reason code and the ledger event, both from the core.

**The subagent short-circuit is deliberately in both places.** The adapter returns allow on a subagent payload *before* reading config, exactly as the pre-extraction gate did, so a subagent's tool calls still cost zero config I/O — subagents make most of the tool calls in an Optimus session. `decide()` also checks `isSubagent` first. That duplication is defence in depth on the one check whose failure mode is total deadlock; do not "clean it up".

- [ ] **Step 1: Write the failing test**

In `tests/run-gate-tests.sh`, add this helper immediately after the existing `check()` function:

```bash
check_msg() {
  local name="$1" fixture="$2" cwd="$3" needle="$4"
  local payload out
  payload="$(sed "s#__PROJECT__#$cwd#" "$FIXTURES/$fixture")"
  out="$(node "$GATE" <<<"$payload")"
  if echo "$out" | grep -qF "$needle"; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name (message did not contain: $needle) -- output: $out"
    fail=$((fail+1))
  fi
}
```

Then, immediately before the `-- kill switch:` block, add:

```bash
echo ""
echo "-- deny message wording (guards user-facing text against refactors) --"
check_msg "msg: work tool names the tool and the Agent tool" main-read.json "$PROJECT" \
  'the Read tool is blocked in the orchestrator session'
check_msg "msg: work tool points at /optimus off" main-read.json "$PROJECT" \
  'Run `/optimus off` if you'
check_msg "msg: no-model names tool_input.model" agent-no-model.json "$PROJECT" \
  'has no tool_input.model set'
check_msg "msg: opus dispatch echoes the model back" agent-opus-model.json "$PROJECT" \
  'the expensive tier'
check_msg "msg: bash nudge says best-effort, not a boundary" main-bash-cat.json "$PROJECT" \
  'best-effort'
```

- [ ] **Step 2: Run the test to verify it passes against the CURRENT gate**

```bash
./tests/run-gate-tests.sh
```

Expected: PASS on all five new assertions **before** the rewrite. This is the point of writing them first — they capture today's wording so the rewrite in Step 3 is provably wording-preserving. If any of the five fails here, the needle text is wrong; fix the needle against the real current output, not the gate.

- [ ] **Step 3: Rewrite `hooks/optimus-gate.js`**

Replace the entire file with:

```js
#!/usr/bin/env node
'use strict';

/**
 * Claude Code PreToolUse adapter.
 *
 * This file is deliberately thin. It knows exactly three things:
 *   - how to read Claude Code's PreToolUse stdin payload
 *   - how to translate Claude Code's tool names into the core's
 *     normalized vocabulary
 *   - how to emit Claude Code's hookSpecificOutput JSON
 * Every actual policy question — which tools are work tools, what makes
 * a model expensive, which shell commands are reads in disguise, the
 * order the checks run in, what gets written to the ledger — lives in
 * hooks/optimus-core.js and is shared with the Cursor adapter.
 *
 * Preserved from the pre-extraction version, all load-bearing:
 *   - The kill switch (OPTIMUS_DISABLED) is checked first and always wins.
 *   - The subagent exemption (agent_id/agent_type) short-circuits BEFORE
 *     any config read. session_id cannot be used for this — it is
 *     identical for the main session and every subagent it spawns.
 *   - Fails OPEN on any internal error (malformed payload, config read
 *     failure, uncaught throw): a bug in this hook must never wedge a
 *     session.
 *   - The user-facing deny wording is unchanged, byte for byte, and is
 *     pinned by check_msg assertions in tests/run-gate-tests.sh.
 */

const path = require('path');
const { isKillSwitchActive, getConfig } = require(
  path.join(__dirname, 'optimus-config.js')
);
const { recordEvent } = require(path.join(__dirname, 'optimus-ledger.js'));
const {
  decide,
  ledgerEventFor,
  AGENT_DISPATCH,
  SHELL,
  REASON,
} = require(path.join(__dirname, 'optimus-core.js'));

/** Claude Code tool name -> normalized core vocabulary. */
function normalizeTool(toolName) {
  if (toolName === 'Agent') return AGENT_DISPATCH;
  if (toolName === 'Bash') return SHELL;
  return toolName;
}

/** Renders the Claude-Code-specific deny text for a core reason code. */
function denyMessage(decision, payload) {
  const toolInput = payload.tool_input || {};
  switch (decision.reason) {
    case REASON.NO_MODEL_SET:
      return (
        'Optimus: this Agent dispatch has no tool_input.model set, which means it would ' +
        "silently inherit the orchestrator's own (expensive) model instead of running cheaper. " +
        'Re-dispatch and pass model explicitly: use "haiku" for simple/mechanical work ' +
        '(file lookups, boilerplate edits, running a command and reporting its output), ' +
        'or "sonnet" for anything that needs real judgement (ambiguous requirements, design ' +
        'tradeoffs, non-trivial debugging). Never omit model, and never dispatch on opus.'
      );
    case REASON.EXPENSIVE_MODEL_DISPATCH:
      return (
        'Optimus: this Agent dispatch names model="' +
        decision.model +
        '", the expensive tier — dispatching a subagent on the same expensive model as the ' +
        'orchestrator defeats the point of delegating. Re-dispatch with model="haiku" for ' +
        'simple/mechanical work, or model="sonnet" for anything needing real judgement.'
      );
    case REASON.WORK_TOOL_IN_ORCHESTRATOR:
      return (
        'Optimus: the ' +
        decision.tool +
        ' tool is blocked in the orchestrator session while Optimus is active for this project. ' +
        'Delegate this work with the Agent tool instead: pass model="haiku" for simple/mechanical ' +
        'work, or model="sonnet" for anything needing real judgement. Run `/optimus off` if you ' +
        'need to work in this session directly.'
      );
    case REASON.SHELL_READ_BYPASS:
      return (
        'Optimus: this Bash command ("' +
        String(toolInput.command || '').slice(0, 160) +
        '") looks like a plain file read or search, which should go through a delegated ' +
        'subagent instead of the orchestrator running it directly. Use the Agent tool ' +
        '(model="haiku" is usually enough for a simple lookup). Note: this is a best-effort ' +
        'pattern match, not a hard boundary — git/build/test/flash and other orchestration ' +
        'commands are never blocked.'
      );
    default:
      return 'Optimus: blocked.';
  }
}

function allow() {
  process.exit(0);
}

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
}

function main(raw) {
  if (isKillSwitchActive()) return allow();

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    return allow(); // never fail closed on our own parsing bug
  }
  if (!payload || typeof payload !== 'object') return allow();

  // Subagent exemption. Short-circuits before any config I/O, and must
  // stay first — see the header comment.
  if (payload.agent_id || payload.agent_type) return allow();

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return allow(); // a bug in our own config resolution must not wedge the session
  }
  if (!cfg.enabled) return allow();

  const tool = normalizeTool(payload.tool_name);
  const toolInput = payload.tool_input || {};

  // Claude Code payloads carry no model field, and the one indirect
  // route (polling the transcript) races this hook's own invocation —
  // see README "Known limitations". Always null here.
  const decision = decide({
    tool: tool,
    toolInput: toolInput,
    isSubagent: false,
    sessionModel: null,
    config: cfg.raw && cfg.raw.modelConditional
      ? { enabled: true, modelConditional: true }
      : { enabled: true },
  });

  const event = ledgerEventFor({ tool: tool, toolInput: toolInput, decision: decision });
  if (event) {
    recordEvent(
      payload.cwd,
      Object.assign({ session_id: payload.session_id, tool_use_id: payload.tool_use_id }, event)
    );
  }

  if (decision.allow) return allow();
  return deny(denyMessage(decision, payload));
}

let raw = '';
process.stdin.on('data', (d) => {
  raw += d;
});
process.stdin.on('end', () => {
  try {
    main(raw);
  } catch (e) {
    // absolute last resort — a crash in the hook must never block the tool call
    process.exit(0);
  }
});
```

Two intentional differences from the pre-extraction file, both benign:

1. `work_tool_denied` events now carry `tool_use_id` (the old code omitted it there while setting it on dispatch events). Extra field, same event name — `bin/optimus-stats` reads by `ev`, so this is additive.
2. `bash_nudge` events now carry `tool_use_id` for the same reason.

If `tests/run-ledger-tests.sh` asserts exact-shape equality on those two events rather than field presence, prefer updating the ledger test's expectation over reintroducing the asymmetry — but read that file before deciding, and if it turns out the asymmetry is asserted deliberately, drop `tool_use_id` for those two events by building the ledger call as `Object.assign({session_id: payload.session_id}, event)` and adding `tool_use_id` only in the `AGENT_DISPATCH` branch.

- [ ] **Step 4: Run every suite to verify the refactor changed nothing**

```bash
./tests/run-core-tests.sh && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh && ./tests/run-stats-tests.sh
```

Expected: all four pass, `0 failed` in each. `run-gate-tests.sh` passing unmodified (except for the additive assertions from Step 1) **is** the regression proof that the extraction preserved Claude Code behaviour.

- [ ] **Step 5: Commit**

```bash
git add hooks/optimus-gate.js tests/run-gate-tests.sh
git commit -m "refactor: reduce optimus-gate.js to a thin Claude Code adapter over the core"
```

---

## Task 3: Build the Cursor probe kit and its deterministic analyser

**Files:**
- Create: `cursor/probe/probe.js`
- Create: `cursor/probe/probe-root.js`
- Create: `cursor/probe/hooks.probe.json`
- Create: `cursor/probe/agents/file-reader.md`
- Create: `cursor/probe/probe-target.txt`
- Create: `cursor/probe/README.md`
- Create: `bin/optimus-probe-report`
- Create: `tests/fixtures/probe/distinguishable.log`
- Create: `tests/fixtures/probe/indistinguishable.log`
- Create: `tests/run-probe-report-tests.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks. This task is independent of Tasks 1–2 and could run in parallel with them.
- Produces: `bin/optimus-probe-report <path-to-probe.log>` — prints the Section 5.1/5.2 analysis and exits 0 on a readable log, 1 on an unreadable/empty one. Task 4 pastes its output into `docs/cursor-probe-findings.md`.

**Why an analyser script and not "read the log by eye":** the Unknown-1 decision matrix turns on "is any key present on the subagent's entry that is absent on the main agent's, or vice versa" and "do `conversation_id`/`generation_id`/`model` differ". Eyeballing two 15-field JSON objects is exactly where a wrong answer gets recorded confidently, and a wrong answer here costs the whole adapter.

- [ ] **Step 1: Write the failing test**

Create `tests/fixtures/probe/distinguishable.log` (two lines, no trailing blank line issues — each line is one JSON object):

```
{"loggedAt":"2026-09-09T10:00:00.000Z","envSnapshot":{"CURSOR_PROJECT_DIR":"/tmp/scratch","CURSOR_TRANSCRIPT_PATH":"/tmp/t.jsonl","CURSOR_PLUGIN_ROOT":null,"PLUGIN_ROOT":null,"CLAUDE_PROJECT_DIR":"/tmp/scratch"},"dirname":"/tmp/scratch/.cursor/hooks","argv":["node","/tmp/scratch/.cursor/hooks/probe.js"],"stdin":{"hook_event_name":"preToolUse","conversation_id":"conv-1","generation_id":"gen-1","model":"Claude Opus 5","model_id":"claude-opus-5","tool_name":"Read","tool_input":{"path":"probe-target.txt"},"tool_use_id":"tu-1","cwd":"/tmp/scratch"}}
{"loggedAt":"2026-09-09T10:00:05.000Z","envSnapshot":{"CURSOR_PROJECT_DIR":"/tmp/scratch","CURSOR_TRANSCRIPT_PATH":"/tmp/t.jsonl","CURSOR_PLUGIN_ROOT":null,"PLUGIN_ROOT":null,"CLAUDE_PROJECT_DIR":"/tmp/scratch"},"dirname":"/tmp/scratch/.cursor/hooks","argv":["node","/tmp/scratch/.cursor/hooks/probe.js"],"stdin":{"hook_event_name":"preToolUse","conversation_id":"conv-1","generation_id":"gen-2","model":"Claude Sonnet 5","model_id":"claude-sonnet-5","tool_name":"Read","tool_input":{"path":"probe-target.txt"},"tool_use_id":"tu-2","cwd":"/tmp/scratch","subagent_id":"sub-1"}}
```

Create `tests/fixtures/probe/indistinguishable.log`:

```
{"loggedAt":"2026-09-09T11:00:00.000Z","envSnapshot":{"CURSOR_PROJECT_DIR":"/tmp/scratch","CURSOR_TRANSCRIPT_PATH":"/tmp/t.jsonl","CURSOR_PLUGIN_ROOT":null,"PLUGIN_ROOT":null,"CLAUDE_PROJECT_DIR":"/tmp/scratch"},"dirname":"/tmp/scratch/.cursor/hooks","argv":["node","/tmp/scratch/.cursor/hooks/probe.js"],"stdin":{"hook_event_name":"preToolUse","conversation_id":"conv-9","generation_id":"gen-1","model":"Claude Opus 5","model_id":"claude-opus-5","tool_name":"Read","tool_input":{"path":"a.txt"},"tool_use_id":"tu-1","cwd":"/tmp/scratch"}}
{"loggedAt":"2026-09-09T11:00:05.000Z","envSnapshot":{"CURSOR_PROJECT_DIR":"/tmp/scratch","CURSOR_TRANSCRIPT_PATH":"/tmp/t.jsonl","CURSOR_PLUGIN_ROOT":null,"PLUGIN_ROOT":null,"CLAUDE_PROJECT_DIR":"/tmp/scratch"},"dirname":"/tmp/scratch/.cursor/hooks","argv":["node","/tmp/scratch/.cursor/hooks/probe.js"],"stdin":{"hook_event_name":"preToolUse","conversation_id":"conv-9","generation_id":"gen-1","model":"Claude Opus 5","model_id":"claude-opus-5","tool_name":"Read","tool_input":{"path":"a.txt"},"tool_use_id":"tu-2","cwd":"/tmp/scratch"}}
```

Create `tests/run-probe-report-tests.sh`:

```bash
#!/usr/bin/env bash
# Tests for bin/optimus-probe-report against synthetic probe logs.
# The real probe log can only be produced by a human driving Cursor
# (see cursor/probe/README.md); these fixtures stand in for the two
# outcomes that change the design, so the analyser itself is testable
# without a Cursor install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT/bin/optimus-probe-report"
FIX="$ROOT/tests/fixtures/probe"

pass=0
fail=0

expect_contains() {
  local name="$1" logfile="$2" needle="$3"
  local out
  out="$(node "$REPORT" "$FIX/$logfile")"
  if echo "$out" | grep -qF "$needle"; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name (missing: $needle)"
    echo "---- output ----"
    echo "$out"
    fail=$((fail+1))
  fi
}

echo "== Optimus probe-report tests =="
expect_contains "distinguishable: flags the extra key"    distinguishable.log   "CANDIDATE SUBAGENT FIELD: subagent_id"
expect_contains "distinguishable: verdict row 1"          distinguishable.log   "UNKNOWN 1 VERDICT: distinguishing field present"
expect_contains "distinguishable: reports model drift"    distinguishable.log   "model differs across preToolUse entries"
expect_contains "indistinguishable: no candidate keys"    indistinguishable.log "CANDIDATE SUBAGENT FIELD: (none)"
expect_contains "indistinguishable: verdict row 2"        indistinguishable.log "UNKNOWN 1 VERDICT: no distinguishing field"
expect_contains "unknown 2: reports env resolution"       distinguishable.log   "CURSOR_PLUGIN_ROOT : (unset/empty)"
expect_contains "unknown 2: verdict"                      distinguishable.log   "UNKNOWN 2 VERDICT: no plugin-root variable resolved"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x tests/run-probe-report-tests.sh
./tests/run-probe-report-tests.sh
```

Expected: FAIL — `Cannot find module '.../bin/optimus-probe-report'`.

- [ ] **Step 3: Write `bin/optimus-probe-report`**

```js
#!/usr/bin/env node
'use strict';

/**
 * Deterministic analyser for a Cursor probe log (see
 * cursor/probe/README.md for how the log is produced).
 *
 * Answers exactly the two questions the Cursor port is blocked on:
 *   Unknown 1 — can a preToolUse payload tell a subagent's own tool call
 *               apart from the orchestrator's?
 *   Unknown 2 — does any plugin-root variable resolve inside a hook?
 *
 * This exists instead of "read the log by eye" because the Unknown-1
 * decision matrix turns on set differences between two ~15-key objects,
 * which is precisely where an eyeballed answer gets recorded with
 * unwarranted confidence.
 */

const fs = require('fs');

const SUBAGENT_HINT_RE = /agent|subagent|parent|worker|child/i;
const CORRELATION_KEYS = ['conversation_id', 'generation_id', 'model', 'model_id', 'tool_use_id', 'cwd'];
const ROOT_VARS = ['CURSOR_PLUGIN_ROOT', 'PLUGIN_ROOT', 'CURSOR_PROJECT_DIR', 'CLAUDE_PROJECT_DIR'];

function die(msg) {
  console.error('optimus-probe-report: ' + msg);
  process.exit(1);
}

const file = process.argv[2];
if (!file) die('usage: optimus-probe-report <path-to-probe.log>');

let raw;
try {
  raw = fs.readFileSync(file, 'utf8');
} catch (e) {
  die('cannot read ' + file + ': ' + e.message);
}

const entries = [];
raw.split('\n').forEach((line, i) => {
  const trimmed = line.trim();
  if (trimmed === '') return;
  try {
    entries.push(JSON.parse(trimmed));
  } catch (e) {
    console.log('WARNING: line ' + (i + 1) + ' is not JSON, skipped');
  }
});

if (entries.length === 0) die('no parseable entries in ' + file);

const events = {};
for (const e of entries) {
  const name = (e.stdin && e.stdin.hook_event_name) || '(unknown)';
  events[name] = (events[name] || 0) + 1;
}

const preTool = entries.filter((e) => e.stdin && e.stdin.hook_event_name === 'preToolUse');

console.log('== Optimus Cursor probe report ==');
console.log('log file      : ' + file);
console.log('total entries : ' + entries.length);
console.log('events seen   : ' + Object.keys(events).map((k) => k + '=' + events[k]).join(', '));
console.log('preToolUse    : ' + preTool.length);
console.log('');

// ---- Unknown 1 --------------------------------------------------------
console.log('-- Unknown 1: subagent distinguishability --');

if (preTool.length === 0) {
  console.log('No preToolUse entries at all. Either the hook never fired or it is');
  console.log('registered on a different event. Re-check the hooks.json before');
  console.log('drawing any conclusion.');
  console.log('UNKNOWN 1 VERDICT: inconclusive - no preToolUse entries');
} else if (preTool.length === 1) {
  console.log('Only ONE preToolUse entry. If the procedure in cursor/probe/README.md');
  console.log('was followed (a main-agent read AND a subagent read), this is itself the');
  console.log('finding: subagent-internal tool calls do not fire preToolUse.');
  console.log('UNKNOWN 1 VERDICT: subagent tool calls appear not to fire preToolUse');
} else {
  const keySets = preTool.map((e) => Object.keys(e.stdin).sort());
  const union = [...new Set([].concat(...keySets))].sort();
  const intersection = union.filter((k) => keySets.every((ks) => ks.includes(k)));
  const variable = union.filter((k) => !intersection.includes(k));

  console.log('key union        : ' + union.join(', '));
  console.log('keys on every    : ' + intersection.join(', '));
  console.log('keys on some only: ' + (variable.length ? variable.join(', ') : '(none)'));

  const hinted = union.filter((k) => SUBAGENT_HINT_RE.test(k));
  const candidates = [...new Set(variable.concat(hinted))].sort();
  console.log('CANDIDATE SUBAGENT FIELD: ' + (candidates.length ? candidates.join(', ') : '(none)'));

  for (const k of CORRELATION_KEYS) {
    const values = [...new Set(preTool.map((e) => JSON.stringify(e.stdin[k])))];
    if (values.length > 1) {
      console.log('  ' + k + ' differs across preToolUse entries: ' + values.join(' | '));
    } else {
      console.log('  ' + k + ' identical across preToolUse entries: ' + values[0]);
    }
  }

  if (candidates.length) {
    console.log('UNKNOWN 1 VERDICT: distinguishing field present -> decision matrix row 1');
    console.log('  Build hooks/optimus-gate-cursor.js checking: ' + candidates.join(' || '));
    console.log('  Treat it as an unversioned, undocumented dependency: re-verify on');
    console.log('  every Cursor update.');
  } else {
    console.log('UNKNOWN 1 VERDICT: no distinguishing field -> decision matrix row 2');
    console.log('  Sidecar correlation via subagentStart/subagentStop is required, OR');
    console.log('  drop hard enforcement on Cursor and ship rules-only. Maintainer call.');
  }
}
console.log('');

// ---- Unknown 2 --------------------------------------------------------
console.log('-- Unknown 2: plugin root resolution --');
const withEnv = entries.filter((e) => e.envSnapshot);
if (withEnv.length === 0) {
  console.log('No entry carried an envSnapshot. Re-run with cursor/probe/probe-root.js.');
  console.log('UNKNOWN 2 VERDICT: inconclusive - no env data');
} else {
  const resolved = {};
  for (const name of ROOT_VARS) {
    const values = [...new Set(withEnv.map((e) => e.envSnapshot[name]).filter((v) => typeof v === 'string' && v !== ''))];
    resolved[name] = values;
    const pad = name + ' '.repeat(Math.max(0, 18 - name.length));
    console.log('  ' + pad + ' : ' + (values.length ? values.join(' | ') : '(unset/empty)'));
  }
  const dirnames = [...new Set(entries.map((e) => e.dirname).filter(Boolean))];
  console.log('  __dirname          : ' + (dirnames.length ? dirnames.join(' | ') : '(not recorded)'));

  const literals = entries
    .filter((e) => Array.isArray(e.argv))
    .filter((e) => e.argv.some((a) => typeof a === 'string' && a.indexOf('${') !== -1));
  if (literals.length) {
    console.log('  NOTE: an unexpanded ${...} reached argv - Cursor did NOT interpolate it.');
  }

  const usable = ['CURSOR_PLUGIN_ROOT', 'PLUGIN_ROOT'].filter((n) => resolved[n].length);
  if (usable.length) {
    console.log('UNKNOWN 2 VERDICT: usable plugin-root variable: ' + usable.join(', '));
    console.log('  cursor/hooks.json may reference it directly.');
  } else if (dirnames.length) {
    console.log('UNKNOWN 2 VERDICT: no plugin-root variable resolved, but __dirname did');
    console.log('  Render absolute paths at install time (optimus-cli install cursor).');
    console.log('  Cost: the generated .cursor/hooks.json is machine-specific.');
  } else {
    console.log('UNKNOWN 2 VERDICT: no plugin-root variable resolved');
    console.log('  Render absolute paths at install time (optimus-cli install cursor).');
  }
}
process.exit(0);
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/optimus-probe-report
./tests/run-probe-report-tests.sh
```

Expected: `== 7 passed, 0 failed ==`.

- [ ] **Step 5: Write the probe hook itself**

Create `cursor/probe/probe.js`:

```js
#!/usr/bin/env node
'use strict';

/**
 * Cursor hook payload logger. Always allows; logs one JSON line per
 * invocation to probe.log next to this file. Feed that log to
 * bin/optimus-probe-report.
 *
 * Deliberately dependency-free and defensive: this runs inside a real
 * Cursor session, and a crash here would make the probe itself the
 * thing under investigation.
 */

const fs = require('fs');
const path = require('path');

const LOG_PATH = path.join(__dirname, 'probe.log');

let raw = '';
process.stdin.on('data', (d) => {
  raw += d;
});
process.stdin.on('end', () => {
  let stdin;
  try {
    stdin = JSON.parse(raw);
  } catch (e) {
    stdin = { parseError: String(e), raw: raw.slice(0, 4000) };
  }
  const entry = {
    loggedAt: new Date().toISOString(),
    envSnapshot: {
      CURSOR_PLUGIN_ROOT: process.env.CURSOR_PLUGIN_ROOT || null,
      PLUGIN_ROOT: process.env.PLUGIN_ROOT || null,
      CURSOR_PROJECT_DIR: process.env.CURSOR_PROJECT_DIR || null,
      CURSOR_TRANSCRIPT_PATH: process.env.CURSOR_TRANSCRIPT_PATH || null,
      CURSOR_VERSION: process.env.CURSOR_VERSION || null,
      CLAUDE_PROJECT_DIR: process.env.CLAUDE_PROJECT_DIR || null,
    },
    dirname: __dirname,
    argv: process.argv,
    stdin: stdin,
  };
  try {
    fs.appendFileSync(LOG_PATH, JSON.stringify(entry) + '\n');
  } catch (e) {
    // logging failure must not block the tool call
  }
  process.stdout.write(JSON.stringify({ permission: 'allow' }));
  process.exit(0);
});
```

Create `cursor/probe/probe-root.js` — same file with two changes: `LOG_PATH` becomes `probe-root.log`, and it does not wait on stdin (it writes and exits immediately, so it also answers "does the hook process even start when the command string contains an unresolvable variable"):

```js
#!/usr/bin/env node
'use strict';

/**
 * Plugin-root prober (spec Unknown 2). Writes one entry and exits
 * without reading stdin — so it still produces a log line even when
 * invoked via a command string whose ${...} never expanded.
 */

const fs = require('fs');
const path = require('path');

const entry = {
  loggedAt: new Date().toISOString(),
  envSnapshot: {
    CURSOR_PLUGIN_ROOT: process.env.CURSOR_PLUGIN_ROOT || null,
    PLUGIN_ROOT: process.env.PLUGIN_ROOT || null,
    CURSOR_PROJECT_DIR: process.env.CURSOR_PROJECT_DIR || null,
    CURSOR_TRANSCRIPT_PATH: process.env.CURSOR_TRANSCRIPT_PATH || null,
    CLAUDE_PROJECT_DIR: process.env.CLAUDE_PROJECT_DIR || null,
  },
  dirname: __dirname,
  filename: __filename,
  argv: process.argv,
};

try {
  fs.appendFileSync(path.join(__dirname, 'probe-root.log'), JSON.stringify(entry) + '\n');
} catch (e) {
  // nothing to do
}
process.stdout.write(JSON.stringify({ permission: 'allow' }));
process.exit(0);
```

Create `cursor/probe/hooks.probe.json`:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "command": "node \"${workspaceFolder}/.cursor/probe/probe.js\"" }
    ]
  }
}
```

Create `cursor/probe/agents/file-reader.md`:

```markdown
---
name: file-reader
description: Reads a fixed test file and reports its contents. Used only to probe hook payloads.
model: inherit
---

Read the file `probe-target.txt` in the project root and report its exact contents back
verbatim. Do nothing else.
```

Create `cursor/probe/probe-target.txt`:

```
optimus probe target
```

- [ ] **Step 6: Write the run procedure**

Create `cursor/probe/README.md`:

```markdown
# Cursor probe kit

Answers the two undocumented facts the Cursor port is blocked on. Run this
BEFORE any Cursor adapter code exists — see docs/cursor-support-spec.md
Section 5 and open decision (a).

## Before you start

- Enterprise Cursor installs disable local plugin imports by default
  ("Allow Local Plugin Imports", off by default). A hook that never fires
  looks identical to a broken hook.
- Enterprise and Team `hooks.json` take precedence over Project and User
  `hooks.json`. If nothing logs, rule this out before concluding anything.

## Unknown 1 — subagent distinguishability

1. Create a scratch Cursor project (NOT this repo).
2. Copy `cursor/probe/` into `<scratch>/.cursor/probe/`, copy
   `cursor/probe/agents/file-reader.md` to `<scratch>/.cursor/agents/file-reader.md`,
   and copy `cursor/probe/probe-target.txt` to the scratch project root.
3. Copy `cursor/probe/hooks.probe.json` to `<scratch>/.cursor/hooks.json`.
   If Cursor rejects the file, fix the schema against your installed
   version and record what you changed — the shape in that file is taken
   from documentation, not from a verified install.
4. Reload the Cursor window so the hook registers.
5. `: > <scratch>/.cursor/probe/probe.log`
6. In the main agent panel, ask it to read `probe-target.txt`. Confirm a
   line landed in `probe.log`. **If nothing landed, stop here** — fix
   registration before continuing; every later step depends on it.
7. Dispatch the `file-reader` subagent (via `/file-reader`, or by asking
   for a Task with `subagent_type: file-reader`) and have it read
   `probe-target.txt`.
8. `node bin/optimus-probe-report <scratch>/.cursor/probe/probe.log`

## Unknown 2 — plugin root

Run these as two separate passes (Cursor's cardinality rules for multiple
hooks on one event are unverified):

Pass A — `<scratch>/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "command": "node \"${CURSOR_PLUGIN_ROOT}/probe/probe-root.js\" --plugin-root-attempt" }
    ]
  }
}
```

Pass B — same, with `${PLUGIN_ROOT}`.

After each pass: reload the window, trigger any tool call, then check
`probe-root.log`. If the file does not exist, the process never started —
that is itself the finding for that variable. Also check Cursor's own
hook-error surface (output panel / notifications) and record whatever it
says verbatim.

Then: `node bin/optimus-probe-report <scratch>/.cursor/probe/probe-root.log`

## Recording the result

Paste both report outputs into `docs/cursor-probe-findings.md` using the
template already in that file. Do not summarize them — the raw output is
the evidence Tasks 5–8 are gated on.
```

- [ ] **Step 7: Commit**

```bash
git add cursor/probe bin/optimus-probe-report tests/fixtures/probe tests/run-probe-report-tests.sh
git commit -m "feat: add Cursor hook probe kit and deterministic probe analyser"
```

---

## Task 4: Run the probes and record the findings (HUMAN CHECKPOINT)

**Files:**
- Create: `docs/cursor-probe-findings.md`

**Interfaces:**
- Consumes: `bin/optimus-probe-report` and `cursor/probe/` from Task 3.
- Produces: `docs/cursor-probe-findings.md` — the gate for Tasks 5–8. Its `Unknown 1 verdict` line selects which of Task 5 / Task 6 runs.

**This task cannot be delegated to an agent.** It requires driving a real Cursor GUI: opening a scratch project, reloading a window, dispatching a subagent from the agent panel, and reading Cursor's own error surface. An executing agent must stop here, hand back, and wait.

- [ ] **Step 1: Create the findings file with its template**

Create `docs/cursor-probe-findings.md`:

```markdown
# Cursor probe findings

**Probe run date:** <!-- YYYY-MM-DD -->
**Cursor version:** <!-- from Cursor > About, and from CURSOR_VERSION in the log -->
**Install type:** <!-- personal / Team / Enterprise. If Enterprise: is "Allow Local Plugin Imports" on? -->

These findings gate the Cursor adapter tasks in
docs/superpowers/plans/2026-09-09-cursor-support.md. Re-run the probes and
update this file on every Cursor upgrade — both facts below are
undocumented upstream and unversioned.

## Unknown 1 — subagent distinguishability

### Raw `optimus-probe-report` output

```
<!-- paste verbatim, do not summarize -->
```

### Verdict

<!-- one of:
     row 1 - distinguishing field present: <field name(s)>
     row 2 - no distinguishing field, sidecar correlation required
     row 3 - subagent tool calls do not fire preToolUse at all
     row 4 - hooks fire but enforcement is unreliable under a subagent
-->

### Deny-path confirmation (decision matrix row 4)

Replace the probe hook with one that unconditionally emits
`{"permission":"deny","user_message":"probe deny","agent_message":"probe deny"}`,
reload, and trigger a tool call from the main agent AND from the
`file-reader` subagent.

- Main agent call actually blocked? <!-- yes/no + what the UI showed -->
- Subagent call actually blocked? <!-- yes/no + what the UI showed -->
- Cursor's own error/notification text: <!-- verbatim, or "none" -->

## Unknown 2 — plugin root resolution

### Raw `optimus-probe-report` output

```
<!-- paste verbatim -->
```

### Verdict

<!-- one of:
     CURSOR_PLUGIN_ROOT resolves to: <path>
     PLUGIN_ROOT resolves to: <path>
     neither resolves - install must render absolute paths
-->

## Tool-name observations (spec Section 4)

Fill in the real `tool_name` string Cursor reports for each operation.
Trigger each one from the main agent and read it out of `probe.log`.
Anything left as `?` must be treated as unresolved, NOT as absent — the
documented matcher list explicitly disclaims completeness.

| Operation | Observed `tool_name` |
|---|---|
| read a file | ? |
| edit part of a file | ? |
| write/overwrite a whole file | ? |
| search file contents | ? |
| list/glob files by pattern | ? |
| fetch a URL | ? |
| web search | ? |
| delete a file | ? |
| run a shell command | ? |
| dispatch a subagent | ? |
| edit a notebook cell | ? |

## `hooks.json` schema corrections

Record any change you had to make to `cursor/probe/hooks.probe.json` to
get Cursor to accept it (matcher required? wildcard syntax? `version`
value?). This feeds directly into `cursor/hooks.json` in Task 7.

<!-- verbatim working file, or "none - the template worked as written" -->
```

- [ ] **Step 2: Run both probes**

Follow `cursor/probe/README.md` exactly. Do not skip the "if nothing landed, stop here" check in Unknown 1 step 6.

- [ ] **Step 3: Fill in every section of `docs/cursor-probe-findings.md`**

Paste raw report output. Fill the tool-name table by triggering each operation from the main agent. Leave `?` only where you genuinely could not trigger the operation, and say so.

- [ ] **Step 4: Commit**

```bash
git add docs/cursor-probe-findings.md
git commit -m "docs: record Cursor hook probe findings"
```

- [ ] **Step 5: Route the remaining work**

| Unknown 1 verdict | Next |
|---|---|
| row 1 — distinguishing field | Task 5, then 7, 8, 9. **Skip Task 6.** |
| row 3 — subagent calls do not fire `preToolUse` | Task 5, then 7, 8, 9. Skip Task 6. `isSubagentPayload()` returns `false` always, and that is correct: if the hook never fires for a subagent, every payload it does see is the orchestrator's. Record that reasoning in the adapter's header comment. |
| row 2 — no distinguishing field | Task 5 first, then Task 6, then 7, 8, 9. Task 6 patches and re-tests the file Task 5 creates, so it cannot precede it. |
| row 4 — enforcement unreliable under subagents | **Stop.** Hard enforcement is not viable on Cursor. Do Task 7 (rules only), Task 8 (installing rules + `sessionStart` only), Task 9 — and state plainly in the README that the Cursor build is advisory, not enforced. Do not ship a gate that only sometimes blocks. |

---

## Task 5: The Cursor `preToolUse` adapter

**Files:**
- Create: `hooks/optimus-gate-cursor.js`
- Create: `tests/fixtures/cursor/main-read.json`
- Create: `tests/fixtures/cursor/subagent-read.json`
- Create: `tests/fixtures/cursor/task-no-model.json`
- Create: `tests/fixtures/cursor/task-opus-model.json`
- Create: `tests/fixtures/cursor/task-cheap-model.json`
- Create: `tests/fixtures/cursor/main-shell-git.json`
- Create: `tests/fixtures/cursor/main-shell-cat.json`
- Create: `tests/fixtures/cursor/main-delete.json`
- Create: `tests/run-gate-cursor-tests.sh`

**Interfaces:**
- Consumes: `decide`, `ledgerEventFor`, `AGENT_DISPATCH`, `SHELL`, `REASON` from `hooks/optimus-core.js`; `isKillSwitchActive`, `getConfig` from `hooks/optimus-config.js`; `recordEvent` from `hooks/optimus-ledger.js`; the verdict and tool-name table from `docs/cursor-probe-findings.md`.
- Produces: an executable hook at `hooks/optimus-gate-cursor.js`, referenced by `cursor/hooks.json` in Task 7.

**Fixture values must come from the probe log, not from this plan.** The fixtures below carry the field set from the spec's documented list; every *value* — especially `tool_name` strings and any subagent-identity field — must be replaced with what `probe.log` actually recorded in Task 4. A fixture that encodes a guess turns the adapter suite into a test of the guess.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/cursor/main-read.json` (the others follow the same shape — `cwd` is the literal `__PROJECT__` token, substituted by the harness, exactly as the Claude Code fixtures do):

```json
{
  "hook_event_name": "preToolUse",
  "conversation_id": "probe-conv-1",
  "generation_id": "probe-gen-1",
  "model": "Claude Opus 5",
  "model_id": "claude-opus-5",
  "cursor_version": "REPLACE_FROM_PROBE",
  "workspace_roots": ["__PROJECT__"],
  "transcript_path": "/tmp/does-not-exist.jsonl",
  "cwd": "__PROJECT__",
  "tool_name": "Read",
  "tool_input": { "path": "work.txt" },
  "tool_use_id": "cursor_fixture_1",
  "agent_message": "Reading work.txt"
}
```

The remaining fixtures, each a copy of the above with these deltas:

| Fixture | Deltas |
|---|---|
| `subagent-read.json` | plus whatever subagent-identity field Task 4 found, e.g. `"subagent_id": "sub-1"`; `tool_use_id: "cursor_fixture_2"` |
| `task-no-model.json` | `tool_name: "Task"`, `tool_input: {"description":"read work.txt","prompt":"read work.txt","subagent_type":"general-purpose"}` |
| `task-opus-model.json` | `tool_name: "Task"`, `tool_input: {"model":"claude-opus-5","subagent_type":"general-purpose"}` |
| `task-cheap-model.json` | `tool_name: "Task"`, `tool_input: {"model":"claude-haiku-4-5","subagent_type":"general-purpose"}` |
| `main-shell-git.json` | `tool_name: "Shell"`, `tool_input: {"command":"git status"}` |
| `main-shell-cat.json` | `tool_name: "Shell"`, `tool_input: {"command":"cat work.txt"}` |
| `main-delete.json` | `tool_name: "Delete"`, `tool_input: {"path":"work.txt"}` |

Create `tests/run-gate-cursor-tests.sh`:

```bash
#!/usr/bin/env bash
# Shape tests for hooks/optimus-gate-cursor.js.
#
# Deliberately shallow: the policy these payloads exercise already has
# direct coverage in tests/core-tests.js. These exist only to catch
# parsing and shape-translation bugs at the Cursor boundary — a wrong
# tool-name mapping, a malformed permission JSON, a subagent field read
# from the wrong key.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/cursor"
GATE="$ROOT/hooks/optimus-gate-cursor.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

check() {
  local name="$1" expect="$2" fixture="$3" cwd="$4" extra_env="${5:-}"
  local payload out decision
  payload="$(sed "s#__PROJECT__#$cwd#g" "$FIXTURES/$fixture")"
  out="$(env $extra_env node "$GATE" <<<"$payload")"
  decision="unparseable"
  if echo "$out" | grep -q '"permission":"deny"'; then
    decision="deny"
  elif echo "$out" | grep -q '"permission":"allow"'; then
    decision="allow"
  fi
  if [ "$decision" == "$expect" ]; then
    echo "PASS: $name (got $decision)"
    pass=$((pass+1))
  else
    echo "FAIL: $name (expected $expect, got $decision) -- output: $out"
    fail=$((fail+1))
  fi
}

echo "== Optimus Cursor gate tests =="
echo "-- inactive project: everything allows (and emits explicit allow JSON) --"
check "inactive: main Read allowed"      allow main-read.json     "$PROJECT"
check "inactive: Task no-model allowed"  allow task-no-model.json "$PROJECT"

echo ""
echo "-- activating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on

echo ""
echo "-- active --"
check "active: main Read DENIED"                deny  main-read.json        "$PROJECT"
check "active: subagent Read ALLOWED (exempt)"  allow subagent-read.json    "$PROJECT"
check "active: Task w/o model DENIED"           deny  task-no-model.json    "$PROJECT"
check "active: Task model=opus DENIED"          deny  task-opus-model.json  "$PROJECT"
check "active: Task cheap model ALLOWED"        allow task-cheap-model.json "$PROJECT"
check "active: Shell git status ALLOWED"        allow main-shell-git.json   "$PROJECT"
check "active: Shell cat DENIED"                deny  main-shell-cat.json   "$PROJECT"
check "active: Delete DENIED"                   deny  main-delete.json      "$PROJECT"

echo ""
echo "-- the deny payload carries both message fields --"
out="$(sed "s#__PROJECT__#$PROJECT#g" "$FIXTURES/main-read.json" | node "$GATE")"
for field in user_message agent_message; do
  if echo "$out" | grep -q "\"$field\""; then
    echo "PASS: deny carries $field"; pass=$((pass+1))
  else
    echo "FAIL: deny is missing $field -- output: $out"; fail=$((fail+1))
  fi
done
if echo "$out" | grep -qF 'cheap/fast model'; then
  echo "PASS: deny text uses generic model tiers"; pass=$((pass+1))
else
  echo "FAIL: deny text should not name Anthropic tiers -- output: $out"; fail=$((fail+1))
fi

echo ""
echo "-- ledger is written with conversation_id mapped onto session_id --"
LEDGER="$PROJECT/.optimus/state/events.jsonl"
if grep -q '"session_id":"probe-conv-1"' "$LEDGER"; then
  echo "PASS: ledger session_id came from conversation_id"; pass=$((pass+1))
else
  echo "FAIL: ledger session_id not mapped -- $(cat "$LEDGER" 2>/dev/null || echo '(no ledger)')"; fail=$((fail+1))
fi
if grep -q '"ev":"work_tool_denied"' "$LEDGER" && grep -q '"ev":"bash_nudge"' "$LEDGER"; then
  echo "PASS: ledger uses the shared event names"; pass=$((pass+1))
else
  echo "FAIL: ledger event names diverge from the Claude Code build"; fail=$((fail+1))
fi

echo ""
echo "-- malformed stdin fails OPEN --"
out="$(echo 'not json at all' | node "$GATE")"
if echo "$out" | grep -q '"permission":"allow"'; then
  echo "PASS: malformed payload allows"; pass=$((pass+1))
else
  echo "FAIL: malformed payload did not fail open -- output: $out"; fail=$((fail+1))
fi

echo ""
echo "-- kill switch forces allow --"
check "kill switch: main Read ALLOWED" allow main-read.json "$PROJECT" "OPTIMUS_DISABLED=1"

echo ""
echo "-- deactivating --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" off
check "deactivated: main Read allowed again" allow main-read.json "$PROJECT"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x tests/run-gate-cursor-tests.sh
./tests/run-gate-cursor-tests.sh
```

Expected: FAIL — `Cannot find module '.../hooks/optimus-gate-cursor.js'`.

- [ ] **Step 3: Write `hooks/optimus-gate-cursor.js`**

```js
#!/usr/bin/env node
'use strict';

/**
 * Cursor preToolUse adapter.
 *
 * Thin by design, exactly like hooks/optimus-gate.js: it parses Cursor's
 * stdin shape, translates Cursor tool names into the core's normalized
 * vocabulary, decides via hooks/optimus-core.js, and emits Cursor's
 * permission JSON. No policy lives here.
 *
 * Cursor-specific plumbing that differs from Claude Code:
 *   - Output is {"permission":"allow"} / {"permission":"deny", ...}, and an
 *     allow is EXPLICIT (Claude Code allows by writing nothing).
 *   - Always exit 0. On Cursor, exit code 2 means deny — exiting 2 for an
 *     allow result would block everything, silently.
 *   - The payload carries conversation_id where Claude Code carries
 *     session_id. The ledger field stays session_id on both hosts so
 *     bin/optimus-stats needs no host branching (spec Section 1.6).
 *   - The payload carries a live `model`. It is passed to decide() as
 *     sessionModel but only consulted when a project sets
 *     modelConditional: true in .optimus/config.json. Off by default, so
 *     both hosts enforce on the same role-based basis out of the box.
 *
 * Fails OPEN on any internal error, same as the Claude Code gate. Note
 * that Cursor ALSO fails open on a crash unless "failClosed": true is set
 * per script in hooks.json — so a bug here means enforcement silently
 * does not apply rather than blocking a user. That is consistent with
 * Optimus's stated philosophy and must stay documented, not discovered.
 */

const path = require('path');
const { isKillSwitchActive, getConfig } = require(
  path.join(__dirname, 'optimus-config.js')
);
const { recordEvent } = require(path.join(__dirname, 'optimus-ledger.js'));
const {
  decide,
  ledgerEventFor,
  AGENT_DISPATCH,
  SHELL,
  REASON,
} = require(path.join(__dirname, 'optimus-core.js'));

/**
 * Cursor tool name -> normalized core vocabulary.
 *
 * REPLACE THE RIGHT-HAND SIDE FROM docs/cursor-probe-findings.md's
 * tool-name table. The entries below are the documented/expected names;
 * any name Task 4 recorded differently wins over this table. An
 * unrecognized name deliberately passes through unchanged and therefore
 * lands outside WORK_TOOLS and is ALLOWED — failing open on vocabulary,
 * consistent with the rest of the plugin. Add an observed name here to
 * start denying it.
 */
const CURSOR_TOOL_MAP = {
  Task: AGENT_DISPATCH,
  Shell: SHELL,
  Read: 'Read',
  Write: 'Write',
  Edit: 'Edit',
  Grep: 'Grep',
  Glob: 'Glob',
  Delete: 'Delete',
  WebFetch: 'WebFetch',
  WebSearch: 'WebSearch',
  NotebookEdit: 'NotebookEdit',
};

function normalizeTool(toolName) {
  if (typeof toolName !== 'string') return '';
  if (Object.prototype.hasOwnProperty.call(CURSOR_TOOL_MAP, toolName)) {
    return CURSOR_TOOL_MAP[toolName];
  }
  return toolName;
}

/**
 * Presents Cursor's raw tool_input under the three key names the core
 * reads: model, subagent_type, command.
 *
 * REPLACE THE SOURCE KEY NAMES FROM docs/cursor-probe-findings.md. The
 * spec flags Cursor's Task tool_input shape as unverified — whether it
 * carries a model-selection field at all, and under what name. The
 * fallbacks below are ordered most-likely-first; a name Task 4 observed
 * belongs at the front of its list.
 */
function normalizeInput(tool, rawInput) {
  const raw = rawInput && typeof rawInput === 'object' ? rawInput : {};
  if (tool === AGENT_DISPATCH) {
    return {
      model: raw.model || raw.model_id || raw.subagent_model,
      subagent_type: raw.subagent_type || raw.agent || raw.agent_type,
    };
  }
  if (tool === SHELL) {
    return { command: raw.command || raw.cmd || raw.script };
  }
  return raw;
}

/**
 * Determines whether this payload originates inside a dispatched
 * subagent rather than the orchestrator.
 *
 * THIS FUNCTION IS THE WHOLE OUTCOME OF SPEC SECTION 5.1. Its body must
 * match the verdict recorded in docs/cursor-probe-findings.md:
 *
 *   row 1 (distinguishing field): check that field, as below.
 *   row 3 (subagent calls never fire preToolUse): return false always —
 *          if the hook never fires for a subagent, every payload it does
 *          see is the orchestrator's.
 *   row 2 (no distinguishing field): delegate to the sidecar reader
 *          built in Task 6 instead of the field check.
 *
 * The field names below are the candidates the probe report surfaces.
 * Keep only what Task 4 actually observed, and treat it as an
 * undocumented, unversioned dependency: re-run the probe on every Cursor
 * upgrade.
 */
function isSubagentPayload(payload) {
  return Boolean(
    payload.subagent_id ||
      payload.subagent_type ||
      payload.agent_id ||
      payload.agent_type ||
      payload.parent_conversation_id ||
      payload.is_parallel_worker
  );
}

/** Cursor-facing deny text. Generic model tiers, never Anthropic aliases. */
function denyMessages(decision) {
  switch (decision.reason) {
    case REASON.NO_MODEL_SET:
      return {
        user_message: 'Optimus blocked a subagent dispatch that named no model.',
        agent_message:
          'Optimus: this Task dispatch sets no model, so it would silently inherit the ' +
          "orchestrator's own expensive model instead of running cheaper. Re-dispatch and set " +
          'the model explicitly: a cheap/fast model for simple, mechanical work (file lookups, ' +
          'boilerplate edits, running a command and reporting its output), and a stronger model ' +
          'only for work that genuinely needs judgement. Never dispatch a subagent on the same ' +
          'expensive model driving this session.',
      };
    case REASON.EXPENSIVE_MODEL_DISPATCH:
      return {
        user_message: 'Optimus blocked a subagent dispatch on the expensive model tier.',
        agent_message:
          'Optimus: this Task dispatch names model="' +
          decision.model +
          '", the expensive tier — dispatching a subagent on the same expensive model as the ' +
          'orchestrator defeats the point of delegating. Re-dispatch with a cheap/fast model for ' +
          'mechanical work, or a mid-tier model for work needing judgement.',
      };
    case REASON.WORK_TOOL_IN_ORCHESTRATOR:
      return {
        user_message: 'Optimus blocked ' + decision.tool + ' in the orchestrator session.',
        agent_message:
          'Optimus: the ' +
          decision.tool +
          ' tool is blocked in the orchestrator session while Optimus is active for this ' +
          'project. Delegate this work with the Task tool instead: a cheap/fast model for ' +
          'simple, mechanical work, a stronger model only where judgement is needed. Run ' +
          '`optimus-cli off` in this project if you need to work in this session directly.',
      };
    case REASON.SHELL_READ_BYPASS:
      return {
        user_message: 'Optimus blocked a shell command that is really a file read.',
        agent_message:
          'Optimus: this Shell command looks like a plain file read or search, which should go ' +
          'through a delegated subagent instead of the orchestrator running it directly. Use the ' +
          'Task tool with a cheap/fast model. Note: this is a best-effort pattern match, not a ' +
          'hard boundary — git/build/test and other orchestration commands are never blocked.',
      };
    default:
      return { user_message: 'Optimus blocked this call.', agent_message: 'Optimus: blocked.' };
  }
}

function allow() {
  process.stdout.write(JSON.stringify({ permission: 'allow' }));
  process.exit(0);
}

function deny(messages) {
  process.stdout.write(
    JSON.stringify({
      permission: 'deny',
      user_message: messages.user_message,
      agent_message: messages.agent_message,
    })
  );
  process.exit(0);
}

function main(raw) {
  if (isKillSwitchActive()) return allow();

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    return allow();
  }
  if (!payload || typeof payload !== 'object') return allow();

  // Subagent exemption. First, and before any config I/O.
  if (isSubagentPayload(payload)) return allow();

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return allow();
  }
  if (!cfg.enabled) return allow();

  const tool = normalizeTool(payload.tool_name);
  const toolInput = normalizeInput(tool, payload.tool_input);

  const decision = decide({
    tool: tool,
    toolInput: toolInput,
    isSubagent: false,
    sessionModel: typeof payload.model_id === 'string' ? payload.model_id : payload.model,
    config: cfg.raw && cfg.raw.modelConditional
      ? { enabled: true, modelConditional: true }
      : { enabled: true },
  });

  const event = ledgerEventFor({ tool: tool, toolInput: toolInput, decision: decision });
  if (event) {
    recordEvent(
      payload.cwd,
      Object.assign(
        { session_id: payload.conversation_id, tool_use_id: payload.tool_use_id },
        event
      )
    );
  }

  if (decision.allow) return allow();
  return deny(denyMessages(decision));
}

let raw = '';
process.stdin.on('data', (d) => {
  raw += d;
});
process.stdin.on('end', () => {
  try {
    main(raw);
  } catch (e) {
    // A crash must never wedge a session. Emit an explicit allow rather
    // than exiting silently: on Cursor, "no output" is not defined as
    // allow the way it is on Claude Code.
    try {
      process.stdout.write(JSON.stringify({ permission: 'allow' }));
    } catch (e2) {
      // nothing left to do
    }
    process.exit(0);
  }
});
```

- [ ] **Step 4: Run the Cursor suite to verify it passes**

```bash
./tests/run-gate-cursor-tests.sh
```

Expected: `0 failed`.

- [ ] **Step 5: Run every suite — the Claude Code build must be untouched**

```bash
./tests/run-core-tests.sh && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh \
  && ./tests/run-stats-tests.sh && ./tests/run-probe-report-tests.sh && ./tests/run-gate-cursor-tests.sh
```

Expected: `0 failed` in all six.

- [ ] **Step 6: Commit**

```bash
git add hooks/optimus-gate-cursor.js tests/fixtures/cursor tests/run-gate-cursor-tests.sh
git commit -m "feat: add Cursor preToolUse adapter over the shared policy core"
```

---

## Task 6: Sidecar subagent correlation (ONLY if Task 4 landed on row 2)

**Skip this task entirely** unless `docs/cursor-probe-findings.md` records "row 2 — no distinguishing field". Task 5's routing table says so; this task exists so that outcome does not need a new plan.

**Files:**
- Create: `hooks/optimus-sidecar.js`
- Create: `hooks/optimus-subagent-cursor.js`
- Create: `tests/run-sidecar-tests.sh`
- Modify: `hooks/optimus-gate-cursor.js` (`isSubagentPayload` delegates to the sidecar)

**Interfaces:**
- Consumes: `findProjectRoot` from `hooks/optimus-config.js`.
- Produces, from `hooks/optimus-sidecar.js`:
  - `markActive(cwd, id) -> void`
  - `clearActive(cwd, id) -> void`
  - `anyActive(cwd) -> boolean`
  - `STALE_MS` (number), `SIDECAR_DIRNAME` (string)

**One marker file per subagent, not one JSON document.** A single `active-subagents.json` would need read-modify-write, reopening exactly the concurrency race the append-only ledger design avoids — and `subagentStart`'s own documented `is_parallel_worker` field says parallel subagents happen. `markActive` creates `<root>/.optimus/state/active-subagents/<id>`; `clearActive` unlinks it; `anyActive` is a `readdirSync` non-empty check. No two writers ever touch the same path.

**Known imprecision, to be documented and not hidden:** this exempts *any* tool call made while some subagent is outstanding, not "this specific subagent's own calls". A main-agent `Read` issued while a subagent is running is wrongly exempted. That is strictly coarser than the Claude Code build. Say so in the README (Task 9), in these words: enforcement on Cursor is suspended while any subagent is outstanding.

**Stale markers expire.** A missed `subagentStop` (crash, force-quit, window reload mid-dispatch) would otherwise exempt the project forever. `anyActive` ignores markers older than `STALE_MS` (30 minutes) and unlinks them opportunistically.

- [ ] **Step 1: Write the failing test**

Create `tests/run-sidecar-tests.sh`:

```bash
#!/usr/bin/env bash
# Lifecycle tests for the Cursor subagent sidecar.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"
CLAUDE_PROJECT_DIR="$PROJECT" node "$ROOT/bin/optimus-cli" on >/dev/null

echo "== Optimus sidecar tests =="
node - "$ROOT" "$PROJECT" <<'NODE'
const path = require('path');
const fs = require('fs');
const assert = require('assert');
const [root, project] = process.argv.slice(2);
const s = require(path.join(root, 'hooks', 'optimus-sidecar.js'));
const dir = path.join(project, '.optimus', 'state', s.SIDECAR_DIRNAME);

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); console.log('PASS: ' + name); pass++; }
  catch (e) { console.log('FAIL: ' + name + ' -- ' + e.message); fail++; }
}

t('nothing active on a fresh project', () => assert.strictEqual(s.anyActive(project), false));
t('markActive makes it active', () => { s.markActive(project, 'sub-1'); assert.strictEqual(s.anyActive(project), true); });
t('a second subagent is independent', () => { s.markActive(project, 'sub-2'); assert.strictEqual(fs.readdirSync(dir).length, 2); });
t('clearing one leaves the other active', () => { s.clearActive(project, 'sub-1'); assert.strictEqual(s.anyActive(project), true); });
t('clearing the last one deactivates', () => { s.clearActive(project, 'sub-2'); assert.strictEqual(s.anyActive(project), false); });
t('clearing an unknown id is a no-op, not a throw', () => { s.clearActive(project, 'nope'); assert.strictEqual(s.anyActive(project), false); });
t('an id with path separators cannot escape the sidecar dir', () => {
  s.markActive(project, '../../escaped');
  assert.strictEqual(fs.existsSync(path.join(project, '.optimus', 'escaped')), false);
  s.clearActive(project, '../../escaped'); // leave nothing active for the stale test below
});
t('a stale marker is ignored and swept', () => {
  s.markActive(project, 'stale-1');
  const f = path.join(dir, 'stale-1');
  const old = new Date(Date.now() - s.STALE_MS - 60000);
  fs.utimesSync(f, old, old);
  assert.strictEqual(s.anyActive(project), false);
  assert.strictEqual(fs.existsSync(f), false);
});
t('anyActive on a non-Optimus directory is false, not a throw', () => {
  assert.strictEqual(s.anyActive('/tmp'), false);
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
NODE
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x tests/run-sidecar-tests.sh
./tests/run-sidecar-tests.sh
```

Expected: FAIL — `Cannot find module '.../hooks/optimus-sidecar.js'`.

- [ ] **Step 3: Write `hooks/optimus-sidecar.js`**

```js
'use strict';

/**
 * Coarse subagent-activity tracker for the Cursor build.
 *
 * Only used when spec Section 5.1's probe landed on decision-matrix
 * row 2: Cursor's preToolUse payload cannot distinguish a subagent's own
 * tool call from the orchestrator's, so the gate falls back to "is ANY
 * subagent outstanding right now" as its exemption signal.
 *
 * One marker FILE per subagent, never one shared JSON document. A shared
 * document would need read-modify-write, which reopens exactly the
 * concurrency race hooks/optimus-ledger.js's append-only design avoids —
 * and subagentStart's own is_parallel_worker field says parallel
 * subagents are real. Two writers never touch the same path here.
 *
 * Never throws. This sits on the gate's hot path.
 */

const fs = require('fs');
const path = require('path');
const { findProjectRoot } = require(path.join(__dirname, 'optimus-config.js'));

const SIDECAR_DIRNAME = 'active-subagents';
/** A marker older than this is treated as abandoned (missed subagentStop). */
const STALE_MS = 30 * 60 * 1000;

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

function markActive(cwd, id) {
  try {
    const dir = sidecarDir(cwd);
    if (!dir) return;
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, safeId(id)), '', { mode: 0o600 });
  } catch (e) {
    // best effort only — a failure here means enforcement stays on for
    // that subagent's calls, which is the safe direction to fail on a
    // host where we cannot identify the caller anyway.
  }
}

function clearActive(cwd, id) {
  try {
    const dir = sidecarDir(cwd);
    if (!dir) return;
    fs.unlinkSync(path.join(dir, safeId(id)));
  } catch (e) {
    // already gone, or never written — nothing to do
  }
}

/**
 * True if at least one non-stale subagent marker exists. Stale markers
 * are unlinked as they are found, so a missed subagentStop cannot
 * exempt a project indefinitely.
 */
function anyActive(cwd) {
  try {
    const dir = sidecarDir(cwd);
    if (!dir) return false;
    const names = fs.readdirSync(dir);
    const cutoff = Date.now() - STALE_MS;
    let active = 0;
    for (const name of names) {
      const file = path.join(dir, name);
      try {
        if (fs.statSync(file).mtimeMs < cutoff) {
          fs.unlinkSync(file);
        } else {
          active++;
        }
      } catch (e) {
        // vanished mid-scan — treat as not active
      }
    }
    return active > 0;
  } catch (e) {
    return false; // no sidecar dir, unreadable, not an Optimus project
  }
}

module.exports = { markActive, clearActive, anyActive, SIDECAR_DIRNAME, STALE_MS };
```

- [ ] **Step 4: Write `hooks/optimus-subagent-cursor.js`**

```js
#!/usr/bin/env node
'use strict';

/**
 * Cursor subagentStart / subagentStop adapter.
 *
 * Maintains the sidecar the Cursor gate consults when Cursor's
 * preToolUse payload cannot identify the calling role (spec Section 5.1
 * decision-matrix row 2). One executable, both events — it branches on
 * hook_event_name.
 *
 * Always emits an explicit allow and exits 0. It enforces nothing.
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

  // subagentStart documents subagent_id; fall back through the other ids
  // it carries so a renamed field degrades to a coarser-but-working
  // marker rather than to no marker at all.
  const id =
    payload.subagent_id ||
    payload.tool_call_id ||
    payload.generation_id ||
    payload.conversation_id;

  if (payload.hook_event_name === 'subagentStart') {
    markActive(payload.cwd, id);
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
```

- [ ] **Step 5: Point the gate at the sidecar**

In `hooks/optimus-gate-cursor.js`, add to the requires:

```js
const { anyActive } = require(path.join(__dirname, 'optimus-sidecar.js'));
```

and replace the whole body of `isSubagentPayload` with:

```js
/**
 * Cursor's preToolUse payload carries no field that distinguishes a
 * subagent's own tool call from the orchestrator's (spec Section 5.1,
 * decision-matrix row 2 — see docs/cursor-probe-findings.md). So this
 * falls back to sidecar correlation: exempt everything while ANY
 * subagent is outstanding in this project.
 *
 * This is deliberately coarser than the Claude Code build, and the
 * imprecision is real: a main-agent tool call made while a subagent is
 * running is wrongly exempted. Documented in the README rather than
 * hidden. The field checks are kept ahead of it so that if a future
 * Cursor version starts sending an identity field, the precise path
 * takes over automatically.
 */
function isSubagentPayload(payload) {
  if (
    payload.subagent_id ||
    payload.subagent_type ||
    payload.parent_conversation_id ||
    payload.is_parallel_worker
  ) {
    return true;
  }
  return anyActive(payload.cwd);
}
```

- [ ] **Step 6: Run everything**

```bash
./tests/run-sidecar-tests.sh && ./tests/run-gate-cursor-tests.sh && ./tests/run-core-tests.sh \
  && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh && ./tests/run-stats-tests.sh
```

Expected: `0 failed` everywhere. `run-gate-cursor-tests.sh`'s `subagent-read.json` case still passes on the field path, since Step 5 keeps the field checks first.

- [ ] **Step 7: Commit**

```bash
git add hooks/optimus-sidecar.js hooks/optimus-subagent-cursor.js hooks/optimus-gate-cursor.js tests/run-sidecar-tests.sh
git commit -m "feat: add sidecar subagent correlation for the Cursor build"
```

---

## Task 7: The Cursor reinforcement surface

**Files:**
- Create: `cursor/optimus.mdc`
- Create: `hooks/optimus-session-cursor.js`
- Create: `cursor/hooks.json`
- Create: `tests/run-session-cursor-tests.sh`

**Interfaces:**
- Consumes: `isKillSwitchActive`, `getConfig` from `hooks/optimus-config.js`.
- Produces:
  - `cursor/optimus.mdc` — the single source of the Cursor reminder text, consumed by `hooks/optimus-session-cursor.js` at runtime and copied verbatim into `.cursor/rules/optimus.mdc` by Task 8.
  - `hooks/optimus-session-cursor.js` — `sessionStart` hook emitting `{"additional_context": …}`.
  - `cursor/hooks.json` — registration template with the literal placeholder `__OPTIMUS_ROOT__`, rendered by Task 8.

**`cursor/optimus.mdc` is the single source of the reminder text — no separate reminder file is created.** Two files carrying the same paragraphs drift; the `sessionStart` hook strips the frontmatter at runtime instead. This is why Step 3's test asserts the hook's output against the file's own body rather than against a hardcoded string.

**Why both a one-shot hook and an always-on rule:** Cursor has no `UserPromptSubmit`/`additionalContext` equivalent. `beforeSubmitPrompt` returns only `{continue, user_message}` — it is a gate, not an injector, and must not be repurposed. `sessionStart`'s `additional_context` covers turn one; `alwaysApply: true` covers every turn after it, which is what actually substitutes for the Claude Code build's per-turn reinjection.

- [ ] **Step 1: Write `cursor/optimus.mdc`**

```markdown
---
description: Optimus orchestrator policy reminder — keeps the main agent delegating work instead of doing it directly
alwaysApply: true
---

Optimus is active for this project: you are the orchestrator, not the worker.

Read, Edit, Write, Grep, Glob, Delete, WebFetch, WebSearch, and NotebookEdit are blocked in this
session where Cursor's hooks enforce it — delegate that work via the Task tool instead.

Every Task dispatch must name a model explicitly: a cheap/fast model for simple, mechanical work
(file lookups, boilerplate edits, running a command and reporting its output), and a stronger model
only for work that genuinely needs judgement (ambiguous requirements, design tradeoffs, non-trivial
debugging). Never dispatch a subagent on the same expensive model driving this session.

Shell stays open for orchestration (git, builds, tests, process control) — but prefer a delegated
subagent over cat/grep/head/find for reading or searching files.

Answer minimally: report the outcome and anything the user must act on, nothing else. No preamble,
no recap of what you just did, no summary tables, no options you did not take. Explain in technical
depth only where the material genuinely requires it.
```

The `globs:` key is omitted rather than left empty. The spec flagged "empty `globs:` plus `alwaysApply: true`" as unconfirmed; omitting the key is the unambiguous way to say "no file-pattern restriction". If Task 4's install turns out to require the key, add it back as an empty bare string (`globs:`) — not a YAML list, which Cursor's rules format does not accept — and note it in `docs/cursor-probe-findings.md`.

- [ ] **Step 2: Write the failing test**

Create `tests/run-session-cursor-tests.sh`:

```bash
#!/usr/bin/env bash
# Tests for the Cursor sessionStart reminder hook.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/optimus-session-cursor.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

payload() {
  printf '{"hook_event_name":"sessionStart","conversation_id":"c1","cwd":"%s","model":"Claude Opus 5"}' "$PROJECT"
}

expect() {
  local name="$1" needle="$2" present="$3" extra_env="${4:-}"
  local out
  out="$(payload | env $extra_env node "$HOOK")"
  if echo "$out" | grep -qF "$needle"; then
    if [ "$present" == "yes" ]; then echo "PASS: $name"; pass=$((pass+1));
    else echo "FAIL: $name (unexpectedly found: $needle) -- $out"; fail=$((fail+1)); fi
  else
    if [ "$present" == "no" ]; then echo "PASS: $name"; pass=$((pass+1));
    else echo "FAIL: $name (missing: $needle) -- $out"; fail=$((fail+1)); fi
  fi
}

echo "== Optimus Cursor sessionStart tests =="
expect "inactive project injects nothing" "additional_context" no

echo ""
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on >/dev/null
expect "active project injects context"        "additional_context"                    yes
expect "context carries the orchestrator line" "you are the orchestrator, not the worker" yes
expect "context uses generic model tiers"      "cheap/fast model"                      yes
expect "frontmatter is stripped"               "alwaysApply"                           no
expect "kill switch injects nothing"           "additional_context"                    no  "OPTIMUS_DISABLED=1"

echo ""
echo "-- output is always valid JSON --"
if payload | node "$HOOK" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s);console.log("ok")})' | grep -q ok; then
  echo "PASS: emits valid JSON"; pass=$((pass+1))
else
  echo "FAIL: emitted invalid JSON"; fail=$((fail+1))
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run it to verify it fails**

```bash
chmod +x tests/run-session-cursor-tests.sh
./tests/run-session-cursor-tests.sh
```

Expected: FAIL — `Cannot find module '.../hooks/optimus-session-cursor.js'`.

- [ ] **Step 4: Write `hooks/optimus-session-cursor.js`**

```js
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
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
./tests/run-session-cursor-tests.sh
```

Expected: `0 failed`.

- [ ] **Step 6: Write `cursor/hooks.json`**

This is a **template**, not a file Cursor reads from this path. `__OPTIMUS_ROOT__` is replaced with an absolute path by `optimus-cli install cursor` (Task 8). Correct the top-level schema against whatever `docs/cursor-probe-findings.md`'s "hooks.json schema corrections" section recorded — including a `matcher` key and the real wildcard syntax if Cursor requires one.

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "command": "node \"__OPTIMUS_ROOT__/hooks/optimus-gate-cursor.js\"" }
    ],
    "sessionStart": [
      { "command": "node \"__OPTIMUS_ROOT__/hooks/optimus-session-cursor.js\"" }
    ]
  }
}
```

If Task 6 ran (sidecar fallback), also add:

```json
    "subagentStart": [
      { "command": "node \"__OPTIMUS_ROOT__/hooks/optimus-subagent-cursor.js\"" }
    ],
    "subagentStop": [
      { "command": "node \"__OPTIMUS_ROOT__/hooks/optimus-subagent-cursor.js\"" }
    ]
```

`beforeShellExecution` is deliberately **not** registered. The spec notes it is the more idiomatic Cursor hook for shell interception, but `preToolUse` already sees `Shell` calls, and registering both would double-fire the same policy and write the ledger twice for one command. Revisit only if the probe shows `preToolUse` does not fire for shell calls — and if so, record that in the findings file first.

- [ ] **Step 7: Commit**

```bash
git add cursor/optimus.mdc cursor/hooks.json hooks/optimus-session-cursor.js tests/run-session-cursor-tests.sh
git commit -m "feat: add Cursor reinforcement surface (alwaysApply rule + sessionStart hook)"
```

---

## Task 8: `optimus-cli install cursor`

**Files:**
- Modify: `bin/optimus-cli`
- Create: `tests/run-install-tests.sh`

**Interfaces:**
- Consumes: `cursor/hooks.json` and `cursor/optimus.mdc` from Task 7; `getConfig`, `setConfig`, `isKillSwitchActive`, `KILL_SWITCH_ENV` from `hooks/optimus-config.js` (already imported).
- Produces: `optimus-cli install cursor [--force]`, writing `<project>/.cursor/hooks.json` and `<project>/.cursor/rules/optimus.mdc`. Exit 0 on success, 1 on a refused overwrite.

**Behaviour decisions, all deliberate:**
- **Project dir resolution gains `CURSOR_PROJECT_DIR` as first choice**, then `CLAUDE_PROJECT_DIR`, then `process.cwd()`. Both variables are documented as available to Cursor hook scripts (`CLAUDE_PROJECT_DIR` is present "for compatibility"), and `on`/`off`/`status` need this too or `/optimus on` cannot work from inside Cursor. `tests/run-gate-tests.sh` sets `CLAUDE_PROJECT_DIR` and keeps working, since it is still consulted.
- **An existing `.cursor/hooks.json` is never silently overwritten.** It may carry the user's own unrelated hooks, and this CLI does not merge JSON — merging someone's hook registrations by inference is how you silently disable their tooling. Instead it writes `.cursor/hooks.json.optimus-suggested`, prints what to do, and exits 1. `--force` overwrites.
- **Writes refuse to follow a pre-existing symlink and are atomic** (temp file with `flag: 'wx'`, then rename), matching `setConfig`'s existing defences in `hooks/optimus-config.js`.
- **`install cursor` does not activate Optimus.** Activation stays `on`/`off` writing `.optimus/config.json` — installing the hooks and turning the policy on are separate acts, exactly as they are on Claude Code.

- [ ] **Step 1: Write the failing test**

Create `tests/run-install-tests.sh`:

```bash
#!/usr/bin/env bash
# Tests for `optimus-cli install cursor`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/optimus-cli"

pass=0
fail=0

ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
check(){ if [ "$2" == "yes" ]; then ok "$1"; else bad "$1"; fi; }

echo "== Optimus install tests =="

# --- clean install ------------------------------------------------------
W="$(mktemp -d)"; P="$W/project"; mkdir -p "$P"
CURSOR_PROJECT_DIR="$P" node "$CLI" install cursor >"$W/out.txt" 2>&1 || bad "clean install exited non-zero"
[ -f "$P/.cursor/hooks.json" ] && ok "writes .cursor/hooks.json" || bad "no .cursor/hooks.json"
[ -f "$P/.cursor/rules/optimus.mdc" ] && ok "writes .cursor/rules/optimus.mdc" || bad "no rules/optimus.mdc"
grep -q '__OPTIMUS_ROOT__' "$P/.cursor/hooks.json" && bad "placeholder left unrendered" || ok "placeholder rendered"
grep -q "$ROOT/hooks/optimus-gate-cursor.js" "$P/.cursor/hooks.json" && ok "absolute gate path rendered" || bad "gate path missing"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$P/.cursor/hooks.json" && ok "hooks.json is valid JSON" || bad "hooks.json invalid"
grep -q 'alwaysApply: true' "$P/.cursor/rules/optimus.mdc" && ok "rule keeps alwaysApply" || bad "rule lost alwaysApply"
grep -q "$P" "$W/out.txt" && ok "prints where it wrote" || bad "did not print target"
# install must NOT activate
grep -q '"enabled": true' "$P/.optimus/config.json" 2>/dev/null && bad "install activated Optimus" || ok "install does not activate"

# --- refuses to clobber a foreign hooks.json ---------------------------
W2="$(mktemp -d)"; P2="$W2/project"; mkdir -p "$P2/.cursor"
echo '{"version":1,"hooks":{"preToolUse":[{"command":"node other.js"}]}}' > "$P2/.cursor/hooks.json"
if CURSOR_PROJECT_DIR="$P2" node "$CLI" install cursor >"$W2/out.txt" 2>&1; then
  bad "did not refuse an existing hooks.json"
else
  ok "refuses an existing hooks.json"
fi
grep -q 'other.js' "$P2/.cursor/hooks.json" && ok "left the existing file untouched" || bad "clobbered the existing file"
[ -f "$P2/.cursor/hooks.json.optimus-suggested" ] && ok "wrote the .optimus-suggested sidecar" || bad "no suggested file"

# --- --force overwrites -------------------------------------------------
CURSOR_PROJECT_DIR="$P2" node "$CLI" install cursor --force >/dev/null 2>&1 || bad "--force exited non-zero"
grep -q 'optimus-gate-cursor.js' "$P2/.cursor/hooks.json" && ok "--force overwrites" || bad "--force did not overwrite"

# --- re-install over our own file is idempotent, no --force needed -----
W3="$(mktemp -d)"; P3="$W3/project"; mkdir -p "$P3"
CURSOR_PROJECT_DIR="$P3" node "$CLI" install cursor >/dev/null 2>&1
if CURSOR_PROJECT_DIR="$P3" node "$CLI" install cursor >/dev/null 2>&1; then
  ok "re-installing over our own hooks.json succeeds"
else
  bad "re-install needed --force"
fi

# --- symlink defence ----------------------------------------------------
W4="$(mktemp -d)"; P4="$W4/project"; mkdir -p "$P4/.cursor"
: > "$W4/elsewhere.json"
ln -s "$W4/elsewhere.json" "$P4/.cursor/hooks.json"
CURSOR_PROJECT_DIR="$P4" node "$CLI" install cursor --force >/dev/null 2>&1 || true
[ -s "$W4/elsewhere.json" ] && bad "wrote through a symlink" || ok "refuses to write through a symlink"

# --- CURSOR_PROJECT_DIR wins over CLAUDE_PROJECT_DIR -------------------
W5="$(mktemp -d)"; mkdir -p "$W5/cursor-target" "$W5/claude-target"
CURSOR_PROJECT_DIR="$W5/cursor-target" CLAUDE_PROJECT_DIR="$W5/claude-target" node "$CLI" install cursor >/dev/null 2>&1
[ -f "$W5/cursor-target/.cursor/hooks.json" ] && ok "CURSOR_PROJECT_DIR takes precedence" || bad "wrong target dir"
[ -f "$W5/claude-target/.cursor/hooks.json" ] && bad "also wrote to CLAUDE_PROJECT_DIR" || ok "did not write to CLAUDE_PROJECT_DIR"

# --- unknown install target --------------------------------------------
W6="$(mktemp -d)"; P6="$W6/project"; mkdir -p "$P6"
if CURSOR_PROJECT_DIR="$P6" node "$CLI" install emacs >/dev/null 2>&1; then
  bad "accepted an unknown install target"
else
  ok "rejects an unknown install target"
fi

rm -rf "$W" "$W2" "$W3" "$W4" "$W5" "$W6"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x tests/run-install-tests.sh
./tests/run-install-tests.sh
```

Expected: FAIL — `install` falls through to the CLI's `default:` branch, so no files are written.

- [ ] **Step 3: Extend `bin/optimus-cli`**

Replace the `cwd` line and the `switch` block. The header comment, the requires, and `printStatus()` stay exactly as they are, except that `printStatus()` gains two lines. New content for the file from the `cwd` assignment down:

```js
const argv = process.argv.slice(2);
const arg = (argv[0] || 'status').trim().toLowerCase();

// CURSOR_PROJECT_DIR first, then CLAUDE_PROJECT_DIR (documented as
// present in Cursor "for compatibility", and what Claude Code sets), then
// the process cwd. Both hosts therefore resolve "this project" the same
// way, which is what lets `on`/`off`/`status` work unchanged inside Cursor.
const cwd = process.env.CURSOR_PROJECT_DIR || process.env.CLAUDE_PROJECT_DIR || process.cwd();

const fs = require('fs');
const PLUGIN_ROOT = path.join(__dirname, '..');
const CURSOR_TEMPLATE_DIR = path.join(PLUGIN_ROOT, 'cursor');
const ROOT_PLACEHOLDER = '__OPTIMUS_ROOT__';

function printStatus() {
  const cfg = getConfig(cwd);
  const killSwitch = isKillSwitchActive();
  console.log('Optimus status for this project');
  console.log('  project dir  : ' + cwd);
  console.log(
    '  config file  : ' +
      (cfg.root ? path.join(cfg.root, '.optimus', 'config.json') : '(none yet — not activated in this project or any parent directory)')
  );
  console.log('  activated    : ' + (cfg.enabled ? 'YES — orchestrator role is enforced here' : 'no'));
  console.log(
    '  kill switch  : ' +
      (killSwitch
        ? 'ON (' + KILL_SWITCH_ENV + ' is set) — ALL enforcement is bypassed everywhere right now, regardless of the line above'
        : 'off')
  );
  console.log(
    '  cursor hooks : ' +
      (fs.existsSync(path.join(cwd, '.cursor', 'hooks.json'))
        ? 'installed at ' + path.join(cwd, '.cursor', 'hooks.json')
        : 'not installed (run `optimus-cli install cursor`)')
  );
  console.log(
    '  enforcement  : role-based' +
      (cfg.raw && cfg.raw.modelConditional
        ? ' + model-conditional (Cursor only — the gate stands down when the session model is not the expensive tier)'
        : '')
  );
}

/** Atomic write that refuses to follow a pre-existing symlink at target. */
function writeFileSafe(target, contents) {
  try {
    const lst = fs.lstatSync(target);
    if (lst.isSymbolicLink()) {
      throw new Error('Optimus: refusing to write through a symlink at ' + target);
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
  const tmp = target + '.tmp-' + process.pid + '-' + Date.now();
  fs.writeFileSync(tmp, contents, { mode: 0o600, flag: 'wx' });
  fs.renameSync(tmp, target);
}

function installCursor(force) {
  const template = fs.readFileSync(path.join(CURSOR_TEMPLATE_DIR, 'hooks.json'), 'utf8');
  const rendered = template.split(ROOT_PLACEHOLDER).join(PLUGIN_ROOT);
  const rule = fs.readFileSync(path.join(CURSOR_TEMPLATE_DIR, 'optimus.mdc'), 'utf8');

  const cursorDir = path.join(cwd, '.cursor');
  const rulesDir = path.join(cursorDir, 'rules');
  const hooksTarget = path.join(cursorDir, 'hooks.json');
  const ruleTarget = path.join(rulesDir, 'optimus.mdc');

  fs.mkdirSync(rulesDir, { recursive: true });

  // Never silently overwrite someone else's hook registrations. This CLI
  // does not merge JSON — inferring a merge of a user's own hooks is how
  // you silently disable their tooling.
  let existing = null;
  try {
    existing = fs.readFileSync(hooksTarget, 'utf8');
  } catch (e) {
    // no existing file — the clean path
  }
  const isOurs = existing !== null && existing.indexOf('optimus-gate-cursor.js') !== -1;

  if (existing !== null && !isOurs && !force) {
    const suggested = hooksTarget + '.optimus-suggested';
    fs.writeFileSync(suggested, rendered, { mode: 0o600 });
    console.log('Optimus: ' + hooksTarget + ' already exists and was not written by Optimus.');
    console.log('Refusing to overwrite it — it may carry your own hook registrations, and this');
    console.log('command does not merge hook JSON.');
    console.log('');
    console.log('What Optimus would have written is here instead:');
    console.log('  ' + suggested);
    console.log('');
    console.log('Merge the "preToolUse" and "sessionStart" entries into your own file, or re-run');
    console.log('with --force to replace it.');
    process.exit(1);
  }

  if (existing !== null) {
    fs.unlinkSync(hooksTarget); // writeFileSafe uses flag 'wx'
  }
  writeFileSafe(hooksTarget, rendered);

  try {
    fs.unlinkSync(ruleTarget);
  } catch (e) {
    // not there yet
  }
  writeFileSafe(ruleTarget, rule);

  console.log('Optimus Cursor hooks installed for ' + cwd);
  console.log('  hooks : ' + hooksTarget);
  console.log('  rule  : ' + ruleTarget);
  console.log('  plugin root baked into the hook commands: ' + PLUGIN_ROOT);
  console.log('');
  console.log('Note: those command paths are absolute and therefore machine-specific.');
  console.log('Re-run this command after moving or reinstalling the plugin, and think twice');
  console.log('before committing .cursor/hooks.json to a shared repository.');
  console.log('');
  console.log('Reload the Cursor window to register the hooks, then run `optimus-cli on`');
  console.log('in this project to activate enforcement.');
  console.log('');
  printStatus();
}

switch (arg) {
  case 'on': {
    const r = setConfig(cwd, true);
    console.log('Optimus activated for ' + r.root);
    console.log('Config written to ' + r.configPath);
    console.log('');
    printStatus();
    break;
  }
  case 'off': {
    const r = setConfig(cwd, false);
    console.log('Optimus deactivated for ' + r.root);
    console.log('');
    printStatus();
    break;
  }
  case 'install': {
    const target = (argv[1] || '').trim().toLowerCase();
    const force = argv.indexOf('--force') !== -1;
    if (target === 'cursor') {
      installCursor(force);
    } else {
      console.log('Usage: optimus-cli install cursor [--force]');
      console.log('');
      console.log('Claude Code needs no install step — the plugin ships hooks/hooks.json,');
      console.log('which Claude Code loads from the plugin itself.');
      process.exit(1);
    }
    break;
  }
  case 'status':
  case '': {
    printStatus();
    break;
  }
  default: {
    console.log('Usage: /optimus [on|off|status]');
    console.log('       optimus-cli install cursor [--force]');
    console.log('');
    printStatus();
  }
}
```

- [ ] **Step 4: Run the install suite plus every other suite**

```bash
./tests/run-install-tests.sh
./tests/run-core-tests.sh && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh \
  && ./tests/run-stats-tests.sh && ./tests/run-probe-report-tests.sh \
  && ./tests/run-gate-cursor-tests.sh && ./tests/run-session-cursor-tests.sh
```

Expected: `0 failed` in all of them. `run-gate-tests.sh` and `run-stats-tests.sh` exercise the CLI's `on`/`off` path, so they are the regression check on the changed `cwd` resolution.

- [ ] **Step 5: Verify the real install end to end in Cursor**

```bash
# in the scratch Cursor project from Task 4
node <plugin>/bin/optimus-cli install cursor
node <plugin>/bin/optimus-cli on
```

Reload the Cursor window, then in the main agent panel ask it to read a file. Expected: the read is denied and the agent is told to use the Task tool. Then confirm `.optimus/state/events.jsonl` in that project gained a `work_tool_denied` line. Record the result — a pass here is the first end-to-end proof the port works; a fail sends you back to `docs/cursor-probe-findings.md`, not to guesswork.

- [ ] **Step 6: Commit**

```bash
git add bin/optimus-cli tests/run-install-tests.sh
git commit -m "feat: add optimus-cli install cursor and Cursor-aware project resolution"
```

---

## Task 9: Documentation, a single test entry point, and the version bump

**Files:**
- Create: `tests/run-all.sh`
- Modify: `README.md`
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: everything built in Tasks 1–8.
- Produces: `./tests/run-all.sh` as the one command that runs every suite.

- [ ] **Step 1: Write `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
# Runs every Optimus test suite. Suites that belong to an optional build
# path (the Cursor sidecar fallback) are skipped when their code is absent
# rather than failing — and the skip is printed, never silent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUITES=(
  run-core-tests.sh
  run-gate-tests.sh
  run-ledger-tests.sh
  run-stats-tests.sh
  run-probe-report-tests.sh
  run-gate-cursor-tests.sh
  run-session-cursor-tests.sh
  run-install-tests.sh
  run-sidecar-tests.sh
)

failed=()
skipped=()

for suite in "${SUITES[@]}"; do
  if [ ! -x "$ROOT/tests/$suite" ]; then
    skipped+=("$suite (not present)")
    continue
  fi
  echo ""
  echo "################ $suite ################"
  if ! "$ROOT/tests/$suite"; then
    failed+=("$suite")
  fi
done

echo ""
echo "######## summary ########"
for s in "${skipped[@]:-}"; do [ -n "$s" ] && echo "SKIP: $s"; done
if [ ${#failed[@]} -eq 0 ]; then
  echo "ALL SUITES PASSED"
  exit 0
fi
for f in "${failed[@]}"; do echo "FAILED: $f"; done
exit 1
```

- [ ] **Step 2: Run it**

```bash
chmod +x tests/run-all.sh
./tests/run-all.sh
```

Expected: `ALL SUITES PASSED`, with `run-sidecar-tests.sh` listed under SKIP if Task 6 did not run.

- [ ] **Step 3: Update `README.md`**

Three edits. Content, not paraphrase:

**(a)** Replace the architecture file tree in the `## Architecture` section (line ~207) so it lists the new files:

```
hooks/
  hooks.json                 Claude Code hook registration (name and path are load-bearing)
  optimus-core.js            host-agnostic policy: work tools, expensive-model rule,
                             shell-bypass patterns, check order, ledger event names
  optimus-gate.js            Claude Code PreToolUse adapter (thin)
  optimus-gate-cursor.js     Cursor preToolUse adapter (thin)
  optimus-session-cursor.js  Cursor sessionStart one-shot reminder
  optimus-subagent-cursor.js Cursor subagentStart/Stop sidecar writer (fallback path only)
  optimus-sidecar.js         coarse "is any subagent outstanding" tracker (fallback path only)
  optimus-reinforce.js       Claude Code UserPromptSubmit per-turn reminder
  optimus-config.js          repo-local activation, kill switch, atomic config writes
  optimus-ledger.js          append-only enforcement ledger
cursor/
  hooks.json                 Cursor registration template (__OPTIMUS_ROOT__ rendered at install)
  optimus.mdc                alwaysApply rule — the single source of the Cursor reminder text
  probe/                     hook-payload probe kit (see docs/cursor-probe-findings.md)
bin/
  optimus-cli                /optimus on|off|status, plus `install cursor`
  optimus-stats              /optimus-stats
  optimus-probe-report       analyses a Cursor probe log
```

**(b)** Add a new `## Cursor` section immediately after `## Install`:

```markdown
## Cursor

Optimus runs on Cursor as well as Claude Code. Both hosts share one policy
core (`hooks/optimus-core.js`), so the rules are identical by construction
rather than by discipline; only the payload parsing and the output shape
differ per host.

Install into a Cursor project:

```bash
optimus-cli install cursor   # writes .cursor/hooks.json and .cursor/rules/optimus.mdc
optimus-cli on               # activates enforcement for this project
```

Then reload the Cursor window so the hooks register.

What differs from the Claude Code build, and why:

| | Claude Code | Cursor |
|---|---|---|
| Enforcement point | `PreToolUse` hook | `preToolUse` hook |
| Dispatch tool | `Agent` | `Task` |
| Shell tool | `Bash` | `Shell` |
| `Delete` tool | does not exist | treated as a work tool — delegate deletions |
| Per-turn reminder | `UserPromptSubmit` re-injects every turn | Cursor has no equivalent event. Turn one comes from a `sessionStart` hook; every turn after it comes from the `alwaysApply` rule at `.cursor/rules/optimus.mdc` |
| Hook path resolution | `${CLAUDE_PLUGIN_ROOT}` | absolute paths baked in at install time, so `.cursor/hooks.json` is machine-specific — re-run `install cursor` after moving the plugin |
| `/optimus-stats` | full report | enforcement-ledger counts only. Cursor's transcript format is undocumented, so the requested-vs-actual model comparison correctly reports no data rather than guessing |
| Model-conditional enforcement | not possible — `PreToolUse` carries no model field | possible: Cursor payloads carry the live session model. Opt in per project with `"modelConditional": true` in `.optimus/config.json`. Off by default so both hosts behave the same out of the box |

Both hosts fail open: a crash in the hook allows the call rather than
blocking it. On Cursor that also means a broken hook results in
enforcement silently not applying, unless you set `"failClosed": true` on
the hook in `.cursor/hooks.json`. That is the same deliberate tradeoff the
kill switch exists for — a bug in Optimus must never wedge a session.
```

If Task 6 ran, append to that section:

```markdown
On this Cursor version, `preToolUse` payloads carry nothing that
distinguishes a subagent's own tool calls from the orchestrator's, so
Optimus falls back to tracking whether *any* subagent is outstanding
(`subagentStart`/`subagentStop` write marker files under
`.optimus/state/active-subagents/`). Enforcement is therefore **suspended
while any subagent is outstanding** — coarser than the Claude Code build,
where the exemption is per-call. A main-session tool call made while a
subagent is running is not blocked. See `docs/cursor-probe-findings.md`.
```

**(c)** Add to `## Known limitations` (line ~346):

```markdown
- **Cursor's hook payload fields are undocumented where Optimus depends on
  them.** The subagent-identity field the Cursor gate keys on, and the
  plugin-root resolution behaviour the installer works around, were both
  established empirically — see `docs/cursor-probe-findings.md` and
  `cursor/probe/`. Neither is versioned upstream. Re-run
  `bin/optimus-probe-report` against a fresh probe log after every Cursor
  upgrade; a silently renamed field degrades enforcement rather than
  announcing itself.
- **`.cursor/hooks.json` contains absolute paths.** It is generated per
  machine by `optimus-cli install cursor` and should generally not be
  committed to a shared repository.
- **Org-managed Cursor installs can shadow or block this entirely.**
  Enterprise and Team `hooks.json` take precedence over Project and User
  `hooks.json`, and "Allow Local Plugin Imports" is off by default on
  Enterprise. Both look identical to "Optimus is broken".
```

- [ ] **Step 4: Bump the version**

In `.claude-plugin/plugin.json`, change `"version": "0.2.0"` to `"version": "0.3.0"`, and add `"cursor"` to the `keywords` array.

- [ ] **Step 5: Verify**

```bash
./tests/run-all.sh
node -e 'const p=require("./.claude-plugin/plugin.json"); console.log(p.version, p.keywords.join(","))'
```

Expected: `ALL SUITES PASSED`, then `0.3.0 orchestration,cost,subagents,hooks,delegation,cursor`.

- [ ] **Step 6: Commit**

```bash
git add tests/run-all.sh README.md .claude-plugin/plugin.json
git commit -m "docs: document the Cursor build; add a single test entry point; bump to 0.3.0"
```

---

## Spec coverage

Every section of `docs/cursor-support-spec.md` mapped to the task that implements it. Read this before starting: if a task appears to conflict with the spec, the spec wins and this plan is wrong.

| Spec section | Where it lands |
|---|---|
| 1.x (background) | Read-only context. Task 2 preserves every behaviour described there. |
| 1.6 (ledger port requirements 1–4) | Task 1 (`ledgerEventFor` keeps event names/fields shared), Task 5 (`conversation_id` → `session_id`, raw requested model recorded, no second ledger writer). |
| 2 (capability mapping) | Task 5 for the enforcement rows; Task 7 for the reminder row; Task 8 for the slash-command row. |
| 3 (live session-model visibility) | Task 1 (`config.modelConditional` + `sessionModel`, default off), Task 5 (passes `model_id`), Task 8 (`printStatus` shows the enforcement basis, so the divergence is visible and not silent). |
| 4 / 7 (tool-name mapping) | Task 4's tool-name table records reality; Task 5's `CURSOR_TOOL_MAP` consumes it. `Delete` is a work tool (Task 1). Unknown names fail open, documented. |
| 5.1 (Unknown 1) | Tasks 3, 4. All four decision-matrix rows are routed at Task 4 Step 5; row 2 has Task 6, row 4 stops the port. |
| 5.2 (Unknown 2) | Tasks 3, 4; the "no variable resolves" fallback is Task 8's absolute-path rendering, with its machine-specificity cost printed to the user and documented in the README. |
| 6.1 (extract the core) | Task 1. |
| 6.2 (Cursor adapter) | Task 5. `updated_input` deliberately unused. |
| 6.3 (new files) | Tasks 1, 5, 6, 7. The spec's `cursor/optimus.mdc` doubles as the reminder-text source; no separate reminder file is created — Task 7 explains why. |
| 6.4 (`install cursor`) | Task 8, all four listed behaviours plus overwrite refusal and symlink defence. |
| 8 (porting reinforce) | Task 7. |
| 9(a) probe-first | Locked. Tasks 3–4 gate 5–8. |
| 9(b) model-conditional | Locked: flag present, default off. |
| 9(c) plain install vs plugin package | Locked: plain install (Task 8). Marketplace packaging is out of scope for this plan. |
| 9(d) Cursor transcript reader | Out of scope, by the spec's own recommendation. `bin/optimus-stats` is untouched; its ledger half works on Cursor with no new code because Task 5 writes the same event names. Documented in the README table. |
| 10 (testing) | Task 1 (core unit tests), Task 2 (existing suites as the regression proof), Task 5 (Cursor fixtures + shallow shape tests), Task 6 (sidecar lifecycle), Tasks 3/7/8 (probe analyser, session hook, installer). |
| 11 (risks) | Fail-open documented in Task 5's header and the README; never-exit-2 stated in Task 5; doc-drift re-verification in Task 9(c); Enterprise precedence and local-plugin-import toggle in `cursor/probe/README.md` and Task 9(c). Marketplace review is out of scope with 9(c). |

## Out of scope, deliberately

- A Cursor transcript reader for `bin/optimus-stats` (spec 9(d)). Needs its own empirical step — a third Unknown, not a follow-on.
- A packaged `.cursor-plugin/plugin.json` and Cursor Marketplace submission (spec 9(c)).
- Registering `beforeShellExecution` (Task 7 explains: it would double-fire).
- A Cursor equivalent of the `/optimus` slash command as a Cursor skill. `optimus-cli` is on `PATH` and works from a terminal in Cursor; a `.cursor/skills/optimus/SKILL.md` wrapper is a small, separable follow-up.

## Execution

Task order: **1 → 2 → 3 → 4 (human) → 5 → [6 if row 2] → 7 → 8 → 9**.

Tasks 1–2 and Task 3 are independent of each other and may run in parallel. Task 4 is a hard checkpoint — an agent must hand back there.
