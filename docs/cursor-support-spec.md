# Optimus: Cursor Support — Implementation Spec

**Date:** 2026-09-09
**Branch:** `feat/cursor-support`
**Author of this spec:** written for hand-off; no assumed context beyond this file and the repository.

## Goal

Port Optimus's orchestrator-enforcement policy — currently implemented as a pair of Claude Code
plugin hooks — to Cursor (the Anysphere editor), so that a Cursor user gets the same "main agent
delegates real work to cheaper subagents, hard-enforced" behavior Optimus already provides in
Claude Code, without regressing the existing Claude Code build and without shipping a design that
turns out to be structurally impossible once Cursor's actual hook payloads are inspected. This spec
is deliberately probe-first: two load-bearing facts about Cursor's hook system are undocumented,
and this document specifies how to test them empirically *before* committing to the architecture in
Section 6.

---

## 1. Background: what Optimus does today (Claude Code)

Everything in this section is drawn directly from the files in this repository as they exist on
`main` at the time of writing. File paths and line references are accurate as of this reading; if
they drift, re-read the source rather than trusting this section.

### 1.1 The two hooks

Optimus registers two Claude Code hooks via `hooks/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write|Grep|Glob|WebFetch|WebSearch|NotebookEdit|Agent|Bash",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/optimus-gate.js\"" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/optimus-reinforce.js\"" }
        ]
      }
    ]
  }
}
```

**`hooks/optimus-gate.js`** is the enforcement point, registered on `PreToolUse`. Its checks run in
a deliberate, documented order (see the file's own header comment, `hooks/optimus-gate.js:7-27`):

0. **Kill switch** (`OPTIMUS_DISABLED` env var) — checked first, always wins, forces allow.
1. **Subagent exemption** — `if (payload.agent_id || payload.agent_type) return allow();`
   (`hooks/optimus-gate.js:84-86`). This check runs before the per-project activation check and
   before everything else. The file's own comment calls this "load-bearing": getting the order
   wrong "blocks every worker Optimus dispatches and inverts the entire point of the plugin."
2. **Per-project activation** — `getConfig(payload.cwd)`; if `!cfg.enabled`, allow everything.
3. **Agent dispatch model check** — if `tool_name === 'Agent'`: a missing/empty
   `tool_input.model` is denied (would silently inherit the orchestrator's own expensive model);
   a model matching `EXPENSIVE_MODEL_RE` (`/opus/i`, defined in `hooks/optimus-config.js:48`) is
   denied. Any other named model is allowed.
4. **Work-tool deny** — if `WORK_TOOLS.has(toolName)` (the set `Read, Edit, Write, Grep, Glob,
   WebFetch, WebSearch, NotebookEdit`, defined in `hooks/optimus-config.js:36-45`), deny
   unconditionally with a message pointing the caller at the `Agent` tool instead.
5. **Bash speed bump** — if `tool_name === 'Bash'`, the command string is tested against
   `BASH_READ_PATTERNS` (`hooks/optimus-gate.js:43-53`): bare `cat`, `head`, `tail`,
   `rg`/`grep` (excluding `--help`/`--version`), `find ... -name`, `ls`, `less`, `more`, `sed -n`.
   A match is denied with a message noting this is "best-effort... not a hard boundary." Anything
   else (git, build, test commands, `awk`, heredocs, `python3 -c`, etc.) is allowed. The README
   states explicitly this is *not* a security boundary and lists concrete bypasses that sail
   through it.

A `deny()` writes this JSON to stdout and exits 0:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "<reason text>"
  }
}
```

`allow()` is simply `process.exit(0)` with no stdout. The whole script fails open: a JSON parse
error, a config-read error, or any uncaught exception in `main()` results in `allow()` — the file's
header comment states "a bug in this hook must never wedge a session," and the top-level
`process.stdin.on('end', ...)` handler wraps the call to `main()` in a try/catch that also exits 0
on any throw (`hooks/optimus-gate.js:162-169`).

**`hooks/optimus-reinforce.js`** is registered on `UserPromptSubmit` and is purely advisory. It
re-injects a short policy reminder on every user turn (not just once at session start), because —
per its own header comment — "a one-shot SessionStart injection decays across a long session,
especially past compaction." It performs the same kill-switch check, the same subagent exemption
(`payload.agent_id || payload.agent_type` — subagents get their own prompts and don't need the
reminder), and the same per-project `enabled` check as the gate, then emits:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "<REMINDER text>"
  }
}
```

The reminder text (`hooks/optimus-reinforce.js:22-28`) restates: which tools are blocked; that
every `Agent` dispatch must name a model (`haiku` for mechanical work, `sonnet` for judgement,
never `opus`); that Bash stays open for orchestration but a subagent is preferred over
`cat`/`grep`/`head`/`find`; and a "minimal answer" style instruction. This hook enforces nothing by
itself — enforcement lives entirely in `optimus-gate.js`.

### 1.2 Config resolution and the kill switch (`hooks/optimus-config.js`)

Shared, host-agnostic-in-spirit (but currently Node/CommonJS and Claude-Code-invoked) helpers:

- `KILL_SWITCH_ENV = 'OPTIMUS_DISABLED'`; `isKillSwitchActive()` treats `'1'`, `'true'`, `'yes'`,
  `'on'` as active.
- Activation state is **repo-local**, not global: `.optimus/config.json`, resolved by
  `findProjectRoot()` walking up from `cwd` (up to `MAX_WALK_LEVELS = 20`) looking for an existing
  `.optimus/config.json`. `getConfig(cwd)` returns `{ enabled, root, raw }` and never throws — a
  missing or corrupt file resolves to `enabled: false`.
- `safeReadJsonFile()` refuses symlinks and files over `MAX_CONFIG_BYTES = 4096`, returning `null`
  (never throwing) on any error.
- `setConfig(cwd, enabled)` writes directly at `cwd` (not walked up — "this project," explicitly),
  refuses to write through a pre-existing symlink at the target path, and writes atomically
  (`fs.writeFileSync` to a temp file with `flag: 'wx'`, then `fs.renameSync`).
- Exports include `WORK_TOOLS` and `EXPENSIVE_MODEL_RE`, which is why `optimus-gate.js` imports
  them rather than redefining them.

### 1.3 The CLI (`bin/optimus-cli`, `bin/optimus-stats`)

`bin/optimus-cli` is the implementation behind `/optimus [on|off|status]`. It deliberately does
**not** infer intent from free-text prompts — the slash command's `!`-prefixed bash execution
invokes this script directly, and it deterministically reads/writes `.optimus/config.json` via the
shared `optimus-config.js` functions. It resolves the project directory as
`process.env.CLAUDE_PROJECT_DIR || process.cwd()` (`bin/optimus-cli:22`) — note this already reads
an env var also documented for Cursor (see Section 5, Unknown 2, and the env-var table in the
Cursor research). `status` prints the config file path, activation state, and kill-switch state.

`bin/optimus-stats` is the implementation behind `/optimus-stats`. It reads Claude Code's own
transcript files directly (there is no documented API for this): `<config dir>/projects/<slug>/`,
where `<config dir>` is `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`, and `slug` is `cwd` with
every non-alphanumeric character replaced by `-` (`bin/optimus-stats:93-95`, explicitly called
"empirically observed... undocumented"). Because that slug is a guess at an undocumented format,
resolution goes through `resolveProjectDir` (`bin/optimus-stats:159-223`): it tries the slug path
first, and if that directory doesn't exist, falls back to scanning each project directory's own
transcripts for a top-level `cwd` field that matches exactly — so a wrong slug guess doesn't
produce a false "no data" result. Once the directory is resolved, it walks every `*.jsonl` session
file for orchestrator usage, and separately walks `<session-dir>/subagents/agent-<id>.jsonl` for
delegated usage, summing every `type:"assistant"` line's `usage` object rather than trusting the
parent's `Agent` tool-result rollup (which the file's header comment notes only reflects the
subagent's *last* turn). It prints a pricing table with a snapshot date
(`PRICING_SNAPSHOT_DATE = '2026-06-24'`) and computes an **estimated** saving versus a hypothetical
all-opus run. Both scripts are exposed on
`PATH` via the plugin's `bin/` directory rather than through `${CLAUDE_PLUGIN_ROOT}` — the README
documents (with a specific historical incident) that `CLAUDE_PLUGIN_ROOT` is not set inside a slash
command's own `!`-prefixed bash execution, only inside `hooks/hooks.json` command strings.

