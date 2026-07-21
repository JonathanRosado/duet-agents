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
DUET_DOCTOR_ROSTER_VALID=""
duet_doctor_issue(){
  DUET_DOCTOR_ISSUES=$((DUET_DOCTOR_ISSUES + 1))
  printf 'ISSUE: %s\n' "$*"
}

duet_doctor_ok(){
  printf 'ok   : %s\n' "$*"
}

duet_doctor_roster_diagnostics(){
  LC_ALL=C awk '
    function issue(message) { print message }
    function int32(value, positive, normalized) {
      if (value !~ /^[0-9]+$/) return 0
      normalized=value
      sub(/^0+/, "", normalized)
      if (normalized == "") normalized="0"
      if (positive && normalized == "0") return 0
      if (length(normalized) > 10 \
          || (length(normalized) == 10 \
              && ("x" normalized) > "x2147483647")) return 0
      return 1
    }
    BEGIN {
      expected="name\tharness\tpane_id\tpane_pid\trank\tspawned"
      cr=sprintf("%c", 13)
    }
    {
      line=$0
      if (substr(line, length(line), 1) == cr) {
        line=substr(line, 1, length(line) - 1)
      }
      if (line == "") next
      logical++
      if (logical == 1) {
        header_ok=(line == expected)
        if (!header_ok) issue("invalid roster header")
        next
      }
      if (!header_ok) next
      rows++
      count=split(line, column, "\t")
      if (count != 6) {
        issue("roster row " NR " does not have exactly six fields")
        next
      }
      name=column[1]
      harness=column[2]
      pane=column[3]
      pane_pid=column[4]
      rank=column[5]
      spawned=column[6]
      if (name !~ /^[A-Za-z0-9_-]+$/) {
        issue("roster row " NR " has an invalid name")
      }
      if (harness != "claude" && harness != "codex" && harness != "kimi") {
        issue("member \047" name "\047 has unsupported harness \047" harness "\047")
      }
      if (pane !~ /^%[0-9]+$/) {
        issue("member \047" name "\047 has invalid pane id \047" pane "\047")
      }
      if (!int32(pane_pid, 1)) {
        issue("member \047" name "\047 has invalid pane pid \047" pane_pid "\047")
      }
      if (!int32(rank, 0)) {
        issue("member \047" name "\047 has invalid rank \047" rank "\047")
      }
      if (spawned != "0" && spawned != "1") {
        issue("member \047" name "\047 has invalid spawned flag \047" spawned "\047")
      }
      if (name in seen_name) issue("duplicate roster name \047" name "\047")
      else seen_name[name]=1
      if (pane in seen_pane) issue("duplicate roster pane \047" pane "\047")
      else seen_pane[pane]=1
      if (pane_pid in seen_pid) issue("duplicate roster pane pid \047" pane_pid "\047")
      else seen_pid[pane_pid]=1
      if (rank in seen_rank) issue("duplicate roster rank \047" rank "\047")
      else seen_rank[rank]=1
    }
    END {
      if (logical == 0) issue("invalid roster header")
      else if (header_ok && rows == 0) issue("roster has no member rows")
      if (header_ok && rows > 5) issue("roster exceeds the five-agent cap")
    }
  ' "$DUET_DIR/roster.tsv" 2>/dev/null
}

