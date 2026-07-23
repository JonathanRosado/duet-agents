#!/usr/bin/env bash
# One live delivery daemon for one pinned session.
#
# Delivery state is intentionally in-process only. A daemon or pane failure,
# or any ambiguity after paste, invalidates the session instead of attempting
# crash recovery.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

duet_deliverd_log(){
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" \
    >> "${DUET_DIR:?}/deliverd.log"
}

duet_mark_unhealthy(){
  local reason="${1:?unhealthy reason required}" tmp
  if [ ! -f "${DUET_DIR:?}/.unhealthy" ]; then
    tmp="$(mktemp "$DUET_DIR/.unhealthy.XXXXXX")" || return 1
    if ! printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$reason" > "$tmp" \
        || ! duet_publish_temp_file "$tmp" "$DUET_DIR/.unhealthy"; then
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
  fi
  duet_deliverd_log "UNHEALTHY: $reason"
  printf 'duet: session unhealthy: %s\n' "$reason" >&2
}

duet_message_sequence(){
  local base sequence
  DUET_MESSAGE_SEQUENCE=""
  base="$(basename "${1:?message file required}")"
  case "$base" in N-*.msg|I-*.msg) :;; *) return 1;; esac
  base="${base#?-}"
  sequence="${base%.msg}"
  case "$sequence" in ''|*[!0-9]*) return 1;; esac
  duet_decimal_d10 "$sequence" 1 || return 1
  printf -v DUET_MESSAGE_SEQUENCE '%010d' "$DUET_DECIMAL_VALUE"
}

# Interrupts are urgent, but FIFO is preserved within each mode. No message is
# superseded: after the interrupt, older normal work remains queued.
duet_queue_next(){
  local box="${1:?queue directory required}" prefix file best sequence
  DUET_NEXT_MESSAGE=""
  for prefix in I N; do
    best=""
    for file in "$box"/"$prefix"-*.msg; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      if ! duet_message_sequence "$file"; then
        DUET_NEXT_MESSAGE="$file"
        return 0
      fi
      sequence="$DUET_MESSAGE_SEQUENCE"
      if [ -z "$best" ] || [[ "$sequence" < "$best" ]]; then
        best="$sequence"
        DUET_NEXT_MESSAGE="$file"
      fi
    done
    [ -z "$DUET_NEXT_MESSAGE" ] || return 0
  done
  return 1
}

duet_raw_message_field(){
  LC_ALL=C awk -F '\t' -v key="${2:?field required}" \
    '$1 == key { sub(/^[^\t]*\t/, ""); print; exit }' \
    "${1:?message required}" 2>/dev/null
}

duet_message_id_delivered(){
  local box="${1:?queue directory required}" id="${2:?message id required}"
  local file delivered_id
  for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    delivered_id="$(duet_raw_message_field "$file" id)"
    [ "$delivered_id" = "$id" ] && return 0
  done
  return 1
}

duet_move_delivered(){
  local file="${1:?message file required}" destination
  mkdir -p "$(dirname "$file")/delivered" || return 1
  destination="$(dirname "$file")/delivered/$(basename "$file")"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  mv "$file" "$destination" || return 1
  DUET_TERMINAL_FILE="$destination"
}

duet_queue_target(){
  local queue="${1:?queue required}"
  DUET_QUEUE_TARGET=""
  case "$queue" in
    leader)
      # Temporary M1 compatibility for the legacy hub sender. M2 removes this
      # alias and its leader state completely.
      duet_read_leader_state || return 1
      DUET_QUEUE_TARGET="$DUET_CURRENT_LEADER"
      ;;
    promotions)
      return 2
      ;;
    *)
      duet_roster_has_name "$queue" || return 1
      DUET_QUEUE_TARGET="$queue"
      ;;
  esac
}

