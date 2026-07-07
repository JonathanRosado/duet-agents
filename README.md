# duet-agents

Pair **Claude Code** and **Codex CLI** as two peer agents that collaborate in real
time, side by side in tmux. You talk to Claude; Claude and Codex talk to each other;
you watch both work in adjacent panes and can interrupt either one.

This repo is a **Claude Code plugin marketplace**. Installing the `duet` plugin gives
Claude a `/duet:duet` skill that spins the whole thing up.

```
   Claude (your pane)                         Codex (spawned pane)
   ─────────────────────                      ─────────────────────
   duet-send codex  ───────── paste ────────▶ [DUET from claude] …
                            (direct inline)
   [DUET from codex] … ◀───── paste ───────── duet-send claude
                            (direct inline)
```

## Why it's built this way

**Messages are pushed, never scraped.** The naive way to wire two terminal agents —
have one read the other's pane with `capture-pane` — is broken at the root: a terminal
is a *display*, not a channel. `capture-pane` samples a mutable character grid that is
a lossy, geometry-dependent, unframed projection of what the other agent wrote (in-place
overwrites destroy history; there's no end-of-message marker, so you race torn reads;
long output scrolls out of a fixed buffer). No wrapper fixes that — it's a property of
the grid.

So duet never reads a pane. Instead each message is **delivered inline**: pasted
straight into the recipient's prompt (bracketed paste, which preserves multi-line text
including code fences). The recipient sees a normal prompt — it never reads a file, so
there's **no read-hop**, and the conversation is synchronous:

- **Turn-taking** keeps the two in sync — each speaks, then waits.
- **Interruption** is first-class: either side (or you) can barge in with `Esc` +
  message to redirect the other mid-task.
- **Symmetric and direct:** both agents run with enough access to drive tmux, so each
  injects straight into the other's pane. Codex runs as a **full peer** by default —
  full filesystem + network, no approval prompts (the same footing as a Claude launched
  with skip-permissions) — and it's configurable. If you deliberately sandbox Codex below
  tmux-socket access, set `DUET_RELAY=1` and a tiny relay does its Codex→Claude delivery
  instead (still inline into Claude's pane, still no read-hop).

**The protocol is durable.** It's written into each agent's auto-loaded instruction file
— `AGENTS.md` for Codex, `CLAUDE.md` for Claude — so it survives `/clear` and context
compaction. Every message is also appended to a `transcript.md`, so after a wipe an agent
can re-read the thread to recover context.

## Requirements

- [`tmux`](https://github.com/tmux/tmux)
- [Claude Code](https://claude.com/claude-code) — `claude` on PATH
- [Codex CLI](https://github.com/openai/codex) — `codex` on PATH, already authenticated

## Install

```bash
claude plugin marketplace add JonathanRosado/duet-agents
claude plugin install duet@duet-agents
```

(Or in Claude: `/plugin marketplace add JonathanRosado/duet-agents` then
`/plugin install duet@duet-agents`.) Nothing separate to install for Codex — the same
repo carries Codex's side of the protocol, and the skill briefs it automatically.

## Use

Claude must be running **inside tmux** (that's how both agents get visible panes):

```bash
tmux new-session claude
```

Then, in that Claude session:

```
/duet:duet
```

Claude splits the window, boots Codex in the new pane, waits for it to confirm ready,
and hands you a live pair. Give Claude a task and tell it to work with Codex —
design debates, cross-checking a tricky change, splitting up an implementation, a second
opinion. To redirect Codex mid-thought, tell Claude to interrupt (or just type into
Codex's pane yourself). To stop, tell Claude you're done; it sends `DUET-END` and closes
the pane. The full transcript persists under `~/.duet/<timestamp>/`.

## What's in here

```
.claude-plugin/marketplace.json      # marketplace manifest
plugins/duet/
├── .claude-plugin/plugin.json        # plugin manifest
├── skills/duet/SKILL.md              # Claude's side (the /duet:duet skill)
├── codex/AGENTS_BRIEF.md             # Codex's durable protocol (-> AGENTS.md at launch)
├── claude/CLAUDE_BRIEF.md            # Claude's durable protocol (-> CLAUDE.md at launch)
└── scripts/
    ├── duet-init.sh                  # anchor protocol, split window, launch Codex, start relay
    ├── duet-send.sh                  # send a message inline (direct to Codex; via relay to Claude)
    ├── duet-relay.sh                 # optional (DUET_RELAY=1): Codex→Claude inject when Codex is sandboxed
    ├── duet-status.sh                # inspect a running duet
    └── duet-end.sh                   # tear down + strip the durable blocks
```

## Safety notes

- Codex launches as a full peer by default: `-s danger-full-access -a never` — full
  filesystem + network, no approval prompts (the same footing as a Claude run with
  `--dangerously-skip-permissions`). Tighten it with `DUET_CODEX_SANDBOX` /
  `DUET_CODEX_APPROVAL` (and add `DUET_RELAY=1` if you drop below tmux-socket access).
- `duet-init.sh` marks the working dir trusted in `~/.codex/config.toml` (exactly what
  Codex's own "Yes, continue" writes) so Codex doesn't stall on a trust dialog at boot.
- The durable blocks in `AGENTS.md`/`CLAUDE.md` are delimited with `DUET:BEGIN/END`
  markers and removed by `duet-end.sh`; your own content is never touched.

## License

MIT — see [LICENSE](LICENSE).
