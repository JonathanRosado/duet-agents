#!/usr/bin/env bash
# Validate one n-agent duet session. Read-only unless --reap targets a pinned,
# already-ended session.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-status.sh"

duet_doctor_usage(){
  echo "usage: duet-doctor.sh [--session <id|directory|duet.env>] [--reap]" >&2
}

DUET_DOCTOR_ISSUES=0
DUET_DOCTOR_ROSTER_VALID=""
duet_doctor_issue(){
  DUET_DOCTOR_ISSUES=$((DUET_DOCTOR_ISSUES + 1))
  printf 'ISSUE: %s\n' "$*"
}

duet_doctor_ok(){
  printf 'ok   : %s\n' "$*"
}

duet_doctor_check_roster(){
  local name harness pane recorded_pid rank spawned row_count=0 initiator_count=0
  DUET_DOCTOR_ROSTER_VALID=""
  if ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
    duet_doctor_issue "roster schema or tuple uniqueness is invalid"
    duet_doctor_issue "member liveness is UNKNOWN because the roster is invalid"
    return
  fi
  DUET_DOCTOR_ROSTER_VALID=1
  duet_doctor_ok "roster schema and tuple uniqueness checked"

  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    [ "$name" != name ] || continue
    row_count=$((row_count + 1))
    if [ "$name" = "${DUET_INITIATOR:-}" ]; then
      initiator_count=$((initiator_count + 1))
      if [ "$rank" != 0 ] || [ "$spawned" != 0 ] \
          || [ "$pane" != "${DUET_INITIATOR_PANE:-}" ]; then
        DUET_DOCTOR_ROSTER_VALID=""
        duet_doctor_issue "initiator row does not match config/rank/spawn invariants"
      fi
    elif [ "$spawned" != 1 ]; then
      DUET_DOCTOR_ROSTER_VALID=""
      duet_doctor_issue "peer '$name' is not marked spawned"
    fi

    duet_diag_pane_state "$pane" "$recorded_pid"
    case "$DUET_DIAG_LIVENESS" in
      UNKNOWN) duet_doctor_issue "member $name pane identity is UNKNOWN ($DUET_DIAG_ALIVE)" ;;
      DEAD) duet_doctor_issue "member $name is confirmed dead" ;;
    esac
    [ -f "$DUET_DIR/ready/$name" ] \
      || duet_doctor_issue "readiness marker missing for $name"
  done < "$DUET_DIR/roster.tsv"

  [ "$row_count" -le 5 ] || {
    DUET_DOCTOR_ROSTER_VALID=""
    duet_doctor_issue "roster exceeds the five-agent cap"
  }
  if [ "$initiator_count" -ne 1 ]; then
    DUET_DOCTOR_ROSTER_VALID=""
    duet_doctor_issue "roster does not contain exactly one configured initiator"
  fi
}

