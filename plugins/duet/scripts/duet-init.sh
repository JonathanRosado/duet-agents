#!/usr/bin/env bash
# Start an n-agent duet ensemble from the invoking harness's tmux pane.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-pairing.sh"

usage(){
  echo "usage: duet-init.sh [--initiator claude|codex|kimi] [--initiator-name <name>] [--initiator-native-id <id>] [--initiator-native-home <dir>] [--member <name>=<harness> ...] [--member-native-id <name>=<id> ...] [--member-native-home <name>=<dir> ...] [--rejoin-from <session dir>] [codex|kimi|claude ...]  (1-4 peers; default: codex kimi)" >&2
}

load_adapter(){
  local harness="${1:?harness required}" adapter="$PLUGIN_DIR/harnesses/${1}.sh"
  [ -f "$adapter" ] || { echo "duet: unsupported harness '$harness'" >&2; return 1; }
  unset DUET_HARNESS_BOOT_RE DUET_HARNESS_BRIEF_FILE
  unset -f duet_harness_check duet_harness_pretrust duet_harness_launch_cmd \
    duet_harness_resume_cmd 2>/dev/null || true
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
command -v node >/dev/null 2>&1 || {
  echo "duet: node is required for exact native-session registration." >&2
  exit 3
}

WORKDIR="$(pwd -P)"
INITIATOR_PANE="${TMUX_PANE:?duet: initiating pane has no TMUX_PANE}"
DUET_TMUX_SOCKET="$(tmux display-message -p -t "$INITIATOR_PANE" '#{socket_path}')"
WINDOW_ID="$(_duet_tmux display-message -p -t "$INITIATOR_PANE" '#{window_id}')"
DUET_TMUX_SERVER_PID="$(_duet_tmux display-message -p '#{pid}')"

initiator_harness="${DUET_INITIATOR_HARNESS:-}"
initiator_name_arg="${DUET_INITIATOR_NAME:-}"
initiator_native_id="${DUET_INITIATOR_NATIVE_ID:-}"
initiator_native_home_arg="${DUET_INITIATOR_NATIVE_HOME:-}"
member_specs=()
member_native_ids=()
member_native_homes=()
rejoin_from=""
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
    --initiator-native-id)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_native_id="$2"
      shift 2
      ;;
    --initiator-native-home)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_native_home_arg="$2"
      shift 2
      ;;
    --member)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      member_specs+=("$2")
      shift 2
      ;;
    --member-native-id)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      member_native_ids+=("$2")
      shift 2
      ;;
    --member-native-home)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      member_native_homes+=("$2")
      shift 2
      ;;
    --rejoin-from)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      rejoin_from="$2"
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
worker_native_ids=()
worker_native_provenances=()
worker_native_homes=()
worker_registration_files=()
worker_registration_nonces=()
boot_states=()
kick_states=()
ready_states=()
codex_count=0
kimi_count=0
claude_count=0

# Explicit member specs (used by rejoin) pin stable roster names; positional
# harness words derive instance names as before. The two forms never mix.
if [ "${#member_specs[@]}" -gt 0 ]; then
  [ "${#workers[@]}" -eq 0 ] || {
    usage; echo "duet: --member cannot be combined with positional harness words." >&2
    exit 2
  }
  [ "${#member_specs[@]}" -ge 1 ] && [ "${#member_specs[@]}" -le 4 ] \
    || { usage; exit 2; }
  for spec in "${member_specs[@]}"; do
    case "$spec" in
      *=*) : ;;
      *) usage; echo "duet: --member must be <name>=<harness>." >&2; exit 2 ;;
    esac
    candidate="${spec%%=*}"
    harness="${spec#*=}"
    case "$candidate" in
      ''|*[!A-Za-z0-9_-]*)
        echo "duet: member name must contain only letters, digits, '_' or '-'." >&2
        exit 2
        ;;
    esac
    case "$harness" in
      claude|codex|kimi) : ;;
      *) usage; echo "duet: unsupported harness '$harness'" >&2; exit 2 ;;
    esac
    [ "$candidate" != "$INITIATOR_NAME" ] || {
      echo "duet: member name collides with the initiator name." >&2; exit 2
    }
    for existing in ${worker_names[@]+"${worker_names[@]}"}; do
      [ "$candidate" != "$existing" ] || {
        echo "duet: duplicate member name '$candidate'." >&2; exit 2
      }
    done
    worker_names+=("$candidate")
    workers+=("$harness")
  done
