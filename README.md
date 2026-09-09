# Optimus

A Claude Code plugin that keeps an expensive orchestrator model doing
orchestration, and pushes the actual work — reading files, searching code,
editing, running lookups — onto cheaper delegated models.

## The problem

Opus is expensive, and its real value is judgement: deciding what to build,
untangling ambiguous requirements, catching subtle bugs, planning multi-step
work. None of that requires Opus to personally `cat` a file, `grep` a
codebase, or write boilerplate. Left alone, though, an orchestrator model
does exactly that — and when it dispatches a subagent without saying which
model to use, that subagent silently inherits the orchestrator's own
(expensive) model, so the delegation doesn't even save anything.

Optimus turns that into policy, enforced where it can actually be enforced:
while it's active for a project, the main session is orchestrator-only. Work
tools are blocked. Every subagent dispatch must name a model. Subagents
themselves are completely exempt — they're where the real work happens now,
on `haiku` or `sonnet` instead of the model running the show.

## Install

```bash
claude plugin marketplace add pietermyb/optimus
claude plugin install optimus@Optimus
```

For local development, or to try it without publishing anywhere:

```bash
claude --plugin-dir /path/to/Optimus
```

## Per-project activation

Optimus does nothing until you turn it on, and it's **per project, not
global** — activating it in one repo does not affect any other session or
project.

```
/optimus on       # activate for the current project
/optimus off       # deactivate for the current project
/optimus status    # show current state, config file location, kill switch
```

State lives in `.optimus/config.json` inside the project (or the nearest
parent directory that has one — the same repo-local walk-up-from-cwd pattern
used for lookup). It is **not** a global flag file. This is a deliberate
departure from how some other plugins persist "mode" state (a single flag
under `~/.claude/`, which leaks across every concurrent session regardless of
project) — Optimus's entire value proposition is per-project policy, so
per-project state is the only design that makes sense. `/optimus on/off`
writes that file directly and deterministically from the command's own
script; it does not try to infer intent from free-text prompts.

You'll probably want to add `.optimus/` to your project's own `.gitignore`
if you don't want to share activation state through the repo (this plugin's
own `.gitignore` does exactly that).

## Commands

### `/optimus [on|off|status]`

Activates, deactivates, or reports Optimus's state for the current project.
Safe to run any time; `status` is read-only.

```
$ /optimus status
Optimus status for this project
  project dir  : /Users/you/code/my-app
  config file  : /Users/you/code/my-app/.optimus/config.json
  activated    : YES — orchestrator role is enforced here
  kill switch  : off
```

### `/optimus-stats`

Reports token usage by model, subagent dispatch counts, orchestrator vs.
delegated split, and an **estimated** saving versus running all that
delegated work on the expensive tier instead. Read-only, safe to run any
time, and degrades to a plain "no data yet" message rather than erroring
when there's no session history for the project yet.

```
Orchestrator usage (main session, by model):
  claude-opus-5: turns=32 input=64 output=15821 cache_write=139012 cache_read=895136 cost=$1.7122

Delegated usage (subagent transcripts, by model):
  claude-sonnet-5: turns=4 input=8 output=408 cache_write=61812 cache_read=61627 cost=$0.1710
  claude-haiku-4-5: turns=39 input=336 output=5914 cache_write=160449 cache_read=881407 cost=$0.3186

Estimated saving vs. running delegated work on the expensive (opus) tier:
  actual delegated cost     : $0.4896
  hypothetical cost on opus : $2.0204
  estimated saving          : $1.5309
  ESTIMATE, not a fact: assumes opus would have used the same token volume for the same work.
```

It reads token usage straight out of Claude Code's own local transcript
files — there's no official API for this. Two things a naive version of this
command would get wrong, that this one specifically corrects:

- **Subagent usage lives in separate transcript files**
  (`<session-dir>/subagents/agent-<id>.jsonl`), not in the parent session's
  transcript. They have to be walked explicitly, or "delegated usage" is
  just empty.
