# Phase B: `tmt ask` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `tmt ask` request/response primitive that sends a prompt to a live agent session, waits for its turn to complete, and returns only the agent's reply as JSON.

**Architecture:** A per-session mkdir-based lock serializes all tmt-initiated input. `ask` sends a marker+prompt, polls the pane once/second for quiescence plus a ready-box pattern, then extracts the reply between the marker and the input box. Everything is pure bash + jq, matching the existing codebase.

**Tech Stack:** Bash (bin/tmt), jq (JSON output), tmux (pane capture), existing test harness (test/test.sh)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `bin/tmt` | Modify (lines 66-69, 216-232, 918-939, new section before `# --- serve`) | Lock helpers, ready-box regex, `cmd_ask`, wire lock into `send`/`key`, add to dispatcher |
| `completions/tmt.bash` | Modify | Add `ask` subcommand + flags |
| `test/test.sh` | Modify (append) | 5 new test cases |

---

### Task 1: Per-session lock helpers

**Files:**
- Modify: `bin/tmt` (insert after line 69, before `# Colors only when...` at line 71)

- [ ] **Step 1: Write the lock test cases**

Append to `test/test.sh` (before the final `exit $fail` at line 135):

```bash
# --- Phase B: ask, readiness, lock -------------------------------------------

# lock contention: holding a lock blocks a second acquire
lockdir="${TMPDIR:-/tmp}/tmux-tasks-${USER:-$(id -un)}"
lockkey="$P_idle"
"$TMT" _test_lock_acquire "$P/idle" && ok "lock acquired" || bad "lock acquire failed"
"$TMT" _test_lock_acquire "$P/idle" 2>/dev/null; [[ $? -eq 4 ]] && ok "lock contention exits 4" || bad "lock contention"
"$TMT" _test_lock_release "$P/idle" && ok "lock released" || bad "lock release failed"
"$TMT" _test_lock_acquire "$P/idle" && ok "lock re-acquire after release" || bad "lock re-acquire failed"
"$TMT" _test_lock_release "$P/idle"

# stale lock steal: dead pid lock is auto-stolen
mkdir -p "$lockdir/$(echo "$P/idle" | tr -c 'A-Za-z0-9._-' '_').lock"
echo 99999 > "$lockdir/$(echo "$P/idle" | tr -c 'A-Za-z0-9._-' '_').lock/pid"
"$TMT" _test_lock_acquire "$P/idle" && ok "stale lock stolen" || bad "stale lock not stolen"
"$TMT" _test_lock_release "$P/idle"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test.sh 2>&1 | tail -10`
Expected: FAIL — `_test_lock_acquire` is not a recognized subcommand.

- [ ] **Step 3: Implement lock helpers and test-only subcommands**

Insert in `bin/tmt` after line 69 (`PROMPT_RE=...`), before the color block:

```bash
# Ready-box pattern: the agent's empty input prompt (turn completed).
# Separate from PROMPT_RE (which detects questions like y/n). Matches:
#   ❯  (Claude Code), >  (aider), $  (shell)
READY_RE='(❯[[:space:]]*$|^>[[:space:]]*$|\$[[:space:]]*$)'

# --- per-session lock (mkdir-based, atomic, no flock dependency) -------------

_lock_path() { printf '%s/%s.lock' "$STATE_DIR" "$(key_of "$1")"; }

_lock_acquire() {
  local sess="$1" lpath
  lpath=$(_lock_path "$sess")
  if mkdir "$lpath" 2>/dev/null; then
    printf '%s' "$$" > "$lpath/pid"
    return 0
  fi
  # Lock exists — check if the holder is alive.
  local holder
  holder=$(<"$lpath/pid" 2>/dev/null) || holder=""
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    die "$EX_LOCKED" "session $sess is locked by pid $holder"
  fi
  # Holder is dead — steal.
  rm -rf "$lpath"
  if mkdir "$lpath" 2>/dev/null; then
    printf '%s' "$$" > "$lpath/pid"
    return 0
  fi
  die "$EX_LOCKED" "session $sess is locked (race)"
}

_lock_release() {
  local sess="$1"
  rm -rf "$(_lock_path "$sess")"
}
```

