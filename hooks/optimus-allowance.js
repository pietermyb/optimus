'use strict';

/**
 * Turn-scoped inline allowance state for orchestrator-side gated calls.
 *
 * Contract:
 *   consumeAllowance({ cwd, conversationId, generationId, inlineAllowancePerTurn })
 *     -> { allowed: boolean, remaining: number }
 *
 * Design constraints, matching Optimus gate/ledger posture:
 *  - State is per project and per conversation, rooted under
 *    `<project>/.optimus/state/turn-allowances`.
 *  - Conversation id is untrusted input from hook payloads. The on-disk
 *    filename is derived from a SHA-256 digest of the raw id rather than a
 *    sanitized/truncated copy of it — see `hashConversationId` below for
 *    why that distinction matters (it is not just a style choice).
 *  - Reads and writes for a given conversation are guarded by an
 *    interprocess lock (a lock *directory*, created with the atomic
 *    `fs.mkdirSync`) because a single assistant turn can fan out several
 *    gated tool calls at once, each running this module in its own
 *    process — without a lock, two processes can both read the same
 *    `remaining` count, both grant, and both persist a decremented count,
 *    net-consuming more allowance than was actually available.
 *  - Any internal failure (root resolution, fs, JSON, atomic write, lock
 *    acquisition) fails CLOSED to "no allowance" so enforcement falls back
 *    to today's deny behaviour, never to a silent bypass.
 *  - Never throw and never write to stdout.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const {
  findProjectRoot,
  writeFileAtomicRefusingSymlink,
} = require(path.join(__dirname, 'optimus-config.js'));

const STATE_DIR = path.join('.optimus', 'state', 'turn-allowances');
/**
 * Defensive cap on the raw conversation id we echo back into the state
 * file as metadata (see `hashConversationId`). This no longer bounds the
 * filename — the digest is always a fixed-length hex string — it only
 * stops a pathologically huge id from bloating the state file on disk.
 */
const MAX_CONVERSATION_ID_LEN = 120;
const MAX_WRITE_RETRIES = 4;

/**
 * Bounded retry/backoff for the interprocess lock (see `acquireLock`).
 * This runs on the hot path of every gated tool call, so the whole budget
 * is kept to tens of milliseconds: LOCK_MAX_ATTEMPTS attempts, sleeping
 * LOCK_RETRY_SLEEP_MS between them, for a worst case of
 * (LOCK_MAX_ATTEMPTS - 1) * LOCK_RETRY_SLEEP_MS = 45ms of sleeping before
 * giving up and denying. A held lock is only ever held for the duration of
 * a read-JSON/compute/write-JSON cycle (microseconds), so a well-behaved
 * competing process should clear it within the first attempt or two.
 */
const LOCK_MAX_ATTEMPTS = 10;
const LOCK_RETRY_SLEEP_MS = 5;
/**
 * A lock directory older than this is assumed to belong to a process that
 * crashed (or was killed) while holding it, rather than one still doing
 * legitimate work — legitimate holds are microseconds long, so a few
 * seconds of slack is generous headroom, not a tight race. Without this,
 * one crashed process would wedge every subsequent gated tool call for
 * the rest of the conversation, which is worse than the race this lock
 * exists to close.
 */
const STALE_LOCK_MS = 3000;

function normalizeAllowance(value) {
  if (!Number.isFinite(value) || !Number.isInteger(value) || value <= 0) return 0;
  return value;
}

function isValidConversationId(conversationId) {
  return typeof conversationId === 'string' && conversationId.trim() !== '';
}

/**
 * Derive the state file's basename from a SHA-256 digest of the RAW
 * conversation id.
 *
 * This used to be a character-sanitizing function (map every byte outside
 * `[A-Za-z0-9_-]` to `_`, then truncate). That stopped path traversal, but
 * NOT collisions: distinct ids differing only in punctuation (e.g.
 * `"abc/def"` and `"abc:def"`) sanitized to the identical string and then
 * shared, reset, and depleted one another's turn budget. A cryptographic
 * digest of the untouched raw id is collision-resistant, which a character
 * substitution cipher can never be no matter how it is tuned.
 *
 * The digest is also, by construction, the ONLY defense this module needs
 * against path traversal: a fixed-length lowercase-hex string cannot
 * contain `/`, `..`, a null byte, or any other path metacharacter. Do not
 * "helpfully" swap this back to using the raw or sanitized id as the
 * filename — that would resurrect both the collision bug this fixes and
 * the traversal risk the old sanitizer existed to close.
 */
function hashConversationId(conversationId) {
  return crypto.createHash('sha256').update(conversationId, 'utf8').digest('hex');
}

function parseStoredState(file) {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
  } catch (e) {
    return null;
  }
}

function writeState(file, state) {
  const payload = JSON.stringify(state, null, 2) + '\n';

  for (let attempt = 0; attempt <= MAX_WRITE_RETRIES; attempt++) {
    try {
      writeFileAtomicRefusingSymlink(file, payload, 0o600);
      return true;
    } catch (e) {
      if (!e || e.code !== 'EEXIST' || attempt === MAX_WRITE_RETRIES) {
        throw e;
      }

      const tick = Date.now();
      while (Date.now() === tick) {
        // Busy wait one millisecond so Date.now() changes and the shared
        // helper's temp-file suffix cannot collide again in this process.
      }
    }
  }

  return false;
}

/**
 * Fully synchronous sleep. This module runs on the hot path of a plain
 * synchronous CLI hook process — there is no event loop to yield to and no
 * room for async/await or setTimeout. `Atomics.wait` on a
 * SharedArrayBuffer-backed Int32Array is the one built-in primitive Node
 * offers for blocking the current thread for a bounded time.
 */
