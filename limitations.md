# Known Limitations

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
  (`<config dir>/projects/<slug>/`, `<session-id>/subagents/agent-<id>.jsonl`,
  where `<config dir>` is `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`) and
  an empirically-observed project-slug format (every non-alphanumeric
  character in the cwd replaced with a dash) — all undocumented
  implementation details, not a stable public API. Because that slug is a
  guess, `/optimus-stats` also falls back to scanning each project
  directory's own transcripts for a `cwd` field that matches exactly, so a
  wrong guess (or even a changed slug format) doesn't produce a false
  "no data". A future Claude Code version could still change the layout in
  a way neither lookup recognizes, in which case `/optimus-stats` degrades
  to "no data" rather than crashing, but that would look the same as "no
  data yet" rather than raising a clear error. If stats stop showing up
  after a Claude Code update, this is the first place to look.
- **Pricing figures are a point-in-time snapshot** printed directly in
  `/optimus-stats` output, dated, specifically so a stale number is visible
  rather than silently wrong. Verify at anthropic.com/pricing before relying
  on the dollar figures for anything that matters. Cache-token pricing
  specifically is an assumption (standard published multipliers), not
  independently re-verified.
- **Cursor's hook payload fields are undocumented where Optimus depends on
  them.** The subagent-identity field the Cursor gate keys on, and the
  plugin-root resolution behaviour the installer works around, were both
  established empirically — see `cursor/probe/`. Neither is versioned
  upstream. Re-run
  `bin/optimus-probe-report` against a fresh probe log after every Cursor
  upgrade; a silently renamed field degrades enforcement rather than
  announcing itself.
- **`.cursor/hooks.json` contains absolute paths.** It is generated per
  machine by `optimus-cli install cursor` and should generally not be
  committed to a shared repository.
- **Org-managed Cursor installs can shadow or block this entirely.**
  Enterprise and Team `hooks.json` take precedence over Project and User
  `hooks.json`, and "Allow Local Plugin Imports" is off by default on
  Enterprise. Both look identical to "Optimus is broken".

## Two-window limitation

Two Cursor windows opened on the same project directory read and write the
same `.optimus/state/` tree, and nothing in a hook payload lets Optimus
tell them apart: `payload.cwd`, `payload.conversation_id` and
`payload.generation_id` are all it gets, with no window or session-instance
identifier alongside them. Two kinds of state are affected:

- **Sidecar subagent markers** (`.optimus/state/active-subagents/`).
  `parentConversations()` unions every live marker under the project,
  regardless of which window wrote it, and `isSubagentConversation()`
  treats any conversation absent from that union as a subagent's. So while
  window A has a dispatch outstanding, window B's own orchestrator
  conversation — which has no dispatch of its own, and so is not in that
  union — is misread as a subagent, and its gated tool calls (Read, Edit,
  Write, ...) are let through without delegation, for as long as window
  A's marker exists.
- **Turn-allowance counters** (`.optimus/state/turn-allowances/`,
  Phase 1's `inlineAllowancePerTurn` mechanism). These live under the same
  shared directory, but each is keyed by a SHA-256 hash of its
  conversation id and guarded by an interprocess lock, so two windows on
  two distinct conversations never touch the same counter file. The one
  case where they do share one — the same conversation id reattached or
  duplicated across two windows — is exactly what that lock exists for:
  `consumeAllowance()` serializes the read-decrement-write, and fails
  CLOSED (denies) rather than granting an extra call if it cannot acquire
  the lock in time. The budget can end up split between the two windows
  sooner than either expects; it cannot be inflated.

Both failure modes are bounded, not open-ended. A stray marker cannot
outlive `STALE_MS` (30 minutes): `parentConversations()` sweeps it on the
next read, and `clearStale()` now also sweeps proactively at every Cursor
`sessionStart`, so a closed window's abandoned markers are cleared the next
time either window's session (re)starts, not just the next time something
happens to read them. A misattributed subagent classification is therefore
self-correcting on that same horizon, and the allowance race can, at
worst, deny a call early — it cannot disable the gate or hand out calls
beyond what was configured.

**Future work, not implemented here:** partitioning `.optimus/state/` by
window or session instance would need a window/instance identifier in the
hook payload, which Cursor does not currently send. Whether Cursor exposes
one anywhere the probe hasn't yet checked is an open question for a future
probe run (see `cursor/probe/`); until one is confirmed, the single-window
assumption stands.
