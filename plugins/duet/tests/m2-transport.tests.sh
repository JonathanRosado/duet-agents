#!/usr/bin/env bash
# Deterministic M2 transport tests for the tmux/bash implementation.
#
# The test owns a unique tmux server and temporary state/work roots. It never
# reads or writes ~/.duet/current and it never addresses the default tmux
# server. Real agent TUIs are deliberately out of scope here.
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
SEND_SCRIPT="$SCRIPTS_DIR/duet-send.sh"
DELIVERD_SCRIPT="$SCRIPTS_DIR/duet-deliverd.sh"
END_SCRIPT="$SCRIPTS_DIR/duet-end.sh"
INIT_SCRIPT="$SCRIPTS_DIR/duet-init.sh"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)" || exit 1
TEST_ROOT="$(mktemp -d "$TMP_BASE/duet-m2-transport.XXXXXX")" || exit 1
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1
STATE_ROOT="$TEST_ROOT/state"
WORK_ROOT="$TEST_ROOT/work"
TMUX_LABEL="duet-m2-$PPID-${RANDOM:-0}"
TMUX_SESSION=transport
TMUX_SOCKET=""
TMUX_SERVER_PID=""
ACTIVE_DAEMON_PIDS=""
ACTIVE_HELPER_PIDS=""
FAILURES=0
CURRENT_CASE="setup"

mkdir -p "$STATE_ROOT" "$WORK_ROOT"

fail(){
  FAILURES=$((FAILURES + 1))
  printf '  FAIL [%s] %s\n' "$CURRENT_CASE" "$*" >&2
}

assert_eq(){
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_file(){
  [ -f "$1" ] || fail "$2: missing file $1"
}

assert_no_file(){
  [ ! -e "$1" ] || fail "$2: unexpected path $1"
}

assert_contains(){
  grep -qF "$2" "$1" 2>/dev/null || fail "$3: '$2' not found in $1"
}

assert_not_contains(){
  if grep -qF "$2" "$1" 2>/dev/null; then
    fail "$3: unexpected '$2' in $1"
  fi
}

wait_for_file(){
  local file="$1" loops="${2:-100}" i
  for i in $(seq 1 "$loops"); do
    [ -f "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_file_value(){
  local file="$1" expected="$2" loops="${3:-100}" i
  for i in $(seq 1 "$loops"); do
    [ "$(cat "$file" 2>/dev/null || true)" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_process_exit(){
  local pid="$1" loops="${2:-100}" i
  for i in $(seq 1 "$loops"); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

direct_message_count(){
  local box="$1" file count=0
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

transcript_count(){
  sed -n '/^----- .* id=/p' "$1" 2>/dev/null | awk 'END { print NR + 0 }'
}

cleanup(){
  local pid command_line
  for pid in $ACTIVE_DAEMON_PIDS; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    kill -0 "$pid" 2>/dev/null || continue
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
      *duet-deliverd.sh*"$TEST_ROOT"*|*"$DELIVERD_SCRIPT"*)
        kill -TERM "$pid" 2>/dev/null || true
        kill -CONT "$pid" 2>/dev/null || true
        ;;
    esac
  done
  for pid in $ACTIVE_HELPER_PIDS; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    kill -0 "$pid" 2>/dev/null || continue
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
      *"$TEST_ROOT"/owner-mismatch-helper.sh*|*"$TEST_ROOT"/*/duet-deliverd.sh*)
        kill -TERM "$pid" 2>/dev/null || true
        ;;
    esac
  done
  command tmux -L "$TMUX_LABEL" kill-server >/dev/null 2>&1 || true
  case "$TMUX_SOCKET" in
    */tmux-*/"$TMUX_LABEL") rm -f -- "$TMUX_SOCKET" ;;
  esac
  case "$TEST_ROOT" in
    "$TMP_BASE"/duet-m2-transport.*) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'duet test: refused unsafe cleanup path %s\n' "$TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if ! command -v tmux >/dev/null 2>&1; then
  printf 'SKIP: tmux is not installed\n'
  exit 0
fi

if ! command tmux -L "$TMUX_LABEL" -f /dev/null new-session -d \
    -s "$TMUX_SESSION" -c "$WORK_ROOT" 'exec /bin/bash --noprofile --norc'; then
  printf 'FAIL: could not start isolated tmux server\n' >&2
  exit 1
fi

INIT_PANE="$(command tmux -L "$TMUX_LABEL" display-message -p -t "$TMUX_SESSION" '#{pane_id}')"
WORKER_ONE_PANE="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" 'exec /bin/bash --noprofile --norc')"
WORKER_TWO_PANE="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" 'exec /bin/bash --noprofile --norc')"
# A live, no-echo pane lets the real daemon inspect a queued message without
# running a protocol payload as a shell command. It is used only by the daemon
# restart assertion and is never placed in later fixtures.
RESTART_PANE="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" "exec /bin/bash --noprofile --norc -c 'stty -echo; exec sleep 600'")"
INIT_PANE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p -t "$INIT_PANE" '#{pane_pid}')"
WORKER_ONE_PANE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p -t "$WORKER_ONE_PANE" '#{pane_pid}')"
WORKER_TWO_PANE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p -t "$WORKER_TWO_PANE" '#{pane_pid}')"
RESTART_PANE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p -t "$RESTART_PANE" '#{pane_pid}')"
TMUX_SOCKET="$(command tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(command tmux -L "$TMUX_LABEL" display-message -p '#{pid}')"

# shellcheck disable=SC1091
. "$SCRIPTS_DIR/duet-common.sh"

create_state(){
  local name="$1" queue env_tmp workdir_active
  DUET_DIR="$STATE_ROOT/$name"
  DUET_SESSION_ID="$name"
  DUET_SESSION="$name"
  DUET_STATE_ROOT="$STATE_ROOT"
  WORKDIR="$WORK_ROOT/$name"
  DUET_TMUX_SOCKET="$TMUX_SOCKET"
  DUET_TMUX_SERVER_PID="$TMUX_SERVER_PID"
  mkdir -p "$DUET_DIR" "$WORKDIR" "$DUET_STATE_ROOT/workdirs"
  DUET_WORKDIR_KEY="$(duet_workdir_key "$WORKDIR")"
  workdir_active="$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.active"
  printf '%s\n' "$DUET_DIR" > "$workdir_active"
  for queue in claude codex-1 kimi-1 leader promotions; do
    mkdir -p "$DUET_DIR/inbox/$queue/delivered" \
      "$DUET_DIR/inbox/$queue/failed" \
      "$DUET_DIR/inbox/$queue/quarantine" \
      "$DUET_DIR/inbox/$queue/superseded"
  done
  : > "$DUET_DIR/transcript.md"
  printf 'term\t0\nleader\tclaude\n' > "$DUET_DIR/leader"
  {
    printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n'
    printf 'claude\tclaude\t%s\t%s\t0\t0\n' "$INIT_PANE" "$INIT_PANE_PID"
    printf 'codex-1\tcodex\t%s\t%s\t1\t1\n' "$WORKER_ONE_PANE" "$WORKER_ONE_PANE_PID"
    printf 'kimi-1\tkimi\t%s\t%s\t2\t1\n' "$WORKER_TWO_PANE" "$WORKER_TWO_PANE_PID"
  } > "$DUET_DIR/roster.tsv"
  env_tmp="$DUET_DIR/duet.env"
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
    printf 'DUET_INITIATOR=%q\n' claude
    printf 'DUET_INITIATOR_PANE=%q\n' "$INIT_PANE"
  } > "$env_tmp"
  ln -sfn "$DUET_DIR" "$DUET_STATE_ROOT/current"
  CURRENT_CONFIG="$env_tmp"
  export DUET_DIR DUET_SESSION DUET_SESSION_ID DUET_WORKDIR_KEY
  export DUET_STATE_ROOT WORKDIR PLUGIN_DIR
  export DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
}

start_actual_daemon(){
  local retry_base="${1:-30}" i
  DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
    DUET_DELIVERY_RETRY_BASE="$retry_base" \
    DUET_DELIVERY_POLL_INTERVAL=0.05 \
    bash "$DELIVERD_SCRIPT" --session "$CURRENT_CONFIG" \
    --session-id "$DUET_SESSION_ID" \
    > "$DUET_DIR/daemon.stdout" 2>&1 &
  STARTED_DAEMON_LAUNCH_PID=$!
  ACTIVE_DAEMON_PIDS="$ACTIVE_DAEMON_PIDS $STARTED_DAEMON_LAUNCH_PID"
  STARTED_DAEMON_PID=""
  for i in $(seq 1 100); do
    if duet_daemon_alive; then
      STARTED_DAEMON_PID="$(cat "$DUET_DIR/daemon.pid" 2>/dev/null || true)"
      [ -n "$STARTED_DAEMON_PID" ] && break
    fi
    kill -0 "$STARTED_DAEMON_LAUNCH_PID" 2>/dev/null || break
    sleep 0.05
  done
  if [ -z "$STARTED_DAEMON_PID" ]; then
    printf '  daemon stdout:\n' >&2
    sed 's/^/    /' "$DUET_DIR/daemon.stdout" >&2 2>/dev/null || true
    printf '  daemon log:\n' >&2
    sed 's/^/    /' "$DUET_DIR/deliverd.log" >&2 2>/dev/null || true
  fi
  [ -n "$STARTED_DAEMON_PID" ]
}

stop_actual_daemon(){
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
  wait_for_process_exit "$pid" 100 || return 1
  wait "$pid" 2>/dev/null || true
  return 0
}

run_case(){
  local label="$1" fn="$2" before
  CURRENT_CASE="$label"
  before=$FAILURES
  printf 'TEST %s\n' "$label"
  "$fn"
  if [ "$FAILURES" -eq "$before" ]; then
    printf '  PASS\n'
  fi
}

run_fixture_init(){
  local workdir="$1" state_root="$2" fixture_path="$3"
  (
    cd "$workdir" || exit 1
    env -u DUET_CONFIG -u DUET_SESSION -u DUET_SESSION_ID -u DUET_DIR \
      -u DUET_WORKDIR_KEY -u WORKDIR -u PLUGIN_DIR \
      -u CODEX_PANE -u CODEX_PANE_PID \
      PATH="$fixture_path" HOME="$TEST_ROOT/init-home" \
      TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$INIT_PANE" \
      DUET_STATE_ROOT="$state_root" DUET_CODEX_SKIP_PRETRUST=1 \
      DUET_TEST_REAL_TMUX="${DUET_TEST_REAL_TMUX:-}" \
      DUET_TEST_REAL_LN="${DUET_TEST_REAL_LN:-}" \
      DUET_TEST_CURRENT_LINK="${DUET_TEST_CURRENT_LINK:-}" \
      DUET_TEST_INIT_PANE="${DUET_TEST_INIT_PANE:-}" \
      DUET_TEST_PID_MARKER="${DUET_TEST_PID_MARKER:-}" \
      BASH_ENV="${DUET_TEST_BASH_ENV:-}" \
      DUET_BOOT_TIMEOUT=2 DUET_READY_TIMEOUT=2 \
      bash "$INIT_SCRIPT" codex
  )
}

