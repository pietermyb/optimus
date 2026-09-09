# Cursor probe findings

**Probe run date:** 2026-09-09
**Cursor version:** 3.19.13 (`cursor_version` in every payload, `CURSOR_VERSION` in the hook env)
**Install type:** personal/Team account (`user_email: <redacted>`), no Enterprise or Team
hook layer active. Cursor's own hooks channel reported `No enterprise hooks configuration found`
and `No active team hooks found for OS` on every reload, so nothing overrode the Project layer.
Local plugin imports are permitted on this install: Cursor loaded and executed hooks from a
Claude Code plugin cache directory (see "Additional findings", item 1).

These findings gate the Cursor adapter tasks in
docs/superpowers/plans/2026-09-09-cursor-support.md. Re-run the probes and
update this file on every Cursor upgrade — both facts below are
undocumented upstream and unversioned.

**Deviation from `cursor/probe/README.md`, and why.** The probes were run in the `optimus`
workspace itself rather than a scratch project at `/tmp/optimus-probe`. An agent session is bound
to the workspace it was started in and cannot open a different folder, so a scratch project could
only have been driven by hand. The probe kit was installed at `optimus/.cursor/` (git-excluded via
`.git/info/exclude`, removed afterwards) so the session could act as the main agent and dispatch a
real subagent. Nothing about the results is workspace-specific: `workspace_roots`,
`CURSOR_PROJECT_DIR` and the hook working directory are all simply the workspace root, whichever it
is. `/tmp/optimus-probe` was also created per the README and is left in place for a hand-run
re-verification if wanted.

Two further deviations, both to remove a confound rather than to skip a step:

- **A `"matcher": "Read"` was added for the Unknown-1 pass.** Without it, the analyser's own
  `Shell` calls land in the same log, and `cwd` (present only on `Shell` payloads) shows up as a
  "key on some only" and is then reported as a CANDIDATE SUBAGENT FIELD. That would have produced
  a false row-1 verdict. Restricting the event to `Read` makes both compared payloads the same
  tool. This also verifies the matcher syntax Task 7 needs.
- **The root variables were additionally passed as command arguments** (`--CURSOR_PLUGIN_ROOT="${CURSOR_PLUGIN_ROOT}"`
  etc.) against an absolute script path, as well as being tried in path position per the README.
  In path position a non-resolving variable produces no log at all, which cannot distinguish
  "expanded to empty" from "left literal". The argument form answers that directly and cannot
  crash. Both were run; both are recorded below.

## Unknown 1 — subagent distinguishability

Log: one main-agent `Read` of `probe-target.txt`, then one `explore` subagent dispatched to read
the same path, `preToolUse` matched to `Read` only, `subagentStart`/`subagentStop` unmatched.

### Raw `optimus-probe-report` output

```
== Optimus Cursor probe report ==
log file      : .cursor/probe/probe-unknown1.log
total entries : 4
events seen   : preToolUse=2, subagentStart=1, subagentStop=1
preToolUse    : 2

-- Unknown 1: subagent distinguishability --
key union        : conversation_id, cursor_version, generation_id, hook_event_name, model, session_id, tool_input, tool_name, tool_use_id, transcript_path, user_email, workspace_roots
keys on every    : conversation_id, cursor_version, generation_id, hook_event_name, model, session_id, tool_input, tool_name, tool_use_id, transcript_path, user_email, workspace_roots
keys on some only: (none)
CANDIDATE SUBAGENT FIELD: (none)
  conversation_id differs across preToolUse entries: "f188fb75-8509-4097-98bd-2c16eb6de30d" | "cfa836a6-bbff-4944-acde-ec84ffb7777f"
  generation_id differs across preToolUse entries: "d6388753-c8e7-4e14-a4a6-08c51fe18329" | "5990544a-6f61-4c8b-a703-df44b8bdf9b1"
  model differs across preToolUse entries: "claude-opus-5" | "cursor-grok-4.5-high"
  model_id identical across preToolUse entries: undefined
  tool_use_id differs across preToolUse entries: "toolu_bdrk_019hbkJhC9ykeJ6NMGvB3nxQ" | "call-5579e06c-e941-4603-9874-5b075c9c5281-1\nfc_4bb066f7-a1ba-9b19-aa8f-54ff5ffcda19_1"
  cwd identical across preToolUse entries: undefined
UNKNOWN 1 VERDICT: no distinguishing field -> decision matrix row 2
  Sidecar correlation via subagentStart/subagentStop is required, OR
  drop hard enforcement on Cursor and ship rules-only. Maintainer call.

-- Unknown 2: plugin root resolution --
  CURSOR_PLUGIN_ROOT : (unset/empty)
  PLUGIN_ROOT        : (unset/empty)
  CURSOR_PROJECT_DIR : /Users/<redacted>/Documents/PAM/optimus
  CLAUDE_PROJECT_DIR : /Users/<redacted>/Documents/PAM/optimus
  __dirname          : /Users/<redacted>/Documents/PAM/optimus/.cursor/probe
UNKNOWN 2 VERDICT: no plugin-root variable resolved, but __dirname did
  Render absolute paths at install time (optimus-cli install cursor).
  Cost: the generated .cursor/hooks.json is machine-specific.
```