Then add test-only subcommands in the `main()` case block (after the `*) die` line is wrong — add before `*)`):

In the `main()` function at line 938, before the `*) die` line, add:

```bash
    _test_lock_acquire) _lock_acquire "$@" ;;
    _test_lock_release) _lock_release "$@" ;;
```

- [ ] **Step 4: Run test to verify lock tests pass**

Run: `bash test/test.sh 2>&1 | grep -E 'lock|stale'`
Expected: all ok — "lock acquired", "lock contention exits 4", "lock released", "lock re-acquire after release", "stale lock stolen".

- [ ] **Step 5: Commit**

```bash
git add bin/tmt test/test.sh
git commit -m "feat: add per-session mkdir lock (Phase B §4)"
```

---

### Task 2: Wire lock into `send` and `key`

**Files:**
- Modify: `bin/tmt` (lines 216-232: `cmd_send` and `cmd_key`)

- [ ] **Step 1: Write the lock-blocks-send test**

Append to `test/test.sh` (after the stale-lock test):

```bash
# send respects lock: holding a lock blocks tmt send
"$TMT" _test_lock_acquire "$P/idle"
"$TMT" send "$P/idle" -- 'blocked' 2>/dev/null; [[ $? -eq 4 ]] && ok "send blocked by lock" || bad "send not blocked"
"$TMT" _test_lock_release "$P/idle"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test.sh 2>&1 | grep 'send blocked'`
Expected: FAIL — send currently ignores locks.

- [ ] **Step 3: Wire lock into cmd_send and cmd_key**

Replace `cmd_send` (lines 216-224) with:

```bash
cmd_send() {
  have_tmux
  local sess="${1:?usage: tmt send SESSION -- TEXT}"; shift
  tmux has-session -t "$sess" 2>/dev/null || die "$EX_NOSESSION" "no such session: $sess"
  [[ "${1:-}" == "--" ]] && shift
  local text="$*"
  _lock_acquire "$sess"
  trap '_lock_release "$sess"' RETURN
  _send_line "$sess" "$text" && \
    printf '%s→ sent to %s:%s %s\n' "$c_grn" "$sess" "$c_reset" "$text"
}
```

Replace `cmd_key` (lines 226-232) with:

```bash
cmd_key() {
  have_tmux
  local sess="${1:?usage: tmt key SESSION KEY...}"; shift
  tmux has-session -t "$sess" 2>/dev/null || die "$EX_NOSESSION" "no such session: $sess"
  _lock_acquire "$sess"
  trap '_lock_release "$sess"' RETURN
  tmux send-keys -t "$sess" "$@" && \
    printf '%s→ sent keys to %s:%s %s\n' "$c_grn" "$sess" "$c_reset" "$*"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test.sh 2>&1 | grep 'send blocked'`
Expected: "ok   send blocked by lock"

Also verify existing tests still pass:
Run: `bash test/test.sh 2>&1 | grep -c '^.*ok'`
Expected: count increases by the new tests, no FAILs.

- [ ] **Step 5: Commit**

```bash
git add bin/tmt test/test.sh
git commit -m "feat: wire per-session lock into send/key (Phase B §4)"
```

---

### Task 3: Readiness detection helper (`_turn_done`)

**Files:**
- Modify: `bin/tmt` (insert after `_lock_release`, before `# Colors only when...`)

- [ ] **Step 1: Write a readiness test**

Append to `test/test.sh`:

```bash
# readiness: a session showing ❯ prompt after quiescence is "done"
tmux kill-session -t "$P/ready" 2>/dev/null
tmux new-session -d -s "$P/ready"
tmux send-keys -t "$P/ready" 'printf "output\\n"; sleep 0.5; printf "❯ "' Enter
sleep 2
# After 2s the pane should be quiescent with ❯ showing
result=$("$TMT" _test_turn_done "$P/ready" 1)
[[ "$result" == "done" ]] && ok "turn_done detects ready box" || bad "turn_done: got '$result'"
tmux kill-session -t "$P/ready" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test.sh 2>&1 | grep 'turn_done'`
Expected: FAIL — `_test_turn_done` not recognized.

