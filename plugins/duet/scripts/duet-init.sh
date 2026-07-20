#!/usr/bin/env bash
# Start an n-agent duet ensemble from the initiating Claude tmux pane.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: duet-init.sh [codex|kimi|claude ...]  (1-4 workers; default: codex)" >&2
}

load_adapter(){
  local harness="${1:?harness required}" adapter="$PLUGIN_DIR/harnesses/${1}.sh"
  [ -f "$adapter" ] || { echo "duet: unsupported harness '$harness'" >&2; return 1; }
  unset DUET_HARNESS_BOOT_RE DUET_HARNESS_BRIEF_FILE
  unset -f duet_harness_check duet_harness_pretrust duet_harness_launch_cmd 2>/dev/null || true
  # shellcheck disable=SC1090
  . "$adapter"
  [ -n "${DUET_HARNESS_BOOT_RE:-}" ] \
    && [ -n "${DUET_HARNESS_BRIEF_FILE:-}" ] \
    && type duet_harness_check >/dev/null 2>&1 \
    && type duet_harness_pretrust >/dev/null 2>&1 \
    && type duet_harness_launch_cmd >/dev/null 2>&1 || {
      echo "duet: harness adapter '$adapter' does not implement the contract" >&2
      return 1
    }
}

[ -n "${TMUX:-}" ] || {
  echo "duet: not inside tmux. Start Claude with: tmux new-session claude" >&2
  exit 3
}
command -v tmux >/dev/null 2>&1 || { echo "duet: tmux not found on PATH" >&2; exit 3; }

[ "$#" -gt 0 ] || set -- codex
[ "$#" -ge 1 ] && [ "$#" -le 4 ] || { usage; exit 2; }

WORKDIR="$PWD"
INITIATOR_NAME=claude
INITIATOR_PANE="${TMUX_PANE:?duet: initiating pane has no TMUX_PANE}"
DUET_TMUX_SOCKET="$(tmux display-message -p -t "$INITIATOR_PANE" '#{socket_path}')"
WINDOW_ID="$(_duet_tmux display-message -p -t "$INITIATOR_PANE" '#{window_id}')"
DUET_STATE_ROOT="${DUET_STATE_ROOT:-$HOME/.duet}"

workers=("$@")
worker_names=()
worker_panes=()
worker_pids=()
boot_states=()
kick_states=()
ready_states=()
codex_count=0
kimi_count=0
claude_count=0

# Validate and name the entire requested roster before disturbing an old session.
for harness in "${workers[@]}"; do
  case "$harness" in
    codex) codex_count=$((codex_count + 1)); worker_names+=("codex-$codex_count") ;;
    kimi) kimi_count=$((kimi_count + 1)); worker_names+=("kimi-$kimi_count") ;;
    claude) claude_count=$((claude_count + 1)); worker_names+=("claude-$claude_count") ;;
    *) usage; echo "duet: unsupported harness '$harness'" >&2; exit 2 ;;
  esac
  load_adapter "$harness"
  duet_harness_check
done

mkdir -p "$DUET_STATE_ROOT"

# Reap only spawned panes from the previous session under this state root. The
# current initiating pane is an unconditional exemption, including malformed
# or legacy rosters.
PREV_ENV="$DUET_STATE_ROOT/current/duet.env"
if [ -f "$PREV_ENV" ]; then
  caller_pane="$INITIATOR_PANE"
  (
    unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET CODEX_PANE
    # shellcheck disable=SC1090
    . "$PREV_ENV"
    duet_reap_session "${DUET_DIR:-}" "${WORKDIR:-}" "${DUET_TMUX_SOCKET:-}" \
      "$caller_pane" "${CODEX_PANE:-}"
  ) || true
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DUET_DIR="$(mktemp -d "$DUET_STATE_ROOT/$STAMP-XXXXXX")"
mkdir -p "$DUET_DIR/ready"
: > "$DUET_DIR/transcript.md"
printf '# Duet assignments\n\nTerm 0 leader: claude\n' > "$DUET_DIR/assignments.md"
printf 'ok\n' > "$DUET_DIR/ready/$INITIATOR_NAME"

for name in "${worker_names[@]}"; do
  mkdir -p "$DUET_DIR/inbox/$name/delivered" \
           "$DUET_DIR/inbox/$name/failed" \
           "$DUET_DIR/inbox/$name/quarantine"