### Verdict

**row 2 — no distinguishing field, sidecar correlation required.**

A subagent's own tool calls *do* fire `preToolUse` (so this is not row 3), and the payload key set
is byte-for-byte identical to a main-agent call (so this is not row 1). Routing per Task 4 Step 5:
**Task 5, then Task 6, then 7, 8, 9.**

The nuance that matters for Task 6, because it makes the sidecar considerably stronger than the
spec assumed: **`conversation_id` is the discriminator.** A subagent's tool calls carry the
subagent's own `conversation_id` (`cfa836a6-…`, which is exactly the agent id the `Task` tool
returns to the orchestrator), not the parent's (`f188fb75-…`). `session_id` equals
`conversation_id` on every payload observed, main and subagent alike, so it carries the same
signal.

Consequences for the Task 6 design, all verified in this run:

- `subagentStart` fires with `parent_conversation_id` set to the parent's `conversation_id`, and it
  fires **before** the subagent's first tool call (09:41:36.131 vs 09:41:39.315). So a sidecar that
  records the parent id at `subagentStart` is populated in time.
- The gate's test becomes `payload.conversation_id !== <recorded parent id>` ⇒ subagent. That is
  **exact per-call attribution**, not the coarse "some subagent is outstanding" approximation the
  spec anticipated, and it therefore has **no race with parallel subagents** — every call carries
  its own originating conversation, however many are in flight.
- Before any dispatch there is no sidecar entry and there are also no subagent calls, so "no
  sidecar entry" can safely be read as "main agent".
- `subagentStart.subagent_id` is *not* the subagent's `conversation_id` (it is the parent's
  `tool_use_id` for the `Task` call — `toolu_bdrk_01QzW6k5RZgPCqitGr4U8E2j`, identical to
  `tool_call_id`). So the sidecar must key on `parent_conversation_id`, and must not attempt to
  pre-register the subagent's own id — that id is not knowable until the subagent's first tool call.

There is also a **stateless** discriminator, offered as corroboration and not as the primary
mechanism: `transcript_path` is `null` on the subagent's `preToolUse` payload and a real path on
every main-agent payload, and the hook environment agrees (`CURSOR_TRANSCRIPT_PATH` unset for the
subagent, set for the main agent). It is rejected as the primary mechanism because the documented
meaning of `transcript_path: null` is "transcripts disabled" — if a user turns transcripts off,
every call would look like a subagent and enforcement would silently switch itself off entirely.
The failure direction is fail-open, which matches Optimus's documented stance, but silently.

Do not read `model` as a role signal: it differs here (`claude-opus-5` vs `cursor-grok-4.5-high`)
only because the `explore` subagent ran on a different model than the session. It would match on
an inheriting subagent. `tool_use_id` format also differs (`toolu_bdrk_…` vs
`call-<uuid>-1\nfc_<uuid>_1`, note the embedded newline) but that is an incidental format detail,
not a contract.

### Deny-path confirmation (decision matrix row 4)

Ran `.cursor/probe/probe-deny.js`, which unconditionally emits
`{"permission":"deny","user_message":"probe deny","agent_message":"probe deny"}`, registered on
`preToolUse` with `"matcher": "Read"` (scoped to `Read` so `Shell` stayed available to recover).
Both calls were then made against the same path.

- **Main agent call actually blocked?** Yes. The tool returned `Error: probe deny` to the agent —
  Cursor surfaced the hook's `agent_message` verbatim as the tool error, and appended its own
  `Agent note: Do not suggest workarounds to the blocked tool.` The read did not happen.
