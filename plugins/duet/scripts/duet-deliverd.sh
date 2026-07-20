#!/usr/bin/env bash
# Single session delivery daemon. It fairly advances at most one message per
# logical recipient queue on each pass; all tmux injection lives here.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

duet_deliverd_log(){
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" \
    >> "${DUET_DIR:?}/deliverd.log"
}

duet_message_sequence(){
  local base
  base="$(basename "${1:?message file required}")"
  base="${base#?-}"
  printf '%s' "${base%.msg}"
}

duet_queue_next(){
  local box="${1:?queue directory required}" file phase sequence best_sequence=""
  DUET_NEXT_MESSAGE=""

  # A prior uncertain submission owns the composer. Resolve it before any
  # interrupt or normal message can paste onto that same edge.
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    phase="$(cat "$file.phase" 2>/dev/null || true)"
    [ "$phase" = ENTER_ONLY ] || continue
    sequence="$(duet_message_sequence "$file")"
    if [ -z "$best_sequence" ] || [[ "$sequence" < "$best_sequence" ]]; then
      DUET_NEXT_MESSAGE="$file"
      best_sequence="$sequence"
    fi
  done
  [ -z "$DUET_NEXT_MESSAGE" ] || return 0

  # Newest interrupt wins. Once terminal, every lower-sequence undelivered item
  # is superseded so a stale assignment cannot arrive after its redirect.
  for file in "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    DUET_NEXT_MESSAGE="$file"
  done
  [ -z "$DUET_NEXT_MESSAGE" ] || return 0

  # Normal traffic is strict FIFO.
  for file in "$box"/N-*.msg; do
    [ -f "$file" ] || continue
    DUET_NEXT_MESSAGE="$file"
    return 0
  done
  return 1
}

duet_retry_due(){
  local file="${1:?message file required}" retry_at now
  retry_at="$(cat "$file.retry_at" 2>/dev/null || true)"
  case "$retry_at" in ''|*[!0-9]*) return 0;; esac
  now="$(date +%s)"
  [ "$now" -ge "$retry_at" ]
}

duet_write_sidecar(){
  local file="${1:?message file required}" suffix="${2:?sidecar suffix required}"
  local value="${3-}" tmp
  tmp="$(mktemp "$(dirname "$file")/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! mv -f "$tmp" "$file.$suffix"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

duet_set_backoff(){
  local file="${1:?message file required}" attempts="${2:?attempts required}"
  local base="${DUET_DELIVERY_RETRY_BASE:-1}" delay now
  case "$base" in ''|*[!0-9]*) base=1;; esac
  if [ "$attempts" -ge 4 ]; then delay=$((base * 8)); else delay=$((base * (1 << (attempts - 1)))); fi
  now="$(date +%s)"
  duet_write_sidecar "$file" retry_at "$((now + delay))"
}

duet_clear_mutable_state(){
  local file="${1:?message file required}"
  rm -f "$file.phase" "$file.tries" "$file.retry_at" "$file.enter_token" \
    2>/dev/null || true
}

duet_move_terminal(){
  local file="${1:?message file required}" directory="${2:?terminal directory required}"
  local destination
  destination="$(dirname "$file")/$directory/$(basename "$file")"
  [ ! -e "$destination" ] || {
    duet_deliverd_log "terminal collision for $(basename "$file") in $directory"
    return 1
  }
  mv "$file" "$destination" || return 1
  duet_clear_mutable_state "$file"
  DUET_TERMINAL_FILE="$destination"
}

