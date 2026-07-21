# Historical plan: duet to n-agent ensemble protocol (v0.2.0-v0.2.1)

> **Archived design history:** Everything below this notice describes the
> v0.2 implementation plan and is non-normative for v0.3.0. Current behavior is
> specified in `README.md`, `plugins/duet/skills/duet/SKILL.md`, and the briefs.
>
> In v0.3.0, automatic election, watchdog counters, ranked succession, and
> failed-leader exclusion were removed. The initiator leads until an operator
> explicitly selects a live target. Generation and delivery fences remain, and
> the daemon may finish only an exact recorded MANUAL handoff.

Evolve the duet plugin from a hardcoded 2-agent (Claude+Codex) protocol to an
n-agent protocol (target 3 concurrent harnesses, protocol designed for up to 5),
adding Kimi CLI (`kimi`, kimi-code) as the third harness. Working session:
Claude = planner/leader/reviewer, Codex = implementer + smoke tester.

## Decisions (locked with the user)

1. **Topology: leader hub-and-spoke.** Workers exchange messages only with the
   current leader. Every edge stays a duet: one message, one reply, wait.
   Workers never message each other.
2. **Leadership: initiator leads, ranked failover.** The agent that started the
   session (the Claude pane hosting the skill) is leader. Succession order =
   roster order. Failover is automatic (see §Failover).
3. **Reply flow: async, queued per pane.** Worker replies wake the leader as
   they arrive. A per-recipient delivery queue serializes injections so two
   workers finishing simultaneously can't corrupt the leader's composer.
4. **Roster: named instances**, e.g. `claude`, `codex-1`, `codex-2`, `kimi-1`.
   Multiple instances of the same harness allowed. Hard cap: 5 agents total.
5. **Isolation: shared workdir, leader-assigned disjoint scopes.** No git
   worktrees. The leader partitions work so no two workers touch the same
   files; a worker that finds its scope conflicts reports back instead of
   editing.
6. **Failover: the delivery daemon is also the watchdog.** It monitors leader
   liveness and promotes the next-ranked live agent.
7. **Packaging: evolve duet in place.** 2-agent is just a roster of one worker.
   Version 0.2.0 delivered the tmux/Bash path; v0.2.1 adds matching
   PowerShell/psmux behavior without changing the wire protocol.

## Session layout (`$DUET_DIR` = `~/.duet/<stamp>/`)

    duet.env            # DUET_DIR, WORKDIR, PLUGIN_DIR, DAEMON_PID
    roster.tsv          # name <TAB> harness <TAB> pane_id <TAB> pane_pid <TAB> rank
    leader              # current leader name — single source of truth
    ready/<name>        # per-agent readiness markers written at boot
    inbox/<name>/NNNN.msg        # queued messages (line 1: NORMAL|INTERRUPT, rest: payload)
    inbox/<name>/delivered/      # archived after injection
    transcript.md       # global log, `from -> to` headers (existing format)
    assignments.md      # leader-maintained work/scope board (convention, not enforced)

## Components

### duet-send.sh (rewrite: enqueue only)
- Usage: `duet-send.sh <recipient-name|leader|all> [--interrupt] [--from <name>]`.
- ALL delivery now goes through the daemon — send only enqueues (atomic tmp+mv,
  monotonic seq). One injection code path instead of two.