- **Subagent call actually blocked?** Yes, genuinely blocked, not advisory. The `explore` subagent
  was asked to read the file and report either the contents or the verbatim error; it reported
  `probe deny`. `probe-deny.log` records two invocations, the second with
  `conversation_id=d59a1532-37b1-42c9-bec4-3ad120126c55` and `transcript_path=null`, i.e. the
  subagent's own call, denied.
- **Cursor's own error/notification text:** none — no error was raised, because a deny is a normal
  outcome rather than a failure. Cursor's hooks channel logged the decision it acted on:

```
Command: node ".cursor/probe/probe-deny.js" --pass=deny (52ms) exit code: 0
...
  "permission": "deny",
  "user_message": "probe deny",
  "agent_message": "probe deny"
```

**This rules out row 4.** Hard enforcement is viable on Cursor, in both the main session and inside
a subagent.

## Unknown 2 — plugin root resolution

### Raw `optimus-probe-report` output

Pass A (`${CURSOR_PLUGIN_ROOT}` in path position) and Pass B (`${PLUGIN_ROOT}`) were run
separately, with `probe-root.log` cleared between them. Neither pass created the file at all, so
the analyser has nothing to read — that absence *is* the finding for both variables:

```
optimus-probe-report: cannot read .cursor/probe/probe-root.log: ENOENT: no such file or directory, open '.cursor/probe/probe-root.log'
(exit code 1)
```

Cursor's hooks channel, verbatim, Pass A:

```
[2026-09-09T09:43:55.296Z] ERROR: Hook 1 failed with exit code 1
Command: node "${CURSOR_PLUGIN_ROOT}/probe/probe-root.js" --plugin-root-attempt (52ms) exit code: 1

OUTPUT:
(empty)

STDERR:
Error: Cannot find module '/probe/probe-root.js'
    code: 'MODULE_NOT_FOUND',
```

Pass B, verbatim — identical failure:

```
[2026-09-09T09:45:28.085Z] ERROR: Hook 1 failed with exit code 1
Command: node "${PLUGIN_ROOT}/probe/probe-root.js" --plugin-root-attempt (43ms) exit code: 1

OUTPUT:
(empty)

STDERR:
Error: Cannot find module '/probe/probe-root.js'
    code: 'MODULE_NOT_FOUND',
```

`Cannot find module '/probe/probe-root.js'` — the variable was **expanded to the empty string**,
not left literal, so `${VAR}` in a project-hook command is resolved by the shell against the hook
process environment, and both plugin-root names are simply unset there.

The variable-passthrough pass confirms that directly. Note the analyser's Unknown-1 section on
this log reads "subagent tool calls appear not to fire preToolUse" — **that is an artefact of a
single-entry log, not a finding.** This log was produced by one main-agent read for the Unknown-2
question only. The Unknown-1 verdict is the one above.

```
== Optimus Cursor probe report ==
log file      : .cursor/probe/probe-rootvars.log
total entries : 1
events seen   : preToolUse=1
preToolUse    : 1

-- Unknown 1: subagent distinguishability --
Only ONE preToolUse entry. If the procedure in cursor/probe/README.md
was followed (a main-agent read AND a subagent read), this is itself the
finding: subagent-internal tool calls do not fire preToolUse.
UNKNOWN 1 VERDICT: subagent tool calls appear not to fire preToolUse

-- Unknown 2: plugin root resolution --
  CURSOR_PLUGIN_ROOT : (unset/empty)
  PLUGIN_ROOT        : (unset/empty)
  CURSOR_PROJECT_DIR : /Users/<redacted>/Documents/PAM/optimus
  CLAUDE_PROJECT_DIR : /Users/<redacted>/Documents/PAM/optimus
  __dirname          : /Users/<redacted>/Documents/PAM/optimus/.cursor/probe
UNKNOWN 2 VERDICT: no plugin-root variable resolved, but __dirname did
  Render absolute paths at install time (optimus-cli install cursor).
  Cost: the generated .cursor/hooks.json is machine-specific.
```

The `argv` that reached the hook process in that pass, showing exactly what each `${…}` became:

```
"/Users/<redacted>/.nvm/versions/node/v20.19.3/bin/node"
"/Users/<redacted>/Documents/PAM/optimus/.cursor/probe/probe.js"
"--pass=root-vars"
"--CURSOR_PLUGIN_ROOT="
"--PLUGIN_ROOT="
"--CLAUDE_PLUGIN_ROOT="
"--workspaceFolder="
"--CURSOR_PROJECT_DIR=/Users/<redacted>/Documents/PAM/optimus"
```

### Verdict

**Neither `CURSOR_PLUGIN_ROOT` nor `PLUGIN_ROOT` resolves in a project hook** — both expand to the
empty string. `${workspaceFolder}` and `${CLAUDE_PLUGIN_ROOT}` are also empty there;
`${CURSOR_PROJECT_DIR}` and `${CLAUDE_PROJECT_DIR}` both resolve to the workspace root.

**However, the analyser's canned advice ("render absolute paths at install time, the generated
`.cursor/hooks.json` is machine-specific") does not apply to a project-level install, and Task 7/8
should not follow it.** A plugin root is not needed at all, because a plain relative path works.
Verified two ways in this run:

- A `preToolUse` entry whose command was `node ".cursor/probe/probe.js" --pass=bare-node-rel-path`
  fired on every tool call, alongside the absolute-path entry, for the whole tool-name sweep.
- Every pass after the first used the relative form exclusively and worked.

`process.cwd()` for a project hook is the workspace root, matching the documented "for project
hooks, paths are relative to the project root". Bare `node` also resolves — this machine's `node`
is nvm-managed at `/Users/…/.nvm/versions/node/v20.19.3/bin/node` and the hook process still found
it on `PATH`, so hooks inherit a login-shell-like `PATH` rather than a bare GUI environment.

So `cursor/hooks.json` can ship checked-in, machine-independent, relative commands. Absolute-path
rendering at install time is only required for a **user-level** install (`~/.cursor/hooks.json`),
where relative paths resolve against `~/.cursor/` instead. `${CURSOR_PROJECT_DIR}` is available as
a portable absolute anchor if one is ever wanted.

## Tool-name observations (spec Section 4)

Every row below was triggered from the main agent and read out of the log; nothing is left
unresolved. `tool_input` field names are included because `CURSOR_TOOL_MAP` in Task 5 needs them
and they differ from Claude Code's (`file_path`, not `path`).

| Operation | Observed `tool_name` |
|---|---|
| read a file | `Read` — `tool_input: {file_path}` |
| edit part of a file | `Write` — no distinct edit tool. A partial edit surfaces as a `Read` of the path followed by a `Write` carrying the **whole** new file content in `tool_input.content` |
| write/overwrite a whole file | `Write` — `tool_input: {file_path, content}`, preceded by a `Read` when the file already exists |
| search file contents | `Grep` — `tool_input: {pattern, file_path, output_mode: "content"}` |
| list/glob files by pattern | `Grep` — same tool name, distinguished by `pattern: ""` plus `glob` set and `output_mode: "files_with_matches"`. Cursor does **not** expose a separate glob tool; this closes the spec's `Glob` "UNVERIFIED" row |
| fetch a URL | `WebFetch` — `tool_input: {url}` |
| web search | `WebSearch` — `tool_input: {search_term, explanation}` |
| delete a file | `Delete` — `tool_input: {file_path}` |
| run a shell command | `Shell` — `tool_input: {command, cwd, timeout}`. `cwd` also appears as a **top-level** payload key, on `Shell` payloads only |
| dispatch a subagent | `Task` — `tool_input: {description, prompt, subagent_type, model}` |
| edit a notebook cell | `Read` then `Write` on the `.ipynb` — no distinct notebook tool, and no cell-level granularity in `tool_input` |

Four consequences worth carrying into Task 5:

1. **`Task`'s `tool_input` does carry a model field.** It is `model`, and it holds the raw requested
   value verbatim — `"inherit"` in this run, alongside `subagent_type: "explore"`. This resolves
   the spec's "does Cursor's `Task` `tool_input` carry a `model` key at all" as **yes**, so the
   "every dispatch must name a non-expensive model" rule ports directly. Note the *top-level*
   `model` on that same `Task` payload was the empty string `""`, so the dispatch model must be
   read from `tool_input.model`, not from the payload's `model`.
2. **Denying `Read` also blocks writes to existing files.** Discovered the hard way while writing
   this file: with the deny hook scoped to `"matcher": "Read"`, a `Write` to an
   already-existing path was rejected with `probe deny`, because Cursor issues an internal `Read`
   of the target first. Read-scoped and write-scoped policy are therefore not independent on
   Cursor, and a `Read` deny is a broader hammer than it looks.