test_concurrent_enqueue_identity_restart(){
  local box output_dir pids="" pid i rc file sequence expected_id actual_id
  local expected_body_with_sentinel expected_body first index
  local message_ids transcript_ids seen expected_seen before_count restart_id roster_tmp

  create_state enqueue
  box="$DUET_DIR/inbox/leader"
  output_dir="$TEST_ROOT/enqueue-output"
  mkdir -p "$output_dir"
  if ! start_actual_daemon 30; then
    fail "actual daemon did not start"
    return
  fi
  kill -STOP "$STARTED_DAEMON_PID" 2>/dev/null || {
    fail "could not stop daemon $STARTED_DAEMON_PID"
    return
  }

  for i in $(seq 1 64); do
    (
      unset TMUX TMUX_PANE DUET_SELF
      export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT
      export DUET_ALLOW_FROM_OVERRIDE=1
      printf 'producer=%03d\nline two\tTAB\ntrailing newline\n' "$i" \
        | bash "$SEND_SCRIPT" leader --from codex-1
    ) > "$output_dir/$i.out" 2> "$output_dir/$i.err" &
    pids="$pids $!:$i"
  done
  for pid in $pids; do
    index="${pid#*:}"
    pid="${pid%%:*}"
    if ! wait "$pid"; then
      fail "concurrent enqueue process $pid (producer $index) failed"
      sed 's/^/    child: /' "$output_dir/$index.err" >&2 2>/dev/null || true
    fi
  done

  assert_eq 64 "$(direct_message_count "$box")" "direct message count"
  assert_eq 64 "$(cat "$box/.counter" 2>/dev/null || true)" "persistent counter"
  assert_eq 64 "$(transcript_count "$DUET_DIR/transcript.md")" "transcript entry count"
  assert_no_file "$box/.enqueue.lock" "enqueue lock cleanup"
  assert_no_file "$DUET_DIR/.transcript.lock" "transcript lock cleanup"
  assert_no_file "$DUET_DIR/.admission.lock" "admission lock cleanup"

  message_ids="$TEST_ROOT/message-ids"
  transcript_ids="$TEST_ROOT/transcript-ids"
  seen="$TEST_ROOT/seen-producers"
  expected_seen="$TEST_ROOT/expected-producers"
  : > "$message_ids"
  : > "$seen"
  : > "$expected_seen"
  sequence=1
  for file in "$box"/N-*.msg; do
    [ -f "$file" ] || continue
    printf -v expected_id 'm-enqueue-leader-%010d' "$sequence"
    actual_id="$(awk -F '\t' '$1 == "id" { print $2; exit }' "$file")"
    assert_eq "$expected_id" "$actual_id" "message ID at sequence $sequence"
    printf '%s\n' "$actual_id" >> "$message_ids"
    if ! duet_read_message "$file"; then
      fail "could not decode $file"
      sequence=$((sequence + 1))
      continue
    fi
    first="${DUET_MESSAGE_BODY%%$'\n'*}"
    index="${first#producer=}"
    expected_body_with_sentinel="$(printf 'producer=%s\nline two\tTAB\ntrailing newline\n.' "$index")"
    expected_body="${expected_body_with_sentinel%.}"
    assert_eq "$expected_body" "$DUET_MESSAGE_BODY" "body fidelity for producer $index"
    printf '%s\n' "$index" >> "$seen"
    sequence=$((sequence + 1))
  done
  for i in $(seq 1 64); do printf '%03d\n' "$i" >> "$expected_seen"; done
  sort "$seen" > "$seen.sorted"
  if ! cmp -s "$expected_seen" "$seen.sorted"; then
    fail "producer bodies were lost or duplicated"
  fi
  sed -n 's/^----- .* id=\([^ ]*\) .*/\1/p' "$DUET_DIR/transcript.md" > "$transcript_ids"
  if ! cmp -s "$message_ids" "$transcript_ids"; then
    fail "transcript order does not match queue sequence order"
  fi

  before_count="$(transcript_count "$DUET_DIR/transcript.md")"
  (
    unset TMUX TMUX_PANE DUET_SELF DUET_ALLOW_FROM_OVERRIDE
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT
    printf 'unresolved\n' | bash "$SEND_SCRIPT" leader
  ) > "$output_dir/unresolved.out" 2>&1
  rc=$?
  assert_eq 7 "$rc" "unresolved sender rejection"

  printf 'mismatch self\n' | DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
    DUET_STATE_ROOT="$DUET_STATE_ROOT" TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" \
    TMUX_PANE="$INIT_PANE" DUET_SELF=codex-1 \
    bash "$SEND_SCRIPT" codex-1 > "$output_dir/self-mismatch.out" 2>&1
  rc=$?
  assert_eq 7 "$rc" "TMUX_PANE and DUET_SELF mismatch rejection"

  printf 'mismatch from\n' | DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
    DUET_STATE_ROOT="$DUET_STATE_ROOT" TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" \
    TMUX_PANE="$INIT_PANE" DUET_SELF=claude \
    bash "$SEND_SCRIPT" leader --from codex-1 > "$output_dir/from-mismatch.out" 2>&1
  rc=$?
  assert_eq 7 "$rc" "known pane and --from mismatch rejection"

  (
    unset TMUX TMUX_PANE DUET_SELF
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT DUET_ALLOW_FROM_OVERRIDE=1
    printf 'hub violation\n' | bash "$SEND_SCRIPT" kimi-1 --from codex-1
  ) > "$output_dir/hub.out" 2>&1
  rc=$?
  assert_eq 8 "$rc" "worker-to-worker hub rejection"
  assert_eq "$before_count" "$(transcript_count "$DUET_DIR/transcript.md")" \
    "rejected sends do not append transcript"
  assert_eq 64 "$(cat "$box/.counter")" "rejected sends do not advance counter"

  (
    unset TMUX TMUX_PANE DUET_SELF
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT DUET_ALLOW_FROM_OVERRIDE=1
    printf 'sequence sixty-five\n' | bash "$SEND_SCRIPT" claude --from codex-1
  ) > "$output_dir/valid.out" 2>&1
  rc=$?
  assert_eq 0 "$rc" "authorized worker-to-leader send"
  assert_eq 65 "$(cat "$box/.counter")" "counter persists after concurrent writers"
  assert_file "$box/N-0000000065.msg" "65th message"
  assert_contains "$box/N-0000000065.msg" $'recipient\tleader' \
    "concrete leader target remains symbolic"

  restart_id="$(awk -F '\t' '$1 == "id" { print $2; exit }' "$box/N-0000000001.msg")"
  if ! stop_actual_daemon "$STARTED_DAEMON_PID"; then
    fail "stopped daemon did not exit"
    return
  fi
  assert_no_file "$DUET_DIR/daemon.pid" "daemon pid cleanup"
  assert_no_file "$DUET_DIR/.daemon.lock" "daemon singleton lock cleanup"

  # Give the leader a live no-echo pane. The restarted daemon must inspect the
  # pending head and persist the uncertain-submit fence without executing a
  # protocol payload in a Bash fixture or triggering failover.
  roster_tmp="$DUET_DIR/.roster.test"
  awk -F '\t' -v pane="$RESTART_PANE" -v pid="$RESTART_PANE_PID" \
    'BEGIN { OFS="\t" } $1 == "claude" { $3=pane; $4=pid } { print }' \
    "$DUET_DIR/roster.tsv" > "$roster_tmp"
  mv "$roster_tmp" "$DUET_DIR/roster.tsv"
  if ! start_actual_daemon 30; then
    fail "actual daemon did not restart"
    return
  fi
  if ! wait_for_file_value "$box/N-0000000001.msg.phase" ENTER_ONLY 120; then
    fail "restarted daemon did not finish inspecting pending head"
  fi
  assert_eq ENTER_ONLY "$(cat "$box/N-0000000001.msg.phase" 2>/dev/null || true)" \
    "restart preserves uncertain-submit phase"
  assert_eq 65 "$(direct_message_count "$box")" "pending queue survives daemon restart"
  assert_eq "$restart_id" \
    "$(awk -F '\t' '$1 == "id" { print $2; exit }' "$box/N-0000000001.msg")" \
    "stable ID survives daemon restart"
  if ! stop_actual_daemon "$STARTED_DAEMON_PID"; then
    fail "restarted daemon did not stop"
  fi
}

# Source the daemon functions without starting its main loop, then replace only
# the pane-verification boundary. Queue parsing, scheduling, sidecars, terminal
# moves, and transcript/enqueue locks remain production code.
# shellcheck disable=SC1090
. "$DELIVERD_SCRIPT"

FAKE_LOG=""
FAKE_CODEX_RC=0
FAKE_KIMI_RC=0
FAKE_INTERRUPT_RC=0
FAKE_ENTER_RC=0

duet_daemon_alive(){ return 0; }

duet_send_verified(){
  local rc
  printf 'FULL\t%s\t%s\t%s\n' "$DUET_MESSAGE_ID" "$DUET_TARGET_NAME" \
    "$DUET_MESSAGE_MODE" >> "$FAKE_LOG"
  if [ "$DUET_MESSAGE_MODE" = INTERRUPT ]; then
    rc=$FAKE_INTERRUPT_RC
  elif [ "$DUET_TARGET_NAME" = codex-1 ]; then
    rc=$FAKE_CODEX_RC
  else
    rc=$FAKE_KIMI_RC
  fi
  return "$rc"
}

duet_send_enter_only(){
  printf 'ENTER\t%s\t%s\t%s\n' "$DUET_MESSAGE_ID" "$DUET_TARGET_NAME" \
    "$DUET_MESSAGE_MODE" >> "$FAKE_LOG"
  return "$FAKE_ENTER_RC"
}

unit_enqueue(){
  local queue="$1" mode="$2" body="$3"
  duet_enqueue_message "$queue" claude "$queue" 0 "$mode" LEADER claude "$body"
  UNIT_ID="$DUET_ENQUEUED_ID"
  UNIT_FILE="$DUET_ENQUEUED_FILE"
}

