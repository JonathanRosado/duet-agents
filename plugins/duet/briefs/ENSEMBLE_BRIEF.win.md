# Duet mesh

You are one named agent in a live Windows/psmux mesh of coding agents. If you
started the session you are `@INITIATOR@`; a spawned peer's name is in its boot
message and `$env:DUET_SELF` (for example `codex-1`, `kimi-1`). Use the full
name—several agents may share a harness. Peers are listed in
`@DUET_DIR@\roster.tsv` (name, harness, pane, pid, rank, spawned).

There is **no leader and no roles**. Whoever the human handed the task to
coordinates by convention, not by authority. Any agent may message any other
agent, in any direction, or broadcast to all.

This brief is rendered into an auto-loaded instruction file so it survives
context compaction. Session dir: `@DUET_DIR@`. Session id: `@DUET_SESSION@`.

## Send a message

Pin this exact session through `DUET_CONFIG` on every mutation. Your pane already
exports it; never replace it with a current pointer, directory scan, or session
id. Body goes on stdin.

PowerShell:

    $env:DUET_CONFIG = '@DUET_DIR@\duet.env'
    @'
    ...your message...
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-send.ps1" <name|all>

Bash or Git Bash:

    DUET_CONFIG='@DUET_DIR@\duet.env' powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-send.ps1" <name|all> <<'DUET_EOF'
    ...your message...
    DUET_EOF

`<name>` is an exact roster name; `all` broadcasts to every other live,
deliverable member (never yourself; dead and blocked peers are skipped). Add
`-Interrupt` only to urgently redirect a peer. `duet-send` prints `queued <id>`:
the file is published, then the daemon injects it. A send racing immediate end
is the documented exception to this guarantee.

## Receive and reply

Messages arrive as ordinary prompts headed
`[DUET session=<id> id=<id> from=<name> to=<name|all>]`. Delivery is
**at-least-once**: if the same `id` arrives again, do not redo its work or resend
a reply already sent for it. Reply to the exact `from`, then wait. Do not spam.
Human messages have no `[DUET ...]` header; handle them normally.

## No recovery

A crashed or wedged session is discarded, not repaired. A dead peer stops
receiving, but the mesh continues for everyone else. There is no leadership
takeover, promotion, daemon restart, or replay. A message that repeatedly cannot
land marks only that recipient *blocked*; re-init to recover that peer.

## Diagnostics

Diagnostics require the explicit absolute config:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-status.ps1" -Session "@DUET_DIR@\duet.env"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-doctor.ps1" -Session "@DUET_DIR@\duet.env"

## Ending

End is **immediate**: it stops the daemon and kills the other recorded spawned
panes; the caller survives. There is no drain and no `DUET-END` ceremony. First
make sure no send is in flight and every result you need was delivered. Any
member may end:

PowerShell:

    $env:DUET_CONFIG = '@DUET_DIR@\duet.env'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-end.ps1"

Bash or Git Bash:

    DUET_CONFIG='@DUET_DIR@\duet.env' powershell.exe -NoProfile -ExecutionPolicy Bypass -File "@PLUGIN@\scripts\duet-end.ps1"