- [ ] **Step 3: Implement `_turn_done`**

Insert in `bin/tmt` after `_lock_release`:

```bash
# --- readiness detection (Phase B §2) ----------------------------------------
#
# _turn_done SESSION QUIESCENT_SECS
#   Checks if the session's pane has been stable for QUIESCENT seconds AND
#   the tail matches a ready-box pattern. Returns (prints):
#     "done"    — agent finished its turn (ready box showing)
#     "blocked" — agent quiesced but on a question (PROMPT_RE matches)
#     "active"  — pane is still changing or hasn't been quiescent long enough
#
# Uses its own hash state file (.ask.hash) so it never perturbs detect()'s
# RUNNING/STALE tracking.

_turn_done() {
  local sess="$1" quiescent="${2:-5}"
  local pane last hash statef prev prev_time now elapsed

  pane=$(tmux capture-pane -t "$sess" -p 2>/dev/null)
  last=$(printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -n 1)
  hash=$(printf '%s' "$pane" | cksum | cut -d' ' -f1)

  statef="$STATE_DIR/$(key_of "$sess").ask.hash"
  now=$(date +%s)

  if [[ -f "$statef" ]]; then
    prev=$(sed -n '1p' "$statef")
    prev_time=$(sed -n '2p' "$statef")
  else
    prev=""; prev_time="$now"
  fi

  if [[ "$hash" != "$prev" ]]; then
    # Pane changed — reset the quiescence timer.
    printf '%s\n%s\n' "$hash" "$now" > "$statef"
    printf 'active'
    return
  fi

  # Pane unchanged — check how long.
  elapsed=$((now - prev_time))
  if [[ "$elapsed" -lt "$quiescent" ]]; then
    printf 'active'
    return
  fi

  # Quiescent long enough. Check what's showing.
  if [[ "$last" =~ $PROMPT_RE ]]; then
    printf 'blocked'
  elif [[ "$last" =~ $READY_RE ]]; then
    printf 'done'
  else
    printf 'active'
  fi
}
```

Add test-only subcommand in `main()` (next to the other `_test_` entries):

```bash
    _test_turn_done) _turn_done "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test.sh 2>&1 | grep 'turn_done'`
Expected: "ok   turn_done detects ready box"

- [ ] **Step 5: Commit**

```bash
git add bin/tmt test/test.sh
git commit -m "feat: add _turn_done readiness helper (Phase B §2)"
```

---

### Task 4: `cmd_ask` — the core request/response command

**Files:**
- Modify: `bin/tmt` (new `cmd_ask` function, insert before `# --- serve`)
- Modify: `bin/tmt` (main dispatcher, add `ask)` line)

- [ ] **Step 1: Write the ask round-trip test**

Append to `test/test.sh`:

```bash
# ask round-trip: send prompt, get reply as JSON
tmux kill-session -t "$P/ask" 2>/dev/null
tmux new-session -d -s "$P/ask"
# A mini agent: reads a line, prints a reply, then shows ❯ prompt
tmux send-keys -t "$P/ask" 'while true; do read l; echo "REPLY:[$l]"; printf "❯ "; done' Enter
sleep 1
# Prime the ❯ prompt
tmux send-keys -t "$P/ask" '' Enter
sleep 1

askout=$("$TMT" ask "$P/ask" --timeout 10 --quiescent 2 -- 'hello world' 2>/dev/null)
askstatus=$(printf '%s' "$askout" | jq -r .status)
askreply=$(printf '%s' "$askout" | jq -r .reply)
[[ "$askstatus" == "done" ]] && ok "ask returns status done" || bad "ask status: '$askstatus'"
printf '%s' "$askreply" | grep -q 'REPLY:\[.*hello world\]' && ok "ask reply contains agent output" || bad "ask reply: '$askreply'"
# Marker should NOT be in the reply
printf '%s' "$askreply" | grep -q '<<<TMT_ASK:' && bad "ask reply contains marker" || ok "ask reply excludes marker"
tmux kill-session -t "$P/ask" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test.sh 2>&1 | grep 'ask'`
Expected: FAIL — unknown subcommand `ask`.