else
  [ "${#workers[@]}" -gt 0 ] || workers=(codex kimi)
  [ "${#workers[@]}" -ge 1 ] && [ "${#workers[@]}" -le 4 ] \
    || { usage; exit 2; }
fi

# Optional native session ids, matched by member name. An id for the initiator
# name is folded into the initiator's own capture; worker ids switch that
# worker's launch to the adapter's native-resume command.
seen_native_specs=""
for spec in ${member_native_ids[@]+"${member_native_ids[@]}"}; do
  case "$spec" in
    *=*) : ;;
    *) usage; echo "duet: --member-native-id must be <name>=<id>." >&2; exit 2 ;;
  esac
  spec_name="${spec%%=*}"
  spec_id="${spec#*=}"
  case " $seen_native_specs " in
    *" $spec_name "*)
      echo "duet: duplicate --member-native-id for '$spec_name'." >&2; exit 2 ;;
  esac
  seen_native_specs="$seen_native_specs $spec_name"
  spec_known=""
  if [ "$spec_name" = "$INITIATOR_NAME" ]; then
    initiator_native_id="$spec_id"
    spec_known=1
  else
    for existing in ${worker_names[@]+"${worker_names[@]}"}; do
      [ "$spec_name" = "$existing" ] && spec_known=1
    done
  fi
  [ -n "$spec_known" ] || {
    echo "duet: --member-native-id names unknown member '$spec_name'." >&2; exit 2
  }
done

seen_home_specs=""
for spec in ${member_native_homes[@]+"${member_native_homes[@]}"}; do
  case "$spec" in
    *=*) : ;;
    *) usage; echo "duet: --member-native-home must be <name>=<dir>." >&2; exit 2 ;;
  esac
  spec_name="${spec%%=*}"
  spec_home="${spec#*=}"
  case " $seen_home_specs " in
    *" $spec_name "*)
      echo "duet: duplicate --member-native-home for '$spec_name'." >&2; exit 2 ;;
  esac
  seen_home_specs="$seen_home_specs $spec_name"
  spec_known=""
  if [ "$spec_name" = "$INITIATOR_NAME" ]; then
    initiator_native_home_arg="$spec_home"
    spec_known=1
  else
    for existing in ${worker_names[@]+"${worker_names[@]}"}; do
      [ "$spec_name" = "$existing" ] && spec_known=1
    done
  fi
  [ -n "$spec_known" ] || {
    echo "duet: --member-native-home names unknown member '$spec_name'." >&2; exit 2
  }
done

member_native_id_for(){
  local want="${1:?name required}" spec
  for spec in ${member_native_ids[@]+"${member_native_ids[@]}"}; do
    [ "${spec%%=*}" = "$want" ] && { printf '%s' "${spec#*=}"; return 0; }
  done
  return 1
}

member_native_home_for(){
  local want="${1:?name required}" spec
  for spec in ${member_native_homes[@]+"${member_native_homes[@]}"}; do
    [ "${spec%%=*}" = "$want" ] && { printf '%s' "${spec#*=}"; return 0; }
  done
  return 1
}

