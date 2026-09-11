# How Optimus works

Deep-dive companion to [README.md](README.md): full Cursor-host mechanics,
`/optimus-stats` internals, and the architecture decisions behind this
repo's layout. Read the README first — this document assumes it.

## Cursor support

### Cursor install details

The easy path (global install, in the README) puts `optimus-cli`/
`optimus-stats` on `PATH` directly, no shell-profile bootstrapping needed.
Two alternatives:

One-shot, without a global install:

```bash
npx -p github:pietermyb/optimus optimus-cli install cursor
npx -p github:pietermyb/optimus optimus-cli on
```

`npx` writes hook paths in `.cursor/hooks.json` that point into the
ephemeral npm cache (the cloned GitHub checkout), so prefer
`npm install -g git+https://github.com/pietermyb/optimus.git`; if the npx
cache is cleared, re-run `optimus-cli install cursor`.

For local development, or a checkout without npm, clone and invoke via
`node` directly:

```bash
git clone https://github.com/pietermyb/optimus.git
cd optimus   # or cd into your project and use an absolute path to optimus/bin
node bin/optimus-cli install cursor
node bin/optimus-cli on
```

`install cursor` writes `.cursor/hooks.json` and `.cursor/rules/optimus.mdc`
into the current project (determined by the `CURSOR_PROJECT_DIR`
environment variable or current working directory), so run it from the
project directory you want to enforce Optimus in, or set
`CURSOR_PROJECT_DIR` explicitly.

### What differs from the Claude Code build, and why

| | Claude Code | Cursor |
|---|---|---|
| Enforcement point | `PreToolUse` hook | `preToolUse` hook |
| Dispatch tool | `Agent` | `Task` |
| Shell tool | `Bash` | `Shell` |
| `Delete` tool | does not exist | treated as a work tool — delegate deletions |
| Per-turn reminder | `UserPromptSubmit` re-injects every turn | Cursor has no equivalent event. Turn one comes from a `sessionStart` hook; every turn after it comes from the `alwaysApply` rule at `.cursor/rules/optimus.mdc` |
| Hook path resolution | `${CLAUDE_PLUGIN_ROOT}` | absolute paths baked in at install time, so `.cursor/hooks.json` is machine-specific — re-run `install cursor` after moving the plugin |
| `/optimus-stats` | full report | enforcement-ledger counts only. Cursor's transcript format is undocumented, so the requested-vs-actual model comparison correctly reports no data rather than guessing |
| Model-conditional enforcement | not possible — `PreToolUse` carries no model field | possible: Cursor payloads carry the live session model. Opt in per project with `"modelConditional": true` in `.optimus/config.json`. Off by default so both hosts behave the same out of the box |

Both hosts fail open: a crash in the hook allows the call rather than
blocking it. On Cursor that also means a broken hook results in
enforcement silently not applying, unless you set `"failClosed": true` on
the hook in `.cursor/hooks.json`. That is the same deliberate tradeoff the
kill switch exists for — a bug in Optimus must never wedge a session.

### How Optimus tells your subagents apart on Cursor

Cursor sends nothing on a tool-call hook that marks the call as a subagent's — the payload from a
subagent is shaped exactly like the orchestrator's. What it does send is `conversation_id`, and a
subagent gets its own. So Optimus records the dispatching conversation for the lifetime of each
subagent (`subagentStart` → `subagentStop`, one small file per outstanding subagent under
`.optimus/state/active-subagents/`) and treats any *other* conversation as a subagent's while a
dispatch is outstanding. That is exact per-call attribution, and it is safe with any number of
subagents running at once.

Two limits worth knowing:

- **Two Cursor windows on the same project.** If window A has a subagent outstanding, window B's
  own tool calls look like a subagent's and are not enforced. Fail-open, and the kill switch or
  `/optimus off` behave normally.
- **A subagent that dispatches its own subagent** would have its own calls enforced. Nested
  dispatch was not observed on Cursor 3.19.13 and is not supported by this build.

### Cursor quirks Optimus works around

- **Denying `Read` also blocks writes to files that already exist**, because Cursor issues an
  internal `Read` of the target before a `Write`. This is not something Optimus can separate;
  read-scoped and write-scoped policy are not independent on Cursor. It does not change anything
  for Optimus, which denies both in the orchestrator anyway.
- **Web search and URL fetch write to a cache** under
  `~/.cursor/projects/<workspace>/agent-tools/`, and those writes fire the tool hook as `Write`.
  Optimus needs no path exemption for them: `WebFetch`/`WebSearch` are themselves delegated work,
  so the orchestrator never gets as far as the cache write, and inside a subagent both the fetch
  and its cache write are exempt.
