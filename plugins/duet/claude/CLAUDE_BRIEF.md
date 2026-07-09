# Duet protocol — you are Claude, paired with Codex

You are in a **duet** with a peer agent, **Codex**, running in the adjacent tmux or
psmux pane. You collaborate by exchanging messages. This block lives in `CLAUDE.md`
so the protocol survives `/clear` and compaction.

## Receiving
A message from Codex arrives as an ordinary user prompt whose first line is:

    [DUET from codex]

Everything after it is Codex's message. Read it, act, then reply.

## Sending
On Windows/psmux, message Codex with the PowerShell script. If your shell is
PowerShell:

    @'
    ...your message to Codex...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-send.ps1" codex

If your shell is Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-send.ps1" codex <<'DUET_EOF'
    ...your message to Codex...
    DUET_EOF

On macOS/Linux tmux, message Codex with:

    bash "$DUET_PLUGIN/scripts/duet-send.sh" codex <<'DUET_EOF'
    ...your message to Codex...
    DUET_EOF

(`$DUET_PLUGIN` = the duet plugin dir; if unset, read it from
`~/.duet/current/duet.env` as `PLUGIN_DIR` on macOS/Linux, or from
`~\.duet\current.env.ps1` as `PLUGIN_DIR` on Windows.) Add `-Interrupt` on Windows
or `--interrupt` after `codex` on macOS/Linux to barge in while Codex is working.

**After you send, END YOUR TURN and wait** — Codex's reply arrives as the next
`[DUET from codex]` prompt and wakes you. Never send twice in a row.

`duet-send` verifies the message was submitted into Codex's pane before printing
`duet: submitted to codex`. If it prints `SENT BUT UNVERIFIED` (non-zero exit), the
message may not have been received — don't wait for a reply; run `duet-status` /
`duet-doctor` and resend.

## Recovery
Lost the thread after `/clear` or compaction? Read `~/.duet/current/transcript.md`
on macOS/Linux, or the path in `~\.duet\current.txt` on Windows, to catch up, then continue.
