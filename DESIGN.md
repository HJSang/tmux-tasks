# tmux-tasks: orchestrated multi-agent design (v0.3+)

Status: **draft for review** — no code written against this yet. Current shipped
version is v0.2.0 (monitor + save/restore). This document defines how `tmt`
evolves into a supervisor for many long-lived, isolated agent tasks driven by a
Claude Code orchestrator.

## 1. The two-tier model

There are two fundamentally different kinds of parallelism, and they live at
different layers:

```
Claude Code orchestrator  (a "supervisor" — one session running the tmt-orchestrate skill)
│
├── tmt session  task/auth-rewrite     ← GIANT TASK A: one top-level Claude agent
│                                          worktree: ../wt/auth-rewrite (branch auth-rewrite)
│      └── native subagents (ephemeral, shared context) ── INVISIBLE to tmt
│
├── tmt session  task/data-migration   ← GIANT TASK B: one top-level Claude agent
│                                          worktree: ../wt/data-migration
│      └── native subagents …
│
└── tmt session  task/perf-audit       ← GIANT TASK C: aider / build loop / shell
                                           cwd: ~/projects/perf (independent project)
```

- **Within one giant task** → ephemeral, shared-context fan-out. Owned by
  **native Claude subagents**. They die with the task. tmux adds nothing here
  and `tmt` must never reach inside.
- **Across giant tasks** → long-lived, independent, isolated, reboot-surviving.
  Owned by **`tmt`**. One tmux session = one giant task = one top-level agent.

The unit `tmt` manages is the **whole giant task**, which is inherently
long-lived — so `tmt` is *always* the right layer at this level. There is no
"tmux vs native" decision to make: tmux for the fleet, native inside each task.

## 2. Roles

| Component | Responsibility | Has judgment? |
|---|---|---|
| `tmt` (bash) | Mechanical primitives: dispatch, send, ask/await, readiness detection, registry, locking, audit, save/restore. Deterministic, testable. | No |
| `tmt-orchestrate` (Claude skill) | The poll loop, which prompts are safe to auto-answer, when to escalate to the human, how to phrase replies, task assignment. | Yes |
| Each giant-task agent | Does its own work, including its own native subagent fan-out. | Yes (its own) |
| Human | Approves escalations, sets policy, defines tasks. | Final authority |

Judgment lives in the skill, not in bash. `tmt` stays a stable Unix tool.

The orchestrator is a **supervisor, not a team lead**: it does not decompose
work across the fleet (each giant task decomposes its own). It launches tasks,
checks on them, answers or escalates prompts, and restores after reboot.

## 3. Isolation (per-task)

Two modes, chosen per task at dispatch, recorded in the registry so restore
rebuilds the right one:

- **`worktree`** — for multiple giant tasks in the **same repo**. `tmt dispatch`
  runs `git worktree add <path> -b <branch>`, sets the session cwd to it. Tasks
  are physically isolated on disk and on separate branches; they cannot corrupt
  each other's working tree. Mirrors Claude Code's native `isolation: "worktree"`.
- **`cwd`** — for **independent projects** already in separate directories. The
  session cwd is that directory; no git worktree is created.

Registry records `isolation`, `worktree_path`/`cwd`, and `branch` so
`tmt restore` recreates the binding (re-adding the worktree if absent).

## 4. Command surface (proposed)

Existing (v0.2): `watch ls status capture send key new save restore snapshots
agent-scan attach version`.

New for orchestration:

```
tmt dispatch NAME --type TYPE [--isolation worktree|cwd] [--repo DIR]
             [--branch B] [--cwd DIR] -- "opening prompt / command"
    Create session + set up isolation + register + launch agent/command +
    send opening prompt. One call = one new giant task.

tmt ask SESSION [--timeout S] [--quiescent S] -- "prompt"
    Send prompt, block until the pane is quiescent AND the session's
    ready-pattern reappears, return ONLY the new output region (JSON).
    The request/response primitive for talking to a task's top-level agent.

tmt registry [SESSION]          Show session metadata (type, task, isolation, ...).
tmt reply SESSION -- "text"     Policy-checked send (auto-answer path).
tmt audit [--session S] [--tail N]   Show the append-only send log.
```

## 5. Agent-consumable I/O (prerequisite)

