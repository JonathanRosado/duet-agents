#!/usr/bin/env bash
# duet-status.sh — inspect the running duet (escape hatch / debugging).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || { echo "duet: no active session"; exit 0; }
claude_state=DEAD; _duet_alive "${CLAUDE_PANE:-}" && claude_state=alive
codex_state=DEAD;  _duet_alive "${CODEX_PANE:-}"  && codex_state=alive
echo "session : $DUET_DIR"
echo "panes   : claude=$CLAUDE_PANE [$claude_state]  codex=$CODEX_PANE [$codex_state]"
echo "relay   : $([ -n "${DUET_RELAY:-}" ] && echo on || echo 'off (direct send)')"
echo "pending codex->claude : $(find "$DUET_DIR/to-claude" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
[ "$codex_state" = DEAD ] && echo "WARNING: codex pane is not alive - re-init or run duet-doctor.sh"
echo "--- transcript (last 24 lines) ---"; tail -24 "$DUET_DIR/transcript.md" 2>/dev/null || echo "(empty)"
echo "--- relay (last 6) ---"; tail -6 "$DUET_DIR/relay.log" 2>/dev/null || echo "(none)"
echo "--- codex pane (last 18 lines) ---"; tmux capture-pane -t "$CODEX_PANE" -p 2>/dev/null | tail -18 || echo "(pane gone)"