duet_doctor_check_roster(){
  local diagnostics diagnostic schema_valid="" name harness pane recorded_pid rank spawned
  local current_leaders=0 initiator_count=0 row_count=0
  DUET_DOCTOR_ROSTER_VALID=""
  if duet_validate_roster "$DUET_DIR/roster.tsv"; then
    schema_valid=1
    DUET_DOCTOR_ROSTER_VALID=1
  fi
  diagnostics="$(duet_doctor_roster_diagnostics)"
  if [ -n "$diagnostics" ]; then
    DUET_DOCTOR_ROSTER_VALID=""
    while IFS= read -r diagnostic; do
      [ -n "$diagnostic" ] && duet_doctor_issue "$diagnostic"
    done <<< "$diagnostics"
  elif [ -z "$schema_valid" ]; then
    duet_doctor_issue "roster schema or tuple uniqueness is invalid"
  fi

  # Structural ambiguity is identity uncertainty, not evidence that any tuple
  # is dead. Do not probe or print per-member liveness from an invalid roster.
  [ -n "$schema_valid" ] || {
    duet_doctor_issue "member liveness is UNKNOWN because the roster is invalid"
    return
  }

  duet_doctor_ok "roster schema and tuple uniqueness checked"
  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    row_count=$((row_count + 1))
    [ "$name" != "$DUET_CURRENT_LEADER" ] || current_leaders=$((current_leaders + 1))
    if [ "$name" = "${DUET_INITIATOR:-}" ]; then
      initiator_count=$((initiator_count + 1))
      if [ "$rank" != 0 ] || [ "$spawned" != 0 ] \
          || [ "$pane" != "${DUET_INITIATOR_PANE:-}" ]; then
        DUET_DOCTOR_ROSTER_VALID=""
        duet_doctor_issue "initiator row does not match config/rank/spawn invariants"
      fi
    elif [ "$spawned" != 1 ]; then
      DUET_DOCTOR_ROSTER_VALID=""
      duet_doctor_issue "worker '$name' is not marked spawned"
    fi

    duet_diag_pane_state "$pane" "$recorded_pid"
    if [ "$DUET_DIAG_LIVENESS" = UNKNOWN ]; then
      duet_doctor_issue "member $name pane identity is UNKNOWN ($DUET_DIAG_ALIVE)"
    elif [ "$DUET_DIAG_LIVENESS" = DEAD ]; then
      if [ "$name" = "$DUET_CURRENT_LEADER" ]; then
        duet_doctor_issue "leader $name is confirmed dead; an operator must choose a manual handoff target"
      else
        duet_doctor_issue "member $name is confirmed dead"
      fi
    fi
    if [ ! -f "$DUET_DIR/ready/$name" ]; then
      duet_doctor_issue "readiness marker missing for $name"
    fi
  done < <(LC_ALL=C awk '
    BEGIN { cr=sprintf("%c", 13) }
    {
      line=$0
      if (substr(line, length(line), 1) == cr) {
        line=substr(line, 1, length(line) - 1)
      }
      if (line == "") next
      logical++
      if (logical > 1) print line
    }
  ' "$DUET_DIR/roster.tsv")

  if [ "$row_count" -gt 5 ]; then
    DUET_DOCTOR_ROSTER_VALID=""
  fi
  if [ "$initiator_count" -ne 1 ]; then
    DUET_DOCTOR_ROSTER_VALID=""
    duet_doctor_issue "roster does not contain exactly one configured initiator"
  fi

  if [ "$current_leaders" -ne 1 ]; then
    duet_doctor_issue "leader '$DUET_CURRENT_LEADER' is not represented exactly once in the roster"
  fi
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
        if [ "$DUET_MESSAGE_HANDOFF_MODE" != MANUAL ] \
            || ! duet_roster_has_name "$DUET_MESSAGE_PRIOR_LEADER" \
            || ! duet_roster_has_name "$DUET_MESSAGE_RECIPIENT"; then
          duet_doctor_issue "pending handoff $(basename "$file") has an invalid manual intent"
        elif ! { [ "$DUET_CURRENT_TERM" = "$DUET_MESSAGE_PRIOR_TERM" ] \
                  && [ "$DUET_CURRENT_LEADER" = "$DUET_MESSAGE_PRIOR_LEADER" ]; } \
            && ! { [ "$DUET_CURRENT_TERM" = "$DUET_MESSAGE_TERM" ] \
                  && [ "$DUET_CURRENT_LEADER" = "$DUET_MESSAGE_RECIPIENT" ]; }; then
          duet_doctor_issue "pending handoff $(basename "$file") is obsolete for the current leader generation"
        fi
      fi
    done
  done
  [ "$promotion_count" -le 1 ] \
    || duet_doctor_issue "$promotion_count simultaneous manual handoff obligations are active"
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
  local name harness pane recorded_pid rank spawned failed=""
  [ -f "$DUET_DIR/.ended" ] || {
    echo "duet: --reap refuses an active session; use duet-end.sh for an orderly drain." >&2
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
    echo "duet: --reap requires --session, DUET_CONFIG, or DUET_SESSION; ambient current is forbidden." >&2
    return 2
  fi
  duet_diag_load_session "$session_arg" 1 || return 1
  duet_read_leader_state || return 1

  echo "=== duet doctor ==="
  duet_diag_print_summary
  duet_diag_print_roster
  duet_diag_print_handoff_guidance
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
