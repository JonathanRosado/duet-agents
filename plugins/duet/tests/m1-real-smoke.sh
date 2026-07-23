#!/usr/bin/env bash
# Real Claude/Codex/Kimi gate for the v4 M1 delivery core.
# Owns tmux server "duetv4smoke" and temporary state/work roots only.
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
INIT_SCRIPT="$SCRIPTS_DIR/duet-init.sh"
SEND_SCRIPT="$SCRIPTS_DIR/duet-send.sh"
END_SCRIPT="$SCRIPTS_DIR/duet-end.sh"
COMMON="$SCRIPTS_DIR/duet-common.sh"
TMUX_LABEL=duetv4smoke
TMUX_SESSION=smoke
REAL_HOME="${HOME:?real HOME is required}"
REAL_CODEX_HOME="${CODEX_HOME:-$REAL_HOME/.codex}"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)" || exit 1
DUET_STATE_ROOT="$(mktemp -d "$TMP_BASE/duetv4-state.XXXXXX")" || exit 1
WORKDIR="$(mktemp -d "$TMP_BASE/duetv4-work.XXXXXX")" || exit 1
SMOKE_CODEX_HOME="$DUET_STATE_ROOT/codex-home"
LOG_DIR="$DUET_STATE_ROOT/gate-logs"
CONFIG=""
DUET_DIR=""
ACTIVE_PID=""
SUCCESS=""
STARTED_AT="$(date +%s)"

# A gate may be launched from a live agent pane. Test routing is always the
# explicit isolated tuple below, never ambient duet/tmux identity.
unset DUET_CONFIG DUET_SESSION DUET_SESSION_ID DUET_SELF TMUX TMUX_PANE
unset CODEX_PANE CODEX_PANE_PID

say(){ printf '[m1-live] %s\n' "$*"; }
die(){ printf '[m1-live] FAIL: %s\n' "$*" >&2; exit 1; }
tmux_smoke(){ command tmux -L "$TMUX_LABEL" "$@"; }

cleanup(){
  local status=$?
  trap - EXIT HUP INT TERM
  case "$ACTIVE_PID" in
    ''|*[!0-9]*) : ;;
    *)
      kill -TERM "$ACTIVE_PID" 2>/dev/null || true
      wait "$ACTIVE_PID" 2>/dev/null || true
      ;;
  esac
  tmux_smoke kill-server >/dev/null 2>&1 || true
  if [ -n "$SUCCESS" ] && [ "$status" -eq 0 ]; then
    case "$DUET_STATE_ROOT" in
      "$TMP_BASE"/duetv4-state.*) rm -rf -- "$DUET_STATE_ROOT" ;;
      *) printf '[m1-live] refused unsafe state cleanup: %s\n' "$DUET_STATE_ROOT" >&2 ;;
    esac
    case "$WORKDIR" in
      "$TMP_BASE"/duetv4-work.*) rm -rf -- "$WORKDIR" ;;
      *) printf '[m1-live] refused unsafe work cleanup: %s\n' "$WORKDIR" >&2 ;;
    esac
  else
    printf '[m1-live] diagnostics retained: %s and %s\n' \
      "$DUET_STATE_ROOT" "$WORKDIR" >&2
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

run_timed(){
  local timeout="${1:?timeout required}" log="${2:?log required}"
  shift 2
  local deadline rc
  "$@" > "$log" 2>&1 &
  ACTIVE_PID=$!
  deadline=$(( $(date +%s) + timeout ))
  while kill -0 "$ACTIVE_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill -TERM "$ACTIVE_PID" 2>/dev/null || true
      sleep 1
      kill -KILL "$ACTIVE_PID" 2>/dev/null || true
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
  local directory="${1:?workdir required}"
  shift
  cd "$directory" || return 1
  "$@"
}

pane_has(){
  local pane="$1" pattern="$2"
  tmux_smoke capture-pane -p -S - -t "$pane" 2>/dev/null \
    | grep -qE "$pattern"
}

claude_ready(){
  local snapshot
  snapshot="$(tmux_smoke capture-pane -p -S -40 -t "$CLAUDE_PANE" \
    2>/dev/null || true)"
  ! printf '%s\n' "$snapshot" | grep -qF 'Quick safety check' \
    && printf '%s\n' "$snapshot" | grep -qF 'Claude Code'
}

message_delivered(){
  local box="$1" id="$2" file
  for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
    [ -f "$file" ] || continue
    [ "$(awk -F '\t' '$1 == "id" { print $2; exit }' "$file")" = "$id" ] \
      && return 0
  done
  return 1
}

message_body_delivered(){
  local box="$1" sender="$2" body="$3" file
  for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
    [ -f "$file" ] || continue
    (
      # shellcheck disable=SC1090
      . "$COMMON"
      duet_read_message "$file" \
        && [ "$DUET_MESSAGE_SENDER" = "$sender" ] \
        && [ "$DUET_MESSAGE_BODY" = "$body" ]
    ) && return 0
  done
  return 1
}