- **The convenient rollup Claude Code attaches to the parent's `Agent`
  tool-result is not a reliable total.** It only reflects the subagent's
  *last* assistant turn, so it silently under-counts any subagent that used
  more than one turn — i.e., the normal case, any time the subagent used a
  tool itself. This command sums every assistant turn in the actual subagent
  transcript instead.

Cache-read tokens are reported separately from fresh input tokens (they're
priced very differently). Pricing is printed in the output itself, with the
date it was captured, specifically so a stale rate is visible rather than
silently wrong — verify current numbers at anthropic.com/pricing before
trusting the dollar figures for anything real. Cache-token pricing
specifically is an **assumption** (standard published multipliers over base
input price), not independently verified — also stated in the output, not
just here.

## The kill switch

```bash
export OPTIMUS_DISABLED=1
```

Set this and every Optimus hook becomes a no-op immediately — globally,
regardless of which project's `.optimus/config.json` says. This exists
because a hook is code, code has bugs, and a hook that can deny tool calls
must never be able to *wedge* a session with no way out. If something about
Optimus's enforcement is ever blocking work it shouldn't, this is the
escape hatch — flip it, finish what you're doing, file an issue, unset it.

It is intentionally an env var (not a repo-local file) so it works no matter
which project you're in and can't itself be blocked by anything Optimus
controls.

## What's hard-enforced vs. advisory

This table is the most important part of this README. Read it before
assuming Optimus can do more than it actually can.

