#!/usr/bin/env bash
# duet-relay.sh — injects Codex->Claude messages when Codex is sandboxed below tmux
# access. Codex drops handoff files in to-claude/; this relay (unsandboxed) pastes
# each INLINE into Claude's pane and VERIFIES submission, retrying with a cap and
# moving unrecoverable messages to failed/ instead of silently marking them sent.
# (Claude->Codex does NOT use the relay; Claude injects directly.)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg"
box="$DUET_DIR/to-claude"; sent="$box/delivered"; failed="$box/failed"; log="$DUET_DIR/relay.log"
mkdir -p "$sent" "$failed"
max=5
echo "[$(date +%H:%M:%S)] relay up -> claude pane $CLAUDE_PANE" >> "$log"
while :; do
  for f in "$box"/*.msg; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    flag="$(head -1 "$f")"
    body="$(tail -n +2 "$f")"
    intr=""; [ "$flag" = INTERRUPT ] && intr=1
    if duet_send_verified "$CLAUDE_PANE" "$body" "$intr"; then
      echo "[$(date +%H:%M:%S)] delivered $base ($flag)" >> "$log"
      rm -f "$box/.$base.tries"; mv -f "$f" "$sent/"
    else
      tf="$box/.$base.tries"; n=$(( $(cat "$tf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$tf"
      if [ "$n" -ge "$max" ]; then
        echo "[$(date +%H:%M:%S)] GAVE UP on $base after $n attempts ($flag) -> failed/" >> "$log"
        rm -f "$tf"; mv -f "$f" "$failed/"
      else
        echo "[$(date +%H:%M:%S)] UNVERIFIED $base attempt $n/$max ($flag) - will retry" >> "$log"
      fi
    fi
  done
  [ -f "$DUET_DIR/.ended" ] && { echo "[$(date +%H:%M:%S)] relay stop" >> "$log"; exit 0; }
  sleep 0.2
done
