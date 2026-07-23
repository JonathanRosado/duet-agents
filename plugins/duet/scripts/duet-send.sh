#!/usr/bin/env bash
# Enqueue one message in a pinned duet session. Injection belongs to deliverd.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: duet-send.sh <exact-roster-name|all> [--interrupt] [--from <name>] [--session <id|dir|duet.env>]" >&2
}

recipient="${1:-}"
[ "$#" -gt 0 ] && shift || true
[ -n "$recipient" ] || { usage; exit 2; }
interrupt=""
from=""
session_arg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interrupt) interrupt=1; shift ;;
    --from)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      from="$2"
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      session_arg="$2"
      shift 2
      ;;
    *) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
  esac
done

caller_session_pin="${DUET_SESSION:-}"
caller_self="${DUET_SELF:-}"
duet_capture_caller_identity || {
  echo "duet: caller is not an identifiable tmux pane." >&2
  exit 7
}

duet_resolve_config "$session_arg" 0 || exit 1
cfg="$DUET_RESOLVED_CONFIG"
unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
unset DUET_SESSION DUET_SESSION_ID DUET_INITIATOR DUET_INITIATOR_PANE DUET_WORKDIR_KEY
# shellcheck disable=SC1090
. "$cfg"
DUET_CONFIG="$cfg"
duet_validate_loaded_session "$caller_session_pin" "$cfg" || exit 7
[ ! -f "$DUET_DIR/.ended" ] || {
  echo "duet: session has ended; refusing to enqueue." >&2
  exit 1
}
duet_validate_roster "$DUET_DIR/roster.tsv" || {
  echo "duet: session roster is invalid; refusing to enqueue." >&2
  exit 1
}
duet_daemon_alive || {
  echo "duet: delivery daemon is not alive; message was not queued." >&2
  exit 6
}

duet_caller_roster_name || {
  echo "duet: caller pane is not exactly one member of session '$DUET_SESSION_ID'." >&2
  exit 7
}
sender="$DUET_CALLER_NAME"
if [ -n "$caller_self" ] && [ "$caller_self" != "$sender" ]; then
  echo "duet: identity mismatch: caller pane is '$sender' but DUET_SELF is '$caller_self'." >&2
  exit 7
fi
if [ -n "$from" ] && [ "$from" != "$sender" ]; then
  echo "duet: --from '$from' does not match caller pane identity '$sender'." >&2
  exit 7
fi

if [ "$recipient" != all ] && ! duet_roster_has_name "$recipient"; then
  echo "duet: recipient '$recipient' is not an exact roster name." >&2
  exit 2
fi

body_with_sentinel="$(cat; printf '.')"
body="${body_with_sentinel%.}"
mode=NORMAL
[ -z "$interrupt" ] || mode=INTERRUPT

enqueue_one(){
  local queue="${1:?queue required}" wire_recipient="${2:?recipient required}"
  duet_enqueue_message "$queue" "$sender" "$wire_recipient" "$mode" "$body"
  printf 'duet: queued %s for %s%s\n' \
    "$DUET_ENQUEUED_ID" "$queue" "${interrupt:+ (interrupt)}"
}

if [ "$recipient" != all ]; then
  enqueue_one "$recipient" "$recipient"
  exit 0
fi

fanout=0
while IFS=$'\t' read -r name _harness _pane _pid _rank _spawned; do
  [ "$name" != name ] || continue
  [ "$name" != "$sender" ] || continue
  duet_roster_member_alive "$name" || continue
  enqueue_one "$name" all
  fanout=$((fanout + 1))
done < "$DUET_DIR/roster.tsv"
[ "$fanout" -gt 0 ] || {
  echo "duet: broadcast has no other live recipients." >&2
  exit 8
}