# Validate and name the entire requested roster before disturbing an old session.
load_adapter "$initiator_harness"
duet_harness_check
for i in ${workers[@]+"${!workers[@]}"}; do
  harness="${workers[$i]}"
  case "$harness" in
    codex|kimi|claude) : ;;
    *) usage; echo "duet: unsupported harness '$harness'" >&2; exit 2 ;;
  esac
  if [ "${#worker_names[@]}" -le "$i" ]; then
    case "$harness" in
      codex) prefix=codex; count_var=codex_count ;;
      kimi)  prefix=kimi;  count_var=kimi_count ;;
      claude) prefix=claude; count_var=claude_count ;;
    esac
    while :; do
      eval "$count_var=\$((\${$count_var} + 1))"
      eval "candidate=\"\$prefix-\${$count_var}\""
      [ "$candidate" != "$INITIATOR_NAME" ] && break
    done
    worker_names+=("$candidate")
  fi
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
STAMP="$(date +%Y%m%d-%H%M%S)"
DUET_DIR="$(mktemp -d "$DUET_STATE_ROOT/$STAMP-XXXXXX")"
DUET_SESSION_ID="$(basename "$DUET_DIR")"
DUET_SESSION="$DUET_SESSION_ID"
NATIVE_REGISTRATION_HELPER="$PLUGIN_DIR/scripts/duet-native-register.js"
[ -f "$NATIVE_REGISTRATION_HELPER" ] || {
  echo "duet: native registration helper is missing: $NATIVE_REGISTRATION_HELPER" >&2
  exit 7
}
initiator_native_home="$(duet_native_home "$initiator_harness" \
  "$initiator_native_home_arg" 2>/dev/null || true)"
[ -n "$initiator_native_home" ] || {
  echo "duet: could not resolve the $initiator_harness native config home." >&2
  exit 7
}
# Freeze the invoker's exact argument/environment identity before anchors or
# same-harness workers can create new transcript records. We never infer it
# from session-store recency.
initiator_capture="$(duet_capture_initiator_id "$initiator_harness" "$WORKDIR" \
  "$initiator_native_id" 2>/dev/null || true)"
initiator_captured_id="${initiator_capture%%$'\t'*}"
initiator_provenance="${initiator_capture#*$'\t'}"
if [ -z "$initiator_captured_id" ] \
    || [ "$initiator_captured_id" = "$initiator_provenance" ]; then
  initiator_captured_id=""
  initiator_provenance=""
fi

init_complete=""
cleanup_on_exit(){
  local status=$? i pane recorded_pid actual_pid
  if [ -z "$init_complete" ]; then
    : > "$DUET_DIR/.ended" 2>/dev/null || true
    if ! duet_stop_daemon "$DUET_DIR" 20; then
      echo "duet: init cleanup could not stop the delivery daemon cleanly." >&2
    fi
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
    duet_strip_session_anchors "$WORKDIR" || true
  fi
  return "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

mkdir -p "$DUET_DIR/ready" "$DUET_DIR/native-registration"
chmod 700 "$DUET_DIR/native-registration" 2>/dev/null || true
: > "$DUET_DIR/transcript.md"
printf '# Duet assignments\n' > "$DUET_DIR/assignments.md"
printf 'ok\n' > "$DUET_DIR/ready/$INITIATOR_NAME"

for name in "${worker_names[@]}"; do
  mkdir -p "$DUET_DIR/inbox/$name/delivered" \
           "$DUET_DIR/inbox/$name/rejected"
done
mkdir -p "$DUET_DIR/inbox/$INITIATOR_NAME/delivered" \
         "$DUET_DIR/inbox/$INITIATOR_NAME/rejected"

render_brief(){
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@DUET_DIR@/$DUET_DIR}"
    line="${line//@PLUGIN@/$PLUGIN_DIR}"
    line="${line//@DUET_SESSION@/$DUET_SESSION}"
    line="${line//@INITIATOR@/$INITIATOR_NAME}"
    printf '%s\n' "$line"
  done < "$PLUGIN_DIR/briefs/ENSEMBLE_BRIEF.md"
}

# Rendered only on a rejoin: the prior run's session dir, its kept transcript,
# and how many queued messages were left undelivered (never replayed).
render_rejoin_note(){
  local line old_undelivered
  old_undelivered="$(duet_count_undelivered "$rejoin_from")"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@OLD_SESSION_DIR@/$rejoin_from}"
    line="${line//@OLD_UNDELIVERED@/$old_undelivered}"
    line="${line//@OLD_TRANSCRIPT@/$rejoin_from/transcript.md}"
    printf '%s\n' "$line"
  done < "$PLUGIN_DIR/briefs/REJOIN_NOTE.md"
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
    if [ -n "$rejoin_from" ]; then
      printf '\n'
      render_rejoin_note
    fi
    printf '<!-- DUET:END -->\n'
  } >> "$file"
}