### 1.4 Manifests and commands

- `.claude-plugin/plugin.json`: `name: "optimus"`, `version: "0.1.0"`, description, author
  (Pieter Myburgh), `homepage`, `license: "GPL-3.0-or-later"`, keywords. **Deliberately carries no
  `"hooks"` key** — the README documents that Claude Code's plugin hook loader only reliably picks
  up hooks from an inline `"hooks"` object in `plugin.json` *or* the literal conventional path
  `hooks/hooks.json`, and warns explicitly against renaming/relocating that file or pointing a
  `"hooks"` key elsewhere, citing a specific incident where a differently-named hook file silently
  never fired.
- `.claude-plugin/marketplace.json`: lets `claude plugin marketplace add pietermyb/optimus` find
  the plugin; `plugins: [{ name: "optimus", source: "./", category: "productivity" }]`.
- `commands/optimus.md`: frontmatter `allowed-tools: Bash(optimus-cli:*)`; body is
  `` !`optimus-cli $ARGUMENTS` `` followed by an instruction to report the output verbatim.
- `commands/optimus-stats.md`: frontmatter `allowed-tools: Bash(optimus-stats:*)`; body is
  `` !`optimus-stats` `` with an instruction to present it as a readable summary without dropping
  the estimate/pricing caveats.

### 1.5 Tests (`tests/`)

`tests/fixtures/` holds seven captured-shape `PreToolUse` payloads as JSON files:
`agent-haiku-model.json`, `agent-no-model.json`, `agent-opus-model.json`, `main-bash-cat.json`,
`main-bash-git.json`, `main-read.json`, `subagent-read.json`. Each carries the fields Claude Code
actually sends (`session_id`, `transcript_path`, `cwd` — templated as the literal string
`__PROJECT__`, substituted at test time — `permission_mode`, `hook_event_name`, `tool_name`,
`tool_input`, `tool_use_id`), and `subagent-read.json` additionally carries `agent_id` and
`agent_type` to exercise the exemption path.

`tests/run-gate-tests.sh` is a bash harness that creates a throwaway project directory under a temp
dir, feeds each fixture (with `__PROJECT__` substituted via `sed`) to `hooks/optimus-gate.js` on
stdin, and checks for the presence/absence of `"permissionDecision":"deny"` in stdout. It exercises:
the inactive state (everything allowed), the active state (main-session `Read` denied, subagent
`Read` allowed, `Agent` without a model denied, `Agent` with `model="claude-opus-5"` denied,
`Agent` with `model="haiku"` allowed, `Bash: git status` allowed, `Bash: cat work.txt` denied), the
kill switch (forces allow even while active), and deactivation (allowed again). It activates/
deactivates Optimus for its throwaway project via the same `bin/optimus-cli` code path `/optimus
on`/`off` uses, not by hand-writing the config file.

### 1.6 The enforcement ledger (`hooks/optimus-ledger.js`)

