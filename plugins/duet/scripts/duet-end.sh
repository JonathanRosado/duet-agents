#!/usr/bin/env bash
# Stop one tmux/bash duet session after atomically closing admission and draining
# every already-published queue item.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

state_root="${DUET_STATE_ROOT:-$HOME/.duet}"
cfg="${DUET_CONFIG:-$state_root/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || { echo "duet: no active session"; exit 0; }

current_pane="${TMUX_PANE:-}"
delivery_fence=""
if [ ! -f "$DUET_DIR/.ended" ]; then
  admission="$DUET_DIR/.admission.lock"
  duet_lock_acquire "$admission" || { echo "duet: could not close message admission." >&2; exit 9; }
  if ! : > "$DUET_DIR/.draining"; then
    duet_lock_release "$admission" || true
    echo "duet: could not publish the draining marker." >&2
    exit 9
  fi
  duet_lock_release "$admission" || true

  drain_timeout="${DUET_DRAIN_TIMEOUT:-30}"
  case "$drain_timeout" in ''|*[!0-9]*) drain_timeout=30;; esac
  drained=""
  for _ in $(seq 1 "$((drain_timeout * 10 + 1))"); do
    pending="$(duet_pending_count)"
    notices="$(duet_notice_obligation_count)"
    if [ "$pending" -eq 0 ] && [ "$notices" -eq 0 ]; then
      delivery_attempts=2
      duet_daemon_alive || delivery_attempts=22
      if duet_lock_acquire "$DUET_DIR/.delivery.lock" "$delivery_attempts" 2>/dev/null; then
        if [ "$(duet_pending_count)" -eq 0 ] \
            && [ "$(duet_notice_obligation_count)" -eq 0 ]; then
          delivery_fence=1
          drained=1
          break
        fi
        duet_lock_release "$DUET_DIR/.delivery.lock" || true
      fi
    fi
    duet_daemon_alive || break
    sleep 0.1
  done
  if [ -z "$drained" ]; then
    pending="$(duet_pending_count)"
    notices="$(duet_notice_obligation_count)"
    if duet_lock_acquire "$admission"; then
      rm -f "$DUET_DIR/.draining"
      duet_lock_release "$admission" 2>/dev/null || true
    else
      echo "duet: could not reopen admission; draining marker remains as a safety fence." >&2
    fi
    echo "duet: drain timed out with $pending pending message(s) and $notices notice obligation(s); session left running." >&2
    exit 9
  fi

  if ! : > "$DUET_DIR/.ended"; then
    [ -z "$delivery_fence" ] || duet_lock_release "$DUET_DIR/.delivery.lock" || true
    echo "duet: could not publish the ended marker; session left intact." >&2
    exit 9
  fi
  [ -z "$delivery_fence" ] || duet_lock_release "$DUET_DIR/.delivery.lock" || true
fi
duet_stop_daemon "$DUET_DIR" 50 || {
  echo "duet: daemon did not stop; session left intact for diagnosis." >&2
  exit 9
}
if ! duet_lock_acquire "$DUET_DIR/.daemon.lock" 22 2>/dev/null; then
  echo "duet: could not prove the delivery daemon is fenced; teardown stopped." >&2
  exit 9
fi
if ! rm -f "$DUET_DIR/daemon.pid"; then
  duet_lock_release "$DUET_DIR/.daemon.lock" 2>/dev/null || true
  echo "duet: could not remove stale daemon.pid; teardown stopped." >&2
  exit 9
fi
if ! duet_lock_release "$DUET_DIR/.daemon.lock"; then
  echo "duet: could not release the daemon finalization fence; teardown stopped." >&2
  exit 9
fi
if ! duet_strip_session_anchors "${WORKDIR:-}"; then
  echo "duet: could not strip session anchors; pane cleanup skipped." >&2
  exit 9
fi
if duet_tmux_server_matches; then
  duet_kill_spawned_panes "$DUET_DIR/roster.tsv" "$current_pane" "${CODEX_PANE:-}"
else
  echo "duet: tmux server identity changed; skipped recorded pane cleanup." >&2
fi

current_link="$DUET_STATE_ROOT/current"
current_target="$(readlink "$current_link" 2>/dev/null || true)"
if [ "$current_target" = "$DUET_DIR" ] && ! rm -f "$current_link"; then
  echo "duet: session ended, but the current-session link could not be removed." >&2
  exit 9
fi

echo "duet: ended. Transcript kept at $DUET_DIR/transcript.md"
