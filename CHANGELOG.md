# Changelog

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
