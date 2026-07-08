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
cleanup() { for s in idle running waiting; do tmux kill-session -t "$P/$s" 2>/dev/null; done; }
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

exit $fail
