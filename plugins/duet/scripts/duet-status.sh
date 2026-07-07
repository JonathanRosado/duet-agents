#!/usr/bin/env bash
# duet-status.sh — inspect the running duet (escape hatch / debugging).
set -uo pipefail
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || { echo "duet: no active session"; exit 0; }
echo "session : $DUET_DIR"
echo "panes   : claude=$CLAUDE_PANE  codex=$CODEX_PANE"
echo "pending codex->claude : $(find "$DUET_DIR/to-claude" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
echo "--- transcript (last 24 lines) ---"; tail -24 "$DUET_DIR/transcript.md" 2>/dev/null || echo "(empty)"
echo "--- relay (last 6) ---"; tail -6 "$DUET_DIR/relay.log" 2>/dev/null || echo "(none)"
echo "--- codex pane (last 18 lines) ---"; tmux capture-pane -t "$CODEX_PANE" -p 2>/dev/null | tail -18 || echo "(pane gone)"