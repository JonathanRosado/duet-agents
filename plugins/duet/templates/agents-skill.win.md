---
name: duet
description: Start a live Windows/psmux mesh of Claude, Codex, and Kimi coding agents that message each other directly. No leader and no roles; the agent given the task coordinates by convention.
---

# Duet mesh (Windows / PowerShell)

Start two to five named coding agents in one psmux window. You are the
initiator; your roster name is your harness's bare name (`codex` or `kimi`).
Requested peers run in separate panes (`codex-1`, `kimi-1`, `claude-1`, ...).

There is **no leader and no enforced role**. Any agent may message any other
agent or broadcast to `all`. The pane the human tasked coordinates by
convention: divide the goal, hand peers scoped work, integrate replies, and
speak to the user.

## 0. Preconditions

- Windows with psmux and PowerShell. If `$env:TMUX` is empty, tell the user to
  relaunch the CLI inside psmux and invoke duet again.
- Accept one to four whitespace-separated harness words: `codex`, `kimi`, or
  `claude`. Reject options and shell syntax. No arguments means `codex`.
- Every requested CLI must already be installed and authenticated.

## 1. Start and pin

Pass the validated harness words to init:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-init.ps1" codex kimi

Init normally infers your harness. If it cannot, rerun with (for example)
`-Initiator codex`. It renders the mesh brief into `AGENTS.md` and `CLAUDE.md`,
starts the peers and one daemon, and waits for readiness.

Retain the absolute config from `duet: session <directory>`:

    <absolute-session-directory>\duet.env

Every mutation reads that exact path from `DUET_CONFIG`; diagnostics take it in
`-Session`. There is no current pointer or session-id fallback. Multiple
sessions use separate git worktrees so their instruction anchors do not collide.

## 2. Coordinate and message

Send directly to an exact roster name or broadcast to `all`. The pane already
exports the pinned environment, but set it explicitly when constructing a new
shell:

    $env:DUET_CONFIG = '<absolute-session-directory>\duet.env'
    @'
    ...your message...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-send.ps1" codex-1

Add `-Interrupt` only for an urgent redirect. `queued <id>` means the immutable
queue file is published; delivery follows asynchronously.

Messages have
`[DUET session=<sid> id=<id> from=<name> to=<name|all>]`. Delivery is
at-least-once: suppress repeated IDs, reply once to the exact `from`, then wait.
Human messages have no DUET header.

Every live message ends delivered or rejected, or its recipient is surfaced as
dead or blocked. A blocked recipient is terminal for that session.

## 3. Diagnostics

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-status.ps1" -Session "<absolute-session-directory>\duet.env"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-doctor.ps1" -Session "<absolute-session-directory>\duet.env"

## 4. End

End is immediate—no drain and no `DUET-END` ritual. Confirm required results
were delivered and no send is in flight, then:

    $env:DUET_CONFIG = '<absolute-session-directory>\duet.env'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-end.ps1"

End stops the daemon and the other spawned panes; its caller survives. A crashed
or wedged session is discarded and re-initialized, never recovered or replayed.