3. **`WebSearch` and `WebFetch` each emit follow-up `Write` calls** that the agent did not ask for:
   Cursor caches fetched page text under
   `~/.cursor/projects/<workspace>/agent-tools/<uuid>.txt` and those writes fire `preToolUse` with
   `tool_name: "Write"`. A gate that denies `Write` in the main session will therefore also break
   web search and URL fetching, with a confusing failure. Task 5 should either scope work-tool
   denial to paths inside the workspace or explicitly exempt the `agent-tools` cache directory.
4. **`model_id` and `model_params` were absent from every `preToolUse` payload observed**, despite
   being documented on the common schema. They *were* present on `subagentStart`/`subagentStop`
   (e.g. `model_id: "claude-opus-5"` with `model_params` carrying `thinking`, `context`, `effort`,
   `fast`). `preToolUse` carried only `model`, as the plain slug `"claude-opus-5"` with no
   thinking/effort suffix. `config.modelConditional` in Task 1 must therefore treat `model_id` as
   optional and fall back to `model`.

## `hooks.json` schema corrections

`cursor/probe/hooks.probe.json` as committed **would not have worked.** It used
`${workspaceFolder}`, which is a VS Code editor variable, not a hook variable: it expands to the
empty string, so the command became `node "/.cursor/probe/probe.js"` and failed with
`MODULE_NOT_FOUND` — logging nothing, which is indistinguishable from a hook that never
registered. That is exactly the "if nothing landed, stop here" trap the README warns about, and it
was the template itself that would have triggered it. Replace it with a project-root-relative path.

Everything else in the template was accepted as written: `"version": 1`, the
`hooks.<eventName>[].command` shape, and `matcher` being optional.