- **Turning the hooks off means writing an empty config, not deleting the file.** Cursor watches
  `.cursor/hooks.json` for writes and reloads on save — no window reload needed — but deleting it
  does not deregister anything. `{"version": 1, "hooks": {}}` clears them.
- **Debugging the gate:** Cursor writes every hook invocation, with `INPUT`, `OUTPUT` and
  `STDERR`, to
  `~/Library/Application Support/Cursor/logs/<session>/window<N>/output_<ts>/cursor.hooks.workspaceId-<id>.log`.
  Start there, not with guesswork. Re-verify the findings in `docs/cursor-probe-findings.md` from
  that log after a Cursor upgrade.
- **A dispatch with `model: "inherit"` is blocked**, the same as one that names no model at all —
  `inherit` means the subagent runs on the orchestrator's expensive model, which is the exact thing
  the rule exists to prevent.

### If you have the Claude Code plugin installed and you use Cursor

Cursor reads Claude Code plugin manifests. With no `.cursor/hooks.json` at all, it finds Optimus's
`hooks/hooks.json`, maps `PreToolUse` onto its own `preToolUse`, resolves `${CLAUDE_PLUGIN_ROOT}`,
and runs `hooks/optimus-gate.js` on every matched tool call.

**That hook is a silent no-op on Cursor, and its deny path fails open.** Its allow path is Claude
Code's "emit nothing", which Cursor also reads as allow, so allows happen to work. But a deny emits
`hookSpecificOutput.permissionDecision: "deny"`, which Cursor does not understand — it logs "none
returned a valid response" and lets the call through. So if you have the plugin and you are working
in Cursor, you are not enforced until you run `optimus-cli install cursor`, and nothing warns you.

## `/optimus-stats` mechanics

