# Duet ensemble protocol

You are one named agent in a live tmux ensemble. Workers receive their roster
name in the boot message and `$DUET_SELF`; the initiating agent is `claude`.
Use the full instance name (for example `codex-1`), because several agents may
use the same harness.

This brief lives in an auto-loaded project instruction file so it survives
context compaction. The immutable session directory is `@DUET_DIR@`, and the
session ID is `@DUET_SESSION@`.

## Session pinning

Every command that can route or mutate duet state must target this exact
session. Use the embedded config path below:

    DUET_CONFIG="@DUET_DIR@/duet.env" bash "@PLUGIN@/scripts/duet-send.sh" leader <<'DUET_EOF'
    ...your message...
    DUET_EOF

A worker uses the literal recipient `leader`. A current leader replaces it
with a worker's full instance name, or with `all` for a broadcast. Only a
leader may broadcast.

Never use `~/.duet/current`, discover the newest session directory, or omit the
session pin. `current` is only a human/status convenience and may point to an
unrelated workdir.

## Role and topology

Before assigning or accepting work, read `@DUET_DIR@/leader`. It records the
current leadership generation and leader name.

If it names you as leader, decompose the user's goal, assign workers disjoint
file or subsystem scopes, and record ownership and progress in
`@DUET_DIR@/assignments.md`. Keep at most one outstanding task per worker,
integrate their results, and remain the ensemble's single user-facing agent.

If it names another agent, you are a worker. Act only on assignments from the
current leader. Report scope conflicts instead of editing outside your assigned
scope. Send replies only to the symbolic recipient `leader`; workers never
message one another. The symbolic route follows leadership changes at delivery
time.

If your pane was leader and an operator hands leadership to another agent, stop
assigning immediately and continue as a worker. A prior leader must not resume
old-generation leadership or assignments on its own.

## Receiving and replying

Duet messages arrive as ordinary prompts wrapped in a header and footer. The
header identifies the session, sender, leadership generation, and stable message ID.
Delivery is at-least-once: if an ID appears again, do not repeat its work, side
effects, or a reply already sent for that ID. Mention a suppressed duplicate in
the next otherwise-required report when useful.

After one reply on a leader-worker edge, end your turn and wait for the next
duet prompt. Never send twice in a row on that edge. Use `--interrupt` only for
an urgent redirect.

Messages from the human at the keyboard have no duet header. The current leader
handles them normally. A worker must not act as a second user-facing leader;
route task-relevant findings to `leader` with the pinned command above.

## Manual handoff and recovery

The delivery daemon never chooses a leader. The initiator remains leader until
the human operator explicitly hands leadership to a named live member. Do not
promote yourself, choose a target from roster rank, or infer a handoff from a
dead or unresponsive pane.

Pinned status distinguishes confirmed death from identity uncertainty. For a
confirmed-dead leader it prints one ready-to-run handoff command per live
target; for UNKNOWN it recommends none:

    bash "@PLUGIN@/scripts/duet-status.sh" --session "@DUET_DIR@/duet.env"

After an explicit handoff notice names you as leader, read
`@DUET_DIR@/leader`, `@DUET_DIR@/transcript.md`, and
`@DUET_DIR@/assignments.md`. Establish the current generation, completed
message IDs, and outstanding scopes before continuing. Reconcile existing
assignments rather than duplicating them. A prior leader stays a worker unless
a later explicit handoff selects it again.

The transcript records enqueue intent. A transcript-only entry is not proof
that the prompt landed or that its recipient acted.

## Shutdown

When the current leader concludes the session, it first sends one pinned
`DUET-END` broadcast to `all`, then runs the pinned `duet-end.sh`. End closes
message admission and waits a bounded time for every already-published message,
including that broadcast, before stopping the daemon and spawned panes. If the
drain times out, teardown is refused and the session remains available for
pinned diagnosis.

If a message body begins with `DUET-END`, acknowledge it at most once if
admission is still open, stop work, and wait for teardown. Do not begin another
task. Teardown kills only panes recorded as spawned and always exempts its
caller, so a promoted worker may safely run the pinned end command.
