#!/usr/bin/env bash
# Destructive-to-its-own-fixtures M3/M4 gate against real Claude, Codex, and
# Kimi TUIs. All tmux and duet state is isolated; HOME remains the caller's
# real home so the installed CLIs can use their normal authentication. Besides
# failover/fencing, this is the release-candidate fan-out/fan-in and teardown
# check used after documentation or packaging changes.
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
INIT_SCRIPT="$SCRIPTS_DIR/duet-init.sh"
SEND_SCRIPT="$SCRIPTS_DIR/duet-send.sh"
END_SCRIPT="$SCRIPTS_DIR/duet-end.sh"
STATUS_SCRIPT="$SCRIPTS_DIR/duet-status.sh"
DOCTOR_SCRIPT="$SCRIPTS_DIR/duet-doctor.sh"
# shellcheck disable=SC1091
. "$SCRIPTS_DIR/duet-common.sh"

CLAUDE_MODEL=haiku
CODEX_MODEL=gpt-5.3-codex-spark
CODEX_REASONING_EFFORT=low
KIMI_MODEL=kimi-code/kimi-for-coding

# A gate may itself be launched from a live agent pane. Drop every ambient
# routing hint before doing anything: all test routing below is explicit.
unset DUET_CONFIG DUET_SESSION DUET_SESSION_ID DUET_SELF TMUX TMUX_PANE

REAL_HOME="${HOME:?m3 real smoke requires the caller real HOME}"
REAL_CODEX_HOME="${CODEX_HOME:-$REAL_HOME/.codex}"
CODEX_CONFIG="$REAL_CODEX_HOME/config.toml"
HARD_LABEL="duet-m3-real-hard-$PPID-${RANDOM:-0}"
SOFT_LABEL="duet-m3-real-soft-$PPID-${RANDOM:-0}"
HARD_TMUX_SESSION=hard
SOFT_TMUX_SESSION=soft
HARD_SOCKET=""
SOFT_SOCKET=""
HARD_CONFIG=""
SOFT_CONFIG=""
HARD_DIR=""
SOFT_DIR=""
ACTIVE_PID=""
SOFT_DAEMON_STOPPED=""
SUCCESS=""
CLEANING=""
DRIVER_PID="${BASHPID:-$$}"

say(){ printf '[m3-real] %s\n' "$*"; }

die(){
  printf '[m3-real] FAIL: %s\n' "$*" >&2
  exit 1
}

is_trusted_codex_project(){
  local candidate="${1:?candidate required}"
  [ -f "$CODEX_CONFIG" ] || return 1
  awk -v wanted="[projects.\"$candidate\"]" '
    $0 == wanted { inside=1; next }
    inside && /^\[/ { exit(found ? 0 : 1) }
    inside && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"trusted"/ {
      found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$CODEX_CONFIG"
}

find_trusted_codex_ancestor(){
  local candidate
  candidate="$(cd "$PLUGIN_DIR" && pwd -P)"
  while [ "$candidate" != / ]; do
    if is_trusted_codex_project "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    candidate="$(dirname "$candidate")"
  done
  return 1
}

for command_name in tmux claude codex kimi base64 awk sed grep mktemp git cp shasum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "required command is unavailable: $command_name"
done
kimi doctor >/dev/null 2>&1 || die "kimi doctor failed"

# Put fixtures below a known project root, but give Codex an isolated home:
# trust is exact-path (not inherited), and the adapter may safely pretrust each
# temporary workdir without changing the user's real config. Authentication is
# copied locally for this short-lived run and deleted with the fixture.
TRUSTED_ROOT="$(find_trusted_codex_ancestor)" \
  || die "no trusted Codex project contains this checkout"
[ "$TRUSTED_ROOT" != / ] || die "refusing to place smoke fixtures under /"

TEST_ROOT="$(mktemp -d "$TRUSTED_ROOT/.duet-m3-real.XXXXXX")" \
  || die "could not allocate test root"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || die "could not canonicalize test root"
STATE_ROOT="$TEST_ROOT/state"
SMOKE_CODEX_HOME="$TEST_ROOT/codex-home"
HARD_WORK="$TEST_ROOT/hard-work"
SOFT_WORK="$TEST_ROOT/soft-work"
LOG_DIR="$TEST_ROOT/logs"
mkdir -p "$STATE_ROOT" "$SMOKE_CODEX_HOME" "$HARD_WORK" "$SOFT_WORK" "$LOG_DIR" \
  || die "could not create isolated fixtures"

# Credential staging happens before the full server-aware cleanup function is
# defined. Cover that setup window with a minimal exact-path trap so an early
# failure or signal can never retain the copied auth file under the fixture.
cleanup_staged_credentials(){
  local status=$?
  trap - EXIT HUP INT TERM
  case "$SMOKE_CODEX_HOME" in
    "$TEST_ROOT"/codex-home) rm -rf -- "$SMOKE_CODEX_HOME" ;;
    *) printf '[m3-real] refused unsafe early Codex-home cleanup: %s\n' \
         "$SMOKE_CODEX_HOME" >&2 ;;
  esac
  exit "$status"
}
trap cleanup_staged_credentials EXIT
trap 'exit 130' HUP INT TERM

for codex_file in auth.json config.toml models_cache.json version.json; do
  [ ! -f "$REAL_CODEX_HOME/$codex_file" ] \
    || cp -p "$REAL_CODEX_HOME/$codex_file" "$SMOKE_CODEX_HOME/$codex_file" \
    || die "could not stage isolated Codex $codex_file"
done
[ -f "$SMOKE_CODEX_HOME/auth.json" ] \
  || die "real Codex authentication is unavailable at $REAL_CODEX_HOME/auth.json"
[ -f "$SMOKE_CODEX_HOME/config.toml" ] \
  || : > "$SMOKE_CODEX_HOME/config.toml"
CODEX_CONFIG_BEFORE="$(shasum -a 256 "$CODEX_CONFIG" | awk '{ print $1 }')"
# Bound instruction discovery to each fixture instead of inheriting AGENTS.md
# from whichever real project contains this test checkout.
git -C "$HARD_WORK" init -q || die "could not initialize hard fixture repository"
git -C "$SOFT_WORK" init -q || die "could not initialize soft fixture repository"