append_anchor "$WORKDIR/AGENTS.md"
append_anchor "$WORKDIR/CLAUDE.md"

# Pretrust and launch workers. No boot message is sent until roster/config are
# atomically published, even if a TUI becomes ready early. Workers carrying a
# paired native id resume that harness session; spawned Claude workers without
# one are assigned a fresh UUID so pairing capture never guesses.
#
# Codex/Kimi workers carry a unique registration path and nonce. Their
# SessionStart hook reports the exact native session id and binds it to the
# resulting pane tuple; repeated workers may therefore boot in any order.
# Claude workers additionally receive an assigned UUID at launch.
requested_native_keys=""
for i in "${!workers[@]}"; do
  harness="${workers[$i]}"
  name="${worker_names[$i]}"
  load_adapter "$harness"
  native_home="$(member_native_home_for "$name" 2>/dev/null || true)"
  native_home="$(duet_native_home "$harness" "$native_home" 2>/dev/null || true)"
  [ -n "$native_home" ] || {
    echo "duet: could not resolve the native config home for $name." >&2
    exit 7
  }
  worker_native_homes+=("$native_home")
  duet_harness_pretrust "$WORKDIR" "$native_home"
  native_id="$(member_native_id_for "$name" || true)"
  native_provenance=""
  if [ -n "$native_id" ]; then
    native_id="$(duet_normalize_native_id "$harness" "$native_id")"
    duet_native_id_shape "$harness" "$native_id" || {
      echo "duet: native id for $name fails the $harness shape check." >&2
      exit 2
    }
    native_key="$harness:$native_home:$native_id"
    case " $requested_native_keys " in
      *" $native_key "*)
        echo "duet: native session $native_id was assigned to more than one $harness member." >&2
        exit 2 ;;
    esac
    requested_native_keys="$requested_native_keys $native_key"
    if [ "$harness" = "$initiator_harness" ] \
        && [ "$native_home" = "$initiator_native_home" ] \
        && [ "$native_id" = "$initiator_captured_id" ]; then
      echo "duet: worker $name cannot resume the initiator's same native session." >&2
      exit 2
    fi
    type duet_harness_resume_cmd >/dev/null 2>&1 || {
      echo "duet: harness adapter '$harness' has no resume command." >&2
      exit 2
    }
    native_provenance=arg
  else
    assigned_id=""
    if [ "$harness" = claude ]; then
      assigned_id="$(duet_uuidgen)"
    fi
    native_id="$assigned_id"
    [ -z "$assigned_id" ] || native_provenance=assigned
  fi
  registration_file="$DUET_DIR/native-registration/$name.json"
  registration_nonce="$(duet_uuidgen)"
  worker_registration_files+=("$registration_file")
  worker_registration_nonces+=("$registration_nonce")
  DUET_NATIVE_REGISTRATION_FILE="$registration_file"
  DUET_NATIVE_REGISTRATION_NONCE="$registration_nonce"
  DUET_NATIVE_REGISTRATION_NAME="$name"
  DUET_NATIVE_REGISTRATION_HARNESS="$harness"
  DUET_NATIVE_REGISTRATION_HELPER="$NATIVE_REGISTRATION_HELPER"
  DUET_NATIVE_EXPECTED_ID="$native_id"
  if [ "$native_provenance" = arg ]; then
    launch_cmd="$(duet_harness_resume_cmd "$WORKDIR" "$DUET_DIR" "$name" \
      "$native_id" "$native_home")"
  else
    launch_cmd="$(duet_harness_launch_cmd "$WORKDIR" "$DUET_DIR" "$name" \
      "$native_id" "$native_home")"
  fi

  if [ "$i" -eq 0 ]; then
    pane="$(_duet_tmux split-window -h -t "$INITIATOR_PANE" -P -F '#{pane_id}' "$launch_cmd")"
  else
    pane="$(_duet_tmux split-window -t "$WINDOW_ID" -P -F '#{pane_id}' "$launch_cmd")"
  fi
  worker_panes+=("$pane")
  pane_pid="$(_duet_tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
  worker_pids+=("$pane_pid")
  worker_native_ids+=("$native_id")
  worker_native_provenances+=("$native_provenance")
