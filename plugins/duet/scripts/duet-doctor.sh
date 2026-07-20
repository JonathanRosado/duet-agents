#!/usr/bin/env bash
# Validate one n-agent duet session. Read-only unless --reap is explicitly used
# against an explicitly pinned, already-ended session.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the status script's session validation and display helpers. Its main is
# guarded, so sourcing it has no diagnostic side effects.
# shellcheck disable=SC1091
. "$SELF_DIR/duet-status.sh"

duet_doctor_usage(){
  echo "usage: duet-doctor.sh [--session <id|directory|duet.env>] [--reap]" >&2
}

DUET_DOCTOR_ISSUES=0
duet_doctor_issue(){
  DUET_DOCTOR_ISSUES=$((DUET_DOCTOR_ISSUES + 1))
  printf 'ISSUE: %s\n' "$*"
}

duet_doctor_ok(){
  printf 'ok   : %s\n' "$*"
}

duet_doctor_check_roster(){
  local expected_header header duplicates name harness pane recorded_pid rank spawned
  local current_leaders=0
  expected_header=$'name\tharness\tpane_id\tpane_pid\trank\tspawned'
  header="$(sed -n '1p' "$DUET_DIR/roster.tsv" 2>/dev/null)"
  if [ "$header" = "$expected_header" ]; then
    duet_doctor_ok "roster header"
  else
    duet_doctor_issue "invalid roster header"
  fi

  duplicates="$(awk -F '\t' '
    NR > 1 {
      if (seen_name[$1]++) print "duplicate name " $1
      if (seen_pane[$3]++) print "duplicate pane " $3
      if (seen_rank[$5]++) print "duplicate rank " $5
    }
  ' "$DUET_DIR/roster.tsv" 2>/dev/null)"
  while IFS= read -r duplicate; do
    [ -n "$duplicate" ] || continue
    duet_doctor_issue "$duplicate in roster"
  done <<< "$duplicates"

  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    [ "$name" != name ] || continue
    [ -n "$name" ] || continue
    case "$name" in *[!A-Za-z0-9_-]*) duet_doctor_issue "invalid roster name '$name'" ;; esac
    case "$rank" in ''|*[!0-9]*) duet_doctor_issue "invalid rank '$rank' for $name" ;; esac
    case "$spawned" in 0|1) : ;; *) duet_doctor_issue "invalid spawned flag '$spawned' for $name" ;; esac
    [ -n "$harness" ] || duet_doctor_issue "missing harness for $name"
    [ -n "$pane" ] || duet_doctor_issue "missing pane for $name"
    [ "$name" != "$DUET_CURRENT_LEADER" ] || current_leaders=$((current_leaders + 1))

    duet_diag_pane_state "$pane" "$recorded_pid"
    if [ "$name" = "$DUET_CURRENT_LEADER" ]; then
      [ "$DUET_DIAG_ALIVE" = yes ] \
        || duet_doctor_issue "current leader $name is not alive with its recorded pane PID ($DUET_DIAG_ALIVE)"
    elif [ "$DUET_DIAG_ALIVE" != yes ] \
        && [ ! -f "$DUET_DIR/failed-leaders/$name" ]; then
      duet_doctor_issue "eligible member $name is not alive with its recorded pane PID ($DUET_DIAG_ALIVE)"
    fi
    if [ "$name" = "$DUET_CURRENT_LEADER" ] \
        && [ -f "$DUET_DIR/failed-leaders/$name" ]; then
      duet_doctor_issue "current leader $name is permanently excluded in failed-leaders/"
    fi
    if [ ! -f "$DUET_DIR/ready/$name" ] \
        && [ ! -f "$DUET_DIR/failed-leaders/$name" ]; then
      duet_doctor_issue "readiness marker missing for $name"
    fi
  done < "$DUET_DIR/roster.tsv"

  if [ "$DUET_CURRENT_LEADER" = NONE ]; then
    duet_doctor_issue "leadership is in the no-live-successor state"
  elif [ "$current_leaders" -ne 1 ]; then
    duet_doctor_issue "leader '$DUET_CURRENT_LEADER' is not represented exactly once in the roster"
  fi
}

