---
name: duet
description: Start and lead a live tmux or psmux ensemble of Claude, Codex, and Kimi agents. Use when the user wants multiple coding agents to collaborate interactively, divide disjoint implementation scopes, debate an approach, or cross-check one another. Messages use fenced queues; leadership remains with the initiator until an operator explicitly hands it to a named member.
argument-hint: "[codex|kimi|claude ...]"
---

# Duet ensemble

Start a named ensemble of two to five agents in one tmux or psmux window. You are the
initiator, roster name `claude`, and generation-0 leader. Each requested harness runs
as a worker in another pane (`codex-1`, `kimi-1`, `claude-1`, and so on).

The topology is a leader hub: the leader may talk to every worker, while each
worker talks only to the symbolic recipient `leader`. Do not ask workers to
message one another.

## 0. Preconditions and platform scope

- Determine the host platform first. On Windows, use PowerShell and psmux. If
  Claude is not already inside psmux, tell the user to relaunch with
  `psmux new-session -s duet -- claude`.
- On macOS/Linux, the v0.3 ensemble path requires Bash and tmux. If `$TMUX` is
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

## 1. Start and pin the session

Pass the validated harness words from the skill invocation to init. With no
words, omit them so init applies its Codex default:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh" codex kimi

On Windows, pass the same validated roster to the PowerShell init:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-init.ps1"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-init.ps1" codex kimi

Init writes the role-neutral protocol into `AGENTS.md` and `CLAUDE.md`, launches
the workers, starts the delivery daemon, and waits for every worker's readiness
marker. Report the roster and any readiness failure to the user.

Find the `duet: session <absolute-directory>` line in init's output and
immediately retain that session's immutable config path:

    /absolute/session/directory/duet.env

Every later agent command must pin that exact session, either with
`DUET_CONFIG=/absolute/session/directory/duet.env`, `--session` on Bash, or
`-Session` on PowerShell. Do not infer the latest directory or omit the pin.
The `current` entry only helps a human inspect a session; another workdir may
repoint it.

Re-running init replaces only the active predecessor for the same canonical
workdir. Sessions in other workdirs remain independent.

## 2. Lead through the hub

Read the pinned session's `leader` file before assigning work. It records the
current generation and leader. While it names you:

1. Decompose the goal into disjoint file or subsystem scopes. Record owner,
   scope, state, and relevant generation in `assignments.md` before dispatching.
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

PowerShell/psmux:

    @'
    ...one scoped assignment or reply...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" codex-1 -Session "C:\absolute\session\directory\duet.env"

Kimi and some Claude tool sessions on Windows run Bash or Git Bash. In those
shells, keep the PowerShell transport but replace the here-string with a Bash
heredoc (the generated session brief includes absolute, ready-to-use forms):

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" codex-1 -Session 'C:\absolute\session\directory\duet.env' <<'DUET_EOF'
    ...one scoped assignment or reply...
    DUET_EOF

The same translation applies to the later Windows broadcast, interrupt, reply,
and `DUET-END` examples; PowerShell switches such as `-Interrupt` are unchanged.

Only the current leader may broadcast:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" all <<'DUET_EOF'
    ...message for every other roster member...
    DUET_EOF

PowerShell/psmux:

    @'
    ...message for every other roster member...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" all -Session "C:\absolute\session\directory\duet.env"

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

PowerShell/psmux uses `-Interrupt`:

    @'
    Stop current work and follow this revised scope: ...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" codex-1 -Interrupt -Session "C:\absolute\session\directory\duet.env"

Interrupts have queue priority and supersede older undeliverable normal work;
use them only for a genuine redirect.

Workers always reply to `leader`, never a concrete leader name. The symbolic
queue resolves at delivery time, so a pending reply follows a manual handoff:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" leader <<'DUET_EOF'
    ...worker result...
    DUET_EOF

PowerShell/psmux:

    @'
    ...worker result...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" leader -Session "C:\absolute\session\directory\duet.env"

The transcript records enqueue intent in serialized queue order. A transcript
entry can survive even when its payload never reaches a prompt, so the entry
alone is not proof that the recipient acted. Do not blindly re-enqueue a
message when delivery is uncertain; inspect the pinned session first.

## 4. Manual leadership and recovery

The daemon never elects a leader. The initiator remains leader until the user
or another human operator explicitly chooses a live target. Do not infer a
handoff from pane death, delivery failure, roster rank, or apparent inactivity.

If the leader looks dead or wedged, run pinned status. A confirmed-dead result
prints one complete handoff command for each confirmed-live target. An UNKNOWN
result means the pane identity could not be proved; report that uncertainty and
do not recommend a target. Wait for the user to choose. The user may also hand
off a leader that is alive but unresponsive.

Every handoff requires `--to` or `-To`:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-promote.sh" --to codex-1 \
      --session "/absolute/session/directory/duet.env"

PowerShell/psmux:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-promote.ps1" -To codex-1 -Session "C:\absolute\session\directory\duet.env"

Any surviving session member may run the command after the operator names the
target. A shell outside the roster must pass an explicit session path. A caller
known to belong to another session is rejected.

The handoff transaction increments the generation, records the exact prior
leader and operator-selected target, and queues the new leader's notice before
ordinary delivery resumes. It refuses to advance while a composer has an
uncertain delivery obligation. Let the daemon finish that recovery, then retry;
there is no force bypass. If the process crashes mid-transaction, the daemon may
finish only that recorded target and generation. It never chooses a substitute.

After a handoff:

- If you are the new leader, read `leader`, `transcript.md`, and
  `assignments.md`; reconcile outstanding work before assigning more.
- If another member now leads, stop assigning, accept the worker role, and
  send future replies only to `leader`.
- A recovered prior leader remains a worker unless another explicit handoff
  selects it. Prior leaders are not permanently excluded.

Use `duet-promote`; editing `leader` directly bypasses the generation CAS,
composer fence, durable intent, and notices.

If context is compacted or lost, recover from the same three pinned files:
`leader`, `transcript.md`, and `assignments.md`. Re-establish the current generation,
your role, completed message IDs, and outstanding scopes before acting.

## 5. Diagnostics

Always diagnose the exact pinned session:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-status.sh" \
      --session "/absolute/session/directory/duet.env"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-doctor.sh" \
      --session "/absolute/session/directory/duet.env"

PowerShell/psmux:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-status.ps1" -Session "C:\absolute\session\directory\duet.env"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-doctor.ps1" -Session "C:\absolute\session\directory\duet.env"

Status shows roster readiness, tri-state pane liveness, leader generation,
inbox depth, and the daemon. For a confirmed-dead leader it prints pinned
manual-handoff commands; for UNKNOWN it does not recommend a target. Doctor
validates session invariants. Never substitute the ambient
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

PowerShell/psmux:

    @'
    DUET-END. Final state and handoff: ...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" all -Session "C:\absolute\session\directory\duet.env"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-end.ps1" -Session "C:\absolute\session\directory\duet.env"

End closes admission and waits for all messages already queued, including the
final broadcast, before stopping the daemon, removing protocol anchors, and
killing only spawned worker panes. If the bounded drain times out, teardown is
refused and the session is left running for pinned diagnosis; do not claim it
ended.