# Process at most one head from one physical queue. A definitely-not-landed
# head remains in place and stalls only this queue. Every post-paste ambiguity
# is fatal for the whole session because safely restarting would require the
# durable recovery protocol v4 deliberately rejects.
duet_process_one(){
  local box="${1:?queue directory required}" exact_file="${2:-}"
  local file queue payload interrupt="" target_harness rc
  DUET_PROCESS_ATTEMPTED=""
  DUET_PROCESS_TARGET_NAME=""
  DUET_PROCESS_TARGET_PANE=""

  if [ -n "$exact_file" ]; then
    [ -f "$exact_file" ] && [ ! -L "$exact_file" ] || return 0
    [ "$(dirname "$exact_file")" = "$box" ] || return 1
    file="$exact_file"
  else
    duet_queue_next "$box" || return 0
    file="$DUET_NEXT_MESSAGE"
  fi

  queue="$(basename "$box")"
  if ! duet_message_sequence "$file"; then
    duet_mark_unhealthy "invalid message filename in inbox/$queue: $(basename "$file")"
    return 1
  fi
  if ! duet_read_message "$file"; then
    duet_mark_unhealthy "invalid message envelope in inbox/$queue: $(basename "$file")"
    return 1
  fi
  if [ "$DUET_MESSAGE_SESSION" != "${DUET_SESSION_ID:?}" ]; then
    duet_mark_unhealthy "message $DUET_MESSAGE_ID names session $DUET_MESSAGE_SESSION"
    return 1
  fi

  if ! duet_queue_target "$queue"; then
    duet_mark_unhealthy "queue inbox/$queue has no unique live-session recipient"
    return 1
  fi
  DUET_TARGET_NAME="$DUET_QUEUE_TARGET"
  case "$queue" in
    leader)
      [ "$DUET_MESSAGE_RECIPIENT" = leader ] || {
        duet_mark_unhealthy "message $DUET_MESSAGE_ID redirects the leader queue"
        return 1
      }
      ;;
    *)
      [ "$DUET_MESSAGE_RECIPIENT" = "$queue" ] || {
        duet_mark_unhealthy "message $DUET_MESSAGE_ID redirects inbox/$queue"
        return 1
      }
      ;;
  esac

  if duet_message_id_delivered "$box" "$DUET_MESSAGE_ID"; then
    duet_deliverd_log "suppressed duplicate $DUET_MESSAGE_ID -> $DUET_TARGET_NAME"
    duet_move_delivered "$file" || {
      duet_mark_unhealthy "could not archive duplicate $DUET_MESSAGE_ID"
      return 1
    }
    return 0
  fi

  DUET_TARGET_PANE="$(duet_roster_pane_for_name "$DUET_TARGET_NAME")"
  target_harness="$(duet_roster_harness_for_name "$DUET_TARGET_NAME")"
  DUET_PROCESS_TARGET_NAME="$DUET_TARGET_NAME"
  DUET_PROCESS_TARGET_PANE="$DUET_TARGET_PANE"
  if [ -z "$DUET_TARGET_PANE" ] || [ -z "$target_harness" ] \
      || ! duet_roster_member_alive "$DUET_TARGET_NAME"; then
    duet_mark_unhealthy "recipient $DUET_TARGET_NAME is dead or has invalid roster identity"
    return 1
  fi

  payload="$(duet_build_payload)"
  [ "$DUET_MESSAGE_MODE" != INTERRUPT ] || interrupt=1
  DUET_PROCESS_ATTEMPTED=1
  if duet_send_verified "$DUET_TARGET_PANE" "$payload" "$interrupt" \
      "$target_harness"; then
    rc=0
  else
    rc=$?
  fi

  case "$rc" in
    0)
      duet_move_delivered "$file" || {
        duet_mark_unhealthy "could not archive delivered message $DUET_MESSAGE_ID"
        return 1
      }
      duet_deliverd_log "delivered $DUET_MESSAGE_ID -> $DUET_TARGET_NAME"
      ;;
    "$DUET_SEND_NOT_LANDED")
      duet_deliverd_log "stalled $DUET_MESSAGE_ID -> $DUET_TARGET_NAME before landing"
      ;;
    "$DUET_SEND_DEAD")
      duet_mark_unhealthy "recipient $DUET_TARGET_NAME died while delivering $DUET_MESSAGE_ID"
      return 1
      ;;
    "$DUET_SEND_LANDED_UNVERIFIED")
      duet_mark_unhealthy "delivery-ambiguous after paste for $DUET_MESSAGE_ID -> $DUET_TARGET_NAME"
      return 1
      ;;
    *)
      duet_mark_unhealthy "unexpected verifier outcome $rc for $DUET_MESSAGE_ID"
      return 1
      ;;
  esac
}

# Every roster member gets at most one bounded head attempt per pass. Since a
# pre-landing stall returns success, the pass continues to every other member.
# The symbolic leader queue is transitional M1 compatibility and is attempted
# only when that physical recipient did not already receive a named attempt.
duet_deliverd_pass(){
  local name box target seen="|"
  if ! duet_validate_roster "${DUET_DIR:?}/roster.tsv"; then
    duet_mark_unhealthy "roster validation failed"
    return 1
  fi

  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] || continue
    box="$DUET_DIR/inbox/$name"
    [ -d "$box" ] || continue
    duet_queue_next "$box" || continue
    if ! duet_process_one "$box" "$DUET_NEXT_MESSAGE"; then
      return 1
    fi
    seen="$seen$name|"
  done < <(awk -F '\t' 'NR > 1 { print $1 "\t" $2 }' "$DUET_DIR/roster.tsv")

  box="$DUET_DIR/inbox/leader"
  if [ -d "$box" ] && duet_queue_next "$box"; then
    duet_queue_target leader || {
      duet_mark_unhealthy "legacy leader queue cannot resolve a recipient"
      return 1
    }
    target="$DUET_QUEUE_TARGET"
    case "$seen" in
      *"|$target|"*) : ;;
      *)
        duet_process_one "$box" "$DUET_NEXT_MESSAGE" || return 1
        ;;
    esac
  fi
}

