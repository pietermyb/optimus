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
| **row 2 — no distinguishing field (THIS IS WHAT HAPPENED — see `docs/cursor-probe-findings.md`)** | Task 5 (sidecar), then Task 6 (adapter), then 7, 8, 9. Both tasks were rewritten after the probe: `conversation_id` turned out to be the discriminator, so the sidecar gives exact per-call attribution rather than the coarse fallback the spec anticipated. |
| row 1 — distinguishing field | Would have collapsed Task 5 into a payload field check inside Task 6. Not what happened. |
| row 3 — subagent calls do not fire `preToolUse` | Ruled out empirically: they do fire. |

| row 4 — enforcement unreliable under subagents | Ruled out empirically: an unconditional deny hook blocked both the orchestrator's and the subagent's calls for real. |

---

## Task 5: The Cursor subagent sidecar

> **Revised after the Task 4 probe run.** The probe landed on decision-matrix row 2 — a Cursor
> `preToolUse` payload carries no field that marks it as a subagent's — but it also established
> that `conversation_id` is the discriminator: a subagent's tool calls carry the subagent's own
> `conversation_id`, and `subagentStart` carries the parent's as `parent_conversation_id` and fires
> before the subagent's first tool call. That is the spec's own preferred row-2 mechanism
> ("keyed by `conversation_id` … if `subagentStart`'s `parent_conversation_id` matches the
> `preToolUse` payload's `conversation_id`"), so the sidecar gives **exact per-call attribution**,
> not the coarse "any subagent is outstanding" approximation the spec fell back to. See
> `docs/cursor-probe-findings.md`.

**Files:**
- Create: `hooks/optimus-sidecar.js`
- Create: `hooks/optimus-subagent-cursor.js`
- Create: `tests/run-sidecar-tests.sh`

**Interfaces:**
- Consumes: `findProjectRoot`, `getConfig`, `isKillSwitchActive` from `hooks/optimus-config.js`.
- Produces, from `hooks/optimus-sidecar.js`:
  - `markActive(cwd, subagentId, parentConversationId) -> void`
  - `clearActive(cwd, subagentId) -> void`
  - `parentConversations(cwd) -> Set<string>`
  - `isSubagentConversation(cwd, conversationId) -> boolean`
  - `SIDECAR_DIRNAME` (string), `STALE_MS` (number)
- Produces, as an executable: `hooks/optimus-subagent-cursor.js`, registered on Cursor's
  `subagentStart` and `subagentStop` in Task 7's `cursor/hooks.json`.

**Design, and why each part is the way it is:**

- **One marker FILE per subagent, filename = the subagent's id, content = the PARENT's
  `conversation_id`.** Never one shared JSON document: a shared document needs read-modify-write,
  reopening exactly the concurrency race `hooks/optimus-ledger.js`'s append-only design avoids.
  Two writers never touch the same path here, so parallel subagents are safe by construction.
- **Keyed on the subagent id, valued by the parent id.** The probe established that
  `subagentStart.subagent_id` is NOT the subagent's own `conversation_id` — it is the parent's
  `tool_use_id` for the `Task` call (identical to `tool_call_id`). The subagent's own conversation
  id is not knowable until its first tool call, so it cannot be pre-registered. The id is used
  only as a unique filename so `subagentStop` can clear the right entry; the parent id is the
  payload.
- **The gate's test is `conversation_id ∉ parentConversations()`.** With at least one subagent
  outstanding, a call whose conversation is a recorded parent is the orchestrator's, and any other
  conversation is a subagent's. With no subagent outstanding there are no subagent calls either,
  so an empty set means "everything is the orchestrator".
- **A `subagentStop` with no matching `subagentStart` must be tolerated.** The probe observed
  exactly that: a dispatch that fails validation fires `subagentStop` (`subagent_type: "unknown"`,
  `status: "error"`) with no preceding `subagentStart`. `clearActive` on an unknown id is a no-op.
- **Stale markers expire.** A missed `subagentStop` (crash, force-quit, window reload mid-dispatch)
  would otherwise leave a parent recorded forever, and every OTHER conversation in the project
  would be treated as a subagent. `parentConversations` ignores markers older than `STALE_MS`
  (30 minutes) and unlinks them as it finds them.

**Two known limitations, to be documented in Task 9 and not hidden:**

1. **Two orchestrators in one project.** If two Cursor windows drive the same project and window A
   has a subagent outstanding, window B's own tool calls have a conversation id that is not a
   recorded parent, so they are exempted. Fail-open, consistent with Optimus's stated stance, and
   strictly narrower than the coarse design the spec anticipated. Closing it would need a write on
   the enforcement hot path to register orchestrator conversations, which costs more than the hole.
2. **Nested subagents are not handled.** If a subagent were itself to dispatch one, that subagent's
   conversation would become a recorded parent and its own calls would start being blocked —
   fail-closed, the bad direction. Nesting was not observed on Cursor 3.19.13 (`subagent_type` is
   a fixed built-in enum) and is out of scope. If it turns out to be real, the fix is a
   known-children marker set alongside the parents.

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

t('no parents on a fresh project', () => {
  assert.strictEqual(s.parentConversations(project).size, 0);
});
t('with no parents recorded, nothing is a subagent', () => {
  assert.strictEqual(s.isSubagentConversation(project, 'conv-main'), false);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-anything'), false);
});
t('markActive records the parent conversation, not the subagent id', () => {
  s.markActive(project, 'tooluse-1', 'conv-main');
  assert.deepStrictEqual([...s.parentConversations(project)], ['conv-main']);
});
t('the parent conversation is NOT a subagent', () => {
  assert.strictEqual(s.isSubagentConversation(project, 'conv-main'), false);
});
t('any other conversation IS a subagent while one is outstanding', () => {
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), true);
});
t('a missing conversation id is treated as the orchestrator, not a subagent', () => {
  assert.strictEqual(s.isSubagentConversation(project, undefined), false);
  assert.strictEqual(s.isSubagentConversation(project, ''), false);
});
t('parallel subagents from one parent collapse to one parent entry', () => {
  s.markActive(project, 'tooluse-2', 'conv-main');
  assert.strictEqual(fs.readdirSync(dir).length, 2);
  assert.deepStrictEqual([...s.parentConversations(project)], ['conv-main']);
});
t('clearing one of two leaves the parent recorded', () => {
  s.clearActive(project, 'tooluse-1');
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), true);
});
t('clearing the last one empties the parent set', () => {
  s.clearActive(project, 'tooluse-2');
  assert.strictEqual(s.parentConversations(project).size, 0);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), false);
});
t('a subagentStop with no matching start is a no-op, not a throw', () => {
  s.clearActive(project, 'never-started');
  assert.strictEqual(s.parentConversations(project).size, 0);
});
t('two parents can be outstanding at once', () => {
  s.markActive(project, 'tooluse-3', 'conv-main');
  s.markActive(project, 'tooluse-4', 'conv-other');
  assert.deepStrictEqual([...s.parentConversations(project)].sort(), ['conv-main', 'conv-other']);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-main'), false);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-other'), false);
  assert.strictEqual(s.isSubagentConversation(project, 'conv-sub'), true);
  s.clearActive(project, 'tooluse-3');
  s.clearActive(project, 'tooluse-4');
});
t('an id with path separators cannot escape the sidecar dir', () => {
  s.markActive(project, '../../escaped', 'conv-main');
  assert.strictEqual(fs.existsSync(path.join(project, '.optimus', 'escaped')), false);
  s.clearActive(project, '../../escaped');
  assert.strictEqual(s.parentConversations(project).size, 0);
});
t('a stale marker is ignored and swept', () => {
  s.markActive(project, 'stale-1', 'conv-main');
  const f = path.join(dir, 'stale-1');
  const old = new Date(Date.now() - s.STALE_MS - 60000);
  fs.utimesSync(f, old, old);
  assert.strictEqual(s.parentConversations(project).size, 0);
  assert.strictEqual(fs.existsSync(f), false);
});
t('a marker with no readable parent id is ignored', () => {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'empty-1'), '');
  assert.strictEqual(s.parentConversations(project).size, 0);
  fs.unlinkSync(path.join(dir, 'empty-1'));
});
t('a non-Optimus directory yields no parents, not a throw', () => {
  assert.strictEqual(s.parentConversations('/tmp').size, 0);
  assert.strictEqual(s.isSubagentConversation('/tmp', 'conv-sub'), false);
});

