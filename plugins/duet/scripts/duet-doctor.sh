#!/usr/bin/env bash
# Check the live basics for exactly one explicitly pinned duet session.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-status.sh"

duet_doctor_usage(){
  echo "usage: duet-doctor.sh --session /absolute/session/duet.env" >&2
}

DUET_DOCTOR_ISSUES=0
duet_doctor_issue(){
  DUET_DOCTOR_ISSUES=$((DUET_DOCTOR_ISSUES + 1))
  printf 'ISSUE: %s\n' "$*"
}

duet_doctor_ok(){
  printf 'ok   : %s\n' "$*"
}

duet_doctor_main(){
  local session_arg="" name harness pane recorded_pid rank spawned
  local ended=""
  DUET_DOCTOR_ISSUES=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session)
        [ "$#" -ge 2 ] || { duet_doctor_usage; return 2; }
        [ -z "$session_arg" ] || {
          echo "duet: --session may be specified only once." >&2
          return 2
        }
        session_arg="$2"
        shift 2
        ;;
      -h|--help) duet_doctor_usage; return 0 ;;
      *) duet_doctor_usage; echo "duet: unknown option '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$session_arg" ] || { duet_doctor_usage; return 2; }

  duet_diag_load_session "$session_arg" || return 1
  echo "=== duet doctor ==="
  duet_diag_print_summary
  duet_diag_print_roster || true
  echo
  echo "checks:"

  if duet_tmux_server_matches; then
    duet_doctor_ok "tmux server identity"
  else
    duet_doctor_issue "tmux server identity mismatch or server unavailable"
  fi
  if ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
    duet_doctor_issue "roster schema or member identities are invalid"
    printf 'doctor: %s issue(s)\n' "$DUET_DOCTOR_ISSUES"
    return 1
  fi
  duet_doctor_ok "roster schema and member identities"

  [ ! -f "$DUET_DIR/.ended" ] || ended=1
  if [ -n "$ended" ]; then
    duet_daemon_alive \
      && duet_doctor_issue "ended session still has a live delivery daemon"
  elif duet_daemon_alive; then
    duet_doctor_ok "delivery daemon"
  else
    duet_doctor_issue "active session delivery daemon is not alive"
  fi

  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    [ "$name" != name ] || continue
    [ -n "$name" ] || continue
    duet_diag_pane_state "$pane" "$recorded_pid"
    if [ -z "$ended" ] && [ "$DUET_DIAG_LIVENESS" != alive ]; then
      duet_doctor_issue "member $name pane is $DUET_DIAG_LIVENESS"
    fi
    if [ -z "$ended" ] && [ ! -f "$DUET_DIR/ready/$name" ]; then
      duet_doctor_issue "readiness marker missing for $name"
    fi
    [ ! -f "$DUET_DIR/dead/$name" ] \
      || duet_doctor_issue "recipient $name was marked dead"
    [ ! -f "$DUET_DIR/blocked/$name" ] \
      || duet_doctor_issue "recipient $name is blocked after ambiguous delivery"
  done < "$DUET_DIR/roster.tsv"

  if [ "$DUET_DOCTOR_ISSUES" -eq 0 ]; then
    echo "doctor: healthy"
    return 0
  fi
  printf 'doctor: %s issue(s)\n' "$DUET_DOCTOR_ISSUES"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  duet_doctor_main "$@"
fi
