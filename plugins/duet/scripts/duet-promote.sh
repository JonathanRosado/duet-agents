#!/usr/bin/env bash
# Manually advance a pinned duet session through the same fenced promotion
# transaction used by the delivery watchdog.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: duet-promote.sh [--to <roster-name>] [--session <id|dir|duet.env>]" >&2
}

session_arg=""
requested=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      session_arg="$2"
      shift 2
      ;;
    --to)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      requested="$2"
      shift 2
      ;;
    --force)
      usage
      echo "duet: --force is not supported; failed members remain ineligible." >&2
      exit 2
      ;;
    *) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
  esac
done

caller_session_pin="${DUET_SESSION:-}"
caller_self="${DUET_SELF:-}"
duet_capture_caller_identity 2>/dev/null || true
saved_caller_socket="${DUET_CALLER_SOCKET:-}"
saved_caller_server_pid="${DUET_CALLER_SERVER_PID:-}"
saved_caller_pane="${DUET_CALLER_PANE:-}"
saved_caller_pane_pid="${DUET_CALLER_PANE_PID:-}"

duet_resolve_config "$session_arg" 0 || exit 1
cfg="$DUET_RESOLVED_CONFIG"
unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
unset DUET_SESSION DUET_SESSION_ID DUET_INITIATOR DUET_INITIATOR_PANE DUET_WORKDIR_KEY
# shellcheck disable=SC1090
. "$cfg" || { echo "duet: could not load pinned session: $cfg" >&2; exit 1; }
DUET_CONFIG="$cfg"
duet_validate_loaded_session "$caller_session_pin" "$cfg" || exit 7
[ ! -f "$DUET_DIR/.ended" ] || { echo "duet: session has ended; refusing promotion." >&2; exit 1; }
duet_daemon_alive || { echo "duet: delivery daemon is not alive; refusing promotion." >&2; exit 6; }
duet_read_leader_state || exit 1

pane_name=""
actual_session=""
if duet_caller_roster_name; then
  pane_name="$DUET_CALLER_NAME"
else
  DUET_CALLER_SOCKET="$saved_caller_socket"
  DUET_CALLER_SERVER_PID="$saved_caller_server_pid"
  DUET_CALLER_PANE="$saved_caller_pane"
  DUET_CALLER_PANE_PID="$saved_caller_pane_pid"
  actual_session="$(duet_find_caller_session "$DUET_STATE_ROOT" 2>/dev/null || true)"
fi
if [ -n "$pane_name" ] && [ -n "$caller_self" ] && [ "$pane_name" != "$caller_self" ]; then
  echo "duet: identity mismatch: pane is '$pane_name' but DUET_SELF is '$caller_self'." >&2
  exit 7
fi
if [ -z "$pane_name" ] && [ -n "$actual_session" ]; then
  echo "duet: caller belongs to '$actual_session', not pinned session '$DUET_SESSION_ID'; override refused." >&2
  exit 7
fi
if [ -z "$pane_name" ] && [ -z "${DUET_ALLOW_PROMOTE_OVERRIDE:-}" ]; then
  echo "duet: manual promotion requires the current leader pane or DUET_ALLOW_PROMOTE_OVERRIDE=1 outside tmux." >&2
  exit 7
fi
if [ -n "$pane_name" ] && [ "$pane_name" != "$DUET_CURRENT_LEADER" ]; then
  echo "duet: only current leader '$DUET_CURRENT_LEADER' may promote; caller is '$pane_name'." >&2
  exit 7
fi

if [ -n "$requested" ]; then
  requested="$(duet_resolve_roster_name "$requested")" || {
    echo "duet: unknown or ambiguous promotion target." >&2
    exit 2
  }
fi

duet_lock_acquire "$DUET_DIR/.delivery.lock" 200 || {
  echo "duet: could not acquire the delivery/promotion fence." >&2
  exit 1
}
release_delivery(){ duet_lock_release "$DUET_DIR/.delivery.lock" 2>/dev/null || true; }
trap release_delivery EXIT
trap 'exit 130' INT TERM

[ ! -f "$DUET_DIR/.ended" ] && [ ! -f "$DUET_DIR/.draining" ] || {
  echo "duet: session ended or began draining while promotion waited; refusing mutation." >&2
  exit 1
}
duet_daemon_alive || {
  echo "duet: delivery daemon stopped while promotion waited; refusing mutation." >&2
  exit 6
}
duet_read_leader_state || exit 1
expected_term="$DUET_CURRENT_TERM"
expected_leader="$DUET_CURRENT_LEADER"
if [ -n "$pane_name" ] && [ "$pane_name" != "$expected_leader" ]; then
  echo "duet: leadership changed while waiting for the fence; retry from '$expected_leader'." >&2
  exit 7
fi
if duet_promote_locked "$expected_term" "$expected_leader" \
    "MANUAL:${pane_name:-admin}" "$requested"; then
  rc=0
else
  rc=$?
fi
case "$rc" in
  0)
    echo "duet: promoted term $DUET_PROMOTED_TERM leader $DUET_PROMOTED_LEADER; notice queued first."
    ;;
  10)
    echo "duet: term advanced to $DUET_PROMOTED_TERM with no live eligible successor (leader NONE)." >&2
    ;;
  11)
    echo "duet: promotion deferred until an uncertain composer is resolved by the delivery daemon." >&2
    exit 5
    ;;
  2) echo "duet: promotion lost the term compare-and-swap; retry." >&2; exit 4 ;;
  3) echo "duet: requested successor is dead, excluded, or the incumbent." >&2; exit 4 ;;
  *) echo "duet: promotion transaction failed." >&2; exit "$rc" ;;
esac

release_delivery
trap - EXIT INT TERM
