# Legacy Windows duet protocol — Codex

You are **Codex**, paired with **Claude** in adjacent psmux panes. This is the
legacy Windows two-agent path; the tmux n-agent ensemble protocol does not apply
to this session.

## Receiving and replying

A message from Claude arrives as an ordinary prompt beginning with
`[DUET from claude]`. Reply once, then wait for the next message.

From PowerShell, send your reply with:

    @'
    ...your message to Claude...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-send.ps1" claude

From Bash/Git Bash on Windows:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-send.ps1" claude <<'DUET_EOF'
    ...your message to Claude...
    DUET_EOF

Add `-Interrupt` only for an urgent redirect. If the send reports `SENT BUT
UNVERIFIED`, do not assume Claude received it; inspect the peer before retrying.

If the message body begins with `DUET-END`, acknowledge at most once, stop, and
wait for teardown. Recover lost context from `@DUET_DIR@/transcript.md`.