done
unset DUET_NATIVE_REGISTRATION_FILE DUET_NATIVE_REGISTRATION_NONCE \
  DUET_NATIVE_REGISTRATION_NAME DUET_NATIVE_REGISTRATION_HARNESS \
  DUET_NATIVE_REGISTRATION_HELPER DUET_NATIVE_EXPECTED_ID

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
  printf 'DUET_INITIATOR=%q\n' "$INITIATOR_NAME"
  printf 'DUET_INITIATOR_PANE=%q\n' "$INITIATOR_PANE"
} > "$env_tmp"
if ! duet_publish_temp_file "$env_tmp" "$DUET_DIR/duet.env"; then
  rm -f "$env_tmp" 2>/dev/null || true
  echo "duet: could not publish the session config." >&2
  exit 7
fi

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

# Compute health before pairing publication. A worker that never reached its
# banner/readiness gate (especially a failed native resume) must not supersede
# the last good mapping merely because its old session file still exists.
failed=0
for i in "${!workers[@]}"; do
  name="${worker_names[$i]}"
  actual_pid="$(_duet_tmux display-message -p -t "${worker_panes[$i]}" \
    '#{pane_pid}' 2>/dev/null || true)"
  if [ -f "$DUET_DIR/ready/$name" ] \
      && [ "${boot_states[$i]}" = ready ] \
      && [ "$actual_pid" = "${worker_pids[$i]}" ]; then
    ready_states[$i]=yes
  else
    ready_states[$i]=no
    failed=1
  fi
done

# Pairing capture: record each member's harness-native session id so a later
# rejoin can rebuild the mesh around the same native sessions. Capture is
# best-effort and never fails the live transport; the complete marker and
# per-member by-id indexes appear only when every exact SessionStart
# registration, native store, roster tuple, and readiness gate validates.
pairing_complete=1
pairing_rows=()
repo_key="$(duet_repo_key "$WORKDIR" || true)"
captured_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ -z "$initiator_captured_id" ] \
    || [ "$initiator_captured_id" = "$initiator_provenance" ]; then
  pairing_complete=""
  initiator_captured_id=""
  initiator_provenance=""
  echo "duet: pairing: no native session id captured for initiator $INITIATOR_NAME." >&2
else
  # A captured id that does not resolve on disk must not complete a record.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    duet_native_id_resolvable "$initiator_harness" "$initiator_captured_id" \
      "$initiator_native_home" \
      && break
    sleep 0.3
  done
  if ! duet_native_id_resolvable "$initiator_harness" "$initiator_captured_id" \
      "$initiator_native_home"; then
    pairing_complete=""
    echo "duet: pairing: initiator native id is not resolvable on disk; record stays diagnostic." >&2
  fi
fi
pairing_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$INITIATOR_NAME" "$initiator_harness" "$initiator_captured_id" \
  "$initiator_provenance" "$INITIATOR_PANE" "$initiator_pid" \
  "$DUET_TMUX_SOCKET" "$DUET_TMUX_SERVER_PID" "$WORKDIR" "$repo_key" \
  "$captured_now" "$DUET_SESSION_ID" "$initiator_native_home")")

actual_initiator_pid="$(_duet_tmux display-message -p -t "$INITIATOR_PANE" \
  '#{pane_pid}' 2>/dev/null || true)"
if [ "$actual_initiator_pid" != "$initiator_pid" ]; then
  pairing_complete=""
  echo "duet: pairing: initiator pane identity changed before publication; record stays diagnostic." >&2
fi

