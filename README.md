# duet-agents

Run **Claude Code**, **Codex CLI**, and **Kimi CLI** as a visible **mesh** of
agents in tmux. Every agent can message every other agent directly — to divide
work, debate an approach, or cross-check one another. There is **no leader and
no election**; the agent the task was given to coordinates by convention.

This repository ships an npm installer (`npx duet-agents`) that sets the mesh
up for **Claude Code, Codex CLI, and Kimi CLI** alike — any of the three can
install it, update it, and initiate a session. It is also still a Claude Code
plugin marketplace for users who prefer native Claude plugin management.
Installing adds a `duet` command to each selected CLI, which creates the panes,
a durable brief, per-recipient message queues, and one delivery daemon.

> **Platform status (0.5.0):** the v4 mesh ships on **macOS/Linux (Bash + tmux)**.
> Windows/PowerShell (psmux) parity is the next release — the bundled `.ps1`
> scripts still run the previous leader-hub protocol, so "no leader" applies to
> the Bash path only.

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
- **Terminal states.** In a live session, a message is archived *delivered* (or
  *rejected* — its envelope is malformed and it is moved to `rejected/` with a
  reason), or its recipient is surfaced as **dead** (pane gone) or **blocked**
  (fenced after a wedged composer, an ambiguous submit, or repeated non-landing)
  and its queued head is no longer attempted — never silent limbo. A single
  peer's failure is recipient-scoped and never sinks the mesh. (The documented
  exceptions are a send racing an immediate `end`, and a discarded crashed
  session — see **Ending** and **No recovery**.)
- **Harness-aware submission.** Bracketed paste plus cursor-row composer-marker
  detection for Claude, Codex, and Kimi; after a paste is seen to land, the
  daemon only retries Enter and never repastes — closing the known transport
  duplication path (delivery still being at-least-once overall).
- **No recovery.** A crashed or wedged session is discarded, not repaired. There
  is no leadership takeover and no restart replay — just re-init.

The transcript is a human-readable activity log, not proof of delivery.

## Requirements

