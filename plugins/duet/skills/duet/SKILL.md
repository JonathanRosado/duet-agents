---
description: Pair this Claude with a live Codex agent in an adjacent tmux pane for real-time, bidirectional, synchronous collaboration (a "duet"). Messages are delivered inline straight into each agent's prompt (no file to read, no polling), turn-taking keeps them in sync, and either side can interrupt the other. Use when the user wants Claude and Codex to work together interactively, debate an approach, or cross-check each other.
---

# Duet: Claude + Codex, side by side

This pairs you (Claude) with a live **Codex** agent in the adjacent tmux pane. You
collaborate as peers by exchanging messages that arrive **inline** — each message is
injected directly into the recipient's prompt (bracketed paste), so nobody reads a
file or polls. Turn-taking keeps you in sync; either side can interrupt the other.

## 0. Preconditions
- You MUST be inside tmux. If `$TMUX` is empty, STOP and tell the user:
  "Relaunch me inside tmux first:  `tmux new-session claude`  — then run `/duet:duet`."
- `codex` must be installed and already authenticated.

## 1. Start
Run:

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-init.sh"

This anchors the protocol in `AGENTS.md`/`CLAUDE.md` (so it survives `/clear` and
compaction), splits the window, launches Codex (which reads its brief at boot), and
starts the relay. Tell the user Codex is booting, then **send it the first message.**

## 2. The protocol
**Receiving.** A message from Codex arrives as a normal user prompt whose first line
is `[DUET from codex]`. Everything after is Codex's message — read it, act, reply.

**Sending.** To message Codex (body on stdin):

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex <<'DUET_EOF'
    ...your message to Codex...
    DUET_EOF

**After you send, END YOUR TURN and wait.** Do not keep working or narrate — Codex's
reply arrives as the next `[DUET from codex]` prompt and wakes you. One message per
reply; never send twice in a row.

**Interrupting.** To barge in while Codex is mid-task, add `--interrupt`:

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

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-send.sh" codex <<'DUET_EOF'
    DUET-END — wrapping up. Summary: ...
    DUET_EOF
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-end.sh"

## Escape hatch
- `bash "${CLAUDE_PLUGIN_ROOT}/scripts/duet-status.sh"` — session state, transcript tail, Codex pane peek.
- Full transcript persists at `~/.duet/<timestamp>/transcript.md`.