This module postdates the rest of Section 1 (it landed after this spec's original research pass)
but is now load-bearing enough to a Cursor port that it needs its own read, for the same reason
Section 1.2/1.3 exist: know the real shape before designing around a guess. `hooks/optimus-gate.js`
calls `recordEvent(cwd, event)` from this module at every point it already reaches a verdict —
`dispatch_allowed`/`dispatch_denied` in the `Agent` branch (`hooks/optimus-gate.js:118-123,
134-140, 149-155`), `work_tool_denied` in the work-tool branch (`hooks/optimus-gate.js:161-165`),
and `bash_nudge` in the Bash branch (`hooks/optimus-gate.js:181-185`). `optimus-reinforce.js` calls
nothing here — this is a gate-only concern.

Properties that matter for a port, not just for Claude Code:

- **Location is repo-local, not Claude-Code-specific.** `recordEvent()` resolves
  `<projectRoot>/.optimus/state/events.jsonl` via `findProjectRoot(cwd)` — the exact same
  `optimus-config.js` walk-up Section 1.2 already documents, not anything tied to Claude Code's own
  transcript layout. Whatever `cwd` a host's hook payload carries is all this needs.
- **Gated by the same two checks the gate itself already makes.** `recordEvent()` calls
  `isKillSwitchActive()` and `getConfig(cwd).enabled` itself, independently of its caller — so even
  a future adapter that forgets one of those checks before calling `recordEvent()` cannot cause an
  event to be written for a project where Optimus isn't active, or while the kill switch is on.
- **Append-only, `fs.appendFileSync` with the `a` flag, never read-modify-written.** This is what
  makes concurrent writes from many gate processes (main session + every subagent it dispatches,
  all potentially calling tools at once) safe with no locking — each call's own "seek to end, write"
  is atomic at the OS level. Anything a Cursor adapter does here must preserve this property; a
  ported implementation that reads the file to append to an in-memory array first, then rewrites the
  whole thing, would reopen exactly the race this design avoids.
- **Privacy backstop baked into the module, not just convention.** `recordEvent()` caps every string
  field at `MAX_FIELD_LEN` (200 characters) before writing, regardless of what its caller passes —
  belt-and-suspenders under the same rule Section 1.1 already states (never log prompts, paths, file
  contents, or full shell commands). The gate only ever passes reduced fields to begin with (e.g.
  `cmd_head`, the first word of a Bash command, never the command itself).
- **Rotates at 1 MB to a single `events.jsonl.1` generation**, checked by `fs.statSync` immediately
  before each append (`ROTATE_MAX_BYTES = 1024 * 1024`) — deliberately a stat, not a read, so
  rotation itself never reopens the concurrency problem the append-only design solves.
- **Never throws, never writes to stdout.** Every fs/JSON call is wrapped in try/catch; a failure is
  swallowed (a stderr note is the most it does). This sits on the exact hot path between the gate
  deciding and emitting its verdict as JSON on stdout, so the same "a bug here must never wedge a
  session" principle Section 1.1 states for the gate itself applies here without exception.

**What a Cursor adapter would need to replicate.** `hooks/optimus-ledger.js` is pure Node/fs with no
Claude-Code-specific API surface — the same property Section 6.2 already claims for
`hooks/optimus-config.js`, and for the same reason: it should be importable **unmodified** by
`hooks/optimus-gate-cursor.js` once that file exists, not reimplemented. The only real work is in
the adapter, not the ledger module itself:

1. **Call `recordEvent(cwd, event)` at the equivalent points** — after a `Task` dispatch is
   allowed/denied (Section 2, Section 4), after a work-tool denial (once Cursor's own `WORK_TOOLS`
   equivalent is settled per the open question in Section 4), and after a `Shell`/
   `beforeShellExecution` bypass match (Section 2). Same event names (`dispatch_allowed`,
   `dispatch_denied`, `work_tool_denied`, `bash_nudge`), same field sets, so `/optimus-stats`'
   reporting (see Section 9(d)'s addendum below) needs zero host-specific branching to read either
   host's ledger.
2. **Translate field names at the call site, not inside the ledger module.** Cursor's `preToolUse`
   payload carries `conversation_id`, not `session_id` (Section 5.1's field list) — the adapter must
   pass `event.session_id = payload.conversation_id`, mirroring how it already has to translate
   `tool_name`/`tool_input` shapes per Section 6.2. `tool_use_id` and `cwd` are already named
   identically on both hosts, so those pass through unchanged.
3. **Use whatever raw value Cursor's `Task` `tool_input` carries as its model-selection field** (still
   unverified per Section 2's row on this) as the ledger's `model` field for `dispatch_allowed`/
   `dispatch_denied` — same principle as the Claude Code side recording the raw requested alias
   (`"haiku"`), not a resolved model id. This is what lets `/optimus-stats`' family-level
   requested-vs-actual comparison (Section 9(d) below) work the same way on both hosts.
4. **Nothing else.** No new rotation logic, no new privacy capping, no new concurrency handling —
   all of that is already host-agnostic in the module as written. If Unknown 1 (Section 5.1) resolves
   in a way that changes *how* `isSubagent` is determined on Cursor, that changes what calls
   `recordEvent()` and when — it does not change anything inside `optimus-ledger.js` itself.

---

## 2. Capability mapping table

| Optimus need | Claude Code mechanism | Cursor mechanism | Verdict |
|---|---|---|---|
| Deny work tools in the main session | `PreToolUse` hook, `hookSpecificOutput.permissionDecision: "deny"` | `preToolUse` hook, `{"permission":"deny"}` | Portable in principle — matcher syntax and payload shape differ (see Section 7 for tool-name mapping), and enforcement of subagent-vs-main distinction is **UNVERIFIED** (Unknown 1). |
| Exempt subagent tool calls | `payload.agent_id \|\| payload.agent_type` on the `PreToolUse` payload | No documented equivalent field on `preToolUse` stdin. `subagent_id`/`subagent_type`/`parent_conversation_id` exist only on `subagentStart`, not on the tool-call hooks fired for a subagent's own actions. | **UNDOCUMENTED / BLOCKING.** This is Unknown 1 below. Do not build past this without a passing probe. |
| Require every dispatch to name a non-expensive model | `PreToolUse` matcher on `Agent`, inspects `tool_input.model` against `/opus/i` | `preToolUse` matcher `Task` (Cursor's dispatch tool), inspect `tool_input` for the equivalent field | Plausible, but the exact shape of Cursor's `Task` `tool_input` (does it carry a `model` key at all, and under what name?) is **UNVERIFIED** — must be captured empirically alongside the Unknown-1 probe. |
| Best-effort Bash-as-bypass speed bump | `PreToolUse` matcher on `Bash`, regex against `tool_input.command` | `preToolUse` matcher `Shell` (or the dedicated `beforeShellExecution` event), regex against the equivalent command field | Portable. `beforeShellExecution` is the more idiomatic Cursor hook for this and additionally supports `"ask"` as a permission value (Claude Code's schema does not expose "ask" as meaningful here). |
| Per-turn advisory reminder | `UserPromptSubmit` hook, `additionalContext` | **No equivalent event.** Cursor's nearest event, `beforeSubmitPrompt`, only returns `{"continue": bool, "user_message": string}` — a gate, not an injector. There is no per-turn `additionalContext`-equivalent output field anywhere in the documented Cursor hook set. | **Not portable as designed.** See Section 8 for the replacement design (`sessionStart` one-shot + always-on `.mdc` rule). |
| Repo-local activation state, kill switch, config resolution | `hooks/optimus-config.js`, pure Node/fs, no Claude-Code-specific API calls | Same Node/fs code runs unmodified under Cursor's hook runtime (hooks are just executables reading stdin/writing stdout) | Fully portable, no changes needed. |
| Slash command `/optimus [on\|off\|status]` | `commands/optimus.md`, Claude Code slash-command frontmatter, `bin/` on `PATH` | Cursor does not have an identical "plugin command with `allowed-tools` frontmatter that runs a PATH binary" primitive in the reviewed docs. Closest analog is a Cursor **skill** (`.cursor/skills/<name>/SKILL.md`) invoked as `/name`, or a legacy `.cursor/commands/*.md` file. | Needs its own small adapter; out of scope for the hook port itself but listed as an open decision in Section 9. |
| Cost/usage reporting (`optimus-stats`) | Reads Claude Code's own undocumented transcript file layout (`~/.claude/projects/<slug>/...`) | `CURSOR_TRANSCRIPT_PATH` env var exists and `transcript_path` is a field on every Cursor hook stdin payload, but **the format of that transcript is not documented in the material reviewed for this spec** | **UNVERIFIED.** See Section 9(d). |
| Enforcement ledger / audit trail (`hooks/optimus-ledger.js`) | `recordEvent(cwd, event)`, pure Node/fs, resolves its own path via the shared `findProjectRoot(cwd)` — no Claude-Code-specific API calls (see Section 1.6) | Same Node/fs module runs unmodified; the Cursor adapter only needs to call it with translated field names (`conversation_id` -> `session_id`; `model`/`tool_use_id`/`cwd` pass through as-is) | Fully portable, no changes needed to the ledger module itself — see Section 1.6's "what a Cursor adapter would need to replicate." The *writing* side is trivial; the caveat is that the ledger-vs-transcript **comparison** `/optimus-stats` builds on top of it inherits Unknown 3 (Section 9(d)) on Cursor, since that comparison's "actual" side still needs a working Cursor transcript reader. |

---

## 3. A capability Cursor has that Claude Code lacks: live session-model visibility

Every Cursor hook payload — on every one of the 21 documented events — carries `model` and
`model_id` in its common stdin fields (per the research this spec is built from). That means a
Cursor `preToolUse` hook can, in principle, gate enforcement on which model is actually running the
session at the moment of the call, with no polling and no race.

This is worth flagging because Optimus's README states the opposite is true for Claude Code, in
two places that are worth quoting exactly rather than summarizing, since this spec must not
misrepresent a decision the maintainer already made deliberately:

From the enforcement table (`README.md:200`):

> `"Only block when the orchestrator is specifically Opus" (model-conditional enforcement) | — |
> Not implemented, deliberately. There is no reliable field carrying the calling model in a
> PreToolUse payload, and the one indirect route (polling the session transcript for the latest
> assistant turn's model) races the hook's own invocation by 150–300ms with no guarantee it
> resolves in time. Optimus enforces by role (main session vs. subagent) instead of by literally
> detecting "is this Opus" — which also means it protects you even if you're driving the
> orchestrator session on a different expensive model.`

From "Known limitations" (`README.md:347-355`):

> `No reliable way to detect the orchestrator's own model from inside a hook. PreToolUse payloads
> don't carry a model field, and neither does the hook process's own environment. The one indirect
> route (polling the session transcript file for the latest assistant turn's message.model) is
> real but races the hook's own invocation — in testing, the entry wasn't flushed to disk yet at
> the moment the hook fired, and needed roughly 150–300ms of polling to appear.`

Both quotes are confirmed accurate against the current `README.md`. If Cursor's `preToolUse`
payload genuinely carries `model`/`model_id` synchronously and reliably (this still needs the same
kind of empirical confirmation Claude Code's absence of the field received — see Section 5's test
plan, which should log this field alongside the subagent probe), the Cursor build could offer
**model-conditional enforcement** — e.g., only enforce when `model` matches an expensive-tier
pattern, mirroring the `EXPENSIVE_MODEL_RE` regex already used for `Agent`/`Task` dispatch checks —
as a capability Claude Code structurally cannot offer today.

This is presented here as an **option to evaluate, not a decided feature**. See open decision (b)
in Section 9. If adopted, it should be a configurable behavior in the shared `decide()` core (see
Section 6), not a hardcoded assumption, since it changes Optimus's enforcement philosophy from
"role-based, host-agnostic" to "role by default, optionally session-model-aware on hosts that
support it" — and the two hosts would then enforce on genuinely different bases, which needs to be
visible in documentation and in `/optimus status`-equivalent output, not silently divergent.

---

## 4. Tool-name mapping between the two hosts

| Claude Code tool | Cursor equivalent | Notes |
|---|---|---|
| `Read` | `Read` | Direct match. |
| `Edit` | `Write` (Cursor does not appear to split "Edit" from "Write" the way Claude Code does — **UNVERIFIED**, confirm during the probe) | Confirm exact Cursor tool name for an in-place edit vs. a full write. |
| `Write` | `Write` | Direct match, pending the Edit/Write split question above. |
| `Grep` | `Grep` | Direct match. |
| `Glob` | No documented 1:1 match in the `preToolUse` matcher list (`Shell, Read, Write, Grep, Delete, Task, MCP:<tool_name>`) | **UNVERIFIED** whether Cursor exposes a distinct glob/file-listing tool name or folds it into `Read`/`Shell`. Must be captured empirically. |
| `WebFetch` | Not in the documented matcher list | **UNVERIFIED / possibly unmatched.** The docs describe the list as covering "Shell, Read, Write, MCP, Task, etc." — the trailing "etc." means the published list is explicitly non-exhaustive. Do not assume absence; test directly. |
| `WebSearch` | Not in the documented matcher list | Same caveat as `WebFetch` — test directly rather than assuming there is no web-search tool name to match on. |
| `NotebookEdit` | Not in the documented matcher list | Likely folds into `Write` or a Jupyter-specific MCP tool; **UNVERIFIED**. |
| `Agent` | `Task` | Cursor's subagent dispatch tool is named `Task`; this is the tool whose `tool_input` needs inspecting for a model-selection field, per the capability mapping in Section 2. |
| `Bash` | `Shell` | Direct conceptual match; Cursor additionally exposes a dedicated `beforeShellExecution` event (see Section 2) as a more idiomatic hook point than matching `Shell` on generic `preToolUse`. |
| *(none)* | `Delete` | Cursor has a distinct `Delete` tool type with no Claude Code equivalent in Optimus's current `WORK_TOOLS` set. Whether Optimus should treat `Delete` as a work tool to deny is an open design question, not decided by this spec — flag it for the maintainer rather than silently including or excluding it. |
| *(none)* | `MCP:<tool_name>` | Cursor's `preToolUse` matcher supports per-MCP-tool matching (`MCP:<tool_name>`), which Claude Code's `PreToolUse` matcher syntax (a plain regex over the tool name) does not do in the same structured way. No action required for parity, but worth knowing the syntax differs. |

The `WebFetch`/`WebSearch`/`Glob`/`NotebookEdit` rows above are the most important open question in
this table: **do not ship a Cursor `WORK_TOOLS`-equivalent set that silently omits these just
because they don't appear in the documented matcher list.** The documentation's own wording
("fires for all tool types... etc.") explicitly disclaims completeness. Capture the real tool names
Cursor's own `preToolUse` payload reports (`tool_name` field) during ordinary read/search/fetch
operations as part of the empirical work in Section 5, and build the Cursor `WORK_TOOLS` set from
what is actually observed, not from the matcher-example list alone.

---

## 5. The two open unknowns — empirical test plans

Both of these must be resolved **before** writing `hooks/optimus-gate-cursor.js` for real. Building
against a guess and discovering the answer later risks shipping something that either deadlocks
every subagent dispatch (Unknown 1) or silently fails to locate its own bundled script (Unknown 2).

### 5.1 Unknown 1 — Subagent exemption (BLOCKING)

**The problem.** Optimus's Claude Code gate exempts subagents by checking
`payload.agent_id || payload.agent_type` *first*, before any other rule, so that a dispatched
subagent's own `Read`/`Grep`/etc. calls are allowed even though the identical tool names are denied
for the main session. Cursor's documented `preToolUse` stdin fields are:

- Common to every hook: `conversation_id`, `generation_id`, `model`, `model_id`, `model_params`,
  `hook_event_name`, `cursor_version`, `workspace_roots`, `user_email`, `transcript_path`.
- `preToolUse`-specific: `tool_name`, `tool_input`, `tool_use_id`, `cwd`, `agent_message`.

None of these is a documented subagent-identity field. `subagent_id`, `subagent_type`,
`parent_conversation_id`, `tool_call_id`, `subagent_model`, `is_parallel_worker`, and `git_branch`
appear only in the `subagentStart` stdin schema — an event that fires once when a subagent begins,
not on every tool call the subagent subsequently makes. The documentation never states whether a
subagent's *internal* tool calls fire `preToolUse` at all, and if they do, whether the
`conversation_id` on that payload is the subagent's own id or its parent's.

**Why this blocks the whole design.** If a subagent's internal `Read` call fires `preToolUse` with
a payload indistinguishable from the main agent's own `Read` call (same `conversation_id`, no
subagent marker), then a Cursor gate that denies `Read` for "the main session" has no way to tell
"main session" from "subagent it just dispatched," and will deny both — total deadlock, and
tool-denial is not a viable enforcement mechanism on Cursor as designed for Claude Code.

**Test plan.**

Step 1 — register a logging probe hook on `preToolUse` that always allows, matching every tool
type. `.cursor/hooks.json` in a scratch test project:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "command": "node ${workspaceFolder}/.cursor/hooks/probe.js"
      }
    ]
  }
}
```

(Confirm the exact top-level shape — `"version"`, whether matchers are required — against a real
Cursor install; this snippet is a starting point based on the reviewed docs' general hooks.json
shape, not a verified-working file. If Cursor requires a `matcher` field the way Claude Code does,
add one that matches every tool name, e.g. `"matcher": ".*"` or the documented wildcard for this
field — confirm the actual wildcard syntax against a real install rather than assuming `.*` is
accepted.)

`.cursor/hooks/probe.js` (~20 lines):

```js
#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const LOG_PATH = path.join(__dirname, 'probe.log');

