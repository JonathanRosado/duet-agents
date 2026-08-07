# Changelog

## Unreleased

## 0.7.0 - 2026-08-07

Adds native harness session pairing and rejoin (Bash/tmux path only; the
Windows/PowerShell runtime is unchanged and its skill text says rejoin is
unavailable there), and fixes the delivery defect that silently stopped peers —
most visibly Kimi — from receiving messages.

Pairing and rejoin:

- Every run records `<session>/pairing.tsv`: each member's harness-native
  session id with provenance, pane tuple, workdir, durable repo id, and exact
  native config home. Spawned Claude workers are assigned `--session-id`;
  Codex and Kimi workers register the exact `SessionStart` id through
  per-pane nonce/name/session/pid-bound hooks. Repeated Codex, Kimi, or Claude
  workers (up to the four-worker cap) can start in any order without
  file-timing attribution. The initiator id comes only from
  `CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID`, Kimi's
  `${KIMI_SESSION_ID}` expansion, or an explicit argument—never a newest/mtime
  guess.
  `pairing.complete` publishes strictly last — after pairing.tsv and every
  home-namespaced `by-id` append — and only when every id resolves on disk and
  every spawned worker passes its exact banner/readiness/pane-pid gate. Staged
  TSV validation matches the immutable roster before any index changes. An
  interrupted, malformed, corrupt, or foreign newest record fails closed
  without rolling back to an older mapping.
- The skill's normal start command is `duet-rejoin.sh` (no harness words
  needed): lookup is keyed by the invoker's exact `(harness, native id)` —
  the last line of that id's append-only `by-id` index, validated as a whole;
  a corrupt or foreign newest entry fails closed and never rolls back to an
  older mapping. Reciprocal validation requires the candidate to still be the
  newest complete record for every member it names, so independent meshes in
  one repo coexist and a superseded mapping fails closed to a fresh,
  unpaired ensemble. A no-arg fallback starts the standard fresh
  `codex kimi` roster; explicit words pin an exact roster instead.
  The invoker's id determines its stable roster name, even when it was a
  worker. Prior ownership is fenced across complete, incomplete, and
  polluted-index runs: a live verified daemon or exact pane tuple refuses, and
  a cleanly ended run adopts only the invoker's own surviving pane. Every
  rejoin is a fresh transport run (new session dir, daemon, inboxes,
  message-id namespace); old queues are never replayed. Native homes are
  restored per member, restored `DUET_*` values are treated as stale, and a
  failed resume cannot supersede the last good map.
- Git repositories receive an untracked `.git/duet-agents-repo-id`, so
  pairings survive linked worktrees and a plain repository move. Kimi's
  current cross-workdir resume refusal is detected before launch and safely
  falls fresh; Duet never mutates Kimi's session store.
- The installer owns one inert Kimi `SessionStart` hook block, preserves
  foreign config and file mode, validates changes with `kimi doctor config`,
  and removes only its block on uninstall. Codex uses a launch-local hook and
  falls back to an unpaired but otherwise normal worker on older hookless
  builds. Kimi's exact workspace is pretrusted through an atomic,
  no-overwrite record before launch so its startup dialog cannot consume the
  Duet boot prompt. Observable worker session switches invalidate an existing
  complete pairing. `duet-resume.sh` remains the live-peer unblock operation.

