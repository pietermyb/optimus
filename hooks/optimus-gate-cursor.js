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
const {
  isKillSwitchActive,
  getConfig,
  getExpensiveModelRe,
  getGatedTools,
  getGatedToolPatterns,
  getShellBypassPatterns,
} = require(path.join(__dirname, 'optimus-config.js'));

const { recordEvent } = require(path.join(__dirname, 'optimus-ledger.js'));
const { consumeAllowance } = require(path.join(__dirname, 'optimus-allowance.js'));
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
  const projectDir = cfg.root || payload.cwd;
  const policy = {
    gatedTools: getGatedTools(projectDir),
    gatedToolPatterns: getGatedToolPatterns(projectDir),
    expensiveModelRe: getExpensiveModelRe(projectDir),
    shellBypassPatterns: getShellBypassPatterns(projectDir),
  };

  const decision = decide({
    tool: tool,
    toolInput: toolInput,
    isSubagent: false,
    consumeAllowance: () =>
      consumeAllowance({
        cwd: payload.cwd,
        conversationId: payload.conversation_id,
        generationId: payload.generation_id,
        inlineAllowancePerTurn: cfg.inlineAllowancePerTurn,
      }),
    // model_id was absent from every preToolUse payload observed, despite
    // being documented; model carried the plain slug. Fall back.
    sessionModel: typeof payload.model_id === 'string' ? payload.model_id : payload.model,
    config: cfg.raw && cfg.raw.modelConditional
      ? {
          enabled: true,
          modelConditional: true,
          inlineAllowancePerTurn: cfg.inlineAllowancePerTurn,
        }
      : { enabled: true, inlineAllowancePerTurn: cfg.inlineAllowancePerTurn },
    policy: policy,
  });

  const event = ledgerEventFor({ tool: tool, toolInput: toolInput, decision: decision });
  if (event) {
    const base = {
      session_id: payload.conversation_id,
      tool_use_id: payload.tool_use_id,
    };
    if (event.ev === 'work_tool_inline_allowed') {
      base.generation_id = payload.generation_id;
    }
    recordEvent(payload.cwd, Object.assign(base, event));
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