let raw = '';
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  const entry = {
    loggedAt: new Date().toISOString(),
    envSnapshot: {
      CURSOR_PROJECT_DIR: process.env.CURSOR_PROJECT_DIR,
      CURSOR_TRANSCRIPT_PATH: process.env.CURSOR_TRANSCRIPT_PATH,
    },
    stdin: (() => { try { return JSON.parse(raw); } catch (e) { return { parseError: String(e), raw }; } })(),
  };
  fs.appendFileSync(LOG_PATH, JSON.stringify(entry) + '\n');
  process.stdout.write(JSON.stringify({ permission: 'allow' }));
  process.exit(0);
});
```

Step 2 — procedure:

1. Open a scratch Cursor project with the hook above installed and reload the window so the hook
   registers.
2. Truncate `probe.log`.
3. In the main chat/agent panel, trigger a plain `Read` of some file directly (not via a subagent).
4. Define a test subagent at `.cursor/agents/file-reader.md`:

   ```markdown
   ---
   name: file-reader
   description: Reads a fixed test file and reports its contents. Used only to probe hook payloads.
   model: inherit
   ---

   Read the file `probe-target.txt` in the project root and report its exact contents back
   verbatim. Do nothing else.
   ```

5. Dispatch that subagent explicitly (either via `/file-reader` or via an explicit Task-tool
   invocation asking for `subagent_type: file-reader`), forcing it to perform a `Read` of
   `probe-target.txt` internally.
6. Read back `probe.log` and pull out the two (or more) `preToolUse` entries: the one from step 3
   (main-agent `Read`) and the one(s) from step 5 (subagent's internal `Read`).

Step 3 — diff the two logged payloads for:

(a) **Does the hook fire at all for the subagent's inner call?** If `probe.log` gained no new
    entry during step 5, `preToolUse` does not fire for subagent-internal tool calls at all — note
    this as its own finding, since it changes the design in a different way than "fires but
    indistinguishable" (see decision matrix below).

(b) **Does `conversation_id` differ** between the main-agent entry and the subagent entry? Also
    check `generation_id`, `tool_use_id`, and `cwd` for any difference.

(c) **Any undocumented extra keys** on the subagent entry that don't appear on the main-agent
    entry (e.g., an unlisted `subagent_id`, `agent_type`, `is_subagent`, or similar field the docs
    didn't mention). Also check whether `model`/`model_id` differ between the two entries — the
    subagent's own model (per `subagentStart`'s documented `subagent_model` field, e.g.
    `"claude-sonnet-4-20250514"`) may show up here even if no explicit subagent-identity field
    does, which would itself be a usable (if indirect) signal.

**Decision matrix.**

| Observed outcome | What it means | Design response |
|---|---|---|
| Subagent's inner `preToolUse` payload carries a distinguishing field (documented or not) not present on main-agent calls | Direct port is viable | Build `hooks/optimus-gate-cursor.js` checking that field, exactly analogous to `payload.agent_id \|\| payload.agent_type` today. Document the field even though it's undocumented upstream, and treat it as a fragile, unversioned dependency (flag for re-verification on every Cursor update). |
| Subagent's inner `preToolUse` payload is **byte-for-byte indistinguishable** from a main-agent call on every field except values that would also legitimately vary for the main agent (e.g. `tool_use_id`) | Tool-denial cannot distinguish role directly | Fall back to **state-file correlation**: have a `subagentStart`-hook and `subagentStop`-hook pair write/clear an entry in a sidecar file (e.g. `.optimus/active-subagents.json`) keyed by `conversation_id` (if `subagentStart`'s `parent_conversation_id` matches the `preToolUse` payload's `conversation_id`, or by whatever id turns out to be shared) for the duration between start and stop. `preToolUse` checks this sidecar file to determine whether *some* subagent is currently active in this conversation, since it cannot identify the calling subagent precisely. This is coarser than Claude Code's exemption (it exempts "any tool call while a subagent is outstanding," not "this specific subagent's own calls") and admits a race if Cursor ever runs subagents in parallel within one conversation (`subagentStart`'s own `is_parallel_worker` field suggests it does) — document this explicitly as a known imprecision, not a silent behavior change. |
| Subagent's inner tool calls **do not fire `preToolUse` at all** | There is nothing to gate | Tool-denial for subagents is moot — subagents are unconditionally exempt by construction, which incidentally matches Claude Code's intended *behavior* even though the *mechanism* is completely different. In this case, verify separately whether the **main agent's own** `preToolUse` calls are unaffected (they should still fire normally) before concluding the port is viable on this axis alone. |
| Hooks fire for the subagent's calls but with `permission: "ask"` silently coerced to something unexpected, or exit-code/fail-open semantics behave differently than expected under a subagent context | Enforcement reliability itself is in question | Re-test with a hook that unconditionally denies (`{"permission":"deny"}`) instead of allows, and confirm the subagent's task genuinely fails/is blocked as expected, to rule out `preToolUse` being advisory-only inside a subagent context even when payloads look otherwise normal. |

If the outcome lands in the second row (sidecar correlation) or worse, the maintainer should also
weigh **abandoning tool-denial entirely for the Cursor build** and shipping rules-only enforcement
(an always-on `.cursor/rules/*.mdc` reminder, no hard gate) — strictly advisory, matching the
"100% advisory" tier Optimus's own README already uses for the haiku-vs-sonnet routing decision.
That is a legitimate, smaller-scope outcome of this spec, not a failure of it; record which
scenario actually happened and update Section 6 accordingly before writing any adapter code.

### 5.2 Unknown 2 — Plugin root path resolution

**The problem.** A bundled Cursor plugin's `hooks/hooks.json` needs its `command` string to
resolve the plugin's own installed location, the same way Claude Code's `hooks/hooks.json` uses
`${CLAUDE_PLUGIN_ROOT}` (confirmed working, per this repo's own `hooks/hooks.json` and the README's
discussion of where that variable is and isn't available). For Cursor:

- `${PLUGIN_ROOT}` appears in the Agent-Plugins `mcp.json` example (`"cwd": "${PLUGIN_ROOT}"`).
- `${CURSOR_PLUGIN_ROOT}` appears only in prose in the `beforeMCPExecution` documentation section.
- **Neither name appears in the authoritative env-var table for hook scripts**, which lists only:
  `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`,
  `CURSOR_CODE_REMOTE`, `CLAUDE_PROJECT_DIR`.

So it is currently unknown whether a bundled plugin's `hooks/hooks.json` command string can
reference its own script location via an interpolated variable at all, or whether it must rely on
some other mechanism (a fixed relative path resolved against `CURSOR_PROJECT_DIR`, an absolute path
baked in at install time, or something else not documented in the material reviewed for this spec).
Note also that `CLAUDE_PROJECT_DIR` is listed as present "for compatibility," and `bin/optimus-cli`
already reads exactly that variable (`bin/optimus-cli:22`) — that line of code will keep working
unmodified in a Cursor context for *project directory* resolution; it says nothing about *plugin
root* resolution, which is the separate question this Unknown is about.

**Test plan.** Bundle a hook script that echoes every candidate variable to a log file, install it
as a local plugin (or as a bare `.cursor/hooks.json` if plugin packaging isn't ready yet — this
test only needs the hook to run, not a full plugin manifest), and inspect the log.

`hooks/probe-root.js`:

```js
#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const LOG_PATH = path.join(__dirname, 'probe-root.log');

const entry = {
  loggedAt: new Date().toISOString(),
  __dirname,
  __filename,
  env: {
    CURSOR_PLUGIN_ROOT: process.env.CURSOR_PLUGIN_ROOT,
    PLUGIN_ROOT: process.env.PLUGIN_ROOT,
    CLAUDE_PROJECT_DIR: process.env.CLAUDE_PROJECT_DIR,
    CURSOR_PROJECT_DIR: process.env.CURSOR_PROJECT_DIR,
  },
  // Also record raw argv, in case the interpolated value shows up as a
  // literal (unexpanded) string in a command-line argument rather than
  // as an env var — that would itself be diagnostic.
  argv: process.argv,
};

fs.appendFileSync(LOG_PATH, JSON.stringify(entry, null, 2) + '\n');
process.stdout.write(JSON.stringify({ permission: 'allow' }));
process.exit(0);
```

Register it with a `hooks/hooks.json` command string that *attempts* both interpolation forms, so
the test also directly observes whether Cursor performs the substitution before invoking the
command or passes the literal `${...}` text through unexpanded:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "command": "node \"${CURSOR_PLUGIN_ROOT}/hooks/probe-root.js\" --plugin-root-attempt" },
      { "command": "node \"${PLUGIN_ROOT}/hooks/probe-root.js\" --generic-attempt" }
    ]
  }
}
```

(If Cursor's hooks.json schema only allows one hook per event per file in this position, run these
as two separate test passes rather than simultaneously — confirm the schema's actual cardinality
rules against a real install.)

Trigger any tool call to fire the hook, then inspect `probe-root.log` for: whether the process
actually started (a bad path in the command string would simply fail to launch node at all, which
is itself informative — check Cursor's hook-error surface, if any, for that case); what `__dirname`
resolved to; and what each candidate env var actually contained (unset, empty string, or a real
path). Record the working form (if any) and update Section 6's file tree and install instructions
accordingly. If neither variable resolves, the fallback is almost certainly to have the
install step (Section 6's `optimus-cli install cursor` subcommand) write out an already-fully-
resolved absolute path baked directly into a generated `.cursor/hooks.json`, rather than relying on
any runtime interpolation — note that this makes the generated file non-portable across machines
for the same project (a real cost, to be weighed against Unknown 2 simply having no better answer).

---

## 6. Proposed architecture (contingent on Section 5 passing)

This section describes the target design **assuming** Section 5.1 resolves to "viable" (first or
third row of the decision matrix). If it resolves to the sidecar-correlation fallback, the
`decide()` signature below needs an added `subagentActive: boolean` (or similar) input alongside or
instead of `isSubagent`; if it resolves to "abandon tool-denial," most of this section does not
apply and the Cursor build is rules-only (Section 8's `.mdc` file becomes the entire enforcement
surface, and it is advisory, not hard-enforced — this must be stated plainly in that build's own
README section, not left implicit).

### 6.1 Extracting the host-agnostic core

Today, `hooks/optimus-gate.js` mixes two concerns: the actual policy decision (which tools are
work tools, what makes a model "expensive," what the Bash bypass patterns are) and the Claude-Code-
specific plumbing (parsing Claude Code's exact stdin shape, emitting Claude Code's exact
`hookSpecificOutput` JSON shape, exiting with Claude Code's expected exit codes). Extract the
former into a new pure module, `hooks/optimus-core.js`:

```js
// hooks/optimus-core.js
'use strict';

/**
 * Pure decision function — no I/O, no process.exit, no host-specific
 * knowledge. Both hooks/optimus-gate.js (Claude Code) and
 * hooks/optimus-gate-cursor.js (Cursor) call this and translate the
 * result into their own host's expected output shape.
 *
 * @param {object} input
 * @param {string} input.tool - normalized tool name (see the mapping
 *   table in the spec this was built from; each adapter is responsible
 *   for translating its host's native tool name into this normalized
 *   form before calling decide()).
 * @param {object} input.toolInput - the tool's raw input object.
 * @param {boolean} input.isSubagent - true if this call originates from
 *   a dispatched subagent, not the orchestrator. How each adapter
 *   determines this is entirely host-specific (see Section 5.1).
 * @param {string|null} input.sessionModel - the live session model, if
 *   the host's hook payload provides one (Cursor does; Claude Code does
 *   not — pass null). Only consulted if input.config.modelConditional
 *   is true.
 * @param {{enabled: boolean, modelConditional?: boolean}} input.config -
 *   resolved Optimus config for this project (from optimus-config.js's
 *   getConfig()), plus any host-specific extension fields.
 * @returns {{allow: boolean, reason: string|null}}
 */