Reports token usage by model, subagent dispatch counts, orchestrator vs.
delegated split, an **estimated** saving versus running all that delegated
work on the expensive tier instead, and — if the project has ever recorded
one — an enforcement summary read back from
[the ledger](#the-enforcement-ledger-hooksoptimus-ledgerjs).

```
$ /optimus-stats
Orchestrator usage (main session, by model):
  claude-opus-5: turns=32 input=64 output=15821 cache_write=139012 cache_read=895136 cost=$1.7122

Delegated usage (subagent transcripts, by model):
  claude-sonnet-5: turns=4 input=8 output=408 cache_write=61812 cache_read=61627 cost=$0.1710
  claude-haiku-4-5: turns=39 input=336 output=5914 cache_write=160449 cache_read=881407 cost=$0.3186

Enforcement ledger summary (from .optimus/state/events.jsonl):
  dispatches allowed         : 3
  dispatches denied by reason: {"no_model":1,"expensive_model":1}
  work-tool denials by tool  : {"Read":2,"Edit":1}
  bash nudges by cmd_head    : {"cat":1}

Requested-vs-actual model family (ledger-requested alias vs. transcript-resolved model, family-level only):
  haiku : requested=3 actual=1  <- counts differ
  sonnet: requested=0 actual=0
  opus  : requested=0 actual=1  <- counts differ
  other : requested=0 actual=0

Model family check: requested and actual counts differ for at least one family -- counts differ, which may be rotation/pruning rather than drift (see caveat below), not proof that a different model actually ran than what was requested.

Estimated saving vs. running delegated work on the expensive (opus) tier:
  actual delegated cost     : $0.4896
  hypothetical cost on opus : $2.0204
  estimated saving          : $1.5309
  ESTIMATE, not a fact: assumes opus would have used the same token volume for the same work.
```

(That's a deliberately busy example, to show every line the enforcement
section can print in one place — a real project usually shows far fewer
denials, and prints no `CAVEAT` line at all unless the ledger has rotated
or the two sides' totals actually differ. The whole enforcement-ledger
block — from `Enforcement ledger summary` through the `Model family
check` line — is omitted entirely for a project with no ledger yet, e.g.
one that predates this feature; every line before and after it is
unaffected.)

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

**Enforcement ledger reporting.** The `Enforcement ledger summary` block
tallies what [the ledger](#the-enforcement-ledger-hooksoptimus-ledgerjs)
actually recorded — dispatch allow/deny counts, work-tool denials, Bash
nudges — read straight from `.optimus/state/events.jsonl` (and a rotated
`events.jsonl.1`, if present). The `Requested-vs-actual model family` block
then compares the model *alias* a dispatch requested (what the ledger
records, e.g. `"haiku"`) against the *actual* resolved model id a subagent
transcript shows it ran on (what the tables above already compute) — but
only at the coarse `haiku`/`sonnet`/`opus`/`other` family level, by
substring match. This is deliberate, not a shortcut: an exact
alias-to-model-id table would go stale the same way a pricing snapshot
does, the moment a model version changes what a given alias resolves to.

Treat that comparison as approximate, not as proof of drift either way, for
three concrete reasons this command states directly in its own output when
they apply: the ledger is cumulative and loses history whenever it rotates;
Claude Code can prune transcript files independently of the ledger; and
only *allowed* dispatches ever reach a transcript at all (a denied dispatch
never ran, so it can never show up on the "actual" side). If the ledger has
rotated, or the two sides' totals simply differ, the command prints an
explicit `CAVEAT` line saying so — a mismatch is worded as "counts differ —
may be rotation/pruning rather than drift," never asserted as confirmed
model substitution.

## Architecture deep-dive

```
Optimus/
├── .claude-plugin/
│   ├── plugin.json          # plugin manifest — deliberately no "hooks" key, see below
│   └── marketplace.json     # lets `claude plugin marketplace add <owner>/Optimus` find it
├── hooks/
│   ├── hooks.json           # THE conventional path Claude Code's hook loader honors
│   ├── optimus-core.js      # shared: host-agnostic policy — work tools, expensive-model rule,
│   │                        #   shell-bypass patterns, check order, ledger event names
│   ├── optimus-gate.js      # Claude Code PreToolUse adapter (thin — parses/emits CC shapes)
│   ├── optimus-gate-cursor.js    # Cursor preToolUse adapter (thin — parses/emits Cursor shapes)
│   ├── optimus-session-cursor.js # Cursor sessionStart: one-shot policy injection
│   ├── optimus-subagent-cursor.js # Cursor subagentStart/Stop: maintains the attribution sidecar
│   ├── optimus-sidecar.js   # shared-by-Cursor: which conversation dispatched each live subagent
│   ├── optimus-reinforce.js # Claude Code UserPromptSubmit: per-turn reminder (decays otherwise)
│   ├── optimus-config.js    # shared: repo-local config resolution, kill switch, safe atomic writes
│   └── optimus-ledger.js    # shared: append-only enforcement-event ledger, called from both gates
├── cursor/
│   ├── hooks.json           # Cursor registration template — __OPTIMUS_ROOT__ rendered at install
│   ├── optimus.mdc          # alwaysApply rule, and the single source of the Cursor reminder text
│   └── probe/               # hook-payload probe kit (see docs/cursor-probe-findings.md)
├── bin/
│   ├── optimus-cli          # /optimus on|off|status, plus `install cursor`
│   ├── optimus-stats        # /optimus-stats — walks transcripts + the ledger, computes cost/savings
│   └── optimus-probe-report # analyses a Cursor probe log into an Unknown-1/Unknown-2 verdict
├── commands/
│   ├── optimus.md           # /optimus — invokes bin/optimus-cli via PATH
│   └── optimus-stats.md     # /optimus-stats — invokes bin/optimus-stats via PATH
├── tests/
│   ├── fixtures/*.json         # captured-shape Claude Code PreToolUse payloads
│   ├── fixtures/cursor/*.json  # captured-shape Cursor preToolUse + subagent payloads
│   ├── fixtures/probe/*.log    # synthetic probe logs for the analyser
│   ├── run-all.sh              # runs every suite below, reporting anything it skipped
│   ├── core-tests.js           # direct unit tests of optimus-core.js's decide()/ledgerEventFor()
│   ├── run-core-tests.sh       # wrapper for core-tests.js
│   ├── run-gate-tests.sh       # Claude Code adapter: allow/deny per fixture, plus deny wording
│   ├── run-gate-cursor-tests.sh # Cursor adapter: shape translation, role attribution, ledger
│   ├── run-session-cursor-tests.sh # Cursor sessionStart injection
│   ├── run-sidecar-tests.sh    # sidecar lifecycle and the subagentStart/Stop hook
│   ├── run-install-tests.sh    # optimus-cli install cursor, including its refusal paths
│   ├── run-probe-report-tests.sh # the probe analyser against synthetic logs
│   ├── run-ledger-tests.sh     # gate -> .optimus/state/events.jsonl
│   └── run-stats-tests.sh      # synthetic transcripts + ledgers -> optimus-stats reporting
├── docs/
│   ├── cursor-support-spec.md     # the Cursor port's design spec
│   └── cursor-probe-findings.md   # what Cursor's hooks empirically do — re-verify on upgrade
├── README.md
├── LICENSE
└── .gitignore
```

### Config knobs: `compilePolicy` and `buildDecideConfig`

`decide()` takes its policy from a compiled config object, not from the raw
`.optimus/config.json`, and both host adapters build that object through one
shared pair of functions in `optimus-core.js` so they enforce the same policy
byte for byte. `compilePolicy(raw)` turns the two optional overrides into the
shapes `decide()` consumes: `expensiveModelPattern` (a string) becomes a
case-insensitive `RegExp` that replaces the built-in `/opus/i`, and `gateTools`
(a string array) becomes anchored `RegExp` globs that are added to the built-in
`WORK_TOOLS` set. `buildDecideConfig(raw)` wraps that, layering on `enabled` and
the Cursor-only `modelConditional`.

Both functions are pure and defensive by design. Every field is validated in
isolation: an `expensiveModelPattern` that is not a valid regex is dropped, and a
`gateTools` entry that is not a non-empty string, or that fails to compile, is
skipped without dropping the rest of the list. Anything malformed falls back to
the built-in default rather than throwing, so a bad config degrades to stock
behaviour instead of wedging a hook. The glob compiler treats only `*` as
special and anchors the match end to end, so `"mcp__*"` matches every MCP tool
name and nothing partial slips through.

### Recipe: gate your MCP tools

The highest-value use of `gateTools` for an MCP-heavy workflow is `["mcp__*"]`,
and the reason is a real sample rather than a guess. Replaying 30 days of one real
Claude Code history through Optimus's `decide()`: 869 MCP calls ran ungated on the
expensive model, grafana-multi 558 of them, then Atlassian at 182 and GitHub at
128. Setting `gateTools: ["mcp__*"]` gates all 869, so that work has to be
delegated instead of running on the expensive tier, and it leaves every built-in
count identical (the edits, the reads and the delegations do not move). For a setup
like that it is the single highest-value line in the config, and it costs nothing
to anyone who leaves it out.

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
everything else in the "advisory" row of the enforcement table — it
doesn't enforce anything by itself, `optimus-gate.js` does that — but it
measurably changed model behavior in testing (the orchestrator started
delegating proactively instead of only after being denied once).

### The enforcement ledger (`hooks/optimus-ledger.js`)

Every enforcement decision `optimus-gate.js` makes — an `Agent` dispatch
allowed or denied, a work tool denied, a Bash-as-bypass nudge — is also
recorded as one JSON line appended to
`<project root>/.optimus/state/events.jsonl`. This exists so that
enforcement isn't invisible: without it, there was no way to see *how much*
Optimus was actually doing versus how much it was invisibly letting slide.
`/optimus-stats` reads this file back (see "Enforcement ledger reporting"
above) to report those counts, plus an approximate comparison between the
model alias a dispatch requested and the model a subagent transcript shows
it actually ran on.

A few properties of this file are load-bearing, not incidental:

- **Append-only, never read-modify-written.** Every write is a single
  `fs.appendFileSync` call, which makes "seek to end, then write" atomic at
  the OS level. That's what makes it safe for many gate processes — one per
  tool call, across the orchestrator and every subagent it dispatches — to
  write to the same file at the same moment without corrupting each other's
  lines or needing any locking.
- **Holds no prompts, file paths, file contents, or full shell commands.**
  The ledger module itself has no notion of what a "prompt" or a "path" is —
  it only ever writes the specific, reduced fields each caller hands it
  (e.g. a Bash nudge logs `cmd_head`, the first word of the command stripped
  to word characters, never the command itself). Every string field is also
  capped at 200 characters as a defensive backstop.
- **Rotates at 1 MB.** Once the file reaches that size, the next write
  renames it to a single `events.jsonl.1` generation (replacing any
  previous one) and starts a fresh `events.jsonl`. There is exactly one
  rotated generation, not a numbered history — this is a lightweight cap on
  disk usage, not an audit archive.
- **Gitignored.** Like `.optimus/config.json`, this is per-project runtime
  state, not something meant to be committed (this plugin's own
  `.gitignore` excludes `.optimus/` for exactly this reason).
- **Fails silently and never blocks a tool call.** Writing the ledger sits
  on the hot path between the gate deciding and emitting its verdict, so it
  can never throw or write to stdout — a missing/unwritable state directory
  degrades to "no ledger for this event," never to a wedged session.