- [ ] **Step 3: Implement `cmd_ask`**

Insert in `bin/tmt` before the line `# --- serve: live HTML dashboard ---` (line 403):

```bash
# --- ask: send-and-await-reply (Phase B §3) -----------------------------------
#
# tmt ask SESSION [--timeout S] [--quiescent S] [--lines N] -- "prompt"
#
# Sends a prompt with an embedded marker, waits for the agent to complete its
# turn (quiescence + ready-box), then extracts and returns only the new output
# between the marker and the input box as JSON.

cmd_ask() {
  have_tmux
  need jq
  local sess="${1:?usage: tmt ask SESSION [--timeout S] [--quiescent S] [--lines N] -- PROMPT}"; shift
  tmux has-session -t "$sess" 2>/dev/null || die "$EX_NOSESSION" "no such session: $sess"

  local timeout=300 quiescent=5 lines=5000
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)   timeout="$2"; shift 2 ;;
      --quiescent) quiescent="$2"; shift 2 ;;
      --lines)     lines="$2"; shift 2 ;;
      --)          shift; break ;;
      *)           break ;;
    esac
  done
  local prompt="$*"
  [[ -z "$prompt" ]] && die "ask: no prompt provided"

  _lock_acquire "$sess"
  trap '_lock_release "$sess"; rm -f "$STATE_DIR/$(key_of "$sess").ask.hash"' RETURN

  # Generate a unique marker and build the wire text (one line, one turn).
  local marker="<<<TMT_ASK:$$-$SECONDS>>>"
  local wire="$marker $prompt"

  # Clear any prior ask-hash state so the quiescence timer starts fresh.
  rm -f "$STATE_DIR/$(key_of "$sess").ask.hash"

  # Send.
  _send_line "$sess" "$wire" || die "ask: send failed"

  # Poll until done, blocked, or timeout.
  local elapsed=0 state=""
  while [[ "$elapsed" -lt "$timeout" ]]; do
    sleep 1
    elapsed=$((elapsed + 1))
    state=$(_turn_done "$sess" "$quiescent")
    [[ "$state" == "active" ]] && continue
    break
  done

  # If still active after timeout, report timeout.
  [[ "$state" == "active" ]] && state="timeout"

  # Capture and extract the reply region.
  local pane reply=""
  pane=$(tmux capture-pane -t "$sess" -p -S "-$lines" 2>/dev/null)

  # Find the LAST occurrence of our marker in the pane. Everything after it
  # (minus the marker line itself, trailing ready-box, and blank lines) is
  # the reply.
  local marker_line_num last_line_num
  marker_line_num=$(printf '%s\n' "$pane" | grep -n "$marker" | tail -1 | cut -d: -f1)
  if [[ -n "$marker_line_num" ]]; then
    last_line_num=$(printf '%s\n' "$pane" | wc -l)
    reply=$(printf '%s\n' "$pane" | sed -n "$((marker_line_num + 1)),${last_line_num}p")
    # Trim trailing ready-box lines and blanks.
    reply=$(printf '%s\n' "$reply" | sed -e '/^[[:space:]]*$/d' | \
      tac | while IFS= read -r line; do
        if [[ "$line" =~ $READY_RE ]]; then continue; fi
        printf '%s\n' "$line"; break
      done | tac)
    # If tac left nothing (all lines were ready-box), reply stays empty.
    # Actually we need to collect all non-trimmed lines:
    reply=$(printf '%s\n' "$pane" | sed -n "$((marker_line_num + 1)),${last_line_num}p" | \
      _trim_trailing_ready)
  fi

  # Output JSON.
  local exit_code=0
  [[ "$state" == "timeout" ]] && exit_code=$EX_TIMEOUT
  jq -n --arg sess "$sess" --arg id "$$-$SECONDS" --arg status "$state" \
        --argjson elapsed "$elapsed" --arg reply "$reply" \
    '{session:$sess, id:$id, status:$status, elapsed_s:$elapsed, reply:$reply}'
  return "$exit_code"
}

# Trim trailing lines that match READY_RE or are blank. Reads stdin.
_trim_trailing_ready() {
  local -a lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done
  # Walk backward, dropping ready-box and blank lines.
  local i=${#lines[@]}
  while [[ $i -gt 0 ]]; do
    i=$((i - 1))
    local l="${lines[$i]}"
    if [[ -z "${l// /}" ]] || [[ "$l" =~ $READY_RE ]]; then
      unset 'lines[i]'
    else
      break
    fi
  done
  printf '%s\n' "${lines[@]}"
}
```