function decide({ tool, toolInput, isSubagent, sessionModel, config }) {
  if (!config.enabled) return { allow: true, reason: null };
  if (isSubagent) return { allow: true, reason: null };

  if (config.modelConditional && sessionModel && !EXPENSIVE_MODEL_RE.test(sessionModel)) {
    return { allow: true, reason: null };
  }

  if (tool === 'AGENT_DISPATCH') {
    const model = toolInput && toolInput.model;
    if (typeof model !== 'string' || model.trim() === '') {
      return { allow: false, reason: 'no-model-set' };
    }
    if (EXPENSIVE_MODEL_RE.test(model)) {
      return { allow: false, reason: 'expensive-model-dispatch' };
    }
    return { allow: true, reason: null };
  }

  if (WORK_TOOLS.has(tool)) {
    return { allow: false, reason: 'work-tool-in-orchestrator' };
  }

  if (tool === 'SHELL' && isReadBypassCommand(toolInput && toolInput.command)) {
    return { allow: false, reason: 'shell-read-bypass' };
  }

  return { allow: true, reason: null };
}

module.exports = { decide /*, ... shared constants re-exported as needed */ };
```

(This is a proposed signature and a sketch, not a literal drop-in replacement — the exact shape of
`reason` as an enum-like string vs. a full human-readable message, and whether the *wording* of
deny messages also moves into `optimus-core.js` or stays in each adapter, is an implementation
detail left to whoever writes the code; the important constraint is that `WORK_TOOLS`,
`EXPENSIVE_MODEL_RE`, the Bash/Shell bypass pattern list, and the ordering of checks live in exactly
one place, not duplicated between two adapters.)

`hooks/optimus-gate.js` becomes a thin Claude Code adapter: parse Claude Code's stdin shape,
normalize `tool_name` (`Agent` → `AGENT_DISPATCH`, `Bash` → `SHELL`, others pass through), call
`decide()`, translate `{allow, reason}` into Claude Code's `hookSpecificOutput` JSON, preserving the
existing kill-switch check, JSON-parse-error fail-open, and top-level try/catch fail-open exactly as
they exist today (these are host-plumbing concerns, not policy, so they belong in the adapter, not
the core — but they must not regress).

### 6.2 The Cursor adapter

`hooks/optimus-gate-cursor.js` — new file. Reads Cursor's `preToolUse` stdin shape
(`tool_name`, `tool_input`, `tool_use_id`, `cwd`, `agent_message`, plus the common fields
`conversation_id`, `model`, `model_id`, etc.), determines `isSubagent` using whatever mechanism
Section 5.1's probe validated, normalizes `tool_name` per the mapping table in Section 4, calls
`decide()`, and translates the result into Cursor's expected output shape:

```json
{ "permission": "allow" }
```

or

```json
{ "permission": "deny", "user_message": "<short user-facing text>", "agent_message": "<text the agent model sees, guiding it to redispatch>" }
```

Cursor's `preToolUse` output schema also accepts `updated_input`, which Claude Code's schema does
not expose in the same way — no current Optimus rule needs it, so leave it unused rather than
inventing a use for it.

`hooks/optimus-config.js` is **untouched** — it's already pure Node/fs with no Claude-Code-specific
API surface, and both adapters import it directly. `hooks/optimus-ledger.js` is untouched for the
same reason (see Section 1.6): `optimus-gate-cursor.js` must call its `recordEvent(cwd, event)` at
the same points `optimus-gate.js` already does — after `decide()` returns, translating Cursor's
`conversation_id` into the ledger's `session_id` field — rather than growing a second ledger writer.

### 6.3 New files and their responsibilities

```
Optimus/
├── hooks/
│   ├── hooks.json                # unchanged — Claude Code's hook file
│   ├── optimus-gate.js           # Claude Code adapter (thin — parses/emits CC shapes, calls decide())
│   ├── optimus-gate-cursor.js    # NEW — Cursor adapter (thin — parses/emits Cursor shapes, calls decide())
│   ├── optimus-reinforce.js      # unchanged — Claude Code UserPromptSubmit hook
│   ├── optimus-core.js           # NEW — extracted pure decision logic, shared by both adapters
│   ├── optimus-config.js         # unchanged — shared config/kill-switch helpers
│   └── optimus-ledger.js         # unchanged — shared enforcement-event ledger (see Section 1.6);
│                                  #   both adapters call recordEvent() at the equivalent points
├── cursor/
│   ├── hooks.json                # NEW — Cursor hook registration template (preToolUse -> optimus-gate-cursor.js,
│   │                              #        beforeShellExecution -> same or a thin wrapper, sessionStart -> one-shot reminder)
│   └── optimus.mdc               # NEW — alwaysApply rule carrying the reinforce text (see Section 8)
├── bin/
│   ├── optimus-cli               # extended — new `install cursor` subcommand (see 6.4)
│   └── optimus-stats             # unchanged; its ledger-reading half (Section 9(d) addendum) needs
│                                  #   no Cursor-specific code once the ledger is wired up above — only
│                                  #   its transcript-reading half remains gated on Section 9(d) itself
```

`cursor/hooks.json` is a **template**, not something Cursor reads directly from this location — it
exists in the repo so `optimus-cli install cursor` has a known-good source to copy/render into a
target project's `.cursor/hooks.json`. Its exact command strings depend on the outcome of Unknown 2
(Section 5.2): if plugin-root interpolation works, it can reference the plugin's own bundled script
path; if it doesn't, the install step must render fully-resolved absolute paths into the generated
file.

`cursor/optimus.mdc` is the rules-file draft described in Section 8.

### 6.4 `optimus-cli install cursor`

Add a subcommand to `bin/optimus-cli` (alongside the existing `on`/`off`/`status` cases) that:

1. Resolves the target project directory the same way the existing commands do
   (`process.env.CLAUDE_PROJECT_DIR || process.cwd()` — note this will need a
   Cursor-appropriate equivalent, likely `process.env.CURSOR_PROJECT_DIR`, checked first, falling
   back to the existing variable for compatibility, since both are documented as available to hook
   scripts).
2. Writes `.cursor/hooks.json` into that project, rendered from the `cursor/hooks.json` template
   (with paths resolved per whatever Section 5.2 determined).
3. Writes `.cursor/rules/optimus.mdc` into that project, copied from `cursor/optimus.mdc`.
4. Prints a status summary analogous to the existing `printStatus()` — confirming what was written
   and where — rather than silently succeeding.

This subcommand does **not** need to touch `.optimus/config.json` handling — that stays exactly as
it is, since `optimus-config.js` is shared and unmodified.

---

## 7. Tool-name mapping

See Section 4 above — kept as a single table rather than duplicated here, since it applies equally
to the architecture in Section 6.

---

## 8. Porting the reinforce hook

Cursor has no event equivalent to Claude Code's `UserPromptSubmit` + `additionalContext` pairing.
The closest-named event, `beforeSubmitPrompt`, takes `{"prompt": "...", "attachments": [...]}` as
input and returns **only** `{"continue": true|false, "user_message": "..."}` — per the research
this spec is built from, `user_message` is documented as "Message shown to the user when the prompt
is blocked." There is no `additional_context`, no `updated_prompt`, no `agent_message` on this
event's output. **It is a gate, not an injector** — it can refuse to submit a prompt and tell the
user why, but it cannot inject new context into the conversation the way Claude Code's
`UserPromptSubmit` hook does. Do not attempt to repurpose it as an injection point; it structurally
cannot do that job.

The replacement design has two parts:

**Part 1 — `sessionStart` one-shot injection.** `sessionStart`'s output schema includes
`additional_context`: "context to add to conversation's initial system context." This fires once,
at conversation creation — it cannot re-inject per turn the way `optimus-reinforce.js` does today,
but it covers the same role a Claude Code `SessionStart` hook would (Optimus doesn't currently use
one, relying entirely on the per-turn `UserPromptSubmit` mechanism instead, per the README's own
"Continuous reinforcement, not just a one-shot nudge" section — so this is genuinely new coverage
for Cursor, not a straight port of an existing Claude Code hook).

**Part 2 — always-on `.mdc` rule**, to cover what the one-shot injection can't: persistence across
a long session. Cursor rules live at `.cursor/rules/*.mdc` (plain `.md` in that directory is
ignored) with frontmatter `description`, `globs` (a comma-separated bare string, not a YAML list),
and `alwaysApply` (bool) — the docs state "If alwaysApply is true, the rule will be applied to every
chat session." This is the mechanism that actually substitutes for Claude Code's per-turn
`UserPromptSubmit` reinjection, since a rule with `alwaysApply: true` is present in every turn's
context, not just the first.

Draft of `cursor/optimus.mdc`:

```markdown
---
description: Optimus orchestrator policy reminder — keeps the main agent delegating work instead of doing it directly
globs:
alwaysApply: true
---

Optimus is active for this project: you are the orchestrator, not the worker.

Read, Edit, Write, Grep, Glob, WebFetch, WebSearch, and NotebookEdit are blocked in this session
where Cursor's hooks enforce it — delegate this work via the Task tool instead.

Every Task dispatch must name a model explicitly: use a cheap/fast model for simple, mechanical
work (file lookups, boilerplate edits, running a command and reporting its output), and a stronger
model only for work that genuinely needs judgement (ambiguous requirements, design tradeoffs,
non-trivial debugging). Never dispatch a subagent on the same expensive model driving this session.

Shell stays open for orchestration (git, builds, tests, process control) — but prefer a delegated
subagent over cat/grep/head/find for reading or searching files.

Answer minimally: report the outcome and anything the user must act on, nothing else. No preamble,
no recap of what you just did, no summary tables, no options you did not take. Explain in technical
depth only where the material genuinely requires it.
```

Notes on this draft:

- The `globs:` field is left empty deliberately — this rule is meant to apply everywhere in the
  project, not scoped to a file pattern; confirm against a real Cursor install whether an empty
  `globs:` combined with `alwaysApply: true` is the correct way to express "no file-pattern
  restriction," or whether the field should be omitted entirely.
- The wording deliberately avoids naming a specific model tier (`haiku`/`sonnet`) the way
  `optimus-reinforce.js`'s Claude-Code text does, since Cursor's own model-naming and
  `model: inherit` conventions for `.cursor/agents/*.md` may not map onto Anthropic's tier names at
  all if the user has non-Anthropic models configured. This is a judgment call, not a settled
  decision — the maintainer may prefer to keep it concrete and Anthropic-specific if Optimus is
  only ever going to be used with Claude models in Cursor. Flag for the maintainer's call rather
  than silently deciding.
- This file does not enforce anything by itself, exactly like `optimus-reinforce.js` today —
  actual enforcement is `optimus-gate-cursor.js`'s job.

---

## 9. Open decisions requiring the maintainer's call

**(a) Probe-first vs. build-and-debug-live.**
*Recommendation:* probe-first, exactly as Section 5 specifies. *Tradeoff:* probing costs a day or
two of setup (a scratch Cursor project, a test subagent definition, manual triggering) before any
"real" adapter code gets written, which can feel like it's not making visible progress. But building
`optimus-gate-cursor.js` against a guessed subagent-exemption mechanism and discovering later that
subagent tool calls are indistinguishable from main-agent calls means throwing away or fundamentally
restructuring the adapter after the fact — and worse, if it ships and only fails intermittently
(e.g., only under `is_parallel_worker: true` conditions), it could silently deadlock a user's
subagents in production before anyone notices. The cost of being wrong here is much higher than the
cost of confirming first.

**(b) Gate enforcement on session model (Opus-only) vs. always-on parity with Claude Code.**
*Recommendation:* ship always-on (role-based only, matching Claude Code's current behavior) first,
and treat model-conditional enforcement (Section 3) as a fast-follow, opt-in config flag rather than
the default. *Tradeoff:* always-on is simpler, matches the mental model established by the existing
README table, and doesn't create two hosts with silently different policies out of the box — but it
forgoes a capability that's uniquely available on Cursor and that some users may specifically want
(e.g., "only make me delegate when I'm burning the expensive model, let me drive directly on a cheap
one"). If added, it must be visible in Cursor's `/optimus status`-equivalent output as a
Cursor-only behavior, not a hidden divergence from the Claude Code build.

**(c) Ship as plain `.cursor/hooks.json` install vs. a full `.cursor-plugin/plugin.json` package.**
*Recommendation:* ship the plain install path first (`optimus-cli install cursor` writing directly
into the target project, as specified in Section 6.4), and treat full plugin packaging + Cursor
Marketplace submission as a separate, later effort. *Tradeoff:* a real Cursor plugin package
(`.cursor-plugin/plugin.json` with `hooks`, `rules`, `agents` fields, auto-discovery, and eventual
marketplace listing) gives users a one-step, versioned install exactly like the existing Claude Code
`claude plugin marketplace add` flow — but it requires public git hosting, a manual Cursor review
process, and an open-source requirement (already satisfied — this repo is GPLv3), and it introduces
Unknown 2 (plugin-root path resolution) as a hard blocker in a way that a plain per-project
`.cursor/hooks.json` file written with fully-resolved absolute paths does not. Solve the simpler
version first; upgrade to packaged distribution once Unknown 2 has a confirmed answer.

**(d) Does `optimus-stats` get a Cursor transcript reader?**
*Recommendation:* not in this initial port. *Tradeoff:* `CURSOR_TRANSCRIPT_PATH` exists as a
documented env var and `transcript_path` is a field on every Cursor hook's stdin payload, so the
*location* of Cursor's transcript is knowable — but its **format** is undocumented in the material
this spec was built from (unlike Claude Code's `.jsonl` transcript format, which
`bin/optimus-stats` already has working, tested parsing logic for, including the specific
subagent-usage-undercounting bug it corrects — see Section 1.3). Writing a Cursor-side stats reader
without first inspecting a real transcript file risks the same category of undercounting bug
`optimus-stats` was specifically built to avoid, silently. If this is wanted, it needs its own
empirical step (dump a real `transcript_path` file from a real Cursor session and inspect its
structure) before any code is written — treat it as a third Unknown alongside Section 5's two, not
as a trivial follow-on.

*Addendum, now that `bin/optimus-stats` also reports off the ledger (Section 1.6):* that new
half of `optimus-stats` splits cleanly along the same Unknown-3 line. Its "Enforcement ledger
summary" block (dispatch/deny/nudge counts) reads only `hooks/optimus-ledger.js`'s output —
`.optimus/state/events.jsonl` — which is repo-local and entirely independent of Claude Code's or
Cursor's transcript format. That half would work on a Cursor port with **zero** additional code
once the adapter is calling `recordEvent()` per Section 1.6, regardless of how Unknown 3 above
resolves. Its "Requested-vs-actual model family" block, in contrast, needs the *actual* side — a
per-family tally over resolved model ids read from real subagent transcripts — and that half is
gated on Unknown 3 exactly like the rest of `optimus-stats`'s transcript reading. Do not conflate
the two: a Cursor build can ship enforcement-count reporting today (once the gate writes to the
ledger there) while still correctly reporting "no data" for the drift comparison until Unknown 3
is resolved.

---

## 10. Testing

The existing pattern in `tests/` (fixture JSON payloads + a shell harness that feeds them to the
gate script and checks the allow/deny outcome, per `tests/run-gate-tests.sh` and
`tests/fixtures/*.json` as read in Section 1.5) extends naturally:

- **Core `decide()` gets direct unit tests**, independent of either host's payload shape — call
  `decide({ tool, toolInput, isSubagent, sessionModel, config })` directly with plain JS objects and
  assert on `{allow, reason}`. This is new: today `optimus-gate.js` can only be tested end-to-end
  via stdin/stdout, because the decision logic and the Claude-Code plumbing are fused. Once
  extracted, the core deserves fast, direct tests that don't require spawning a `node` subprocess
  per case the way `run-gate-tests.sh` currently does.
- **`hooks/optimus-gate.js` (Claude Code adapter) keeps its existing fixture-driven tests
  unmodified** — `tests/run-gate-tests.sh` and `tests/fixtures/*.json` should not need to change at
  all if the extraction in Section 6.1 is done correctly (same inputs, same outputs, only the
  internals move). Re-running the existing suite after the refactor is the regression check that
  the extraction didn't change Claude Code behavior.
- **Add a `tests/fixtures/cursor/` directory** with captured-shape Cursor `preToolUse` payloads,
  built from what the Section 5 probes actually observed (not from the docs' example payloads
  alone, since the probes may surface undocumented fields) — mirroring the existing fixture set:
  a main-agent read, a subagent's internal read (in whatever shape Section 5.1 determined actually
  distinguishes it, or documented as "no distinguishing shape — sidecar-file test instead" if that's
  the outcome), a `Task` dispatch with/without a model, a `Shell` command matching and not matching
  the bypass patterns.
- **`hooks/optimus-gate-cursor.js` gets thin shape tests** analogous to the Claude Code adapter's:
  feed each Cursor fixture on stdin, assert the emitted `{"permission": ...}` JSON matches
  expectations. These tests should be shallow by design — the interesting logic already has direct
  coverage on `decide()`; the adapter tests exist only to catch parsing/shape-translation bugs at
  the boundary.
- If the sidecar-correlation fallback (Section 5.1) is what's actually built, add tests for the
  sidecar file's own lifecycle (`subagentStart` writes an entry, `subagentStop` removes it,
  `preToolUse` consults it correctly) as its own small test group, since that's new stateful logic
  with no Claude Code analog to inherit test coverage from.

---

## 11. Risks

- **Hooks fail open on any non-zero, non-2 exit code unless `"failClosed": true` is set per script**
  in `hooks.json`. This mirrors Optimus's own deliberate Claude Code design (fail open on internal
  errors, per `hooks/optimus-gate.js`'s own header comment and the kill-switch rationale in the
  README) — but it means a genuine bug in `optimus-gate-cursor.js` that crashes before it can write
  valid JSON will silently *allow* the very thing it was supposed to deny, not block it. This is
  consistent with the existing philosophy ("a bug in this hook must never wedge a session") and
  should stay consistent, but it must be stated plainly in the Cursor build's own documentation, not
  left as a surprise a user discovers by having enforcement silently not apply.
- **Exit code 2 means "block" (`permission: "deny"`) on Cursor**, distinct from Claude Code's model
  of "exit 0 with deny JSON on stdout." Adapter code must not accidentally exit 2 for an *allow*
  result or exit 0-with-no-output expecting that to mean deny — get this backwards and the adapter
  either blocks everything or blocks nothing, silently.
- **Cursor's hook documentation may drift.** Both Unknowns in Section 5, and several rows in the
  tool-name mapping table (Section 4), are explicitly flagged as based on documentation that may not
  be exhaustive (the "etc." in the `preToolUse` tool-type list) or may change as Cursor's hooks
  system matures past whatever version was current when this spec's research was gathered
  (2026-09-09). Re-verify against current docs before relying on any UNVERIFIED/UNDOCUMENTED item in
  this spec for a production release, not just once during initial development.
- **Public marketplace distribution requires manual review and an open-source repository.** This
  repo already satisfies the open-source requirement (GPLv3), but the review step is a human
  process with unknown turnaround time — do not plan a release date around marketplace acceptance
  without accounting for that.
- **Enterprise Cursor installs block local plugin imports by default** ("Allow Local Plugin
  Imports" admin toggle, off by default). Anyone testing this port inside an Enterprise-managed
  Cursor installation may need that toggle enabled by an admin before `~/.cursor/plugins/local/`
  symlink installs will even load — this can look identical to "the plugin is broken" if not known
  in advance.
- **Enterprise and Team `hooks.json` precedence overrides Project and User `hooks.json`.** A
  developer testing Optimus's Cursor hooks inside an org-managed Cursor install may have their
  project-level `.cursor/hooks.json` silently overridden or merged with an org policy they can't see
  from the project alone — worth knowing before concluding a hook "isn't firing" when it may simply
  be shadowed.

---

## 12. Sources

All Cursor-side facts in this spec (Sections 2 through 9, except where explicitly marked UNVERIFIED
against a live Cursor install) were gathered from the following official Cursor documentation pages
on 2026-09-09:

- https://cursor.com/docs/hooks
- https://cursor.com/docs/subagents
- https://cursor.com/docs/plugins
- https://cursor.com/docs/reference/plugins
- https://cursor.com/docs/rules

All Claude Code / Optimus-side facts in Section 1 were read directly from this repository's own
source files as of 2026-09-09: `hooks/hooks.json`, `hooks/optimus-gate.js`,
`hooks/optimus-reinforce.js`, `hooks/optimus-config.js`, `bin/optimus-cli`, `bin/optimus-stats`,
`commands/optimus.md`, `commands/optimus-stats.md`, `.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`, `README.md`, `tests/run-gate-tests.sh`, and
`tests/fixtures/*.json`.
