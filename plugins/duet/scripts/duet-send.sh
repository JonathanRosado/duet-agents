#!/usr/bin/env bash
# duet-send.sh <codex|claude> [--interrupt]  — send a message (read from stdin) to
# the peer, delivered INLINE: pasted straight into the recipient's prompt (bracketed
# paste), never read from a file — so there is no receive-side read-hop. --interrupt
# barges in (Esc first) to redirect the peer mid-task.
#
# Both agents run with enough access to drive tmux, so delivery is symmetric and
# direct. (Only if Codex is deliberately sandboxed below tmux-socket access do you set
# DUET_RELAY=1 and run duet-relay.sh; then codex->claude is handed to the relay.)
set -euo pipefail
recipient="${1:-}"; [ $# -ge 1 ] && shift
interrupt=""; [ "${1:-}" = "--interrupt" ] && interrupt=1
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
[ -f "$cfg" ] || { echo "duet: no session ($cfg). run duet-init first." >&2; exit 1; }
# shellcheck disable=SC1090
. "$cfg"
case "$recipient" in
  codex)  sender=claude; pane="$CODEX_PANE"  ;;
  claude) sender=codex;  pane="$CLAUDE_PANE" ;;
  *) echo "usage: duet-send.sh <codex|claude> [--interrupt]   (message body on stdin)" >&2; exit 2 ;;
esac

body="$(cat)"
ts="$(date '+%H:%M:%S')"
# durable transcript (both directions) — for recovery after /clear or compaction
printf '\n----- %s  %s -> %s%s -----\n%s\n' "$ts" "$sender" "$recipient" "${interrupt:+  (INTERRUPT)}" "$body" \
  >> "$DUET_DIR/transcript.md"
# framed payload the peer receives (header lets it tell duet msgs from a human typing)
payload="$(printf '[DUET from %s]\n%s' "$sender" "$body")"

# Optional relay path: ONLY for a deliberately-sandboxed Codex that cannot drive tmux.
if [ "$recipient" = claude ] && [ -n "${DUET_RELAY:-}" ]; then
  box="$DUET_DIR/to-claude"; mkdir -p "$box"
  n=$(( $(find "$box" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ') + 1 ))
  seq=$(printf '%04d' "$n"); tmp="$box/.$seq.tmp"; final="$box/$seq.msg"
  { [ -n "$interrupt" ] && echo INTERRUPT || echo NORMAL; printf '%s' "$payload"; } > "$tmp"; mv -f "$tmp" "$final"
  echo "duet: queued for claude via relay${interrupt:+ (interrupt)}"; exit 0
fi

# Default: inject directly into the recipient's pane (bracketed paste).
buf="duet-$$"
[ -n "$interrupt" ] && { tmux send-keys -t "$pane" Escape; tmux send-keys -t "$pane" Escape; }
printf '%s' "$payload" | tmux load-buffer -b "$buf" -
tmux paste-buffer -d -b "$buf" -p -t "$pane"
tmux send-keys -t "$pane" Enter
echo "duet: delivered to $recipient${interrupt:+ (interrupt)}"