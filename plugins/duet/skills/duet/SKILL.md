---
name: duet
description: Start and lead a live tmux ensemble of Claude, Codex, and Kimi agents. Use when the user wants multiple coding agents to collaborate interactively, divide disjoint implementation scopes, debate an approach, or cross-check one another. Messages are queued and injected into each agent's prompt while a watchdog provides fenced leader failover.
argument-hint: "[codex|kimi|claude ...]"
---

# Duet ensemble

Start a named ensemble of two to five agents in one tmux window. You are the
initiator, roster name `claude`, and term-0 leader. Each requested harness runs
as a worker in another pane (`codex-1`, `kimi-1`, `claude-1`, and so on).

The topology is a leader hub: the leader may talk to every worker, while each
worker talks only to the symbolic recipient `leader`. Do not ask workers to
message one another.

## 0. Preconditions and platform scope

- Determine the host platform first. On Windows, use only the legacy psmux
  path below; if Claude is not already inside psmux, tell the user to relaunch
  with `psmux new-session -s duet -- claude`.
- On macOS/Linux, the v0.2 ensemble path requires Bash and tmux. If `$TMUX` is
  empty, stop and tell the user to relaunch with `tmux new-session claude`, then
  run `/duet:duet` again.
- Validate every harness argument before starting. Supported values are
  `codex`, `kimi`, and `claude`; the user may request one to four workers.
  Each requested CLI must already be installed and authenticated.
- `/duet:duet` with no arguments defaults to one Codex worker. Examples:
  `/duet:duet codex kimi` creates three agents total, while
  `/duet:duet codex codex kimi` creates four.

The invocation arguments are: $ARGUMENTS

Treat them only as a whitespace-separated list of the three supported harness
words. Reject options, shell syntax, or more than four words; do not interpolate
unvalidated argument text into a shell command. An empty list means `codex`.

### Windows/psmux legacy path

The PowerShell scripts are intentionally unchanged in v0.2. On Windows they
continue to provide the prior two-agent Claude+Codex behavior only:

From PowerShell:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-init.ps1"

From Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT\scripts\duet-init.ps1"

Do not pass roster arguments or promise queues, leadership terms, failover, or
session fencing on that path. Follow the two-agent brief produced by the
PowerShell script. The remaining sections describe only the tmux/Bash ensemble.

## 1. Start and pin the session

Pass the validated harness words from the skill invocation to init. With no
words, omit them so init applies its Codex default:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh" codex kimi

Init writes the role-neutral protocol into `AGENTS.md` and `CLAUDE.md`, launches
the workers, starts the delivery daemon, and waits for every worker's readiness
marker. Report the roster and any readiness failure to the user.

Find the `duet: session <absolute-directory>` line in init's output and
immediately retain that session's immutable config path:

    /absolute/session/directory/duet.env

Every later agent command must pin that exact session, either with
`DUET_CONFIG=/absolute/session/directory/duet.env` or `--session` with that
path. Never use `~/.duet/current`, infer the latest directory, or omit the pin.
`current` is only a human/status convenience and another workdir may repoint it.

Re-running init replaces only the active predecessor for the same canonical
workdir. Sessions in other workdirs remain independent.

## 2. Lead through the hub

Read the pinned session's `leader` file before assigning work. It records the
current term and leader. While it names you:

1. Decompose the goal into disjoint file or subsystem scopes. Record owner,
   scope, state, and relevant term in `assignments.md` before dispatching.
2. Keep at most one outstanding task per worker. You may fan out one task to
   each worker and integrate replies asynchronously as they arrive.
3. Send each worker a self-contained task with acceptance criteria. If scopes
   collide, revise the assignment; workers are instructed to report conflicts
   rather than edit outside their scope.
4. Review and integrate worker results, maintain `assignments.md`, and remain
   the single agent speaking to the user for the ensemble.

Send to a named worker with the pinned config (body on stdin):

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex-1 <<'DUET_EOF'
    ...one scoped assignment or reply...
    DUET_EOF