Delivery fixes (Bash/tmux path; the Windows/PowerShell v4 path shipped in 0.6.0
already separates an unreadable composer from an empty one, but still fences a
recipient on its first ambiguous observation, still tolerates a redrawn
placeholder for Codex alone, and has no resume path; tracked in #9):

- The composer probe no longer reports "empty" when it simply could not read the
  cursor row. A pane that is still streaming a response relocates its composer
  row as output arrives, so the detector's before/capture/after cursor samples
  can disagree; measured at roughly 1 in 100 samples against a real Kimi TUI.
  That unreadable result was previously indistinguishable from a cleared
  composer, so the daemon recorded messages as **delivered that were still
  sitting unsent in the peer's composer**. The next message then found the
  leftover placeholder, stalled 30 times, and the peer was fenced as "composer
  wedged". Reads are now retried for a stable row and reported as indeterminate
  when no stable row is obtained, and an indeterminate read decides nothing.
- A cleared composer must be observed twice in a row before a message is scored
  as submitted, so a single blank frame mid-redraw cannot fake an accepted
  message.
- Collapsed-placeholder ownership tolerates a redraw for every harness. It was
  exact-match for all but Codex, so an ordinary renumber or reflow in a Claude
  or Kimi pane read as "someone else owns the composer" and blocked that peer.
  This is why Codex survived sessions in which Claude and Kimi were both fenced.
- An unconfirmed submission is no longer terminal. It is resumed enter-only on
  later passes — never repasted — and the recipient is fenced only after
  `DUET_AMBIGUOUS_LIMIT` (default 20) unresolved resumes. Resuming re-reads the
  composer, so the common case (the peer was merely busy) now resolves as a
  normal delivery.
- The landing budget is 40 clean checks instead of 20, and samples that could
  not be read do not consume it.
- Added `duet-resume.sh <name>`: returns a blocked but live and idle peer to the
  session, clearing both the block and the in-process counters that produced it.
  Delivery continues from that recipient's existing queue head. A blocked peer
  is no longer a reason to re-initialize the session.
- Every supported harness queues input while it is generating — verified against
  real Kimi (0.30.0 and 0.31.1) and Codex (0.144.6) TUIs. A peer being busy is
  therefore never a reason a message cannot be sent, and the code and briefs now
  say so.

## 0.6.0 - 2026-07-24

- Brought Windows/PowerShell + psmux to the v4 leaderless protocol: every live
  member can send directly to any other member or broadcast to `all`, with the
  same immutable roster, per-recipient FIFO queues, and immediate teardown as
  the Bash/tmux path.
- Removed the Windows leader, promotion, generation, restart-reconciliation,
  admission, and predecessor-reaping surfaces. A failed recipient is isolated
  as dead, blocked, or rejected without sinking the rest of the mesh.
- Added an authenticated short readiness helper, exact pane/daemon ancestry
  checks, isolated `CODEX_HOME`/`KIMI_CODE_HOME` propagation, and tuple-bound
  handling of Claude's worktree trust prompt.
- Hardened Windows delivery against concurrent lock reads, uncertain TCP
  acknowledgments, stale psmux environments, tiled-pane boot redraws, and
  Claude's status-row collapsed-paste rendering. An uncertain write is never
  repeated; only a visibly owned composer can receive the Enter continuation.
- Added seven deterministic PowerShell suites plus a real psmux smoke covering
  Claude 2.1.218, Codex 0.144.6, and Kimi 0.29.1. Claude and Codex executed
  readiness/model tasks; Kimi's actual TUI passed boot, direct, broadcast, and
  peer-delivery transport while its local model remained unconfigured.

## 0.5.0 - 2026-07-23

- Added the `npx duet-agents` installer (`install` / `update` / `uninstall`) so
  Codex CLI and Kimi CLI are first-class install targets and session initiators
  alongside Claude Code, on macOS/Linux and Windows.
- Claude Code keeps its native marketplace path (the installer drives
  `claude plugin marketplace add/install/update` for you). Codex reads the
  skill `~/.agents/skills/duet` (`$duet` / `/skills`); Kimi reads
  `$KIMI_CODE_HOME/skills/duet` (`/skill:duet`). Both share a versioned,
  immutable runtime under `~/.duet/plugin/<version>` — the installer never
  modifies or deletes a runtime, so live sessions stay pinned by construction.
- The installer validates every canonicalized destination (symlink aliases
  cannot bypass the no-overlap and source-tree rules, and paths with
  shell-significant characters are rejected before rendering), writes ownership
  markers, verifies a runtime's payload before reusing it, and never adopts,
  overwrites, or deletes a pre-existing foreign directory.
- The session briefs (Bash and PowerShell) no longer assume the initiator is
  `claude`; they render the actual initiator roster name, and `duet-init.ps1`
  gained the same explicit/inferred initiator-harness support as the Bash path.
- Added an installer gate to the Bash test suite.

## 0.4.0 - 2026-07-23

- Replaced the Bash leader hub with a leaderless, any-to-any mesh and removed
  leadership, election, `duet-promote`, generation, and term machinery.
- Fixed Kimi's collapsed `[paste #N +M lines]` delivery and made Claude, Codex,
  and Kimi composer-marker detection cursor-row scoped.
- Replaced the roughly 1,120-line recovery daemon with a roughly 380-line
  delivery core: paste once, retry only Enter after observed landing, and never
  repaste.
- Guaranteed a terminal delivery outcome — delivered, or recipient-scoped
  dead, blocked, or rejected — so one failed peer never sinks the mesh.
- Removed admission/drain/`DUET-END`, `~/.duet/current`, the one-session-per-
  workdir lock, predecessor reaping, and foreign-payload quarantine. Multiple
  sessions can coexist in one repository through separate worktrees.
- Removed crash recovery by design: a crashed session is discarded and
  re-initialized instead of replayed or repaired.
- Ships the v4 Bash/tmux path on macOS and Linux; Windows/PowerShell remains on
  the previous protocol, with parity planned next.
- Validated end to end with real Claude, Codex, and Kimi TUIs.

## 0.3.1 - 2026-07-21

- Validated the explicit-handoff protocol end to end on macOS with real
  Claude, Codex, and Kimi TUIs.
- Hardened the Bash/tmux path against ambiguous rosters, malformed or
  NUL-tainted envelopes, and unbounded persisted numeric state.
- Made invalid session state fail closed before routing, delivery, handoff, or
  teardown mutations.
- Fixed CRLF spawned-pane cleanup and propagated pane-reaping failures.

## 0.3.0 - 2026-07-21

- Replaced automatic leader election with explicit operator handoff to a named
  live member.
- Kept generation, stale-leader, session, and uncertain-composer fences.
- Added a durable MANUAL handoff envelope so the daemon can finish only the
  exact operator choice after a crash.
- Removed watchdog counters, ranked successor selection, `NONE` leadership,
  no-successor state, and permanent failed-leader exclusions.
- Added DEAD versus UNKNOWN status reporting and pinned recovery commands.
- Kept Bash/tmux and PowerShell/psmux behavior in parity.

## 0.2.1 - 2026-07-20

- Added the Windows/psmux implementation of the queued ensemble protocol.

## 0.2.0 - 2026-07-20

- Added the queued n-agent Bash/tmux protocol and session lifecycle.