Working file, verbatim (the Unknown-1 configuration):

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "command": "node \".cursor/probe/probe.js\" --pass=unknown1",
        "matcher": "Read"
      }
    ],
    "subagentStart": [
      {
        "command": "node \".cursor/probe/probe.js\" --pass=subagent-start"
      }
    ],
    "subagentStop": [
      {
        "command": "node \".cursor/probe/probe.js\" --pass=subagent-stop"
      }
    ]
  }
}
```

Additional schema facts established for Task 7:

- **`matcher` works and is a regex over the tool name**, as documented. With `"matcher": "Read"`,
  `Shell` calls stopped firing the hook entirely.
- **Multiple entries on one event all run.** The README flagged Cursor's cardinality rules as
  unverified: two `preToolUse` entries both fired on every tool call, and Cursor's channel logged
  `Found 1 hook(s)`/`Executing hook 1/1` per source and then `Merged 2 valid response(s)` when more
  than one returned output.
- **No window reload is needed to register or change hooks.** Cursor watches `hooks.json` and
  reloads on save (`Reloading hooks configuration...` → `Loaded 3 project hook(s) for steps:
  preToolUse, subagentStart, subagentStop`). Every pass in this run took effect on save. This
  contradicts step 4 of `cursor/probe/README.md`; a couple of seconds' settle time was allowed
  after each write.
- **Deleting `hooks.json` does *not* deregister its hooks.** `rm .cursor/hooks.json` produced no
  `Reloading hooks configuration...` line and the previously loaded hooks — including the
  unconditional deny — kept firing. Only a *write* is watched. Writing
  `{"version": 1, "hooks": {}}` produced `Loaded 0 project hook(s) for steps:` and cleared them.
  Task 8's uninstall path must overwrite with an empty config, not unlink the file, or it will
  leave a live gate behind pointing at scripts it just removed.
- **Project and User hooks are merged, not overridden.** The channel logged
  `Loaded 6 user hook(s) …` and `Loaded 3 project hook(s) …` together. Installing a project
  `hooks.json` did not disable the pre-existing user-level hooks.
- **Hooks fail open by default.** Across Passes A and B the hook exited 1 with no output on every
  `Read`, and every read still succeeded. Cursor logged
  `All hooks for step preToolUse completed but none returned a valid response` and proceeded. Only
  an explicit `{"permission":"deny"}` (or exit code 2) blocks. Optimus's fail-open stance is
  therefore consistent with the host default, but note it means a crashing gate silently stops
  enforcing.
- **Cursor's error surface is a file, not just a panel.** The Hooks output channel is written to
  `~/Library/Application Support/Cursor/logs/<session>/window<N>/output_<ts>/cursor.hooks.workspaceId-<id>.log`,
  with full `INPUT`/`OUTPUT`/`STDERR` per invocation. This is the fastest way to debug the adapter
  and to re-verify these findings after a Cursor upgrade; Task 9(c) should point at it.

## Additional findings

Three things turned up that the plan did not anticipate. The first is the significant one.

1. **Cursor already loads and runs the Claude Code Optimus plugin's `PreToolUse` hook, and
   `${CLAUDE_PLUGIN_ROOT}` resolves there.** With no `.cursor/hooks.json` present, Cursor's channel
   logged `Executing hook 1/1 from claude-plugin config`,
   `Running script in directory: /Users/<redacted>/.claude/plugins/cache/Optimus/optimus/0.2.0`,
   and ran `node "/Users/…/.claude/plugins/cache/Optimus/optimus/0.2.0/hooks/optimus-gate.js"` —
   i.e. it read the plugin's Claude-shaped `hooks/hooks.json` (nested
   `PreToolUse[].hooks[].command` with `${CLAUDE_PLUGIN_ROOT}`), mapped `PreToolUse` onto
   `preToolUse`, honoured the `matcher`, and expanded `${CLAUDE_PLUGIN_ROOT}` correctly. The hooks
   service also reports `Claude user config path: /Users/…/.claude/settings.json` at startup.
   So `${CLAUDE_PLUGIN_ROOT}` *does* resolve when the hook comes from a claude-plugin config, even
   though it is empty in a project hook.

   Two consequences, and they pull in opposite directions, so this is a maintainer decision that
   affects Task 7 and Task 8:

   - The existing Claude Code plugin manifest may be a viable delivery vehicle for Cursor with no
     separate `.cursor/hooks.json` at all.
   - **Right now, on Cursor, `optimus-gate.js` is a silent no-op.** It was invoked with Cursor's
     payload on every matched tool call, exited 0, and produced no output (`Hook 1 produced no
     output` → `none returned a valid response` → allowed). Its allow path is Claude Code's
     "emit nothing", which Cursor reads as allow, so that much is accidentally compatible. But its
     **deny** path emits `hookSpecificOutput.permissionDecision: "deny"`, which Cursor does not
     understand — so a deny would also be read as "no valid response" and **fail open**. Anyone
     who has the Claude plugin installed and uses Cursor is currently unenforced without any
     warning. Exit code 2 is honoured by both hosts and is the one blocking mechanism that already
     ports; worth considering for the adapter's deny path.

2. **Project-level agent definitions do not hot-reload.** `.cursor/agents/file-reader.md` was
   installed but `subagent_type: "file-reader"` was rejected with
   `Invalid enum value. Expected 'generalPurpose' | 'explore' | …`. The built-in `explore` type was
   used instead, which answers the question identically. A failed dispatch still fires
   `subagentStop` (with `subagent_type: "unknown"`, `status: "error"`, `duration_ms: 0` and the
   validation error in `error_message`) but no `subagentStart`, and no `preToolUse` for the `Task`
   call — worth knowing for Task 6, since a sidecar keyed on `subagentStart` must tolerate a
   `subagentStop` it never saw a start for. `cursor/probe/README.md` step 7 should note that the
   agent file needs a reload, unlike `hooks.json`.

3. **`session_id` is present on `preToolUse` and equals `conversation_id`** on every payload
   observed, main agent and subagent alike, so Task 5's `conversation_id` → `session_id` ledger
   mapping can use either. `user_email` is also present on every payload
   (`<redacted>`); it is not needed for enforcement, and the ledger writer should not
   start recording it without a deliberate decision.

## Reproducing this run

Not committed, and deleted after the run: `optimus/.cursor/{hooks.json,probe/,agents/}` and
`optimus/probe-target.txt`, plus their `.git/info/exclude` entries. The raw logs behind every
report above were `probe-unknown1.log`, `probe-rootvars.log`, `probe-deny.log` and
`probe-toolnames.log` (the 51-line tool-name sweep) in `.cursor/probe/`. To reproduce, re-run
`cursor/probe/README.md` with the two corrections recorded here: a project-root-relative command
path instead of `${workspaceFolder}`, and a `"matcher": "Read"` on the Unknown-1 pass.
