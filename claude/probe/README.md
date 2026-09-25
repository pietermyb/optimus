# Claude Code probe kit

Answers the three payload questions the agent-map work needs before any
Claude-side lifecycle writer is written (same discipline as
`cursor/probe/README.md`):

| # | Question | Why it blocks |
|---|---|---|
| CP1 | `PostToolUse` on the `Agent` tool: `tool_use_id`? `duration_ms`? `tool_response` shape? | `agent_finished` success row — join key + duration |
| CP2 | `PostToolUseFailure` on the `Agent` tool: registered at all? `error`? `is_interrupt`? `tool_use_id`? | `agent_finished` error row |
| CP3 | `SessionStart`: session id field? `model`? | `session_started` root row |

## Steps

1. **Scratch project.** Use a throwaway directory (not a real project —
   the production Optimus plugin hooks also load, and we don't want its
   ledger writing into a real workspace).
2. **Register.** Copy `probe.js` to `<scratch>/.claude/probe/probe.js`,
   copy `settings.probe.json` to `<scratch>/.claude/settings.json`,
   replacing `__PROBE__` with the absolute path of the copied probe.js.
3. **Truncate.** `: > <scratch>/.claude/probe/probe.log`
4. **Drive.** From `<scratch>`:

   ```bash
   # CP1 — successful dispatch (PostToolUse should fire on completion)
   claude -p --debug hooks --allowedTools "Agent" \
     "Use the Agent tool with subagent_type general-purpose, prompt: 'What is 2+2? Reply with just the number.' Then tell me its answer."

   # CP2 — forced tool failure (PostToolUseFailure, if the event exists)
   claude -p --debug hooks --allowedTools "Agent" \
     "Call the Agent tool with subagent_type 'nonexistent-agent-type-xyz' and prompt 'hi'."
   ```

   `SessionStart` (CP3) fires at the start of each run. Watch the
   `--debug hooks` output for registration warnings (an unknown event
   key like `PostToolUseFailure` would show there).
5. **Record.** Paste the raw `probe.log` lines (redact paths) into
   `docs/claude-probe-findings.md` — **do not summarize**, raw JSON is
   the evidence. Note the Claude Code version (`claude --version`) and
   any `--debug hooks` registration warnings.
6. **Deregister.** Delete `<scratch>` entirely when done (project
   settings live only inside the scratch dir; no global state).

## Re-run

Re-run on every Claude Code major/minor upgrade — hook payload field
names are undocumented and unversioned upstream, exactly like the Cursor
payloads. Update `docs/claude-probe-findings.md` with the new raw output.