test_fairness_fifo(){
  local codex_box kimi_box c1 c2 k1 k2
  create_state fairness
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  DUET_DELIVERY_MAX_ATTEMPTS=5
  FAKE_CODEX_RC=$DUET_SEND_NOT_LANDED
  FAKE_KIMI_RC=0
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=0
  codex_box="$DUET_DIR/inbox/codex-1"
  kimi_box="$DUET_DIR/inbox/kimi-1"

  unit_enqueue codex-1 NORMAL codex-one; c1="$UNIT_FILE"
  unit_enqueue codex-1 NORMAL codex-two; c2="$UNIT_FILE"
  unit_enqueue kimi-1 NORMAL kimi-one; k1="$UNIT_FILE"
  unit_enqueue kimi-1 NORMAL kimi-two; k2="$UNIT_FILE"

  duet_deliverd_pass || fail "first fair scheduler pass failed"
  assert_eq 1 "$(cat "$c1.tries" 2>/dev/null || true)" "failed head advanced once"
  assert_no_file "$c2.tries" "second Codex message remains behind failed head"
  assert_file "$kimi_box/delivered/$(basename "$k1")" "first Kimi delivery"
  assert_file "$k2" "second Kimi message advances at most once per pass"

  duet_deliverd_pass || fail "second fair scheduler pass failed"
  assert_eq 2 "$(cat "$c1.tries" 2>/dev/null || true)" "failed head advanced once again"
  assert_no_file "$c2.tries" "second Codex message is still FIFO-blocked"
  assert_file "$kimi_box/delivered/$(basename "$k2")" \
    "independent Kimi queue advances despite Codex failure"

  FAKE_CODEX_RC=0
  duet_deliverd_pass || fail "Codex head recovery pass failed"
  assert_file "$codex_box/delivered/$(basename "$c1")" "Codex head eventually delivered"
  assert_file "$c2" "Codex second message waits for next pass"
  duet_deliverd_pass || fail "Codex second FIFO pass failed"
  assert_file "$codex_box/delivered/$(basename "$c2")" "Codex FIFO successor delivered"
}

test_interrupt_supersede(){
  local box n1 i2 i3 n4
  create_state interrupt
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  DUET_DELIVERY_MAX_ATTEMPTS=5
  FAKE_CODEX_RC=$DUET_SEND_NOT_LANDED
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=0
  box="$DUET_DIR/inbox/codex-1"

  unit_enqueue codex-1 NORMAL stale-normal; n1="$UNIT_FILE"
  duet_process_one "$box" || fail "failed-head setup pass failed"
  unit_enqueue codex-1 INTERRUPT redirect-one; i2="$UNIT_FILE"
  unit_enqueue codex-1 INTERRUPT redirect-newest; i3="$UNIT_FILE"
  unit_enqueue codex-1 NORMAL post-redirect; n4="$UNIT_FILE"

  duet_process_one "$box" || fail "interrupt delivery pass failed"
  assert_file "$box/delivered/$(basename "$i3")" "newest interrupt wins"
  assert_file "$box/superseded/$(basename "$n1")" "failed normal superseded"
  assert_file "$box/superseded/$(basename "$i2")" "older interrupt superseded"
  assert_file "$n4" "newer normal is not superseded"

  FAKE_CODEX_RC=0
  duet_process_one "$box" || fail "post-interrupt normal pass failed"
  assert_file "$box/delivered/$(basename "$n4")" "post-interrupt normal delivered"
}

test_interrupt_restart_reconcile(){
  local box stale interrupt terminal newer full_ids
  create_state interrupt-reconcile
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=0
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=0
  box="$DUET_DIR/inbox/codex-1"

  unit_enqueue codex-1 NORMAL stale-before-terminal-interrupt; stale="$UNIT_FILE"
  unit_enqueue codex-1 INTERRUPT already-terminal-interrupt; interrupt="$UNIT_FILE"
  duet_move_terminal "$interrupt" delivered || fail "could not stage terminal interrupt"
  terminal="$DUET_TERMINAL_FILE"
  unit_enqueue codex-1 NORMAL newer-after-terminal-interrupt; newer="$UNIT_FILE"
  assert_no_file "$terminal.supersede_done" "crash-stage interrupt has no completion sidecar"

  duet_deliverd_pass || fail "interrupt restart reconciliation pass failed"
  assert_file "$box/superseded/$(basename "$stale")" \
    "terminal interrupt reconciles lower active root"
  assert_file "$terminal.supersede_done" "terminal interrupt records reconciliation completion"
  assert_file "$box/delivered/$(basename "$newer")" \
    "newer root delivers only after supersede reconciliation"
  full_ids="$(awk -F '\t' '$1 == "FULL" { print $2 }' "$FAKE_LOG")"
  assert_eq "$(awk -F '\t' '$1 == "id" { print $2; exit }' \
    "$box/delivered/$(basename "$newer")")" "$full_ids" \
    "stale lower root is never injected during restart reconciliation"
}

test_failure_notice_dedupe(){
  local location box original failed original_id notice notice_id terminal
  local before_counter before_transcript noticed
  for location in root terminal; do
    create_state "notice-dedupe-$location"
    FAKE_LOG="$DUET_DIR/fake.log"
    : > "$FAKE_LOG"
    box="$DUET_DIR/inbox/leader"

    unit_enqueue codex-1 NORMAL failed-worker-message; original="$UNIT_FILE"
    original_id="$UNIT_ID"
    duet_move_terminal "$original" failed || fail "could not stage failed worker message"
    failed="$DUET_TERMINAL_FILE"
    if ! duet_enqueue_message leader duet-system leader 0 NORMAL SYSTEM claude \
        existing-failure-notice "failure-$original_id"; then
      fail "could not stage existing $location failure notice"
      continue
    fi
    notice="$DUET_ENQUEUED_FILE"
    notice_id="$DUET_ENQUEUED_ID"
    if [ "$location" = terminal ]; then
      duet_move_terminal "$notice" delivered || fail "could not terminalize existing notice"
      terminal="$DUET_TERMINAL_FILE"
      notice="$terminal"
    fi
    before_counter="$(cat "$box/.counter")"
    before_transcript="$(transcript_count "$DUET_DIR/transcript.md")"

    duet_reconcile_failure_notices || fail "$location notice reconciliation failed"
    noticed="$(cat "$failed.noticed" 2>/dev/null || true)"
    assert_eq "$notice_id" "$noticed" "$location notice ID reused"
    assert_eq "$before_counter" "$(cat "$box/.counter")" \
      "$location notice dedupe does not advance counter"
    assert_eq "$before_transcript" "$(transcript_count "$DUET_DIR/transcript.md")" \
      "$location notice dedupe does not append transcript"
    assert_file "$notice" "$location existing notice remains canonical"

    duet_reconcile_failure_notices || fail "$location second reconciliation failed"
    assert_eq "$before_counter" "$(cat "$box/.counter")" \
      "$location notice reconciliation is repeat-safe"
  done
}

test_malformed_body_rejected(){
  local box message staged full_count
  create_state malformed-body
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=0
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=0
  box="$DUET_DIR/inbox/codex-1"

  unit_enqueue codex-1 NORMAL valid-before-corruption; message="$UNIT_FILE"
  staged="$box/.malformed.test"
  awk -F '\t' 'BEGIN { OFS="\t" } $1 == "body64" { $2="%%%not-base64%%%" } { print }' \
    "$message" > "$staged"
  mv "$staged" "$message"

  duet_process_one "$box" || fail "malformed message rejection pass failed"
  assert_file "$box/failed/$(basename "$message")" \
    "malformed body is archived as invalid"
  assert_file "$box/failed/$(basename "$message").noticed" \
    "malformed immutable message has no notice obligation"
  assert_eq invalid-message \
    "$(cat "$box/failed/$(basename "$message").noticed" 2>/dev/null || true)" \
    "malformed immutable message terminal reason"
  assert_no_file "$box/delivered/$(basename "$message")" \
    "malformed body is never delivered"
  full_count="$(awk -F '\t' '$1 == "FULL" { n++ } END { print n + 0 }' "$FAKE_LOG")"
  assert_eq 0 "$full_count" "malformed body never reaches pane verifier"
}

test_strict_message_parser(){
  local parser_dir message body body64 invalid64 variant
  create_state strict-parser
  parser_dir="$DUET_DIR/parser-fixtures"
  mkdir -p "$parser_dir"
  message="$parser_dir/valid.msg"
  body="$(printf 'h\303\251llo \342\230\203\nline two\tpunctuation !?')"
  body64="$(printf '%s' "$body" | base64 | tr -d '\r\n')"
  {
    printf 'DUETv1\n'
    printf 'id\tm-strict-codex-1-0000000001\n'
    printf 'session\tstrict-parser\n'
    printf 'order\t0000000001\n'
    printf 'mode\tNORMAL\n'
    printf 'sender\tclaude\n'
    printf 'recipient\tcodex-1\n'
    printf 'term\t0\n'
    printf 'origin\tLEADER\n'
    printf 'leader_at_send\tclaude\n'
    printf 'dedupe\t\n'
    printf 'body64\t%s\n' "$body64"
  } > "$message"

  if ! duet_read_message "$message"; then
    fail "valid strict DUETv1 envelope was rejected"
  else
    assert_eq m-strict-codex-1-0000000001 "$DUET_MESSAGE_ID" \
      "valid envelope ID"
    assert_eq "$body" "$DUET_MESSAGE_BODY" \
      "valid UTF-8 multiline body survives strict parsing"
  fi

  variant="$parser_dir/valid-crlf.msg"
  LC_ALL=C awk '{ printf "%s\r\n", $0 }' "$message" > "$variant"
  if ! duet_read_message "$variant"; then
    fail "valid CRLF-framed DUETv1 envelope was rejected"
  else
    assert_eq "$body" "$DUET_MESSAGE_BODY" "CRLF framing preserves the body"
  fi

  variant="$parser_dir/valid-empty-body.msg"
  LC_ALL=C awk -F '\t' 'BEGIN { OFS="\t" } $1 == "body64" { $2="" } { print }' \
    "$message" > "$variant"
  if ! duet_read_message "$variant"; then
    fail "present empty body64 field was treated as missing"
  else
    assert_eq "" "$DUET_MESSAGE_BODY" "present empty body parses as empty"
  fi

  variant="$parser_dir/duplicate.msg"
  LC_ALL=C awk 'NR == 3 { print "id\tm-conflicting-id" } { print }' \
    "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "duplicate known envelope field was accepted"
  fi

  variant="$parser_dir/unknown.msg"
  LC_ALL=C awk 'NR == 3 { print "bogus\tvalue" } { print }' \
    "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "unknown envelope field was accepted"
  fi

  variant="$parser_dir/missing-required.msg"
  LC_ALL=C awk -F '\t' '$1 != "dedupe" { print }' "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "missing required dedupe field was accepted"
  fi

  variant="$parser_dir/control-metadata.msg"
  LC_ALL=C awk -F '\t' '
    $1 == "dedupe" { printf "dedupe\tsafe%cunsafe\n", 7; next }
    { print }
  ' "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "ASCII control character in metadata was accepted"
  fi

  variant="$parser_dir/invalid-identity.msg"
  LC_ALL=C awk -F '\t' 'BEGIN { OFS="\t" }
    $1 == "recipient" { $2="../codex-1" }
    { print }
  ' "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "path-like identity metadata was accepted"
  fi

  variant="$parser_dir/oversized-order.msg"
  LC_ALL=C awk -F '\t' 'BEGIN { OFS="\t" }
    $1 == "order" { $2="10000000000" }
    { print }
  ' "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "oversized message order was accepted"
  fi

  variant="$parser_dir/noncanonical-term.msg"
  LC_ALL=C awk -F '\t' 'BEGIN { OFS="\t" }
    $1 == "term" { $2="01" }
    { print }
  ' "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "noncanonical message term was accepted"
  fi

  variant="$parser_dir/partial-manual-fields.msg"
  LC_ALL=C awk -F '\t' '$1 == "body64" { print "handoff_mode\t" } { print }' \
    "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "present-but-empty partial manual handoff metadata was accepted"
  fi

  invalid64="$(printf '\377\376\377' | base64 | tr -d '\r\n')"
  variant="$parser_dir/invalid-utf8.msg"
  LC_ALL=C awk -F '\t' -v invalid64="$invalid64" 'BEGIN { OFS="\t" }
    $1 == "body64" { $2=invalid64 }
    { print }
  ' "$message" > "$variant"
  if duet_read_message "$variant"; then
    fail "invalid UTF-8 body bytes were accepted"
  fi
}

