#!/usr/bin/env node
'use strict';

/**
 * Claude Code hook payload logger. Always allows; logs one JSON line per
 * invocation to probe.log next to this file, then emits {} and exits 0
 * for every hook event (SessionStart / PostToolUse / PostToolUseFailure).
 *
 * Mirrors cursor/probe/probe.js: dependency-free and defensive — this
 * runs inside a real Claude Code session, and a crash here would make
 * the probe itself the thing under investigation.
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
      CLAUDE_PROJECT_DIR: process.env.CLAUDE_PROJECT_DIR || null,
      CLAUDE_CODE_SESSION_ID: process.env.CLAUDE_CODE_SESSION_ID || null,
      CLAUDE_CODE_TOOL_USE_ID: process.env.CLAUDE_CODE_TOOL_USE_ID || null,
      CLAUDE_MODEL: process.env.CLAUDE_MODEL || null,
      CLAUDE_CODE_SSE_PORT: process.env.CLAUDE_CODE_SSE_PORT || null,
      CLAUDE_PLUGIN_ROOT: process.env.CLAUDE_PLUGIN_ROOT || null,
    },
    dirname: __dirname,
    argv: process.argv,
    stdin: stdin,
  };
  try {
    fs.appendFileSync(LOG_PATH, JSON.stringify(entry) + '\n');
  } catch (e) {
    // logging failure must not affect the hook
  }
  process.stdout.write('{}');
  process.exit(0);
});

process.stdin.on('error', () => {
  process.stdout.write('{}');
  process.exit(0);
});
