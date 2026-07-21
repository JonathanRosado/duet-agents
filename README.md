# duet-agents

Run **Claude Code**, **Codex CLI**, and **Kimi CLI** as a visible, leader-led
agent ensemble in tmux or psmux. The Claude that starts the session leads; up
to four named workers collaborate in adjacent panes, with leader failover if
the leader disappears or can no longer receive messages.

This repository is a Claude Code plugin marketplace. Installing the `duet`
plugin adds `/duet:duet`, which creates the panes, durable briefs, message
queues, delivery daemon, and session transcript.

```text
                         leadership state
                         {term, leader}
                                │
                 ┌──────────────▼──────────────┐
                 │  queue + delivery daemon   │
                 │  watchdog + session fence  │
                 └──────┬──────────────┬──────┘
                        │              │
    you ──▶ Claude      ▼              ▼
           (leader) ◀── inbox       inbox ──▶ Codex / Kimi / Claude
               ▲                                      (workers)
               └──────── worker replies to `leader` ──────────┘
```

Workers never message one another directly. Each leader-worker edge keeps the
simple duet discipline: one message, one reply, then wait.

The queued n-agent protocol runs through Bash/tmux on macOS and Linux and
through PowerShell/psmux on Windows. Both paths use the same roster, session
fences, delivery states, and leader-failover rules.

## Why queues instead of screen-scraping

A terminal pane is a mutable display, not a reliable message channel. Duet does
not reconstruct agent responses by scraping pane output. A send atomically
publishes the message to a per-recipient inbox, and one delivery daemon injects
it into the recipient's normal prompt using bracketed paste. The daemon may
probe the composer to decide whether a paste landed, but agent content travels
in the queued payload, not through `capture-pane` output.

The transport has a few important properties:

- **Serialized, fair delivery.** Each recipient has a FIFO inbox. The daemon
  makes at most one bounded operation per resolved pane per pass, coalescing
  symbolic and named queues that currently target the same pane. One stuck pane
  therefore does not block the others. Urgent interrupts can supersede an
  undeliverable normal message.
- **Fenced leadership.** Every payload carries a session ID, stable message ID,
  and leadership term. Worker replies use the symbolic recipient `leader`,
  which is resolved only when delivered. Messages from a stale leader term and
  payloads from another session are quarantined.
- **Ranked failover.** The daemon watches the current leader. A dead pane or
  three consecutive verified delivery failures promotes the next eligible live
  roster member. The failed incumbent is excluded from automatic succession,
  and the new leader's promotion notice is delivered before ordinary traffic.
- **Durable recovery.** The role-neutral protocol is anchored in `AGENTS.md` or
  `CLAUDE.md`; `transcript.md`, `assignments.md`, and the leadership state let a
  promoted or context-compacted agent recover.
- **At-least-once delivery.** A crash during an uncertain submit can result in
  the same stable message ID appearing more than once. Agents are instructed to
  suppress duplicate work by ID. Exactly-once delivery is not claimed.

The transcript records enqueue intent immediately before the queue file's
atomic publication. It can therefore contain a **transcript-only phantom** if
publication is interrupted, or if the payload is later quarantined, fails
permanently, or the session ends before injection. Treat the transcript as an
audit/recovery record, not proof that a recipient processed an entry.

## Requirements

