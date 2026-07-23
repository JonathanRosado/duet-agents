---
name: duet
description: Start a live tmux mesh of Claude, Codex, and Kimi coding agents that message each other directly to collaborate — divide work, debate an approach, or cross-check. No leader and no roles; the agent the task was given to coordinates by convention. macOS/Linux (tmux); Windows uses the .ps1 runtime.
---

# Duet mesh

Start a named ensemble of two to five coding agents in one tmux window. You are
the initiator; your roster name is your harness's bare name (`codex` or `kimi`).
Each requested harness runs in its own pane (`codex-1`, `kimi-1`, `claude-1`, …).

**There is no leader and no roles.** Any agent may message any other agent, in any
direction, or broadcast to `all`. You — the pane the human gave the task to —
coordinate by convention: decompose the goal, hand peers scoped tasks, integrate
their replies, and speak for the ensemble to the user. That is a social role, not
an enforced one; a peer may message you or any other peer at any time.

## 0. Preconditions
- **macOS/Linux** (Bash + tmux). If `$TMUX` is empty, tell the user to relaunch
  your CLI inside tmux (for example `tmux new-session codex` or
  `tmux new-session kimi`), then invoke duet again.
- Take the worker roster from the user's invocation: a whitespace-separated list
  of the harness words `codex`, `kimi`, `claude` (one to four workers). Reject
  options, shell syntax, or more than four words; do not interpolate unvalidated
  argument text into a shell command. No arguments means `codex`. Each requested
  CLI must already be installed and authenticated.
- Examples: no arguments = you + one Codex worker; `codex kimi` = three agents
  total; `codex codex kimi` = four.

## 1. Start and pin the session
Pass the validated harness words to init (omit them for the Codex default):

    bash "@DUET_PLUGIN_DIR@/scripts/duet-init.sh" codex kimi

Init infers which harness you are from the pane's foreground process. If it
reports it cannot infer the invoking harness, rerun with an explicit flag, for
example `duet-init.sh --initiator codex codex kimi`.

Init renders the mesh brief into `AGENTS.md` and `CLAUDE.md`, launches the worker
panes, starts the one delivery daemon, and waits for every worker's readiness
marker. Report the roster and any readiness failure to the user.

From init's `duet: session <absolute-directory>` line, retain the pinned config:

    /absolute/session/directory/duet.env

**Pin that exact session on every later command** — `DUET_CONFIG=<dir>/duet.env`
or `--session <dir>/duet.env`. There is no `~/.duet/current` fallback; an absolute
pin is required and unpinned commands error. Multiple sessions can run
concurrently in one repo, each in its own git worktree (distinct anchor files).

## 2. Coordinate (no hub)
You drive by convention, not authority. Decompose the goal into scopes, hand each
peer a self-contained task, and integrate replies as they arrive. `assignments.md`
in the session dir is an optional shared scratchpad. Peers may also talk to each
other directly — you are not a required relay.

## 3. Send and receive
Send to one peer by its exact roster name, or `all` to broadcast (fans out to
every other live, deliverable member — never yourself; dead or blocked peers are
skipped). Body on stdin:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "@DUET_PLUGIN_DIR@/scripts/duet-send.sh" codex-1 <<'DUET_EOF'
    ...your message...
    DUET_EOF

`duet-send` prints `queued <id>` — the queue file is published (not yet
delivered); the daemon then injects it into the recipient's pane. To urgently
redirect a peer, add `--interrupt`.

Messages arrive as ordinary prompts headed
`[DUET session=<sid> id=<id> from=<name> to=<name|all>]`. Delivery is
**at-least-once**: a repeated `id` is a duplicate — do not redo its work or resend
a reply you already sent. Reply to the exact `from`; reply once to what you
receive and then wait for the next message (do not send a peer a second message
before it has replied, and do not spam). Human messages have no `[DUET …]` header.

In a live session every message is archived *delivered* (or *rejected*, if its
envelope is malformed), or its recipient is surfaced as **dead** or **blocked**
and its queued head is no longer attempted — never silent limbo. A blocked
recipient is terminal (re-init to recover it). If a peer seems unresponsive,
check `duet-status.sh`.

## 4. Diagnostics
Always pass the explicit session:

    bash "@DUET_PLUGIN_DIR@/scripts/duet-status.sh" --session "/absolute/session/directory/duet.env"
    bash "@DUET_PLUGIN_DIR@/scripts/duet-doctor.sh"  --session "/absolute/session/directory/duet.env"

Status shows the pinned session id, daemon liveness, each roster pane / harness /
readiness, per-recipient queue depth, and any dead or blocked recipients.

## 5. End
Ending is **immediate** — it stops the daemon and kills the *other* spawned panes
(the caller's own pane survives). There is **no drain and no `DUET-END` ritual**.
Because there is no drain, before you end: make sure no send is in flight and that
any result you need has actually been delivered, then:

    DUET_CONFIG="/absolute/session/directory/duet.env" \
      bash "@DUET_PLUGIN_DIR@/scripts/duet-end.sh"

A crashed or wedged session is discarded, not recovered — just re-init if needed.