default_current_fingerprint(){
  local path="$REAL_HOME/.duet/current"
  if [ -L "$path" ]; then
    printf 'link:%s' "$(readlink "$path" 2>/dev/null || true)"
  elif [ -e "$path" ]; then
    printf 'other:%s' "$(ls -di "$path" 2>/dev/null || true)"
  else
    printf 'missing'
  fi
}
DEFAULT_CURRENT_BEFORE="$(default_current_fingerprint)"

tmux_hard(){ command tmux -L "$HARD_LABEL" "$@"; }
tmux_soft(){ command tmux -L "$SOFT_LABEL" "$@"; }

owned_child_alive(){
  local pid="${1:-}" parent
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  parent="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')"
  [ "$parent" = "$DRIVER_PID" ]
}

capture_server(){
  local which="$1" destination="$2" pane
  : > "$destination"
  if [ "$which" = hard ]; then
    tmux_hard list-panes -a -F '#{pane_id}' 2>/dev/null |
      while IFS= read -r pane; do
        [ -n "$pane" ] || continue
        printf '\n===== %s =====\n' "$pane" >> "$destination"
        tmux_hard capture-pane -p -S - -t "$pane" >> "$destination" 2>&1 || true
      done
  else
    tmux_soft list-panes -a -F '#{pane_id}' 2>/dev/null |
      while IFS= read -r pane; do
        [ -n "$pane" ] || continue
        printf '\n===== %s =====\n' "$pane" >> "$destination"
        tmux_soft capture-pane -p -S - -t "$pane" >> "$destination" 2>&1 || true
      done
  fi
}

exact_daemon_pid(){
  local config="${1:?config required}" dir session pid owner command_line
  [ -f "$config" ] || return 1
  dir="$(dirname "$config")"
  session="$(basename "$dir")"
  pid="$(cat "$dir/daemon.pid" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  if [ -d "$dir/.daemon.lock" ]; then
    owner="$(cat "$dir/.daemon.lock/owner" 2>/dev/null || true)"
  else
    owner="$(cat "$dir/.daemon.lock" 2>/dev/null || true)"
  fi
  [ "${owner%%$'\t'*}" = "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case " $command_line " in
    *duet-deliverd.sh*" --session $config --session-id $session "*)
      printf '%s' "$pid"
      ;;
    *) return 1 ;;
  esac
}

stop_exact_daemon(){
  local config="${1:-}" pid
  pid="$(exact_daemon_pid "$config" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  kill -CONT "$pid" 2>/dev/null || true
  pid="$(exact_daemon_pid "$config" 2>/dev/null || true)"
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
}

write_failure_diagnostics(){
  local config session
  capture_server hard "$LOG_DIR/hard-panes.txt"
  capture_server soft "$LOG_DIR/soft-panes.txt"
  # Include a session whose init died after publishing its config but before
  # this driver learned its path.
  for config in "$STATE_ROOT"/*/duet.env; do
    [ -f "$config" ] || continue
    session="$(basename "$(dirname "$config")")"
    env HOME="$REAL_HOME" bash "$STATUS_SCRIPT" --session "$config" \
      > "$LOG_DIR/$session-status-final.txt" 2>&1 || true
    env HOME="$REAL_HOME" bash "$DOCTOR_SCRIPT" --session "$config" \
      > "$LOG_DIR/$session-doctor-final.txt" 2>&1 || true
  done
  printf '%s\n' "before=$DEFAULT_CURRENT_BEFORE" \
    "after=$(default_current_fingerprint)" \
    "codex_config_before=$CODEX_CONFIG_BEFORE" \
    "codex_config_after=$(shasum -a 256 "$CODEX_CONFIG" 2>/dev/null | awk '{ print $1 }')" \
    > "$LOG_DIR/default-current.txt"
}

cleanup(){
  local status=$? socket child_wait
  [ -z "$CLEANING" ] || return
  CLEANING=1
  trap - EXIT HUP INT TERM

  case "$ACTIVE_PID" in
    ''|*[!0-9]*) : ;;
    *)
      owned_child_alive "$ACTIVE_PID" \
        && kill -TERM "$ACTIVE_PID" 2>/dev/null || true
      child_wait=0
      while owned_child_alive "$ACTIVE_PID" && [ "$child_wait" -lt 20 ]; do
        sleep 0.1
        child_wait=$((child_wait + 1))
      done
      owned_child_alive "$ACTIVE_PID" \
        && kill -KILL "$ACTIVE_PID" 2>/dev/null || true
      wait "$ACTIVE_PID" 2>/dev/null || true
      ACTIVE_PID=""
      ;;
  esac

  if [ -z "$SUCCESS" ] || [ "$status" -ne 0 ]; then
    write_failure_diagnostics
  fi
  [ -z "$SOFT_DAEMON_STOPPED" ] || {
    stopped_pid="$(exact_daemon_pid "$SOFT_DAEMON_STOPPED" 2>/dev/null || true)"
    [ -z "$stopped_pid" ] || kill -CONT "$stopped_pid" 2>/dev/null || true
    SOFT_DAEMON_STOPPED=""
  }
  for partial_config in "$STATE_ROOT"/*/duet.env; do
    [ -f "$partial_config" ] || continue
    stop_exact_daemon "$partial_config"
  done
  tmux_hard kill-server >/dev/null 2>&1 || true
  tmux_soft kill-server >/dev/null 2>&1 || true

  for socket in "$HARD_SOCKET" "$SOFT_SOCKET"; do
    case "$socket" in
      */tmux-*/"$HARD_LABEL"|*/tmux-*/"$SOFT_LABEL") rm -f -- "$socket" ;;
    esac
  done

  # Failure diagnostics never need a copied credential. Remove the isolated
  # Codex home after its tmux servers are gone, even when other logs are kept.
  case "$SMOKE_CODEX_HOME" in
    "$TEST_ROOT"/codex-home) rm -rf -- "$SMOKE_CODEX_HOME" ;;
    *) printf '[m3-real] refused unsafe Codex-home cleanup: %s\n' "$SMOKE_CODEX_HOME" >&2 ;;
  esac

  if [ -n "$SUCCESS" ] && [ "$status" -eq 0 ]; then
    case "$TEST_ROOT" in
      "$TRUSTED_ROOT"/.duet-m3-real.*) rm -rf -- "$TEST_ROOT" ;;
      *) printf '[m3-real] refused unsafe cleanup path: %s\n' "$TEST_ROOT" >&2; status=1 ;;
    esac
  else
    printf '[m3-real] diagnostics retained at %s\n' "$TEST_ROOT" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

