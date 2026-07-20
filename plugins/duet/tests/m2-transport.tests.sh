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

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TEST_ROOT="$(mktemp -d "$TMP_BASE/duet-m2-transport.XXXXXX")" || exit 1
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
      *"$TEST_ROOT"/owner-mismatch-helper.sh*) kill -TERM "$pid" 2>/dev/null || true ;;
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
trap cleanup EXIT HUP INT TERM

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
TMUX_SOCKET="$(command tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(command tmux -L "$TMUX_LABEL" display-message -p '#{pid}')"

# shellcheck disable=SC1091
. "$SCRIPTS_DIR/duet-common.sh"

create_state(){
  local name="$1" queue env_tmp
  DUET_DIR="$STATE_ROOT/$name"
  DUET_SESSION_ID="$name"
  DUET_STATE_ROOT="$STATE_ROOT"
  WORKDIR="$WORK_ROOT/$name"
  DUET_TMUX_SOCKET="$TMUX_SOCKET"
  DUET_TMUX_SERVER_PID="$TMUX_SERVER_PID"
  mkdir -p "$DUET_DIR" "$WORKDIR"
  for queue in claude codex-1 kimi-1 leader; do
    mkdir -p "$DUET_DIR/inbox/$queue/delivered" \
      "$DUET_DIR/inbox/$queue/failed" \
      "$DUET_DIR/inbox/$queue/quarantine" \
      "$DUET_DIR/inbox/$queue/superseded"
  done
  : > "$DUET_DIR/transcript.md"
  printf 'term\t0\nleader\tclaude\n' > "$DUET_DIR/leader"
  {
    printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n'
    printf 'claude\tclaude\t%s\t0\t0\t0\n' "$INIT_PANE"
    printf 'codex-1\tcodex\t%s\t0\t1\t1\n' "$WORKER_ONE_PANE"
    printf 'kimi-1\tkimi\t%s\t0\t2\t1\n' "$WORKER_TWO_PANE"
  } > "$DUET_DIR/roster.tsv"
  env_tmp="$DUET_DIR/duet.env"
  {
    printf 'DUET_DIR=%q\n' "$DUET_DIR"
    printf 'DUET_STATE_ROOT=%q\n' "$DUET_STATE_ROOT"
    printf 'WORKDIR=%q\n' "$WORKDIR"
    printf 'PLUGIN_DIR=%q\n' "$PLUGIN_DIR"
    printf 'DUET_TMUX_SOCKET=%q\n' "$DUET_TMUX_SOCKET"
    printf 'DUET_TMUX_SERVER_PID=%q\n' "$DUET_TMUX_SERVER_PID"
    printf 'DUET_SESSION_ID=%q\n' "$DUET_SESSION_ID"
    printf 'DUET_INITIATOR=%q\n' claude
    printf 'DUET_INITIATOR_PANE=%q\n' "$INIT_PANE"
  } > "$env_tmp"
  ln -sfn "$DUET_DIR" "$DUET_STATE_ROOT/current"
  CURRENT_CONFIG="$env_tmp"
  export DUET_DIR DUET_SESSION_ID DUET_STATE_ROOT WORKDIR PLUGIN_DIR
  export DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
}

