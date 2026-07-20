#!/usr/bin/env bash
# Inspect one tmux/bash duet session. Human diagnostics may use the ambient
# `current` link, but --session, DUET_CONFIG, and DUET_SESSION take precedence.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

duet_status_usage(){
  echo "usage: duet-status.sh [--session <id|directory|duet.env>]" >&2
}

duet_diag_load_session(){
  local session_arg="${1:-}" allow_current="${2:-1}"
  local expected_session="" inherited_session="${DUET_SESSION:-}" cfg

  if [ -n "$session_arg" ]; then
    case "$session_arg" in */*) : ;; *) expected_session="$session_arg" ;; esac
  elif [ -n "$inherited_session" ]; then
    expected_session="$inherited_session"
  fi

  duet_resolve_config "$session_arg" "$allow_current" || return 1
  cfg="$DUET_RESOLVED_CONFIG"

  # Do not let inherited values fill omissions in a malformed config.
  unset DUET_DIR DUET_STATE_ROOT WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
  unset DUET_SESSION DUET_SESSION_ID DUET_WORKDIR_KEY DUET_INITIATOR DUET_INITIATOR_PANE
  # shellcheck disable=SC1090
  . "$cfg" 2>/dev/null || {
    echo "duet: could not load session config: $cfg" >&2
    return 1
  }
  duet_validate_loaded_session "$expected_session" "$cfg" || return 1
  [ -f "$DUET_DIR/roster.tsv" ] || {
    echo "duet: session roster is missing: $DUET_DIR/roster.tsv" >&2
    return 1
  }

  DUET_CONFIG="$cfg"
  DUET_SESSION="$DUET_SESSION_ID"
  DUET_DIAG_CONFIG="$cfg"
  export DUET_CONFIG DUET_SESSION
}

duet_diag_workdir_fence(){
  local canonical key active_file active_target=""
  DUET_DIAG_WORKDIR_KEY="${DUET_WORKDIR_KEY:-}"
  DUET_DIAG_WORKDIR_FENCE=invalid-workdir
  canonical="$(cd "${WORKDIR:-}" 2>/dev/null && pwd -P)" || return 0
  key="$(duet_workdir_key "$canonical" 2>/dev/null)" || return 0
  if [ -n "$DUET_DIAG_WORKDIR_KEY" ] && [ "$DUET_DIAG_WORKDIR_KEY" != "$key" ]; then
    DUET_DIAG_WORKDIR_FENCE=key-mismatch
    return 0
  fi
  DUET_DIAG_WORKDIR_KEY="$key"
  active_file="${DUET_STATE_ROOT:?}/workdirs/$key.active"
  if [ -f "$active_file" ]; then
    active_target="$(cat "$active_file" 2>/dev/null || true)"
    if [ "$active_target" = "$DUET_DIR" ]; then
      if [ -f "$DUET_DIR/.ended" ]; then
        DUET_DIAG_WORKDIR_FENCE=stale-ended-owner
      else
        DUET_DIAG_WORKDIR_FENCE=owned
      fi
    else
      DUET_DIAG_WORKDIR_FENCE="other:${active_target:-invalid}"
    fi
  elif [ -f "$DUET_DIR/.ended" ]; then
    DUET_DIAG_WORKDIR_FENCE=released
  else
    DUET_DIAG_WORKDIR_FENCE=missing
  fi
}

duet_diag_inbox_depth(){
  local queue="${1:?queue required}" box="$DUET_DIR/inbox/${1:?queue required}"
  local file count=0
  [ -d "$box" ] || { printf '0'; return; }
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# Sets DUET_DIAG_ALIVE and DUET_DIAG_ACTUAL_PID. A pane is alive only when its
# current pane PID still matches the roster, not merely when its server-local
# pane ID happens to exist.
duet_diag_pane_state(){
  local pane="${1:-}" recorded_pid="${2:-}" data actual_pane actual_pid
  DUET_DIAG_ALIVE=no
  DUET_DIAG_ACTUAL_PID="-"
  case "$recorded_pid" in ''|*[!0-9]*) DUET_DIAG_ALIVE=invalid-pid; return;; esac
  [ -n "$pane" ] || return
  if ! duet_tmux_server_matches; then
    DUET_DIAG_ALIVE=server-mismatch
    return
  fi
  data="$(_duet_tmux display-message -p -t "$pane" \
    '#{pane_id}|#{pane_pid}' 2>/dev/null || true)"
  [ -n "$data" ] || return
  actual_pane="${data%%|*}"
  actual_pid="${data#*|}"
  DUET_DIAG_ACTUAL_PID="${actual_pid:--}"
  [ "$actual_pane" = "$pane" ] || return
  if [ "$actual_pid" = "$recorded_pid" ]; then
    DUET_DIAG_ALIVE=yes
  else
    DUET_DIAG_ALIVE=pid-mismatch
  fi
}

duet_diag_read_watchdog(){
  local file="$DUET_DIR/watchdog" state
  DUET_DIAG_WATCHDOG_SESSION="-"
  DUET_DIAG_WATCHDOG_TERM="-"
  DUET_DIAG_WATCHDOG_LEADER="-"
  DUET_DIAG_WATCHDOG_COUNT=missing
  [ -f "$file" ] || return 0
  state="$(awk -F '\t' '
    $1 == "session" { session=$2 }
    $1 == "term" { term=$2 }
    $1 == "leader" { leader=$2 }
    $1 == "count" { count=$2 }
    END { print session "|" term "|" leader "|" count }
  ' "$file" 2>/dev/null)"
  IFS='|' read -r DUET_DIAG_WATCHDOG_SESSION DUET_DIAG_WATCHDOG_TERM \
    DUET_DIAG_WATCHDOG_LEADER DUET_DIAG_WATCHDOG_COUNT <<< "$state"
  [ -n "$DUET_DIAG_WATCHDOG_SESSION" ] || DUET_DIAG_WATCHDOG_SESSION="-"
  [ -n "$DUET_DIAG_WATCHDOG_TERM" ] || DUET_DIAG_WATCHDOG_TERM="-"
  [ -n "$DUET_DIAG_WATCHDOG_LEADER" ] || DUET_DIAG_WATCHDOG_LEADER="-"
  case "$DUET_DIAG_WATCHDOG_COUNT" in
    ''|*[!0-9]*) DUET_DIAG_WATCHDOG_COUNT=invalid ;;
  esac
}

duet_diag_read_no_successor(){
  local file="$DUET_DIR/no-successor"
  DUET_DIAG_NO_SUCCESSOR=no
  DUET_DIAG_NO_SUCCESSOR_TERM="-"
  DUET_DIAG_NO_SUCCESSOR_REASON="-"
  DUET_DIAG_NO_SUCCESSOR_INCUMBENT="-"
  [ "${DUET_CURRENT_LEADER:-}" != NONE ] || DUET_DIAG_NO_SUCCESSOR=yes
  [ -f "$file" ] || return 0
  DUET_DIAG_NO_SUCCESSOR=yes
  DUET_DIAG_NO_SUCCESSOR_TERM="$(awk -F '\t' \
    '$1 == "term" { print $2; exit }' "$file" 2>/dev/null)"
  DUET_DIAG_NO_SUCCESSOR_REASON="$(awk -F '\t' \
    '$1 == "reason" { sub(/^[^\t]*\t/, ""); print; exit }' "$file" 2>/dev/null)"
  DUET_DIAG_NO_SUCCESSOR_INCUMBENT="$(awk -F '\t' \
    '$1 == "incumbent" || $1 == "failed" { print $2; exit }' "$file" 2>/dev/null)"
  [ -n "$DUET_DIAG_NO_SUCCESSOR_TERM" ] || DUET_DIAG_NO_SUCCESSOR_TERM="-"
  [ -n "$DUET_DIAG_NO_SUCCESSOR_REASON" ] || DUET_DIAG_NO_SUCCESSOR_REASON="-"
  [ -n "$DUET_DIAG_NO_SUCCESSOR_INCUMBENT" ] || DUET_DIAG_NO_SUCCESSOR_INCUMBENT="-"
}

duet_diag_pending_promotions(){
  local file box="$DUET_DIR/inbox/promotions"
  DUET_DIAG_PENDING_PROMOTIONS=0
  DUET_DIAG_PROMOTION_ID="-"
  DUET_DIAG_PROMOTION_TERM="-"
  DUET_DIAG_PROMOTION_TARGET="-"
  [ -d "$box" ] || return 0
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    DUET_DIAG_PENDING_PROMOTIONS=$((DUET_DIAG_PENDING_PROMOTIONS + 1))
    [ "$DUET_DIAG_PROMOTION_ID" != "-" ] && continue
    DUET_DIAG_PROMOTION_ID="$(awk -F '\t' '$1 == "id" { print $2; exit }' "$file")"
    DUET_DIAG_PROMOTION_TERM="$(awk -F '\t' '$1 == "term" { print $2; exit }' "$file")"
    DUET_DIAG_PROMOTION_TARGET="$(awk -F '\t' '$1 == "recipient" { print $2; exit }' "$file")"
  done
}

duet_diag_print_summary(){
  local daemon_pid daemon_state lifecycle symbolic_depth total_pending
  daemon_pid="$(cat "$DUET_DIR/daemon.pid" 2>/dev/null || true)"
  [ -n "$daemon_pid" ] || daemon_pid="-"
  if duet_daemon_alive; then daemon_state=alive; else daemon_state=DEAD; fi
  if [ -f "$DUET_DIR/.ended" ]; then
    lifecycle=ended
  elif [ -f "$DUET_DIR/.draining" ]; then
    lifecycle=draining
  else
    lifecycle=active
  fi
  symbolic_depth="$(duet_diag_inbox_depth leader)"
  total_pending="$(duet_pending_count 2>/dev/null || printf '?')"
  duet_diag_read_watchdog
  duet_diag_read_no_successor
  duet_diag_pending_promotions
  duet_diag_workdir_fence

  printf 'session       : %s\n' "$DUET_SESSION_ID"
  printf 'session dir   : %s\n' "$DUET_DIR"
  printf 'workdir       : %s\n' "${WORKDIR:-?}"
  printf 'workdir fence : %s key=%s\n' "$DUET_DIAG_WORKDIR_FENCE" \
    "${DUET_DIAG_WORKDIR_KEY:--}"
  printf 'lifecycle     : %s\n' "$lifecycle"
  printf 'leadership    : term=%s leader=%s\n' "$DUET_CURRENT_TERM" "$DUET_CURRENT_LEADER"
  printf 'daemon        : %s pid=%s\n' "$daemon_state" "$daemon_pid"
  printf 'watchdog      : count=%s term=%s leader=%s\n' \
    "$DUET_DIAG_WATCHDOG_COUNT" "$DUET_DIAG_WATCHDOG_TERM" \
    "$DUET_DIAG_WATCHDOG_LEADER"
  printf 'no successor  : %s' "$DUET_DIAG_NO_SUCCESSOR"
  if [ "$DUET_DIAG_NO_SUCCESSOR" = yes ]; then
    printf ' term=%s incumbent=%s reason=%s' "$DUET_DIAG_NO_SUCCESSOR_TERM" \
      "$DUET_DIAG_NO_SUCCESSOR_INCUMBENT" "$DUET_DIAG_NO_SUCCESSOR_REASON"
  fi
  printf '\n'
  printf 'queues        : total=%s symbolic-leader=%s promotions=%s' \
    "$total_pending" "$symbolic_depth" "$DUET_DIAG_PENDING_PROMOTIONS"
  if [ "$DUET_DIAG_PENDING_PROMOTIONS" -gt 0 ]; then
    printf ' first=%s term=%s target=%s' "$DUET_DIAG_PROMOTION_ID" \
      "$DUET_DIAG_PROMOTION_TERM" "$DUET_DIAG_PROMOTION_TARGET"
  fi
  printf '\n'
}

duet_diag_print_roster(){
  local name harness pane recorded_pid rank spawned role eligibility ready depth
  printf '\n%-12s %-8s %4s %-8s %-11s %-6s %-8s %-12s %-5s %5s\n' \
    NAME HARNESS RANK ROLE ELIGIBILITY PANE PID ALIVE READY INBOX
  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    [ "$name" != name ] || continue
    [ -n "$name" ] || continue
    duet_diag_pane_state "$pane" "$recorded_pid"
    if [ "$name" = "$DUET_CURRENT_LEADER" ]; then role=leader; else role=worker; fi
    if [ -f "$DUET_DIR/failed-leaders/$name" ]; then
      eligibility=excluded
    elif [ "$DUET_DIAG_ALIVE" != yes ]; then
      eligibility=unavailable
    elif [ "$role" = leader ]; then
      eligibility=incumbent
    else
      eligibility=eligible
    fi
    if [ -f "$DUET_DIR/ready/$name" ]; then ready=yes; else ready=no; fi
    depth="$(duet_diag_inbox_depth "$name")"
    printf '%-12s %-8s %4s %-8s %-11s %-6s %-8s %-12s %-5s %5s\n' \
      "$name" "$harness" "$rank" "$role" "$eligibility" "$pane" \
      "$recorded_pid" "$DUET_DIAG_ALIVE" "$ready" "$depth"
  done < "$DUET_DIR/roster.tsv"
}

duet_status_main(){
  local session_arg=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session)
        [ "$#" -ge 2 ] || { duet_status_usage; return 2; }
        session_arg="$2"
        shift 2
        ;;
      -h|--help) duet_status_usage; return 0 ;;
      *) duet_status_usage; echo "duet: unknown option '$1'" >&2; return 2 ;;
    esac
  done

  duet_diag_load_session "$session_arg" 1 || return 1
  duet_read_leader_state || return 1
  duet_diag_print_summary
  duet_diag_print_roster
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  duet_status_main "$@"
fi
