---
name: duet
description: Start a live tmux or Windows/psmux mesh of Claude, Codex, and Kimi coding agents that message each other directly. No leader and no roles; the agent given the task coordinates by convention.
argument-hint: "[codex|kimi|claude ...]"
---

# Duet mesh

Start two to five named coding agents in one terminal-multiplexer window. You
are the initiator (`claude`); requested peers use instance names such as
`codex-1`, `kimi-1`, and `claude-1`.

There is **no leader and no enforced role**. Any agent may message any other
agent or broadcast to `all`. You coordinate by convention because the human
gave you the task: divide the goal, hand peers scoped work, integrate replies,
and speak to the user.

## 0. Validate the invocation

The invocation arguments are: $ARGUMENTS

Treat them only as one to four whitespace-separated words from `codex`, `kimi`,
and `claude`. Reject options and shell syntax. An empty list means `codex`.
Every requested CLI must already be installed and authenticated.

Use the Windows path when running on Windows/PowerShell with psmux; otherwise
use Bash/tmux. If the matching `TMUX`/`TMUX_PANE` environment is absent, tell
the user to relaunch Claude inside the appropriate multiplexer and invoke duet
again.

## 1. Start and pin

macOS/Linux:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh" codex kimi

Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-init.ps1" codex kimi

Init renders the mesh brief into `AGENTS.md` and `CLAUDE.md`, launches peers,
starts one delivery daemon, and waits for readiness. Report any readiness
failure.

Retain the absolute config from `duet: session <directory>`. Every mutation
reads that exact file from `DUET_CONFIG`; diagnostics take it explicitly.
There is no current-pointer or session-id fallback. Concurrent sessions use
separate git worktrees so their instruction anchors do not collide.

## 2. Coordinate and message

Use exact roster names. Send directly to one peer or broadcast to `all`, which
skips the sender and any dead or blocked member.

macOS/Linux:

    DUET_CONFIG="/absolute/session/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex-1 <<'DUET_EOF'
    ...your message...
    DUET_EOF

Windows PowerShell:

    $env:DUET_CONFIG = 'C:\absolute\session\duet.env'
    @'
    ...your message...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-send.ps1" codex-1

Add `--interrupt` (Bash) or `-Interrupt` (PowerShell) only for an urgent
redirect. `queued <id>` means the immutable queue file was published; the
daemon delivers it asynchronously.

Messages arrive with
`[DUET session=<sid> id=<id> from=<name> to=<name|all>]`. Delivery is
at-least-once: suppress repeated IDs, reply once to the exact `from`, then wait.
Human messages have no DUET header.

In a live session every message becomes delivered or rejected, or its recipient
is surfaced as dead or blocked. A blocked recipient is terminal; re-init.

## 3. Diagnostics

macOS/Linux:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-status.sh" --session "/absolute/session/duet.env"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-doctor.sh" --session "/absolute/session/duet.env"

Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-status.ps1" -Session "C:\absolute\session\duet.env"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-doctor.ps1" -Session "C:\absolute\session\duet.env"

## 4. End

End is immediate—no drain and no `DUET-END` ritual. First ensure no send is in
flight and required results were delivered.

macOS/Linux:

    DUET_CONFIG="/absolute/session/duet.env" \
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-end.sh"

Windows:

    $env:DUET_CONFIG = 'C:\absolute\session\duet.env'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-end.ps1"

End stops the daemon and other spawned panes; its caller survives. A crashed or
wedged session is discarded and re-initialized, never recovered or replayed.