for i in "${!workers[@]}"; do
  harness="${workers[$i]}"
  name="${worker_names[$i]}"
  captured_id="${worker_native_ids[$i]:-}"
  provenance="${worker_native_provenances[$i]:-}"
  native_home="${worker_native_homes[$i]}"
  # Codex and Kimi ids are accepted only from the exact pane-scoped lifecycle
  # registration. On resume, the hook must also report the requested id.
  if [ "$harness" = codex ] || [ "$harness" = kimi ]; then
    expected_id="$captured_id"
    capture_tries="${DUET_PAIRING_CAPTURE_TRIES:-30}"
    case "$capture_tries" in ''|*[!0-9]*) capture_tries=30;; esac
    registration=""
    for _ in $(seq 1 "$capture_tries"); do
      registration="$(duet_capture_registered_worker_id \
        "$NATIVE_REGISTRATION_HELPER" "${worker_registration_files[$i]}" \
        "$harness" "$name" "${worker_registration_nonces[$i]}" \
        "$DUET_SESSION_ID" "${worker_panes[$i]}" "${worker_pids[$i]}" \
        "$WORKDIR" "$expected_id" 2>/dev/null || true)"
      [ -n "$registration" ] && break
      sleep 0.1
    done
    if [ -n "$registration" ]; then
      captured_id="${registration%%$'\t'*}"
      registration_source="${registration#*$'\t'}"
      provenance=hook
      if [ -n "$expected_id" ] && [ "$registration_source" != resume ]; then
        captured_id=""
        provenance=""
      elif [ -z "$expected_id" ] && [ "$registration_source" != startup ]; then
        captured_id=""
        provenance=""
      fi
    else
      captured_id=""
      provenance=""
    fi
  fi
  if [ -n "$captured_id" ] && duet_native_id_shape "$harness" "$captured_id"; then
    [ -n "$provenance" ] || provenance="assigned"
    # Completeness requires on-disk resolvability, not just a plausible id.
    if ! duet_native_id_resolvable "$harness" "$captured_id" "$native_home"; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        duet_native_id_resolvable "$harness" "$captured_id" "$native_home" && break
      done
    fi
    if ! duet_native_id_resolvable "$harness" "$captured_id" "$native_home"; then
      pairing_complete=""
      echo "duet: pairing: $name native id is not resolvable on disk; record stays diagnostic." >&2
    fi
  else
    pairing_complete=""
    echo "duet: pairing: no native session id captured for worker $name." >&2
    captured_id=""
    provenance=""
  fi
  if [ "${ready_states[$i]}" != yes ]; then
    pairing_complete=""
    echo "duet: pairing: worker $name did not pass the exact readiness/liveness gate." >&2
  fi
  pairing_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$name" "$harness" "$captured_id" "$provenance" "${worker_panes[$i]}" \
    "${worker_pids[$i]}" "$DUET_TMUX_SOCKET" "$DUET_TMUX_SERVER_PID" "$WORKDIR" \
    "$repo_key" "$captured_now" "$DUET_SESSION_ID" "$native_home")")
done

if [ "$pairing_complete" = 1 ]; then
  if duet_pairing_publish "$DUET_DIR" "$DUET_STATE_ROOT" "$WORKDIR" 1 \
      "${pairing_rows[@]}"; then
    echo "duet: pairing complete; rejoin key recorded for this repo."
  else
    echo "duet: pairing publication did not finish; the record stays unreachable (fail-closed)." >&2
  fi
else
  if duet_pairing_publish "$DUET_DIR" "$DUET_STATE_ROOT" "$WORKDIR" 0 \
      "${pairing_rows[@]}"; then
    echo "duet: pairing incomplete; this run cannot be rejoined (diagnostic kept at $DUET_DIR/pairing.tsv)." >&2
  else
    echo "duet: pairing diagnostic failed structural validation and was not published." >&2
  fi
fi

printf 'duet: session %s\n' "$DUET_DIR"
printf '  %-12s %-8s %-6s %-10s %-22s %s\n' NAME HARNESS PANE BOOT KICK READY
for i in "${!workers[@]}"; do
  name="${worker_names[$i]}"
  printf '  %-12s %-8s %-6s %-10s %-22s %s\n' \
    "$name" "${workers[$i]}" "${worker_panes[$i]}" "${boot_states[$i]}" \
    "${kick_states[$i]}" "${ready_states[$i]}"
done

init_complete=1
trap - EXIT INT TERM
if [ "$failed" -ne 0 ]; then
  echo "duet: one or more workers did not confirm readiness; session left running for diagnosis." >&2
  exit 5
fi
echo "duet: all peers READY; initiator=$INITIATOR_NAME harness=$initiator_harness"
