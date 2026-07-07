#!/usr/bin/env bash
# duet-end.sh — tear down: stop the relay, strip the durable protocol blocks, close
# Codex's pane. The transcript under ~/.duet/<stamp>/ is kept.
set -uo pipefail
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg" 2>/dev/null || { echo "duet: no active session"; exit 0; }

touch "$DUET_DIR/.ended"   # signals the relay to exit
strip(){  # remove the DUET block; delete the file if nothing else remains
  [ -f "$1" ] || return 0
  perl -0777 -pi -e 's/\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\n?//s' "$1" 2>/dev/null || return 0
  grep -q '[^[:space:]]' "$1" 2>/dev/null || rm -f "$1"
}
strip "${WORKDIR:-}/AGENTS.md"
strip "${WORKDIR:-}/CLAUDE.md"

if [ -n "${CODEX_PANE:-}" ]; then
  tmux send-keys -t "$CODEX_PANE" C-c 2>/dev/null || true
  tmux kill-pane -t "$CODEX_PANE" 2>/dev/null || true
fi
echo "duet: ended. Transcript kept at $DUET_DIR/transcript.md"