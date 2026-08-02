#!/usr/bin/env bash
# Clear one recipient's delivery block in a pinned duet session.
#
# A block fences a recipient whose composer could not be driven to a confirmed
# submission. That is a statement about a bounded run of observations, not about
# the peer itself, so a live and ready peer must be able to rejoin the session.
# Nothing here repastes or reorders: the daemon resumes from that recipient's
# existing queue head, enter-only if the head had already landed.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: DUET_CONFIG=/absolute/session/duet.env duet-resume.sh <exact-roster-name>" >&2
}

recipient="${1:-}"
[ "$#" -le 1 ] || { usage; exit 2; }
[ -n "$recipient" ] || { usage; exit 2; }

duet_resolve_config "" 1 || exit 1
cfg="$DUET_RESOLVED_CONFIG"
unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
unset DUET_SESSION DUET_SESSION_ID DUET_INITIATOR DUET_INITIATOR_PANE
# shellcheck disable=SC1090
. "$cfg"
DUET_CONFIG="$cfg"
duet_validate_loaded_session "" "$cfg" || exit 7
[ ! -f "$DUET_DIR/.ended" ] || {
  echo "duet: session has ended; nothing to resume." >&2
  exit 1
}
[ ! -f "$DUET_DIR/.unhealthy" ] || {
  echo "duet: session is unhealthy; re-initialize instead of resuming." >&2
  exit 1
}
duet_validate_roster "$DUET_DIR/roster.tsv" || {
  echo "duet: session roster is invalid; refusing to resume." >&2
  exit 1
}

duet_roster_has_name "$recipient" || {
  echo "duet: recipient '$recipient' is not an exact roster name." >&2
  exit 2
}
[ -f "$DUET_DIR/blocked/$recipient" ] || {
  echo "duet: recipient '$recipient' is not blocked." >&2
  exit 0
}
[ ! -f "$DUET_DIR/dead/$recipient" ] || {
  echo "duet: recipient '$recipient' is dead; a dead pane cannot be resumed." >&2
  exit 8
}
# A block is only worth clearing against a pane that still holds its recorded
# roster identity. Resuming onto a reused pane id would drive a stranger's TUI.
duet_roster_member_alive "$recipient" || {
  echo "duet: recipient '$recipient' is not live; re-initialize the session." >&2
  exit 8
}

rm -f "$DUET_DIR/blocked/$recipient" || {
  echo "duet: could not clear the block for '$recipient'." >&2
  exit 1
}
printf '[%s] RESUMED recipient %s by operator\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$recipient" >> "$DUET_DIR/deliverd.log"
printf 'duet: resumed %s; delivery continues from its queue head.\n' "$recipient"