duet_deliverd_cleanup(){
  local exit_status="${1:-0}"
  local daemon_pid="${DUET_DAEMON_PID:-${BASHPID:-$$}}" recorded
  recorded="$(cat "${DUET_DIR:-}/daemon.pid" 2>/dev/null || true)"
  [ "$recorded" != "$daemon_pid" ] || rm -f "$DUET_DIR/daemon.pid"
  [ -z "${DUET_DIR:-}" ] \
    || duet_lock_release "$DUET_DIR/.daemon.lock" 2>/dev/null || true
  if [ -n "${DUET_DAEMON_ACTIVE:-}" ] \
      && [ -z "${DUET_DAEMON_ORDERLY_STOP:-}" ] \
      && [ -n "${DUET_DIR:-}" ] && [ ! -f "$DUET_DIR/.ended" ] \
      && [ ! -f "$DUET_DIR/.unhealthy" ]; then
    duet_mark_unhealthy "delivery daemon exited unexpectedly (status $exit_status)" \
      2>/dev/null || true
  fi
}

duet_deliverd_main(){
  local session_arg="" session_id_arg="" inherited_session="${DUET_SESSION:-}" cfg
  local env_server_pid actual_server_pid pid_tmp poll
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session)
        [ "$#" -ge 2 ] || {
          echo "usage: duet-deliverd.sh --session <duet.env> --session-id <id>" >&2
          return 2
        }
        session_arg="$2"
        shift 2
        ;;
      --session-id)
        [ "$#" -ge 2 ] || {
          echo "usage: duet-deliverd.sh --session <duet.env> --session-id <id>" >&2
          return 2
        }
        session_id_arg="$2"
        shift 2
        ;;
      *) echo "duet: unknown daemon option '$1'" >&2; return 2 ;;
    esac
  done

  duet_resolve_config "$session_arg" 0 || return 1
  cfg="$DUET_RESOLVED_CONFIG"
  if [ "$session_arg" != "$cfg" ]; then
    exec bash "$SELF_DIR/duet-deliverd.sh" \
      --session "$cfg" --session-id "$session_id_arg"
  fi
  unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
  unset DUET_SESSION DUET_SESSION_ID DUET_WORKDIR_KEY DUET_INITIATOR DUET_INITIATOR_PANE
  # shellcheck disable=SC1090
  . "$cfg" || {
    echo "duet: daemon could not load pinned config: $cfg" >&2
    return 1
  }
  duet_validate_loaded_session "$inherited_session" "$cfg" || return 1
  [ "$session_id_arg" = "$DUET_SESSION_ID" ] || {
    echo "duet: daemon command identity does not match pinned session $DUET_SESSION_ID." >&2
    return 1
  }
  DUET_CONFIG="$cfg"
  export DUET_CONFIG DUET_SESSION
  [ ! -f "$DUET_DIR/.ended" ] || return 0
  [ ! -f "$DUET_DIR/.unhealthy" ] || {
    echo "duet: unhealthy sessions cannot restart their delivery daemon." >&2
    return 1
  }
  duet_validate_roster "$DUET_DIR/roster.tsv" || {
    echo "duet: session roster is invalid; daemon will not start." >&2
    return 1
  }

  env_server_pid="${DUET_TMUX_SERVER_PID:-}"
  actual_server_pid="$(_duet_tmux display-message -p '#{pid}' 2>/dev/null || true)"
  if [ -n "$env_server_pid" ] && [ "$actual_server_pid" != "$env_server_pid" ]; then
    echo "duet: tmux server identity mismatch; daemon will not start." >&2
    return 1
  fi

  if [ -e "$DUET_DIR/daemon.pid" ] || [ -L "$DUET_DIR/daemon.pid" ] \
      || [ -e "$DUET_DIR/.daemon.lock" ] || [ -L "$DUET_DIR/.daemon.lock" ]; then
    duet_mark_unhealthy "stale daemon state found; session restart is forbidden"
    return 1
  fi
  duet_lock_acquire "$DUET_DIR/.daemon.lock" 1 || {
    echo "duet: another delivery daemon already owns this session." >&2
    return 1
  }

  DUET_DAEMON_PID="${BASHPID:-$$}"
  DUET_DAEMON_ACTIVE=1
  trap 'duet_deliverd_cleanup $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  pid_tmp="$(mktemp "$DUET_DIR/.daemon.pid.XXXXXX")" || return 1
  if ! printf '%s\n' "$DUET_DAEMON_PID" > "$pid_tmp" \
      || ! duet_publish_temp_file "$pid_tmp" "$DUET_DIR/daemon.pid"; then
    rm -f "$pid_tmp"
    echo "duet: could not publish daemon.pid." >&2
    return 1
  fi
  duet_deliverd_log "daemon up pid=$DUET_DAEMON_PID"

  poll="${DUET_DELIVERY_POLL_INTERVAL:-0.1}"
  while [ ! -f "$DUET_DIR/.ended" ]; do
    if ! duet_tmux_server_matches; then
      duet_mark_unhealthy "tmux server identity changed"
      return 1
    fi
    if ! duet_deliverd_pass; then
      return 1
    fi
    sleep "$poll"
  done
  DUET_DAEMON_ORDERLY_STOP=1
  duet_deliverd_log "daemon stop"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  duet_deliverd_main "$@"
fi
