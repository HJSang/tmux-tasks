---
name: tmt
description: Use when the user wants to monitor, summarize, or drive their long-lived per-task tmux sessions via the `tmt` (tmux-tasks) tool — checking which tasks need input, launching a new isolated task, or answering a prompt in one. Triggers on "check my tasks/sessions", "what's blocked", "dispatch/start a task", "monitor the agents", "which session needs input".
---

# tmt — supervising per-task tmux sessions

`tmt` (tmux-tasks) manages long-lived, independent tasks, each in its own tmux
session. You are the **supervisor**: you read fleet state, summarize it, launch
new isolated tasks, and — only with explicit human approval — send input into a
session. You never reach inside a task's own internal work.

**Two-tier rule:** within one task, that task's agent does its own fan-out
(native subagents). `tmt` operates *across* tasks — one session per task. Do not
use `tmt` to parallelize sub-parts of a single task; use it to supervise
separate, long-lived tasks.

## Scope (what is shipped today — Phase A)

Shipped and safe to use: `agent-scan`, `ls`, `status`, `capture`, `registry`,
`dispatch`, `send`, `key`, `save`, `restore`, `snapshots`.

NOT yet built — do not call or promise them: `tmt ask` (send-and-await-reply),
an auto-response policy engine, `tmt reply`, `tmt audit`. Until those exist,
**every `send`/`key` requires explicit human approval each time** (see Safety).

## Reading the fleet (do this first)

Always start from structured state, not a long-running UI. **Never launch
`tmt watch` or `tmt serve` yourself** — both block forever (an interactive TUI
and an HTTP server) and will hang your turn. Use the one-shot commands:

```bash
tmt agent-scan --json            # all sessions: state, type, task, isolation, pane_tail
tmt agent-scan --filter 'task/*' --json
tmt registry                     # per-task metadata (type, isolation, branch, ready-pattern)
tmt status SESSION               # human-readable detail + last 25 lines
tmt capture SESSION --lines 200  # more scrollback when you need context
```

If the **user** wants to watch the fleet themselves, point them at the
status-tabbed browser dashboard — tell them to run it in their own terminal,
don't run it for them: `tmt serve` (opens http://127.0.0.1:8787/, tabs for
all/waiting/stale/running/idle, auto-refreshing, read-only).

State field meanings:
- `RUNNING` — a non-shell process is working; output moving.
- `WAITING` — last pane line looks like a prompt; **likely needs input**.
- `IDLE` — foreground is a shell; nothing running (task done, or agent at rest).
- `STALE` — non-shell process but output unchanged since last scan; maybe hung.

Parse the JSON. When summarizing for the user, lead with what needs attention:
WAITING and STALE sessions first, then RUNNING, then IDLE.

## Launching a new task (`dispatch`)

One `tmt dispatch` = one new isolated giant task. Choose isolation deliberately:

- **Independent project** already in its own directory → `--isolation cwd`:
  ```bash
  tmt dispatch task/perf-audit --type aider --isolation cwd \
      --cwd ~/projects/perf -- 'aider .'
  ```
- **Another task in a repo already in use** → `--isolation worktree` so the new
  task gets its own branch + working tree and cannot corrupt the others:
  ```bash
  tmt dispatch task/auth-rewrite --type claude --isolation worktree \
      --repo ~/code/app --branch auth-rewrite -- 'claude'
  ```

Ask the user for the repo/dir, task name, and what to launch if not given.
Confirm the isolation choice when a repo is already backing another live task.

## Answering a prompt in a session (SAFETY-CRITICAL)

When a session is WAITING and the user asks you to respond:

1. `tmt capture SESSION --lines 40` and show the user the exact prompt.
2. Propose the precise input you would send.
3. **Get explicit approval for that specific input**, then:
   ```bash
   tmt send SESSION -- 'the approved text'   # types text, then submits Enter
   tmt key  SESSION C-c                        # for control keys
   ```
   `send` splits the text and Enter into two keystrokes with a settle delay so
   TUI agents (Claude, aider) actually submit. If a submit doesn't register in
   a slow/heavy TUI, retry with a longer delay: `TMT_SEND_DELAY=0.8 tmt send ...`.
4. Re-`capture` to confirm the prompt was accepted; report the result. If the
   text is in the input box but wasn't submitted, send Enter alone:
   `tmt key SESSION Enter`.

Hard rules until the Phase C policy+audit layer exists:
- **Never** send input without showing the prompt and getting approval for the
  exact text — no standing "just keep answering yes" authorization.
- **Never** auto-answer anything destructive or irreversible (delete, drop,
  force-push, rm, credential/password prompts). Surface it and stop.
- If a prompt is ambiguous or you are unsure what it wants, escalate to the
  user rather than guess.
- One session at a time; do not fan out sends across the fleet.

## Reboot safety

- `tmt save --filter 'task/*'` snapshots session layout (name, cwd, command).
- `tmt restore --run` recreates sessions and relaunches commands after reboot.
- Reboots kill process state — restore revives *layout*, not a running build or
  an agent's conversation. Say so plainly; don't imply work resumes mid-flight.

## Exit codes (branch on these)

`0` ok · `2` usage · `3` no such session · `4` locked · `5` policy-denied ·
`6` no tmux server · `7` timeout. On `3`, the session name is wrong or the task
ended — re-run `agent-scan` before retrying.

## Etiquette

- Prefer read-only commands (`agent-scan`, `status`, `capture`, `registry`);
  they never change anything and don't prompt.
- Report faithfully: if a task is STALE or a send didn't take, say so with the
  captured output. Don't declare a prompt answered until you re-captured proof.
