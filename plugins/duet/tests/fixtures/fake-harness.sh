#!/usr/bin/env bash
# Tiny interactive TUI used only by isolated lifecycle smokes.
set -u

harness="$(basename "$0")"
if [ "$harness" = kimi ] && [ "${1:-}" = doctor ]; then
  exit 0
fi

case "$harness" in
  claude) banner='Claude Code' ;;
  codex) banner='OpenAI Codex' ;;
  kimi) banner='Welcome to Kimi Code!' ;;
  *) banner='Duet fake harness' ;;
esac

name="${DUET_SELF:-$harness}"
accept_root="${DUET_FAKE_ACCEPT_ROOT:-}"
if [ -n "$accept_root" ]; then
  mkdir -p "$accept_root"
  accept_log="$accept_root/$name.log"
else
  accept_log=""
fi

printf '%s\n' "$banner"
printf 'fake harness ready: %s\n' "$name"
session_dir="${DUET_DIR:-}"
if [ -z "$session_dir" ] && [ -n "${DUET_CONFIG:-}" ]; then
  session_dir="${DUET_CONFIG%/duet.env}"
fi
if [ -n "$session_dir" ]; then
  mkdir -p "$session_dir/ready"
  printf 'ok\n' > "$session_dir/ready/$name"
fi
# Tell tmux that this fake TUI understands bracketed paste, just like the real
# harnesses. That lets the byte loop distinguish pasted newlines from Enter.
printf '\033[?2004h> '

saved_stty="$(stty -g 2>/dev/null || true)"
[ -z "$saved_stty" ] || stty -echo -icanon min 1 time 0
trap '[ -z "$saved_stty" ] || stty "$saved_stty" 2>/dev/null || true' EXIT

buffer=""
control=""
in_paste=""
while IFS= read -r -n 1 character; do
  if [ -n "$control" ]; then
    if [ "$character" = $'\033' ]; then
      control=$'\033'
      continue
    fi
    control="${control}${character}"
    case "$control" in
      $'\033[200~') in_paste=1; control=""; continue ;;
      $'\033[201~') in_paste=""; control=""; continue ;;
    esac
    [ "${#control}" -lt 8 ] || control=""
    continue
  fi
  case "$character" in
    $'\r')
      [ -z "$accept_log" ] || printf '%s\n' "$buffer" >> "$accept_log"
      buffer=""
      printf '\r\naccepted: %s\nready: 1\nready: 2\nready: 3\nready: 4\n> ' "$name"
      ;;
    '')
      if [ -n "$in_paste" ]; then
        buffer="${buffer}"$'\n'
        printf '\r\n'
      else
        [ -z "$accept_log" ] || printf '%s\n' "$buffer" >> "$accept_log"
        buffer=""
        printf '\r\naccepted: %s\nready: 1\nready: 2\nready: 3\nready: 4\n> ' "$name"
      fi
      ;;
    $'\033')
      control=$'\033'
      ;;
    *)
      buffer="${buffer}${character}"
      printf '%s' "$character"
      ;;
  esac
done
