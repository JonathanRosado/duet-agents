#!/usr/bin/env bash
# End exactly one pinned session immediately.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: DUET_CONFIG=/absolute/session/duet.env duet-end.sh" >&2
}

[ "$#" -eq 0 ] || { usage; exit 2; }

caller_self="${DUET_SELF:-}"
duet_capture_caller_identity || {
  echo "duet: caller is not an identifiable tmux pane." >&2
  exit 7
}

duet_resolve_config "" 1 || exit 1
cfg="$DUET_RESOLVED_CONFIG"
unset DUET_DIR DUET_STATE_ROOT WORKDIR PLUGIN_DIR
unset DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
unset DUET_SESSION DUET_SESSION_ID DUET_INITIATOR DUET_INITIATOR_PANE
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || {
  echo "duet: could not load pinned session: $cfg" >&2
  exit 1
}
DUET_CONFIG="$cfg"
duet_validate_loaded_session "" "$cfg" || exit 1
duet_validate_roster "$DUET_DIR/roster.tsv" || {
  echo "duet: session roster is invalid; refusing pane teardown." >&2
  exit 9
}
duet_caller_roster_name || {
  echo "duet: caller pane is not exactly one member of session '$DUET_SESSION_ID'." >&2
  exit 7
}
if [ -n "$caller_self" ] && [ "$caller_self" != "$DUET_CALLER_NAME" ]; then
  echo "duet: identity mismatch: caller pane is '$DUET_CALLER_NAME' but DUET_SELF is '$caller_self'." >&2
  exit 7
fi

if ! : > "$DUET_DIR/.ended"; then
  echo "duet: could not publish the ended marker; session left intact." >&2
  exit 9
fi

failed=""
if ! duet_stop_daemon "$DUET_DIR" 30; then
  echo "duet: warning: delivery daemon did not stop cleanly." >&2
  failed=1
fi
if duet_tmux_server_matches; then
  if ! duet_kill_spawned_panes "$DUET_DIR/roster.tsv" "$DUET_CALLER_PANE"; then
    echo "duet: invalid or ambiguous roster blocked recorded pane cleanup." >&2
    failed=1
  fi
else
  echo "duet: tmux server identity changed; skipped recorded pane cleanup." >&2
  failed=1
fi
if ! duet_strip_session_anchors "$WORKDIR"; then
  echo "duet: could not strip session anchors." >&2
  failed=1
fi

echo "duet: ended. Transcript kept at $DUET_DIR/transcript.md"
[ -z "$failed" ]
