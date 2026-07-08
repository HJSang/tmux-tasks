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

## Surviving reboots (save / restore)

A reboot kills every process, so **no tool can revive a running build or a live agent** — tmux sessions are just processes. What `tmt` (like tmux-resurrect) does is snapshot the session *layout* — session name, working directory, and the foreground command — and recreate it afterward.

```bash
tmt save                       # snapshot all sessions
tmt save --filter 'task/*' --name work
tmt snapshots                  # list saved snapshots
tmt restore --dry-run          # preview what the latest snapshot would recreate
tmt restore                    # recreate the sessions (shells only)
tmt restore --run              # recreate AND re-launch the captured commands
tmt restore work-20260708-163011.tsv --run   # restore a specific snapshot
```

Snapshots are stored in `~/.local/share/tmux-tasks/snapshots/` — a **persistent** location, deliberately not `/tmp` (which many systems wipe on the very reboot you're guarding against). The last 20 snapshots are kept; `latest.tsv` always points at the newest.

**Automate it** so you never forget to save, and sessions come back after every reboot:

```bash
# 1. periodic autosave (cron) — snapshot every 15 min
*/15 * * * * $HOME/.local/bin/tmt save --filter 'task/*' --name auto >/dev/null 2>&1

# 2. restore on login — add to ~/.bashrc or ~/.zshrc
tmt restore --run 2>/dev/null   # recreates sessions from the latest snapshot
```

Restore is session-level (one tmux session per task, matching how `tmt` is used) and skips sessions that already exist, so re-running it is safe. Full multi-pane layout revival is out of scope.

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

`tmt agent-scan --json` emits `{session, state, fg_process, type, task, isolation, pane_tail}` per session. Point a Claude Code session at it to summarize status and, for any WAITING session, propose input for you to approve. Allowlist the read-only calls in `~/.claude/settings.json` (`tmt ls/status/capture/agent-scan/registry`) and leave `tmt send`/`key` off the allowlist so the agent always confirms before typing.

### Orchestration (multi-agent, in progress)

`tmt` is growing into a supervisor for many long-lived, isolated agent tasks driven by a Claude Code orchestrator. See [`DESIGN.md`](DESIGN.md) for the full two-tier model (native subagents *within* a task; `tmt` *across* tasks). Shipped so far (Phase A):

- **Agent-consumable I/O** — colors auto-strip when stdout isn't a TTY (or set `NO_COLOR=1`); stable exit codes (`0` ok · `2` usage · `3` no session · `4` locked · `5` policy-denied · `6` no tmux · `7` timeout).
- **Session registry** — per-task metadata (type, task, isolation, ready-pattern) at `~/.local/share/tmux-tasks/registry/`. `tmt registry [SESSION]` prints it as JSON.
- **`tmt dispatch`** — create one isolated giant task and register it:

```bash
# independent project (cwd isolation)
tmt dispatch task/perf-audit --type aider --isolation cwd --cwd ~/projects/perf -- 'aider .'

# same-repo task (git worktree isolation — own branch + working tree)
tmt dispatch task/auth-rewrite --type claude --isolation worktree \
    --repo ~/code/app --branch auth-rewrite -- 'claude'
```

Worktree tasks get a dedicated `git worktree` under `<repo>/../tmt-worktrees/<branch>`, so multiple long-lived agents on one repo can't corrupt each other's tree.

Not yet shipped: `tmt ask` (send-and-await-reply), the auto-response policy layer, and the `tmt-orchestrate` skill. See `DESIGN.md` phases B–D.

## License

Free and open source — public domain. Do whatever you like with it.
