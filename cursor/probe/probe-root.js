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