console.log('');
console.log('== ' + pass + ' passed, ' + fail + ' failed ==');
process.exit(fail === 0 ? 0 : 1);
NODE

echo ""
echo "-- the subagentStart/subagentStop hook drives the same sidecar --"
HOOK="$ROOT/hooks/optimus-subagent-cursor.js"
DIR="$PROJECT/.optimus/state/active-subagents"
pass=0
fail=0

start_payload() {
  printf '{"hook_event_name":"subagentStart","conversation_id":"conv-sub","parent_conversation_id":"conv-main","subagent_id":"tooluse-9","tool_call_id":"tooluse-9","cwd":"%s"}' "$PROJECT"
}
stop_payload() {
  printf '{"hook_event_name":"subagentStop","conversation_id":"conv-sub","parent_conversation_id":"conv-main","subagent_id":"tooluse-9","cwd":"%s"}' "$PROJECT"
}

out="$(start_payload | node "$HOOK")"
if echo "$out" | grep -q '"permission":"allow"'; then
  echo "PASS: subagentStart emits allow"; pass=$((pass+1))
else
  echo "FAIL: subagentStart did not emit allow -- $out"; fail=$((fail+1))
fi
if [ "$(cat "$DIR/tooluse-9" 2>/dev/null)" == "conv-main" ]; then
  echo "PASS: subagentStart recorded the parent conversation"; pass=$((pass+1))
else
  echo "FAIL: marker missing or wrong -- $(ls -1 "$DIR" 2>/dev/null)"; fail=$((fail+1))
fi
stop_payload | node "$HOOK" >/dev/null
if [ ! -e "$DIR/tooluse-9" ]; then
  echo "PASS: subagentStop cleared the marker"; pass=$((pass+1))
else
  echo "FAIL: subagentStop left the marker behind"; fail=$((fail+1))
fi

echo ""
echo "-- an orphan subagentStop is harmless --"
if printf '{"hook_event_name":"subagentStop","subagent_id":"orphan-1","subagent_type":"unknown","status":"error","cwd":"%s"}' "$PROJECT" | node "$HOOK" | grep -q '"permission":"allow"'; then
  echo "PASS: orphan subagentStop allows"; pass=$((pass+1))
else
  echo "FAIL: orphan subagentStop misbehaved"; fail=$((fail+1))
fi

echo ""
echo "-- inactive project and kill switch write nothing --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$ROOT/bin/optimus-cli" off >/dev/null
start_payload | node "$HOOK" >/dev/null
if [ ! -e "$DIR/tooluse-9" ]; then
  echo "PASS: inactive project writes no marker"; pass=$((pass+1))
else
  echo "FAIL: wrote a marker while inactive"; fail=$((fail+1))
fi
CLAUDE_PROJECT_DIR="$PROJECT" node "$ROOT/bin/optimus-cli" on >/dev/null
start_payload | OPTIMUS_DISABLED=1 node "$HOOK" >/dev/null
if [ ! -e "$DIR/tooluse-9" ]; then
  echo "PASS: kill switch writes no marker"; pass=$((pass+1))
else
  echo "FAIL: wrote a marker with the kill switch on"; fail=$((fail+1))
fi

echo ""
echo "-- malformed stdin is harmless --"
if echo 'not json' | node "$HOOK" | grep -q '"permission":"allow"'; then
  echo "PASS: malformed payload allows"; pass=$((pass+1))
else
  echo "FAIL: malformed payload misbehaved"; fail=$((fail+1))
fi

echo ""
echo "== hook: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
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
 * One marker FILE per outstanding subagent — filename is the subagent's
 * id, contents are the parent's conversation id. Never one shared JSON
 * document: that would need read-modify-write, reopening exactly the
 * concurrency race hooks/optimus-ledger.js's append-only design avoids.
 * Two writers never touch the same path here.
 *
 * The filename is only a unique key so subagentStop can clear the right
 * entry. It is deliberately NOT treated as the subagent's conversation
 * id: the probe showed subagentStart.subagent_id is the parent's
 * tool_use_id for the Task call, and the subagent's own conversation id
 * is not knowable until its first tool call.
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
```

- [ ] **Step 4: Write `hooks/optimus-subagent-cursor.js`**

```js
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

  // subagent_id is the parent's tool_use_id for the Task call, and equals
  // tool_call_id. Either serves as the unique marker key; fall back
  // through them so a renamed field degrades to a still-unique key rather
  // than to no marker at all.
  const id = payload.subagent_id || payload.tool_call_id || payload.generation_id;

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
```

- [ ] **Step 5: Run the sidecar suite, then everything**

```bash
./tests/run-sidecar-tests.sh
./tests/run-core-tests.sh && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh \
  && ./tests/run-stats-tests.sh && ./tests/run-probe-report-tests.sh