wait_until(){
  local timeout="${1:?timeout required}" label="${2:?label required}"
  shift 2
  local deadline=$(( $(date +%s) + timeout ))
  while ! "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || die "timed out: $label"
    sleep 0.25
  done
}

run_timed_log(){
  local timeout="${1:?timeout required}" log="${2:?log required}" rc deadline
  shift 2
  "$@" > "$log" 2>&1 &
  ACTIVE_PID=$!
  deadline=$(( $(date +%s) + timeout ))
  while owned_child_alive "$ACTIVE_PID"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      owned_child_alive "$ACTIVE_PID" \
        && kill -TERM "$ACTIVE_PID" 2>/dev/null || true
      sleep 1
      owned_child_alive "$ACTIVE_PID" \
        && kill -KILL "$ACTIVE_PID" 2>/dev/null || true
      wait "$ACTIVE_PID" 2>/dev/null || true
      ACTIVE_PID=""
      return 124
    fi
    sleep 0.25
  done
  wait "$ACTIVE_PID"
  rc=$?
  ACTIVE_PID=""
  return "$rc"
}

run_in_workdir(){
  local workdir="${1:?workdir required}"
  shift
  cd "$workdir" || return 1
  "$@"
}

pane_has(){
  local which="$1" pane="$2" pattern="$3"
  if [ "$which" = hard ]; then
    tmux_hard capture-pane -p -t "$pane" 2>/dev/null | grep -qE "$pattern"
  else
    tmux_soft capture-pane -p -t "$pane" 2>/dev/null | grep -qE "$pattern"
  fi
}

pane_history_has(){
  local which="$1" pane="$2" pattern="$3"
  if [ "$which" = hard ]; then
    tmux_hard capture-pane -p -S - -t "$pane" 2>/dev/null | grep -qE "$pattern"
  else
    tmux_soft capture-pane -p -S - -t "$pane" 2>/dev/null | grep -qE "$pattern"
  fi
}

pane_pid_is(){
  local which="$1" pane="$2" expected="$3" actual
  if [ "$which" = hard ]; then
    actual="$(tmux_hard display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
  else
    actual="$(tmux_soft display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
  fi
  [ "$actual" = "$expected" ]
}

pane_absent(){
  local which="$1" pane="$2"
  if [ "$which" = hard ]; then
    if tmux_hard list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane"; then
      return 1
    fi
  else
    if tmux_soft list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane"; then
      return 1
    fi
  fi
  return 0
}

process_has_arg_text(){
  local pid="$1" expected="$2" command_line
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  printf '%s\n' "$command_line" | grep -qF -- "$expected"
}

pane_start_command_has(){
  local which="$1" pane="$2" expected="$3" command_line
  if [ "$which" = hard ]; then
    command_line="$(tmux_hard display-message -p -t "$pane" '#{pane_start_command}' 2>/dev/null || true)"
  else
    command_line="$(tmux_soft display-message -p -t "$pane" '#{pane_start_command}' 2>/dev/null || true)"
  fi
  printf '%s\n' "$command_line" | grep -qF -- "$expected"
}

roster_value(){
  local roster="$1" name="$2" column="$3"
  awk -F '\t' -v wanted="$name" -v field="$column" \
    '$1 == wanted { print $field; exit }' "$roster"
}

leader_is(){
  local dir="$1" term="$2" leader="$3" actual_term actual_leader
  actual_term="$(awk -F '\t' '$1 == "term" { print $2; exit }' "$dir/leader" 2>/dev/null)"
  actual_leader="$(awk -F '\t' '$1 == "leader" { print $2; exit }' "$dir/leader" 2>/dev/null)"
  [ "$actual_term" = "$term" ] && [ "$actual_leader" = "$leader" ]
}

message_id_matches(){
  local file="$1" id="$2"
  [ -f "$file" ] || return 1
  [ "$(awk -F '\t' '$1 == "id" { print $2; exit }' "$file")" = "$id" ]
}

