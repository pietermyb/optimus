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
const {
  isKillSwitchActive,
  getConfig,
  getExpensiveModelRe,
  getGatedTools,
  getShellBypassPatterns,
} = require(path.join(__dirname, 'optimus-config.js'));

const { consumeAllowance } = require(path.join(__dirname, 'optimus-allowance.js'));
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
  const projectDir = cfg.root || payload.cwd;
  const gatedTools = getGatedTools(projectDir);
  if (!cfg.raw || !Array.isArray(cfg.raw.gatedTools)) {
    gatedTools.add('Delete');
  }
  const policy = {
    gatedTools: gatedTools,
    expensiveModelRe: getExpensiveModelRe(projectDir),
    shellBypassPatterns: getShellBypassPatterns(projectDir),
  };

  // Claude Code gives us a stable session key but no generation/turn key.
  // Without a trustworthy boundary signal, an inline-allowance counter
  // cannot honestly reset per turn, so strict deny behaviour is preserved.
  const hasTurnKey =
    typeof payload.session_id === 'string' &&
    payload.session_id.trim() !== '' &&
    typeof payload.generation_id === 'string' &&
    payload.generation_id.trim() !== '';

  const allowanceConsumer = hasTurnKey
    ? () =>
        consumeAllowance({
          cwd: payload.cwd,
          conversationId: payload.session_id,
          generationId: payload.generation_id,
          inlineAllowancePerTurn: cfg.inlineAllowancePerTurn,
        })
    : undefined;

  // Claude Code payloads carry no model field, and the one indirect
  // route (polling the transcript) races this hook's own invocation —
  // see limitations.md. Always null here.
  const decision = decide({
    tool: tool,
    toolInput: toolInput,
    isSubagent: false,
    sessionModel: null,
    consumeAllowance: allowanceConsumer,
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