active_message_count(){
  local box file count=0
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    for file in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$file" ] || continue
      count=$((count + 1))
    done
  done
  printf '%s' "$count"
}

all_messages_terminal(){ [ "$(active_message_count)" -eq 0 ]; }

send_from(){
  local sender="$1" recipient="$2" body="$3" output
  output="$LOG_DIR/send-$recipient-$RANDOM.txt"
  if ! printf '%s' "$body" | env HOME="$REAL_HOME" \
      DUET_CONFIG="$CONFIG" DUET_ALLOW_FROM_OVERRIDE=1 \
      bash "$SEND_SCRIPT" "$recipient" --from "$sender" --session "$CONFIG" \
      > "$output" 2>&1; then
    cat "$output" >&2
    die "could not enqueue $sender -> $recipient"
  fi
  SEND_ID="$(sed -n 's/^duet: queued \([^ ]*\) for .*/\1/p' "$output" \
    | tail -n 1)"
  [ -n "$SEND_ID" ] || die "could not parse queued message ID"
  cat "$output"
}

for required in tmux claude codex kimi git base64 awk sed grep mktemp; do
  command -v "$required" >/dev/null 2>&1 \
    || die "required command unavailable: $required"
done
kimi doctor >/dev/null 2>&1 || die "kimi doctor failed"
KIMI_VERSION="$(kimi --version 2>/dev/null || true)"
case "$KIMI_VERSION" in 0.29.*) :;; *) die "expected Kimi 0.29.x, got $KIMI_VERSION";; esac
if tmux_smoke list-sessions >/dev/null 2>&1; then
  die "isolated tmux label $TMUX_LABEL is already in use"
fi

mkdir -p "$SMOKE_CODEX_HOME" "$LOG_DIR"
for file in auth.json config.toml models_cache.json version.json; do
  [ ! -f "$REAL_CODEX_HOME/$file" ] \
    || cp -p "$REAL_CODEX_HOME/$file" "$SMOKE_CODEX_HOME/$file" \
    || die "could not stage Codex $file"
done
[ -f "$SMOKE_CODEX_HOME/auth.json" ] \
  || die "Codex auth unavailable at $REAL_CODEX_HOME/auth.json"
[ -f "$SMOKE_CODEX_HOME/config.toml" ] \
  || : > "$SMOKE_CODEX_HOME/config.toml"
git -C "$WORKDIR" init -q || die "could not initialize temporary workdir"

say "isolated tmux=$TMUX_LABEL state=$DUET_STATE_ROOT work=$WORKDIR"
say "versions: Claude $(claude --version), Codex $(codex --version), Kimi $KIMI_VERSION"

printf -v CLAUDE_COMMAND 'exec %q --model %q --dangerously-skip-permissions' \
  "$(command -v claude)" haiku
tmux_smoke -f /dev/null new-session -d -s "$TMUX_SESSION" \
  -c "$WORKDIR" "$CLAUDE_COMMAND" \
  || die "could not start isolated Claude pane"
CLAUDE_PANE="$(tmux_smoke display-message -p -t "$TMUX_SESSION" '#{pane_id}')"
SOCKET="$(tmux_smoke display-message -p '#{socket_path}')"
SERVER_PID="$(tmux_smoke display-message -p '#{pid}')"
wait_until 75 "Claude boot or trust screen" \
  pane_has "$CLAUDE_PANE" 'Claude Code|Quick safety check'
if pane_has "$CLAUDE_PANE" 'Quick safety check'; then
  tmux_smoke send-keys -t "$CLAUDE_PANE" Enter
fi
wait_until 75 "Claude ready after trust" claude_ready

say "launching Codex and Kimi workers through duet-init"
if ! run_timed 360 "$LOG_DIR/init.log" run_in_workdir "$WORKDIR" env \
    HOME="$REAL_HOME" CODEX_HOME="$SMOKE_CODEX_HOME" \
    TMUX="$SOCKET,$SERVER_PID,0" TMUX_PANE="$CLAUDE_PANE" \
    DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    DUET_CLAUDE_MODEL=haiku \
    DUET_CODEX_REASONING_EFFORT=low \
    DUET_KIMI_MODEL=kimi-code/kimi-for-coding \
    DUET_BOOT_TIMEOUT=90 DUET_READY_TIMEOUT=240 \
    bash "$INIT_SCRIPT" codex kimi; then
  sed 's/^/[init] /' "$LOG_DIR/init.log" >&2 2>/dev/null || true
  die "duet-init failed"
fi
cat "$LOG_DIR/init.log"