message_delivered(){
  local box="$1" id="$2" file
  for file in "$box"/delivered/*.msg; do
    message_id_matches "$file" "$id" && return 0
  done
  return 1
}

promotion_delivered(){
  local dir="$1" term="$2" recipient="$3" file file_term file_recipient
  for file in "$dir/inbox/promotions/delivered"/*.msg; do
    [ -f "$file" ] || continue
    file_term="$(awk -F '\t' '$1 == "term" { print $2; exit }' "$file")"
    file_recipient="$(awk -F '\t' '$1 == "recipient" { print $2; exit }' "$file")"
    [ "$file_term" = "$term" ] && [ "$file_recipient" = "$recipient" ] && return 0
  done
  return 1
}

active_message_count(){
  local dir="$1" box file count=0
  for box in "$dir"/inbox/*; do
    [ -d "$box" ] || continue
    for file in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$file" ] || continue
      count=$((count + 1))
    done
  done
  printf '%s' "$count"
}

all_messages_terminal(){ [ "$(active_message_count "$1")" -eq 0 ]; }

terminal_count_for_id(){
  local box="$1" id="$2" directory file count=0
  for directory in delivered failed quarantine superseded; do
    for file in "$box/$directory"/*.msg; do
      [ -f "$file" ] || continue
      if message_id_matches "$file" "$id"; then count=$((count + 1)); fi
    done
  done
  printf '%s' "$count"
}

terminal_count_for_id_is(){
  local box="${1:?queue directory required}" id="${2:?message id required}"
  local expected="${3:?expected count required}"
  [ "$(terminal_count_for_id "$box" "$id")" -eq "$expected" ]
}

transcript_token_count_is(){
  local dir="${1:?session directory required}" token="${2:?token required}"
  local expected="${3:?expected count required}" count
  count="$(grep -cF "$token" "$dir/transcript.md" 2>/dev/null || true)"
  [ "$count" -eq "$expected" ]
}

delivered_reply_count_is(){
  local box="${1:?queue directory required}" sender="${2:?sender required}"
  local expected_body="${3-}" expected_count="${4:?expected count required}"
  local file count=0
  for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
    [ -f "$file" ] || continue
    duet_read_message "$file" || continue
    if [ "$DUET_MESSAGE_SENDER" = "$sender" ] \
        && [ "$DUET_MESSAGE_RECIPIENT" = leader ] \
        && [ "$DUET_MESSAGE_BODY" = "$expected_body" ]; then
      count=$((count + 1))
    fi
  done
  [ "$count" -eq "$expected_count" ]
}

send_from(){
  local config="$1" sender="$2" recipient="$3" body="$4"
  local output_file="$LOG_DIR/send-$RANDOM-$$.txt"
  if ! printf '%s' "$body" | env HOME="$REAL_HOME" \
      DUET_CONFIG="$config" DUET_ALLOW_FROM_OVERRIDE=1 \
      bash "$SEND_SCRIPT" "$recipient" --from "$sender" --session "$config" \
      > "$output_file" 2>&1; then
    cat "$output_file" >> "$LOG_DIR/sends.log"
    die "explicit send $sender -> $recipient failed (see sends.log)"
  fi
  cat "$output_file" >> "$LOG_DIR/sends.log"
  SEND_ID="$(sed -n 's/^duet: queued \([^ ]*\) for .*/\1/p' "$output_file" | tail -n 1)"
  [ -n "$SEND_ID" ] || die "could not parse queued message id"
  rm -f "$output_file"
}

send_all_from(){
  local config="$1" sender="$2" body="$3"
  local output_file="$LOG_DIR/send-all-$RANDOM-$$.txt"
  if ! printf '%s' "$body" | env HOME="$REAL_HOME" \
      DUET_CONFIG="$config" DUET_ALLOW_FROM_OVERRIDE=1 \
      bash "$SEND_SCRIPT" all --from "$sender" --session "$config" \
      > "$output_file" 2>&1; then
    cat "$output_file" >> "$LOG_DIR/sends.log"
    die "explicit broadcast from $sender failed (see sends.log)"
  fi
  cat "$output_file" >> "$LOG_DIR/sends.log"
  SEND_ALL_CLAUDE_ID="$(sed -n 's/^duet: queued \([^ ]*\) for claude$/\1/p' \
    "$output_file" | tail -n 1)"
  SEND_ALL_KIMI_ID="$(sed -n 's/^duet: queued \([^ ]*\) for kimi-1$/\1/p' \
    "$output_file" | tail -n 1)"
  [ -n "$SEND_ALL_CLAUDE_ID" ] && [ -n "$SEND_ALL_KIMI_ID" ] \
    || die "could not parse broadcast message ids"
  [ "$(grep -cE '^duet: queued [^ ]+ for (claude|kimi-1)$' "$output_file" \
      2>/dev/null || true)" -eq 2 ] \
    || die "broadcast did not enqueue exactly one copy per non-sender"
  if grep -qE '^duet: queued [^ ]+ for codex-1$' "$output_file"; then
    die "broadcast enqueued an unexpected sender copy"
  fi
  rm -f "$output_file"
}

current_points_to(){
  [ -L "$STATE_ROOT/current" ] \
    && [ "$(readlink "$STATE_ROOT/current" 2>/dev/null || true)" = "$1" ]
}

say "models: Claude=$CLAUDE_MODEL Codex=$CODEX_MODEL Kimi=$KIMI_MODEL"
say "fixtures: $TEST_ROOT (HOME remains $REAL_HOME)"

# --- Hard-failover session: real Claude initiator, Codex, and Kimi. ---
printf -v CLAUDE_COMMAND 'exec env DUET_CLAUDE_MODEL=%q %q --model %q --dangerously-skip-permissions' \
  "$CLAUDE_MODEL" "$(command -v claude)" "$CLAUDE_MODEL"
tmux_hard -f /dev/null new-session -d -s "$HARD_TMUX_SESSION" \
  -c "$HARD_WORK" "$CLAUDE_COMMAND" \
  || die "could not start isolated hard tmux server"
HARD_CLAUDE_PANE="$(tmux_hard display-message -p -t "$HARD_TMUX_SESSION" '#{pane_id}')"
HARD_CLAUDE_PID="$(tmux_hard display-message -p -t "$HARD_CLAUDE_PANE" '#{pane_pid}')"
HARD_SOCKET="$(tmux_hard display-message -p '#{socket_path}')"
HARD_SERVER_PID="$(tmux_hard display-message -p '#{pid}')"
wait_until 60 "Claude Haiku boot" pane_has hard "$HARD_CLAUDE_PANE" 'Claude Code'

say "initializing hard session"
if ! run_timed_log 360 "$LOG_DIR/hard-init.log" run_in_workdir "$HARD_WORK" \
    env HOME="$REAL_HOME" CODEX_HOME="$SMOKE_CODEX_HOME" \
    TMUX="$HARD_SOCKET,$HARD_SERVER_PID,0" TMUX_PANE="$HARD_CLAUDE_PANE" \
    DUET_STATE_ROOT="$STATE_ROOT" \
    DUET_CLAUDE_MODEL="$CLAUDE_MODEL" DUET_CODEX_MODEL="$CODEX_MODEL" \
    DUET_CODEX_REASONING_EFFORT="$CODEX_REASONING_EFFORT" \
    DUET_KIMI_MODEL="$KIMI_MODEL" DUET_BOOT_TIMEOUT=75 DUET_READY_TIMEOUT=240 \
    bash "$INIT_SCRIPT" codex kimi; then
  die "hard duet-init failed or timed out (see hard-init.log)"
