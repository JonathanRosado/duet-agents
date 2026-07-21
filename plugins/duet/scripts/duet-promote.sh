#!/usr/bin/env bash
# Hand leadership of a pinned duet session to one explicit live member.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: duet-promote.sh --to <roster-name> [--session <id|dir|duet.env>]" >&2
}

session_arg=""
session_arg_set=""
requested=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      session_arg="$2"
      session_arg_set=1
      shift 2
      ;;
    --to)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      requested="$2"
      shift 2
      ;;
    --force)
      usage
      echo "duet: --force is not supported; resolve uncertain delivery, then retry." >&2
      exit 2
      ;;
    *) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$requested" ] || { usage; echo "duet: --to is required for a manual handoff." >&2; exit 2; }
[ -z "$session_arg_set" ] || [ -n "$session_arg" ] \
  || { usage; echo "duet: --session may not be empty." >&2; exit 2; }

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
[ ! -f "$DUET_DIR/.ended" ] || { echo "duet: session has ended; refusing handoff." >&2; exit 1; }
[ -f "$DUET_DIR/roster.tsv" ] \
  || { echo "duet: session roster is missing; refusing handoff." >&2; exit 1; }
duet_validate_roster "$DUET_DIR/roster.tsv" \
  || { echo "duet: session roster is invalid; refusing handoff." >&2; exit 1; }
duet_daemon_alive || { echo "duet: delivery daemon is not alive; refusing handoff." >&2; exit 6; }
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
if [ -z "$pane_name" ] && [ -z "$session_arg_set" ]; then
  echo "duet: an external shell must pin the target with --session." >&2
  exit 7
fi

requested="$(duet_resolve_roster_name "$requested")" || {
  echo "duet: unknown or ambiguous handoff target." >&2
  exit 2
}

duet_lock_acquire "$DUET_DIR/.delivery.lock" 200 || {
  echo "duet: could not acquire the delivery/handoff fence." >&2
  exit 1
}
release_delivery(){ duet_lock_release "$DUET_DIR/.delivery.lock" 2>/dev/null || true; }
trap release_delivery EXIT
trap 'exit 130' INT TERM

[ ! -f "$DUET_DIR/.ended" ] && [ ! -f "$DUET_DIR/.draining" ] || {
  echo "duet: session ended or began draining while the handoff waited; refusing mutation." >&2
  exit 1
}
duet_daemon_alive || {
  echo "duet: delivery daemon stopped while the handoff waited; refusing mutation." >&2
  exit 6
}
duet_read_leader_state || exit 1
duet_validate_roster "$DUET_DIR/roster.tsv" || {
  echo "duet: session roster became invalid while the handoff waited; refusing mutation." >&2
  exit 1
}
expected_term="$DUET_CURRENT_TERM"
expected_leader="$DUET_CURRENT_LEADER"
if duet_promote_locked "$expected_term" "$expected_leader" \
    "MANUAL:${pane_name:-operator}" "$requested"; then
  rc=0
else
  rc=$?
fi
case "$rc" in
  0)
    echo "duet: handed off generation $DUET_PROMOTED_TERM to $DUET_PROMOTED_LEADER; notice queued before the leader update."
    ;;
  11)
    echo "duet: handoff blocked by uncertain delivery. Let the delivery daemon finish recovery, then retry." >&2
    exit 5
    ;;
  2) echo "duet: handoff lost the generation compare-and-swap; retry." >&2; exit 4 ;;
  3) echo "duet: target must be a live, noncurrent session member." >&2; exit 4 ;;
  4) echo "duet: durable manual handoff intent could not be verified." >&2; exit 4 ;;
  *) echo "duet: handoff transaction failed." >&2; exit "$rc" ;;
esac

release_delivery
trap - EXIT INT TERM