```

Expected: `0 failed` everywhere. Nothing consumes the sidecar yet — Task 6's adapter does.

- [ ] **Step 6: Commit**

```bash
git add hooks/optimus-sidecar.js hooks/optimus-subagent-cursor.js tests/run-sidecar-tests.sh
git commit -m "feat: add Cursor subagent sidecar keyed on parent conversation id"
```

---

## Task 6: The Cursor `preToolUse` adapter

> **Revised after the Task 4 probe run.** Every tool name, `tool_input` key and payload field below
> is what Cursor 3.19.13 actually sent, recorded in `docs/cursor-probe-findings.md` — not a
> documented guess. Four probe results changed this task from its pre-probe form: `isSubagent` now
> comes from Task 5's sidecar rather than a payload field; `tool_input` keys are Cursor's real ones
> (`file_path`, not `path`); `Task`'s `tool_input.model` exists and can hold the string `inherit`,
> which must be rejected; and `model_id`/`model_params` are absent from `preToolUse` entirely.

**Files:**
- Create: `hooks/optimus-gate-cursor.js`
- Create: `tests/fixtures/cursor/main-read.json`
- Create: `tests/fixtures/cursor/subagent-read.json`
- Create: `tests/fixtures/cursor/subagent-start.json`
- Create: `tests/fixtures/cursor/subagent-stop.json`
- Create: `tests/fixtures/cursor/task-no-model.json`
- Create: `tests/fixtures/cursor/task-inherit-model.json`
- Create: `tests/fixtures/cursor/task-opus-model.json`
- Create: `tests/fixtures/cursor/task-cheap-model.json`
- Create: `tests/fixtures/cursor/main-shell-git.json`
- Create: `tests/fixtures/cursor/main-shell-cat.json`
- Create: `tests/fixtures/cursor/main-delete.json`
- Create: `tests/run-gate-cursor-tests.sh`

**Interfaces:**
- Consumes: `decide`, `ledgerEventFor`, `AGENT_DISPATCH`, `SHELL`, `REASON` from
  `hooks/optimus-core.js`; `isKillSwitchActive`, `getConfig` from `hooks/optimus-config.js`;
  `recordEvent` from `hooks/optimus-ledger.js`; `isSubagentConversation` from
  `hooks/optimus-sidecar.js` (Task 5).
- Produces: an executable hook at `hooks/optimus-gate-cursor.js`, registered on `preToolUse` by
  Task 7's `cursor/hooks.json`.

**Probe facts this task is built on** (all from `docs/cursor-probe-findings.md`):

| Fact | Consequence here |
|---|---|
| `Read`→`{file_path}`, `Write`→`{file_path, content}`, `Grep`→`{pattern, file_path, output_mode}`, `WebFetch`→`{url}`, `WebSearch`→`{search_term}`, `Delete`→`{file_path}`, `Shell`→`{command, cwd, timeout}`, `Task`→`{description, prompt, subagent_type, model}` | The tool map and the input normalizer below |
| No distinct `Edit` tool — a partial edit is a `Read` then a `Write` of the whole file | `Edit` stays in the map as inert future-proofing, with a comment saying it was not observed |
| No distinct glob tool — globbing is `Grep` with `pattern: ""` and `glob` set | `Glob` likewise inert; `Grep` already covers it |
| No notebook tool — `.ipynb` edits are `Read`+`Write` | `NotebookEdit` likewise inert |
| `Task`'s `tool_input.model` held the literal string `"inherit"` | **Must be rejected.** `inherit` means the subagent runs on the orchestrator's own expensive model — exactly what the no-model rule exists to prevent, and `/opus/i` does not match it |
| The *top-level* `model` on a `Task` payload was `""` | The dispatch model must come from `tool_input.model`, never the payload's `model` |
| `model_id` and `model_params` were absent from every `preToolUse` payload; `model` was the plain slug | `sessionModel` falls back from `model_id` to `model`; `modelConditional` must tolerate `model_id` being missing |
| `session_id` is present and equals `conversation_id` on every payload | Either can feed the ledger's `session_id`; use `conversation_id` as specified, since it is the field the spec names |
| `transcript_path` is `null` on a subagent's payload, a real path on the orchestrator's | Recorded in the fixtures for fidelity. Deliberately NOT used as a role signal: `null` also means "transcripts disabled", so trusting it would silently disable all enforcement for a user who turns transcripts off |
| Denying `Read` also blocks writes to existing files (Cursor issues an internal `Read` first) | No action: Optimus denies `Read` and `Write` together anyway. Documented in Task 9 |
| `WebSearch`/`WebFetch` emit follow-up `Write` calls to `~/.cursor/projects/<ws>/agent-tools/*.txt` | No action, and no path exemption: `WebFetch`/`WebSearch` are themselves denied in the orchestrator, so no cache write follows; inside a subagent the fetch and its cache write share the subagent's conversation and are both exempt. Documented in Task 9 |

**Fixtures carry no `user_email`.** Cursor sends one on every payload; the adapter never reads it
and the ledger must not start recording it without a deliberate decision, so it is left out of the
fixtures rather than baking a real address into the repository.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/cursor/main-read.json` — `cwd` and `workspace_roots` use the literal
`__PROJECT__` token, substituted by the harness, exactly as the Claude Code fixtures do:

```json
{
  "hook_event_name": "preToolUse",
  "conversation_id": "probe-conv-main",
  "session_id": "probe-conv-main",
  "generation_id": "probe-gen-1",
  "model": "claude-opus-5",
  "cursor_version": "3.19.13",
  "workspace_roots": ["__PROJECT__"],
  "transcript_path": "/tmp/does-not-exist.jsonl",
  "cwd": "__PROJECT__",
  "tool_name": "Read",
  "tool_input": { "file_path": "work.txt" },
  "tool_use_id": "toolu_bdrk_probe_main_1",
  "agent_message": "Reading work.txt"
}
```

`tests/fixtures/cursor/subagent-read.json` — the subagent's own conversation, and
`transcript_path: null` as observed:

```json
{
  "hook_event_name": "preToolUse",
  "conversation_id": "probe-conv-sub",
  "session_id": "probe-conv-sub",
  "generation_id": "probe-gen-2",
  "model": "cursor-grok-4.5-high",
  "cursor_version": "3.19.13",
  "workspace_roots": ["__PROJECT__"],
  "transcript_path": null,
  "cwd": "__PROJECT__",
  "tool_name": "Read",
  "tool_input": { "file_path": "work.txt" },
  "tool_use_id": "call-probe-sub-1",
  "agent_message": "Reading work.txt"
}
```

`tests/fixtures/cursor/subagent-start.json`:

```json
{
  "hook_event_name": "subagentStart",
  "conversation_id": "probe-conv-sub",
  "parent_conversation_id": "probe-conv-main",
  "subagent_id": "toolu_bdrk_probe_task_1",
  "tool_call_id": "toolu_bdrk_probe_task_1",
  "subagent_type": "explore",
  "cursor_version": "3.19.13",
  "cwd": "__PROJECT__"
}
```

`tests/fixtures/cursor/subagent-stop.json`:

```json
{
  "hook_event_name": "subagentStop",
  "conversation_id": "probe-conv-sub",
  "parent_conversation_id": "probe-conv-main",
  "subagent_id": "toolu_bdrk_probe_task_1",
  "subagent_type": "explore",
  "status": "completed",
  "cursor_version": "3.19.13",
  "cwd": "__PROJECT__"
}
```

The remaining seven are copies of `main-read.json` with these deltas and a distinct `tool_use_id`:

| Fixture | `tool_name` | `tool_input` |
|---|---|---|
| `task-no-model.json` | `Task` | `{"description":"read work.txt","prompt":"read work.txt","subagent_type":"explore"}` |
| `task-inherit-model.json` | `Task` | `{"description":"read work.txt","prompt":"read work.txt","subagent_type":"explore","model":"inherit"}` |
| `task-opus-model.json` | `Task` | `{"description":"read work.txt","prompt":"read work.txt","subagent_type":"explore","model":"claude-opus-5"}` |
| `task-cheap-model.json` | `Task` | `{"description":"read work.txt","prompt":"read work.txt","subagent_type":"explore","model":"claude-haiku-4-5"}` |
| `main-shell-git.json` | `Shell` | `{"command":"git status","cwd":"__PROJECT__","timeout":120000}` |
| `main-shell-cat.json` | `Shell` | `{"command":"cat work.txt","cwd":"__PROJECT__","timeout":120000}` |
| `main-delete.json` | `Delete` | `{"file_path":"work.txt"}` |

Note the `Task` fixtures keep the top-level `"model": "claude-opus-5"` from `main-read.json`
deliberately: the probe showed the top-level `model` on a real `Task` payload was `""`, and either
way it must not be what the dispatch check reads. `task-cheap-model.json` passing while the
top-level model is `claude-opus-5` is the assertion that proves the check reads
`tool_input.model`.

Create `tests/run-gate-cursor-tests.sh`:

```bash
#!/usr/bin/env bash
# Shape tests for hooks/optimus-gate-cursor.js.
#
# Deliberately shallow: the policy these payloads exercise already has
# direct coverage in tests/core-tests.js, and the sidecar has its own
# suite. These exist to catch parsing and shape-translation bugs at the
# Cursor boundary — a wrong tool-name mapping, a wrong tool_input key, a
# malformed permission JSON, a role decision read from the wrong place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/cursor"
GATE="$ROOT/hooks/optimus-gate-cursor.js"
SUBHOOK="$ROOT/hooks/optimus-subagent-cursor.js"
CLI="$ROOT/bin/optimus-cli"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT"

pass=0
fail=0

render() { sed "s#__PROJECT__#$PROJECT#g" "$FIXTURES/$1"; }

check() {
  local name="$1" expect="$2" fixture="$3" extra_env="${4:-}"
  local out decision
  out="$(render "$fixture" | env $extra_env node "$GATE")"
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
echo "-- inactive project: everything allows, with explicit allow JSON --"
check "inactive: main Read allowed"     allow main-read.json
check "inactive: Task no-model allowed" allow task-no-model.json

echo ""
echo "-- activating Optimus for $PROJECT --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" on

echo ""
echo "-- active, no dispatch outstanding: every conversation is the orchestrator --"
check "active: main Read DENIED"                 deny  main-read.json
check "active: subagent-shaped Read also DENIED" deny  subagent-read.json
check "active: Task w/o model DENIED"            deny  task-no-model.json
check "active: Task model=inherit DENIED"        deny  task-inherit-model.json
check "active: Task model=opus DENIED"           deny  task-opus-model.json
check "active: Task cheap model ALLOWED"         allow task-cheap-model.json
check "active: Shell git status ALLOWED"         allow main-shell-git.json
check "active: Shell cat DENIED"                 deny  main-shell-cat.json
check "active: Delete DENIED"                    deny  main-delete.json

echo ""
echo "-- with a dispatch outstanding: the subagent's conversation is exempt --"
render subagent-start.json | node "$SUBHOOK" >/dev/null
check "outstanding: subagent Read ALLOWED (exempt)" allow subagent-read.json
check "outstanding: orchestrator Read still DENIED" deny  main-read.json
render subagent-stop.json | node "$SUBHOOK" >/dev/null
check "after stop: subagent-shaped Read DENIED again" deny subagent-read.json

echo ""
echo "-- the deny payload carries both message fields --"
out="$(render main-read.json | node "$GATE")"
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
if render task-inherit-model.json | node "$GATE" | grep -qF 'inherit'; then
  echo "PASS: the inherit deny names the offending value"; pass=$((pass+1))
else
  echo "FAIL: the inherit deny does not mention inherit"; fail=$((fail+1))
fi

echo ""
echo "-- ledger: conversation_id maps onto session_id, shared event names --"
LEDGER="$PROJECT/.optimus/state/events.jsonl"
if grep -q '"session_id":"probe-conv-main"' "$LEDGER"; then
  echo "PASS: ledger session_id came from conversation_id"; pass=$((pass+1))
else
  echo "FAIL: ledger session_id not mapped"; fail=$((fail+1))
fi
for ev in work_tool_denied bash_nudge dispatch_denied dispatch_allowed; do
  if grep -q "\"ev\":\"$ev\"" "$LEDGER"; then
    echo "PASS: ledger wrote $ev"; pass=$((pass+1))
  else
    echo "FAIL: ledger never wrote $ev"; fail=$((fail+1))
  fi
done
if grep -q '"model":"claude-haiku-4-5"' "$LEDGER"; then
  echo "PASS: dispatch_allowed recorded the requested model verbatim"; pass=$((pass+1))
else
  echo "FAIL: requested model not recorded"; fail=$((fail+1))
fi
if grep -q '"user_email"' "$LEDGER"; then
  echo "FAIL: ledger recorded user_email"; fail=$((fail+1))
else
  echo "PASS: ledger did not record user_email"; pass=$((pass+1))
fi

echo ""
echo "-- malformed stdin fails OPEN with an explicit allow --"
out="$(echo 'not json at all' | node "$GATE")"
if echo "$out" | grep -q '"permission":"allow"'; then
  echo "PASS: malformed payload allows"; pass=$((pass+1))
else
  echo "FAIL: malformed payload did not fail open -- output: $out"; fail=$((fail+1))
fi

echo ""
echo "-- an unrecognized tool name fails open --"
if printf '{"hook_event_name":"preToolUse","conversation_id":"probe-conv-main","cwd":"%s","tool_name":"MCP:atlassian_search","tool_input":{}}' "$PROJECT" | node "$GATE" | grep -q '"permission":"allow"'; then
  echo "PASS: unknown tool allowed"; pass=$((pass+1))
else
  echo "FAIL: unknown tool was not allowed"; fail=$((fail+1))
fi

echo ""
echo "-- kill switch forces allow --"
check "kill switch: main Read ALLOWED" allow main-read.json "OPTIMUS_DISABLED=1"

echo ""
echo "-- deactivating --"
CLAUDE_PROJECT_DIR="$PROJECT" node "$CLI" off
check "deactivated: main Read allowed again" allow main-read.json

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
 * stdin shape, translates Cursor tool names and input keys into the
 * core's normalized vocabulary, decides via hooks/optimus-core.js, and
 * emits Cursor's permission JSON. No policy lives here.
 *
 * Cursor-specific plumbing that differs from Claude Code:
 *   - Output is {"permission":"allow"} / {"permission":"deny", ...}, and
 *     an allow is EXPLICIT (Claude Code allows by writing nothing).
 *   - Always exit 0. On Cursor, exit code 2 means deny — exiting 2 for an
 *     allow would block everything, silently.
 *   - The payload carries conversation_id where Claude Code carries
 *     session_id. The ledger field stays session_id on both hosts so
 *     bin/optimus-stats needs no host branching (spec Section 1.6).
 *   - Role is not on the payload. Cursor sends nothing that marks a call
 *     as a subagent's, so isSubagent comes from hooks/optimus-sidecar.js:
 *     a call whose conversation is a recorded dispatch parent is the
 *     orchestrator's, anything else while a dispatch is outstanding is a
 *     subagent's. See docs/cursor-probe-findings.md.
 *   - The payload carries a live `model`. It is passed as sessionModel
 *     but only consulted when a project sets modelConditional: true in
 *     .optimus/config.json. Off by default, so both hosts enforce on the
 *     same role-based basis out of the box.
 *
 * Fails OPEN on any internal error, same as the Claude Code gate. Cursor
 * ALSO fails open on a crash unless "failClosed": true is set per script
 * in hooks.json — confirmed empirically: a hook that exits non-zero with
 * no output is logged as "none returned a valid response" and the tool
 * call proceeds. So a bug here means enforcement silently does not apply
 * rather than blocking a user. That is consistent with Optimus's stated
 * philosophy and must stay documented, not discovered.
 */

