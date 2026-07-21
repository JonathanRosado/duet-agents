# Changelog

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
