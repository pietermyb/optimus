#!/usr/bin/env node
'use strict';

/**
 * PreToolUse hook — the actual enforcement point.
 *
 * Order of checks matters and is deliberate:
 *   0. Kill switch (OPTIMUS_DISABLED) — always first, always wins.
 *   1. Subagent exemption — MUST come before anything else. A payload
 *      carrying `agent_id`/`agent_type` originates inside a dispatched
 *      subagent, not the orchestrator, and is allowed unconditionally.
 *      Getting this order wrong blocks every worker Optimus dispatches
 *      and inverts the entire point of the plugin. See README + the
 *      research notes this was built from for why session_id cannot be
 *      used for this instead (it's identical for main session and every
 *      subagent it spawns).
 *   2. Per-project activation — if Optimus isn't turned on for this
 *      project (`/optimus on`), every call is allowed.
 *   3. Agent dispatch must name a non-expensive model.
 *   4. Work tools (Read/Edit/Write/Grep/Glob/WebFetch/WebSearch/NotebookEdit)
 *      are denied in the main session.
 *   5. Bash: best-effort pattern match against obvious read-as-bypass
 *      commands. This is explicitly NOT a security boundary — see README.
 *
 * Fails OPEN on any internal error (malformed payload, config read
 * failure, etc.) — a bug in this hook must never wedge a session.
 */

const path = require('path');
const {
  isKillSwitchActive,
  getConfig,
  WORK_TOOLS,
  EXPENSIVE_MODEL_RE,
} = require(path.join(__dirname, 'optimus-config.js'));

// Best-effort patterns for "this Bash command is really just a file read/search,
// dressed up to dodge the Read/Grep/etc. denial". Deliberately narrow and
// conservative — false negatives are expected and accepted (see README);
// the goal is raising the cost of the *casual, unprompted* bypass observed
// during testing (a model's first instinct for "read a file" was `cat`),
// not building a wall.
const BASH_READ_PATTERNS = [
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

  // Rule 1 — subagent exemption. Load-bearing; must stay first.
  if (payload.agent_id || payload.agent_type) {
    return allow();
  }

  const toolName = payload.tool_name;
  const toolInput = payload.tool_input || {};

  let cfg;
  try {
    cfg = getConfig(payload.cwd);
  } catch (e) {
    return allow(); // a bug in our own config resolution must not wedge the session
  }
  if (!cfg.enabled) return allow();

  // Rule 3 — Agent dispatch must name a model, and it must not be the expensive tier.
  if (toolName === 'Agent') {
    const model = toolInput.model;
    if (typeof model !== 'string' || model.trim() === '') {
      return deny(
        'Optimus: this Agent dispatch has no tool_input.model set, which means it would ' +
          "silently inherit the orchestrator's own (expensive) model instead of running cheaper. " +
          'Re-dispatch and pass model explicitly: use "haiku" for simple/mechanical work ' +
          '(file lookups, boilerplate edits, running a command and reporting its output), ' +
          'or "sonnet" for anything that needs real judgement (ambiguous requirements, design ' +
          'tradeoffs, non-trivial debugging). Never omit model, and never dispatch on opus.'
      );
    }
    if (EXPENSIVE_MODEL_RE.test(model)) {
      return deny(
        'Optimus: this Agent dispatch names model="' +
          model +
          '", the expensive tier — dispatching a subagent on the same expensive model as the ' +
          'orchestrator defeats the point of delegating. Re-dispatch with model="haiku" for ' +
          'simple/mechanical work, or model="sonnet" for anything needing real judgement.'
      );
    }
    return allow();
  }

  // Rule 4 — work tools denied in the main session while Optimus is active.
  if (WORK_TOOLS.has(toolName)) {
    return deny(
      'Optimus: the ' +
        toolName +
        ' tool is blocked in the orchestrator session while Optimus is active for this project. ' +
        'Delegate this work with the Agent tool instead: pass model="haiku" for simple/mechanical ' +
        'work, or model="sonnet" for anything needing real judgement. Run `/optimus off` if you ' +
        'need to work in this session directly.'
    );
  }

  // Rule 5 — Bash: best-effort speed bump only, not a security boundary.
  if (toolName === 'Bash') {
    const command = typeof toolInput.command === 'string' ? toolInput.command : '';
    for (const pattern of BASH_READ_PATTERNS) {
      if (pattern.test(command)) {
        return deny(
          'Optimus: this Bash command ("' +
            command.slice(0, 160) +
            '") looks like a plain file read or search, which should go through a delegated ' +
            'subagent instead of the orchestrator running it directly. Use the Agent tool ' +
            '(model="haiku" is usually enough for a simple lookup). Note: this is a best-effort ' +
            'pattern match, not a hard boundary — git/build/test/flash and other orchestration ' +
            'commands are never blocked.'
        );
      }
    }
    return allow();
  }

  return allow();
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