duet_doctor_check_queues(){
  local box queue file
  for box in "$DUET_DIR"/inbox/*; do
    [ -d "$box" ] || continue
    queue="$(basename "$box")"
    duet_roster_has_name "$queue" \
      || duet_doctor_issue "inbox exists for nonmember '$queue'"
    for file in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$file" ] || continue
      if ! duet_read_message "$file"; then
        duet_doctor_issue "invalid active payload: $file"
        continue
      fi
      [ "$DUET_MESSAGE_SESSION" = "$DUET_SESSION_ID" ] \
        || duet_doctor_issue "foreign active payload $(basename "$file") in inbox/$queue"
      case "$DUET_MESSAGE_ID" in
        "m-${DUET_SESSION_ID}-${queue}-"*) : ;;
        *) duet_doctor_issue "invalid message id $(basename "$file") in inbox/$queue" ;;
      esac
      duet_roster_has_name "$DUET_MESSAGE_SENDER" \
        || duet_doctor_issue "payload $(basename "$file") names nonmember sender"
      if [ "$DUET_MESSAGE_RECIPIENT" != "$queue" ] \
          && [ "$DUET_MESSAGE_RECIPIENT" != all ]; then
        duet_doctor_issue "payload $(basename "$file") redirects inbox/$queue"
      fi
    done
  done
}

duet_doctor_check_workdir_fence(){
  duet_diag_workdir_fence
  if [ -f "$DUET_DIR/.ended" ]; then
    [ "$DUET_DIAG_WORKDIR_FENCE" = released ] \
      || duet_doctor_issue "ended session workdir fence is $DUET_DIAG_WORKDIR_FENCE"
  else
    [ "$DUET_DIAG_WORKDIR_FENCE" = owned ] \
      || duet_doctor_issue "active session workdir fence is $DUET_DIAG_WORKDIR_FENCE"
  fi
}

duet_doctor_check_daemon(){
  if [ -f "$DUET_DIR/.ended" ]; then
    duet_daemon_alive \
      && duet_doctor_issue "ended session still has a live delivery daemon"
  elif duet_daemon_alive; then
    duet_doctor_ok "delivery daemon owns its PID and lifetime lock"
  else
    duet_doctor_issue "active session delivery daemon is not healthy"
  fi
}

duet_doctor_reap_ended(){
  local caller_socket="" caller_server="" caller_pane="" caller_pid=""
  local name harness pane recorded_pid rank spawned failed=""
  [ -f "$DUET_DIR/.ended" ] || {
    echo "duet: --reap refuses an active session; use duet-end.sh for orderly teardown." >&2
    return 2
  }
  if [ -z "${DUET_DOCTOR_ROSTER_VALID:-}" ] \
      || ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
    echo "duet: --reap refuses an invalid or ambiguous session roster." >&2
    return 9
  fi
  duet_tmux_server_matches || {
    echo "duet: --reap refuses because the recorded tmux server identity does not match." >&2
    return 2
  }
  if duet_capture_caller_identity; then
    caller_socket="$DUET_CALLER_SOCKET"
    caller_server="$DUET_CALLER_SERVER_PID"
    caller_pane="$DUET_CALLER_PANE"
    caller_pid="$DUET_CALLER_PANE_PID"
  fi

  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    spawned="${spawned%$'\r'}"
    [ "$name" != name ] || continue
    [ "$spawned" = 1 ] || continue
    duet_diag_pane_state "$pane" "$recorded_pid"
    [ "$DUET_DIAG_ALIVE" = yes ] || continue
    if [ "$caller_socket" = "${DUET_TMUX_SOCKET:-}" ] \
        && [ "$caller_server" = "${DUET_TMUX_SERVER_PID:-}" ] \
        && [ "$caller_pane" = "$pane" ] && [ "$caller_pid" = "$recorded_pid" ]; then
      printf 'skip : %s is the caller pane\n' "$name"
      continue
    fi
    printf 'reap : %s pane=%s pid=%s\n' "$name" "$pane" "$recorded_pid"
    _duet_tmux send-keys -t "$pane" C-c 2>/dev/null || true
    sleep 0.3
    duet_diag_pane_state "$pane" "$recorded_pid"
    if [ "$DUET_DIAG_ALIVE" = yes ] \
        && ! _duet_tmux kill-pane -t "$pane" 2>/dev/null; then
      printf 'fail : %s pane=%s could not be reaped\n' "$name" "$pane" >&2
      failed=1
    fi
  done < "$DUET_DIR/roster.tsv"
  [ -z "$failed" ]
}

duet_doctor_main(){
  local session_arg="" reap="" explicit_session=""
  if [ -n "${DUET_CONFIG:-}" ] || [ -n "${DUET_SESSION:-}" ]; then
    explicit_session=1
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session)
        [ "$#" -ge 2 ] || { duet_doctor_usage; return 2; }
        session_arg="$2"
        explicit_session=1
        shift 2
        ;;
      --reap) reap=1; shift ;;
      -h|--help) duet_doctor_usage; return 0 ;;
      *) duet_doctor_usage; echo "duet: unknown option '$1'" >&2; return 2 ;;
    esac
  done
  if [ -n "$reap" ] && [ -z "$explicit_session" ]; then
    echo "duet: --reap requires --session, DUET_CONFIG, or DUET_SESSION." >&2
    return 2
  fi

  duet_diag_load_session "$session_arg" 1 || return 1
  echo "=== duet doctor ==="
  duet_diag_print_summary
  duet_diag_print_roster
  echo
  echo "checks:"

  if duet_tmux_server_matches; then
    duet_doctor_ok "tmux server identity"
  else
    duet_doctor_issue "tmux server identity mismatch or server unavailable"
  fi
  duet_doctor_check_daemon
  duet_doctor_check_roster
  duet_doctor_check_queues
  duet_doctor_check_workdir_fence

  if [ "$DUET_DOCTOR_ISSUES" -eq 0 ]; then
    echo "doctor: healthy"
  else
    printf 'doctor: %s issue(s)\n' "$DUET_DOCTOR_ISSUES"
  fi
  if [ -n "$reap" ]; then
    duet_doctor_reap_ended || return $?
  fi
  [ "$DUET_DOCTOR_ISSUES" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  duet_doctor_main "$@"
fi