duet_supersede_before(){
  local box="${1:?queue directory required}" winning_sequence="${2:?sequence required}"
  local file sequence
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    sequence="$(duet_message_sequence "$file")"
    if [ $((10#$sequence)) -lt $((10#$winning_sequence)) ]; then
      duet_deliverd_log "superseded $(basename "$file") by interrupt sequence $winning_sequence"
      duet_move_terminal "$file" superseded || return 1
    fi
  done
}

duet_complete_interrupt_supersede(){
  local box="${1:?queue directory required}" terminal_file="${2:?terminal interrupt required}"
  local sequence
  sequence="$(duet_message_sequence "$terminal_file")"
  duet_supersede_before "$box" "$sequence" || return 1
  duet_write_sidecar "$terminal_file" supersede_done "$sequence"
}

# A daemon crash can occur after an interrupt is durably archived but before
# its older work is superseded. Reconcile that obligation before considering
# any active message, so stale assignments cannot escape on restart.
duet_reconcile_interrupt_supersedes(){
  local box file
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    for file in "$box"/delivered/I-*.msg "$box"/quarantine/I-*.msg; do
      [ -f "$file" ] || continue
      [ ! -f "$file.supersede_done" ] || continue
      duet_complete_interrupt_supersede "$box" "$file" || return 1
    done
  done
}

duet_delivery_failure_notice(){
  local failed_name="${1:?failed recipient required}" id="${2:?message id required}"
  local outcome="${3:?outcome required}" failed_file="${4:?failed file required}" body
  duet_read_leader_state || return 1
  body="Delivery to worker $failed_name failed permanently ($outcome) for message $id. Reassign its work if needed."
  if DUET_INTERNAL_ENQUEUE=1 duet_enqueue_message leader duet-system leader "$DUET_CURRENT_TERM" NORMAL \
      SYSTEM "$DUET_CURRENT_LEADER" "$body" "failure-$id"; then
    duet_write_sidecar "$failed_file" noticed "$DUET_ENQUEUED_ID" || return 1
    duet_deliverd_log "queued leader notice $DUET_ENQUEUED_ID for failed delivery $id"
  else
    duet_deliverd_log "could not queue leader notice for failed delivery $id"
    return 1
  fi
}

duet_reconcile_failure_notices(){
  local file box queue
  for file in "${DUET_DIR:?}"/inbox/*/failed/*.msg; do
    [ -f "$file" ] || continue
    [ ! -f "$file.noticed" ] || continue
    box="$(dirname "$(dirname "$file")")"
    queue="$(basename "$box")"
    [ "$queue" != leader ] || continue
    if ! duet_read_message "$file"; then
      # Corrupt messages cannot yield a trustworthy recipient or ID. Mark the
      # terminal record so every pass does not retry an impossible notice.
      duet_write_sidecar "$file" noticed invalid-message || return 1
      continue
    fi
    [ "$DUET_MESSAGE_RECIPIENT" != leader ] || continue
    duet_delivery_failure_notice "$DUET_MESSAGE_RECIPIENT" \
      "$DUET_MESSAGE_ID" UNKNOWN "$file" || return 1
  done
}

duet_resolve_delivery_target(){
  local recipient="${1:?recipient required}"
  if [ "$recipient" = leader ]; then
    duet_read_leader_state || return 1
    DUET_TARGET_NAME="$DUET_CURRENT_LEADER"
  else
    DUET_TARGET_NAME="$recipient"
  fi
  DUET_TARGET_PANE="$(duet_roster_pane_for_name "$DUET_TARGET_NAME")"
  [ -n "$DUET_TARGET_PANE" ]
}

duet_process_one(){
  local box="${1:?queue directory required}" file phase payload rc attempts max enter_token
  local interrupt="" target_is_symbolic="" target_harness=""
  duet_queue_next "$box" || return 0
  file="$DUET_NEXT_MESSAGE"
  duet_retry_due "$file" || return 0

  if ! duet_read_message "$file"; then
    duet_deliverd_log "invalid message $(basename "$file") -> failed"
    duet_move_terminal "$file" failed || return 1
    duet_write_sidecar "$DUET_TERMINAL_FILE" noticed invalid-message || return 1
    return 0
  fi
  payload="$(duet_build_payload)"
  [ "$DUET_MESSAGE_MODE" != INTERRUPT ] || interrupt=1
  [ "$DUET_MESSAGE_RECIPIENT" != leader ] || target_is_symbolic=1
  phase="$(cat "$file.phase" 2>/dev/null || true)"
  case "$phase" in
    '')
      if [ -e "$file.phase" ]; then
        duet_deliverd_log "empty delivery phase for $DUET_MESSAGE_ID; quarantined"
        duet_move_terminal "$file" quarantine || return 1
        return 0
      fi
      ;;
    READY|ENTER_ONLY) : ;;
    INFLIGHT)
      duet_deliverd_log "recovering in-flight $DUET_MESSAGE_ID with the same stable id"
      phase=READY
      ;;
    *)
      duet_deliverd_log "invalid delivery phase '$phase' for $DUET_MESSAGE_ID; quarantined"
      duet_move_terminal "$file" quarantine || return 1
      return 0
      ;;
  esac

  if ! duet_resolve_delivery_target "$DUET_MESSAGE_RECIPIENT"; then
    rc=$DUET_SEND_DEAD
  elif [ "$phase" = ENTER_ONLY ]; then
    enter_token="$(cat "$file.enter_token" 2>/dev/null || true)"
    if duet_send_enter_only "$DUET_TARGET_PANE" "$payload" "$enter_token"; then rc=0; else rc=$?; fi
  else
    target_harness="$(duet_roster_harness_for_name "$DUET_TARGET_NAME")"
    duet_write_sidecar "$file" phase INFLIGHT || {
      duet_deliverd_log "could not persist INFLIGHT for $DUET_MESSAGE_ID; daemon halting"
      return 1
    }
    if duet_send_verified "$DUET_TARGET_PANE" "$payload" "$interrupt" "$target_harness"; then rc=0; else rc=$?; fi
  fi

  # Once a paste may have landed, no later outcome can make a full repaste
  # safe. A vanished/replaced pane is especially hazardous for the symbolic
  # leader queue: resetting to READY here could duplicate the task after a
  # promotion. Only an Enter-only success resolves this state; everything else
  # is terminally uncertain.
  if [ "$phase" = ENTER_ONLY ] && [ "$rc" -ne 0 ] \
      && [ "$rc" -ne "$DUET_SEND_LANDED_UNVERIFIED" ]; then
    duet_deliverd_log "quarantined $DUET_MESSAGE_ID: Enter-only continuation returned $rc"
    duet_move_terminal "$file" quarantine || return 1
    [ "$DUET_MESSAGE_MODE" != INTERRUPT ] \
      || duet_complete_interrupt_supersede "$box" "$DUET_TERMINAL_FILE" || return 1
    return 0
  fi

  attempts="$(cat "$file.tries" 2>/dev/null || true)"
  case "$attempts" in ''|*[!0-9]*) attempts=0;; esac
  max="${DUET_DELIVERY_MAX_ATTEMPTS:-5}"
  case "$max" in ''|*[!0-9]*) max=5;; esac

  case "$rc" in
    0)
      duet_deliverd_log "delivered $DUET_MESSAGE_ID -> $DUET_TARGET_NAME"
      duet_move_terminal "$file" delivered || return 1
      [ "$DUET_MESSAGE_MODE" != INTERRUPT ] \
        || duet_complete_interrupt_supersede "$box" "$DUET_TERMINAL_FILE" || return 1
      ;;
    "$DUET_SEND_LANDED_UNVERIFIED")
      if [ "$phase" = ENTER_ONLY ]; then
        duet_deliverd_log "quarantined $DUET_MESSAGE_ID after Enter-only verification failed"
        duet_move_terminal "$file" quarantine || return 1
        [ "$DUET_MESSAGE_MODE" != INTERRUPT ] \
          || duet_complete_interrupt_supersede "$box" "$DUET_TERMINAL_FILE" || return 1
      else
        duet_deliverd_log "enter-only continuation scheduled for $DUET_MESSAGE_ID"
        if [ -n "${DUET_SEND_ENTER_TOKEN:-}" ]; then
          duet_write_sidecar "$file" enter_token "$DUET_SEND_ENTER_TOKEN" || return 1
        fi
        duet_write_sidecar "$file" phase ENTER_ONLY || return 1
        duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 1 ))" || return 1
      fi
      ;;
    "$DUET_SEND_NOT_LANDED")
      attempts=$((attempts + 1))
      if [ -z "$target_is_symbolic" ] && [ "$attempts" -ge "$max" ]; then
        duet_deliverd_log "failed $DUET_MESSAGE_ID after $attempts NOT_LANDED outcomes"
        duet_move_terminal "$file" failed || return 1
        duet_delivery_failure_notice "$DUET_TARGET_NAME" "$DUET_MESSAGE_ID" \
          NOT_LANDED "$DUET_TERMINAL_FILE" || return 1
      else
        duet_write_sidecar "$file" tries "$attempts" || return 1
        duet_set_backoff "$file" "$attempts" || return 1
        duet_write_sidecar "$file" phase READY || return 1
      fi
      ;;
    "$DUET_SEND_DEAD")
      attempts=$((attempts + 1))
      if [ -z "$target_is_symbolic" ] && [ "$attempts" -ge "$max" ]; then
        duet_deliverd_log "failed $DUET_MESSAGE_ID: worker $DUET_TARGET_NAME is dead"
        duet_move_terminal "$file" failed || return 1
        duet_delivery_failure_notice "$DUET_TARGET_NAME" "$DUET_MESSAGE_ID" \
          DEAD "$DUET_TERMINAL_FILE" || return 1
      else
        duet_write_sidecar "$file" tries "$attempts" || return 1
        duet_set_backoff "$file" "$attempts" || return 1
        duet_write_sidecar "$file" phase READY || return 1
      fi
      ;;
    *)
      duet_deliverd_log "unexpected verifier outcome $rc for $DUET_MESSAGE_ID; quarantined"
      duet_move_terminal "$file" quarantine || return 1
      ;;
  esac
}

duet_deliverd_pass(){
  local box
  duet_reconcile_interrupt_supersedes || return 1
  duet_reconcile_failure_notices || return 1
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    duet_process_one "$box" || return 1
  done
}

duet_deliverd_cleanup(){
  local daemon_pid="${DUET_DAEMON_PID:-${BASHPID:-$$}}" recorded
  recorded="$(cat "${DUET_DIR:-}/daemon.pid" 2>/dev/null || true)"
  [ "$recorded" != "$daemon_pid" ] || rm -f "$DUET_DIR/daemon.pid"
  [ -z "${DUET_DIR:-}" ] || duet_lock_release "$DUET_DIR/.delivery.lock" 2>/dev/null || true
  [ -z "${DUET_DIR:-}" ] || duet_lock_release "$DUET_DIR/.daemon.lock" 2>/dev/null || true
}

duet_deliverd_main(){
  local state_root cfg env_server_pid actual_server_pid pid_tmp poll
  state_root="${DUET_STATE_ROOT:-$HOME/.duet}"
  cfg="${DUET_CONFIG:-$state_root/current/duet.env}"
  [ -f "$cfg" ] || { echo "duet: daemon config missing: $cfg" >&2; return 1; }
  # shellcheck disable=SC1090
  . "$cfg"
  [ ! -f "$DUET_DIR/.ended" ] || return 0

  env_server_pid="${DUET_TMUX_SERVER_PID:-}"
  actual_server_pid="$(_duet_tmux display-message -p '#{pid}' 2>/dev/null || true)"
  if [ -n "$env_server_pid" ] && [ "$actual_server_pid" != "$env_server_pid" ]; then
    echo "duet: tmux server identity mismatch; daemon will not start." >&2
    return 1
  fi

  duet_lock_acquire "$DUET_DIR/.daemon.lock" 40 || {
    echo "duet: another delivery daemon already owns this session." >&2
    return 1
  }
  DUET_DAEMON_PID="${BASHPID:-$$}"
  trap duet_deliverd_cleanup EXIT
  trap 'exit 0' INT TERM
  pid_tmp="$(mktemp "$DUET_DIR/.daemon.pid.XXXXXX")" || return 1
  if ! printf '%s\n' "$DUET_DAEMON_PID" > "$pid_tmp" \
      || ! mv -f "$pid_tmp" "$DUET_DIR/daemon.pid"; then
    rm -f "$pid_tmp"
    echo "duet: could not publish daemon.pid." >&2
    return 1
  fi
  duet_deliverd_log "daemon up pid=$DUET_DAEMON_PID"

  poll="${DUET_DELIVERY_POLL_INTERVAL:-0.1}"
  while [ ! -f "$DUET_DIR/.ended" ]; do
    if ! duet_tmux_server_matches; then
      duet_deliverd_log "tmux server identity changed; daemon halting"
      return 1
    fi
    if ! duet_lock_acquire "$DUET_DIR/.delivery.lock" 40; then
      duet_deliverd_log "could not acquire delivery-pass fence; daemon halting"
      return 1
    fi
    if ! duet_deliverd_pass; then
      duet_deliverd_log "delivery state transition failed; daemon halting"
      return 1
    fi
    if ! duet_lock_release "$DUET_DIR/.delivery.lock"; then
      duet_deliverd_log "could not release delivery-pass fence; daemon halting"
      return 1
    fi
    sleep "$poll"
  done
  duet_deliverd_log "daemon stop"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  duet_deliverd_main "$@"
fi