test_nul_payload_and_state_fences(){
  local box source variant staged nul_body64 seed seed_id replacement
  create_state nul-payload-state-fences
  box="$DUET_DIR/inbox/codex-1"
  mkdir -p "$DUET_DIR/nul-fixtures"

  unit_enqueue codex-1 NORMAL valid-source-envelope
  source="$UNIT_FILE"

  variant="$DUET_DIR/nul-fixtures/raw-metadata-nul.msg"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      dedupe$'\t'*) printf 'dedupe\tsafe\000hidden\n' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$source" > "$variant"
  if duet_read_message "$variant"; then
    fail "raw NUL byte in envelope metadata was accepted"
  fi

  nul_body64="$(printf 'A\000B' | base64 | tr -d '\r\n')"
  variant="$DUET_DIR/nul-fixtures/decoded-body-nul.msg"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      body64$'\t'*) printf 'body64\t%s\n' "$nul_body64" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$source" > "$variant"
  if duet_read_message "$variant"; then
    fail "decoded body64 containing A-NUL-B was accepted"
  fi

  printf 'term\t0\nleader\tclaude\000shadow\n' > "$DUET_DIR/leader"
  if duet_read_leader_state > /dev/null 2>&1; then
    fail "NUL-tainted leader state was accepted"
  fi
  printf 'term\t0\nleader\tclaude\n' > "$DUET_DIR/leader"

  if ! duet_enqueue_message codex-1 claude codex-1 0 NORMAL LEADER claude \
      nul-dedupe-seed nul-dedupe-key; then
    fail "could not create NUL-dedupe seed message"
    return
  fi
  seed="$DUET_ENQUEUED_FILE"
  seed_id="$DUET_ENQUEUED_ID"
  staged="$box/.nul-dedupe.test"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      dedupe$'\t'nul-dedupe-key) printf 'dedupe\tnul-dedupe-key\000\n' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$seed" > "$staged"
  mv "$staged" "$seed"
  if duet_find_dedupe_message "$box" nul-dedupe-key; then
    fail "NUL-tainted envelope was trusted as a dedupe capability"
  fi
  if ! duet_enqueue_message codex-1 claude codex-1 0 NORMAL LEADER claude \
      replacement-after-nul-dedupe nul-dedupe-key; then
    fail "NUL-tainted dedupe record blocked a replacement enqueue"
    return
  fi
  replacement="$DUET_ENQUEUED_FILE"
  [ "$DUET_ENQUEUED_ID" != "$seed_id" ] \
    || fail "replacement enqueue reused the NUL-tainted message ID"
  [ "$replacement" != "$seed" ] \
    || fail "replacement enqueue resolved to the NUL-tainted message"
  if ! duet_read_message "$replacement"; then
    fail "replacement after NUL-tainted dedupe is not a valid envelope"
  else
    assert_eq nul-dedupe-key "$DUET_MESSAGE_DEDUPE" \
      "replacement publishes the requested clean dedupe key"
  fi
}

test_retry_at_numeric_fences(){
  local box message terminal marker

  create_state oversized-retry-at
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=0
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=0
  box="$DUET_DIR/inbox/codex-1"
  unit_enqueue codex-1 NORMAL oversized-retry-at-message
  message="$UNIT_FILE"
  printf '10000000000\n' > "$message.retry_at"
  DUET_MESSAGE_MODE=INTERRUPT
  duet_process_one "$box" "$message" \
    || fail "oversized retry timestamp processing failed"
  terminal="$box/quarantine/$(basename "$message")"
  assert_file "$terminal" \
    "oversized retry timestamp is terminalized instead of head-blocking"
  assert_eq invalid-delivery-retry-time \
    "$(cat "$terminal.reason" 2>/dev/null || true)" \
    "oversized retry timestamp quarantine reason"
  assert_eq 0 \
    "$(awk -F '\t' '$1 == "FULL" { n++ } END { print n + 0 }' "$FAKE_LOG")" \
    "oversized retry timestamp is rejected before a pane operation"
  assert_no_file "$terminal.supersede_done" \
    "pre-parse quarantine cannot inherit stale interrupt authority"

  create_state invalid-retry-at
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=0
  box="$DUET_DIR/inbox/codex-1"
  marker="$DUET_DIR/RETRY-AT-PWNED"
  unit_enqueue codex-1 NORMAL hostile-retry-at-message
  message="$UNIT_FILE"
  printf '%s\n' '$(touch RETRY-AT-PWNED)' > "$message.retry_at"
  (cd "$DUET_DIR" && duet_process_one "$box" "$message") \
    || fail "hostile retry timestamp processing failed"
  terminal="$box/quarantine/$(basename "$message")"
  assert_file "$terminal" \
    "invalid retry timestamp is terminalized instead of head-blocking"
  assert_eq invalid-delivery-retry-time \
    "$(cat "$terminal.reason" 2>/dev/null || true)" \
    "invalid retry timestamp quarantine reason"
  assert_eq 0 \
    "$(awk -F '\t' '$1 == "FULL" { n++ } END { print n + 0 }' "$FAKE_LOG")" \
    "invalid retry timestamp is rejected before a pane operation"
  assert_no_file "$marker" \
    "retry timestamp text is never evaluated as arithmetic or shell code"
}

test_decimal_d10_bounds(){
  local value

  for value in 0 1 42 9999999999; do
    if ! duet_decimal_d10 "$value"; then
      fail "canonical D10 value $value was rejected"
      continue
    fi
    assert_eq "$value" "$DUET_DECIMAL_VALUE" \
      "canonical D10 value $value is preserved"
  done

  if ! duet_decimal_d10 0000000000 1; then
    fail "zero-padded D10 zero was rejected"
  else
    assert_eq 0 "$DUET_DECIMAL_VALUE" "zero-padded D10 zero normalization"
  fi
  if ! duet_decimal_d10 0000000042 1; then
    fail "zero-padded D10 value was rejected"
  else
    assert_eq 42 "$DUET_DECIMAL_VALUE" "zero-padded D10 value normalization"
  fi
  if ! duet_decimal_d10 9999999999 1; then
    fail "maximum zero-padding-enabled D10 value was rejected"
  else
    assert_eq 9999999999 "$DUET_DECIMAL_VALUE" \
      "maximum zero-padding-enabled D10 value"
  fi

  for value in '' 00 01 -1 +1 1x 10000000000 '$(touch D10-PWNED)'; do
    if duet_decimal_d10 "$value"; then
      fail "invalid canonical D10 value '$value' was accepted"
    fi
    assert_eq '' "$DUET_DECIMAL_VALUE" \
      "failed D10 parse clears output for '$value'"
  done
  if duet_decimal_d10 10000000000 1; then
    fail "oversized zero-padding-enabled D10 value was accepted"
  fi
  assert_eq '' "$DUET_DECIMAL_VALUE" \
    "oversized padding-enabled D10 parse clears output"
}

test_persistent_numeric_bounds(){
  local box output rc
  create_state persistent-numeric-bounds
  box="$DUET_DIR/inbox/codex-1"
  output="$DUET_DIR/numeric.err"

  printf '9999999998\n' > "$box/.counter"
  if ! duet_next_sequence "$box"; then
    fail "queue counter could not allocate the maximum D10 sequence"
  else
    assert_eq 9999999999 "$DUET_SEQUENCE" "maximum queue sequence allocation"
    assert_eq 9999999999 "$(cat "$box/.counter")" \
      "maximum queue counter publication"
  fi
  if duet_next_sequence "$box" > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "exhausted queue counter allocated past the D10 cap"
  assert_contains "$output" 'sequence exhausted (D10 cap)' \
    "queue sequence exhaustion diagnostic"
  assert_eq 9999999999 "$(cat "$box/.counter")" \
    "exhausted queue counter remains unchanged"

  printf '10000000000\n' > "$box/.counter"
  if duet_next_sequence "$box" > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "oversized queue counter was accepted"
  assert_eq 10000000000 "$(cat "$box/.counter")" \
    "oversized queue counter is not rewritten"
  printf '0000000001\n' > "$box/.counter"
  if duet_next_sequence "$box" > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "noncanonical queue counter was accepted"
  assert_eq 0000000001 "$(cat "$box/.counter")" \
    "noncanonical queue counter is not rewritten"

  printf '9999999998\n' > "$DUET_DIR/.message-order"
  if ! duet_next_message_order; then
    fail "global order could not allocate the maximum D10 value"
  else
    assert_eq 9999999999 "$DUET_MESSAGE_ORDER_ALLOC" \
      "maximum global message-order allocation"
    assert_eq 9999999999 "$(cat "$DUET_DIR/.message-order")" \
      "maximum global message-order publication"
  fi
  if duet_next_message_order > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "global message order allocated past the D10 cap"
  assert_contains "$output" 'message-order exhausted (D10 cap)' \
    "global message-order exhaustion diagnostic"
  assert_eq 9999999999 "$(cat "$DUET_DIR/.message-order")" \
    "exhausted global message order remains unchanged"

  printf '10000000000\n' > "$DUET_DIR/.message-order"
  if duet_next_message_order > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "oversized global message order was accepted"
  assert_eq 10000000000 "$(cat "$DUET_DIR/.message-order")" \
    "oversized global message order is not rewritten"
  printf '0000000001\n' > "$DUET_DIR/.message-order"
  if duet_next_message_order > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "noncanonical global message order was accepted"
  assert_eq 0000000001 "$(cat "$DUET_DIR/.message-order")" \
    "noncanonical global message order is not rewritten"
}

