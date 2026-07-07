#!/usr/bin/env bash
# duet-relay.sh — the ONLY component that injects Codex->Claude messages.
# Codex is sandboxed and cannot drive tmux, so it drops handoff files in to-claude/.
# This relay (unsandboxed) reads each, optionally interrupts, and pastes it INLINE
# into Claude's pane (bracketed paste) — so Claude receives a normal prompt, no
# read-hop. (Claude->Codex does NOT use the relay; Claude injects directly.)
set -uo pipefail
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
# shellcheck disable=SC1090
. "$cfg"
box="$DUET_DIR/to-claude"; sent="$box/delivered"; log="$DUET_DIR/relay.log"
mkdir -p "$sent"
echo "[$(date +%H:%M:%S)] relay up -> claude pane $CLAUDE_PANE" >> "$log"
while :; do
  for f in "$box"/*.msg; do
    [ -e "$f" ] || continue
    flag="$(head -1 "$f")"
    body="$(tail -n +2 "$f")"
    [ "$flag" = INTERRUPT ] && { tmux send-keys -t "$CLAUDE_PANE" Escape; tmux send-keys -t "$CLAUDE_PANE" Escape; }
    printf '%s' "$body" | tmux load-buffer -b duetrelay -
    tmux paste-buffer -b duetrelay -p -t "$CLAUDE_PANE"
    tmux send-keys -t "$CLAUDE_PANE" Enter
    echo "[$(date +%H:%M:%S)] injected $(basename "$f") ($flag)" >> "$log"
    mv -f "$f" "$sent/"
  done
  [ -f "$DUET_DIR/.ended" ] && { echo "[$(date +%H:%M:%S)] relay stop" >> "$log"; exit 0; }
  sleep 0.2
done