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
  local base sequence
  DUET_MESSAGE_SEQUENCE=""
  base="$(basename "${1:?message file required}")"
  case "$base" in N-*.msg|I-*.msg) :;; *) return 1;; esac
  base="${base#?-}"
  sequence="${base%.msg}"
  case "$sequence" in ''|*[!0-9]*) return 1;; esac
  duet_decimal_d10 "$sequence" 1 || return 2
  printf -v DUET_MESSAGE_SEQUENCE '%010d' "$DUET_DECIMAL_VALUE"
}

duet_queue_next(){
  local box="${1:?queue directory required}" file phase sequence best_sequence=""
  DUET_NEXT_MESSAGE=""

  # A prior uncertain submission owns the composer. Resolve it before any
  # interrupt or normal message can paste onto that same edge.
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    phase="$(cat "$file.phase" 2>/dev/null || true)"
    case "$phase" in ENTER_ONLY|INFLIGHT|CLEAR_RETRY) : ;; *) continue ;; esac
    if ! duet_message_sequence "$file"; then
      DUET_NEXT_MESSAGE="$file"
      return 0
    fi
    sequence="$DUET_MESSAGE_SEQUENCE"
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
  local file="${1:?message file required}" retry_file retry_at now
  DUET_RETRY_INVALID=""
  retry_file="$file.retry_at"
  if [ ! -e "$retry_file" ] && [ ! -L "$retry_file" ]; then
    return 0
  fi
  if ! duet_regular_file_without_nul "$retry_file"; then
    DUET_RETRY_INVALID=1
    return 0
  fi
  retry_at="$(cat "$retry_file" 2>/dev/null || true)"
  if ! duet_decimal_d10 "$retry_at"; then
    DUET_RETRY_INVALID=1
    return 0
  fi
  retry_at="$DUET_DECIMAL_VALUE"
  now="$(date +%s)"
  [ "$now" -ge "$retry_at" ]
}

duet_write_sidecar(){
  local file="${1:?message file required}" suffix="${2:?sidecar suffix required}"
  local value="${3-}" tmp
  tmp="$(mktemp "$(dirname "$file")/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" > "$tmp" \
      || ! duet_publish_temp_file "$tmp" "$file.$suffix"; then
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
    "$file.landing_observed" \
    "$file.target_pane" "$file.target_name" "$file.target_term" \
    2>/dev/null || true
}

duet_move_terminal(){
  local file="${1:?message file required}" directory="${2:?terminal directory required}"
  local destination suffix
  destination="$(dirname "$file")/$directory/$(basename "$file")"
  [ ! -e "$destination" ] || {
    duet_deliverd_log "terminal collision for $(basename "$file") in $directory"
    return 1
  }
  mv "$file" "$destination" || return 1
  for suffix in reason promotion_term quarantine_reason; do
    [ ! -f "$file.$suffix" ] || {
      [ ! -e "$destination.$suffix" ] && [ ! -L "$destination.$suffix" ] \
        || return 1
      mv "$file.$suffix" "$destination.$suffix" || return 1
      [ -f "$destination.$suffix" ] && [ ! -L "$destination.$suffix" ] \
        || return 1
    }
  done
  duet_clear_mutable_state "$file"
  DUET_TERMINAL_FILE="$destination"
}