DUET_DIR="$(readlink "$DUET_STATE_ROOT/current" 2>/dev/null || true)"
case "$DUET_DIR" in "$DUET_STATE_ROOT"/*) :;; *) die "invalid session path";; esac
SESSION_ID="$(basename "$DUET_DIR")"
CONFIG="$DUET_DIR/duet.env"
[ -f "$CONFIG" ] || die "session config missing"
[ ! -f "$DUET_DIR/.unhealthy" ] || die "session became unhealthy during boot"
CODEX_PANE="$(awk -F '\t' '$1 == "codex-1" { print $3; exit }' \
  "$DUET_DIR/roster.tsv")"
KIMI_PANE="$(awk -F '\t' '$1 == "kimi-1" { print $3; exit }' \
  "$DUET_DIR/roster.tsv")"
[ -n "$CODEX_PANE" ] && [ -n "$KIMI_PANE" ] || die "worker roster incomplete"

say "proving live Codex -> Claude delivery"
FANIN_TOKEN="M1-CODEX-CLAUDE-$PPID-${RANDOM:-0}"
printf -v CODEX_BODY \
  'M1 live delivery gate. Send exactly this one-line body to leader using the pinned duet command in AGENTS.md, then wait: %s' \
  "$FANIN_TOKEN"
send_from claude codex-1 "$CODEX_BODY"
CODEX_TASK_ID="$SEND_ID"
wait_until 90 "Codex task delivery" \
  message_delivered "$DUET_DIR/inbox/codex-1" "$CODEX_TASK_ID"
wait_until 180 "Codex reply delivery to Claude" \
  message_body_delivered "$DUET_DIR/inbox/leader" codex-1 \
    "$FANIN_TOKEN"$'\n'
grep -qF "delivered m-$SESSION_ID-leader-" \
  "$DUET_DIR/deliverd.log" \
  || die "Codex reply did not traverse the live Claude delivery path"
say "PASS live Codex -> Claude id=$CODEX_TASK_ID"

say "proving Kimi 0.29 long collapsed paste"
KIMI_TOKEN="M1-KIMI-COLLAPSED-$PPID-${RANDOM:-0}"
KIMI_BODY="M1 live Kimi transport gate $KIMI_TOKEN. Do not run tools or send a duet reply; accept this prompt and wait."
line=1
while [ "$line" -le 73 ]; do
  printf -v padding 'padding-line-%02d-0123456789-abcdefghijklmnopqrstuvwxyz' "$line"
  KIMI_BODY="$KIMI_BODY
$padding"
  line=$((line + 1))
done
KIMI_SENT_AT="$(date +%s)"
send_from claude kimi-1 "$KIMI_BODY"
KIMI_TASK_ID="$SEND_ID"
wait_until 60 "Kimi long message delivery" \
  message_delivered "$DUET_DIR/inbox/kimi-1" "$KIMI_TASK_ID"
KIMI_ELAPSED=$(( $(date +%s) - KIMI_SENT_AT ))
grep -qF \
  "observed kimi collapsed composer for $KIMI_TASK_ID -> kimi-1" \
  "$DUET_DIR/deliverd.log" \
  || die "daemon did not observe the Kimi collapsed marker"
wait_until 30 "Kimi accepted history" pane_has "$KIMI_PANE" "$KIMI_TOKEN"
KIMI_MARKER="$(
  (
    unset DUET_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
    # shellcheck disable=SC1090
    . "$CONFIG"
    # shellcheck disable=SC1090
    . "$COMMON"
    _duet_paste_marker "$KIMI_PANE" kimi
  )
)"
[ -z "$KIMI_MARKER" ] \
  || die "Kimi composer still owns collapsed marker $KIMI_MARKER"
message_delivered "$DUET_DIR/inbox/kimi-1" "$KIMI_TASK_ID" \
  || die "Kimi queue file did not complete"
[ ! -f "$DUET_DIR/.unhealthy" ] || die "Kimi delivery marked session unhealthy"
say "PASS Kimi collapsed marker detected, Enter submitted, marker cleared, accepted-history token present, queue complete id=$KIMI_TASK_ID elapsed=${KIMI_ELAPSED}s"

wait_until 60 "queue drain" all_messages_terminal
say "ending isolated session"
if ! run_timed 120 "$LOG_DIR/end.log" env HOME="$REAL_HOME" \
    bash "$END_SCRIPT" --session "$CONFIG"; then
  sed 's/^/[end] /' "$LOG_DIR/end.log" >&2 2>/dev/null || true
  die "duet-end failed"
fi
[ ! -f "$DUET_DIR/daemon.pid" ] || die "daemon survived end"

SUCCESS=1
TOTAL_ELAPSED=$(( $(date +%s) - STARTED_AT ))
say "PASS real Claude+Codex+Kimi M1 gate (${TOTAL_ELAPSED}s)"
exit 0
