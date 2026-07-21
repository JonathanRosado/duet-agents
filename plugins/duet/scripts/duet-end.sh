#!/usr/bin/env bash
# Stop one tmux/bash duet session after atomically closing admission and draining
# every already-published queue item.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){ echo "usage: duet-end.sh [--session <id|dir|duet.env>]" >&2; }

session_arg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      session_arg="$2"
      shift 2
      ;;
    *) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
  esac
done

caller_session="${DUET_SESSION:-}"
duet_resolve_config "$session_arg" 0 || exit 1
cfg="$DUET_RESOLVED_CONFIG"
unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
unset DUET_SESSION DUET_SESSION_ID DUET_WORKDIR_KEY CODEX_PANE CODEX_PANE_PID
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || { echo "duet: could not load pinned session: $cfg" >&2; exit 1; }
duet_validate_loaded_session "$caller_session" "$cfg" || exit 1
if { [ -e "$DUET_DIR/roster.tsv" ] || [ -L "$DUET_DIR/roster.tsv" ]; } \
    && ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
  echo "duet: session roster is invalid; refusing teardown before any lifecycle mutation." >&2
  exit 9
fi

WORKDIR="$(cd "$WORKDIR" 2>/dev/null && pwd -P)" || {
  echo "duet: recorded workdir is unavailable; refusing teardown." >&2
  exit 9
}
DUET_STATE_ROOT="$(cd "$DUET_STATE_ROOT" 2>/dev/null && pwd -P)" || {
  echo "duet: recorded state root is unavailable; refusing teardown." >&2
  exit 9
}
computed_workdir_key="$(duet_workdir_key "$WORKDIR")" || exit 9
if [ -n "${DUET_WORKDIR_KEY:-}" ] && [ "$DUET_WORKDIR_KEY" != "$computed_workdir_key" ]; then
  echo "duet: recorded workdir key does not match the canonical workdir; refusing teardown." >&2
  exit 9
fi
DUET_WORKDIR_KEY="$computed_workdir_key"
mkdir -p "$DUET_STATE_ROOT/workdirs"
workdir_active="$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.active"
workdir_lock="$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.lock"
workdir_lock_held=""

release_workdir_lock(){
  [ -n "$workdir_lock_held" ] || return 0
  if duet_lock_release "$workdir_lock"; then
    workdir_lock_held=""
    return 0
  fi
  return 1
}

workdir_lock_attempts="${DUET_WORKDIR_LOCK_ATTEMPTS:-4000}"
case "$workdir_lock_attempts" in ''|*[!0-9]*) workdir_lock_attempts=4000;; esac
duet_lock_acquire "$workdir_lock" "$workdir_lock_attempts" || {
  echo "duet: another init/end owns the workdir transition lock." >&2
  exit 9
}
workdir_lock_held=1
trap 'release_workdir_lock 2>/dev/null || true' EXIT
trap 'exit 130' INT TERM

active_target="$(cat "$workdir_active" 2>/dev/null || true)"
owns_workdir=""
if [ -f "$workdir_active" ]; then
  [ "$active_target" != "$DUET_DIR" ] || owns_workdir=1
else
  # Compatibility for a pinned pre-A8 session. New sessions always have an
  # active record, so absence cannot identify a replacement.
  owns_workdir=1
fi

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
if [ -n "$owns_workdir" ]; then
  if ! duet_strip_session_anchors "$WORKDIR"; then
    echo "duet: could not strip session anchors; pane cleanup skipped." >&2
    exit 9
  fi
else
  echo "duet: a replacement session owns $WORKDIR; preserved its anchors and active index." >&2
fi
if duet_tmux_server_matches; then
  if ! duet_kill_spawned_panes "$DUET_DIR/roster.tsv" "$current_pane" \
      "${CODEX_PANE:-}" "${CODEX_PANE_PID:-}"; then
    echo "duet: invalid or ambiguous roster blocked recorded pane cleanup." >&2
    exit 9
  fi
else
  echo "duet: tmux server identity changed; skipped recorded pane cleanup." >&2
fi

if [ -n "$owns_workdir" ] && [ -f "$workdir_active" ] \
    && [ "$(cat "$workdir_active" 2>/dev/null || true)" = "$DUET_DIR" ]; then
  if ! rm -f "$workdir_active"; then
    echo "duet: session ended, but its active-workdir record could not be removed." >&2
    exit 9
  fi
fi

current_link="$DUET_STATE_ROOT/current"
if ! duet_lock_acquire "$DUET_STATE_ROOT/.current.lock" 80; then
  echo "duet: session ended, but the current-session lock is unavailable." >&2
  exit 9
fi
current_target="$(readlink "$current_link" 2>/dev/null || true)"
if [ "$current_target" = "$DUET_DIR" ] && ! rm -f "$current_link"; then
  duet_lock_release "$DUET_STATE_ROOT/.current.lock" 2>/dev/null || true
  echo "duet: session ended, but the current-session link could not be removed." >&2
  exit 9
fi
duet_lock_release "$DUET_STATE_ROOT/.current.lock" || {
  echo "duet: could not release the current-session lock." >&2
  exit 9
}

release_workdir_lock || {
  echo "duet: could not release the workdir transition lock." >&2
  exit 9
}
trap - EXIT INT TERM

echo "duet: ended. Transcript kept at $DUET_DIR/transcript.md"
