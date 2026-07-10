#!/usr/bin/env bash
# Smoke test for tmt. Creates throwaway tmux sessions, exercises detection,
# send, and agent-scan, then cleans up. Safe to run repeatedly.
set -uo pipefail

TMT="$(cd "$(dirname "$0")/.." && pwd)/bin/tmt"
P="tmttest_$$"   # unique prefix so we never touch real sessions
fail=0
ok()   { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

command -v tmux >/dev/null || { echo "tmux not installed; skipping"; exit 0; }
cleanup() {
  for s in idle running waiting ready ask askblk asktmo asklk; do tmux kill-session -t "$P/$s" 2>/dev/null; done
  # remove any lock dirs and ask-state files (ours, or strays from prior runs)
  rm -rf "${TMPDIR:-/tmp}/tmux-tasks-${USER:-$(id -un)}"/tmttest_*.lock 2>/dev/null
  rm -f "${TMPDIR:-/tmp}/tmux-tasks-${USER:-$(id -un)}"/tmttest_*.ask.hash 2>/dev/null
}
trap cleanup EXIT

# version works with no tmux dependency
"$TMT" version | grep -q "tmux-tasks" && ok "version" || bad "version"

# build three sessions in known states
tmux new-session -d -s "$P/idle"
tmux new-session -d -s "$P/running"; tmux send-keys -t "$P/running" 'sleep 60' Enter
tmux new-session -d -s "$P/waiting"; tmux send-keys -t "$P/waiting" 'read "a?proceed? (y/n) "' Enter
sleep 1

scan=$("$TMT" agent-scan --filter "$P/*" --json)

check() { # session, expected-state
  local got; got=$(printf '%s' "$scan" | jq -r ".[] | select(.session==\"$P/$1\") | .state")
  [[ "$got" == "$2" ]] && ok "$1 -> $2" || bad "$1: expected $2, got '$got'"
}
check idle IDLE
check waiting WAITING
# running may read RUNNING or STALE depending on timing; accept either non-idle
rstate=$(printf '%s' "$scan" | jq -r ".[] | select(.session==\"$P/running\") | .state")
[[ "$rstate" == "RUNNING" || "$rstate" == "STALE" ]] && ok "running -> $rstate" || bad "running: got '$rstate'"

# send input resolves the waiting prompt
"$TMT" send "$P/waiting" -- 'y' >/dev/null
sleep 1
after=$(tmux display-message -t "$P/waiting" -p '#{pane_current_command}')
[[ "$after" =~ (zsh|bash|sh) ]] && ok "send resolved prompt" || bad "send: fg still '$after'"

# new + duplicate guard
"$TMT" new "$P/idle" >/dev/null 2>&1 && bad "new: should reject duplicate" || ok "new rejects duplicate"

# save / restore round-trip: snapshot cwd + command, kill, restore, verify
snapdir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-tasks/snapshots"
tmux kill-session -t "$P/running" 2>/dev/null
tmux new-session -d -s "$P/running" -c /tmp
tmux send-keys -t "$P/running" 'sleep 60' Enter
sleep 0.7
"$TMT" save --filter "$P/*" --name "$P" >/dev/null
snapf=$(ls -1t "$snapdir/$P"-*.tsv 2>/dev/null | head -1)
[[ -f "$snapf" ]] && ok "save wrote snapshot" || bad "save: no snapshot file"
grep -q $'/tmp\t.*sleep 60' "$snapf" && ok "snapshot captured cwd + cmd" || bad "snapshot missing cwd/cmd"

tmux kill-session -t "$P/running" 2>/dev/null   # simulate reboot
"$TMT" restore "$snapf" --run >/dev/null
sleep 1
rcwd=$(tmux display-message -t "$P/running" -p '#{pane_current_path}' 2>/dev/null)
[[ "$rcwd" == /tmp ]] && ok "restore recreated session in correct cwd" || bad "restore cwd: got '$rcwd'"
rm -f "$snapdir/$P"-*.tsv

# --- Phase A: agent-consumable I/O, registry, dispatch --------------------

# colors stripped when stdout is not a TTY
if "$TMT" version | cat -v | grep -q '\^\['; then bad "ansi leaks when piped"; else ok "no ansi when piped"; fi

# stable exit codes
"$TMT" status "nope-$$" >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "exit 3 on no-session" || bad "no-session exit code"
"$TMT" bogus-sub       >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "exit 2 on bad usage"  || bad "usage exit code"

# dispatch (cwd isolation) writes registry + launches
regdir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-tasks/registry"
"$TMT" dispatch "$P/disp" --type shell --isolation cwd --cwd /tmp -- 'sleep 60' >/dev/null
sleep 0.5
tmux has-session -t "$P/disp" 2>/dev/null && ok "dispatch created session" || bad "dispatch: no session"
rtype=$("$TMT" registry "$P/disp" | jq -r .type)
[[ "$rtype" == shell ]] && ok "registry records type" || bad "registry type: got '$rtype'"
ready=$("$TMT" registry "$P/disp" | jq -r .ready_pattern)
[[ "$ready" == "<<<TMT_READY:$P/disp>>>" ]] && ok "registry has sentinel ready-pattern" || bad "ready_pattern: '$ready'"

# agent-scan carries registry fields
scantype=$("$TMT" agent-scan --filter "$P/disp" --json | jq -r '.[0].type')
[[ "$scantype" == shell ]] && ok "agent-scan includes type" || bad "agent-scan type: '$scantype'"

# dispatch worktree isolation makes a real git worktree
gt=$(mktemp -d); git -C "$gt" init -q
git -C "$gt" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
"$TMT" dispatch "$P/wt" --type claude --isolation worktree --repo "$gt" --branch b1 -- 'sleep 60' >/dev/null
sleep 0.5
wcwd=$(tmux display-message -t "$P/wt" -p '#{pane_current_path}' 2>/dev/null)
[[ "$wcwd" == *tmt-worktrees/b1 ]] && ok "worktree session cwd is the worktree" || bad "worktree cwd: '$wcwd'"

# send splits text + Enter and actually submits (Enter registers)
tmux new-session -d -s "$P/sub" -c /tmp
tmux send-keys -t "$P/sub" 'read l; echo "GOT:[$l]"' Enter
sleep 0.8
"$TMT" send "$P/sub" -- 'submit-me' >/dev/null
sleep 1
tmux capture-pane -t "$P/sub" -p | grep -q 'GOT:\[submit-me\]' && ok "send submits (Enter registers)" || bad "send: Enter not registered"
tmux kill-session -t "$P/sub" 2>/dev/null

# serve: static tabbed shell + live data.json the browser polls (needs python3 + curl + jq)
if command -v python3 >/dev/null && command -v curl >/dev/null && command -v jq >/dev/null; then
  tmux new-session -d -s "$P/srun" -c /tmp; tmux send-keys -t "$P/srun" 'sleep 60' Enter
  tmux new-session -d -s "$P/swait" -c /tmp; tmux send-keys -t "$P/swait" 'read "a?go? (y/n) "' Enter
  sleep 1
  sport=8791
  "$TMT" serve --filter "$P/s*" --port "$sport" --interval 2 --lines 8 >/dev/null 2>&1 &
  spid=$!
  sleep 2
  shtml=$(curl -s "http://127.0.0.1:$sport/" 2>/dev/null)
  sdata=$(curl -s "http://127.0.0.1:$sport/data.json" 2>/dev/null)
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  # the shell carries the 5 status tabs
  ntabs=$(printf '%s' "$shtml" | grep -oE 'href="#(all|waiting|stale|running|idle)"' | sort -u | wc -l)
  [[ "$ntabs" -eq 5 ]] && ok "serve renders 5 status tabs" || bad "serve tabs: got $ntabs"
  # shell no longer meta-refreshes; it polls data.json instead
  printf '%s' "$shtml" | grep -q 'http-equiv="refresh"' && bad "serve still uses meta refresh" || ok "serve dropped meta refresh (polls in place)"
  printf '%s' "$shtml" | grep -q "fetch('data.json" && ok "serve shell polls data.json" || bad "serve: no data.json poll"
  # data.json is valid and carries the waiting session with its state
  wstate=$(printf '%s' "$sdata" | jq -r ".sessions[] | select(.session==\"$P/swait\") | .state" 2>/dev/null)
  [[ "$wstate" == "WAITING" ]] && ok "serve data.json reports session state" || bad "serve data.json state: got '$wstate'"
  tmux kill-session -t "$P/srun" 2>/dev/null; tmux kill-session -t "$P/swait" 2>/dev/null
else
  echo "skip serve test (python3/curl/jq missing)"
fi

# cleanup phase A
tmux kill-session -t "$P/disp" 2>/dev/null; tmux kill-session -t "$P/wt" 2>/dev/null
rm -f "$regdir/${P//\//_}"*.json
rm -rf "$gt" "$(dirname "$gt")/tmt-worktrees" 2>/dev/null

# --- Phase B: ask, readiness, lock -------------------------------------------

# lock acquire/contention/release/re-acquire. Record OUR pid ($$) as holder so
# the liveness check in the contention case sees a live process (the tmt
# process that acquires exits immediately, so its own pid would look stale).
"$TMT" _test_lock_acquire "$P/idle" $$ && ok "lock acquired" || bad "lock acquire failed"
"$TMT" _test_lock_acquire "$P/idle" 2>/dev/null; [[ $? -eq 4 ]] && ok "lock contention exits 4" || bad "lock contention"
"$TMT" _test_lock_release "$P/idle" && ok "lock released" || bad "lock release failed"
"$TMT" _test_lock_acquire "$P/idle" $$ && ok "lock re-acquire after release" || bad "lock re-acquire failed"
"$TMT" _test_lock_release "$P/idle"

# stale lock steal: a lock recording a dead pid is auto-stolen. Spawn and reap
# a child so we have a pid that is guaranteed dead (hardcoded pids can collide
# with live processes on busy hosts).
( : ) & deadpid=$!; wait "$deadpid" 2>/dev/null
statedir="${TMPDIR:-/tmp}/tmux-tasks-${USER:-$(id -un)}"
stalekey=$(printf '%s' "$P/idle" | tr -c 'A-Za-z0-9._-' '_')
mkdir -p "$statedir/$stalekey.lock"
echo "$deadpid" > "$statedir/$stalekey.lock/pid"
"$TMT" _test_lock_acquire "$P/idle" $$ && ok "stale lock stolen" || bad "stale lock not stolen"
"$TMT" _test_lock_release "$P/idle"

# send respects lock: holding a lock blocks tmt send
"$TMT" _test_lock_acquire "$P/idle" $$
"$TMT" send "$P/idle" -- 'blocked' 2>/dev/null; lkrc=$?
[[ "$lkrc" -eq 4 ]] && ok "send blocked by lock" || bad "send blocked: exit $lkrc (expected 4)"
"$TMT" _test_lock_release "$P/idle"

# readiness: a session showing ❯ prompt after quiescence is "done".
# The trailing sleep holds the foreground so the shell prompt doesn't repaint
# over the ❯ (mimics an agent TUI sitting at its ready box).
tmux kill-session -t "$P/ready" 2>/dev/null
tmux new-session -d -s "$P/ready"
tmux send-keys -t "$P/ready" 'printf "output\n"; sleep 0.5; printf "❯ "; sleep 60' Enter
sleep 2
# _turn_done is a polled helper: the first call seeds the quiescence timer
# (state file records hash + first-seen time), later calls measure elapsed.
seed=$("$TMT" _test_turn_done "$P/ready" 1)
[[ "$seed" == "active" ]] && ok "turn_done first poll seeds timer (active)" || bad "turn_done seed: got '$seed'"
sleep 1.2
# Pane has been quiescent >1s since the seed call, with ❯ showing
result=$("$TMT" _test_turn_done "$P/ready" 1)
[[ "$result" == "done" ]] && ok "turn_done detects ready box" || bad "turn_done: got '$result'"
tmux kill-session -t "$P/ready" 2>/dev/null

# ask round-trip: send prompt, get reply as JSON
tmux kill-session -t "$P/ask" 2>/dev/null
tmux new-session -d -s "$P/ask"
# A mini agent: reads a line, prints a reply, re-shows ❯ (held by sleep)
tmux send-keys -t "$P/ask" 'while true; do printf "❯ "; read l; echo "REPLY:[$l]"; done' Enter
sleep 1.5

askout=$("$TMT" ask "$P/ask" --timeout 15 --quiescent 2 -- 'hello world' 2>/dev/null)
askrc=$?
askstatus=$(printf '%s' "$askout" | jq -r .status 2>/dev/null)
askreply=$(printf '%s' "$askout" | jq -r .reply 2>/dev/null)
[[ "$askrc" -eq 0 ]] && ok "ask exits 0" || bad "ask exit: $askrc"
[[ "$askstatus" == "done" ]] && ok "ask returns status done" || bad "ask status: '$askstatus'"
printf '%s' "$askreply" | grep -q 'REPLY:\[.*hello world\]' && ok "ask reply contains agent output" || bad "ask reply: '$askreply'"
printf '%s' "$askreply" | grep -q '<<<TMT_ASK:' && bad "ask reply contains marker" || ok "ask reply excludes marker"
tmux kill-session -t "$P/ask" 2>/dev/null

# ask blocked: agent quiesces on a question
tmux kill-session -t "$P/askblk" 2>/dev/null
tmux new-session -d -s "$P/askblk"
# Agent: reads, prints a question, then blocks on read
tmux send-keys -t "$P/askblk" 'printf "❯ "; while true; do read l; echo "got it"; sleep 0.3; read "a?proceed? (y/n) "; done' Enter
sleep 1.5

blkout=$("$TMT" ask "$P/askblk" --timeout 12 --quiescent 2 -- 'test input' 2>/dev/null)
blkrc=$?
blkstatus=$(printf '%s' "$blkout" | jq -r .status 2>/dev/null)
[[ "$blkrc" -eq 0 ]] && ok "ask blocked exits 0" || bad "ask blocked exit: $blkrc"
[[ "$blkstatus" == "blocked" ]] && ok "ask detects blocked status" || bad "ask blocked: '$blkstatus'"
tmux kill-session -t "$P/askblk" 2>/dev/null

# ask timeout: session that never shows a ready box
tmux kill-session -t "$P/asktmo" 2>/dev/null
tmux new-session -d -s "$P/asktmo"
# Runs a long sleep — never shows ❯ or a question prompt
tmux send-keys -t "$P/asktmo" 'sleep 120' Enter
sleep 1

tmoout=$("$TMT" ask "$P/asktmo" --timeout 4 --quiescent 2 -- 'ping' 2>/dev/null)
tmorc=$?
tmostatus=$(printf '%s' "$tmoout" | jq -r .status 2>/dev/null)
[[ "$tmorc" -eq 7 ]] && ok "ask timeout exits 7" || bad "ask timeout exit: $tmorc"
[[ "$tmostatus" == "timeout" ]] && ok "ask timeout status field" || bad "ask timeout status: '$tmostatus'"
tmux kill-session -t "$P/asktmo" 2>/dev/null

# lock contention: ask holds lock, send is rejected, then succeeds after
tmux kill-session -t "$P/asklk" 2>/dev/null
tmux new-session -d -s "$P/asklk"
# Slow agent: reads, waits 4s, prints reply, re-shows ❯
tmux send-keys -t "$P/asklk" 'printf "❯ "; while true; do read l; sleep 3; echo "done:[$l]"; printf "❯ "; done' Enter
sleep 1.5

# Launch ask in background (holds lock for ~4-5s)
"$TMT" ask "$P/asklk" --timeout 15 --quiescent 2 -- 'hold lock' >/dev/null 2>&1 &
askpid=$!
sleep 1.5

# While ask is in flight, send should fail with exit 4
"$TMT" send "$P/asklk" -- 'interloper' 2>/dev/null; lkrc=$?
[[ "$lkrc" -eq 4 ]] && ok "send blocked during ask" || bad "send during ask: exit $lkrc"

# Wait for ask to finish, then send should succeed
wait "$askpid" 2>/dev/null
sleep 0.5
"$TMT" send "$P/asklk" -- 'after' >/dev/null 2>&1; lkrc2=$?
[[ "$lkrc2" -eq 0 ]] && ok "send succeeds after ask completes" || bad "send after ask: exit $lkrc2"
tmux kill-session -t "$P/asklk" 2>/dev/null

exit $fail