test_term_numeric_bounds(){
  local box max_message before_counter before_order before_transcript output rc
  create_state term-numeric-bounds
  box="$DUET_DIR/inbox/codex-1"
  output="$DUET_DIR/term.err"

  if ! duet_write_leader_state 9999999999 claude; then
    fail "maximum D10 leader term could not be written"
  elif ! duet_read_leader_state; then
    fail "maximum D10 leader term could not be read"
  else
    assert_eq 9999999999 "$DUET_CURRENT_TERM" "maximum leader term round trip"
  fi
  if duet_promote_locked 9999999999 claude MANUAL codex-1; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "handoff advanced beyond the maximum D10 generation"
  assert_contains "$DUET_DIR/leader" $'term\t9999999999' \
    "exhausted handoff leaves the maximum leader generation unchanged"
  assert_no_file "$DUET_DIR/inbox/promotions/.counter" \
    "exhausted handoff publishes no promotion intent"
  if duet_write_leader_state 10000000000 claude; then
    fail "oversized leader term was written"
  fi
  if duet_write_leader_state 0000000001 claude; then
    fail "noncanonical leader term was written"
  fi
  assert_contains "$DUET_DIR/leader" $'term\t9999999999' \
    "invalid leader writes preserve the prior state"

  printf 'term\t10000000000\nleader\tclaude\n' > "$DUET_DIR/leader"
  if duet_read_leader_state > /dev/null 2> "$output"; then
    fail "oversized persisted leader term was accepted"
  fi
  printf 'term\t0000000001\nleader\tclaude\n' > "$DUET_DIR/leader"
  if duet_read_leader_state > /dev/null 2> "$output"; then
    fail "noncanonical persisted leader term was accepted"
  fi
  printf 'term\t0\nleader\tclaude\n' > "$DUET_DIR/leader"

  if ! duet_enqueue_message codex-1 claude codex-1 9999999999 \
      NORMAL LEADER claude maximum-term-message; then
    fail "ordinary envelope rejected maximum D10 term"
    return
  fi
  max_message="$DUET_ENQUEUED_FILE"
  assert_contains "$max_message" $'term\t9999999999' \
    "maximum envelope term publication"
  if ! duet_read_message "$max_message"; then
    fail "maximum D10 term envelope could not be parsed"
  else
    assert_eq 9999999999 "$DUET_MESSAGE_TERM" "maximum parsed envelope term"
  fi
  before_counter="$(cat "$box/.counter")"
  before_order="$(cat "$DUET_DIR/.message-order")"
  before_transcript="$(transcript_count "$DUET_DIR/transcript.md")"

  if duet_enqueue_message codex-1 claude codex-1 10000000000 \
      NORMAL LEADER claude oversized-term > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "oversized envelope term was accepted"
  if duet_enqueue_message codex-1 claude codex-1 0000000001 \
      NORMAL LEADER claude noncanonical-term > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "noncanonical envelope term was accepted"
  assert_eq "$before_counter" "$(cat "$box/.counter")" \
    "invalid envelope terms do not advance queue counter"
  assert_eq "$before_order" "$(cat "$DUET_DIR/.message-order")" \
    "invalid envelope terms do not advance global order"
  assert_eq "$before_transcript" "$(transcript_count "$DUET_DIR/transcript.md")" \
    "invalid envelope terms do not append transcript"
}

test_message_filename_numeric_fences(){
  local box valid malicious oversized marker rc
  create_state message-filename-numeric-fences
  box="$DUET_DIR/inbox/codex-1"
  marker="$DUET_DIR/FILENAME-PWNED"

  unit_enqueue codex-1 NORMAL valid-older-message
  valid="$UNIT_FILE"
  malicious="$box/N-\$(touch FILENAME-PWNED).msg"
  printf 'hostile filename fixture\n' > "$malicious"
  if ! (cd "$DUET_DIR" && duet_supersede_before "$box" 0000000002); then
    fail "interrupt supersede rejected a nonnumeric filename instead of ignoring it"
  fi
  assert_no_file "$marker" "literal command substitution in filename is inert"
  assert_file "$box/superseded/$(basename "$valid")" \
    "valid lower sequence is superseded beside hostile filename"
  assert_file "$malicious" "hostile nonnumeric filename remains for quarantine"

  oversized="$box/N-10000000000.msg"
  printf 'oversized filename fixture\n' > "$oversized"
  if duet_message_sequence "$oversized"; then rc=0; else rc=$?; fi
  assert_eq 2 "$rc" "oversized numeric filename has a fail-closed result"
  if duet_supersede_before "$box" 0000000002 > /dev/null 2>&1; then
    fail "interrupt supersede accepted an oversized numeric sequence"
  fi
  assert_no_file "$marker" "supersede scan never evaluates hostile filename text"

  DUET_MESSAGE_MODE=NORMAL
  duet_process_one "$box" "$oversized" \
    || fail "oversized numeric filename quarantine failed"
  assert_file "$box/quarantine/$(basename "$oversized")" \
    "oversized numeric filename is quarantined"
  assert_eq invalid-message-filename \
    "$(cat "$box/quarantine/$(basename "$oversized").reason" 2>/dev/null || true)" \
    "oversized numeric filename quarantine reason"

  DUET_MESSAGE_MODE=NORMAL
  duet_process_one "$box" "$malicious" \
    || fail "hostile nonnumeric filename quarantine failed"
  assert_file "$box/quarantine/$(basename "$malicious")" \
    "hostile nonnumeric filename is quarantined"
  assert_no_file "$marker" "hostile filename remains inert during quarantine"
}

test_delivery_attempt_numeric_fences(){
  local box message terminal marker

  create_state invalid-delivery-attempt-count
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=$DUET_SEND_NOT_LANDED
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=0
  box="$DUET_DIR/inbox/codex-1"
  unit_enqueue codex-1 NORMAL invalid-attempt-sidecar
  message="$UNIT_FILE"
  printf '0001\n' > "$message.tries"
  duet_process_one "$box" "$message" || fail "invalid attempt-count quarantine failed"
  terminal="$box/quarantine/$(basename "$message")"
  assert_file "$terminal" "noncanonical attempt count is quarantined"
  assert_eq invalid-delivery-attempt-count \
    "$(cat "$terminal.reason" 2>/dev/null || true)" \
    "noncanonical attempt-count quarantine reason"
  assert_eq 0 "$(grep -cE '^(FULL|ENTER)' "$FAKE_LOG" 2>/dev/null || true)" \
    "invalid attempt count is rejected before any composer operation"

  create_state oversized-delivery-attempt-count
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=$DUET_SEND_NOT_LANDED
  box="$DUET_DIR/inbox/codex-1"
  marker="$DUET_DIR/TRIES-PWNED"
  unit_enqueue codex-1 NORMAL oversized-attempt-sidecar
  message="$UNIT_FILE"
  printf '%s\n' '$(touch TRIES-PWNED)' > "$message.tries"
  (cd "$DUET_DIR" && duet_process_one "$box" "$message") \
    || fail "hostile attempt-count quarantine failed"
  terminal="$box/quarantine/$(basename "$message")"
  assert_file "$terminal" "hostile attempt count is quarantined"
  assert_eq invalid-delivery-attempt-count \
    "$(cat "$terminal.reason" 2>/dev/null || true)" \
    "hostile attempt-count quarantine reason"
  assert_no_file "$marker" "attempt-count text is never evaluated as arithmetic"
  assert_eq 0 "$(grep -cE '^(FULL|ENTER)' "$FAKE_LOG" 2>/dev/null || true)" \
    "hostile attempt count is rejected before any composer operation"

  create_state maximum-delivery-attempt-count
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_CODEX_RC=$DUET_SEND_NOT_LANDED
  box="$DUET_DIR/inbox/codex-1"
  unit_enqueue codex-1 NORMAL maximum-attempt-sidecar
  message="$UNIT_FILE"
  printf '9999999999\n' > "$message.tries"
  duet_process_one "$box" "$message" || fail "maximum attempt-count quarantine failed"
  terminal="$box/quarantine/$(basename "$message")"
  assert_file "$terminal" "maximum attempt count is quarantined"
  assert_eq delivery-attempt-count-exhausted \
    "$(cat "$terminal.reason" 2>/dev/null || true)" \
    "maximum attempt-count quarantine reason"
  assert_eq 0 "$(grep -cE '^(FULL|ENTER)' "$FAKE_LOG" 2>/dev/null || true)" \
    "exhausted attempt count is rejected before any composer operation"
}

test_terminal_counter_rollback_rejected(){
  local box first terminal before_transcript output rc
  create_state counter-rollback
  box="$DUET_DIR/inbox/codex-1"
  output="$TEST_ROOT/counter-rollback.err"

  unit_enqueue codex-1 NORMAL allocated-once; first="$UNIT_FILE"
  duet_move_terminal "$first" delivered || fail "could not stage terminal sequence"
  terminal="$DUET_TERMINAL_FILE"
  printf '0\n' > "$box/.counter"
  before_transcript="$(transcript_count "$DUET_DIR/transcript.md")"

  if duet_enqueue_message codex-1 claude codex-1 0 NORMAL LEADER claude \
      must-not-reuse > /dev/null 2> "$output"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then fail "rolled-back counter reused a terminal sequence"; fi
  assert_contains "$output" 'counter rollback would reuse sequence 0000000001' \
    "terminal sequence reuse diagnostic"
  assert_eq 0 "$(cat "$box/.counter")" "rejected rollback leaves counter unchanged"
  assert_eq 0 "$(direct_message_count "$box")" "rejected rollback publishes no active root"
  assert_file "$terminal" "original terminal sequence remains intact"
  assert_eq "$before_transcript" "$(transcript_count "$DUET_DIR/transcript.md")" \
    "rejected rollback does not append transcript"
}

test_uncertain_dead_fencing(){
  local box uncertain full_count enter_count
  create_state uncertain
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  DUET_DELIVERY_MAX_ATTEMPTS=5
  FAKE_CODEX_RC=$DUET_SEND_LANDED_UNVERIFIED
  FAKE_INTERRUPT_RC=0
  FAKE_ENTER_RC=$DUET_SEND_DEAD
  box="$DUET_DIR/inbox/codex-1"

  unit_enqueue codex-1 NORMAL uncertain-payload; uncertain="$UNIT_FILE"
  duet_process_one "$box" || fail "uncertain landing pass failed"
  assert_eq ENTER_ONLY "$(cat "$uncertain.phase" 2>/dev/null || true)" \
    "uncertain landing persists Enter-only phase"
  duet_write_sidecar "$uncertain" retry_at 0 || fail "could not make Enter-only retry due"
  duet_process_one "$box" || fail "Enter-only DEAD pass failed"
  assert_file "$box/quarantine/$(basename "$uncertain")" \
    "DEAD after uncertain landing quarantines message"
  assert_no_file "$uncertain" "uncertain message cannot return to READY"
  duet_process_one "$box" || fail "empty follow-up pass failed"
  full_count="$(awk -F '\t' '$1 == "FULL" { n++ } END { print n + 0 }' "$FAKE_LOG")"
  enter_count="$(awk -F '\t' '$1 == "ENTER" { n++ } END { print n + 0 }' "$FAKE_LOG")"
  assert_eq 1 "$full_count" "uncertain payload is pasted exactly once"
  assert_eq 1 "$enter_count" "uncertain payload receives one Enter-only continuation"
}