Then add to the `main()` dispatcher (after the `send)` line at 925):

```bash
    ask)         cmd_ask "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test.sh 2>&1 | grep -E 'ask (returns|reply)'`
Expected:
```
ok   ask returns status done
ok   ask reply contains agent output
ok   ask reply excludes marker
```

- [ ] **Step 5: Commit**

```bash
git add bin/tmt test/test.sh
git commit -m "feat: add tmt ask request/response primitive (Phase B §3)"
```

---

### Task 5: Blocked and timeout tests

**Files:**
- Modify: `test/test.sh` (append)

- [ ] **Step 1: Write blocked-detection test**

Append to `test/test.sh`:

```bash
# ask blocked: agent quiesces on a question, not a ready box
tmux kill-session -t "$P/askblk" 2>/dev/null
tmux new-session -d -s "$P/askblk"
# Agent that asks a question after receiving input
tmux send-keys -t "$P/askblk" 'while true; do read l; echo "got it"; sleep 0.5; read "a?proceed? (y/n) "; done' Enter
sleep 1
# Prime the read prompt
tmux send-keys -t "$P/askblk" '' Enter; sleep 1.5

blkout=$("$TMT" ask "$P/askblk" --timeout 10 --quiescent 2 -- 'test input' 2>/dev/null)
blkstatus=$(printf '%s' "$blkout" | jq -r .status)
[[ "$blkstatus" == "blocked" ]] && ok "ask detects blocked status" || bad "ask blocked: '$blkstatus'"
tmux kill-session -t "$P/askblk" 2>/dev/null
```

- [ ] **Step 2: Write timeout test**

Append to `test/test.sh`:

```bash
# ask timeout: session that never shows a ready box
tmux kill-session -t "$P/asktmo" 2>/dev/null
tmux new-session -d -s "$P/asktmo"
# Runs a long sleep — never shows ❯ or a prompt
tmux send-keys -t "$P/asktmo" 'sleep 120' Enter
sleep 1

tmoout=$("$TMT" ask "$P/asktmo" --timeout 4 --quiescent 2 -- 'ping' 2>/dev/null)
tmorc=$?
tmostatus=$(printf '%s' "$tmoout" | jq -r .status)
[[ "$tmorc" -eq 7 ]] && ok "ask timeout exits 7" || bad "ask timeout exit: $tmorc"
[[ "$tmostatus" == "timeout" ]] && ok "ask timeout status field" || bad "ask timeout status: '$tmostatus'"
tmux kill-session -t "$P/asktmo" 2>/dev/null
```

- [ ] **Step 3: Run all tests**

Run: `bash test/test.sh 2>&1 | tail -15`
Expected: "ok   ask detects blocked status", "ok   ask timeout exits 7", "ok   ask timeout status field", no FAILs.

- [ ] **Step 4: Commit**

```bash
git add test/test.sh
git commit -m "test: add blocked and timeout cases for tmt ask"
```

---

### Task 6: Lock contention integration test

**Files:**
- Modify: `test/test.sh` (append)

- [ ] **Step 1: Write the contention test**

Append to `test/test.sh`:

```bash
# lock contention end-to-end: ask holds lock, send is rejected, then succeeds
tmux kill-session -t "$P/asklk" 2>/dev/null
tmux new-session -d -s "$P/asklk"
# Slow agent: waits 4s before showing ready
tmux send-keys -t "$P/asklk" 'while true; do read l; sleep 3; echo "done"; printf "❯ "; done' Enter
sleep 1
tmux send-keys -t "$P/asklk" '' Enter; sleep 1

# Launch ask in background (will hold lock for ~4-5s)
"$TMT" ask "$P/asklk" --timeout 15 --quiescent 2 -- 'hold lock' >/dev/null 2>&1 &
askpid=$!
sleep 1

# While ask is in flight, send should fail with exit 4
"$TMT" send "$P/asklk" -- 'interloper' 2>/dev/null; lkrc=$?
[[ "$lkrc" -eq 4 ]] && ok "send blocked during ask" || bad "send during ask: exit $lkrc"

# Wait for ask to finish, then send should succeed
wait "$askpid" 2>/dev/null
sleep 0.5
"$TMT" send "$P/asklk" -- 'after' >/dev/null 2>&1; lkrc2=$?
[[ "$lkrc2" -eq 0 ]] && ok "send succeeds after ask completes" || bad "send after ask: exit $lkrc2"
tmux kill-session -t "$P/asklk" 2>/dev/null
```

- [ ] **Step 2: Run test**

Run: `bash test/test.sh 2>&1 | grep -E 'send (blocked|succeeds)'`
Expected: "ok   send blocked during ask", "ok   send succeeds after ask completes"

- [ ] **Step 3: Commit**

```bash
git add test/test.sh
git commit -m "test: add lock contention integration test for ask vs send"
```

---

### Task 7: Completions, help text, version bump

**Files:**
- Modify: `bin/tmt` (lines 1-28 header, line 43 version)
- Modify: `completions/tmt.bash`

- [ ] **Step 1: Add `ask` to the help header**

In `bin/tmt`, insert after the `send` line in the header comment (after line 16):

```bash
#   ask   SESSION [--timeout S] [--quiescent S] [--lines N] -- PROMPT
#                                           Send prompt, await reply (JSON output)
```

- [ ] **Step 2: Bump version**

Change line 45:

```bash
TMT_VERSION="0.4.0"
```

- [ ] **Step 3: Add `ask` to bash completion**

In `completions/tmt.bash`, add `ask` to the `subcmds` string:

```bash
  subcmds="watch ls status capture send ask key new dispatch registry save restore snapshots agent-scan serve attach version help"
```

Add a completion case for `ask` (after the `serve)` case):

```bash
    ask)
      if [[ $COMP_CWORD -eq 2 ]]; then
        local sessions
        sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
        mapfile -t COMPREPLY < <(compgen -W "$sessions" -- "$cur")
      elif [[ "$cur" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--timeout --quiescent --lines" -- "$cur")
      fi
      return
      ;;
```

- [ ] **Step 4: Verify syntax and tests**

Run: `bash -n bin/tmt && echo "syntax OK"`
Run: `bash test/test.sh 2>&1 | grep -c 'ok'` — should be total of all tests passing.
Run: `bin/tmt --help | grep ask` — should show the ask line.

- [ ] **Step 5: Commit**

```bash
git add bin/tmt completions/tmt.bash
git commit -m "feat: wire tmt ask into completion/help, bump to v0.4.0 (Phase B)"
```

---

### Task 8: Reinstall and smoke-test against live fleet

**Files:** none (verification only)

- [ ] **Step 1: Reinstall**

```bash
make install
tmt version
# Expected: tmt (tmux-tasks) 0.4.0
```

- [ ] **Step 2: Run full test suite**

```bash
bash test/test.sh
# Expected: all ok, 0 fails
```

- [ ] **Step 3: Smoke-test ask against a real idle session**

Pick any IDLE session (shell prompt showing `$`):

```bash
tmt ask codex --timeout 10 --quiescent 3 -- 'echo hello-from-ask'
```

Expected: JSON with `status: "done"`, reply containing `hello-from-ask`.

- [ ] **Step 4: Verify lock works live**

```bash
# In one terminal:
tmt ask codex --timeout 30 --quiescent 5 -- 'sleep 5 && echo done-sleeping'
# In another terminal immediately:
tmt send codex -- 'interloper'
# Expected: exit 4, "locked by pid ..."
```

- [ ] **Step 5: Final commit (if any adjustments needed)**

```bash
git add -A && git commit -m "fix: adjustments from live smoke test" || echo "nothing to commit"
```