const path = require('path');
const { isKillSwitchActive, getConfig } = require(
  path.join(__dirname, 'optimus-config.js')
);
const { recordEvent } = require(path.join(__dirname, 'optimus-ledger.js'));
const { isSubagentConversation } = require(path.join(__dirname, 'optimus-sidecar.js'));
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
 * Every mapping here was observed on Cursor 3.19.13 and is recorded in
 * docs/cursor-probe-findings.md, EXCEPT Edit, Glob and NotebookEdit:
 * Cursor has no distinct tool for any of the three (a partial edit is a
 * Read then a whole-file Write; globbing is Grep with an empty pattern
 * and a glob; a notebook edit is Read+Write on the .ipynb). They are kept
 * as inert future-proofing so that a Cursor version which does introduce
 * them starts being enforced rather than silently allowed.
 *
 * An unrecognized name deliberately passes through unchanged, lands
 * outside WORK_TOOLS, and is ALLOWED — failing open on vocabulary,
 * consistent with the rest of the plugin. Add an observed name here to
 * start denying it.
 */
const CURSOR_TOOL_MAP = {
  Task: AGENT_DISPATCH,
  Shell: SHELL,
  Read: 'Read',
  Write: 'Write',
  Grep: 'Grep',
  Delete: 'Delete',
  WebFetch: 'WebFetch',
  WebSearch: 'WebSearch',
  Edit: 'Edit',
  Glob: 'Glob',
  NotebookEdit: 'NotebookEdit',
};