| Policy | Enforced how | Hard-enforced or advisory? |
|---|---|---|
| Subagent tool calls are always exempt from every rule below | `PreToolUse` hook checks for `agent_id`/`agent_type` on the payload | **Hard-enforced.** This field is reliably present on every subagent-originated tool call and absent from the orchestrator's own, in every payload observed. |
| Read/Edit/Write/Grep/Glob/WebFetch/WebSearch/NotebookEdit are blocked in the main session while Optimus is active | `PreToolUse` hook denies these tool names outright (after the subagent exemption and the per-project activation check) | **Hard-enforced.** The hook runs deterministically on every matching tool call; there is no model cooperation required. |
| Every `Agent` dispatch must name a model | `PreToolUse` hook denies any `Agent` call whose `tool_input.model` is missing or names the expensive tier | **Hard-enforced.** `tool_input` is handed to the hook synchronously as part of the event — no race, no polling, no guessing. |
| "Only block when the orchestrator is specifically Opus" (model-conditional enforcement) | — | **Not implemented, deliberately.** There is no reliable field carrying the calling model in a `PreToolUse` payload, and the one indirect route (polling the session transcript for the latest assistant turn's model) races the hook's own invocation by 150–300ms with no guarantee it resolves in time. Optimus enforces by **role** (main session vs. subagent) instead of by literally detecting "is this Opus" — which also means it protects you even if you're driving the orchestrator session on a different expensive model. |
| Bash is open for orchestration (git, builds, tests, flashing, process control) | Not blocked by tool name | By design — Bash has to stay open for real orchestration work. |
| Bash used as a read/search bypass (`cat file.txt`, bare `grep foo`, etc.) | `PreToolUse` hook pattern-matches `tool_input.command` against a narrow set of "this looks like a plain read" regexes and denies those specifically | **Best-effort only, not a security boundary.** During testing, a model's first instinct for "read a file" was `Bash: cat`, unprompted — so leaving Bash open at all is only meaningful policy if the obvious literal bypass has *some* friction. But the underlying classification ("is this command orchestration or a disguised read") is fundamentally gameable: `awk '{print}' file`, a heredoc, `python3 -c "print(open('x').read())"`, piping through `xargs cat`, and plenty more all sail straight through. Treat the Bash check as a speed bump for the casual/unprompted case, not a wall. |
| Choosing `haiku` vs `sonnet` for a given delegated task | Reminder text in the deny messages and the per-turn `UserPromptSubmit` reinforcement | **100% advisory.** A hook only sees a string (`tool_input.prompt`); judging whether a task is "simple" or needs real judgement is a semantic call about the task's content, not something a length or keyword heuristic can reliably make. The one thing Optimus *does* enforce here is that a model is named at all, and that it isn't the expensive tier — never which specific cheaper model is the "correct" choice. |
| Per-project on/off | `/optimus` writes/reads `.optimus/config.json`; every hook checks it first | **Hard-enforced** as a gate — if it says off, or the file's missing, every hook allows everything. |
| Kill switch | `OPTIMUS_DISABLED` env var, checked first in every hook | **Hard-enforced**, and takes priority over everything else, including "activated". |

## Architecture

```
Optimus/
├── .claude-plugin/
│   ├── plugin.json          # plugin manifest — deliberately no "hooks" key, see below
│   └── marketplace.json     # lets `claude plugin marketplace add <owner>/Optimus` find it
├── hooks/
│   ├── hooks.json           # THE conventional path Claude Code's hook loader honors
│   ├── optimus-gate.js      # PreToolUse: subagent exemption, work-tool deny, Agent model check, Bash speed bump
│   ├── optimus-reinforce.js # UserPromptSubmit: per-turn policy reminder (decays otherwise, see below)
│   └── optimus-config.js    # shared: repo-local config resolution, kill-switch check, safe file I/O
├── bin/
│   ├── optimus-cli          # implementation behind /optimus — reads or writes .optimus/config.json
│   └── optimus-stats        # implementation behind /optimus-stats — walks transcripts, computes cost/savings
├── commands/
│   ├── optimus.md           # /optimus — invokes bin/optimus-cli via PATH
│   └── optimus-stats.md     # /optimus-stats — invokes bin/optimus-stats via PATH
├── tests/
│   ├── fixtures/*.json      # captured-shape PreToolUse payloads (main session, subagent, Agent dispatches, Bash)
│   └── run-gate-tests.sh    # feeds each fixture to optimus-gate.js and checks the allow/deny outcome
├── README.md
├── LICENSE
└── .gitignore
```

### `hooks/hooks.json` — naming matters, and this is not hypothetical

Claude Code's plugin hook loader reliably picks up hook configuration in
exactly two shapes: a `"hooks"` object embedded directly inline inside
`.claude-plugin/plugin.json`, or (with no `"hooks"` key in `plugin.json` at
all) a file at the **literal, conventional path `hooks/hooks.json`**. Every
plugin confirmed working locally during this plugin's research used one of
those two patterns. A plugin found installed and enabled with **no hooks
firing at all** turned out to point its `plugin.json` `"hooks"` key at a
different filename (`./hooks/claude-codex-hooks.json`) — a perfectly valid
hook file, just not the one Claude Code's own loader was looking for, sitting
right next to a conventionally-named `hooks/hooks.json` that was never
referenced. It installed and enabled with no error of any kind. It just
silently did nothing.

**If you fork this plugin: do not rename or relocate `hooks/hooks.json`, and
do not add a `"hooks"` string-path key to `plugin.json` pointing somewhere
else.** Both are exactly how the failure above happened. If you ever target
another agent host (Codex, Cursor, etc.) alongside Claude Code, give that
host its own separate top-level manifest file rather than repointing this
one.

### The `bin/` + PATH mechanism — not `CLAUDE_PLUGIN_ROOT`, and here's why

Hook `command` strings in `hooks/hooks.json` can reference
`${CLAUDE_PLUGIN_ROOT}` — that's confirmed to work reliably. **A slash
command's own `!`-prefixed inline bash execution is a different code path,
and `CLAUDE_PLUGIN_ROOT` is not set there** — verified directly: it resolves
to an empty string, no error, no warning, just silently absent, which is
exactly the kind of failure this plugin's own hook-naming warning above is
about. What Claude Code *does* do is add every loaded plugin's own `bin/`
directory to `PATH` for the duration of the session (confirmed by dumping
the environment from inside a running session). So `/optimus` and
`/optimus-stats` invoke their implementation scripts by bare name
(`optimus-cli`, `optimus-stats`) via that `PATH` entry, rather than by
constructing a path through a variable that isn't actually available in
that context. If you add more commands, follow the same pattern — don't
reach for `$CLAUDE_PLUGIN_ROOT` inside a command's `!`-execution block.

### Why subagents are unconditionally exempt

This is the mechanism the entire plugin depends on, so it's worth being
explicit about it here too, not just in code comments. A dispatched
subagent's tool calls share the exact same `session_id` as the orchestrator
that dispatched it — `session_id` cannot tell them apart. What *does* tell
them apart, reliably, in every payload: a subagent's own tool-call hooks
carry `agent_id` and `agent_type`; the orchestrator's own tool calls never
do. `optimus-gate.js` checks for that field **before** checking anything
else — before the kill switch's own project-config lookup, even — so a bug
anywhere else in the gate can never accidentally start blocking the workers
this plugin exists to unblock.

### Continuous reinforcement, not just a one-shot nudge

`optimus-reinforce.js` runs on `UserPromptSubmit` and re-injects a short
policy reminder on every turn Optimus is active, rather than relying on a
single `SessionStart` injection. A one-shot injection decays across a long
session — especially past context compaction, or once other plugins add
their own competing instructions. This reminder is advisory text, same as
everything else in the "advisory" row of the table above — it doesn't
enforce anything by itself, `optimus-gate.js` does that — but it measurably
changed model behavior in testing (the orchestrator started delegating
proactively instead of only after being denied once).

## Known limitations

- **No reliable way to detect the orchestrator's own model from inside a
  hook.** `PreToolUse` payloads don't carry a `model` field, and neither
  does the hook process's own environment. The one indirect route (polling
  the session transcript file for the latest assistant turn's `message.model`)
  is real but races the hook's own invocation — in testing, the entry
  wasn't flushed to disk yet at the moment the hook fired, and needed roughly
  150–300ms of polling to appear. That's undocumented write-flush timing,
  not a supported API, and not something worth building a hard boundary on.
  Optimus enforces by session **role** instead (see the table above).
- **Bash can route around the Read/Grep/etc. denial**, by a model that
  chooses `cat`/`grep`/`sed` instead of the named tools — observed directly
  and unprompted during testing. The pattern-based Bash check narrows this
  but does not close it; see the enforcement table.
- **Haiku-vs-Sonnet routing is advisory text**, not something the plugin can
  verify or correct after the fact. Optimus enforces that a model is named
  and isn't the expensive tier; it does not and cannot judge whether the
  *specific* cheaper model chosen was the right call for the task.
  Perfect world - lookups/mechanical edits to Haiku, judgement calls to Sonnet.
- **Token/cost stats depend on Claude Code's transcript file layout**
  (`~/.claude/projects/<slug>/`, `<session-id>/subagents/agent-<id>.jsonl`)
  and an empirically-observed project-slug format (cwd path separators
  replaced with dashes) — all undocumented implementation details, not a
  stable public API. A future Claude Code version could change this layout
  without warning; `/optimus-stats` degrades to "no data" rather than
  crashing if the expected directory just isn't there, but a *changed*
  layout it doesn't recognize would look the same as "no data yet" rather
  than raising a clear error. If stats stop showing up after a Claude Code
  update, this is the first place to look.
- **Pricing figures are a point-in-time snapshot** printed directly in
  `/optimus-stats` output, dated, specifically so a stale number is visible
  rather than silently wrong. Verify at anthropic.com/pricing before relying
  on the dollar figures for anything that matters. Cache-token pricing
  specifically is an assumption (standard published multipliers), not
  independently re-verified.

## License

GPLv3 — see [LICENSE](LICENSE).