function sleepMs(ms) {
  try {
    const sab = new SharedArrayBuffer(4);
    const view = new Int32Array(sab);
    Atomics.wait(view, 0, 0, ms);
  } catch (e) {
    // Atomics/SharedArrayBuffer unavailable for some reason — fall back to
    // a bounded busy-wait so the retry loop still makes forward progress
    // instead of hammering mkdirSync with zero backoff.
    const until = Date.now() + ms;
    while (Date.now() < until) {
      // busy wait
    }
  }
}

/**
 * If `lockDir` looks abandoned (older than STALE_LOCK_MS), remove it so a
 * crashed process holding the lock cannot wedge every subsequent gated
 * tool call for the rest of the conversation. Best-effort and silent: the
 * lock directory can legitimately vanish or reappear between our stat and
 * our rmSync (another process recovering it at the same moment, or the
 * original holder finishing normally), and any of those interleavings
 * must be treated as "this attempt didn't clear it," not as an error —
 * the caller's retry loop is what actually decides whether to keep going.
 */
function tryRemoveStaleLock(lockDir) {
  try {
    const st = fs.statSync(lockDir);
    if (Date.now() - st.mtimeMs > STALE_LOCK_MS) {
      fs.rmSync(lockDir, { recursive: true, force: true });
    }
  } catch (e) {
    // Raced with another process, or the dir is simply gone/inaccessible —
    // either way, fall through and let the next mkdirSync attempt decide.
  }
}

/**
 * Acquire the interprocess lock guarding `stateFile`'s read-compute-write
 * cycle. `lockDir` is a directory, not a file: `fs.mkdirSync` on an
 * existing path is an atomic, portable "acquire" primitive (it throws
 * EEXIST if some other process already holds it), whereas a lock *file*
 * would need an extra flag/mode dance to get the same atomicity.
 *
 * Returns true iff this call created the directory (i.e. holds the lock).
 * Any failure — the lock is genuinely held, or something unexpected went
 * wrong probing/clearing it — is treated identically as "could not
 * acquire the lock on this attempt" and folded into the same bounded
 * retry loop; the caller must never proceed unlocked and must never throw
 * out of this function.
 */
function acquireLock(lockDir) {
  for (let attempt = 0; attempt < LOCK_MAX_ATTEMPTS; attempt++) {
    try {
      fs.mkdirSync(lockDir);
      return true;
    } catch (e) {
      // EEXIST (held, possibly stale) or any other transient fs error —
      // either way this attempt failed to acquire. Try to clear a stale
      // lock (a no-op if the lock is fresh or already gone) and, unless
      // this was the last attempt, back off briefly before retrying.
      tryRemoveStaleLock(lockDir);
      if (attempt < LOCK_MAX_ATTEMPTS - 1) sleepMs(LOCK_RETRY_SLEEP_MS);
    }
  }
  return false;
}

/** Release a lock this process acquired. Best-effort: never throws. */
function releaseLock(lockDir) {
  try {
    fs.rmSync(lockDir, { recursive: true, force: true });
  } catch (e) {
    // If this fails, STALE_LOCK_MS bounds how long the next caller waits.
  }
}

function consumeAllowance(input) {
  try {
    const args = input && typeof input === 'object' ? input : {};
    const allowancePerTurn = normalizeAllowance(args.inlineAllowancePerTurn);
    if (allowancePerTurn <= 0) return { allowed: false, remaining: 0 };

    if (!isValidConversationId(args.conversationId)) return { allowed: false, remaining: 0 };
    const rawConversationId = args.conversationId;
    const conversationIdHash = hashConversationId(rawConversationId);

    const generationId =
      typeof args.generationId === 'string' && args.generationId.trim() !== ''
        ? args.generationId
        : null;
    if (!generationId) return { allowed: false, remaining: 0 };

    const root = findProjectRoot(args.cwd);
    if (!root) return { allowed: false, remaining: 0 };

    const stateDir = path.join(root, STATE_DIR);
    const stateFile = path.join(stateDir, conversationIdHash + '.json');
    const lockDir = stateFile + '.lock';

    fs.mkdirSync(stateDir, { recursive: true });

    if (!acquireLock(lockDir)) return { allowed: false, remaining: 0 };

    try {
      const stored = parseStoredState(stateFile);

      const storedRemaining =
        stored && Number.isInteger(stored.remaining) && stored.remaining >= 0
          ? stored.remaining
          : 0;

      let remaining;
      if (!stored || stored.lastGenerationId !== generationId) {
        remaining = allowancePerTurn;
      } else {
        remaining = storedRemaining;
      }

      let allowed = false;
      if (remaining > 0) {
        remaining -= 1;
        allowed = true;
      }

      const nextState = {
        conversationId: rawConversationId.slice(0, MAX_CONVERSATION_ID_LEN),
        lastGenerationId: generationId,
        remaining: remaining,
        updatedAt: new Date().toISOString(),
      };

      writeState(stateFile, nextState);
      return { allowed: allowed, remaining: remaining };
    } finally {
      releaseLock(lockDir);
    }
  } catch (e) {
    try {
      process.stderr.write(
        'optimus-allowance: failed to consume allowance: ' + (e && e.message) + '\n'
      );
    } catch (e2) {
      // swallow
    }
    return { allowed: false, remaining: 0 };
  }
}

module.exports = {
  consumeAllowance,
  hashConversationId,
  normalizeAllowance,
  STATE_DIR,
  MAX_CONVERSATION_ID_LEN,
  LOCK_MAX_ATTEMPTS,
  LOCK_RETRY_SLEEP_MS,
  STALE_LOCK_MS,
};