- macOS or Linux with [`tmux`](https://github.com/tmux/tmux), or Windows with
  [psmux](https://github.com/psmux/psmux) 3.3.6
- [Claude Code](https://claude.com/claude-code) (`claude` on `PATH`)
- Each selected worker CLI must be on `PATH` and already authenticated:
  [Codex CLI](https://github.com/openai/codex) (`codex`),
  [Kimi CLI](https://github.com/MoonshotAI/kimi-cli) (`kimi`), or another
  `claude` process

Claude can also be used as a worker harness. A session has one initiating
Claude plus one to four workers, for a hard cap of five agents.

## Install

```bash
claude plugin marketplace add JonathanRosado/duet-agents
claude plugin install duet@duet-agents
```

Or use `/plugin marketplace add JonathanRosado/duet-agents`, followed by
`/plugin install duet@duet-agents`, from Claude Code.

## Use

Start Claude inside the multiplexer for your platform:

```bash
tmux new-session claude
```

```powershell
psmux new-session -s duet -- claude
```

Then choose the worker roster. With no arguments, the existing two-agent
Claude + Codex experience remains the default:

```text
/duet:duet
/duet:duet codex kimi
/duet:duet codex codex kimi
/duet:duet codex kimi claude
```

Workers receive instance names such as `codex-1`, `codex-2`, `kimi-1`, and
`claude-1`; the bare name `claude` is reserved for the initiator. Repeating a
harness launches multiple instances.

The leader decomposes the user's goal, assigns disjoint file scopes, records
them in `assignments.md`, and keeps at most one outstanding task per worker.
Workers report scope conflicts instead of editing across another worker's
assignment. A leader can fan out to `all`; workers reply only to `leader`.

When work is complete, the leader broadcasts `DUET-END` and runs the end
command. Teardown first closes queue admission and waits for already-published
messages to drain, then removes durable brief anchors and stops only panes that
this session spawned.

## Pin every session operation

The `current` pointer under the state root helps a human inspect the newest
session. Two ensembles may be active in different workdirs, so each agent
command must use the absolute session config injected at launch as
`DUET_CONFIG`, or pass `--session` on Bash and `-Session` on PowerShell.

```bash
DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-status.sh"

DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-send.sh" leader <<'DUET_EOF'
...message...
DUET_EOF
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-status.ps1" `
  -Session "C:\absolute\state\<session>\duet.env"

@'
...message...
'@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-send.ps1" leader `
  -Session "C:\absolute\state\<session>\duet.env"
```

On Windows, Kimi and some Claude tool sessions use Bash or Git Bash. In that
shell, invoke the same PowerShell script with a Bash heredoc instead of a
PowerShell here-string:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "$CLAUDE_PLUGIN_ROOT\scripts\duet-send.ps1" leader \
  -Session 'C:\absolute\state\<session>\duet.env' <<'DUET_EOF'
...message...
DUET_EOF
```

Do not make agent traffic depend on the `current` pointer, and do not mix a
send script copied from another plugin version or session. Duet cross-checks
the sender's multiplexer pane, `DUET_SELF`, roster membership, and session ID;
it refuses cross-session sends.

One active session is allowed per workdir. Starting a replacement reaps only
the same-workdir predecessor and cannot disturb a session in another workdir.
Set `DUET_STATE_ROOT` before init to place session state somewhere other than
the default `$HOME/.duet` on Unix or `%USERPROFILE%\.duet` on Windows.

## Model and permission overrides

Built-in adapters use each launched worker CLI's configured default model
unless its override is set before `/duet:duet` starts. These variables do not
change the already-running initiating Claude:

| Harness | Environment variable | Launch argument |
| --- | --- | --- |
| Claude | `DUET_CLAUDE_MODEL` | `--model <value>` |
| Codex | `DUET_CODEX_MODEL` | `-m <value>` |
| Codex | `DUET_CODEX_REASONING_EFFORT` | `-c model_reasoning_effort=<value>` |
| Kimi | `DUET_KIMI_MODEL` | `-m <value>` |

For example:

```bash
DUET_CLAUDE_MODEL=haiku \
DUET_CODEX_MODEL=gpt-5.3-codex-spark \
DUET_CODEX_REASONING_EFFORT=low \
DUET_KIMI_MODEL=kimi-code/kimi-for-coding \
claude
```

That example selects locally available models; model names are owned by their
respective CLIs and may change. Duet does not otherwise replace a CLI's normal
model configuration.

Workers are intentionally launched as capable peers. Codex defaults to
`-s danger-full-access -a never`, Claude workers to
`--dangerously-skip-permissions`, and Kimi workers to `--auto`. Advanced users
can override these with `DUET_CODEX_SANDBOX`, `DUET_CODEX_APPROVAL`,
`DUET_CLAUDE_PERMISSION_FLAG`, and `DUET_KIMI_MODE_FLAG`. Restricting a worker
below multiplexer or shared-workdir access can prevent delivery or collaboration.

## Adding another CLI harness

Add `plugins/duet/harnesses/<harness>.sh` for Bash/tmux and a matching
`<harness>.ps1` adapter for PowerShell/psmux. Bash adapters implement this
contract:

```bash
DUET_HARNESS_BOOT_RE='regex visible after a successful boot'
DUET_HARNESS_BRIEF_FILE='AGENTS.md' # or CLAUDE.md

duet_harness_check() { ...; }
duet_harness_pretrust() { # $1 = workdir; idempotent
  ...
}
duet_harness_launch_cmd() { # $1 = workdir, $2 = duet dir, $3 = instance name
  # Print one shell-quoted command for tmux split-window.
  ...
}
```

`duet_harness_check` must fail before panes are changed when its locally
testable boot prerequisites are missing (at minimum, the binary). Authentication
may still be established only by the real readiness kick. The optional
`duet_harness_pretrust` step must suppress interactive trust dialogs without
corrupting existing configuration. The launch command must start in the shared
workdir, give the CLI access to the session directory, avoid approval dialogs,
and export `DUET_SELF`, the absolute `DUET_CONFIG`, and the unique
`DUET_SESSION`. The CLI must auto-load the selected durable brief.

PowerShell adapters return a hashtable with `BootRegex`, `BriefFile`, `Check`,
`Pretrust`, and `LaunchCommand`. Register the harness name and instance counter
in both init scripts. Keep model selection optional through a
`DUET_<HARNESS>_MODEL` variable so an unset value preserves the CLI default.

## Troubleshooting and recovery

Always pin the session when running diagnostics:

```bash
DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-status.sh"

DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
  bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-doctor.sh"
```

On Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-status.ps1" `
  -Session "C:\absolute\state\<session>\duet.env"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-doctor.ps1" `
  -Session "C:\absolute\state\<session>\duet.env"
```

- If a long or collapsed paste leaves a recipient composer non-empty and Enter
  will not submit it, the daemon automatically clears and requeues only a Codex
  marker it can prove belongs to that stable message ID. It durably fences the
  pane before sending **Escape**, then **Ctrl-U**, and never repastes until the
  marker is visibly gone. If ownership cannot be proved and manual recovery is
  required, focus that pane and press **Escape**, then **Ctrl-U** yourself. Do
  not blindly repaste: the first copy may already have landed.
- If a worker loses context, it should read the pinned session's
  `transcript.md`, `assignments.md`, and `leader` files before continuing.
- If sends are refused because the daemon is down or the session is draining,
  inspect status/doctor rather than bypassing the queue.
- If automatic succession is unsuitable, run the fenced promotion transaction
  from the current leader pane:

  ```bash
  DUET_CONFIG="/absolute/path/to/.duet/<session>/duet.env" \
    bash "$CLAUDE_PLUGIN_ROOT/scripts/duet-promote.sh" --to codex-1
  ```

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    "$env:CLAUDE_PLUGIN_ROOT\scripts\duet-promote.ps1" -To codex-1 `
    -Session "C:\absolute\state\<session>\duet.env"
  ```

  Directly editing `leader` is an emergency-only, unsafe last resort: it skips
  the term compare-and-swap, failed-member exclusion, promotion-first ordering,
  and notices. Prefer the platform's `duet-promote` script.

  Promotion is a permanent handoff within that session: the former incumbent
  becomes ineligible and `--force` is intentionally unsupported.

Session artifacts persist under `$DUET_STATE_ROOT/<session>/` after teardown so
the transcript remains available.

## Upgrading from 0.1.x or Windows 0.2.0

Version 0.2.1 brings the queued n-agent schema to Windows. End any live legacy
Windows or 0.1.x session, update the plugin through Claude's plugin manager,
restart Claude so it loads the new plugin cache, and start a fresh ensemble.
Existing session directories are audit records; they are not upgraded in place.

Compatibility notes:

- `/duet:duet` with no arguments still starts one Codex worker.
- Direct pane-to-pane send and the optional `DUET_RELAY` path are retired.
  Every message now goes through the queue and delivery daemon.
- Worker names are suffixed, and worker replies should target `leader` rather
  than a concrete agent name.
- Every agent-facing send, end, or promotion command now requires an explicit
  session pin (`DUET_CONFIG`, `--session`, or `-Session`). Do not use the
  `current` pointer for agent routing. Human-only status/doctor calls may inspect
  `current`, but pinning them is safer when multiple sessions exist.
- Do not use a cached 0.1.x `duet-send` against a current session.

## Repository layout

```text
.claude-plugin/marketplace.json
plugins/duet/
├── .claude-plugin/plugin.json
├── briefs/ENSEMBLE_BRIEF.md
├── briefs/ENSEMBLE_BRIEF.win.md
├── harnesses/
│   ├── claude.sh / claude.ps1
│   ├── codex.sh / codex.ps1
│   └── kimi.sh / kimi.ps1
├── skills/duet/SKILL.md
└── scripts/
    ├── duet-common.sh / duet-common.ps1
    ├── duet-init.sh / duet-init.ps1
    ├── duet-send.sh / duet-send.ps1
    ├── duet-deliverd.sh / duet-deliverd.ps1
    ├── duet-promote.sh / duet-promote.ps1
    ├── duet-status.sh / duet-status.ps1
    ├── duet-doctor.sh / duet-doctor.ps1
    └── duet-end.sh / duet-end.ps1
```

## Safety notes

- All agents share one workdir. The protocol relies on leader-assigned,
  disjoint scopes; it does not create separate git worktrees.
- Codex pretrust adds the same trusted-project entry its own confirmation UI
  would write to `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`).
- Durable blocks in `AGENTS.md` and `CLAUDE.md` are delimited by
  `DUET:BEGIN`/`DUET:END`; teardown removes only those blocks.
- End/reap kills only panes recorded as spawned and always exempts the caller.
- The Windows path scopes each psmux operation to its recorded namespace and
  session, then checks the recorded backend PID and pane PID before acting.

## License

MIT — see [LICENSE](LICENSE).
