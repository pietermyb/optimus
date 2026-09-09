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
 *   3. Dispatch must name a non-expensive model.
 *   4. Optional model-conditional exemption (off by default) — waives
 *      only the two checks below it (work tools, shell speed bump),
 *      never the dispatch-model rule above it. See the comment on that
 *      block for why.
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

  // 3 — dispatch must name a model, and it must not be the expensive tier.
  // Runs BEFORE the model-conditional exemption below, and must always:
  // the dispatch rule exists to stop expensive tokens being burned in the
  // *subagent*, which is orthogonal to what the orchestrator itself is
  // running on. A cheap orchestrator dispatching an expensive model is
  // exactly the waste Optimus exists to prevent, so no exemption keyed on
  // the orchestrator's own role or model may waive it.
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

  // 4 — optional model-conditional exemption. Off unless a project opts
  // in, so both hosts enforce on the same (role-based) basis by default.
  // A missing/unknown sessionModel deliberately enforces rather than
  // exempts: "we could not tell" must not become "you are exempt".
  //
  // Placed AFTER the dispatch-model check above, not before it: this
  // exemption only ever reaches the two checks below it (work tools, the
  // shell speed bump). It must never be able to waive the dispatch rule
  // — see the comment on step 3 for why that guarantee has to hold
  // regardless of what model the orchestrator is running on.
  if (
    cfg.modelConditional &&
    typeof sessionModel === 'string' &&
    sessionModel.trim() !== '' &&
    !EXPENSIVE_MODEL_RE.test(sessionModel)
  ) {
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