start_actual_daemon(){
  local retry_base="${1:-30}" i
  DUET_CONFIG="$CURRENT_CONFIG" DUET_DELIVERY_RETRY_BASE="$retry_base" \
    DUET_DELIVERY_POLL_INTERVAL=0.05 \
    bash "$DELIVERD_SCRIPT" > "$DUET_DIR/daemon.stdout" 2>&1 &
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
      unset TMUX_PANE DUET_SELF
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
    unset TMUX_PANE DUET_SELF DUET_ALLOW_FROM_OVERRIDE
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT
    printf 'unresolved\n' | bash "$SEND_SCRIPT" leader
  ) > "$output_dir/unresolved.out" 2>&1
  rc=$?
  assert_eq 7 "$rc" "unresolved sender rejection"

  printf 'mismatch self\n' | DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" DUET_SELF=codex-1 \
    bash "$SEND_SCRIPT" codex-1 > "$output_dir/self-mismatch.out" 2>&1
  rc=$?
  assert_eq 7 "$rc" "TMUX_PANE and DUET_SELF mismatch rejection"

  printf 'mismatch from\n' | DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" DUET_SELF=claude \
    bash "$SEND_SCRIPT" leader --from codex-1 > "$output_dir/from-mismatch.out" 2>&1
  rc=$?
  assert_eq 7 "$rc" "known pane and --from mismatch rejection"

  (
    unset TMUX_PANE DUET_SELF
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT DUET_ALLOW_FROM_OVERRIDE=1
    printf 'hub violation\n' | bash "$SEND_SCRIPT" kimi-1 --from codex-1
  ) > "$output_dir/hub.out" 2>&1
  rc=$?
  assert_eq 8 "$rc" "worker-to-worker hub rejection"
  assert_eq "$before_count" "$(transcript_count "$DUET_DIR/transcript.md")" \
    "rejected sends do not append transcript"
  assert_eq 64 "$(cat "$box/.counter")" "rejected sends do not advance counter"

  (
    unset TMUX_PANE DUET_SELF
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

  # Make the symbolic leader deliberately dead before restart. The restarted
  # real daemon may advance retry metadata, but cannot paste into a test shell.
  roster_tmp="$DUET_DIR/.roster.test"
  awk -F '\t' 'BEGIN { OFS="\t" } $1 == "claude" { $3="%999999" } { print }' \
    "$DUET_DIR/roster.tsv" > "$roster_tmp"
  mv "$roster_tmp" "$DUET_DIR/roster.tsv"
  if ! start_actual_daemon 30; then
    fail "actual daemon did not restart"
    return
  fi
  if ! wait_for_file "$box/N-0000000001.msg.tries" 100; then
    fail "restarted daemon did not inspect pending head"
  fi
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
  local helper helper_pid owner_pid output rc
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
}

test_already_ended_finalization(){
  local output_dir roster_tmp first_rc second_rc alive_panes
  create_state already-ended
  output_dir="$TEST_ROOT/already-ended-output"
  mkdir -p "$output_dir"

  # Preserve the shared fixture panes for the subsequent drain test; this case
  # exercises already-ended finalization rather than spawned-pane ownership.
  roster_tmp="$DUET_DIR/.roster.test"
  awk -F '\t' 'BEGIN { OFS="\t" } NR > 1 { $6=0 } { print }' \
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

  DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" bash "$END_SCRIPT" \
    > "$output_dir/first.out" 2> "$output_dir/first.err"
  first_rc=$?
  DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT="$DUET_STATE_ROOT" \
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
    printf '%s\n' 'dir="$1"'
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
    printf '%s\n' '  if [ -f "$2" ]; then'
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

  fake_pid="$(bash -c 'nohup bash "$1" "$2" "$3" >/dev/null 2>&1 & echo $!' \
    duet-test "$fake_script" "$DUET_DIR" "$release_file")"
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
    unset TMUX_PANE DUET_SELF
    export DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT DUET_ALLOW_FROM_OVERRIDE=1
    printf 'final queued message\n' | bash "$SEND_SCRIPT" codex-1 --from claude
  ) > "$output_dir/initial.out" 2>&1
  rc=$?
  assert_eq 0 "$rc" "pre-drain enqueue"
  before_counter="$(cat "$DUET_DIR/inbox/codex-1/.counter")"
  before_transcript="$(transcript_count "$DUET_DIR/transcript.md")"

  DUET_CONFIG="$CURRENT_CONFIG" DUET_STATE_ROOT="$DUET_STATE_ROOT" \
    TMUX_PANE="$INIT_PANE" DUET_DRAIN_TIMEOUT=5 \
    bash "$END_SCRIPT" > "$output_dir/end.out" 2> "$output_dir/end.err" &
  end_pid=$!
  if ! wait_for_file "$DUET_DIR/.draining" 100; then
    fail "end did not publish drain admission fence"
    touch "$release_file"
  fi

  (
    unset TMUX_PANE DUET_SELF
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
run_case 'terminal counter rollback rejection' test_terminal_counter_rollback_rejected
run_case 'uncertain landing DEAD fencing' test_uncertain_dead_fencing
run_case 'daemon stop owner mismatch fence' test_daemon_stop_owner_mismatch
run_case 'already-ended idempotent finalization' test_already_ended_finalization
run_case 'drain admission barrier and safe teardown' test_drain_admission_barrier

if [ "$FAILURES" -eq 0 ]; then
  printf '==== ALL M2 TRANSPORT TESTS PASS ====\n'
  exit 0
fi
printf '==== %s M2 TRANSPORT ASSERTION(S) FAILED ====\n' "$FAILURES" >&2
exit 1
