# duet-agents

Run **Claude Code**, **Codex CLI**, and **Kimi CLI** as a visible **mesh** of
agents in tmux. Every agent can message every other agent directly — to divide
work, debate an approach, or cross-check one another. There is **no leader and
no election**; the agent the task was given to coordinates by convention.

This repository is a Claude Code plugin marketplace. Installing the `duet`
plugin adds `/duet:duet`, which creates the panes, a durable brief, per-recipient
message queues, and one delivery daemon.

> **Platform status (0.4.0):** the v4 mesh ships on **macOS/Linux (Bash + tmux)**.
> Windows/PowerShell (psmux) parity is the next release — the bundled `.ps1`
> scripts still run the previous leader-hub protocol.

```text
      ┌──────── one delivery daemon (per session) ────────┐
      │    per-recipient FIFO inboxes · at-least-once      │
      └──▲──────────▲──────────▲──────────▲────────────────┘
         │          │          │          │
      claude ◀───▶ codex-1 ◀─▶ kimi-1 ◀─▶ claude-1
        any agent messages any agent by name, or broadcasts to `all`
```

Duet is deliberately small. v4 removed the leadership, election, failover,
crash recovery, admission control, and cross-session fencing that had accreted
over earlier versions. What remains is one job done well: reliably moving a
message from one agent's queue into another agent's prompt.

## Why queues instead of screen-scraping

A terminal pane is a mutable display, not a reliable message channel. Duet does
not reconstruct agent responses by scraping pane output. A send atomically
publishes the message to a per-recipient inbox, and one delivery daemon injects
it into the recipient's normal prompt with bracketed paste. The daemon probes
the composer only to decide whether a paste landed; agent content travels in the
queued payload, never through `capture-pane` output.

The transport's properties:

- **Serialized, fair delivery.** Each recipient has a FIFO inbox. The daemon
  makes at most one bounded attempt per recipient per pass, so one stuck
  recipient never blocks the others. Interrupts take priority within a queue.
- **At-least-once + dedup.** Every payload carries a session ID and a stable
  message ID. A recipient suppresses a repeated ID; agents are told to ignore a
  duplicate. Exactly-once is not claimed.
- **Terminal states.** Every message ends as *delivered*, or its recipient is
  surfaced as **dead** (pane gone), **blocked** (a wedged composer, after a
  bounded number of non-landing attempts), or **rejected** (a malformed
  envelope) — never silent limbo. A single peer's failure never sinks the mesh.
- **Harness-aware submission.** Bracketed paste plus cursor-row composer-marker
  detection for Claude, Codex, and Kimi; after a paste is seen to land, the
  daemon only retries Enter and never repastes (so a task is never duplicated).
- **No recovery.** A crashed or wedged session is discarded, not repaired. There
  is no leadership takeover and no restart replay — just re-init.

The transcript is a human-readable activity log, not proof of delivery.

## Requirements

- macOS or Linux with [`tmux`](https://github.com/tmux/tmux). (Windows/psmux v4
  support is the next release.)