/**
 * A dispatch model of "inherit" means the subagent runs on the
 * orchestrator's own model — exactly what the dispatch rule exists to
 * prevent, and EXPENSIVE_MODEL_RE does not match the word. It is treated
 * as "no model named", which is what it functionally is. Observed as the
 * real value Cursor's Task tool sends by default.
 */
const INHERIT_MODEL_RE = /^inherit$/i;

function normalizeTool(toolName) {
  if (typeof toolName !== 'string') return '';
  if (Object.prototype.hasOwnProperty.call(CURSOR_TOOL_MAP, toolName)) {
    return CURSOR_TOOL_MAP[toolName];
  }
  return toolName;
}

/**
 * Presents Cursor's raw tool_input under the key names the core reads:
 * model, subagent_type, command. Cursor's other input keys (file_path,
 * content, pattern, url, search_term) are never read by the core, so
 * non-dispatch, non-shell inputs pass through untouched.
 */
function normalizeInput(tool, rawInput) {
  const raw = rawInput && typeof rawInput === 'object' ? rawInput : {};
  if (tool === AGENT_DISPATCH) {
    const requested = typeof raw.model === 'string' ? raw.model.trim() : '';
    return {
      // Deliberately NOT payload.model: the probe showed the top-level
      // model on a Task payload is the empty string.
      model: INHERIT_MODEL_RE.test(requested) ? undefined : raw.model,
      subagent_type: raw.subagent_type,
    };
  }
  if (tool === SHELL) {
    return { command: raw.command };
  }
  return raw;
}

