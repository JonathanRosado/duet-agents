#!/usr/bin/env bash
# Enqueue one duet message. Injection is owned exclusively by duet-deliverd.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: duet-send.sh <recipient-name|leader|all> [--interrupt] [--from <name>]" >&2
}

recipient_token="${1:-}"
[ "$#" -gt 0 ] && shift || true
[ -n "$recipient_token" ] || { usage; exit 2; }
interrupt=""
from=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interrupt) interrupt=1; shift ;;
    --from)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      from="$2"
      shift 2
      ;;
    *) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
  esac
done

state_root="${DUET_STATE_ROOT:-$HOME/.duet}"
cfg="${DUET_CONFIG:-$state_root/current/duet.env}"
[ -f "$cfg" ] || { echo "duet: no session ($cfg); run duet-init first." >&2; exit 1; }
# shellcheck disable=SC1090
. "$cfg"
[ ! -f "$DUET_DIR/.ended" ] || { echo "duet: session has ended; refusing to enqueue." >&2; exit 1; }
[ -f "$DUET_DIR/roster.tsv" ] || { echo "duet: session roster is missing." >&2; exit 1; }
duet_read_leader_state
duet_daemon_alive || { echo "duet: delivery daemon is not alive; message was not queued." >&2; exit 6; }

pane_name=""
if [ -n "${TMUX_PANE:-}" ]; then
  pane_name="$(duet_roster_name_for_pane "$TMUX_PANE")"
fi
self_name="${DUET_SELF:-}"
if [ -n "$pane_name" ] && [ -n "$self_name" ] && [ "$pane_name" != "$self_name" ]; then
  echo "duet: identity mismatch: pane $TMUX_PANE is '$pane_name' but DUET_SELF is '$self_name'." >&2
  exit 7
fi

known_sender="$pane_name"
if [ -n "$from" ]; then
  duet_roster_has_name "$from" || { echo "duet: --from identity '$from' is not in the roster." >&2; exit 7; }
  if [ -n "$known_sender" ] && [ "$known_sender" != "$from" ] \
      && [ -z "${DUET_ALLOW_FROM_OVERRIDE:-}" ]; then
    echo "duet: --from '$from' does not match caller pane identity '$known_sender'." >&2
    exit 7
  fi
  if [ -n "$self_name" ] && [ "$self_name" != "$from" ] \
      && [ -z "${DUET_ALLOW_FROM_OVERRIDE:-}" ]; then
    echo "duet: --from '$from' does not match DUET_SELF '$self_name'." >&2
    exit 7
  fi
  if [ -z "$known_sender" ] && [ -z "${DUET_ALLOW_FROM_OVERRIDE:-}" ]; then
    echo "duet: caller pane is not in this roster; set DUET_ALLOW_FROM_OVERRIDE=1 for explicit admin/test sends." >&2
    exit 7
  fi
  sender="$from"
else
  [ -n "$known_sender" ] || {
    echo "duet: cannot resolve sender from TMUX_PANE; use an explicit authorized --from override." >&2
    exit 7
  }
  sender="$known_sender"
fi

body_with_sentinel="$(cat; printf '.')"
body="${body_with_sentinel%.}"
mode=NORMAL
[ -z "$interrupt" ] || mode=INTERRUPT
origin=WORKER
[ "$sender" != "$DUET_CURRENT_LEADER" ] || origin=LEADER

enqueue_one(){
  local queue="$1" recipient="$2"
  duet_enqueue_message "$queue" "$sender" "$recipient" "$DUET_CURRENT_TERM" \
    "$mode" "$origin" "$DUET_CURRENT_LEADER" "$body"
  printf 'duet: queued %s for %s%s\n' \
    "$DUET_ENQUEUED_ID" "$recipient" "${interrupt:+ (interrupt)}"
}

if [ "$sender" = "$DUET_CURRENT_LEADER" ]; then
  if [ "$recipient_token" = all ]; then
    while IFS=$'\t' read -r name _harness _pane _pid _rank _spawned; do
      [ "$name" = name ] && continue
      [ "$name" = "$sender" ] && continue
      enqueue_one "$name" "$name"
    done < "$DUET_DIR/roster.tsv"
    exit 0
  fi

  if [ "$recipient_token" = leader ]; then
    echo "duet: leader '$sender' cannot send to itself through the leader alias." >&2
    exit 8
  fi
  recipient="$(duet_resolve_roster_name "$recipient_token")" || {
    echo "duet: unknown or ambiguous recipient '$recipient_token'." >&2
    exit 2
  }
  [ "$recipient" != "$sender" ] || { echo "duet: sender and recipient are both '$sender'." >&2; exit 8; }
  enqueue_one "$recipient" "$recipient"
  exit 0
fi

# Worker traffic is canonicalized to the symbolic leader queue, even when the
# caller used the current leader's concrete name. Delivery-time resolution then
# preserves an in-flight reply across a later promotion.
if [ "$recipient_token" != leader ]; then
  recipient="$(duet_resolve_roster_name "$recipient_token")" || {
    echo "duet: unknown or ambiguous recipient '$recipient_token'." >&2
    exit 2
  }
  if [ "$recipient" != "$DUET_CURRENT_LEADER" ]; then
    echo "duet: hub violation: worker '$sender' may send only to leader '$DUET_CURRENT_LEADER'." >&2
    exit 8
  fi
fi
enqueue_one leader leader
