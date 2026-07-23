#!/usr/bin/env bash
# Inspect exactly one explicitly pinned duet session.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

duet_status_usage(){
  echo "usage: duet-status.sh --session /absolute/session/duet.env" >&2
}

duet_diag_load_session(){
  local session_arg="${1:-}" cfg
  duet_resolve_config "$session_arg" 0 || return 1
  cfg="$DUET_RESOLVED_CONFIG"
  unset DUET_DIR DUET_STATE_ROOT WORKDIR PLUGIN_DIR
  unset DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
  unset DUET_SESSION DUET_SESSION_ID DUET_INITIATOR DUET_INITIATOR_PANE
  # shellcheck disable=SC1090
  . "$cfg" 2>/dev/null || {
    echo "duet: could not load session config: $cfg" >&2
    return 1
  }
  duet_validate_loaded_session "" "$cfg" || return 1
  [ -f "$DUET_DIR/roster.tsv" ] || {
    echo "duet: session roster is missing: $DUET_DIR/roster.tsv" >&2
    return 1
  }
  DUET_CONFIG="$cfg"
  DUET_DIAG_CONFIG="$cfg"
  export DUET_CONFIG DUET_SESSION
}

duet_diag_inbox_depth(){
  local box="$DUET_DIR/inbox/${1:?queue required}" file count=0
  [ -d "$box" ] || { printf '0'; return; }
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# Sets DUET_DIAG_LIVENESS and DUET_DIAG_ACTUAL_PID.
duet_diag_pane_state(){
  local pane="${1:-}" recorded_pid="${2:-}" data actual_pid
  DUET_DIAG_LIVENESS=unknown
  DUET_DIAG_ACTUAL_PID="-"
  case "$recorded_pid" in ''|*[!0-9]*) return;; esac
  [ -n "$pane" ] || return
  duet_tmux_server_matches || return
  data="$(_duet_tmux list-panes -a -F '#{pane_id}|#{pane_pid}' 2>/dev/null)" \
    || return
  actual_pid="$(printf '%s\n' "$data" \
    | awk -F '|' -v pane="$pane" '$1 == pane { print $2; exit }')"
  [ -n "$actual_pid" ] || { DUET_DIAG_LIVENESS=dead; return; }
  DUET_DIAG_ACTUAL_PID="$actual_pid"
  if [ "$actual_pid" = "$recorded_pid" ]; then
    DUET_DIAG_LIVENESS=alive
  else
    DUET_DIAG_LIVENESS=dead
  fi
}

duet_diag_print_summary(){
  local daemon_pid daemon_state lifecycle total_pending
  daemon_pid="$(cat "$DUET_DIR/daemon.pid" 2>/dev/null || true)"
  [ -n "$daemon_pid" ] || daemon_pid="-"
  if duet_daemon_alive; then daemon_state=alive; else daemon_state=dead; fi
  if [ -f "$DUET_DIR/.ended" ]; then lifecycle=ended; else lifecycle=active; fi
  total_pending="$(duet_pending_count 2>/dev/null || printf '?')"

  printf 'session     : %s\n' "$DUET_SESSION_ID"
  printf 'session dir : %s\n' "$DUET_DIR"
  printf 'workdir     : %s\n' "${WORKDIR:-?}"
  printf 'lifecycle   : %s\n' "$lifecycle"
  printf 'initiator   : %s\n' "${DUET_INITIATOR:-?}"
  printf 'daemon      : %s pid=%s\n' "$daemon_state" "$daemon_pid"
  printf 'queues      : total=%s\n' "$total_pending"
  [ ! -f "$DUET_DIR/.unhealthy" ] \
    || printf 'unhealthy   : %s\n' "$(cat "$DUET_DIR/.unhealthy" 2>/dev/null)"
}

duet_diag_print_roster(){
  local name harness pane recorded_pid rank spawned state ready depth
  duet_validate_roster "$DUET_DIR/roster.tsv" || {
    printf '\nroster      : invalid\n'
    return 1
  }
  printf '\n%-12s %-8s %4s %-6s %-8s %-9s %-5s %5s\n' \
    NAME HARNESS RANK PANE PID STATE READY INBOX
  while IFS=$'\t' read -r name harness pane recorded_pid rank spawned; do
    [ "$name" != name ] || continue
    [ -n "$name" ] || continue
    duet_diag_pane_state "$pane" "$recorded_pid"
    state="$DUET_DIAG_LIVENESS"
    [ ! -f "$DUET_DIR/dead/$name" ] || state=dead
    [ ! -f "$DUET_DIR/blocked/$name" ] || state=blocked
    if [ -f "$DUET_DIR/ready/$name" ]; then ready=yes; else ready=no; fi
    depth="$(duet_diag_inbox_depth "$name")"
    printf '%-12s %-8s %4s %-6s %-8s %-9s %-5s %5s\n' \
      "$name" "$harness" "$rank" "$pane" "$recorded_pid" "$state" "$ready" "$depth"
  done < "$DUET_DIR/roster.tsv"
}

duet_status_main(){
  local session_arg=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session)
        [ "$#" -ge 2 ] || { duet_status_usage; return 2; }
        [ -z "$session_arg" ] || {
          echo "duet: --session may be specified only once." >&2
          return 2
        }
        session_arg="$2"
        shift 2
        ;;
      -h|--help) duet_status_usage; return 0 ;;
      *) duet_status_usage; echo "duet: unknown option '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$session_arg" ] || { duet_status_usage; return 2; }

  duet_diag_load_session "$session_arg" || return 1
  duet_validate_roster "$DUET_DIR/roster.tsv" || {
    echo "duet: session roster is invalid: $DUET_DIR/roster.tsv" >&2
    return 1
  }
  duet_diag_print_summary
  duet_diag_print_roster
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  duet_status_main "$@"
fi
