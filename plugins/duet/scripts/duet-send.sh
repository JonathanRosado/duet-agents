#!/usr/bin/env bash
# duet-send.sh <codex|claude> [--interrupt]  — send a message (read from stdin) to
# the peer, delivered INLINE (bracketed paste) and VERIFIED submitted. Prints
# "submitted" only after confirming the peer's composer actually cleared; prints
# "SENT BUT UNVERIFIED" (exit 3) otherwise, instead of a false "delivered". This is
# the fix for the Enter-races-bracketed-paste silent drop (issues #1 and #2).
# --interrupt barges in (Esc first) to redirect a BUSY peer.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"
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
# durable transcript (both directions) - for recovery after /clear or compaction
printf '\n----- %s  %s -> %s%s -----\n%s\n' "$ts" "$sender" "$recipient" "${interrupt:+  (INTERRUPT)}" "$body" \
  >> "$DUET_DIR/transcript.md"
# framed payload the peer receives (header lets it tell duet msgs from a human typing)
payload="$(printf '[DUET from %s]\n%s' "$sender" "$body")"

# Optional relay path: ONLY for a deliberately-sandboxed Codex that cannot drive
# tmux. The relay process verifies submission and retries; refuse to queue silently
# if no relay is actually running (that would recreate the old false-"delivered").
if [ "$recipient" = claude ] && [ -n "${DUET_RELAY:-}" ]; then
  if [ ! -f "$DUET_DIR/relay.log" ]; then
    echo "duet: DUET_RELAY set but no relay.log - relay may not be running; sending directly." >&2
  else
    box="$DUET_DIR/to-claude"; mkdir -p "$box"
    n=$(( $(find "$box" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ') + 1 ))
    seq=$(printf '%04d' "$n"); tmp="$box/.$seq.tmp"; final="$box/$seq.msg"
    { [ -n "$interrupt" ] && echo INTERRUPT || echo NORMAL; printf '%s' "$payload"; } > "$tmp"; mv -f "$tmp" "$final"
    echo "duet: queued for claude via relay${interrupt:+ (interrupt)} ($seq.msg)"; exit 0
  fi
fi

# Default: inject directly into the recipient's pane and VERIFY submission.
_duet_alive "$pane" || { echo "duet: $recipient pane ($pane) is not alive - re-init the duet or run duet-doctor.sh." >&2; exit 4; }
if duet_send_verified "$pane" "$payload" "$interrupt"; then
  echo "duet: submitted to $recipient${interrupt:+ (interrupt)}"
  exit 0
else
  echo "duet: SENT BUT UNVERIFIED to $recipient - could not confirm it was submitted. Check its pane (duet-status.sh); do NOT assume delivery." >&2
  exit 3
fi
