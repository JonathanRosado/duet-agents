#!/usr/bin/env bash
# Start an n-agent duet ensemble from the invoking harness's tmux pane.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"

usage(){
  echo "usage: duet-init.sh [--initiator claude|codex|kimi] [--initiator-name <name>] [codex|kimi|claude ...]  (1-4 peers; default: codex)" >&2
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
  echo "duet: not inside tmux. Start a supported harness in tmux first." >&2
  exit 3
}
command -v tmux >/dev/null 2>&1 || { echo "duet: tmux not found on PATH" >&2; exit 3; }

WORKDIR="$(pwd -P)"
INITIATOR_PANE="${TMUX_PANE:?duet: initiating pane has no TMUX_PANE}"
DUET_TMUX_SOCKET="$(tmux display-message -p -t "$INITIATOR_PANE" '#{socket_path}')"
WINDOW_ID="$(_duet_tmux display-message -p -t "$INITIATOR_PANE" '#{window_id}')"
DUET_TMUX_SERVER_PID="$(_duet_tmux display-message -p '#{pid}')"

initiator_harness="${DUET_INITIATOR_HARNESS:-}"
initiator_name_arg="${DUET_INITIATOR_NAME:-}"
workers=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --initiator)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_harness="$2"
      shift 2
      ;;
    --initiator-name)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_name_arg="$2"
      shift 2
      ;;
    --) shift; workers+=("$@"); break ;;
    -*) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
    *) workers+=("$1"); shift ;;
  esac
done

if [ -z "$initiator_harness" ]; then
  pane_command="$(_duet_tmux display-message -p -t "$INITIATOR_PANE" \
    '#{pane_current_command}' 2>/dev/null || true)"
  case "$pane_command" in
    claude|codex|kimi) initiator_harness="$pane_command" ;;
    *)
      echo "duet: could not infer the invoking harness; pass --initiator claude, codex, or kimi." >&2
      exit 2
      ;;
  esac
fi
case "$initiator_harness" in
  claude|codex|kimi) : ;;
  *) usage; echo "duet: unsupported initiator harness '$initiator_harness'" >&2; exit 2 ;;
esac
INITIATOR_NAME="${initiator_name_arg:-$initiator_harness}"
case "$INITIATOR_NAME" in
  ''|*[!A-Za-z0-9_-]*)
    echo "duet: initiator name must contain only letters, digits, '_' or '-'." >&2
    exit 2
    ;;
esac

[ "${#workers[@]}" -gt 0 ] || workers=(codex)
[ "${#workers[@]}" -ge 1 ] && [ "${#workers[@]}" -le 4 ] \
  || { usage; exit 2; }

if [ -z "${DUET_STATE_ROOT:-}" ]; then
  [ -n "${HOME:-}" ] || {
    echo "duet: set DUET_STATE_ROOT or HOME before starting a session." >&2
    exit 7
  }
  DUET_STATE_ROOT="$HOME/.duet"
fi

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
load_adapter "$initiator_harness"
duet_harness_check
for harness in "${workers[@]}"; do
  case "$harness" in
    codex)
      while :; do
        codex_count=$((codex_count + 1))
        candidate="codex-$codex_count"
        [ "$candidate" != "$INITIATOR_NAME" ] && break
      done
      worker_names+=("$candidate")
      ;;
    kimi)
      while :; do
        kimi_count=$((kimi_count + 1))
        candidate="kimi-$kimi_count"
        [ "$candidate" != "$INITIATOR_NAME" ] && break
      done
      worker_names+=("$candidate")
      ;;
    claude)
      while :; do
        claude_count=$((claude_count + 1))
        candidate="claude-$claude_count"
        [ "$candidate" != "$INITIATOR_NAME" ] && break
      done
      worker_names+=("$candidate")
      ;;
    *) usage; echo "duet: unsupported harness '$harness'" >&2; exit 2 ;;
  esac
  load_adapter "$harness"
  duet_harness_check
done

mkdir -p "$DUET_STATE_ROOT"
DUET_STATE_ROOT="$(cd "$DUET_STATE_ROOT" && pwd -P)"
if [ "$DUET_STATE_ROOT" = / ]; then
  echo "duet: refusing to use / as DUET_STATE_ROOT." >&2
  exit 7