Today's output targets human eyeballs. For a program consumer:

- **Strip ANSI when stdout is not a TTY** (`[[ -t 1 ]]`), keep colors for humans.
- **`--json` on every scriptable command**, with a stable schema.
- **Stable exit codes**: `0` ok · `2` usage · `3` no such session · `4` session
  locked · `5` policy-denied · `6` no tmux server · `7` timeout.

Everything else depends on this; it ships first.

## 6. Agent-turn readiness detection

The v0.2 WAITING/IDLE heuristic keys on **shell** prompts — useless for "did the
Claude agent finish its turn." Add **per-type ready-patterns** in the registry:

- `claude` — its prompt glyph / the "esc to interrupt" indicator disappearing.
- `aider` — the `>` prompt returning.
- `shell` — existing behavior.
- `build` — process exit (fg returns to shell).

`tmt ask` polls until: output hash stable for `--quiescent` seconds **and** the
ready-pattern matches the tail. Falls back to `--timeout` with exit `7`.

## 7. Safety layer (gates autonomy — built before auto-response turns on)

"Auto-respond with policy + audit" is the highest-risk feature. It does not turn
on until all three exist:

1. **Per-session lock** — a lockfile per session; no two sends race into one
   pane. `tmt reply/ask` acquire it; contention → exit `4`.
2. **Policy file** (`~/.config/tmux-tasks/policy.yaml` or `.conf`):
   - `auto_allow`: patterns the orchestrator MAY auto-answer (re-prompts,
     `Continue?`, trusted `[y/N]` on known-safe operations).
   - `always_escalate`: patterns that ALWAYS go to the human — destructive verbs
     (delete/drop/rm/force-push/terminate), credential/password prompts.
   - **Default-deny**: any prompt matching neither → escalate to human. Unknown
     is never auto-answered.
3. **Append-only audit log** (`~/.local/share/tmux-tasks/audit.log`): every send
   records timestamp, session, input, authorizer (`policy:<rule>` or `human`),
   and the pane context that triggered it. Non-negotiable accountability trail.

The skill enforces escalation; `tmt` enforces lock + audit + default-deny
mechanically so a skill bug cannot silently auto-answer an unknown prompt.

## 8. Reboot survival (extends v0.2 save/restore)

Snapshots additionally persist registry metadata (type, isolation, worktree,
branch, task, ready-pattern). `tmt restore --run`:
1. Recreates each session; for `worktree` tasks, re-adds the git worktree if the
   path is missing.
2. Re-launches the agent/command.
3. Does **not** replay conversation history — a reboot kills process state; the
   agent restarts fresh in its worktree. (Honest limitation, documented.)

Audit log and policy are already on persistent disk, unaffected by reboot.

## 9. Phasing (each independently shippable + tested)

- **Phase A** — §5 I/O + §3/§4 registry & `dispatch` (cwd + worktree isolation).
  Low risk. Unblocks the orchestrator as a *reader* and task *launcher*.
- **Phase B** — §6 readiness detection + `tmt ask`. The talk-to-agents core.
- **Phase C** — §7 lock + policy + audit, then the `reply` auto-answer path.
  Autonomy turns on ONLY after this. 
- **Phase D** — the `tmt-orchestrate` Claude skill: poll loop, escalation logic,
  task assignment, reboot recovery. Judgment layer.

Ship A→B→C→D so autonomy is impossible before locking and audit exist.

## 10. Explicit non-goals

- Reaching inside a giant task's native subagent fan-out.
- Decomposing/scheduling work across tasks (each task owns its decomposition).
- Reviving process memory across reboot (impossible; we recreate + relaunch).
- Multi-pane split-layout revival (session-level restore only).
- Competing with native Claude subagents for ephemeral, same-context fan-out.

## 11. Open questions

- Policy format: YAML (needs a parser dep) vs. simple line-based `.conf` (pure
  bash, no dep)? Leaning `.conf` to keep `tmt` dependency-light.
- Ready-pattern for Claude sessions: detect via the pane glyph, or have the
  orchestrator inject a sentinel echo after each turn? Sentinel is more robust
  but requires cooperation from the launched agent.
- Should `dispatch` support a pending-task **queue** (assign backlog to freed
  sessions), or is one-task-per-explicit-dispatch enough for now?
