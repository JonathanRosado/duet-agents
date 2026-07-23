---
name: duet
description: Start a live psmux ensemble of Claude, Codex, and Kimi coding agents that message each other through queued delivery. Windows/PowerShell currently runs the previous leader-hub protocol; the leaderless v4 mesh ships on macOS/Linux first, with Windows parity planned next.
---

# Duet ensemble (Windows / PowerShell)

Start a named ensemble of two to five coding agents in one psmux window. You are
the initiator; each requested harness runs in its own pane (`codex-1`, `kimi-1`,
`claude-1`, …).

> **Protocol note:** the Windows runtime currently implements the previous
> leader-hub protocol, not the leaderless v4 mesh. The initiator leads; workers
> reply to the symbolic recipient `leader`; only the leader may broadcast. The
> brief that init renders into `AGENTS.md`/`CLAUDE.md` carries the authoritative
> protocol rules — follow it over anything here.

## 0. Preconditions
- Windows with [psmux](https://github.com/psmux/psmux) and PowerShell. psmux
  sets `TMUX` and `TMUX_PANE` inside its panes: if `$env:TMUX` is empty, tell
  the user to relaunch your CLI inside psmux first, then invoke duet again.
- Take the worker roster from the user's invocation: a whitespace-separated list
  of the harness words `codex`, `kimi`, `claude` (one to four workers). Reject
  options, shell syntax, or more than four words. No arguments means `codex`.
  Each requested CLI must already be installed and authenticated.

## 1. Start and pin the session
Pass the validated harness words to init (omit them for the Codex default):

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-init.ps1" codex kimi

Init infers which harness you are from the pane's foreground process and fails
closed when it cannot (a wrapper may expose `powershell` or `node` instead). In
that case rerun with an explicit flag, for example
`duet-init.ps1 -Initiator codex codex kimi`.

Init renders the ensemble brief into `AGENTS.md` and `CLAUDE.md`, launches the
worker panes, starts the delivery daemon, and waits for readiness. Report the
roster and any readiness failure to the user.

From init's session output, retain the pinned config:

    <absolute-session-directory>\duet.env

**Pin that exact session on every later command** (`-Session <dir>\duet.env`).
Never use `~\.duet\current.session` or discover the newest session directory.

## 2. Coordinate and message
You lead: decompose the goal, hand each worker a self-contained scoped task, and
integrate replies. `assignments.md` in the session dir records scopes. Send with
the body on stdin (here-string piped in PowerShell, heredoc in Git Bash):

    @'
    ...your message...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-send.ps1" codex-1 -Session "<absolute-session-directory>\duet.env"

Workers use the literal recipient `leader`; you address workers by full instance
name, or `all` to broadcast. Delivery is at-least-once: ignore a repeated message
id, reply once, then wait. Add `-Interrupt` only to urgently redirect a peer.

## 3. Diagnostics and shutdown

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-status.ps1" -Session "<absolute-session-directory>\duet.env"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-doctor.ps1" -Session "<absolute-session-directory>\duet.env"

To conclude: send one pinned `DUET-END` broadcast to `all`, then:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@DUET_PLUGIN_DIR@\scripts\duet-end.ps1" -Session "<absolute-session-directory>\duet.env"

End drains already-published messages before stopping the daemon and spawned
panes; if the drain times out, teardown is refused and the session stays
available for pinned diagnosis.
