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

### Claude Code

```bash
claude plugin marketplace add pietermyb/optimus
claude plugin install optimus@Optimus
```

Local development: `claude --plugin-dir /path/to/Optimus`.

### Cursor

```bash
npm install -g git+https://github.com/pietermyb/optimus.git
cd your-project
optimus-cli install cursor
optimus-cli on
```

Puts `optimus-cli`/`optimus-stats` on `PATH` and writes `.cursor/hooks.json`
+ `.cursor/rules/optimus.mdc` into the current project. Hooks reload on
write; the rule may need **Developer: Reload Window** to pick up. `npx`
and from-source alternatives, plus every Cursor-specific behavior (host
differences, quirks, Claude-Code-plugin coexistence), are in
[how_it_works.md](how_it_works.md#cursor-support).

Both hosts share one policy core (`hooks/optimus-core.js`), so the rules
are identical by construction, not by discipline.

## Per-project activation

Optimus does nothing until you turn it on, and it's **per project, not
global** — activating it in one repo does not affect any other session.

```
/optimus on       # activate for the current project
/optimus off       # deactivate for the current project
/optimus status    # show current state, config file location, kill switch
```

State lives in `.optimus/config.json` inside the project (nearest parent
directory that has one), written directly by `/optimus on`/`off` — not a
global flag file, not inferred from free-text prompts. Add `.optimus/` to
your project's `.gitignore` if you don't want to share activation state.

## Configuring what gets gated

Optimus gates a default set of work tools: Read, Edit, Write, Grep, Glob,
WebFetch, WebSearch, NotebookEdit, and (on Cursor) Delete. Two optional
keys in `.optimus/config.json` change that set.

**`gatedTools`** replaces the default set with your own exact tool names.
Naming it means you own the set completely, so `{ "gatedTools": ["Read",
"Edit"] }` gates only those two and lets everything else through. Reach for
it when the defaults are more than you want.

**`gatedToolPatterns`** gates by name shape, and it adds to whatever
`gatedTools` resolves to instead of replacing it. Only `*` is a wildcard.
The case it exists for is MCP:

```json
{ "gatedToolPatterns": ["mcp__*"] }
```

That gates every MCP tool call in the orchestrator, so MCP work has to be
delegated like any other work tool, while the default file tools keep being
gated. MCP tool names differ per setup and change over time, so an exact
list can never cover them. A glob can.

The two keys are separate on purpose. `gatedTools` replaces, so folding a
glob into it would gate `mcp__*` only by quietly un-gating Read and Edit.
`gatedToolPatterns` unions, so the defaults stay and the MCP class is added
on top.

## Commands

### `/optimus [on|off|status]`

Activates, deactivates, or reports Optimus's state for the current project.
Safe to run any time; `status` is read-only.

### `/optimus-stats`

Reports token usage by model, subagent dispatch counts, an **estimated**
saving versus running all delegated work on the expensive tier instead, and
an enforcement-ledger summary (dispatch allow/deny counts, work-tool
denials). Read-only, and prints a plain "no data yet" rather than erroring
when there's no session history yet.

Reads Claude Code's own local transcript files directly (no official API
for this), correctly walking subagent transcripts separately from the
parent's. Pricing is a dated snapshot printed in the output itself, so a
stale rate is visible rather than silently wrong. Full mechanics, caveats,
and an example run: [how_it_works.md](how_it_works.md#optimus-stats-mechanics).

## The kill switch

```bash
export OPTIMUS_DISABLED=1
```

Every Optimus hook becomes a no-op immediately — globally, regardless of
any project's `.optimus/config.json`. A hook that can deny tool calls must
never be able to *wedge* a session with no way out; this is the escape
hatch. It's an env var, not a repo-local file, so it works everywhere and
can't itself be blocked by anything Optimus controls.

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
| Bash used as a read/search bypass (`cat file.txt`, bare `grep foo`, etc.) | `PreToolUse` hook pattern-matches `tool_input.command` against a narrow set of "this looks like a plain read" regexes and denies those specifically | **Best-effort only, not a security boundary.** During testing, a model's first instinct for "read a file" was `Bash: cat`, unprompted — so leaving Bash open at all is only meaningful policy if the obvious literal bypass has *some* friction. But the underlying classification is fundamentally gameable: `awk '{print}' file`, a heredoc, `python3 -c "print(open('x').read())"`, piping through `xargs cat`, and plenty more all sail straight through. Treat the Bash check as a speed bump for the casual/unprompted case, not a wall. |
| Choosing `haiku` vs `sonnet` for a given delegated task | Reminder text in the deny messages and the per-turn reinforcement | **100% advisory.** A hook only sees a string (`tool_input.prompt`); judging whether a task is "simple" or needs real judgement is a semantic call about content, not something a length or keyword heuristic can reliably make. Optimus enforces that a model is named at all, and that it isn't the expensive tier — never which specific cheaper model is the "correct" choice. |
| Per-project on/off | `/optimus` writes/reads `.optimus/config.json`; every hook checks it first | **Hard-enforced** as a gate — if it says off, or the file's missing, every hook allows everything. |
| Kill switch | `OPTIMUS_DISABLED` env var, checked first in every hook | **Hard-enforced**, and takes priority over everything else, including "activated". |

## Architecture

Two host adapters (`hooks/optimus-gate.js` for Claude Code,
`hooks/optimus-gate-cursor.js` for Cursor) share one policy core
(`hooks/optimus-core.js`), so both hosts make the same decisions from the
same rules rather than two independently-maintained implementations. Full
breakdown, plus the reasoning behind naming/path choices that look
arbitrary but aren't, is in
[how_it_works.md](how_it_works.md#architecture-deep-dive).

```
Optimus/
├── .claude-plugin/   # plugin manifest + marketplace registration
├── hooks/            # policy core + host adapters (Claude Code & Cursor)
├── cursor/           # Cursor hook registration template, rule, probe kit
├── bin/              # optimus-cli, optimus-stats, optimus-probe-report
├── commands/         # /optimus, /optimus-stats slash-command definitions
├── tests/            # fixtures + test suites, one per host adapter
├── docs/             # Cursor port design spec + empirical probe findings
├── README.md / limitations.md / how_it_works.md
└── LICENSE
```

A project that activates Optimus also gets its own runtime state under
`.optimus/` (`config.json`, plus `state/events.jsonl` — the ledger
`/optimus-stats` reads back — once any enforcement event has fired).
Neither is part of this plugin's own source tree.

## Known limitations

See [limitations.md](limitations.md) for known limitations.

## License

GPLv3 — see [LICENSE](LICENSE).