test_daemon_stop_owner_mismatch(){
  local helper helper_pid owner_pid output rc other_dir other_script other_pid
  create_state stop-owner-mismatch
  helper="$TEST_ROOT/owner-mismatch-helper.sh"
  output="$TEST_ROOT/owner-mismatch.err"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "trap 'exit 0' INT TERM"
    printf '%s\n' 'while :; do sleep 1; done'
  } > "$helper"
  chmod +x "$helper"
  bash "$helper" &
  helper_pid=$!
  ACTIVE_HELPER_PIDS="$ACTIVE_HELPER_PIDS $helper_pid"
  owner_pid="${BASHPID:-$$}"
  printf '%s\n' "$helper_pid" > "$DUET_DIR/daemon.pid"
  printf '%s\tforeign-owner\n' "$owner_pid" > "$DUET_DIR/.daemon.lock"

  if duet_stop_daemon "$DUET_DIR" 1 > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  assert_eq 1 "$rc" "daemon stop rejects lock-owner mismatch"
  assert_contains "$output" 'daemon.pid does not own this session' \
    "daemon owner mismatch diagnostic"
  kill -0 "$helper_pid" 2>/dev/null \
    || fail "owner-mismatched live PID was signaled"

  # Exact shutdown-publication race: daemon.pid has already become stale/dead,
  # but a different live process still owns the lifetime lock. The dead pid
  # file must not make stop report success or signal the live owner.
  printf '99999999\n' > "$DUET_DIR/daemon.pid"
  printf '%s\tlive-owner\n' "$helper_pid" > "$DUET_DIR/.daemon.lock"
  if duet_stop_daemon "$DUET_DIR" 1 > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  assert_eq 1 "$rc" "daemon stop rejects dead PID with different live owner"
  assert_contains "$output" 'daemon.pid does not own this session' \
    "dead PID and live owner mismatch diagnostic"
  kill -0 "$helper_pid" 2>/dev/null \
    || fail "live daemon-lock owner was signaled for a dead daemon.pid"

  rm -f "$DUET_DIR/daemon.pid" "$DUET_DIR/.daemon.lock"
  kill -TERM "$helper_pid" 2>/dev/null || true
  wait "$helper_pid" 2>/dev/null || true

  # A live daemon from a different state root may share this session basename.
  # The canonical --session config path is part of process identity.
  other_dir="$TEST_ROOT/other-root/$DUET_SESSION_ID"
  other_script="$TEST_ROOT/other-root/duet-deliverd.sh"
  mkdir -p "$other_dir"
  : > "$other_dir/duet.env"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "trap 'exit 0' INT TERM"
    printf '%s\n' 'while :; do sleep 1; done'
  } > "$other_script"
  chmod +x "$other_script"
  bash "$other_script" --session "$other_dir/duet.env" \
    --session-id "$DUET_SESSION_ID" &
  other_pid=$!
  ACTIVE_HELPER_PIDS="$ACTIVE_HELPER_PIDS $other_pid"
  printf '%s\n' "$other_pid" > "$DUET_DIR/daemon.pid"
  printf '%s\tforeign-root\n' "$other_pid" > "$DUET_DIR/.daemon.lock"
  if ( . "$SCRIPTS_DIR/duet-common.sh"; duet_daemon_alive ); then
    rc=0
  else
    rc=$?
  fi
  assert_eq 1 "$rc" "daemon liveness rejects same id from another config path"
  if duet_stop_daemon "$DUET_DIR" 1 > /dev/null 2> "$output"; then rc=0; else rc=$?; fi
  assert_eq 1 "$rc" "daemon stop rejects same id from another config path"
  kill -0 "$other_pid" 2>/dev/null \
    || fail "foreign-root daemon was signaled"
  rm -f "$DUET_DIR/daemon.pid" "$DUET_DIR/.daemon.lock"
  kill -TERM "$other_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
}

test_daemon_metachar_path_identity(){
  local ordinary_state_root="$STATE_ROOT" meta_root helper helper_pid decoy_pid
  local decoy_config rc output
  meta_root="$TEST_ROOT/state[*?]"
  STATE_ROOT="$meta_root"
  create_state daemon-meta
  helper="$TEST_ROOT/meta-helper/duet-deliverd.sh"
  output="$TEST_ROOT/daemon-meta.err"
  mkdir -p "$(dirname "$helper")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '[ "$1" = --session ] || exit 2'
    printf '%s\n' '[ "$3" = --session-id ] || exit 2'
    printf '%s\n' "trap 'exit 0' INT TERM"
    printf '%s\n' 'while :; do sleep 1; done'
  } > "$helper"
  chmod +x "$helper"

  # This differs from the canonical path by dropping the bracket delimiters.
  # A process-identity fence must compare the argument literally, never accept
  # it as an expansion of pattern characters in the configured state root.
  decoy_config="$TEST_ROOT/state*/daemon-meta/duet.env"
  bash "$helper" --session "$decoy_config" --session-id "$DUET_SESSION_ID" &
  decoy_pid=$!
  ACTIVE_HELPER_PIDS="$ACTIVE_HELPER_PIDS $decoy_pid"
  mkdir "$DUET_DIR/.daemon.lock"
  printf '%s\tmeta-path-decoy\n' "$decoy_pid" > "$DUET_DIR/.daemon.lock/owner"
  printf '%s\n' "$decoy_pid" > "$DUET_DIR/daemon.pid"
  if ( . "$SCRIPTS_DIR/duet-common.sh"; duet_daemon_alive ); then
    rc=0
  else
    rc=$?
  fi
  assert_eq 1 "$rc" "daemon liveness rejects a non-literal config path"
  if duet_stop_daemon "$DUET_DIR" 1 > /dev/null 2> "$output"; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 1 "$rc" "daemon stop rejects a non-literal config path"
  kill -0 "$decoy_pid" 2>/dev/null \
    || fail "config-path decoy was signaled by daemon stop"
  kill -TERM "$decoy_pid" 2>/dev/null || true
  wait "$decoy_pid" 2>/dev/null || true
  rm -f "$DUET_DIR/daemon.pid" "$DUET_DIR/.daemon.lock/owner"
  rmdir "$DUET_DIR/.daemon.lock" 2>/dev/null || true

  bash "$helper" --session "$CURRENT_CONFIG" --session-id "$DUET_SESSION_ID" &
  helper_pid=$!
  ACTIVE_HELPER_PIDS="$ACTIVE_HELPER_PIDS $helper_pid"
  mkdir "$DUET_DIR/.daemon.lock"
  printf '%s\tmeta-path\n' "$helper_pid" > "$DUET_DIR/.daemon.lock/owner"
  printf '%s\n' "$helper_pid" > "$DUET_DIR/daemon.pid"

  if ( . "$SCRIPTS_DIR/duet-common.sh"; duet_daemon_alive ); then
    rc=0
  else
    rc=$?
  fi
  assert_eq 0 "$rc" \
    "daemon liveness treats *, ?, and [ in canonical config path literally"
  if duet_stop_daemon "$DUET_DIR" 1 > /dev/null 2> "$output"; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 0 "$rc" \
    "daemon stop treats *, ?, and [ in canonical config path literally"
  if ! wait_for_process_exit "$helper_pid" 40; then
    fail "daemon under metacharacter state root was not stopped"
    kill -TERM "$helper_pid" 2>/dev/null || true
  fi
  wait "$helper_pid" 2>/dev/null || true
  STATE_ROOT="$ordinary_state_root"
}

