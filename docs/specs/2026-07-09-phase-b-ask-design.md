# Phase B: `tmt ask`, readiness detection, and per-session lock

Status: **approved design** (2026-07-09)

## 1. Overview & goals

Turn `tmt` from "type into a pane and hope" into a real request/response channel
with a live task's top-level agent. Three pieces:

1. **Readiness detection** — know when an interactive agent has *finished its
   turn* (not just "a shell is idle").
2. **`tmt ask`** — send a prompt, block until the turn completes, return **only
   the new output** as JSON.
3. **Minimal per-session lock** — so `ask`/`send` can't interleave with a
   concurrent `send` or the session's own loop.

### Out of scope (Phase C/D)

Policy file, auto-answer/`reply`, audit log, the orchestrator skill loop.

## 2. Readiness detection

A turn is **done** when, polling `capture-pane` once a second:

- The pane content hash is **unchanged for `--quiescent` seconds** (default 5),
  **AND**
- The pane tail matches a **ready-box pattern** — the empty input prompt of an
  interactive agent.

### Implementation

- New helper `_turn_done SESSION QUIESCENT` in `bin/tmt`.
- Uses its own hash state file (`$STATE_DIR/<key>.ask.hash`) so it never
  perturbs `detect()`'s RUNNING/STALE tracking — that state is load-bearing for
  `watch`/`agent-scan`.
- Ready-box regex (separate from `PROMPT_RE` which detects *questions*):
  ```
  READY_RE='(❯[[:space:]]*$|^>[[:space:]]*$|\$[[:space:]]*$)'
  ```
  Applied to the last non-empty line of the pane.
- A pane matching `PROMPT_RE` (y/n question) is NOT ready — it's "blocked".
  `ask` reports this distinctly (status: "blocked") so the caller knows the agent
  is asking something, not done.
- Registry's existing `ready_pattern` field (the sentinel) stays recorded at
  dispatch but is unused by this implementation — quiescence+box works on
  undispatched sessions too (the realistic case: `bigrun`/`mopd`/`opd`).

## 3. `tmt ask` command surface

```
tmt ask SESSION [--timeout S] [--quiescent S] [--lines N] -- "prompt"
```

### Flow

1. **Acquire** the session lock (§4); already held → exit `4`.
2. **Generate id** (`$$-$SECONDS`), build wire text:
   `<<<TMT_ASK:id>>> prompt` — one line, one turn. The marker prints inside
   the agent's echoed user message, surviving redraws.
3. **Send** via existing `_send_line` (text, settle delay, Enter).
4. **Poll** once/second until:
   - `_turn_done` → success (`status: "done"`)
   - pane matches `PROMPT_RE` after quiescence → blocked-on-question
     (`status: "blocked"`)
   - `--timeout` (default 300s) elapses → exit `7` (`status: "timeout"`)
5. **Capture** `-S -5000`, find the **last** marker line, return everything
   after it, trimming:
   - The marker line itself (it's the user's echoed input, not the reply).
   - Trailing lines that match `READY_RE` (the input box prompt).
   - Any trailing blank lines.
   This leaves only the agent's output text.
6. **Release** lock (trap-guaranteed, also on timeout/Ctrl-C).

### Output (stdout, JSON)

```json
{
  "session": "mopd",
  "id": "1234-56",
  "status": "done|blocked|timeout",
  "elapsed_s": 42,
  "reply": "...the new output region..."
}
```

`--json` is the only mode — `ask` is for program consumers; humans use `watch`.

### Defaults

| Flag | Default | Notes |
|------|---------|-------|
| `--timeout` | 300 | Seconds before giving up (exit 7) |
| `--quiescent` | 5 | Seconds of unchanged output before declaring done |
| `--lines` | 5000 | Scrollback depth for reply capture |

## 4. Per-session lock

### Mechanism

`mkdir`-based lockfile — `$STATE_DIR/<key>.lock/` (mkdir is atomic on POSIX; no
`flock` dependency, matches zero-dep philosophy). Inside it, a `pid` file records
the holder.

### Acquire (`_lock_acquire SESSION`)

1. Try `mkdir`.
2. On failure, read `pid`:
   - Dead process → **steal stale lock** (remove + retry once).
   - Alive → exit `4` with message naming the holder pid.
3. No blocking/waiting — fail fast; caller retries if desired.

### Who takes the lock

| Command | Lock scope |
|---------|-----------|
| `tmt ask` | Held for entire send→await→capture window |
| `tmt send` | Held for just the send |
| `tmt key` | Held for just the send |

This is exactly the `mopd` scenario: `ask` holds the lock for the full turn, so
a concurrent `tmt send` gets exit `4` instead of interleaving keystrokes
mid-question.

### What the lock does NOT protect

Input typed by a human attached to the session, or the agent's own scheduled
loops (e.g. `/loop` inside Claude Code). It serializes *tmt-initiated* input
only. Documented plainly.

### Lifecycle

Lock lives in `$STATE_DIR` (tmpfs) — reboot clears locks automatically, no
stale-lock-after-reboot problem.

## 5. Error handling & exit codes

All existing exit codes; no new ones needed.

| Condition | Exit | JSON status | Reply field |
|-----------|------|-------------|-------------|
| No such session | `3` | — | — |
| Lock held by live pid | `4` | — | — |
| Turn completes normally | `0` | `"done"` | New output region |
| Agent quiesces on a question | `0` | `"blocked"` | New output incl. the question |
| Timeout elapses | `7` | `"timeout"` | Partial output (if any) |
| Marker never found in scrollback | `7` | `"timeout"` | `""` (honest failure) |

Exit `0` + `"blocked"` means the agent responded but ended on a question rather
than its ready box — the caller decides what to answer; `ask` never answers
anything itself.

## 6. Testing (extends `test/test.sh`)

Deterministic tests against a scripted `read`-loop session, not a real Claude:

1. **Ask round-trip:** session runs `while read l; do echo "R:[$l]"; done` under
   a `❯`-printing wrapper → `ask` returns `status:done`, reply contains
   `R:[hello]`, marker excluded.
2. **Blocked detection:** session prints `proceed? (y/n)` after input →
   `status:blocked`, exit 0.
3. **Timeout:** session that echoes nothing and shows no ready box → exit `7`
   within `--timeout 3`.
4. **Lock contention:** background `ask` in flight → concurrent `tmt send` exits
   `4`; after completion, lock released and `send` succeeds.
5. **Stale lock steal:** hand-craft a lock dir with a dead pid → `ask` proceeds.

## 7. Changes to existing commands

- `tmt send` and `tmt key` acquire+release the session lock around their send
  call. This is the only behavioral change to shipped commands — it adds one
  mkdir+rmdir (microseconds) and a new failure mode (exit `4` if the session is
  mid-ask).
- Completion file (`completions/tmt.bash`) gains `ask` subcommand + flags.
- `tmt --help` header gains the `ask` line.
- DESIGN.md §9 Phase B → marked as shipped (after merge).

## 8. Implementation order

1. Lock helpers (`_lock_acquire`, `_lock_release`) + wire into `send`/`key`.
2. Ready-box regex + `_turn_done` helper.
3. `cmd_ask` with the full flow.
4. Tests (§6 items 1–5).
5. Completion, help text, README.
