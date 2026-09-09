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
```
