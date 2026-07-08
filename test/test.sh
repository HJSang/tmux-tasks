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

exit $fail