fi
HARD_DIR="$(readlink "$STATE_ROOT/current" 2>/dev/null || true)"
case "$HARD_DIR" in "$STATE_ROOT"/*) :;; *) die "hard init published an invalid session path";; esac
HARD_CONFIG="$HARD_DIR/duet.env"
[ -f "$HARD_CONFIG" ] || die "hard session config is missing"
current_points_to "$HARD_DIR" || die "isolated current does not name hard session"

HARD_CODEX_PANE="$(roster_value "$HARD_DIR/roster.tsv" codex-1 3)"
HARD_KIMI_PANE="$(roster_value "$HARD_DIR/roster.tsv" kimi-1 3)"
HARD_CODEX_PID="$(roster_value "$HARD_DIR/roster.tsv" codex-1 4)"
HARD_KIMI_PID="$(roster_value "$HARD_DIR/roster.tsv" kimi-1 4)"
[ -n "$HARD_CODEX_PANE" ] && [ -n "$HARD_KIMI_PANE" ] \
  || die "hard roster is incomplete"
process_has_arg_text "$HARD_CLAUDE_PID" "--model $CLAUDE_MODEL" \
  || die "Claude worker did not launch with the smoke model"
process_has_arg_text "$HARD_CODEX_PID" "-m $CODEX_MODEL" \
  || die "Codex worker did not launch with the smoke model"
process_has_arg_text "$HARD_CODEX_PID" "model_reasoning_effort=$CODEX_REASONING_EFFORT" \
  || die "Codex worker did not launch with the smoke reasoning effort"
pane_start_command_has hard "$HARD_KIMI_PANE" "-m $KIMI_MODEL" \
  || die "Kimi worker did not launch with the smoke model"
pane_history_has hard "$HARD_KIMI_PANE" 'Model:[[:space:]]+K2\.7 Coding' \
  || die "Kimi worker did not render the expected managed model"

say "running one real leader fan-out / worker fan-in round"
CODEX_FANIN_TOKEN="M4-FANIN-CODEX-$PPID-${RANDOM:-0}"
KIMI_FANIN_TOKEN="M4-FANIN-KIMI-$PPID-${RANDOM:-0}"
printf -v CODEX_FANOUT_BODY \
  'M4 release-candidate fan-out. Run the pinned duet send command from your session brief exactly once and send this exact one-line body to leader: %s. Do not send any other duet reply for this task; then wait.' \
  "$CODEX_FANIN_TOKEN"
printf -v KIMI_FANOUT_BODY \
  'M4 release-candidate fan-out. Run the pinned duet send command from your session brief exactly once and send this exact one-line body to leader: %s. Do not send any other duet reply for this task; then wait.' \
  "$KIMI_FANIN_TOKEN"
send_from "$HARD_CONFIG" claude codex-1 "$CODEX_FANOUT_BODY"
CODEX_FANOUT_ID="$SEND_ID"
send_from "$HARD_CONFIG" claude kimi-1 "$KIMI_FANOUT_BODY"
KIMI_FANOUT_ID="$SEND_ID"
wait_until 90 "Codex fan-out delivery" \
  message_delivered "$HARD_DIR/inbox/codex-1" "$CODEX_FANOUT_ID"
wait_until 90 "Kimi fan-out delivery" \
  message_delivered "$HARD_DIR/inbox/kimi-1" "$KIMI_FANOUT_ID"
# Each token appears once in the leader's assignment and once in the worker's
# reply. Counting transcript entries, rather than pane text, also catches a
# worker that accidentally enqueues a duplicate response. The pinned command
# in the brief uses a heredoc, so the exact decoded reply body includes its one
# terminating newline.
wait_until 180 "Codex worker fan-in" \
  transcript_token_count_is "$HARD_DIR" "$CODEX_FANIN_TOKEN" 2
wait_until 180 "Kimi worker fan-in" \
  transcript_token_count_is "$HARD_DIR" "$KIMI_FANIN_TOKEN" 2
wait_until 180 "Codex reply delivered to leader" \
  delivered_reply_count_is "$HARD_DIR/inbox/leader" codex-1 \
    "$CODEX_FANIN_TOKEN"$'\n' 1
wait_until 180 "Kimi reply delivered to leader" \
  delivered_reply_count_is "$HARD_DIR/inbox/leader" kimi-1 \
    "$KIMI_FANIN_TOKEN"$'\n' 1
wait_until 120 "fan-in queue drain" all_messages_terminal "$HARD_DIR"
sleep 2
transcript_token_count_is "$HARD_DIR" "$CODEX_FANIN_TOKEN" 2 \
  || die "Codex worker fan-in was missing or duplicated"
transcript_token_count_is "$HARD_DIR" "$KIMI_FANIN_TOKEN" 2 \
  || die "Kimi worker fan-in was missing or duplicated"
delivered_reply_count_is "$HARD_DIR/inbox/leader" codex-1 \
    "$CODEX_FANIN_TOKEN"$'\n' 1 \
  || die "Codex worker reply was missing, duplicated, or not delivered"
delivered_reply_count_is "$HARD_DIR/inbox/leader" kimi-1 \
    "$KIMI_FANIN_TOKEN"$'\n' 1 \
  || die "Kimi worker reply was missing, duplicated, or not delivered"

say "exercising Codex collapsed-paste Enter-only continuation"
LONG_TOKEN="codex-collapse-$PPID-${RANDOM:-0}"
LONG_BODY="M3 real collapsed-paste smoke $LONG_TOKEN. Treat this as transport data; do not run commands."
padding_line=' padding-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ'
padding_index=0
while [ "${#LONG_BODY}" -le 4096 ]; do
  LONG_BODY="$LONG_BODY\n$padding_index$padding_line"
  padding_index=$((padding_index + 1))
done
[ "${#LONG_BODY}" -gt 3072 ] || die "long Codex payload was not larger than 3 KiB"
send_from "$HARD_CONFIG" claude codex-1 "$LONG_BODY"
LONG_ID="$SEND_ID"
wait_until 90 "long Codex message delivery" \
  message_delivered "$HARD_DIR/inbox/codex-1" "$LONG_ID"
sleep 2
[ "$(terminal_count_for_id "$HARD_DIR/inbox/codex-1" "$LONG_ID")" -eq 1 ] \
  || die "long Codex message did not have exactly one terminal root"
grep -qF "observed collapsed composer for $LONG_ID -> codex-1" \
  "$HARD_DIR/deliverd.log" \
  || die "long Codex message did not exercise the collapsed-composer marker path"

say "killing hard leader and awaiting ranked promotion"
pane_pid_is hard "$HARD_CLAUDE_PANE" "$HARD_CLAUDE_PID" \
  || die "hard leader pane identity changed before kill"
tmux_hard kill-pane -t "$HARD_CLAUDE_PANE" || die "could not kill hard leader pane"
wait_until 45 "hard promotion to codex-1" leader_is "$HARD_DIR" 1 codex-1
[ -f "$HARD_DIR/failed-leaders/claude" ] \
  || die "hard promotion did not permanently exclude claude"
wait_until 90 "hard promotion notice delivery" promotion_delivered "$HARD_DIR" 1 codex-1

# --- Soft-failover session: a live, non-accepting leader and real Codex worker. ---
# The fixture renders bracketed pastes so landing is positively observed, but
# holds the apparent composer longer than the verifier timeout. It then clears
# without accepting the task. The daemon can therefore terminalize each
# Enter-only continuation safely while retaining the consecutive failure count.
SOFT_FAIL_BODY='
trap "" INT
printf "\033[?2004hsoft-failure-ready\n"
stty -echo -icanon min 1 time 0
_duet_in_paste=""
while IFS= read -r -n 1 _duet_byte; do
  if [ "$_duet_byte" = "$(printf "\033")" ]; then
    _duet_sequence="$_duet_byte"
    for _duet_index in 1 2 3 4 5; do
      IFS= read -r -n 1 _duet_next || exit 0
      _duet_sequence="$_duet_sequence$_duet_next"
    done
    case "$_duet_sequence" in
      "$(printf "\033[200~")") _duet_in_paste=1 ;;
      "$(printf "\033[201~")") _duet_in_paste="" ;;
      *) printf "%s" "$_duet_sequence" ;;
    esac
    continue
  fi
  if [ -n "$_duet_in_paste" ]; then
    if [ -n "$_duet_byte" ]; then printf "%s" "$_duet_byte"; else printf "\n"; fi
    continue
  fi
  [ -z "$_duet_byte" ] || continue
  sleep 10
  printf "\033[2J\033[H\033[?2004hsoft-failure-ready\n"
  IFS= read -r -n 1 _duet_discard || exit 0
  IFS= read -r -n 1 _duet_discard || exit 0
done'
printf -v SOFT_FAIL_COMMAND 'exec %q --noprofile --norc -c %q' /bin/bash "$SOFT_FAIL_BODY"
tmux_soft -f /dev/null new-session -d -s "$SOFT_TMUX_SESSION" \
  -c "$SOFT_WORK" "$SOFT_FAIL_COMMAND" \
  || die "could not start isolated soft tmux server"
SOFT_CLAUDE_PANE="$(tmux_soft display-message -p -t "$SOFT_TMUX_SESSION" '#{pane_id}')"
SOFT_CLAUDE_PID="$(tmux_soft display-message -p -t "$SOFT_CLAUDE_PANE" '#{pane_pid}')"
SOFT_SOCKET="$(tmux_soft display-message -p '#{socket_path}')"
SOFT_SERVER_PID="$(tmux_soft display-message -p '#{pid}')"
sleep 1
pane_pid_is soft "$SOFT_CLAUDE_PANE" "$SOFT_CLAUDE_PID" \
  || die "soft blackhole leader did not remain alive"

say "initializing soft session"
if ! run_timed_log 300 "$LOG_DIR/soft-init.log" run_in_workdir "$SOFT_WORK" \
    env HOME="$REAL_HOME" CODEX_HOME="$SMOKE_CODEX_HOME" \
    TMUX="$SOFT_SOCKET,$SOFT_SERVER_PID,0" TMUX_PANE="$SOFT_CLAUDE_PANE" \
    DUET_STATE_ROOT="$STATE_ROOT" \
    DUET_CLAUDE_MODEL="$CLAUDE_MODEL" DUET_CODEX_MODEL="$CODEX_MODEL" \
    DUET_CODEX_REASONING_EFFORT="$CODEX_REASONING_EFFORT" \
    DUET_KIMI_MODEL="$KIMI_MODEL" DUET_DELIVERY_RETRY_BASE=0 \
    DUET_DELIVERY_POLL_INTERVAL=4 \
    DUET_BOOT_TIMEOUT=75 DUET_READY_TIMEOUT=240 \
    bash "$INIT_SCRIPT" codex; then
  die "soft duet-init failed or timed out (see soft-init.log)"
fi
SOFT_DIR="$(readlink "$STATE_ROOT/current" 2>/dev/null || true)"
case "$SOFT_DIR" in "$STATE_ROOT"/*) :;; *) die "soft init published an invalid session path";; esac
[ "$SOFT_DIR" != "$HARD_DIR" ] || die "second init reused the hard session"
SOFT_CONFIG="$SOFT_DIR/duet.env"
[ -f "$SOFT_CONFIG" ] || die "soft session config is missing"
current_points_to "$SOFT_DIR" || die "isolated current did not repoint to soft session"
SOFT_CODEX_PANE="$(roster_value "$SOFT_DIR/roster.tsv" codex-1 3)"
SOFT_CODEX_PID="$(roster_value "$SOFT_DIR/roster.tsv" codex-1 4)"
[ -n "$SOFT_CODEX_PANE" ] && [ -n "$SOFT_CODEX_PID" ] \
  || die "soft Codex worker is absent from roster"

say "checking explicit routing and cross-server pane collision fencing"
send_from "$HARD_CONFIG" codex-1 kimi-1 \
  "Explicit hard-session route after isolated current repointed to $SOFT_DIR."
HARD_EXPLICIT_ID="$SEND_ID"
wait_until 60 "explicit hard route after current repoint" \
  message_delivered "$HARD_DIR/inbox/kimi-1" "$HARD_EXPLICIT_ID"

[ "$HARD_CLAUDE_PANE" = "$SOFT_CLAUDE_PANE" ] \
  || die "isolated servers did not produce the intended colliding pane id"
CROSS_OUTPUT="$LOG_DIR/cross-session-refusal.txt"
if printf '%s' 'foreign caller must be refused' | env HOME="$REAL_HOME" \
    TMUX="$SOFT_SOCKET,$SOFT_SERVER_PID,0" TMUX_PANE="$SOFT_CLAUDE_PANE" \
    DUET_ALLOW_FROM_OVERRIDE=1 \
    bash "$SEND_SCRIPT" kimi-1 --from claude --session "$HARD_CONFIG" \
    > "$CROSS_OUTPUT" 2>&1; then
  die "cross-session colliding-pane send was accepted"
else
  CROSS_RC=$?
fi
[ "$CROSS_RC" -eq 7 ] || die "cross-session refusal returned $CROSS_RC, expected 7"
grep -qF "caller belongs to '$SOFT_DIR'" "$CROSS_OUTPUT" \
  || die "cross-session refusal did not name the caller's actual session"
grep -qF 'override refused' "$CROSS_OUTPUT" \
  || die "cross-session membership override was not explicitly refused"

env HOME="$REAL_HOME" bash "$STATUS_SCRIPT" --session "$HARD_CONFIG" \
  > "$LOG_DIR/hard-status.txt" 2>&1 || die "hard status failed"
env HOME="$REAL_HOME" bash "$DOCTOR_SCRIPT" --session "$HARD_CONFIG" \
  > "$LOG_DIR/hard-doctor.txt" 2>&1 || die "hard doctor found an issue"
grep -qF 'doctor: healthy' "$LOG_DIR/hard-doctor.txt" \
  || die "hard doctor did not report healthy"
HARD_DAEMON_PID="$(exact_daemon_pid "$HARD_CONFIG" 2>/dev/null || true)"
case "$HARD_DAEMON_PID" in
  ''|*[!0-9]*) die "hard daemon identity is invalid before end" ;;
esac

say "broadcasting DUET-END from the promoted leader"
send_all_from "$HARD_CONFIG" codex-1 \
  "DUET-END — M4 release-candidate teardown. Do not send another duet message; stop and wait for session cleanup."
wait_until 90 "DUET-END delivery to remaining live worker" \
  message_delivered "$HARD_DIR/inbox/kimi-1" "$SEND_ALL_KIMI_ID"
# The broadcast also has a copy for the dead former leader. It cannot be
# delivered, but must reach one durable terminal state so the drain barrier is
# not hiding an active queue obligation.
wait_until 60 "DUET-END dead-incumbent copy terminal" \
  terminal_count_for_id_is "$HARD_DIR/inbox/claude" \
    "$SEND_ALL_CLAUDE_ID" 1

say "ending hard session without disturbing soft current"
if ! run_timed_log 120 "$LOG_DIR/hard-end.log" env HOME="$REAL_HOME" \
    bash "$END_SCRIPT" --session "$HARD_CONFIG"; then
  die "explicit hard end failed or timed out"
fi
[ -f "$HARD_DIR/.ended" ] || die "hard end marker is missing"
[ ! -f "$HARD_DIR/daemon.pid" ] || die "hard end left daemon.pid behind"
if kill -0 "$HARD_DAEMON_PID" 2>/dev/null; then
  die "hard end left its delivery daemon alive"
fi
pane_absent hard "$HARD_CODEX_PANE" \
  || die "hard end left the spawned Codex pane alive"
pane_absent hard "$HARD_KIMI_PANE" \
  || die "hard end left the spawned Kimi pane alive"
current_points_to "$SOFT_DIR" || die "ending hard session disturbed soft current"
pane_pid_is soft "$SOFT_CLAUDE_PANE" "$SOFT_CLAUDE_PID" \
  || die "ending hard session disturbed soft leader pane"
pane_pid_is soft "$SOFT_CODEX_PANE" "$SOFT_CODEX_PID" \
  || die "ending hard session disturbed soft worker pane"

say "queuing three failures against the live non-accepting leader"
SOFT_DAEMON_PID="$(exact_daemon_pid "$SOFT_CONFIG" 2>/dev/null || true)"
case "$SOFT_DAEMON_PID" in ''|*[!0-9]*) die "soft daemon identity is invalid";; esac
kill -STOP "$SOFT_DAEMON_PID" || die "could not pause soft daemon for deterministic enqueue"
SOFT_DAEMON_STOPPED="$SOFT_CONFIG"
soft_index=1
while [ "$soft_index" -le 3 ]; do
  send_from "$SOFT_CONFIG" codex-1 leader \
    "Soft watchdog probe $soft_index: the non-accepting leader must not verify this delivery."
  soft_index=$((soft_index + 1))
done
RESUME_PID="$(exact_daemon_pid "$SOFT_CONFIG" 2>/dev/null || true)"
[ "$RESUME_PID" = "$SOFT_DAEMON_PID" ] || die "soft daemon identity changed while paused"
kill -CONT "$RESUME_PID" || die "could not resume soft daemon"
SOFT_DAEMON_STOPPED=""

wait_until 60 "soft promotion to codex-1" leader_is "$SOFT_DIR" 1 codex-1
pane_pid_is soft "$SOFT_CLAUDE_PANE" "$SOFT_CLAUDE_PID" \
  || die "soft failover killed or replaced the still-live incumbent pane"
[ -f "$SOFT_DIR/failed-leaders/claude" ] \
  || die "soft promotion did not permanently exclude claude"
wait_until 90 "soft promotion notice delivery" promotion_delivered "$SOFT_DIR" 1 codex-1
wait_until 120 "soft symbolic queue drain after reroute" all_messages_terminal "$SOFT_DIR"

say "atomically injecting and quarantining a foreign-session payload"
FOREIGN_SECRET="FOREIGN-BODY-MUST-NOT-LAND-$PPID-${RANDOM:-0}"
FOREIGN_SEQ="$(printf '%010d' "$((9000000000 + ${RANDOM:-0}))")"
FOREIGN_BOX="$SOFT_DIR/inbox/codex-1"
FOREIGN_ROOT="$FOREIGN_BOX/N-$FOREIGN_SEQ.msg"
FOREIGN_TMP="$(mktemp "$FOREIGN_BOX/.foreign.XXXXXX")" \
  || die "could not allocate foreign payload staging file"
FOREIGN_BODY64="$(printf '%s' "$FOREIGN_SECRET" | base64 | tr -d '\r\n')"
if ! {
  printf 'DUETv1\n'
  printf 'id\tm-foreign-session-codex-1-%s\n' "$FOREIGN_SEQ"
  printf 'session\tforeign-session\n'
  printf 'order\t9999999999\n'
  printf 'mode\tNORMAL\n'
  printf 'sender\tforeign-agent\n'
  printf 'recipient\tcodex-1\n'
  printf 'term\t1\n'
  printf 'origin\tSYSTEM\n'
  printf 'leader_at_send\tforeign-agent\n'
  printf 'dedupe\tforeign-smoke-%s\n' "$FOREIGN_SEQ"
  printf 'body64\t%s\n' "$FOREIGN_BODY64"
} > "$FOREIGN_TMP"; then
  rm -f "$FOREIGN_TMP"
  die "could not stage foreign payload"
fi
[ ! -e "$FOREIGN_ROOT" ] || die "foreign payload target unexpectedly exists"
mv "$FOREIGN_TMP" "$FOREIGN_ROOT" || die "atomic foreign payload publish failed"
FOREIGN_QUARANTINE="$FOREIGN_BOX/quarantine/$(basename "$FOREIGN_ROOT")"
wait_until 30 "foreign payload quarantine" test -f "$FOREIGN_QUARANTINE"
wait_until 30 "foreign quarantine leader notice" test -f "$FOREIGN_QUARANTINE.noticed"
[ "$(cat "$FOREIGN_QUARANTINE.reason" 2>/dev/null || true)" = foreign-session ] \
  || die "foreign payload quarantine reason is not foreign-session"
wait_until 90 "foreign notice delivery" all_messages_terminal "$SOFT_DIR"
[ "$(grep -cF 'Quarantined a foreign-session payload in local queue codex-1' \
    "$SOFT_DIR/transcript.md" 2>/dev/null || true)" -eq 1 ] \
  || die "foreign payload did not generate exactly one safe leader notice"
if grep -qF "$FOREIGN_SECRET" "$SOFT_DIR/transcript.md"; then
  die "foreign payload body leaked into transcript"
fi
if tmux_soft capture-pane -p -S - -t "$SOFT_CLAUDE_PANE" 2>/dev/null \
    | grep -qF "$FOREIGN_SECRET"; then
  die "foreign payload body landed in the old leader pane"
fi
if tmux_soft capture-pane -p -S - -t "$SOFT_CODEX_PANE" 2>/dev/null \
    | grep -qF "$FOREIGN_SECRET"; then
  die "foreign payload body landed in the promoted leader pane"
fi

say "running pinned status and doctor on the promoted soft session"
env HOME="$REAL_HOME" bash "$STATUS_SCRIPT" --session "$SOFT_CONFIG" \
  > "$LOG_DIR/soft-status.txt" 2>&1 || die "soft status failed"
grep -qF 'leadership    : term=1 leader=codex-1' "$LOG_DIR/soft-status.txt" \
  || die "soft status did not report promoted leadership"
env HOME="$REAL_HOME" bash "$DOCTOR_SCRIPT" --session "$SOFT_CONFIG" \
  > "$LOG_DIR/soft-doctor.txt" 2>&1 || die "soft doctor found an issue"
grep -qF 'doctor: healthy' "$LOG_DIR/soft-doctor.txt" \
  || die "soft doctor did not report healthy"

say "ending soft session explicitly"
if ! run_timed_log 120 "$LOG_DIR/soft-end.log" env HOME="$REAL_HOME" \
    bash "$END_SCRIPT" --session "$SOFT_CONFIG"; then
  die "explicit soft end failed or timed out"
fi
[ -f "$SOFT_DIR/.ended" ] || die "soft end marker is missing"
[ ! -f "$SOFT_DIR/daemon.pid" ] || die "soft end left daemon.pid behind"
if kill -0 "$SOFT_DAEMON_PID" 2>/dev/null; then
  die "soft end left its delivery daemon alive"
fi
pane_absent soft "$SOFT_CODEX_PANE" \
  || die "soft end left the spawned Codex pane alive"
pane_pid_is soft "$SOFT_CLAUDE_PANE" "$SOFT_CLAUDE_PID" \
  || die "soft end killed or replaced the non-spawned initiator pane"
[ ! -e "$STATE_ROOT/current" ] && [ ! -L "$STATE_ROOT/current" ] \
  || die "soft end left the isolated current link behind"
[ "$(default_current_fingerprint)" = "$DEFAULT_CURRENT_BEFORE" ] \
  || die "the live $REAL_HOME/.duet/current fingerprint changed"
[ "$(shasum -a 256 "$CODEX_CONFIG" | awk '{ print $1 }')" = "$CODEX_CONFIG_BEFORE" ] \
  || die "the live Codex config changed"
if grep -qF '<!-- DUET:BEGIN' "$HARD_WORK/AGENTS.md" "$HARD_WORK/CLAUDE.md" \
    "$SOFT_WORK/AGENTS.md" "$SOFT_WORK/CLAUDE.md" 2>/dev/null; then
  die "duet-end left an anchor in a temporary workdir"
fi

SUCCESS=1
say "PASS: real fan-out/fan-in, hard/soft failover, DUET-END, A8 fences, and diagnostics"
exit 0