# Terminalization moves the immutable root before its durable metadata. Repair
# the bounded crash window on restart, and discard mutable root state once the
# terminal record proves the active message no longer exists.
duet_reconcile_terminal_moves(){
  local box directory file root suffix final_reason
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    # A quarantine intent is persisted before the immutable root is moved.
    # Complete it if the daemon died before terminalization.
    for root in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$root" ] || continue
      [ -f "$root.quarantine_reason" ] || continue
      final_reason="$(cat "$root.quarantine_reason" 2>/dev/null || true)"
      [ -n "$final_reason" ] || return 1
      duet_move_terminal "$root" quarantine || return 1
      duet_write_sidecar "$DUET_TERMINAL_FILE" reason "$final_reason" || return 1
      rm -f "$DUET_TERMINAL_FILE.quarantine_reason" || return 1
    done
    for directory in delivered failed quarantine superseded; do
      for file in "$box/$directory"/*.msg; do
        [ -f "$file" ] || continue
        root="$box/$(basename "$file")"
        for suffix in reason promotion_term quarantine_reason; do
          [ -f "$root.$suffix" ] || continue
          if [ ! -e "$file.$suffix" ] && [ ! -L "$file.$suffix" ]; then
            mv "$root.$suffix" "$file.$suffix" || return 1
            [ -f "$file.$suffix" ] && [ ! -L "$file.$suffix" ] || return 1
          elif [ -f "$file.$suffix" ] && [ ! -L "$file.$suffix" ]; then
            rm -f "$root.$suffix" || return 1
          else
            return 1
          fi
        done
        if [ -f "$file.quarantine_reason" ]; then
          final_reason="$(cat "$file.quarantine_reason" 2>/dev/null || true)"
          [ -n "$final_reason" ] || return 1
          duet_write_sidecar "$file" reason "$final_reason" || return 1
          rm -f "$file.quarantine_reason" || return 1
        fi
        duet_clear_mutable_state "$root"
      done
    done
  done
}

duet_supersede_before(){
  local box="${1:?queue directory required}" winning_sequence="${2:?sequence required}"
  local file sequence winning_value rc synthetic_winner
  synthetic_winner="$box/I-$winning_sequence.msg"
  duet_message_sequence "$synthetic_winner" || return 1
  winning_value="$DUET_MESSAGE_SEQUENCE"
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    if duet_message_sequence "$file"; then
      sequence="$DUET_MESSAGE_SEQUENCE"
    else
      rc=$?
      [ "$rc" -eq 1 ] && continue
      return 1
    fi
    if [ $((10#$sequence)) -lt $((10#$winning_value)) ]; then
      duet_deliverd_log "superseded $(basename "$file") by interrupt sequence $winning_sequence"
      duet_move_terminal "$file" superseded || return 1
    fi
  done
}

duet_complete_interrupt_supersede(){
  local box="${1:?queue directory required}" terminal_file="${2:?terminal interrupt required}"
  local sequence
  duet_message_sequence "$terminal_file" || return 1
  sequence="$DUET_MESSAGE_SEQUENCE"
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

duet_raw_message_field(){
  awk -F '\t' -v key="${2:?field required}" \
    '$1 == key { sub(/^[^\t]*\t/, ""); print; exit }' \
    "${1:?message required}" 2>/dev/null
}

duet_quarantine_reason(){
  local file="${1:?message required}" reason="${2:?reason required}"
  duet_write_sidecar "$file" quarantine_reason "$reason" || return 1
  duet_move_terminal "$file" quarantine || return 1
  duet_write_sidecar "$DUET_TERMINAL_FILE" reason "$reason" || return 1
  rm -f "$DUET_TERMINAL_FILE.quarantine_reason" || return 1
}

duet_foreign_payload_notice(){
  local terminal_file="${1:?terminal file required}" queue session id safe_session safe_id body key
  [ ! -f "$terminal_file.noticed" ] || return 0
  queue="$(basename "$(dirname "$(dirname "$terminal_file")")")"
  session="$(duet_raw_message_field "$terminal_file" session)"
  id="$(duet_raw_message_field "$terminal_file" id)"
  safe_session="$(printf '%s' "${session:-missing}" | LC_ALL=C tr -cd 'A-Za-z0-9_.-')"
  safe_id="$(printf '%s' "${id:-missing}" | LC_ALL=C tr -cd 'A-Za-z0-9_.-')"
  body="Quarantined a foreign-session payload in local queue $queue (declared session ${safe_session:-invalid}, id ${safe_id:-invalid}). No foreign body was delivered."
  key="foreign-$queue-$(basename "$terminal_file")"
  duet_read_leader_state || return 1
  if DUET_INTERNAL_ENQUEUE=1 duet_enqueue_message leader duet-system leader \
      "$DUET_CURRENT_TERM" NORMAL SYSTEM "$DUET_CURRENT_LEADER" "$body" "$key"; then
    duet_write_sidecar "$terminal_file" noticed "$DUET_ENQUEUED_ID" || return 1
    duet_deliverd_log "queued foreign-payload notice $DUET_ENQUEUED_ID"
    return 0
  fi
  return 1
}

duet_reconcile_foreign_notices(){
  local file reason
  for file in "${DUET_DIR:?}"/inbox/*/quarantine/*.msg; do
    [ -f "$file" ] || continue
    [ ! -f "$file.noticed" ] || continue
    reason="$(cat "$file.reason" 2>/dev/null || true)"
    case "$reason" in
      foreign-session|missing-session|foreign-message-id)
        duet_foreign_payload_notice "$file" || return 1
        ;;
    esac
  done
}

# A MANUAL handoff message is the operator's immutable crash journal. Complete
# only its exact prior/current tuple; never infer a target or react to health.
duet_reconcile_promotion_intents(){
  local box="${DUET_DIR:?}/inbox/promotions" file raw_session raw_id
  local prior prior_leader message_term
  [ -d "$box" ] || return 0
  for file in "$box"/N-*.msg; do
    [ -f "$file" ] || continue
    if ! duet_message_sequence "$file"; then
      duet_quarantine_reason "$file" invalid-message-filename || return 1
      continue
    fi
    raw_session="$(duet_raw_message_field "$file" session)"
    if [ -z "$raw_session" ]; then
      duet_quarantine_reason "$file" missing-session || return 1
      continue
    fi
    if [ "$raw_session" != "${DUET_SESSION_ID:?}" ]; then
      duet_quarantine_reason "$file" foreign-session || return 1
      continue
    fi
    raw_id="$(duet_raw_message_field "$file" id)"
    case "$raw_id" in
      "m-${DUET_SESSION_ID}-"*) : ;;
      *) duet_quarantine_reason "$file" foreign-message-id || return 1; continue ;;
    esac
    if ! duet_read_message "$file"; then
      duet_quarantine_reason "$file" invalid-promotion-envelope || return 1
      continue
    fi
    message_term="$DUET_MESSAGE_TERM"
    prior="$DUET_MESSAGE_PRIOR_TERM"
    prior_leader="$DUET_MESSAGE_PRIOR_LEADER"
    if [ "$DUET_MESSAGE_HANDOFF_MODE" != MANUAL ] \
        || [ "$DUET_MESSAGE_ORIGIN" != SYSTEM ] \
        || [ "$DUET_MESSAGE_DEDUPE" != "promotion-$message_term" ] \
        || ! duet_roster_has_name "$prior_leader" \
        || ! duet_roster_has_name "$DUET_MESSAGE_RECIPIENT"; then
      duet_quarantine_reason "$file" invalid-promotion-envelope || return 1
      continue
    fi
    duet_read_leader_state || return 1
    if [ "$DUET_CURRENT_TERM" = "$prior" ] \
        && [ "$DUET_CURRENT_LEADER" = "$prior_leader" ]; then
      if duet_has_uncertain_delivery; then
        duet_deliverd_log "deferred manual handoff completion behind uncertain $(basename "$DUET_UNCERTAIN_FILE")"
        continue
      fi
      [ -f "$file.promotion_term" ] \
        || duet_atomic_write "$file.promotion_term" "$message_term" || return 1
      duet_write_leader_state "$message_term" "$DUET_MESSAGE_RECIPIENT" || return 1
      duet_deliverd_log "completed recorded manual handoff term $message_term -> $DUET_MESSAGE_RECIPIENT"
    elif [ "$DUET_CURRENT_TERM" = "$message_term" ] \
        && [ "$DUET_CURRENT_LEADER" = "$DUET_MESSAGE_RECIPIENT" ]; then
      [ -f "$file.promotion_term" ] \
        || duet_atomic_write "$file.promotion_term" "$message_term" || return 1
    else
      duet_deliverd_log "quarantined obsolete manual handoff $(basename "$file")"
      duet_quarantine_reason "$file" obsolete-promotion || return 1
    fi
  done
}

duet_reconcile_promotion_fanout(){
  local box="${DUET_DIR:?}/inbox/promotions" file promotion_term name body marker reason
  for file in "$box"/delivered/N-*.msg "$box"/quarantine/N-*.msg; do
    [ -f "$file" ] || continue
    [ ! -f "$file.fanout_done" ] || continue
    promotion_term="$(cat "$file.promotion_term" 2>/dev/null || true)"
    duet_decimal_d10 "$promotion_term" || continue
    promotion_term="$DUET_DECIMAL_VALUE"
    reason="$(cat "$file.reason" 2>/dev/null || true)"
    case "$reason" in
      obsolete-promotion)
        duet_write_sidecar "$file" fanout_done obsolete || return 1
        continue
        ;;
      foreign-session|missing-session|foreign-message-id)
        duet_write_sidecar "$file" fanout_done foreign || return 1
        continue
        ;;
    esac
    if ! duet_read_message "$file" \
        || [ "$DUET_MESSAGE_SESSION" != "${DUET_SESSION_ID:?}" ] \
        || [ "$DUET_MESSAGE_HANDOFF_MODE" != MANUAL ] \
        || [ "$DUET_MESSAGE_ORIGIN" != SYSTEM ] \
        || [ "$DUET_MESSAGE_TERM" != "$promotion_term" ] \
        || [ "$DUET_MESSAGE_DEDUPE" != "promotion-$promotion_term" ]; then
      duet_write_sidecar "$file" fanout_done invalid || return 1
      continue
    fi
    duet_read_leader_state || return 1
    if [ "$DUET_CURRENT_TERM" != "$promotion_term" ] \
        || [ "$DUET_CURRENT_LEADER" != "$DUET_MESSAGE_RECIPIENT" ]; then
      duet_write_sidecar "$file" fanout_done superseded || return 1
      continue
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ "$name" != "$DUET_MESSAGE_RECIPIENT" ] || continue
      duet_roster_member_alive "$name" || continue
      marker="fanout-$name"
      [ ! -f "$file.$marker" ] || continue
      body="Leadership handoff for session ${DUET_SESSION_ID:?}: generation $promotion_term leader is $DUET_MESSAGE_RECIPIENT. Prior leader was $DUET_MESSAGE_PRIOR_LEADER. Read the leader file before continuing work."
      if ! DUET_INTERNAL_ENQUEUE=1 duet_enqueue_message "$name" duet-system "$name" \
          "$promotion_term" NORMAL SYSTEM "$DUET_MESSAGE_RECIPIENT" "$body" \
          "promotion-fanout-$promotion_term-$name"; then
        return 1
      fi
      duet_write_sidecar "$file" "$marker" "$DUET_ENQUEUED_ID" || return 1
    done < <(awk -F '\t' 'NR > 1 { print $1 }' "$DUET_DIR/roster.tsv")
    duet_write_sidecar "$file" fanout_done complete || return 1
  done
}

duet_clear_target_binding(){
  local file="${1:?message file required}"
  rm -f "$file.target_pane" "$file.target_name" "$file.target_term" \
    2>/dev/null || true
}

duet_finish_quarantine(){
  local box="${1:?queue directory required}" file="${2:?message required}"
  local reason="${3:?reason required}"
  duet_deliverd_log "quarantined $(basename "$file"): $reason"
  duet_quarantine_reason "$file" "$reason" || return 1
  if [ "${DUET_MESSAGE_MODE:-}" = INTERRUPT ]; then
    duet_complete_interrupt_supersede "$box" "$DUET_TERMINAL_FILE" || return 1
  fi
}

# Check the immutable routing envelope before decoding or displaying its body.
duet_validate_message_session(){
  local file="${1:?message required}" raw_session raw_id
  raw_session="$(duet_raw_message_field "$file" session)"
  raw_id="$(duet_raw_message_field "$file" id)"
  if [ -z "$raw_session" ]; then
    DUET_SESSION_FENCE_REASON=missing-session
    return 1
  fi
  if [ "$raw_session" != "${DUET_SESSION_ID:?}" ]; then
    DUET_SESSION_FENCE_REASON=foreign-session
    return 1
  fi
  case "$raw_id" in
    "m-${DUET_SESSION_ID}-"*) : ;;
    *) DUET_SESSION_FENCE_REASON=foreign-message-id; return 1 ;;
  esac
  DUET_SESSION_FENCE_REASON=""
}

# Process one exact queue root when supplied, otherwise the current queue head.
# At most one pane operation is performed.
duet_process_one(){
  local box="${1:?queue directory required}" exact_file="${2:-}" file phase payload rc
  local attempts max enter_token interrupt="" target_is_symbolic="" target_harness=""
  local continuation="" clear_recovery="" landing_evidence="" landing_clearable=""
  local queue current_term current_leader target_term
  local bound_pane bound_name bound_term binding_complete="" reason
  DUET_PROCESS_ATTEMPTED=""
  DUET_PROCESS_TARGET_PANE=""
  DUET_PROCESS_TARGET_NAME=""
  # Pre-parse quarantine paths must not inherit envelope capabilities from the
  # message processed immediately before this one.
  DUET_MESSAGE_MODE=""
  if [ -n "$exact_file" ]; then
    [ -f "$exact_file" ] || return 0
    [ "$(dirname "$exact_file")" = "$box" ] || return 1
    file="$exact_file"
  else
    duet_queue_next "$box" || return 0
    file="$DUET_NEXT_MESSAGE"
  fi
  if ! duet_message_sequence "$file"; then
    duet_finish_quarantine "$box" "$file" invalid-message-filename
    return
  fi
  if duet_retry_due "$file"; then
    :
  else
    return 0
  fi
  if [ -n "${DUET_RETRY_INVALID:-}" ]; then
    duet_finish_quarantine "$box" "$file" invalid-delivery-retry-time
    return
  fi

  queue="$(basename "$box")"
  if ! duet_validate_message_session "$file"; then
    reason="$DUET_SESSION_FENCE_REASON"
    duet_deliverd_log "foreign envelope $(basename "$file") -> quarantine ($reason)"
    duet_quarantine_reason "$file" "$reason" || return 1
    duet_foreign_payload_notice "$DUET_TERMINAL_FILE" || return 1
    return 0
  fi
  if ! duet_read_message "$file"; then
    duet_deliverd_log "invalid message $(basename "$file") -> failed"
    duet_move_terminal "$file" failed || return 1
    duet_write_sidecar "$DUET_TERMINAL_FILE" noticed invalid-message || return 1
    return 0
  fi

  # The physical queue is part of the routing capability; immutable metadata
  # cannot redirect a named queue to another member.
  case "$queue" in
    leader)
      [ "$DUET_MESSAGE_RECIPIENT" = leader ] || {
        duet_finish_quarantine "$box" "$file" recipient-queue-mismatch
        return
      }
      target_is_symbolic=1
      ;;
    promotions)
      [ "$DUET_MESSAGE_ORIGIN" = SYSTEM ] \
        && [ "$DUET_MESSAGE_HANDOFF_MODE" = MANUAL ] \
        && [ "$DUET_MESSAGE_RECIPIENT" != leader ] || {
          duet_finish_quarantine "$box" "$file" invalid-promotion-envelope
          return
        }
      target_is_symbolic=1
      ;;
    *)
      [ "$DUET_MESSAGE_RECIPIENT" = "$queue" ] || {
        duet_finish_quarantine "$box" "$file" recipient-queue-mismatch
        return
      }
      ;;
  esac

  # Read the mutable delivery phase before applying term fences. Sanctioned
  # promotion paths defer their CAS behind INFLIGHT/ENTER_ONLY/CLEAR_RETRY
  # roots. If an
  # unsafe raw leader edit bypassed that guard, keep the stale uncertain root
  # as a poison fence: never submit stale work and never release its pane for a
  # later paste while composer ownership is unknown.
  phase="$(cat "$file.phase" 2>/dev/null || true)"
  case "$phase" in
    '')
      if [ -e "$file.phase" ]; then
        duet_finish_quarantine "$box" "$file" empty-delivery-phase
        return
      fi
      ;;
    READY|ENTER_ONLY|INFLIGHT|CLEAR_RETRY) : ;;
    *)
      duet_finish_quarantine "$box" "$file" "invalid-delivery-phase-$phase"
      return
      ;;
  esac

  duet_read_leader_state || return 1
  current_term="$DUET_CURRENT_TERM"
  current_leader="$DUET_CURRENT_LEADER"
  if [ "$DUET_MESSAGE_ORIGIN" = LEADER ] \
      && { [ "$DUET_MESSAGE_TERM" != "$current_term" ] \
           || [ "$DUET_MESSAGE_SENDER" != "$current_leader" ] \
           || [ "$DUET_MESSAGE_LEADER_AT_SEND" != "$current_leader" ]; }; then
    case "$phase" in
      ENTER_ONLY|INFLIGHT|CLEAR_RETRY)
        duet_deliverd_log "poison-fenced stale uncertain $DUET_MESSAGE_ID; operator recovery required"
        duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 8 ))" || return 1
        return 0
        ;;
    esac
    duet_finish_quarantine "$box" "$file" stale-leader-term
    return
  fi
  if [ "$queue" = promotions ]; then
    if [ "$DUET_MESSAGE_TERM" != "$current_term" ] \
        || [ "$DUET_MESSAGE_RECIPIENT" != "$current_leader" ] \
        || [ "$DUET_MESSAGE_DEDUPE" != "promotion-$DUET_MESSAGE_TERM" ]; then
      duet_finish_quarantine "$box" "$file" obsolete-promotion
      return
    fi
  elif [ "$DUET_MESSAGE_ORIGIN" = SYSTEM ]; then
    case "$DUET_MESSAGE_DEDUPE" in
      promotion-fanout-*)
        if [ "$DUET_MESSAGE_TERM" != "$current_term" ] \
            || [ "$DUET_MESSAGE_LEADER_AT_SEND" != "$current_leader" ]; then
          duet_finish_quarantine "$box" "$file" stale-promotion-fanout
          return
        fi
        ;;
    esac
  fi

  payload="$(duet_build_payload)"
  [ "$DUET_MESSAGE_MODE" != INTERRUPT ] || interrupt=1

  if [ "$queue" = promotions ]; then
    DUET_TARGET_NAME="$DUET_MESSAGE_RECIPIENT"
  elif [ "$DUET_MESSAGE_RECIPIENT" = leader ]; then
    DUET_TARGET_NAME="$current_leader"
  else
    DUET_TARGET_NAME="$DUET_MESSAGE_RECIPIENT"
  fi
  DUET_TARGET_PANE="$(duet_roster_pane_for_name "$DUET_TARGET_NAME")"
  target_term="$current_term"
  DUET_PROCESS_TARGET_NAME="$DUET_TARGET_NAME"
  DUET_PROCESS_TARGET_PANE="$DUET_TARGET_PANE"

  bound_pane="$(cat "$file.target_pane" 2>/dev/null || true)"
  bound_name="$(cat "$file.target_name" 2>/dev/null || true)"
  bound_term="$(cat "$file.target_term" 2>/dev/null || true)"
  if [ -n "$bound_pane$bound_name$bound_term" ]; then
    if [ -n "$bound_pane" ] && [ -n "$bound_name" ] && [ -n "$bound_term" ]; then
      binding_complete=1
    elif [ "$phase" = CLEAR_RETRY ]; then
      duet_deliverd_log "poison-fenced CLEAR_RETRY with incomplete target binding for $DUET_MESSAGE_ID"
      duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 8 ))" || return 1
      return 0
    elif [ "$phase" = ENTER_ONLY ]; then
      duet_finish_quarantine "$box" "$file" incomplete-target-binding
      return
    elif [ "$phase" = INFLIGHT ]; then
      # All binding fields are published before INFLIGHT. An incomplete set can
      # only be the crash tail of clearing them after a proven NOT_LANDED/DEAD
      # outcome from an older daemon, so it is safe to resume as READY.
      duet_write_sidecar "$file" phase READY || return 1
      duet_clear_target_binding "$file"
      phase=READY
      bound_pane=""; bound_name=""; bound_term=""
    else
      duet_clear_target_binding "$file"
      bound_pane=""; bound_name=""; bound_term=""
    fi
  fi
  # The binding is published before INFLIGHT. A crash in that small window is
  # provably pre-paste, so an empty/READY phase may safely discard it and
  # resolve a newly promoted symbolic leader.
  if [ -n "$binding_complete" ] \
      && [ "$phase" != ENTER_ONLY ] && [ "$phase" != INFLIGHT ] \
      && [ "$phase" != CLEAR_RETRY ]; then
    duet_clear_target_binding "$file"
    bound_pane=""; bound_name=""; bound_term=""; binding_complete=""
  fi
  if [ -n "$binding_complete" ]; then
    if [ "$bound_name" != "$DUET_TARGET_NAME" ] \
        || [ "$bound_pane" != "$DUET_TARGET_PANE" ] \
        || { [ -n "$target_is_symbolic" ] && [ "$bound_term" != "$target_term" ]; }; then
      case "$phase" in
        ENTER_ONLY|INFLIGHT|CLEAR_RETRY)
          # A raw leader-file edit can bypass the sanctioned pre-CAS
          # ownership fence.  Never terminalize and release the old pane in
          # that state; retain the original binding as a poison fence.
          duet_deliverd_log "poison-fenced target change after possible landing for $DUET_MESSAGE_ID"
          duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 8 ))" || return 1
          return 0
          ;;
      esac
      duet_finish_quarantine "$box" "$file" target-changed-after-possible-landing
      return
    fi
    DUET_TARGET_NAME="$bound_name"
    DUET_TARGET_PANE="$bound_pane"
    target_term="$bound_term"
  fi

  # Persisted attempt counts are untrusted recovery state. Validate them before
  # any composer operation; an invalid or exhausted counter cannot earn one
  # additional delivery attempt.
  attempts="$(cat "$file.tries" 2>/dev/null || true)"
  if [ -z "$attempts" ]; then
    attempts=0
  elif ! duet_decimal_d10 "$attempts"; then
    duet_finish_quarantine "$box" "$file" invalid-delivery-attempt-count
    return
  else
    attempts="$DUET_DECIMAL_VALUE"
  fi
  if [ "$attempts" = 9999999999 ]; then
    duet_finish_quarantine "$box" "$file" delivery-attempt-count-exhausted
    return
  fi
  max="${DUET_DELIVERY_MAX_ATTEMPTS:-5}"
  case "$max" in ''|*[!0-9]*) max=5;; esac

  target_harness="$(duet_roster_harness_for_name "$DUET_TARGET_NAME")"
  if [ -z "$DUET_TARGET_PANE" ] \
      || ! duet_roster_member_alive "$DUET_TARGET_NAME"; then
    rc=$DUET_SEND_DEAD
  elif [ "$phase" = CLEAR_RETRY ]; then
    clear_recovery=1
    DUET_PROCESS_ATTEMPTED=1
    enter_token="$(cat "$file.enter_token" 2>/dev/null || true)"
    landing_evidence="$(cat "$file.landing_observed" 2>/dev/null || true)"
    DUET_SEND_COMPOSER_CLEAR=""
    if [ "$target_harness" != codex ] || [ "$landing_evidence" != marker ] \
        || [ -z "$enter_token" ]; then
      rc=$DUET_SEND_LANDED_UNVERIFIED
    elif duet_clear_refused_composer "$DUET_TARGET_PANE" "$enter_token"; then
      rc=0
    else
      rc=$?
    fi
  elif [ "$phase" = ENTER_ONLY ] \
      || { [ "$phase" = INFLIGHT ] && [ -n "$binding_complete" ]; }; then
    continuation=1
    DUET_PROCESS_ATTEMPTED=1
    enter_token="$(cat "$file.enter_token" 2>/dev/null || true)"
    landing_evidence="$(cat "$file.landing_observed" 2>/dev/null || true)"
    DUET_SEND_COMPOSER_CLEAR=""
    DUET_SEND_LANDING_OBSERVED=""
    DUET_SEND_ENTER_TOKEN=""
    if duet_send_enter_only "$DUET_TARGET_PANE" "$payload" "$enter_token" \
        "$target_harness"; then
      rc=0
    else
      rc=$?
    fi
    # The exact marker token is the capability tying collapsed composer state
    # to this message. Publish it before the coarser marker-kind evidence so a
    # crash can never leave clearable marker evidence without its token.
    if [ -n "${DUET_SEND_ENTER_TOKEN:-}" ]; then
      enter_token="$DUET_SEND_ENTER_TOKEN"
      duet_write_sidecar "$file" enter_token "$enter_token" || return 1
    fi
    if [ -n "${DUET_SEND_LANDING_OBSERVED:-}" ]; then
      landing_evidence="$DUET_SEND_LANDING_OBSERVED"
      duet_write_sidecar "$file" landing_observed "$landing_evidence" || return 1
    fi
  else
    if [ -z "$binding_complete" ]; then
      duet_write_sidecar "$file" target_name "$DUET_TARGET_NAME" || return 1
      duet_write_sidecar "$file" target_pane "$DUET_TARGET_PANE" || return 1
      duet_write_sidecar "$file" target_term "$target_term" || return 1
    fi
    # A new full attempt must never inherit a capability from a prior pane or
    # a prior safe reset.  Remove it before publishing INFLIGHT.
    rm -f "$file.enter_token" "$file.landing_observed" 2>/dev/null || true
    duet_write_sidecar "$file" phase INFLIGHT || {
      duet_deliverd_log "could not persist INFLIGHT for $DUET_MESSAGE_ID; daemon halting"
      return 1
    }
    DUET_PROCESS_ATTEMPTED=1
    if duet_send_verified "$DUET_TARGET_PANE" "$payload" "$interrupt" "$target_harness"; then rc=0; else rc=$?; fi
    # Publish causal landing capabilities immediately on verifier return and
    # before later state transitions. This minimizes the only unavoidable
    # crash window between observing the live composer and durable recovery.
    if [ -n "${DUET_SEND_ENTER_TOKEN:-}" ]; then
      enter_token="$DUET_SEND_ENTER_TOKEN"
      duet_write_sidecar "$file" enter_token "$enter_token" || return 1
    fi
    if [ -n "${DUET_SEND_LANDING_OBSERVED:-}" ]; then
      landing_evidence="$DUET_SEND_LANDING_OBSERVED"
      duet_write_sidecar "$file" landing_observed "$landing_evidence" || return 1
    fi
    if [ -n "${DUET_SEND_COLLAPSED:-}" ]; then
      duet_deliverd_log "observed collapsed composer for $DUET_MESSAGE_ID -> $DUET_TARGET_NAME"
    fi
  fi

  if [ -n "$continuation" ] && [ "$rc" -ne 0 ] \
      && [ "$rc" -ne "$DUET_SEND_LANDED_UNVERIFIED" ] \
      && [ "$rc" -ne "$DUET_SEND_COMPOSER_REFUSED" ]; then
    duet_finish_quarantine "$box" "$file" "enter-only-outcome-$rc"
    return
  fi

  # CLEAR_RETRY is a durable, pane-owning phase.  It is published before any
  # Escape/Ctrl-U recovery keys, so a crash either repeats only the idempotent
  # clear or observes the already-empty composer.  No full payload can repaste
  # until this branch verifies the owned marker is absent and resets READY.
  if [ -n "$clear_recovery" ]; then
    case "$rc" in
      0)
        [ -n "${DUET_SEND_COMPOSER_CLEAR:-}" ] || {
          duet_deliverd_log "clear recovery lacked empty-composer evidence for $DUET_MESSAGE_ID"
          duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 8 ))" || return 1
          return 0
        }
        duet_deliverd_log "cleared refused Codex composer for $DUET_MESSAGE_ID; requeueing stable ID"
        if [ -z "$target_is_symbolic" ] && [ "$attempts" -ge "$max" ]; then
          duet_move_terminal "$file" failed || return 1
          duet_delivery_failure_notice "$DUET_TARGET_NAME" "$DUET_MESSAGE_ID" \
            COMPOSER_REFUSED "$DUET_TERMINAL_FILE" || return 1
        else
          # READY is the crash-safe commit point: after it, stale capability
          # sidecars are harmless and ordinary recovery may discard them.
          duet_write_sidecar "$file" phase READY || return 1
          rm -f "$file.enter_token" "$file.landing_observed" "$file.retry_at" \
            2>/dev/null || true
          duet_set_backoff "$file" "$((attempts > 0 ? attempts : 1))" || return 1
          duet_clear_target_binding "$file"
        fi
        ;;
      "$DUET_SEND_LANDED_UNVERIFIED")
        duet_deliverd_log "refused Codex composer remains uncleared for $DUET_MESSAGE_ID"
        duet_write_sidecar "$file" phase CLEAR_RETRY || return 1
        duet_set_backoff "$file" "$((attempts > 0 ? attempts : 1))" || return 1
        ;;
      "$DUET_SEND_DEAD")
        # The vanished pane cannot retain a dirty composer.  Reuse ordinary
        # DEAD handling below to retry/reroute or terminalize as appropriate.
        :
        ;;
      *)
        duet_deliverd_log "unexpected clear-recovery outcome $rc for $DUET_MESSAGE_ID"
        duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 8 ))" || return 1
        return 0
        ;;
    esac
    [ "$rc" = "$DUET_SEND_DEAD" ] || return 0
  fi
  case "$rc" in
    0)
      duet_deliverd_log "delivered $DUET_MESSAGE_ID -> $DUET_TARGET_NAME"
      duet_move_terminal "$file" delivered || return 1
      [ "$DUET_MESSAGE_MODE" != INTERRUPT ] \
        || duet_complete_interrupt_supersede "$box" "$DUET_TERMINAL_FILE" || return 1
      ;;
    "$DUET_SEND_LANDED_UNVERIFIED")
      if [ -n "$continuation" ]; then
        duet_write_sidecar "$file" phase ENTER_ONLY || return 1
        landing_clearable=""
        case "$landing_evidence" in
          probe) landing_clearable=1 ;;
          marker) [ -z "$enter_token" ] || landing_clearable=1 ;;
          '') [ -z "$enter_token" ] || landing_clearable=1 ;;
        esac
        if [ -n "${DUET_SEND_COMPOSER_CLEAR:-}" ] \
            && [ -n "$landing_clearable" ]; then
          duet_finish_quarantine "$box" "$file" enter-only-unverified
        else
          attempts=$((attempts + 1))
          duet_deliverd_log "composer ownership remains uncertain for $DUET_MESSAGE_ID; handoff remains fenced"
          duet_write_sidecar "$file" tries "$attempts" || return 1
          duet_set_backoff "$file" "$attempts" || return 1
        fi
      else
        duet_deliverd_log "enter-only continuation scheduled for $DUET_MESSAGE_ID"
        # Persist the marker capability before its kind for crash safety.
        if [ -n "${DUET_SEND_ENTER_TOKEN:-}" ]; then
          duet_write_sidecar "$file" enter_token "$DUET_SEND_ENTER_TOKEN" || return 1
        fi
        if [ -n "${DUET_SEND_LANDING_OBSERVED:-}" ]; then
          duet_write_sidecar "$file" landing_observed \
            "$DUET_SEND_LANDING_OBSERVED" || return 1
        fi
        duet_write_sidecar "$file" phase ENTER_ONLY || return 1
        duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 1 ))" || return 1
      fi
      ;;
    "$DUET_SEND_COMPOSER_REFUSED")
      # Only a causally observed Codex marker can reach this phase.  Publish
      # its exact capability before the phase, then clear on a later pass.
      if [ "$target_harness" != codex ] \
          || [ "${DUET_SEND_LANDING_OBSERVED:-$landing_evidence}" != marker ] \
          || [ -z "${DUET_SEND_ENTER_TOKEN:-$enter_token}" ]; then
        duet_deliverd_log "refused-composer outcome lacked Codex marker evidence for $DUET_MESSAGE_ID"
        duet_write_sidecar "$file" phase ENTER_ONLY || return 1
        duet_write_sidecar "$file" retry_at "$(( $(date +%s) + 8 ))" || return 1
        return 0
      fi
      enter_token="${DUET_SEND_ENTER_TOKEN:-$enter_token}"
      duet_write_sidecar "$file" enter_token "$enter_token" || return 1
      duet_write_sidecar "$file" landing_observed marker || return 1
      attempts=$((attempts + 1))
      duet_write_sidecar "$file" tries "$attempts" || return 1
      duet_write_sidecar "$file" phase CLEAR_RETRY || return 1
      duet_set_backoff "$file" "$attempts" || return 1
      duet_deliverd_log "Codex composer refused Enter for $DUET_MESSAGE_ID; clear recovery scheduled"
      ;;
    "$DUET_SEND_NOT_LANDED")
      attempts=$((attempts + 1))
      if [ -z "$target_is_symbolic" ] && [ "$attempts" -ge "$max" ]; then
        duet_deliverd_log "failed $DUET_MESSAGE_ID after $attempts NOT_LANDED outcomes"
        duet_move_terminal "$file" failed || return 1
        duet_delivery_failure_notice "$DUET_TARGET_NAME" "$DUET_MESSAGE_ID" \
          NOT_LANDED "$DUET_TERMINAL_FILE" || return 1
      else
        duet_write_sidecar "$file" phase READY || return 1
        duet_write_sidecar "$file" tries "$attempts" || return 1
        duet_set_backoff "$file" "$attempts" || return 1
        duet_clear_target_binding "$file"
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
        duet_write_sidecar "$file" phase READY || return 1
        duet_write_sidecar "$file" tries "$attempts" || return 1
        duet_set_backoff "$file" "$attempts" || return 1
        duet_clear_target_binding "$file"
      fi
      ;;
    *) duet_finish_quarantine "$box" "$file" "unexpected-verifier-outcome-$rc" ;;
  esac
}

duet_candidate_target(){
  local queue="${1:?queue required}" file="${2:?message required}"
  local phase bound_name bound_pane
  phase="$(cat "$file.phase" 2>/dev/null || true)"
  case "$phase" in
    ENTER_ONLY|INFLIGHT|CLEAR_RETRY)
      bound_name="$(cat "$file.target_name" 2>/dev/null || true)"
      bound_pane="$(cat "$file.target_pane" 2>/dev/null || true)"
      if [ -n "$bound_name" ] && [ -n "$bound_pane" ]; then
        # Ownership follows the durable physical binding, even after an unsafe
        # raw leader edit.  This coalesces newer traffic targeting that old
        # pane behind the poison-fenced root.
        DUET_CANDIDATE_NAME="$bound_name"
        DUET_CANDIDATE_PANE="$bound_pane"
        DUET_CANDIDATE_KEY="pane:$bound_pane"
        return 0
      fi
      ;;
  esac
  case "$queue" in
    promotions) DUET_CANDIDATE_NAME="$(duet_raw_message_field "$file" recipient)" ;;
    leader)
      duet_read_leader_state || return 1
      DUET_CANDIDATE_NAME="$DUET_CURRENT_LEADER"
      ;;
    *) DUET_CANDIDATE_NAME="$queue" ;;
  esac
  DUET_CANDIDATE_PANE="$(duet_roster_pane_for_name "$DUET_CANDIDATE_NAME")"
  if [ -n "$DUET_CANDIDATE_PANE" ]; then
    DUET_CANDIDATE_KEY="pane:$DUET_CANDIDATE_PANE"
  else
    DUET_CANDIDATE_KEY="unresolved:$queue"
  fi
}

# One candidate per queue. Promotions, uncertain composers, and interrupts
# block their pane during backoff; an ordinary not-due head does not block a
# due head in another queue mapped to that pane.
duet_collect_candidates(){
  local box queue file phase priority order base message_term
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    duet_queue_next "$box" || continue
    file="$DUET_NEXT_MESSAGE"
    queue="$(basename "$box")"
    if [ "$queue" = promotions ]; then
      # A crash-recovery promotion intent can be durable before its CAS. When
      # an uncertain composer defers that CAS, reconciliation deliberately
      # leaves the intent active; it is not yet a deliverable notice.
      message_term="$(duet_raw_message_field "$file" term)"
      duet_read_leader_state || return 1
      [ "$message_term" = "$DUET_CURRENT_TERM" ] || continue
    fi
    phase="$(cat "$file.phase" 2>/dev/null || true)"
    base="$(basename "$file")"
    # A composer that may already contain bytes predates the promotion and must
    # be resolved or retained as a poison fence before any new paste. The
    # promotion is still first among messages that have not possibly landed.
    if [ "$phase" = ENTER_ONLY ] || [ "$phase" = INFLIGHT ] \
        || [ "$phase" = CLEAR_RETRY ]; then
      priority=0
    elif [ "$queue" = promotions ]; then
      priority=1
    elif [[ "$base" = I-* ]]; then
      priority=2
    else
      priority=3
    fi
    if ! duet_retry_due "$file" && [ "$priority" -eq 3 ]; then
      continue
    fi
    order="$(duet_raw_message_field "$file" order)"
    case "$order" in ''|*[!0-9]*) order=0000000000;; esac
    duet_candidate_target "$queue" "$file" || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$priority" "$order" "$DUET_CANDIDATE_KEY" "$box" "$file"
  done
}

duet_deliverd_pass(){
  local candidates seen priority order key box file
  if ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
    duet_deliverd_log "roster validation failed; daemon halting"
    return 1
  fi
  duet_reconcile_terminal_moves || return 1
  duet_reconcile_promotion_intents || return 1
  duet_reconcile_interrupt_supersedes || return 1
  duet_reconcile_failure_notices || return 1
  duet_reconcile_foreign_notices || return 1
  duet_reconcile_promotion_fanout || return 1

  candidates="$(mktemp "${DUET_DIR:?}/.schedule.XXXXXX")" || return 1
  seen="$(mktemp "${DUET_DIR:?}/.schedule-seen.XXXXXX")" || {
    rm -f "$candidates"
    return 1
  }
  if ! duet_collect_candidates | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n > "$candidates"; then
    rm -f "$candidates" "$seen"
    return 1
  fi
  while IFS=$'\t' read -r priority order key box file; do
    [ -n "$file" ] || continue
    grep -qxF "$key" "$seen" 2>/dev/null && continue
    printf '%s\n' "$key" >> "$seen" || { rm -f "$candidates" "$seen"; return 1; }
    if ! duet_process_one "$box" "$file"; then
      rm -f "$candidates" "$seen"
      return 1
    fi
  done < "$candidates"
  rm -f "$candidates" "$seen"
  duet_reconcile_promotion_fanout || return 1
}

duet_deliverd_cleanup(){
  local daemon_pid="${DUET_DAEMON_PID:-${BASHPID:-$$}}" recorded
  recorded="$(cat "${DUET_DIR:-}/daemon.pid" 2>/dev/null || true)"
  [ "$recorded" != "$daemon_pid" ] || rm -f "$DUET_DIR/daemon.pid"
  [ -z "${DUET_DIR:-}" ] || duet_lock_release "$DUET_DIR/.delivery.lock" 2>/dev/null || true
  [ -z "${DUET_DIR:-}" ] || duet_lock_release "$DUET_DIR/.daemon.lock" 2>/dev/null || true
}

duet_deliverd_main(){
  local session_arg="" session_id_arg="" inherited_session="${DUET_SESSION:-}" cfg
  local env_server_pid actual_server_pid pid_tmp poll
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session)
        [ "$#" -ge 2 ] || { echo "usage: duet-deliverd.sh [--session <id|dir|duet.env>]" >&2; return 2; }
        session_arg="$2"
        shift 2
        ;;
      --session-id)
        [ "$#" -ge 2 ] || { echo "usage: duet-deliverd.sh --session <id|dir|duet.env> --session-id <id>" >&2; return 2; }
        session_id_arg="$2"
        shift 2
        ;;
      *) echo "duet: unknown daemon option '$1'" >&2; return 2 ;;
    esac
  done
  duet_resolve_config "$session_arg" 0 || return 1
  cfg="$DUET_RESOLVED_CONFIG"
  # Process identity is fenced by the literal canonical config path in argv.
  # Normalize manual/bare-id/lexical invocations once so liveness and shutdown
  # checks cannot disagree with the daemon that successfully loaded them.
  if [ "$session_arg" != "$cfg" ]; then
    exec bash "$SELF_DIR/duet-deliverd.sh" \
      --session "$cfg" --session-id "$session_id_arg"
  fi
  unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
  unset DUET_SESSION DUET_SESSION_ID DUET_WORKDIR_KEY DUET_INITIATOR DUET_INITIATOR_PANE
  # shellcheck disable=SC1090
  . "$cfg" || { echo "duet: daemon could not load pinned config: $cfg" >&2; return 1; }
  duet_validate_loaded_session "$inherited_session" "$cfg" || return 1
  [ "$session_id_arg" = "$DUET_SESSION_ID" ] || {
    echo "duet: daemon command identity does not match pinned session $DUET_SESSION_ID." >&2
    return 1
  }
  DUET_CONFIG="$cfg"
  export DUET_CONFIG DUET_SESSION
  [ ! -f "$DUET_DIR/.ended" ] || return 0
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

  duet_lock_acquire "$DUET_DIR/.daemon.lock" 40 || {
    echo "duet: another delivery daemon already owns this session." >&2
    return 1
  }
  DUET_DAEMON_PID="${BASHPID:-$$}"
  trap duet_deliverd_cleanup EXIT
  trap 'exit 0' INT TERM
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
