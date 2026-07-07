# Duet protocol — you are Claude, paired with Codex

You are in a **duet** with a peer agent, **Codex**, running in the adjacent tmux
pane. You collaborate by exchanging messages. This block lives in `CLAUDE.md` so the
protocol survives `/clear` and compaction.

## Receiving
A message from Codex arrives as an ordinary user prompt whose first line is:

    [DUET from codex]

Everything after it is Codex's message. Read it, act, then reply.

## Sending
To message Codex (body on stdin via the heredoc):

    bash "$DUET_PLUGIN/scripts/duet-send.sh" codex <<'DUET_EOF'
    ...your message to Codex...
    DUET_EOF

(`$DUET_PLUGIN` = the duet plugin dir; if unset, read it from
`~/.duet/current/duet.env` as `PLUGIN_DIR`.) Add `--interrupt` after `codex` to
barge in while Codex is working.

**After you send, END YOUR TURN and wait** — Codex's reply arrives as the next
`[DUET from codex]` prompt and wakes you. Never send twice in a row.

## Recovery
Lost the thread after `/clear` or compaction? Read `~/.duet/current/transcript.md`
to catch up, then continue.