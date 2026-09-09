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
