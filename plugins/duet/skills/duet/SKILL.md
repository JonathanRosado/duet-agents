---
description: Pair this Claude with a live Codex agent in an adjacent tmux or psmux pane for real-time, bidirectional, synchronous collaboration (a "duet"). Messages are delivered inline straight into each agent's prompt (no file to read, no polling), turn-taking keeps them in sync, and either side can interrupt the other. Use when the user wants Claude and Codex to work together interactively, debate an approach, or cross-check each other.
---

# Duet: Claude + Codex, side by side

This pairs you (Claude) with a live **Codex** agent in the adjacent tmux or psmux
pane. You collaborate as peers by exchanging messages that arrive **inline** — each message is
injected directly into the recipient's prompt (bracketed paste), so nobody reads a
file or polls. Turn-taking keeps you in sync; either side can interrupt the other.

## 0. Preconditions
- You MUST be inside tmux or psmux. If `$TMUX` is empty, STOP and tell the user:
  "Relaunch me in a multiplexer first: macOS/Linux `tmux new-session claude`; Windows `psmux new-session -s duet -- claude`; then run `/duet:duet`."
- `codex` must be installed and already authenticated.

## 1. Start
On Windows, run the PowerShell script. If your shell is PowerShell:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-init.ps1"

If your shell is Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT\scripts\duet-init.ps1"

On macOS/Linux, run:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh"

This anchors the protocol in `AGENTS.md`/`CLAUDE.md` (so it survives `/clear` and
compaction), splits the window, launches Codex (which reads its brief at boot), and
starts the relay. Tell the user Codex is booting, then **send it the first message.**

Re-running init is safe: it reaps the previous session's Codex first, so you never
end up with a stale, context-less agent shadowing the current one.

## 2. The protocol
**Receiving.** A message from Codex arrives as a normal user prompt whose first line
is `[DUET from codex]`. Everything after is Codex's message — read it, act, reply.

**Sending.** To message Codex on Windows (body on stdin). If your shell is PowerShell:

    @'
    ...your message to Codex...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" codex

If your shell is Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT\scripts\duet-send.ps1" codex <<'DUET_EOF'
    ...your message to Codex...
    DUET_EOF

To message Codex on macOS/Linux:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex <<'DUET_EOF'
    ...your message to Codex...
    DUET_EOF

**After you send, END YOUR TURN and wait.** Do not keep working or narrate — Codex's
reply arrives as the next `[DUET from codex]` prompt and wakes you. One message per
reply; never send twice in a row.

**Delivery is verified.** `duet-send` confirms the message actually landed in the
peer's composer and was submitted (it retries the Enter if the first raced the paste)
before printing `duet: submitted to <peer>`. If it instead prints `SENT BUT UNVERIFIED`
and exits non-zero, the peer may **not** have received it — do NOT assume delivery.
Check with `duet-status`/`duet-doctor`, confirm the peer's pane is alive, and resend
rather than waiting forever for a reply that can't come.

**Interrupting.** To barge in while Codex is mid-task, add `-Interrupt` on
Windows or `--interrupt` on macOS/Linux:

PowerShell:

    @'
    Stop - let's reconsider: ...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" codex -Interrupt

Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT\scripts\duet-send.ps1" codex -Interrupt <<'DUET_EOF'
    Stop - let's reconsider: ...
    DUET_EOF

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex --interrupt <<'DUET_EOF'
    Stop — let's reconsider: ...
    DUET_EOF

Use it only to redirect urgently (it aborts Codex's in-flight work). The user can
also type into either pane at any time — both are theirs.

## 3. Driving the collaboration
- Send Codex the task — the user's goal, your plan, or a concrete question.
- Treat Codex as a peer: share reasoning, ask its take, let it disagree, merge the best.
- Keep the user in the loop: when Codex replies, summarize for the user before you reply back.

## 4. Ending
When done (or the user says stop):

On Windows:

PowerShell:

    @'
    DUET-END - wrapping up. Summary: ...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-send.ps1" codex
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-end.ps1"

Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT\scripts\duet-send.ps1" codex <<'DUET_EOF'
    DUET-END - wrapping up. Summary: ...
    DUET_EOF
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT\scripts\duet-end.ps1"

On macOS/Linux:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex <<'DUET_EOF'
    DUET-END — wrapping up. Summary: ...
    DUET_EOF
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-end.sh"

## Escape hatch
- Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-status.ps1"` — session state (incl. pane liveness), transcript tail, Codex pane peek.
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-status.sh"` — session state, transcript tail, Codex pane peek.
- If a peer seems unresponsive or a send reports `UNVERIFIED`, run the doctor to list
  panes and find/reap orphaned agents:
  Windows `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${env:CLAUDE_PLUGIN_ROOT}\scripts\duet-doctor.ps1"` (add `-Reap` to kill orphans);
  macOS/Linux `bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-doctor.sh"` (add `--reap`).
- Full transcript persists at `~/.duet/<timestamp>/transcript.md` on macOS/Linux and `~\.duet\<timestamp>\transcript.md` on Windows.
