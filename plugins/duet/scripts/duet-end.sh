#!/usr/bin/env bash
# Stop one tmux/bash duet session. M2 adds the bounded queue-drain barrier;
# this M1 lifecycle skeleton already enforces spawned-only, never-self reaping.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

state_root="${DUET_STATE_ROOT:-$HOME/.duet}"
cfg="${DUET_CONFIG:-$state_root/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || { echo "duet: no active session"; exit 0; }

current_pane="${TMUX_PANE:-}"
: > "$DUET_DIR/.ended"
duet_strip_session_anchors "${WORKDIR:-}"
duet_kill_spawned_panes "$DUET_DIR/roster.tsv" "$current_pane" "${CODEX_PANE:-}"

current_link="$DUET_STATE_ROOT/current"
current_target="$(readlink "$current_link" 2>/dev/null || true)"
[ "$current_target" = "$DUET_DIR" ] && rm -f "$current_link"

echo "duet: ended. Transcript kept at $DUET_DIR/transcript.md"