/** Cursor-facing deny text. Generic model tiers, never Anthropic aliases. */
function denyMessages(decision) {
  switch (decision.reason) {
    case REASON.NO_MODEL_SET:
      return {
        user_message: 'Optimus blocked a subagent dispatch that named no usable model.',
        agent_message:
          'Optimus: this Task dispatch names no model of its own (an absent model, or ' +
          'model="inherit"), so it would run on the same expensive model as this session ' +
          'instead of running cheaper. Re-dispatch with an explicit model: a cheap/fast model ' +
          'for simple, mechanical work (file lookups, boilerplate edits, running a command and ' +
          'reporting its output), and a stronger model only for work that genuinely needs ' +
          'judgement. Never dispatch a subagent on the same expensive model driving this session.',
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

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return allow();
  }
  if (!cfg.enabled) return allow();

  // Role comes from the sidecar, not the payload. Checked after the
  // activation gate rather than before it, because unlike Claude Code's
  // agent_id field this costs a directory read — and there is nothing to
  // exempt in a project where Optimus is not active anyway.
  //
  // Deliberately NOT wrapped in a local try/catch. isSubagentConversation
  // never throws by contract, and if it somehow did, the right response is
  // the file-wide one: the top-level handler emits an explicit allow. A
  // local catch would have to pick a direction, and both are wrong here —
  // "enforce" deadlocks a real subagent (the exact failure the spec warns
  // loudest about) and "exempt" silently switches enforcement off. Letting
  // it reach the outer handler keeps one fail-open policy for the whole
  // file instead of two.
  if (isSubagentConversation(payload.cwd, payload.conversation_id)) return allow();

  const tool = normalizeTool(payload.tool_name);
  const toolInput = normalizeInput(tool, payload.tool_input);

  const decision = decide({
    tool: tool,
    toolInput: toolInput,
    isSubagent: false,
    // model_id was absent from every preToolUse payload observed, despite
    // being documented; model carried the plain slug. Fall back.
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

One deliberate consequence of rejecting `inherit` through `normalizeInput`: the ledger records
`dispatch_denied` with `reason: 'no_model'` for it, and no `model` field, because the core sees an
absent model. That keeps the ledger's vocabulary and `bin/optimus-stats`' reader unchanged. The
user-facing message names `model="inherit"` explicitly so the distinction is not lost where it
matters.

- [ ] **Step 4: Run the Cursor suite**

```bash
./tests/run-gate-cursor-tests.sh
```

Expected: `0 failed`.

- [ ] **Step 5: Run every suite — the Claude Code build must be untouched**

```bash
./tests/run-core-tests.sh && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh \
  && ./tests/run-stats-tests.sh && ./tests/run-probe-report-tests.sh \
  && ./tests/run-sidecar-tests.sh && ./tests/run-gate-cursor-tests.sh
```

Expected: `0 failed` in all seven.

- [ ] **Step 6: Commit**

```bash
git add hooks/optimus-gate-cursor.js tests/fixtures/cursor tests/run-gate-cursor-tests.sh
git commit -m "feat: add Cursor preToolUse adapter over the shared policy core"
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
    ],
    "subagentStart": [
      { "command": "node \"__OPTIMUS_ROOT__/hooks/optimus-subagent-cursor.js\"" }
    ],
    "subagentStop": [
      { "command": "node \"__OPTIMUS_ROOT__/hooks/optimus-subagent-cursor.js\"" }
    ]
  }
}
```

All four events are unconditional: the probe landed on row 2, so the sidecar is the only thing that
tells a subagent's calls apart from the orchestrator's, and without `subagentStart`/`subagentStop`
the gate would enforce against every subagent Optimus dispatches.

**Schema facts this file relies on, all established empirically in
`docs/cursor-probe-findings.md` — do not "improve" any of them:**

- `"version": 1` and the flat `hooks.<eventName>[].command` shape are accepted as written.
- `matcher` is optional and, when present, is a regex over the tool name. It is deliberately
  omitted here: the gate must see every tool, and it decides for itself which ones it cares about.
- **Do NOT use `${workspaceFolder}`.** It is a VS Code editor variable, not a hook variable: in a
  Cursor hook command it expands to the empty string, producing `node "/hooks/..."` and a
  `MODULE_NOT_FOUND` that logs nothing at all — indistinguishable from a hook that never
  registered. `${CURSOR_PLUGIN_ROOT}`, `${PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_ROOT}` are all empty
  in a project hook too. Only `${CURSOR_PROJECT_DIR}` and `${CLAUDE_PROJECT_DIR}` resolve there,
  both to the workspace root — which is not where Optimus's scripts live, hence the absolute path
  rendered by Task 8.
- Multiple entries on one event all run, and Cursor merges their responses.
- Cursor watches `hooks.json` and reloads it on **write**; no window reload is needed. But
  **deleting** the file does not deregister its hooks — only a write is watched. Anything that
  needs to turn these hooks off must overwrite with `{"version": 1, "hooks": {}}`, never unlink.
- Project and User hooks are merged, not overridden, so installing this does not disable a user's
  own `~/.cursor/hooks.json` hooks.

`beforeShellExecution` is deliberately **not** registered. The spec notes it is the more idiomatic Cursor hook for shell interception, but `preToolUse` already sees `Shell` calls, and registering both would double-fire the same policy and write the ledger twice for one command. Revisit only if the probe shows `preToolUse` does not fire for shell calls — and if so, record that in the findings file first.

- [ ] **Step 7: Commit**

```bash
git add cursor/optimus.mdc cursor/hooks.json hooks/optimus-session-cursor.js tests/run-session-cursor-tests.sh
git commit -m "feat: add Cursor reinforcement surface (alwaysApply rule + sessionStart hook)"
```

---

## Task 8: `optimus-cli install cursor`

**Files:**
- Modify: `hooks/optimus-config.js` (extract and export the atomic-write-refusing-symlinks primitive)
- Modify: `bin/optimus-cli`
- Create: `tests/run-install-tests.sh`

> **Amended after the Task 8 review.** The first draft of this task had `bin/optimus-cli` carry its
> own copy of the symlink-refusing atomic write, because `hooks/optimus-config.js` was a protected
> file. The reviewer correctly called that out: it duplicates the single most security-relevant
> primitive in the plugin across two files that can silently drift. So this task now extracts it
> instead. `hooks/optimus-config.js` is unprotected **for this one extraction only** — `setConfig`'s
> observable behaviour must not change, and `run-gate-tests.sh` and `run-ledger-tests.sh` both
> exercise it through `bin/optimus-cli on`/`off`, so they are the regression check. (`run-stats-tests.sh`
> does NOT — `bin/optimus-stats` imports only `findProjectRoot` and `CONFIG_DIRNAME` from
> `optimus-config.js` and never calls `setConfig`.)

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

# --- an unreadable existing hooks.json must NOT be silently replaced ----
# Treating "cannot read it" as "it is not there" would skip the overwrite
# refusal, and rename() only needs write permission on the DIRECTORY — so the
# user's own file would be replaced without them ever being asked.
W7="$(mktemp -d)"; P7="$W7/project"; mkdir -p "$P7/.cursor"
echo '{"version":1,"hooks":{"preToolUse":[{"command":"node theirs.js"}]}}' > "$P7/.cursor/hooks.json"
chmod 000 "$P7/.cursor/hooks.json"
if CURSOR_PROJECT_DIR="$P7" node "$CLI" install cursor >"$W7/out.txt" 2>&1; then
  bad "install succeeded over an unreadable hooks.json"
else
  ok "refuses when the existing hooks.json cannot be read"
fi
chmod 644 "$P7/.cursor/hooks.json"
grep -q 'theirs.js' "$P7/.cursor/hooks.json" && ok "left the unreadable file untouched" || bad "replaced the unreadable file"
grep -qi 'install failed' "$W7/out.txt" && ok "prints a reason, not a stack trace" || bad "no clean failure message: $(cat "$W7/out.txt")"
grep -q 'at Object' "$W7/out.txt" && bad "dumped a stack trace at the user" || ok "no stack trace in output"

# --- a dangling symlink at the target fails cleanly ---------------------
W8="$(mktemp -d)"; P8="$W8/project"; mkdir -p "$P8/.cursor"
ln -s "$W8/nonexistent.json" "$P8/.cursor/hooks.json"
if CURSOR_PROJECT_DIR="$P8" node "$CLI" install cursor >"$W8/out.txt" 2>&1; then
  bad "install succeeded through a dangling symlink"
else
  ok "refuses a dangling symlink at the target"
fi
[ -L "$P8/.cursor/hooks.json" ] && ok "left the dangling symlink in place" || bad "removed the symlink"
[ -e "$W8/nonexistent.json" ] && bad "wrote through the dangling symlink" || ok "did not write through the dangling symlink"
grep -qi 'refusing to write through a symlink' "$W8/out.txt" && ok "names the symlink as the reason" || bad "unclear reason: $(cat "$W8/out.txt")"

rm -rf "$W" "$W2" "$W3" "$W4" "$W5" "$W6" "$W7" "$W8"

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

- [ ] **Step 3: Extract the shared write primitive in `hooks/optimus-config.js`**

`setConfig` already contains the exact write `bin/optimus-cli` needs. Lift it out rather than
copying it. Replace the body of `setConfig` from its `try { const lst = fs.lstatSync(target); ... }`
block through the `fs.renameSync(tmp, target);` line with a single call, and add the extracted
function above it:

```js
/**
 * Write `contents` to `target` atomically, refusing to follow a pre-existing
 * symlink there.
 *
 * The symlink check is a cheap defence against a local symlink-plant aimed at
 * tricking Optimus into writing through a link somewhere else; the temp-file-
 * then-rename makes the replacement atomic so a reader never sees a partial
 * file. Throws on a symlink at the target, and on any fs error other than the
 * target simply not existing yet — callers decide how to present that.
 *
 * Exported because `bin/optimus-cli install cursor` writes into a user's
 * project and needs exactly these two properties. It must never be duplicated:
 * this is the most security-relevant primitive in the plugin, and two copies
 * drift.
 */
function writeFileAtomicRefusingSymlink(target, contents, mode) {
  try {
    const lst = fs.lstatSync(target);
    if (lst.isSymbolicLink()) {
      throw new Error('Optimus: refusing to write through a symlink at ' + target);
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }

  const tmp = target + '.tmp-' + process.pid + '-' + Date.now();
  fs.writeFileSync(tmp, contents, { mode: typeof mode === 'number' ? mode : 0o600, flag: 'wx' });
  fs.renameSync(tmp, target);
}
```

`setConfig`'s write becomes:

```js
  writeFileAtomicRefusingSymlink(target, payload);
```

and `writeFileAtomicRefusingSymlink` joins the `module.exports` list. Nothing else in
`hooks/optimus-config.js` changes — `setConfig`'s signature, its return value, its
`mkdirSync`, and its payload construction all stay exactly as they are. Its observable behaviour
must be identical, which `run-gate-tests.sh` and `run-ledger-tests.sh` between them prove — both
drive `bin/optimus-cli on`/`off`, which is the only caller of `setConfig`.

- [ ] **Step 4: Extend `bin/optimus-cli`**

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
    // ENOENT is the clean path: there is nothing there to protect. Anything
    // else (EACCES on a file we may not read, EISDIR, a dangling symlink's
    // own ENOENT is indistinguishable and handled below) must NOT be
    // swallowed: treating an unreadable file as absent would skip the
    // overwrite refusal and let the rename replace it, which is exactly the
    // guarantee this command exists to make.
    if (e.code !== 'ENOENT') throw e;
  }
  const isOurs = existing !== null && existing.indexOf('optimus-gate-cursor.js') !== -1;

  if (existing !== null && !isOurs && !force) {
    const suggested = hooksTarget + '.optimus-suggested';
    writeFileAtomicRefusingSymlink(suggested, rendered);
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
    fs.unlinkSync(hooksTarget); // the shared writer uses flag 'wx'
  }
  writeFileAtomicRefusingSymlink(hooksTarget, rendered);

  try {
    fs.unlinkSync(ruleTarget);
  } catch (e) {
    // not there yet
  }
  writeFileAtomicRefusingSymlink(ruleTarget, rule);

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
      try {
        installCursor(force);
      } catch (e) {
        // A refusal (a symlink at a target path, an unreadable existing
        // hooks.json) is a legitimate outcome, not a crash. Print the reason
        // and exit non-zero rather than dumping a stack trace at the user.
        console.log('Optimus: install failed — ' + (e && e.message ? e.message : e));
        process.exit(1);
      }
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

- [ ] **Step 5: Run the install suite plus every other suite**

```bash
./tests/run-install-tests.sh
./tests/run-core-tests.sh && ./tests/run-gate-tests.sh && ./tests/run-ledger-tests.sh \
  && ./tests/run-stats-tests.sh && ./tests/run-probe-report-tests.sh \
  && ./tests/run-gate-cursor-tests.sh && ./tests/run-session-cursor-tests.sh
```

Expected: `0 failed` in all of them. `run-gate-tests.sh` and `run-stats-tests.sh` exercise the CLI's `on`/`off` path, so they are the regression check on the changed `cwd` resolution.

- [ ] **Step 6: Verify the real install end to end in Cursor**

```bash
# in the scratch Cursor project from Task 4
node <plugin>/bin/optimus-cli install cursor
node <plugin>/bin/optimus-cli on
```

Reload the Cursor window, then in the main agent panel ask it to read a file. Expected: the read is denied and the agent is told to use the Task tool. Then confirm `.optimus/state/events.jsonl` in that project gained a `work_tool_denied` line. Record the result — a pass here is the first end-to-end proof the port works; a fail sends you back to `docs/cursor-probe-findings.md`, not to guesswork.

- [ ] **Step 7: Commit**

```bash
git add hooks/optimus-config.js bin/optimus-cli tests/run-install-tests.sh
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

- [ ] **Step 3: Correct the probe kit against what the probe actually found**

The kit shipped in Task 3 contains one defect that would trap the next person to run it, plus two
procedural errors. All three are recorded in `docs/cursor-probe-findings.md`.

In `cursor/probe/hooks.probe.json`, replace the `${workspaceFolder}` command path — it expands to
the empty string in a Cursor hook and fails with `MODULE_NOT_FOUND`, logging nothing, which is
exactly the "if nothing landed, stop here" trap the README warns about. Use a project-root-relative
path, and add the `matcher` that keeps the analyser's own `Shell` calls out of the log:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "command": "node \".cursor/probe/probe.js\"", "matcher": "Read" }
    ],
    "subagentStart": [
      { "command": "node \".cursor/probe/probe.js\"" }
    ],
    "subagentStop": [
      { "command": "node \".cursor/probe/probe.js\"" }
    ]
  }
}
```

In `cursor/probe/README.md`:

- Step 4 ("reload the Cursor window so the hook registers") is wrong — Cursor reloads `hooks.json`
  on write. Replace it with: "save the file and allow a couple of seconds to settle; Cursor watches
  `hooks.json` and reloads on write. No window reload is needed. Note that **deleting**
  `hooks.json` does NOT deregister its hooks — to turn them off, write `{"version": 1, "hooks": {}}`."
- Step 7 (dispatch the `file-reader` subagent) needs a note that project-level agent definitions in
  `.cursor/agents/` do NOT hot-reload, so a freshly written one is rejected with an
  `Invalid enum value` listing the built-in types. Either reload the window or use a built-in type
  such as `explore`, which answers the Unknown-1 question identically.
- Add to "Before you start": the fastest debugging surface is Cursor's own hooks log at
  `~/Library/Application Support/Cursor/logs/<session>/window<N>/output_<ts>/cursor.hooks.workspaceId-<id>.log`,
  which records `INPUT`, `OUTPUT` and `STDERR` per invocation.
- Add to the Unknown-2 section: clear or move `probe-root.log` between Pass A and Pass B, otherwise
  a `__dirname`-only result cannot be attributed to either variable. (Deferred minor from Task 3's
  review.)

Then re-run `./tests/run-probe-report-tests.sh` — it does not read these files, so it must still
pass unchanged.

- [ ] **Step 4: Update `README.md`**

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

**(d)** Add these probe-established facts to the Cursor section. They are the things a user or a
future maintainer cannot work out from the code, and every one of them cost a probe run to learn.
Sources: `docs/cursor-probe-findings.md`.

```markdown
### How Optimus tells your subagents apart on Cursor

Cursor sends nothing on a tool-call hook that marks the call as a subagent's — the payload from a
subagent is shaped exactly like the orchestrator's. What it does send is `conversation_id`, and a
subagent gets its own. So Optimus records the dispatching conversation for the lifetime of each
subagent (`subagentStart` → `subagentStop`, one small file per outstanding subagent under
`.optimus/state/active-subagents/`) and treats any *other* conversation as a subagent's while a
dispatch is outstanding. That is exact per-call attribution, and it is safe with any number of
subagents running at once.

Two limits worth knowing:

- **Two Cursor windows on the same project.** If window A has a subagent outstanding, window B's
  own tool calls look like a subagent's and are not enforced. Fail-open, and the kill switch or
  `/optimus off` behave normally.
- **A subagent that dispatches its own subagent** would have its own calls enforced. Nested
  dispatch was not observed on Cursor 3.19.13 and is not supported by this build.

### Cursor quirks Optimus works around

- **Denying `Read` also blocks writes to files that already exist**, because Cursor issues an
  internal `Read` of the target before a `Write`. This is not something Optimus can separate;
  read-scoped and write-scoped policy are not independent on Cursor. It does not change anything
  for Optimus, which denies both in the orchestrator anyway.
- **Web search and URL fetch write to a cache** under
  `~/.cursor/projects/<workspace>/agent-tools/`, and those writes fire the tool hook as `Write`.
  Optimus needs no path exemption for them: `WebFetch`/`WebSearch` are themselves delegated work,
  so the orchestrator never gets as far as the cache write, and inside a subagent both the fetch
  and its cache write are exempt.
- **Turning the hooks off means writing an empty config, not deleting the file.** Cursor watches
  `.cursor/hooks.json` for writes and reloads on save — no window reload needed — but deleting it
  does not deregister anything. `{"version": 1, "hooks": {}}` clears them.
- **Debugging the gate:** Cursor writes every hook invocation, with `INPUT`, `OUTPUT` and
  `STDERR`, to
  `~/Library/Application Support/Cursor/logs/<session>/window<N>/output_<ts>/cursor.hooks.workspaceId-<id>.log`.
  Start there, not with guesswork. Re-verify the findings in `docs/cursor-probe-findings.md` from
  that log after a Cursor upgrade.
- **A dispatch with `model: "inherit"` is blocked**, the same as one that names no model at all —
  `inherit` means the subagent runs on the orchestrator's expensive model, which is the exact thing
  the rule exists to prevent.

### If you have the Claude Code plugin installed and you use Cursor

Cursor reads Claude Code plugin manifests. With no `.cursor/hooks.json` at all, it finds Optimus's
`hooks/hooks.json`, maps `PreToolUse` onto its own `preToolUse`, resolves `${CLAUDE_PLUGIN_ROOT}`,
and runs `hooks/optimus-gate.js` on every matched tool call.

**That hook is a silent no-op on Cursor, and its deny path fails open.** Its allow path is Claude
Code's "emit nothing", which Cursor also reads as allow, so allows happen to work. But a deny emits
`hookSpecificOutput.permissionDecision: "deny"`, which Cursor does not understand — it logs "none
returned a valid response" and lets the call through. So if you have the plugin and you are working
in Cursor, you are not enforced until you run `optimus-cli install cursor`, and nothing warns you.
```

- [ ] **Step 5: Bump the version**

In `.claude-plugin/plugin.json`, change `"version": "0.2.0"` to `"version": "0.3.0"`, and add `"cursor"` to the `keywords` array.

- [ ] **Step 6: Verify**

```bash
./tests/run-all.sh
node -e 'const p=require("./.claude-plugin/plugin.json"); console.log(p.version, p.keywords.join(","))'
```

Expected: `ALL SUITES PASSED`, then `0.3.0 orchestration,cost,subagents,hooks,delegation,cursor`.

- [ ] **Step 7: Commit**

```bash
git add tests/run-all.sh README.md .claude-plugin/plugin.json cursor/probe
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

Task order: **1 → 2 → 3 → 4 (human) → 5 → 6 → 7 → 8 → 9**. Tasks 5 and 6 were rewritten after the probe; Task 5 is now the sidecar and Task 6 the adapter, and both are unconditional because the probe landed on row 2.

Tasks 1–2 and Task 3 are independent of each other and may run in parallel. Task 4 is a hard checkpoint — an agent must hand back there.