- macOS or Linux with [`tmux`](https://github.com/tmux/tmux) for the v4 mesh —
  or Windows with [psmux](https://github.com/psmux/psmux) and PowerShell, which
  currently runs the previous leader-hub protocol (v4 parity is the next
  release).
- [Node.js](https://nodejs.org) ≥ 16.7 for the `npx duet-agents` installer.
- At least one of the supported CLIs on `PATH` and already authenticated —
  [Claude Code](https://claude.com/claude-code) (`claude`),
  [Codex CLI](https://github.com/openai/codex) (`codex`), or
  [Kimi CLI](https://github.com/MoonshotAI/kimi-cli) (`kimi`). Any of them can
  initiate a session; each additionally selected worker CLI must also be on
  `PATH` and authenticated.

A session has one initiator plus one to four workers — a hard cap of five
agents. The initiator is whichever CLI you run the duet command in: Claude,
Codex, and Kimi are all first-class initiators.

## Install

One command installs duet for every detected harness (or pick a subset with
`--claude`, `--codex`, `--kimi`):

```bash
npx duet-agents@latest install
```

Straight from GitHub, without waiting for an npm publish:

```bash
npx github:JonathanRosado/duet-agents install
```

What each harness gets:

- **Claude Code** — the `duet` plugin from this repository's marketplace
  (the installer runs `claude plugin marketplace add` + `claude plugin
  install` for you), giving `/duet:duet`.
- **Codex CLI** — the skill `~/.agents/skills/duet`, giving `$duet` (or
  `/skills → duet`).
- **Kimi CLI** — the skill `$KIMI_CODE_HOME/skills/duet` (default
  `~/.kimi-code/skills/duet`), giving `/skill:duet`.

Codex and Kimi share one **versioned, immutable** runtime under
`~/.duet/plugin/<version>` — the rendered skills point at it, and every duet
session pins its absolute path at launch. The installer canonicalizes every
destination (symlink aliases cannot bypass validation), refuses to adopt any
directory it did not create, and only ever deletes installed directories
carrying its own ownership marker.

**Claude-only alternative.** If you only use Claude Code, the plain plugin
commands still work exactly as before:

```bash
claude plugin marketplace add JonathanRosado/duet-agents
claude plugin install duet@duet-agents
```

Or `/plugin marketplace add JonathanRosado/duet-agents` then
`/plugin install duet@duet-agents` from inside Claude Code.

Restart each CLI after installing so it picks up the new plugin/skill.

## Updating

Move an existing install to the latest release, then **restart each CLI** to
apply it:

```bash
npx duet-agents@latest update
```

For Claude Code this runs `claude plugin update duet@duet-agents` (after a
best-effort `claude plugin marketplace update duet-agents`). For Codex and Kimi
it installs a new `~/.duet/plugin/<version>` directory and repoints only the
installed skills. Runtime directories are **immutable**: a running duet session
pins its version's absolute path in `duet.env` at launch, and the installer
never modifies or deletes a runtime — so an update can never hot-upgrade or
break a live session; it applies to the next session you start after the
restart.

To remove duet from the selected harnesses, per-harness:

```bash
npx duet-agents@latest uninstall [--claude] [--codex] [--kimi]
```

Uninstall removes each selected harness's skill and the Claude plugin. Runtime
copies under `~/.duet/plugin` are deliberately left in place — they are small
and a live session may still pin one; delete that directory yourself when no
sessions are running. Uninstall never touches session state under `~/.duet` or
directories it did not install, and it exits nonzero if any selected piece
could not be removed.

## Use

Start any installed CLI inside tmux — the one you start becomes the initiator —
then choose the worker roster:

```bash
tmux new-session claude   # then: /duet:duet
tmux new-session codex    # then: $duet   (or pick duet from /skills)
tmux new-session kimi     # then: /skill:duet
```

```text
/duet:duet codex kimi       # Claude Code
$duet codex kimi            # Codex CLI
/skill:duet codex kimi      # Kimi CLI
```

Roster arguments work the same in every CLI: no arguments means one Codex
worker, and repeating a harness word launches multiple instances
(`codex codex kimi` = four agents total).

With no arguments, the initiator + one Codex worker default remains. Workers
get instance names (`codex-1`, `kimi-1`, `claude-1`); the initiator keeps its
harness's bare name (`claude`, `codex`, or `kimi`). Repeating a harness
launches multiple instances.

Any agent addresses any other by exact roster name, or `all` to broadcast to
every other live, **deliverable** member (itself, and any dead or blocked peer,
are skipped). The agent that received the task coordinates by convention —
decompose the goal, hand peers scoped tasks, integrate their replies — but peers
may also talk to each other directly. `assignments.md` in the session dir is an
optional shared scratchpad.

Ending is immediate and has no drain: it stops the daemon and kills the other
spawned panes (the caller's own pane survives). Because there is no drain, make
sure no send is in flight and any result you need has been delivered *before*
you end the session.

## Pin every session operation

There is no `current` pointer. Every command targets one explicit session.
**Mutation commands (`send`, `end`) read `DUET_CONFIG`; diagnostics (`status`,
`doctor`) take an explicit `--session <duet.env>`.** Both are the absolute config
injected at launch.

```bash
DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$DUET_PLUGIN/scripts/duet-send.sh" codex-1 <<'DUET_EOF'
...message...
DUET_EOF

bash "$DUET_PLUGIN/scripts/duet-status.sh" \
  --session "/absolute/path/to/.duet/<session>/duet.env"
```

Here `$DUET_PLUGIN` is wherever duet is installed: `$CLAUDE_PLUGIN_ROOT` for a
Claude Code plugin install, or `~/.duet/plugin/<version>` for an `npx
duet-agents` install. (Agents never have to care — the session brief and
`duet.env` always carry the absolute path that launched them.)

Duet cross-checks the sender's tmux pane, `DUET_SELF` (when the pane has it),
roster membership, and session ID, and refuses cross-session sends. **Multiple
sessions can run concurrently in one repository — put each in its own git
worktree** (distinct `AGENTS.md`/`CLAUDE.md` anchor files). Set `DUET_STATE_ROOT`
before init to place session state somewhere other than the default `$HOME/.duet`.

## Model and permission overrides

Built-in adapters use each worker CLI's configured default model unless its
override is set before the session starts. These do not change the already-
running initiating agent:

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

Diagnostics take an explicit `--session`:

```bash
bash "$DUET_PLUGIN/scripts/duet-status.sh" --session "/absolute/path/to/.duet/<session>/duet.env"
bash "$DUET_PLUGIN/scripts/duet-doctor.sh"  --session "/absolute/path/to/.duet/<session>/duet.env"
```

Status shows the pinned session id, daemon liveness, each roster pane / harness /
readiness, per-recipient queue depth, and any **dead** or **blocked** recipients.

- **A peer stops receiving.** Check status. `dead` = its pane is gone. `blocked`
  = the daemon has terminally fenced that recipient (a wedged composer after
  `DUET_NOT_LANDED_LIMIT` attempts, default 30 ≈ a few seconds; an ambiguous
  submit; or a rejected head). A blocked recipient is **not** auto-recovered —
  the daemon skips it and new sends to it are refused; **re-init** if you need
  it. The exact reason is in `<session>/blocked/<name>` and `deliverd.log`;
  malformed messages are archived under `<session>/rejected/` with a reason.
- **`queued` but nothing arrives.** The daemon may be down (`duet-status`) —
  sends are refused when it is not alive. Do not blindly re-send: a landed paste
  may already be accepted.
- **Do not `end` while a send is in flight.** Ending is immediate and unfenced,
  so a send racing teardown can be accepted into a stopped session and stranded.
  Confirm needed deliveries first, then end.
- **A wedged session** is discarded, not recovered. Re-init a fresh ensemble;
  session artifacts remain under `$DUET_STATE_ROOT/<session>/` as an audit record.

## Repository layout

```text
package.json                          # npm manifest for the npx installer
bin/duet-agents.js                    # cross-platform install/update/uninstall entrypoint
.claude-plugin/marketplace.json
plugins/duet/
├── .claude-plugin/plugin.json
├── briefs/
│   ├── ENSEMBLE_BRIEF.md             # v4 mesh brief (Bash path)
│   └── ENSEMBLE_BRIEF.win.md         # previous protocol; pending Windows parity
├── harnesses/{claude,codex,kimi}.sh  # + matching .ps1 (previous protocol; pending parity)
├── skills/duet/SKILL.md              # Claude Code plugin skill (/duet:duet)
├── templates/
│   ├── agents-skill.posix.md         # rendered for Codex (~/.agents/skills/duet) and Kimi ($KIMI_CODE_HOME/skills/duet)
│   └── agents-skill.win.md           # Windows variant (.ps1, previous protocol)
├── scripts/
│   ├── duet-common.sh                # shared library + harness-aware verified send
│   ├── duet-init.sh                  # roster, brief render, launch, daemon
│   ├── duet-send.sh                  # enqueue: <name> | all
│   ├── duet-deliverd.sh              # per-recipient FIFO delivery daemon
│   ├── duet-end.sh                   # immediate teardown
│   ├── duet-status.sh
│   └── duet-doctor.sh                # (matching *.ps1 remain on the previous protocol)
└── tests/
    └── run-bash-tests.sh             # installer · m1-delivery · m2-mesh · m3-lifecycle · v4-real-smoke
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