Only the current leader may broadcast:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" all <<'DUET_EOF'
    ...message for every other roster member...
    DUET_EOF

`duet-send` prints one `duet: queued <message-id> for <recipient>` line per
recipient accepted. A broadcast therefore prints several lines. These confirm
durable enqueue, not prompt submission; the daemon owns injection and retries.

## 3. Message discipline and delivery model

Messages arrive as ordinary prompts with a header like:

    [DUET session=<session-id> id=<message-id> term=<term> from=<sender>]

Treat the stable message ID as the logical message identity. Delivery is
at-least-once across uncertain TUI submission and daemon restart: if an ID
appears again, do not repeat work, side effects, or a reply already sent for
that ID. Mention a suppressed duplicate in the next otherwise-required report
when useful.

Keep one in-flight exchange per leader-worker edge: after assigning a worker,
do not send that same worker a second task until it replies or the first task is
explicitly superseded. Other worker edges remain independent.

To urgently redirect a worker, add `--interrupt`:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex-1 --interrupt <<'DUET_EOF'
    Stop current work and follow this revised scope: ...
    DUET_EOF

Interrupts have queue priority and supersede older undeliverable normal work;
use them only for a genuine redirect.

Workers always reply to `leader`, never a concrete leader name. The symbolic
queue resolves at delivery time, so a pending reply follows a promotion:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" leader <<'DUET_EOF'
    ...worker result...
    DUET_EOF

The transcript records enqueue intent in serialized queue order. A transcript
entry can survive even when its payload never reaches a prompt, so the entry
alone is not proof that the recipient acted. Do not blindly re-enqueue a
message when delivery is uncertain; inspect the pinned session first.

## 4. Promotion and recovery

The delivery daemon watches the current leader. It advances the leadership
term after the leader pane dies or after three consecutive verified-delivery
failures to it. The failed incumbent becomes ineligible for automatic
succession; the next-ranked live eligible roster member is promoted. The new
leader's promotion notice is delivered before its ordinary traffic, and the
other live agents receive a leadership-change notice.

On a promotion:

- If you are the new leader, read `leader`, `transcript.md`, and
  `assignments.md`; reconcile each outstanding assignment before dispatching
  more work, preserve disjoint scopes, and take over user-facing coordination.
- If another agent was promoted, stop assigning immediately, accept the worker
  role, and send future replies only to `leader`.
- If a former leader's pane recovers, it remains a worker. It must not resume
  old-term assignments or leadership on its own.

The current leader may request a fenced manual promotion, optionally naming an
eligible successor:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-promote.sh" --to codex-1

Use `duet-promote.sh`; direct edits to the `leader` file bypass term and
composer fencing and are an unsafe emergency-only recovery action. If no live
eligible successor exists, leadership becomes `NONE`; report it to the user
and use pinned diagnostics rather than assigning more work.

Manual promotion is a permanent handoff for that session: the old incumbent is
added to `failed-leaders` and cannot be promoted back automatically or with
`--force`.

If context is compacted or lost, recover from the same three pinned files:
`leader`, `transcript.md`, and `assignments.md`. Re-establish the current term,
your role, completed message IDs, and outstanding scopes before acting.

## 5. Diagnostics

Always diagnose the exact pinned session:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-status.sh" \
      --session "/absolute/session/directory/duet.env"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-doctor.sh" \
      --session "/absolute/session/directory/duet.env"

Status shows roster readiness, pane liveness, leader/term, inbox depth, and the
daemon. Doctor validates session invariants. Never substitute the ambient
`current` link in agent-driven recovery.

## 6. End cleanly

When the work is done or the user says stop, the current leader first enqueues
one `DUET-END` broadcast, then ends the same pinned session:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" all <<'DUET_EOF'
    DUET-END — wrapping up. Final state and handoff: ...
    DUET_EOF
    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-end.sh"

End closes admission and waits for all messages already queued, including the
final broadcast, before stopping the daemon, removing protocol anchors, and
killing only spawned worker panes. If the bounded drain times out, teardown is
refused and the session is left running for pinned diagnosis; do not claim it
ended.
