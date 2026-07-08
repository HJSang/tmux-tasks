# tmux-tasks (`tmt`)

Run each of your tasks in its own tmux session, then **monitor and drive all of them from one place**. `tmt` lists your sessions, detects whether each is running / idle / waiting-for-input / possibly-hung, shows a live table, and lets you send input to a session without attaching — all in the terminal.

It also exposes an `agent-scan` digest so a coding agent (e.g. Claude Code) can read every session's state and help you decide what to type into the ones that are blocked.

## Install

**Make / install.sh** (Linux + macOS, no dependencies beyond tmux):

```bash
git clone https://github.com/HJSang/tmux-tasks.git
cd tmux-tasks
make install                 # -> ~/.local/bin/tmt
# system-wide: sudo make install PREFIX=/usr/local
```

Or one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/HJSang/tmux-tasks/main/install.sh | bash
```

**Homebrew** (macOS / Linuxbrew):

```bash
brew tap HJSang/tap
brew install tmux-tasks
```

Requires `tmux`. `jq` is only needed for `agent-scan --json`.

## Usage

```bash
tmt                                  # live auto-refreshing table (default)
tmt watch --filter 'task/*' --interval 5
tmt ls   --filter 'task/*'           # one-shot table
tmt status  task/auth-fix            # state + recent output of one session
tmt capture task/auth-fix --lines 200
tmt send task/auth-fix -- 'y'        # type a line into a session
tmt key  task/auth-fix C-c           # send a control key
tmt new  task/2026-07-08/auth-fix -- 'aider .'   # create a task session
tmt attach task/auth-fix
```

In `watch`, single-key actions: `#` attach, `s` send-input (with confirm), `k` raw key, `c` capture, `r` refresh, `q` quit.

### States

| State | Meaning |
|---|---|
| ▶ RUNNING | a non-shell process is working and output is moving |
| ⏳ WAITING | last line looks like a prompt — needs your input |
| · IDLE | foreground process is a shell; nothing running |
| ■ STALE | non-shell process but output hasn't changed since last scan (maybe hung) |

### Tip: name sessions by date/week

```bash
tmt new task/2026-07-08/auth-fix
tmt watch --filter 'task/2026-07-08/*'
```

## Agent integration

`tmt agent-scan --json` emits `{session, state, fg_process, pane_tail}` per session. Point a Claude Code session at it to summarize status and, for any WAITING session, propose input for you to approve. Allowlist the read-only calls in `~/.claude/settings.json` (`tmt ls/status/capture/agent-scan`) and leave `tmt send`/`key` off the allowlist so the agent always confirms before typing.

## License

Free and open source — public domain. Do whatever you like with it.
