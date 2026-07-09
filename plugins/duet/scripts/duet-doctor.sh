#!/usr/bin/env bash
# duet-doctor.sh — inspect duet panes, flag orphaned agents, optionally reap them.
# Read-only by default; pass --reap to kill orphaned Codex agent panes that do not
# belong to the current session (issue #3).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

reap=""; [ "${1:-}" = "--reap" ] && reap=1
cfg="${DUET_CONFIG:-$HOME/.duet/current/duet.env}"
cur_claude=""; cur_codex=""; cur_dir=""; relay=""
if [ -f "$cfg" ]; then
  # shellcheck disable=SC1090
  ( . "$cfg" ) >/dev/null 2>&1 && { . "$cfg"; cur_claude="${CLAUDE_PANE:-}"; cur_codex="${CODEX_PANE:-}"; cur_dir="${DUET_DIR:-}"; relay="${DUET_RELAY:-}"; }
fi
self_pane="${TMUX_PANE:-}"

echo "=== duet doctor ==="
if [ -n "$cur_dir" ]; then
  echo "current session : $cur_dir"
  echo "  claude pane   : $cur_claude"
  echo "  codex pane    : $cur_codex"
  echo "  relay         : $([ -n "$relay" ] && echo on || echo 'off (direct send)')"
else
  echo "current session : (none - no ~/.duet/current/duet.env)"
fi
echo ""
echo "--- all panes (list-panes -a) ---"

orphans=""
while IFS='|' read -r id ppid cmd start; do
  [ -n "$id" ] || continue
  tags=""
  [ "$id" = "$cur_claude" ] && tags="$tags current-claude"
  [ "$id" = "$cur_codex" ]  && tags="$tags current-codex"
  [ "$id" = "$self_pane" ]  && tags="$tags this-pane"
  looks_agent=""
  case "$cmd" in codex|node) looks_agent=1;; esac
  case "$start" in *codex*|*.duet*|*--add-dir*) looks_agent=1;; esac
  if [ -n "$looks_agent" ] && [ "$id" != "$cur_claude" ] && [ "$id" != "$cur_codex" ] && [ "$id" != "$self_pane" ]; then
    tags="$tags ORPHAN?"
    orphans="$orphans $id"
  fi
  printf '  %-5s pid=%-8s cmd=%-12s %.70s%s\n' "$id" "$ppid" "$cmd" "$start" "${tags:+  [$tags ]}"
done < <(tmux list-panes -a -F '#{pane_id}|#{pane_pid}|#{pane_current_command}|#{pane_start_command}' 2>/dev/null)
echo ""

orphans="$(echo "$orphans" | tr -s ' ' | sed 's/^ //;s/ $//')"
if [ -z "$orphans" ]; then
  echo "No orphaned agent panes detected."
  exit 0
fi
echo "Found possible orphaned agent pane(s): $orphans"
if [ -z "$reap" ]; then
  echo "Re-run with --reap to kill them. (Never kills the current session's panes or this pane.)"
  exit 0
fi
for o in $orphans; do
  echo "reaping $o ..."
  tmux send-keys -t "$o" C-c 2>/dev/null || true
  sleep 0.3
  tmux kill-pane -t "$o" 2>/dev/null || true
done
echo "done."
