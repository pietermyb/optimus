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