done
mkdir -p "$DUET_DIR/inbox/$INITIATOR_NAME/delivered" \
         "$DUET_DIR/inbox/$INITIATOR_NAME/failed" \
         "$DUET_DIR/inbox/$INITIATOR_NAME/quarantine"

# Leadership state is human-readable but never sourced as shell code.
leader_tmp="$(mktemp "$DUET_DIR/.leader.XXXXXX")"
printf 'term\t0\nleader\t%s\n' "$INITIATOR_NAME" > "$leader_tmp"
mv -f "$leader_tmp" "$DUET_DIR/leader"

render_brief(){
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@DUET_DIR@/$DUET_DIR}"
    line="${line//@PLUGIN@/$PLUGIN_DIR}"
    printf '%s\n' "$line"
  done < "$PLUGIN_DIR/briefs/ENSEMBLE_BRIEF.md"
}

append_anchor(){
  local file="${1:?anchor file required}"
  touch "$file"
  duet_strip_anchor_file "$file"
  {
    printf '\n<!-- DUET:BEGIN (added by duet-init; removed by duet-end) -->\n'
    render_brief
    printf '<!-- DUET:END -->\n'
  } >> "$file"
}

init_complete=""
cleanup_on_exit(){
  local status=$? pane current_target
  [ -n "$init_complete" ] && return "$status"
  : > "$DUET_DIR/.ended" 2>/dev/null || true
  for pane in "${worker_panes[@]}"; do
    [ -n "$pane" ] || continue
    [ "$pane" = "$INITIATOR_PANE" ] && continue
    _duet_alive "$pane" && _duet_tmux kill-pane -t "$pane" 2>/dev/null || true
  done
  duet_strip_session_anchors "$WORKDIR"
  current_target="$(readlink "$DUET_STATE_ROOT/current" 2>/dev/null || true)"
  [ "$current_target" = "$DUET_DIR" ] && rm -f "$DUET_STATE_ROOT/current"
  return "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

append_anchor "$WORKDIR/AGENTS.md"
append_anchor "$WORKDIR/CLAUDE.md"

# Pretrust and launch workers. No boot message is sent until roster/config are
# atomically published, even if a TUI becomes ready early.
for i in "${!workers[@]}"; do
  harness="${workers[$i]}"
  name="${worker_names[$i]}"
  load_adapter "$harness"
  duet_harness_pretrust "$WORKDIR"
  launch_cmd="$(duet_harness_launch_cmd "$WORKDIR" "$DUET_DIR" "$name")"

  if [ "$i" -eq 0 ]; then
    pane="$(_duet_tmux split-window -h -t "$INITIATOR_PANE" -P -F '#{pane_id}' "$launch_cmd")"
  else
    pane="$(_duet_tmux split-window -t "$WINDOW_ID" -P -F '#{pane_id}' "$launch_cmd")"
  fi
  worker_panes+=("$pane")
  pane_pid="$(_duet_tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
  worker_pids+=("$pane_pid")
done

_duet_tmux select-pane -t "$INITIATOR_PANE"
[ "${#workers[@]}" -lt 2 ] || _duet_tmux select-layout -t "$WINDOW_ID" tiled >/dev/null

initiator_pid="$(_duet_tmux display-message -p -t "$INITIATOR_PANE" '#{pane_pid}' 2>/dev/null || true)"

roster_tmp="$(mktemp "$DUET_DIR/.roster.XXXXXX")"
printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n' > "$roster_tmp"
printf '%s\t%s\t%s\t%s\t0\t0\n' \
  "$INITIATOR_NAME" claude "$INITIATOR_PANE" "$initiator_pid" >> "$roster_tmp"
for i in "${!workers[@]}"; do
  printf '%s\t%s\t%s\t%s\t%s\t1\n' \
    "${worker_names[$i]}" "${workers[$i]}" "${worker_panes[$i]}" \
    "${worker_pids[$i]}" "$((i + 1))" >> "$roster_tmp"
done
mv -f "$roster_tmp" "$DUET_DIR/roster.tsv"

env_tmp="$(mktemp "$DUET_DIR/.env.XXXXXX")"
{
  printf 'DUET_DIR=%q\n' "$DUET_DIR"
  printf 'DUET_STATE_ROOT=%q\n' "$DUET_STATE_ROOT"
  printf 'WORKDIR=%q\n' "$WORKDIR"
  printf 'PLUGIN_DIR=%q\n' "$PLUGIN_DIR"
  printf 'DUET_TMUX_SOCKET=%q\n' "$DUET_TMUX_SOCKET"
  printf 'DUET_INITIATOR=%q\n' "$INITIATOR_NAME"
  printf 'DUET_INITIATOR_PANE=%q\n' "$INITIATOR_PANE"
} > "$env_tmp"
mv -f "$env_tmp" "$DUET_DIR/duet.env"
ln -sfn "$DUET_DIR" "$DUET_STATE_ROOT/current"

# Wait for every harness banner, then issue direct verified boot kicks. M2 moves
# all ordinary traffic to the daemon; this bootstrap path exists only so an
# agent can prove it loaded the durable brief and can use tools.
boot_timeout="${DUET_BOOT_TIMEOUT:-35}"
for i in "${!workers[@]}"; do
  harness="${workers[$i]}"
  name="${worker_names[$i]}"
  pane="${worker_panes[$i]}"
  load_adapter "$harness"
  boot_state=timeout
  for _ in $(seq 1 "$boot_timeout"); do
    if ! _duet_alive "$pane"; then boot_state=dead; break; fi
    if _duet_tmux capture-pane -p -t "$pane" 2>/dev/null | grep -qE "$DUET_HARNESS_BOOT_RE"; then
      boot_state=ready
      break
    fi
    sleep 1
  done
  boot_states[$i]="$boot_state"

  printf -v ready_path_q '%q' "$DUET_DIR/ready/$name"
  printf -v kick '[DUET boot]\nYou are %s (harness: %s). Read %s and %s/leader. Confirm readiness now by running exactly this shell command: printf '\''ok\\n'\'' > %s . Then wait for a task from the leader.' \
    "$name" "$harness" "$DUET_HARNESS_BRIEF_FILE" "$DUET_DIR" "$ready_path_q"
  kick_state=failed
  if duet_send_verified "$pane" "$kick" ""; then
    kick_state=submitted
  else
    send_rc=$?
    if [ "$send_rc" -eq "$DUET_SEND_NOT_LANDED" ]; then
      sleep 0.5
      if duet_send_verified "$pane" "$kick" ""; then
        kick_state=submitted-after-retry
      else
        send_rc=$?
        [ "$send_rc" -eq "$DUET_SEND_LANDED_UNVERIFIED" ] && kick_state=landed-unverified || kick_state=failed
      fi
    elif [ "$send_rc" -eq "$DUET_SEND_LANDED_UNVERIFIED" ]; then
      kick_state=landed-unverified
    elif [ "$send_rc" -eq "$DUET_SEND_DEAD" ]; then
      kick_state=dead
    fi
  fi
  kick_states[$i]="$kick_state"
done

ready_timeout="${DUET_READY_TIMEOUT:-75}"
for _ in $(seq 1 "$ready_timeout"); do
  all_ready=1
  for name in "${worker_names[@]}"; do
    [ -f "$DUET_DIR/ready/$name" ] || { all_ready=0; break; }
  done
  [ "$all_ready" -eq 1 ] && break
  sleep 1
done

failed=0
printf 'duet: session %s\n' "$DUET_DIR"
printf '  %-12s %-8s %-6s %-10s %-22s %s\n' NAME HARNESS PANE BOOT KICK READY
for i in "${!workers[@]}"; do
  name="${worker_names[$i]}"
  if [ -f "$DUET_DIR/ready/$name" ]; then ready_state=yes; else ready_state=no; failed=1; fi
  ready_states[$i]="$ready_state"
  printf '  %-12s %-8s %-6s %-10s %-22s %s\n' \
    "$name" "${workers[$i]}" "${worker_panes[$i]}" "${boot_states[$i]}" \
    "${kick_states[$i]}" "$ready_state"
done

init_complete=1
trap - EXIT INT TERM
if [ "$failed" -ne 0 ]; then
  echo "duet: one or more workers did not confirm readiness; session left running for diagnosis." >&2
  exit 5
fi
echo "duet: all workers READY; leader=$INITIATOR_NAME term=0"