test_stale_lock_symlink_escape(){
  local fixture lock victim atomic_target rc
  fixture="$TEST_ROOT/stale-lock-escape"
  lock="$fixture/session/.delivery.lock"
  victim="$fixture/victim.claim-outside"
  mkdir -p "$(dirname "$lock")" "$victim"
  printf '999999999\tforeign-owner\n' > "$victim/owner"
  ln -s ../victim.claim-outside "$lock"

  if duet_lock_acquire "$lock" 20; then rc=0; else rc=$?; fi
  assert_eq 0 "$rc" "stale hostile symlink is recoverable"
  assert_file "$victim/owner" "stale-lock cleanup cannot escape lock directory"
  if [ "$rc" -eq 0 ]; then
    duet_lock_release "$lock" || fail "recovered stale lock could not be released"
  fi

  atomic_target="$fixture/atomic-target"
  mkdir "$atomic_target"
  if duet_atomic_write "$atomic_target" unsafe >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_eq 1 "$rc" "atomic publication rejects a directory destination"
  [ -d "$atomic_target" ] \
    || fail "atomic publication replaced its directory destination"
  [ -z "$(find "$atomic_target" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || fail "atomic publication moved its temp file inside a directory destination"
}

test_init_path_publication_and_cleanup_fences(){
  local fake_bin fake_ln_bin fake_bash_env real_tmux real_ln state work key outside sentinel
  local output rc anchor_target anchor_body worker_pane actual_pid before_panes after_panes
  fake_bin="$TEST_ROOT/init-fake-bin"
  fake_ln_bin="$TEST_ROOT/init-fake-ln-bin"
  fake_bash_env="$fake_ln_bin/bash-env"
  real_tmux="$(command -v tmux)"
  real_ln="$(command -v ln)"
  mkdir -p "$fake_bin" "$fake_ln_bin" "$TEST_ROOT/init-home"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "printf 'OpenAI Codex\\n'"
    printf '%s\n' 'for _ in $(seq 1 100); do'
    printf '%s\n' '  if [ -f "${DUET_CONFIG:-}" ]; then'
    printf '%s\n' '    . "$DUET_CONFIG"'
    printf '%s\n' "    printf 'ok\\n' > \"\$DUET_DIR/ready/\$DUET_SELF\""
    printf '%s\n' '    break'
    printf '%s\n' '  fi'
    printf '%s\n' '  sleep 0.02'
    printf '%s\n' 'done'
    printf '%s\n' "trap 'exit 0' INT TERM"
    printf '%s\n' 'while :; do sleep 1; done'
  } > "$fake_bin/codex"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'args=("$@")'
    printf '%s\n' 'target=""; is_display=""; is_pid=""; i=0'
    printf '%s\n' 'while [ "$i" -lt "${#args[@]}" ]; do'
    printf '%s\n' '  case "${args[$i]}" in'
    printf '%s\n' '    display-message) is_display=1 ;;'
    printf '%s\n' "    '#{pane_pid}') is_pid=1 ;;"
    printf '%s\n' '    -t) i=$((i + 1)); target="${args[$i]:-}" ;;'
    printf '%s\n' '  esac'
    printf '%s\n' '  i=$((i + 1))'
    printf '%s\n' 'done'
    printf '%s\n' 'if [ "$is_display" = 1 ] && [ "$is_pid" = 1 ] \
  && [ -n "${DUET_TEST_PID_MARKER:-}" ] \
  && [ "$target" != "${DUET_TEST_INIT_PANE:-}" ]; then'
    printf '%s\n' '  if [ -f "$DUET_TEST_PID_MARKER" ]; then'
    printf '%s\n' "    printf '999999999\\n'"
    printf '%s\n' '    exit 0'
    printf '%s\n' '  fi'
    printf '%s\n' "  printf '%s\\n' \"\$target\" > \"\$DUET_TEST_PID_MARKER\""
    printf '%s\n' 'fi'
    printf '%s\n' 'exec "$DUET_TEST_REAL_TMUX" "${args[@]}"'
  } > "$fake_bin/tmux"
  {
    printf '%s\n' 'ln(){'
    printf '%s\n' '  local last=""'
    printf '%s\n' '  for last in "$@"; do :; done'
    printf '%s\n' '  if [ "$last" = "$DUET_TEST_CURRENT_LINK" ]; then return 0; fi'
    printf '%s\n' '  command "$DUET_TEST_REAL_LN" "$@"'
    printf '%s\n' '}'
  } > "$fake_bash_env"
  chmod +x "$fake_bin/codex" "$fake_bin/tmux"

  work="$TEST_ROOT/init-no-home-work"
  mkdir -p "$work"
  output="$TEST_ROOT/init-no-home.out"
  if (
    cd "$work" || exit 1
    env -u HOME -u DUET_STATE_ROOT -u DUET_CONFIG -u DUET_SESSION \
      PATH="$fake_bin:$PATH" DUET_TEST_REAL_TMUX="$real_tmux" \
      TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$INIT_PANE" \
      bash "$INIT_SCRIPT" codex
  ) > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "missing HOME and state root is rejected cleanly"
  assert_contains "$output" 'set DUET_STATE_ROOT or HOME' \
    "missing state-root fallback diagnostic"

  output="$TEST_ROOT/init-root-state.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" / "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "filesystem root cannot be the state root"
  assert_contains "$output" 'refusing to use / as DUET_STATE_ROOT' \
    "filesystem-root state diagnostic"

  state="$TEST_ROOT/init-"$'bad\tstate'
  work="$TEST_ROOT/init-control-work"
  mkdir -p "$state" "$work"
  output="$TEST_ROOT/init-control-state.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "control character in canonical state root is rejected"
  assert_contains "$output" 'DUET_STATE_ROOT contains a control character' \
    "state-root control-character diagnostic"
  assert_no_file "$state/workdirs" "invalid state root is rejected before registry creation"

  # An active record may be lexically under the state root while resolving
  # elsewhere. Neither a symlink nor a dot-dot spelling may reach duet.env.
  state="$TEST_ROOT/init-prev-state"
  work="$TEST_ROOT/init-prev-work"
  outside="$TEST_ROOT/init-prev-outside"
  sentinel="$outside/config-sourced"
  mkdir -p "$state/workdirs" "$work" "$outside"
  key="$(duet_workdir_key "$work")"
  {
    printf 'touch %q\n' "$sentinel"
    printf 'DUET_DIR=%q\n' "$outside"
    printf 'WORKDIR=%q\n' "$work"
  } > "$outside/duet.env"
  ln -s "$outside" "$state/escaped"
  printf '%s\n' "$state/escaped" > "$state/workdirs/$key.active"
  output="$TEST_ROOT/init-prev-symlink.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "symlinked predecessor escape is rejected"
  assert_no_file "$sentinel" "symlinked predecessor config is never sourced"

  printf '%s\n' "$state/../init-prev-outside" > "$state/workdirs/$key.active"
  output="$TEST_ROOT/init-prev-dotdot.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "dot-dot predecessor escape is rejected"
  assert_no_file "$sentinel" "dot-dot predecessor config is never sourced"

  mkdir -p "$state/inside"
  ln -s "$outside/duet.env" "$state/inside/duet.env"
  printf '%s\n' "$state/inside" > "$state/workdirs/$key.active"
  output="$TEST_ROOT/init-prev-config-symlink.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "symlinked predecessor config is rejected"
  assert_no_file "$sentinel" "symlinked predecessor config target is never sourced"

  state="$TEST_ROOT/init-legacy-config-state"
  mkdir -p "$state/legacy"
  ln -s "$outside/duet.env" "$state/legacy/duet.env"
  output="$TEST_ROOT/init-legacy-config-symlink.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "symlinked legacy-scan config is rejected"
  assert_no_file "$sentinel" "symlinked legacy-scan target is never sourced"

  # Refusing an instruction-file symlink must leave both the link and target
  # byte-for-byte intact, including text that resembles a duet anchor.
  state="$TEST_ROOT/init-anchor-state"
  work="$TEST_ROOT/init-anchor-work"
  anchor_target="$TEST_ROOT/init-anchor-target"
  anchor_body=$'keep\n<!-- DUET:BEGIN test -->\ndo-not-edit\n<!-- DUET:END -->'
  mkdir -p "$state" "$work"
  printf '%s' "$anchor_body" > "$anchor_target"
  ln -s "$anchor_target" "$work/AGENTS.md"
  output="$TEST_ROOT/init-anchor.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "symlinked anchor unexpectedly allowed init"
  assert_contains "$output" 'refusing symlinked anchor file' \
    "symlinked anchor refusal diagnostic"
  assert_eq "$anchor_body" "$(cat "$anchor_target")" \
    "symlinked anchor target is unchanged"
  [ -L "$work/AGENTS.md" ] || fail "symlinked AGENTS.md was replaced"

  # Make the pane PID appear changed only during failure cleanup. A real
  # current/ directory must abort publication, and cleanup must preserve the
  # pane whose current process no longer matches the PID captured at spawn.
  state="$TEST_ROOT/init-current-dir-state"
  work="$TEST_ROOT/init-current-dir-work"
  mkdir -p "$state/current" "$work"
  output="$TEST_ROOT/init-current-dir.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" \
      DUET_TEST_INIT_PANE="$INIT_PANE" \
      DUET_TEST_PID_MARKER="$TEST_ROOT/init-worker-pane" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "real current directory rejects publication"
  assert_contains "$output" 'publication path is a directory' \
    "real current directory refusal diagnostic"
  assert_eq "" "$(ls -A "$state/current" 2>/dev/null || true)" \
    "publication does not create a symlink inside current directory"
  worker_pane="$(cat "$TEST_ROOT/init-worker-pane" 2>/dev/null || true)"
  actual_pid="$(command tmux -L "$TMUX_LABEL" display-message -p \
    -t "$worker_pane" '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$actual_pid" ] || fail "PID-mismatched init worker was killed during cleanup"
  [ -z "$worker_pane" ] \
    || command tmux -L "$TMUX_LABEL" kill-pane -t "$worker_pane" 2>/dev/null || true

  # A successful ln(1) status is insufficient: publication is complete only
  # when readlink reports the exact session directory.
  state="$TEST_ROOT/init-readlink-state"
  work="$TEST_ROOT/init-readlink-work"
  mkdir -p "$state" "$work"
  state="$(cd "$state" && pwd -P)"
  before_panes="$(command tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
  output="$TEST_ROOT/init-readlink.out"
  if DUET_TEST_REAL_TMUX="$real_tmux" DUET_TEST_REAL_LN="$real_ln" \
      DUET_TEST_CURRENT_LINK="$state/current" \
      DUET_TEST_BASH_ENV="$fake_bash_env" \
      run_fixture_init "$work" "$state" "$fake_bin:$PATH" \
      > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 7 "$rc" "unverified current publication is rejected"
  assert_contains "$output" 'could not publish the current-session convenience link' \
    "unverified publication diagnostic"
  assert_no_file "$state/current" "unverified current link is not accepted"
  after_panes="$(command tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
  assert_eq "$before_panes" "$after_panes" \
    "PID-matched init worker is removed after publication failure"
}

test_end_legacy_pane_pid_fences(){
  local configured_pane configured_pid ambient_pane ambient_pid output rc actual_pid

  configured_pane="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
    -t "$TMUX_SESSION" 'exec sleep 600')"
  configured_pid="$(command tmux -L "$TMUX_LABEL" display-message -p \
    -t "$configured_pane" '#{pane_pid}')"
  create_state legacy-configured-pane
  rm -f "$DUET_DIR/roster.tsv"
  : > "$DUET_DIR/.ended"
  {
    printf 'CODEX_PANE=%q\n' "$configured_pane"
    printf 'CODEX_PANE_PID=%q\n' "$configured_pid"
  } >> "$CURRENT_CONFIG"
  output="$TEST_ROOT/end-legacy-configured.out"
  if DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
      TMUX_PANE="$INIT_PANE" bash "$END_SCRIPT" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 0 "$rc" "config-pinned legacy teardown succeeds"
  actual_pid="$(command tmux -L "$TMUX_LABEL" display-message -p \
    -t "$configured_pane" '#{pane_pid}' 2>/dev/null || true)"
  assert_eq "" "$actual_pid" "config-pinned legacy pane and PID are reaped"

  ambient_pane="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
    -t "$TMUX_SESSION" 'exec sleep 600')"
  ambient_pid="$(command tmux -L "$TMUX_LABEL" display-message -p \
    -t "$ambient_pane" '#{pane_pid}')"
  create_state legacy-ambient-pane
  rm -f "$DUET_DIR/roster.tsv"
  : > "$DUET_DIR/.ended"
  output="$TEST_ROOT/end-legacy-ambient.out"
  if DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
      CODEX_PANE="$ambient_pane" CODEX_PANE_PID="$ambient_pid" \
      TMUX_PANE="$INIT_PANE" bash "$END_SCRIPT" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 0 "$rc" "legacy teardown ignores inherited pane identity"
  actual_pid="$(command tmux -L "$TMUX_LABEL" display-message -p \
    -t "$ambient_pane" '#{pane_pid}' 2>/dev/null || true)"
  assert_eq "$ambient_pid" "$actual_pid" \
    "inherited CODEX_PANE and CODEX_PANE_PID cannot select a victim"
  command tmux -L "$TMUX_LABEL" kill-pane -t "$ambient_pane" 2>/dev/null || true
}