fi
case "$DUET_STATE_ROOT" in
  *$'\t'*|*$'\r'*|*$'\n'*)
    echo "duet: DUET_STATE_ROOT contains a control character; init aborted." >&2
    exit 7
    ;;
esac
mkdir -p "$DUET_STATE_ROOT/workdirs"
DUET_WORKDIR_KEY="$(duet_workdir_key "$WORKDIR")"
WORKDIR_ACTIVE="$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.active"
WORKDIR_LOCK="$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.lock"
workdir_lock_held=""

release_workdir_lock(){
  [ -n "$workdir_lock_held" ] || return 0
  if duet_lock_release "$WORKDIR_LOCK"; then
    workdir_lock_held=""
    return 0
  fi
  return 1
}

# Locate a pre-A8 predecessor only by inspecting immutable session configs and
# matching their canonical workdir. Never consult current as routing state.
legacy_predecessor_candidate(){
  local env="${1:?config required}" expected="${2:?expected workdir required}"
  local expected_root="$DUET_STATE_ROOT" config_parent config_dir config_workdir
  local DUET_DIR="" WORKDIR="" PLUGIN_DIR="" DUET_TMUX_SOCKET=""
  local DUET_TMUX_SERVER_PID="" DUET_SESSION="" DUET_SESSION_ID=""
  local DUET_WORKDIR_KEY="" CODEX_PANE="" CODEX_PANE_PID=""

  config_parent="$(cd "$(dirname "$env")" && pwd -P)" || return 1
  case "$config_parent" in
    "$expected_root"/*) : ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC1090
  . "$env" 2>/dev/null || return 1
  [ -n "$DUET_DIR" ] && [ -n "$WORKDIR" ] || return 1
  config_dir="$(cd "$DUET_DIR" 2>/dev/null && pwd -P)" || return 1
  config_workdir="$(cd "$WORKDIR" 2>/dev/null && pwd -P)" || return 1
  [ "$config_dir" = "$config_parent" ] || return 1
  [ "$config_workdir" = "$expected" ] || return 1
  printf '%s' "$config_dir"
}

find_legacy_predecessor(){
  local env candidate match="" count=0 expected_workdir="$WORKDIR"
  for env in "$DUET_STATE_ROOT"/*/duet.env; do
    if [ -L "$env" ]; then
      echo "duet: refusing symlinked legacy session config: $env" >&2
      return 1
    fi
    [ -f "$env" ] || continue
    [ "$(basename "$(dirname "$env")")" != current ] || continue
    [ ! -f "$(dirname "$env")/.ended" ] || continue
    candidate="$(legacy_predecessor_candidate "$env" "$expected_workdir")" \
      || continue
    [ -n "$candidate" ] || continue
    count=$((count + 1))
    match="$candidate"
  done
  if [ "$count" -gt 1 ]; then
    echo "duet: multiple live legacy sessions claim workdir $WORKDIR; refusing ambiguous reap." >&2
    return 1
  fi
  printf '%s' "$match"
}

workdir_lock_attempts="${DUET_WORKDIR_LOCK_ATTEMPTS:-4000}"
case "$workdir_lock_attempts" in ''|*[!0-9]*) workdir_lock_attempts=4000;; esac
duet_lock_acquire "$WORKDIR_LOCK" "$workdir_lock_attempts" || {
  echo "duet: another init/end owns the workdir transition lock." >&2
  exit 7
}
workdir_lock_held=1
trap 'release_workdir_lock 2>/dev/null || true' EXIT

PREV_DIR=""
PREV_DIR_RECORDED=""
if [ -f "$WORKDIR_ACTIVE" ]; then
  PREV_DIR="$(cat "$WORKDIR_ACTIVE" 2>/dev/null || true)"
  case "$PREV_DIR" in
    ''|*$'\n'*)
      echo "duet: corrupt active-session record for workdir $WORKDIR; init aborted." >&2
      exit 7
      ;;
  esac
else
  PREV_DIR="$(find_legacy_predecessor)" || exit 7
fi