- **Sender identity:** resolved by looking up `$TMUX_PANE` in roster.tsv (every
  agent's shell inherits its pane's env, including the initiator's). `--from`
  overrides; error out if unresolvable.
- **Hub enforcement:** if sender ≠ current leader, recipient must be the leader
  (accept the literal alias `leader`). Reject worker→worker with a clear error.
  `all` (broadcast) is leader-only.
- `leader` alias always resolves against the `leader` file at send time, so
  worker briefs stay correct across promotions.

### duet-deliverd.sh (new daemon; generalizes duet-relay.sh)
- One daemon per session, started unconditionally by init (the DUET_RELAY
  conditional mode is retired). Loop over `inbox/*/`, inject each message into
  the recipient's pane via `duet_send_verified` (duet-common.sh), honoring
  INTERRUPT flags, archiving to `delivered/`, appending nothing to the
  transcript (send already did).
- Strict per-recipient FIFO; recipients are independent of each other.
- **Watchdog:** each loop, check the leader's pane with `_duet_alive`.
  Promotion triggers: (a) leader pane dead — hard trigger; (b) 3 consecutive
  `duet_send_verified` failures delivering to the leader — soft trigger.
  (Queue depth/age alone never triggers promotion; a slow leader is not a dead
  leader.)
- **Promotion:** pick the lowest-rank live agent from roster.tsv; write its
  name to `leader`; inject `[DUET promotion] You are now the leader …` (with
  instructions to read transcript.md + assignments.md and take over); enqueue a
  leadership-change notice to every other live agent; log to transcript.
- Exit when `$DUET_DIR/.ended` appears.

### Harness adapters (new: `plugins/duet/harnesses/<harness>.sh`)
Each adapter is a small sourced file defining a fixed contract:
- `duet_harness_check` — binary present/authenticated enough to boot.
- `duet_harness_pretrust <workdir>` — pre-trust the workdir (codex:
  config.toml trust block, as today; kimi/claude: whatever avoids boot dialogs).
- `duet_harness_launch_cmd <workdir> <duet_dir> <name>` — print the full
  command for `tmux split-window`, embedding `DUET_SELF=<name>` in the pane
  environment and full-access/no-approval flags (overridable via env, as the
  codex sandbox flags are today).
- `DUET_HARNESS_BOOT_RE` — pane-banner regex for boot detection
  (codex: `OpenAI Codex`; kimi: TBD during smoke test).
- `DUET_HARNESS_BRIEF_FILE` — which anchor file it reads at boot
  (codex: AGENTS.md, kimi: AGENTS.md — confirmed: the kimi binary templates
  AGENTS.md into its system prompt; claude: CLAUDE.md).
- Ship three adapters: `codex.sh`, `kimi.sh`, `claude.sh` (claude as a
  *worker* instance launched via the `claude` CLI).

### Briefs (replace the two per-agent briefs with one generic brief)
- One `briefs/ENSEMBLE_BRIEF.md` rendered into BOTH `AGENTS.md` and
  `CLAUDE.md` anchors. Since Codex and Kimi both read AGENTS.md, identity can
  no longer be implied by file — the brief is written role-neutral:
  - "Your name was given in your boot message and in `$DUET_SELF`."
  - "Read `$DUET_DIR/leader`. If it names you, you are the leader: decompose,
    assign disjoint file scopes (record in assignments.md), one outstanding
    task per worker, merge results, talk to the user. Otherwise you are a
    worker: act on tasks from the leader, send replies ONLY to `leader`,
    report scope conflicts instead of editing across them."
  - Turn discipline per edge unchanged: one reply per received message, then
    wait. Interrupts only to urgently redirect.
  - `DUET-END` semantics and transcript recovery, as today.

### duet-init.sh (rewrite)
- Usage: `duet-init.sh <harness> [<harness>…]`, e.g. `duet-init.sh codex kimi`.
  Roster = initiator (`claude`, rank 0) + one entry per arg in order
  (auto-named `codex-1`, `kimi-1`, `codex-2`, …; plain `codex` when a harness
  appears once). Enforce cap of 5, ≥1 worker.
- Reap any previous session's ENTIRE roster (generalize `duet_reap_prev`).
- Write anchors (generic brief), pretrust per harness, launch each worker pane,
  `select-layout tiled` for n≥3, write roster.tsv + leader + duet.env, start
  the daemon, then kick each worker: "You are `<name>` … confirm with
  `printf ok > $DUET_DIR/ready/<name>`", and wait for all ready files.
  Report per-agent ready status to the user.
- Keep the paste-verification discipline (`duet_send_verified`) everywhere.

### duet-end.sh / duet-status.sh / duet-doctor.sh
- End: touch `.ended` (daemon exits), strip anchors, kill every roster pane.
  (The leader should broadcast `DUET-END` via `duet-send.sh all` first —
  documented in SKILL.md, as today.)
- Status/doctor: roster table — name, harness, pane, alive?, inbox depth,
  ready?, current leader, daemon pid.

### SKILL.md + README
- `/duet:duet codex kimi` — skill passes roster args through to init; no args
  defaults to `codex` (today's behavior, preserved).
- Rewrite protocol sections for hub semantics, `leader` alias, failover
  behavior, assignments.md convention. Update README (rename pitch: duet → n).

## Failover heuristic (summary)
Ranks = roster order. Trigger = leader pane dead, or 3 consecutive failed
verified deliveries to it. Daemon promotes lowest-rank live agent, updates
`leader`, notifies everyone. Recovery of an old leader is out of scope; the
user can manually edit `leader` (documented).

## Milestones (implementation order for Codex)
- **M1:** session layout, roster, generic brief, adapters (codex/claude/kimi),
  init rewrite. Parity smoke: 2-agent claude+codex boots and round-trips.
- **M2:** send rewrite + delivery daemon. 3-agent smoke: claude+codex+kimi;
  concurrent double-send to leader proves serialization.
- **M3:** watchdog failover + status/doctor. Smoke: kill leader pane, observe
  promotion + notices.
- **M4:** SKILL.md, README, briefs polish; bump plugin.json to 0.2.0.

## Smoke test protocol (Codex, fresh tmux server)
Run on an isolated server socket so this live session is untouched:
`tmux -L duetsmoke new-session -d …`. Scripted checks: all ready files appear;
round-trip on each leader↔worker edge; two workers sending "simultaneously"
arrive serialized and intact; worker→worker send is rejected; leader pane kill
→ promotion observed within timeout; DUET-END teardown leaves no panes, daemon
exited, anchors stripped. NOTE: duet-common.sh's verified-send is marked as
never having been exercised against a live tmux TUI — this smoke test is also
its first real exercise; fix what it reveals.

## Adopted amendments (post-critique — NORMATIVE, supersedes conflicting text above)

Codex's architecture critique was accepted in full. Where the following
conflicts with earlier sections, this section wins.

### A1. Atomic queue + transcript
- Enqueue: per-recipient `mkdir` lock + persistent counter (collision-free,
  sortable IDs), `mktemp` staging names, atomic rename. No `count+1` naming.
- Transcript appends serialized under a lock; transcript order must match
  queue order.

### A2. Delivery is at-least-once, not exactly-once
- `duet_send_verified` outcomes split into: `NOT_LANDED` (safe to repaste),
  `LANDED_UNVERIFIED` (retry Enter only / quarantine — never blind repaste),
  `DEAD` (pane gone).
- Every payload carries a stable message ID and the current leadership term in
  its header. Delivery documented as at-least-once under crash/uncertain-submit;
  briefs tell agents to ignore a duplicate message ID.

### A3. Failover: epoch + fencing
- Leadership state is `{term, leader}` written atomically (tmp+mv).
- Promotion excludes the failed incumbent; demoted/failed leaders are
  permanently ineligible for automatic succession.
- The symbolic recipient `leader` is preserved until *delivery time* (daemon
  resolves it), so queued worker replies survive a promotion. Leader-originated
  messages from a stale term are quarantined, not delivered.
- Promotion notice to the new leader precedes ordinary traffic and is retried.
  Define and log the no-live-successor terminal state.
- Promotion is done via a `duet-promote` command path (also usable manually);
  raw edits of the leader file are documented as emergency-only/unsafe.

### A4. Daemon scheduling + interrupts
- Recipients must be genuinely independent: one bounded delivery attempt per
  recipient per pass (fair scheduler) — a failing head stalls only its own
  queue, never the watchdog or other recipients.
- INTERRUPT messages have priority/supersede semantics within a recipient's
  queue (an interrupt queued behind an undeliverable NORMAL must still barge).

### A5. Failure behavior for non-leader delivery
- Bounded retry with backoff → `inbox/<name>/failed/` + a notice to the leader
  when a worker pane dies.
- `duet-send` reports "queued", never "submitted"; it warns/refuses if the
  daemon is not alive. Daemon PID lives in an atomic `daemon.pid` file, not in
  duet.env.

### A6. Lifecycle
- Roster gains a `spawned` column; end/reap only ever kill *spawned* panes and
  always exempt the initiator/current pane (fixes self-kill on end and re-init).
- `duet-end` drains queues (bounded barrier) before touching `.ended`, so a
  final `send all` (DUET-END) is actually delivered.
- Re-init strips the *previous* session's anchors from its WORKDIR before
  appending fresh ones (no stale DUET_DIR paths).
- Session dir uses a collision-proof suffix (`mktemp -d` style), not
  second-resolution timestamps. Roster/config published atomically before any
  boot kick.

### A7. Identity
- ALL workers are suffixed (`codex-1`, `kimi-1`, `claude-1`); the bare name
  `claude` is reserved for the initiator. (Optional alias for 2-agent
  ergonomics: `codex` → `codex-1` when unambiguous.)
- Sender authority: roster lookup by `$TMUX_PANE`, cross-checked against
  `DUET_SELF` when present — mismatch is an error. `--from` is validated and
  rejected on mismatch with a known caller pane (admin/test override env var
  exists but is explicit).
- Store the tmux socket/server identity in duet.env so daemon/status work from
  outside panes and isolated test servers behave. Shell-quote all values
  sourced from env files.
- `DUET_STATE_ROOT` (default `$HOME/.duet`) parameterizes all session state —
  required for isolated smoke testing.

### A8. Session pinning & cross-session fencing (added after a live incident)
Live incident during implementation (2026-07-20): a second `/duet:duet` in
another tmux window repointed `~/.duet/current`. The implementer's M2 gate
report, sent with ambient session resolution, was delivered to the OTHER
session's leader — which accepted the gate and issued M3 GO to its own
context-less worker (in the wrong workdir) while the real implementer sat
idle. Split-brain: two leaders, two workers, each pair half-wrong. Fixes:
- **No ambient session resolution by agents, ever.** `current` is a
  human/status convenience only. Every spawned pane gets `DUET_CONFIG` and
  `DUET_SESSION` (unique session id) in its environment; the initiator's
  brief embeds the absolute session path. `duet-send` requires an explicit
  session (env or `--session`) and errors without one.
- **Membership fence:** send refuses when the caller's pane is not in the
  resolved session's roster, and names the session the pane actually belongs
  to in the error.
- **Foreign-payload fence:** payload headers carry `{session id, message id,
  term}`; the daemon quarantines payloads whose session id doesn't match and
  notifies the leader.
- **Init never touches another workdir's session.** One active session per
  workdir, enforced by a lock under `DUET_STATE_ROOT`; reap targets only the
  same-workdir predecessor. A session in workdir X must be unable to disturb
  routing for a live session in workdir Y.
- Smoke additions: cross-session send refusal; foreign-session payload
  quarantine; second-session init leaves the first session's routing intact.
Scope: fold into M3 (it is fencing work); document in M4.

## Resolved harness facts (verified locally by Codex, kimi 0.28.0)
- **Kimi:** boot banner `Welcome to Kimi Code!` (boot regex). Unattended flag
  is `--auto` (NOT `--yolo`, which may still ask). No pretrust step needed on
  this install; pass `--add-dir "$DUET_DIR"`. Bracketed paste renders verbatim
  in the idle composer and tail-probing works; Enter submits. Busy/interrupt
  behavior still needs the live smoke. `TMUX_PANE` and `DUET_SELF` survive
  into its `!` shell environment.
- **Claude worker:** `--dangerously-skip-permissions`, `--add-dir "$DUET_DIR"`,
  optionally `--name`. Never `--bare` (disables CLAUDE.md auto-discovery,
  which would defeat the durable brief).
- **Codex:** as today (trust block in config.toml, `-s`/`-a` flags,
  banner `OpenAI Codex`).

## Milestones (amended gates — replaces §Milestones above)
- **M1:** state schema (term/roster/naming/state-root), adapters, generic
  brief, safe init/reap/end skeleton, multi-pane boot + readiness only.
- **M2:** atomic enqueue, transcript locking, daemon with retry semantics +
  fair scheduling, send/hub enforcement, end drain barrier. Gate: 2-agent
  parity smoke + 3-agent concurrent delivery smoke.
- **M3:** watchdog, epoch/fencing/reroute/quarantine, promotion path,
  status/doctor. Gate: hard and soft failover smokes.
- **M4:** SKILL.md/README/brief polish, 0.2.0 manifests.

## Smoke protocol (amended — replaces §Smoke test protocol above)
- Isolation: `tmux -L duetsmoke -f /dev/null`, `DUET_STATE_ROOT=$(mktemp -d)`,
  temporary workdir, real `$HOME` (auth must remain available). Never touches
  the live session's `~/.duet/current`.
- Checks: all ready files; per-edge round-trips; 50+ concurrent enqueues to
  one recipient arrive serialized, intact, in order; unresolved/mismatched
  sender rejected; per-recipient FIFO preserved after a failed head; daemon
  kill/restart with queued work; pending worker reply survives promotion;
  stale old-term assignment quarantined; soft failover excludes incumbent and
  never re-promotes a demoted rank; promotion notice precedes other traffic;
  async DUET-END drains before teardown; re-init strips old anchors and never
  kills the caller pane. For real TUIs (all three harnesses): idle
  paste/submit plus busy interrupt. Teardown asserts daemon exited, anchors
  stripped, all *spawned* panes gone, caller pane alive.
- This is also the first live-TUI exercise of duet-common.sh's verified-send;
  fix what it reveals.