test_already_ended_finalization(){
  local output_dir roster_tmp first_rc second_rc alive_panes stale_worker_pid actual_pid
  create_state already-ended
  output_dir="$TEST_ROOT/already-ended-output"
  mkdir -p "$output_dir"

  # Preserve the shared fixture panes for the subsequent drain test. One row
  # deliberately retains spawned=1 and the live pane ID with a stale PID,
  # modeling a pane ID reused by a replacement process after the roster write.
  roster_tmp="$DUET_DIR/.roster.test"
  stale_worker_pid=$((10#$WORKER_ONE_PANE_PID + 1000000))
  awk -F '\t' -v stale="$stale_worker_pid" 'BEGIN { OFS="\t" }
    NR > 1 {
      $6=0
      if ($1 == "codex-1") { $4=stale; $6=1 }
    }
    { print }
  ' \
    "$DUET_DIR/roster.tsv" > "$roster_tmp"
  mv "$roster_tmp" "$DUET_DIR/roster.tsv"
  : > "$DUET_DIR/.ended"
  printf '99999999\n' > "$DUET_DIR/daemon.pid"
  {
    printf 'keep-ended-agents\n'
    printf '<!-- DUET:BEGIN test -->\nremove-ended-agents\n<!-- DUET:END -->\n'
  } > "$WORKDIR/AGENTS.md"
  {
    printf 'keep-ended-claude\n'
    printf '<!-- DUET:BEGIN test -->\nremove-ended-claude\n<!-- DUET:END -->\n'
  } > "$WORKDIR/CLAUDE.md"

  DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
    DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" bash "$END_SCRIPT" \
    > "$output_dir/first.out" 2> "$output_dir/first.err"
  first_rc=$?
  DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
    DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" bash "$END_SCRIPT" \
    > "$output_dir/second.out" 2> "$output_dir/second.err"
  second_rc=$?

  assert_eq 0 "$first_rc" "already-ended finalization"
  assert_eq 0 "$second_rc" "already-ended finalization is idempotent"
  assert_no_file "$DUET_DIR/daemon.pid" "stale dead-daemon PID removed"
  assert_no_file "$DUET_DIR/.daemon.lock" "daemon finalization lock released"
  assert_no_file "$DUET_STATE_ROOT/current" "already-ended current link removed"
  assert_not_contains "$WORKDIR/AGENTS.md" '<!-- DUET:BEGIN' \
    "already-ended AGENTS anchor stripped"
  assert_not_contains "$WORKDIR/CLAUDE.md" '<!-- DUET:BEGIN' \
    "already-ended CLAUDE anchor stripped"
  assert_contains "$WORKDIR/AGENTS.md" keep-ended-agents \
    "already-ended AGENTS user content retained"
  assert_contains "$WORKDIR/CLAUDE.md" keep-ended-claude \
    "already-ended CLAUDE user content retained"
  assert_eq 0 "$(duet_pending_count)" "already-ended session has no pending messages"
  assert_eq 0 "$(duet_notice_obligation_count)" \
    "already-ended session has no notice obligations"
  alive_panes="$(command tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_id}')"
  printf '%s\n' "$alive_panes" | grep -qxF "$INIT_PANE" \
    || fail "initiator pane was killed by already-ended finalization"
  printf '%s\n' "$alive_panes" | grep -qxF "$WORKER_ONE_PANE" \
    || fail "replacement process in reused pane ID was killed during teardown"
  actual_pid="$(command tmux -L "$TMUX_LABEL" display-message -p \
    -t "$WORKER_ONE_PANE" '#{pane_pid}' 2>/dev/null || true)"
  assert_eq "$WORKER_ONE_PANE_PID" "$actual_pid" \
    "pane-PID fence preserves replacement process during repeated teardown"
}

test_drain_admission_barrier(){
  local fake_script fake_pid release_file output_dir end_pid end_rc rc
  local before_counter before_transcript alive_panes i
  create_state drain
  output_dir="$TEST_ROOT/drain-output"
  mkdir -p "$output_dir"
  fake_script="$TEST_ROOT/fake-duet-deliverd.sh"
  release_file="$DUET_DIR/release-drain"

  # This fixture only models daemon liveness and archival. Its distinctive
  # script name intentionally satisfies duet_daemon_alive's command fence.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -u'
    printf '%s\n' '[ "$1" = --session ] || exit 2'
    printf '%s\n' 'config="$2"'
    printf '%s\n' '[ "$3" = --session-id ] || exit 2'
    printf '%s\n' 'session_id="$4"'
    printf '%s\n' 'dir="$5"'
    printf '%s\n' 'cleanup(){'
    printf '%s\n' '  recorded="$(cat "$dir/daemon.pid" 2>/dev/null || true)"'
    printf '%s\n' '  [ "$recorded" != "$$" ] || rm -f "$dir/daemon.pid"'
    printf '%s\n' '  held="$(cat "$dir/.daemon.lock/owner" 2>/dev/null || true)"'
    printf '%s\n' '  if [ "${held%%'"$'\t'"'*}" = "$$" ]; then'
    printf '%s\n' '    rm -f "$dir/.daemon.lock/owner"'
    printf '%s\n' '    rmdir "$dir/.daemon.lock" 2>/dev/null || true'
    printf '%s\n' '  fi'
    printf '%s\n' '}'
    printf '%s\n' 'trap cleanup EXIT'
    printf '%s\n' "trap 'exit 0' INT TERM"
    printf '%s\n' 'while [ ! -f "$dir/.ended" ]; do'
    printf '%s\n' '  if [ -f "$6" ]; then'
    printf '%s\n' '    for box in "$dir"/inbox/*; do'
    printf '%s\n' '      [ -d "$box" ] || continue'
    printf '%s\n' '      for file in "$box"/N-*.msg "$box"/I-*.msg; do'
    printf '%s\n' '        [ -f "$file" ] || continue'
    printf '%s\n' '        mv "$file" "$box/delivered/$(basename "$file")"'
    printf '%s\n' '        rm -f "$file.phase" "$file.tries" "$file.retry_at"'
    printf '%s\n' '      done'
    printf '%s\n' '    done'
    printf '%s\n' '  fi'
    printf '%s\n' '  sleep 0.05'
    printf '%s\n' 'done'
  } > "$fake_script"
  chmod +x "$fake_script"

  fake_pid="$(bash -c 'nohup bash "$1" --session "$2" --session-id "$3" "$4" "$5" >/dev/null 2>&1 & echo $!' \
    duet-test "$fake_script" "$CURRENT_CONFIG" "$DUET_SESSION_ID" \
    "$DUET_DIR" "$release_file")"
  ACTIVE_DAEMON_PIDS="$ACTIVE_DAEMON_PIDS $fake_pid"
  mkdir "$DUET_DIR/.daemon.lock"
  printf '%s\tfake\n' "$fake_pid" > "$DUET_DIR/.daemon.lock/owner"
  printf '%s\n' "$fake_pid" > "$DUET_DIR/daemon.pid"
  sleep 0.1

  {
    printf 'keep-agents\n'
    printf '<!-- DUET:BEGIN test -->\nremove-agents\n<!-- DUET:END -->\n'
    printf 'keep-agents-end\n'
  } > "$WORKDIR/AGENTS.md"
  {
    printf 'keep-claude\n'
    printf '<!-- DUET:BEGIN test -->\nremove-claude\n<!-- DUET:END -->\n'
    printf 'keep-claude-end\n'
  } > "$WORKDIR/CLAUDE.md"

  (
    unset TMUX TMUX_PANE DUET_SELF
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT DUET_ALLOW_FROM_OVERRIDE=1
    printf 'final queued message\n' | bash "$SEND_SCRIPT" codex-1 --from claude
  ) > "$output_dir/initial.out" 2>&1
  rc=$?
  assert_eq 0 "$rc" "pre-drain enqueue"
  before_counter="$(cat "$DUET_DIR/inbox/codex-1/.counter")"
  before_transcript="$(transcript_count "$DUET_DIR/transcript.md")"

  DUET_CONFIG="$CURRENT_CONFIG" DUET_SESSION="$DUET_SESSION_ID" \
    DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" DUET_DRAIN_TIMEOUT=5 \
    bash "$END_SCRIPT" > "$output_dir/end.out" 2> "$output_dir/end.err" &
  end_pid=$!
  if ! wait_for_file "$DUET_DIR/.draining" 100; then
    fail "end did not publish drain admission fence"
    touch "$release_file"
  fi

  (
    unset TMUX TMUX_PANE DUET_SELF
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT DUET_ALLOW_FROM_OVERRIDE=1
    printf 'must be rejected\n' | bash "$SEND_SCRIPT" codex-1 --from claude
  ) > "$output_dir/rejected.out" 2>&1
  rc=$?
  assert_eq 1 "$rc" "send rejected after drain fence"
  assert_eq "$before_counter" "$(cat "$DUET_DIR/inbox/codex-1/.counter")" \
    "drain rejection does not advance counter"
  assert_eq "$before_transcript" "$(transcript_count "$DUET_DIR/transcript.md")" \
    "drain rejection does not append transcript"

  touch "$release_file"
  if wait "$end_pid"; then end_rc=0; else end_rc=$?; fi
  assert_eq 0 "$end_rc" "drained end exit status"
  assert_file "$DUET_DIR/.ended" "ended marker"
  if kill -0 "$fake_pid" 2>/dev/null; then fail "drain daemon is still alive"; fi
  assert_no_file "$DUET_STATE_ROOT/current" "current symlink removed"
  assert_not_contains "$WORKDIR/AGENTS.md" '<!-- DUET:BEGIN' "AGENTS anchor stripped"
  assert_not_contains "$WORKDIR/CLAUDE.md" '<!-- DUET:BEGIN' "CLAUDE anchor stripped"
  assert_contains "$WORKDIR/AGENTS.md" keep-agents "AGENTS user content retained"
  assert_contains "$WORKDIR/CLAUDE.md" keep-claude "CLAUDE user content retained"

  alive_panes="$(command tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_id}' 2>/dev/null || true)"
  printf '%s\n' "$alive_panes" | grep -qxF "$INIT_PANE" \
    || fail "initiator pane was killed during end"
  for i in "$WORKER_ONE_PANE" "$WORKER_TWO_PANE"; do
    if printf '%s\n' "$alive_panes" | grep -qxF "$i"; then
      fail "spawned pane $i survived end"
    fi
  done
}

run_case '64 concurrent enqueue, identity, daemon restart' \
  test_concurrent_enqueue_identity_restart
run_case 'fair scheduling and per-recipient FIFO' test_fairness_fifo
run_case 'interrupt priority and supersede' test_interrupt_supersede
run_case 'terminal interrupt restart reconciliation' test_interrupt_restart_reconcile
run_case 'failure notice root and terminal dedupe' test_failure_notice_dedupe
run_case 'malformed body64 rejection' test_malformed_body_rejected
run_case 'strict DUETv1 envelope parser parity' test_strict_message_parser
run_case 'NUL payload, leader-state, and dedupe fences' \
  test_nul_payload_and_state_fences
run_case 'retry timestamp numeric and arithmetic fences' \
  test_retry_at_numeric_fences
run_case 'D10 decimal parsing and normalization' test_decimal_d10_bounds
run_case 'persistent counter and message-order D10 bounds' \
  test_persistent_numeric_bounds
run_case 'leader and envelope term D10 bounds' test_term_numeric_bounds
run_case 'message filename numeric and arithmetic fences' \
  test_message_filename_numeric_fences
run_case 'delivery-attempt numeric and arithmetic fences' \
  test_delivery_attempt_numeric_fences
run_case 'terminal counter rollback rejection' test_terminal_counter_rollback_rejected
run_case 'uncertain landing DEAD fencing' test_uncertain_dead_fencing
run_case 'daemon stop owner mismatch fence' test_daemon_stop_owner_mismatch
run_case 'daemon metacharacter path identity fence' test_daemon_metachar_path_identity
run_case 'stale lock symlink escape fence' test_stale_lock_symlink_escape
run_case 'init path, publication, anchor, and cleanup fences' \
  test_init_path_publication_and_cleanup_fences
run_case 'legacy end pane/PID environment fences' test_end_legacy_pane_pid_fences
run_case 'already-ended idempotent finalization' test_already_ended_finalization
run_case 'drain admission barrier and safe teardown' test_drain_admission_barrier

if [ "$FAILURES" -eq 0 ]; then
  printf '==== ALL M2 TRANSPORT TESTS PASS ====\n'
  exit 0
fi
printf '==== %s M2 TRANSPORT ASSERTION(S) FAILED ====\n' "$FAILURES" >&2
exit 1