duet_doctor_check_failed_leaders(){
  local file name failed_term
  [ -d "$DUET_DIR/failed-leaders" ] || return 0
  for file in "$DUET_DIR"/failed-leaders/*; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    if ! duet_roster_has_name "$name"; then
      duet_doctor_issue "failed-leader marker names nonmember '$name'"
      continue
    fi
    failed_term="$(awk -F '\t' '$1 == "term" { print $2; exit }' "$file" 2>/dev/null)"
    case "$failed_term" in
      ''|*[!0-9]*) duet_doctor_issue "failed-leader marker for $name has invalid term" ;;
    esac
  done
}

duet_doctor_check_watchdog(){
  duet_diag_read_watchdog
  if [ "$DUET_DIAG_WATCHDOG_COUNT" = missing ]; then
    [ -f "$DUET_DIR/.ended" ] \
      || duet_doctor_issue "watchdog state is missing"
    return
  fi
  [ "$DUET_DIAG_WATCHDOG_COUNT" != invalid ] \
    || duet_doctor_issue "watchdog count is invalid"
  [ "$DUET_DIAG_WATCHDOG_SESSION" = "$DUET_SESSION_ID" ] \
    || duet_doctor_issue "watchdog session does not match $DUET_SESSION_ID"
  [ "$DUET_DIAG_WATCHDOG_TERM" = "$DUET_CURRENT_TERM" ] \
    || duet_doctor_issue "watchdog term does not match leadership term"
  [ "$DUET_DIAG_WATCHDOG_LEADER" = "$DUET_CURRENT_LEADER" ] \
    || duet_doctor_issue "watchdog leader does not match leadership state"
}

duet_doctor_check_no_successor(){
  local file="$DUET_DIR/no-successor" record_session record_term
  if [ "$DUET_CURRENT_LEADER" = NONE ]; then
    if [ ! -f "$file" ]; then
      duet_doctor_issue "leader is NONE but no-successor record is missing"
      return
    fi
  elif [ -f "$file" ]; then
    duet_doctor_issue "stale no-successor record exists while leader is $DUET_CURRENT_LEADER"
    return
  else
    return
  fi
  record_session="$(awk -F '\t' '$1 == "session" { print $2; exit }' "$file" 2>/dev/null)"
  record_term="$(awk -F '\t' '$1 == "term" { print $2; exit }' "$file" 2>/dev/null)"
  [ "$record_session" = "$DUET_SESSION_ID" ] \
    || duet_doctor_issue "no-successor record has a foreign session"
  [ "$record_term" = "$DUET_CURRENT_TERM" ] \
    || duet_doctor_issue "no-successor record term does not match leadership term"
}

duet_doctor_check_queues(){
  local box queue file promotion_count=0
  for box in "$DUET_DIR"/inbox/*; do
    [ -d "$box" ] || continue
    queue="$(basename "$box")"
    case "$queue" in
      leader|promotions) : ;;
      *) duet_roster_has_name "$queue" \
           || duet_doctor_issue "inbox exists for nonmember '$queue'" ;;
    esac
    for file in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$file" ] || continue
      if ! duet_read_message "$file"; then
        duet_doctor_issue "invalid active payload: $file"
        continue
      fi
      [ "$DUET_MESSAGE_SESSION" = "$DUET_SESSION_ID" ] \
        || duet_doctor_issue "foreign active payload $(basename "$file") in inbox/$queue"
      case "$DUET_MESSAGE_ID" in
        "m-${DUET_SESSION_ID}-"*) : ;;
        *) duet_doctor_issue "foreign message id $(basename "$file") in inbox/$queue" ;;
      esac
      case "$queue" in
        leader)
          [ "$DUET_MESSAGE_RECIPIENT" = leader ] \
            || duet_doctor_issue "leader queue payload $(basename "$file") redirects to $DUET_MESSAGE_RECIPIENT"
          ;;
        promotions) : ;;
        *)
          [ "$DUET_MESSAGE_RECIPIENT" = "$queue" ] \
            || duet_doctor_issue "named queue payload $(basename "$file") redirects to $DUET_MESSAGE_RECIPIENT"
          ;;
      esac
      if [ "$queue" = promotions ]; then
        promotion_count=$((promotion_count + 1))
        [ "$DUET_MESSAGE_TERM" = "$DUET_CURRENT_TERM" ] \
          || duet_doctor_issue "pending promotion $(basename "$file") has stale/future term $DUET_MESSAGE_TERM"
        [ "$DUET_MESSAGE_RECIPIENT" = "$DUET_CURRENT_LEADER" ] \
          || duet_doctor_issue "pending promotion $(basename "$file") targets $DUET_MESSAGE_RECIPIENT, not current leader"
      fi
    done
  done
  [ "$promotion_count" -le 1 ] \
    || duet_doctor_issue "$promotion_count simultaneous promotion obligations are active"
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

# --reap is intentionally not an orphan scanner. It can only finish cleanup of
# panes explicitly recorded as spawned by the explicitly pinned, ended session.
duet_doctor_reap_ended(){
  local caller_socket="" caller_server="" caller_pane="" caller_pid=""
  local name harness pane recorded_pid rank spawned
  [ -f "$DUET_DIR/.ended" ] || {
    echo "duet: --reap refuses an active session; use duet-end.sh for an orderly drain." >&2
    return 2
  }
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
    [ "$DUET_DIAG_ALIVE" = yes ] \
      && _duet_tmux kill-pane -t "$pane" 2>/dev/null || true
  done < "$DUET_DIR/roster.tsv"
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
    echo "duet: --reap requires --session, DUET_CONFIG, or DUET_SESSION; ambient current is forbidden." >&2
    return 2
  fi
  duet_diag_load_session "$session_arg" 1 || return 1
  duet_read_leader_state || return 1

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
  duet_doctor_check_failed_leaders
  duet_doctor_check_watchdog
  duet_doctor_check_no_successor
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