- [Claude Code](https://claude.com/claude-code) (`claude` on `PATH`)
- Each selected worker CLI on `PATH` and already authenticated:
  [Codex CLI](https://github.com/openai/codex) (`codex`),
  [Kimi CLI](https://github.com/MoonshotAI/kimi-cli) (`kimi`), or another
  `claude` process

A session has one initiating Claude plus one to four workers — a hard cap of
five agents.

## Install

```bash
claude plugin marketplace add JonathanRosado/duet-agents
claude plugin install duet@duet-agents
```

Or `/plugin marketplace add JonathanRosado/duet-agents` then
`/plugin install duet@duet-agents` from inside Claude Code.

## Use

Start Claude inside tmux, then choose the worker roster:

```bash
tmux new-session claude
```

```text
/duet:duet
/duet:duet codex kimi
/duet:duet codex codex kimi
/duet:duet codex kimi claude
```

With no arguments, the two-agent Claude + Codex default remains. Workers get
instance names (`codex-1`, `kimi-1`, `claude-1`); the bare name `claude` is the
initiator. Repeating a harness launches multiple instances.

Any agent addresses any other by exact roster name, or `all` to broadcast to
every other live member (never itself). The agent that received the task
coordinates by convention — decompose the goal, hand peers scoped tasks,
integrate their replies — but peers may also talk to each other directly.
`assignments.md` in the session dir is an optional shared scratchpad.

Ending is immediate and has no drain: it stops the daemon and kills the other
spawned panes (the caller's own pane survives). Because there is no drain, make
sure no send is in flight and any result you need has been delivered *before*
you end the session.

## Pin every session operation

There is no `current` pointer. Every command must pin the exact session with the
absolute config injected at launch as `DUET_CONFIG`, or `--session` on Bash:

```bash
DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-send.sh" codex-1 <<'DUET_EOF'
...message...
DUET_EOF

DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-status.sh"
```

Duet cross-checks the sender's tmux pane, `DUET_SELF`, roster membership, and
session ID, and refuses cross-session sends. **Multiple sessions can run
concurrently in one repository — put each in its own git worktree** (distinct
`AGENTS.md`/`CLAUDE.md` anchor files). Set `DUET_STATE_ROOT` before init to place
session state somewhere other than the default `$HOME/.duet`.

## Model and permission overrides

Built-in adapters use each worker CLI's configured default model unless its
override is set before `/duet:duet` starts. These do not change the already-
running initiating Claude:

| Harness | Environment variable | Launch argument |
| --- | --- | --- |
| Claude | `DUET_CLAUDE_MODEL` | `--model <value>` |
| Codex | `DUET_CODEX_MODEL` | `-m <value>` |
| Codex | `DUET_CODEX_REASONING_EFFORT` | `-c model_reasoning_effort=<value>` |
| Kimi | `DUET_KIMI_MODEL` | `-m <value>` |

Workers are launched as capable peers: Codex defaults to
`-s danger-full-access -a never`, Claude workers to
`--dangerously-skip-permissions`, and Kimi workers to `--auto`. Override with
`DUET_CODEX_SANDBOX`, `DUET_CODEX_APPROVAL`, `DUET_CLAUDE_PERMISSION_FLAG`, and
`DUET_KIMI_MODE_FLAG`. Restricting a worker below tmux or shared-workdir access
can prevent delivery or collaboration.

## Adding another CLI harness

Add `plugins/duet/harnesses/<harness>.sh` for Bash/tmux (and a matching
`<harness>.ps1` for the pending PowerShell path). Bash adapters implement:

```bash
DUET_HARNESS_BOOT_RE='regex visible after a successful boot'
DUET_HARNESS_BRIEF_FILE='AGENTS.md' # or CLAUDE.md

duet_harness_check()   { ...; }                 # fail before panes change if the binary is missing
duet_harness_pretrust(){ ...; }                 # $1 = workdir; idempotent; suppress trust dialogs
duet_harness_launch_cmd(){ ...; }               # $1 = workdir, $2 = duet dir, $3 = instance name
```

The launch command must start in the shared workdir, give the CLI access to the
session directory, avoid approval dialogs, export `DUET_SELF`, the absolute
`DUET_CONFIG`, and the unique `DUET_SESSION`, and auto-load the selected brief.
Register the harness name and instance counter in init.

## Troubleshooting

Always pin the session:

```bash
DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-status.sh"
DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-doctor.sh"
```

Status shows the pinned session id, daemon liveness, each roster pane / harness /
readiness, per-recipient queue depth, and any **dead** or **blocked** recipients.

- **A peer stops receiving.** Check status. `dead` = its pane is gone (re-init to
  replace it). `blocked` = its composer stayed occupied for `DUET_NOT_LANDED_LIMIT`
  consecutive attempts (default 30 ≈ a few seconds); clear that pane's composer
  (focus it, press **Escape**) and re-send. `rejected/` under the session dir
  holds malformed messages with a reason sidecar.
- **`queued` but nothing arrives.** The daemon may be down (`duet-status`) — sends
  are refused when it is not alive. Do not blindly re-send: a landed paste may
  already be accepted.
- **Do not `end` while a send is in flight.** Ending is immediate and unfenced, so
  a send racing teardown can be accepted into a stopped session and stranded.
  Confirm needed deliveries first, then end.
- **A wedged session** is discarded, not recovered. Re-init a fresh ensemble;
  session artifacts remain under `$DUET_STATE_ROOT/<session>/` as an audit record.

## Repository layout

```text
.claude-plugin/marketplace.json
plugins/duet/
├── .claude-plugin/plugin.json
├── briefs/ENSEMBLE_BRIEF.md          # mesh brief (Bash path)
├── briefs/ENSEMBLE_BRIEF.win.md      # previous protocol; updated with Windows parity
├── harnesses/{claude,codex,kimi}.{sh,ps1}
├── skills/duet/SKILL.md
├── scripts/
│   ├── duet-common.sh                # shared library + harness-aware verified send
│   ├── duet-init.sh                  # roster, brief render, launch, daemon
│   ├── duet-send.sh                  # enqueue: name | all
│   ├── duet-deliverd.sh              # per-recipient FIFO delivery daemon
│   ├── duet-end.sh                   # immediate teardown
│   └── duet-status.sh / duet-doctor.sh
│   └── (matching *.ps1 — previous protocol until Windows parity)
└── tests/
    └── run-bash-tests.sh             # m1-delivery · m2-mesh · m3-lifecycle · v4-real-smoke
```

## Safety notes

- Concurrent sessions in one repo use one git worktree each; a single worktree
  should host only one session (they share one `DUET:BEGIN`/`DUET:END` anchor).
- Codex pretrust adds the same trusted-project entry its own confirmation UI
  would write to `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`).
- Durable blocks in `AGENTS.md`/`CLAUDE.md` are delimited by `DUET:BEGIN`/
  `DUET:END`; teardown removes only those blocks.
- End kills only panes recorded as spawned and always exempts the caller pane,
  after checking the recorded tmux server and pane PID.

## License

MIT — see [LICENSE](LICENSE).