if [ -n "$PREV_DIR" ]; then
  PREV_DIR_RECORDED="$PREV_DIR"
  PREV_DIR="$(cd "$PREV_DIR" 2>/dev/null && pwd -P)" || {
    echo "duet: active session path is unavailable; init aborted." >&2
    exit 7
  }
  case "$PREV_DIR" in
    "$DUET_STATE_ROOT"/*) : ;;
    *) echo "duet: active session is outside DUET_STATE_ROOT; init aborted." >&2; exit 7 ;;
  esac
  PREV_ENV="$PREV_DIR/duet.env"
  if [ -L "$PREV_ENV" ]; then
    echo "duet: active session config is a symlink; init aborted." >&2
    exit 7
  fi
  [ -f "$PREV_ENV" ] || {
    echo "duet: active session config is missing: $PREV_ENV" >&2
    exit 7
  }
  caller_pane="$INITIATOR_PANE"
  expected_workdir="$WORKDIR"
  expected_prev_dir="$(cd "$PREV_DIR" && pwd -P)"
  if ! (
    config_path="$PREV_ENV"
    config_parent="$(cd "$(dirname "$config_path")" && pwd -P)" || exit 1
    unset DUET_DIR WORKDIR PLUGIN_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
    unset DUET_SESSION DUET_SESSION_ID DUET_WORKDIR_KEY CODEX_PANE CODEX_PANE_PID
    # shellcheck disable=SC1090
    . "$config_path"
    [ -n "${DUET_DIR:-}" ] && [ -n "${WORKDIR:-}" ] || exit 1
    config_dir="$(cd "$DUET_DIR" 2>/dev/null && pwd -P)" || exit 1
    config_workdir="$(cd "$WORKDIR" 2>/dev/null && pwd -P)" || exit 1
    [ "$config_dir" = "$config_parent" ] || exit 1
    [ "$config_dir" = "$expected_prev_dir" ] || exit 1
    [ "$config_workdir" = "$expected_workdir" ] || exit 1
    duet_reap_session "$config_dir" "$config_workdir" "${DUET_TMUX_SOCKET:-}" \
      "$caller_pane" "${CODEX_PANE:-}" "${DUET_TMUX_SERVER_PID:-}" \
      "${CODEX_PANE_PID:-}"
  ); then
    echo "duet: same-workdir predecessor could not be validated/reaped; init aborted." >&2
    exit 7
  fi
  if [ -f "$WORKDIR_ACTIVE" ] \
      && [ "$(cat "$WORKDIR_ACTIVE" 2>/dev/null || true)" = "$PREV_DIR_RECORDED" ]; then
    rm -f "$WORKDIR_ACTIVE"
  fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DUET_DIR="$(mktemp -d "$DUET_STATE_ROOT/$STAMP-XXXXXX")"
DUET_SESSION_ID="$(basename "$DUET_DIR")"
DUET_SESSION="$DUET_SESSION_ID"

init_complete=""
cleanup_on_exit(){
  local status=$? i pane recorded_pid actual_pid current_target active_target cleanup_safe=1
  if [ -z "$init_complete" ]; then
    : > "$DUET_DIR/.ended" 2>/dev/null || true
    if ! duet_stop_daemon "$DUET_DIR" 20; then
      echo "duet: init cleanup left panes intact because the daemon could not be fenced." >&2
      cleanup_safe=""
    fi
    if [ -n "$cleanup_safe" ]; then
      # Bash 3.2 + nounset rejects an ordinary expansion of an empty array.
      for i in ${worker_panes[@]+"${!worker_panes[@]}"}; do
        pane="${worker_panes[$i]}"
        recorded_pid="${worker_pids[$i]:-}"
        [ -n "$pane" ] || continue
        [ "$pane" = "$INITIATOR_PANE" ] && continue
        [ -n "$recorded_pid" ] || continue
        actual_pid="$(_duet_tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
        [ "$actual_pid" = "$recorded_pid" ] \
          && _duet_tmux kill-pane -t "$pane" 2>/dev/null || true
      done
      active_target="$(cat "$WORKDIR_ACTIVE" 2>/dev/null || true)"
      if [ -z "$active_target" ] || [ "$active_target" = "$DUET_DIR" ]; then
        duet_strip_session_anchors "$WORKDIR" || true
        [ "$active_target" != "$DUET_DIR" ] || rm -f "$WORKDIR_ACTIVE"
      fi
      if duet_lock_acquire "$DUET_STATE_ROOT/.current.lock" 80 2>/dev/null; then
        current_target="$(readlink "$DUET_STATE_ROOT/current" 2>/dev/null || true)"
        [ "$current_target" != "$DUET_DIR" ] || rm -f "$DUET_STATE_ROOT/current"
        duet_lock_release "$DUET_STATE_ROOT/.current.lock" 2>/dev/null || true
      fi
    fi
  fi
  release_workdir_lock 2>/dev/null || true
  return "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

mkdir -p "$DUET_DIR/ready"
: > "$DUET_DIR/transcript.md"
printf '# Duet assignments\n' > "$DUET_DIR/assignments.md"
printf 'ok\n' > "$DUET_DIR/ready/$INITIATOR_NAME"

for name in "${worker_names[@]}"; do
  mkdir -p "$DUET_DIR/inbox/$name/delivered" \
           "$DUET_DIR/inbox/$name/failed" \
           "$DUET_DIR/inbox/$name/quarantine" \
           "$DUET_DIR/inbox/$name/superseded"
done
mkdir -p "$DUET_DIR/inbox/$INITIATOR_NAME/delivered" \
         "$DUET_DIR/inbox/$INITIATOR_NAME/failed" \
         "$DUET_DIR/inbox/$INITIATOR_NAME/quarantine" \
         "$DUET_DIR/inbox/$INITIATOR_NAME/superseded"

render_brief(){
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@DUET_DIR@/$DUET_DIR}"
    line="${line//@PLUGIN@/$PLUGIN_DIR}"
    line="${line//@DUET_SESSION@/$DUET_SESSION}"
    printf '%s\n' "$line"
  done < "$PLUGIN_DIR/briefs/ENSEMBLE_BRIEF.md"
}

append_anchor(){
  local file="${1:?anchor file required}"
  if [ -L "$file" ]; then
    echo "duet: refusing symlinked anchor file: $file" >&2
    return 1
  fi
  touch "$file"
  duet_strip_anchor_file "$file"
  {
    printf '\n<!-- DUET:BEGIN (added by duet-init; removed by duet-end) -->\n'
    render_brief
    printf '<!-- DUET:END -->\n'
  } >> "$file"
}

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
  "$INITIATOR_NAME" "$initiator_harness" "$INITIATOR_PANE" "$initiator_pid" >> "$roster_tmp"
for i in "${!workers[@]}"; do
  printf '%s\t%s\t%s\t%s\t%s\t1\n' \
    "${worker_names[$i]}" "${workers[$i]}" "${worker_panes[$i]}" \
    "${worker_pids[$i]}" "$((i + 1))" >> "$roster_tmp"
done
if ! duet_publish_temp_file "$roster_tmp" "$DUET_DIR/roster.tsv"; then
  rm -f "$roster_tmp" 2>/dev/null || true
  echo "duet: could not publish the session roster." >&2
  exit 7
fi
if ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
  echo "duet: generated session roster failed validation." >&2
  exit 7
fi

env_tmp="$(mktemp "$DUET_DIR/.env.XXXXXX")"
{
  printf 'DUET_DIR=%q\n' "$DUET_DIR"
  printf 'DUET_STATE_ROOT=%q\n' "$DUET_STATE_ROOT"
  printf 'WORKDIR=%q\n' "$WORKDIR"
  printf 'PLUGIN_DIR=%q\n' "$PLUGIN_DIR"
  printf 'DUET_TMUX_SOCKET=%q\n' "$DUET_TMUX_SOCKET"
  printf 'DUET_TMUX_SERVER_PID=%q\n' "$DUET_TMUX_SERVER_PID"
  printf 'DUET_SESSION=%q\n' "$DUET_SESSION"
  printf 'DUET_SESSION_ID=%q\n' "$DUET_SESSION_ID"
  printf 'DUET_WORKDIR_KEY=%q\n' "$DUET_WORKDIR_KEY"
  printf 'DUET_INITIATOR=%q\n' "$INITIATOR_NAME"
  printf 'DUET_INITIATOR_PANE=%q\n' "$INITIATOR_PANE"
} > "$env_tmp"
if ! duet_publish_temp_file "$env_tmp" "$DUET_DIR/duet.env"; then
  rm -f "$env_tmp" 2>/dev/null || true
  echo "duet: could not publish the session config." >&2
  exit 7
fi
duet_atomic_write "$WORKDIR_ACTIVE" "$DUET_DIR"
if ! duet_lock_acquire "$DUET_STATE_ROOT/.current.lock" 80; then
  echo "duet: could not acquire the current-session publication lock." >&2
  exit 7
fi
current_link="$DUET_STATE_ROOT/current"
if [ -d "$current_link" ] && [ ! -L "$current_link" ]; then
  duet_lock_release "$DUET_STATE_ROOT/.current.lock" 2>/dev/null || true
  echo "duet: current-session publication path is a directory; refusing to publish." >&2
  exit 7
fi
if ! ln -sfn "$DUET_DIR" "$current_link" \
    || [ "$(readlink "$current_link" 2>/dev/null || true)" != "$DUET_DIR" ]; then
  duet_lock_release "$DUET_STATE_ROOT/.current.lock" 2>/dev/null || true
  echo "duet: could not publish the current-session convenience link." >&2
  exit 7
fi
duet_lock_release "$DUET_STATE_ROOT/.current.lock"

DUET_CONFIG="$DUET_DIR/duet.env" DUET_SESSION="$DUET_SESSION" \
  nohup bash "$PLUGIN_DIR/scripts/duet-deliverd.sh" \
  --session "$DUET_DIR/duet.env" --session-id "$DUET_SESSION_ID" \
  >/dev/null 2>&1 &
daemon_boot_pid=$!
disown 2>/dev/null || true
daemon_ready=""
for _ in $(seq 1 50); do
  if duet_daemon_alive; then daemon_ready=1; break; fi
  kill -0 "$daemon_boot_pid" 2>/dev/null || break
  sleep 0.1
done
[ -n "$daemon_ready" ] || {
  echo "duet: delivery daemon failed to start; see $DUET_DIR/deliverd.log" >&2
  exit 6
}

# Wait for every harness banner, then enqueue boot kicks through the same daemon
# path used by every later message.
boot_timeout="${DUET_BOOT_TIMEOUT:-35}"
for i in "${!workers[@]}"; do
  harness="${workers[$i]}"
  name="${worker_names[$i]}"
  pane="${worker_panes[$i]}"
  load_adapter "$harness"
  boot_state=timeout
  for _ in $(seq 1 "$boot_timeout"); do
    if ! _duet_alive "$pane"; then boot_state=dead; break; fi
    # Tiling 3-5 agents can shrink a pane enough that the startup banner sits
    # just above the visible viewport before this loop runs. Search a bounded
    # slice of history so a ready TUI is not misclassified as a boot timeout.
    if _duet_tmux capture-pane -p -S -200 -t "$pane" 2>/dev/null \
        | grep -qE "$DUET_HARNESS_BOOT_RE"; then
      boot_state=ready
      break
    fi
    sleep 1
  done
  boot_states[$i]="$boot_state"

  printf -v ready_path_q '%q' "$DUET_DIR/ready/$name"
  printf -v kick '[DUET boot]\nYou are %s (harness: %s). Read %s. Confirm readiness now by running exactly this shell command: printf '\''ok\\n'\'' > %s . Then wait for a task from a peer.' \
    "$name" "$harness" "$DUET_HARNESS_BRIEF_FILE" "$ready_path_q"
  kick_state=failed
  if kick_output="$(printf '%s' "$kick" \
      | DUET_CONFIG="$DUET_DIR/duet.env" DUET_SESSION="$DUET_SESSION" \
        bash "$SELF_DIR/duet-send.sh" "$name" --from "$INITIATOR_NAME")"; then
    kick_state="queued:${kick_output#duet: queued }"
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
if ! release_workdir_lock; then
  echo "duet: could not release the workdir transition lock." >&2
  exit 7
fi
trap - EXIT INT TERM
if [ "$failed" -ne 0 ]; then
  echo "duet: one or more workers did not confirm readiness; session left running for diagnosis." >&2
  exit 5
fi
echo "duet: all peers READY; initiator=$INITIATOR_NAME harness=$initiator_harness"
