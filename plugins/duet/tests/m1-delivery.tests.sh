#!/usr/bin/env bash
# Deterministic v4 M1 delivery-core tests.
# Owns an isolated tmux server and a temporary state root.
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
COMMON="$PLUGIN_DIR/scripts/duet-common.sh"
DELIVERD="$PLUGIN_DIR/scripts/duet-deliverd.sh"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)" || exit 1
TEST_ROOT="$(mktemp -d "$TMP_BASE/duet-v4-m1.XXXXXX")" || exit 1
STATE_ROOT="$TEST_ROOT/state"
WORK_ROOT="$TEST_ROOT/work"
TMUX_LABEL="duet-v4-m1-$PPID-${RANDOM:-0}"
TMUX_SESSION=m1
FAILURES=0
CURRENT_CASE=setup

mkdir -p "$STATE_ROOT" "$WORK_ROOT"

fail(){
  FAILURES=$((FAILURES + 1))
  printf '  FAIL [%s] %s\n' "$CURRENT_CASE" "$*" >&2
}

assert_eq(){
  local expected="$1" actual="$2" label="$3"
  [ "$expected" = "$actual" ] \
    || fail "$label: expected '$expected', got '$actual'"
}

assert_file(){
  [ -f "$1" ] || fail "$2: missing $1"
}

assert_no_file(){
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2: unexpected $1"
}

assert_contains(){
  grep -qF "$2" "$1" 2>/dev/null \
    || fail "$3: '$2' not found in $1"
}

run_case(){
  local label="$1" fn="$2" before
  CURRENT_CASE="$label"
  before="$FAILURES"
  printf 'TEST %s\n' "$label"
  "$fn"
  if [ "$FAILURES" -eq "$before" ]; then
    printf '  PASS\n'
  fi
}

cleanup(){
  command tmux -L "$TMUX_LABEL" kill-server >/dev/null 2>&1 || true
  case "$TEST_ROOT" in
    "$TMP_BASE"/duet-v4-m1.*) rm -rf -- "$TEST_ROOT" ;;
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
    -s "$TMUX_SESSION" -c "$WORK_ROOT" 'exec sleep 600'; then
  printf 'FAIL: could not start isolated tmux server\n' >&2
  exit 1
fi
PANE_ONE="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$TMUX_SESSION" '#{pane_id}')"
PANE_TWO="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" 'exec sleep 600')"
PANE_THREE="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" 'exec sleep 600')"
PANE_ONE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$PANE_ONE" '#{pane_pid}')"
PANE_TWO_PID="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$PANE_TWO" '#{pane_pid}')"
PANE_THREE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$PANE_THREE" '#{pane_pid}')"
TMUX_SOCKET="$(command tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(command tmux -L "$TMUX_LABEL" display-message -p '#{pid}')"

# shellcheck disable=SC1090
. "$COMMON"
eval "$(
  declare -f duet_send_verified \
    | sed '1s/^duet_send_verified[[:space:]]*()/duet_send_verified_production()/'
)"

test_kimi_marker_cursor_scope(){
  if ! (
    local token
    _duet_tmux(){
      case "$1" in
        display-message) printf '2\n' ;;
        capture-pane)
          printf '%s\n' \
            'history [paste #2 +9 lines]' \
            'ordinary history' \
            '[paste #7 +74 lines]'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' kimi)"
    [ "$token" = kimipaste774lines ]
  ); then
    fail "active-row Kimi marker was not normalized exactly"
  fi
  if ! (
    local token
    _duet_tmux(){
      case "$1" in
        display-message) printf '2\n' ;;
        capture-pane)
          printf '%s\n' \
            'history [paste #2 +9 lines]' \
            '[paste #7 +74 lines]' \
            'empty active composer'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' kimi)"
    [ -z "$token" ]
  ); then
    fail "Kimi marker in history was mistaken for the active composer"
  fi
}

run_verified_scenario(){
  local mode="$1" state paste_count enter_count
  local clear_after=1 rc
  state="$TEST_ROOT/verifier-$mode.state"
  paste_count="$TEST_ROOT/verifier-$mode.pastes"
  enter_count="$TEST_ROOT/verifier-$mode.enters"
  printf 'clean\n' > "$state"
  printf '0\n' > "$paste_count"
  printf '0\n' > "$enter_count"
  case "$mode" in
    preexisting) printf 'existing\n' > "$state" ;;
    retry-enter) clear_after=2 ;;
  esac
  (
    _duet_alive(){ return 0; }
    duet_tmux_server_matches(){ return 0; }
    _duet_tail_strip(){ printf ''; }
    _duet_paste_marker(){
      case "$(cat "$state")" in
        existing) printf 'kimipaste174lines' ;;
        landed) [ "$mode" != no-evidence ] && printf 'kimipaste174lines' ;;
      esac
    }
    _duet_tmux(){
      local count
      case "$1" in
        load-buffer)
          command cat >/dev/null
          ;;
        paste-buffer)
          count="$(cat "$paste_count")"
          printf '%s\n' "$((count + 1))" > "$paste_count"
          printf 'landed\n' > "$state"
          ;;
        send-keys)
          if [ "${4:-}" = Enter ]; then
            count="$(cat "$enter_count")"
            count=$((count + 1))
            printf '%s\n' "$count" > "$enter_count"
            [ "$count" -lt "$clear_after" ] || printf 'submitted\n' > "$state"
          fi
          ;;
        delete-buffer) : ;;
      esac
    }
    DUET_LANDING_CHECKS=1
    DUET_LANDING_SLEEP=0
    DUET_SUBMIT_ATTEMPTS=3
    DUET_SUBMIT_CHECKS=1
    DUET_SUBMIT_SLEEP=0
    if duet_send_verified_production \
        '%1' 'payload with unique tail 8675309' '' kimi; then
      rc=0
    else
      rc=$?
    fi
    printf '%s\n' "$rc" > "$TEST_ROOT/verifier-$mode.rc"
  )
}

test_verified_send_fsm(){
  run_verified_scenario success
  assert_eq 0 "$(cat "$TEST_ROOT/verifier-success.rc")" "verified success"
  assert_eq 1 "$(cat "$TEST_ROOT/verifier-success.pastes")" "single paste"
  assert_eq 1 "$(cat "$TEST_ROOT/verifier-success.enters")" "single Enter"

  run_verified_scenario retry-enter
  assert_eq 0 "$(cat "$TEST_ROOT/verifier-retry-enter.rc")" "Enter retry success"
  assert_eq 1 "$(cat "$TEST_ROOT/verifier-retry-enter.pastes")" \
    "Enter retry never repastes"
  assert_eq 2 "$(cat "$TEST_ROOT/verifier-retry-enter.enters")" \
    "Enter retried in process"

  run_verified_scenario no-evidence
  assert_eq "$DUET_SEND_LANDED_UNVERIFIED" \
    "$(cat "$TEST_ROOT/verifier-no-evidence.rc")" "no-evidence ambiguity"
  assert_eq 1 "$(cat "$TEST_ROOT/verifier-no-evidence.pastes")" \
    "ambiguous delivery pastes once"
  assert_eq 0 "$(cat "$TEST_ROOT/verifier-no-evidence.enters")" \
    "no Enter without landing evidence"

  run_verified_scenario preexisting
  assert_eq "$DUET_SEND_NOT_LANDED" \
    "$(cat "$TEST_ROOT/verifier-preexisting.rc")" "pre-existing marker stalls"
  assert_eq 0 "$(cat "$TEST_ROOT/verifier-preexisting.pastes")" \
    "pre-existing marker blocks paste"
}

# shellcheck disable=SC1090
. "$DELIVERD"

FAKE_LOG=""
FAKE_STALLED_TARGET=""
FAKE_AMBIGUOUS_TARGET=""

duet_send_verified(){
  printf '%s\t%s\t%s\n' "$DUET_MESSAGE_ID" "$DUET_TARGET_NAME" \
    "$DUET_MESSAGE_BODY" >> "$FAKE_LOG"
  if [ "$DUET_TARGET_NAME" = "$FAKE_STALLED_TARGET" ]; then
    return "$DUET_SEND_NOT_LANDED"
  fi
  if [ "$DUET_TARGET_NAME" = "$FAKE_AMBIGUOUS_TARGET" ]; then
    return "$DUET_SEND_LANDED_UNVERIFIED"
  fi
  return 0
}

duet_daemon_alive(){ return 0; }

create_state(){
  local name="$1" queue
  DUET_DIR="$STATE_ROOT/$name"
  DUET_SESSION_ID="$name"
  DUET_SESSION="$name"
  DUET_STATE_ROOT="$STATE_ROOT"
  WORKDIR="$WORK_ROOT/$name"
  DUET_TMUX_SOCKET="$TMUX_SOCKET"
  DUET_TMUX_SERVER_PID="$TMUX_SERVER_PID"
  mkdir -p "$DUET_DIR" "$WORKDIR"
  for queue in claude codex-1 kimi-1; do
    mkdir -p "$DUET_DIR/inbox/$queue/delivered"
  done
  : > "$DUET_DIR/transcript.md"
  {
    printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n'
    printf 'claude\tclaude\t%s\t%s\t0\t0\n' "$PANE_ONE" "$PANE_ONE_PID"
    printf 'codex-1\tcodex\t%s\t%s\t1\t1\n' "$PANE_TWO" "$PANE_TWO_PID"
    printf 'kimi-1\tkimi\t%s\t%s\t2\t1\n' "$PANE_THREE" "$PANE_THREE_PID"
  } > "$DUET_DIR/roster.tsv"
  export DUET_DIR DUET_SESSION_ID DUET_SESSION DUET_STATE_ROOT WORKDIR
  export DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID
}

enqueue_one(){
  local recipient="$1" body="$2"
  duet_enqueue_message "$recipient" claude "$recipient" NORMAL "$body"
}

active_count(){
  local box="$1" file count=0
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

delivered_count(){
  local box="$1" file count=0
  for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

test_failed_head_is_fair_and_fifo(){
  local codex_box kimi_box
  create_state fairness
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=codex-1
  FAKE_AMBIGUOUS_TARGET=""
  enqueue_one codex-1 codex-one
  enqueue_one codex-1 codex-two
  enqueue_one kimi-1 kimi-one
  enqueue_one kimi-1 kimi-two
  codex_box="$DUET_DIR/inbox/codex-1"
  kimi_box="$DUET_DIR/inbox/kimi-1"

  duet_deliverd_pass || fail "first pass failed"
  assert_eq 2 "$(active_count "$codex_box")" "stalled recipient retains FIFO"
  assert_eq 1 "$(delivered_count "$kimi_box")" "other recipient advances once"

  duet_deliverd_pass || fail "second pass failed"
  assert_eq 2 "$(active_count "$codex_box")" "stalled head still blocks successor"
  assert_eq 2 "$(delivered_count "$kimi_box")" "other recipient advances again"
  assert_no_file "$codex_box/N-0000000001.msg.phase" "no durable phase"
  assert_no_file "$codex_box/N-0000000001.msg.tries" "no durable attempts"
}

test_ambiguous_delivery_stops_loudly(){
  create_state ambiguous
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=""
  FAKE_AMBIGUOUS_TARGET=kimi-1
  enqueue_one kimi-1 ambiguous-body
  if duet_deliverd_pass; then
    fail "ambiguous pass unexpectedly succeeded"
  fi
  assert_file "$DUET_DIR/.unhealthy" "unhealthy marker"
  assert_contains "$DUET_DIR/.unhealthy" delivery-ambiguous \
    "loud ambiguity reason"
  assert_eq 1 "$(active_count "$DUET_DIR/inbox/kimi-1")" \
    "ambiguous message remains for diagnosis"
  assert_no_file "$DUET_DIR/inbox/kimi-1/N-0000000001.msg.phase" \
    "no ENTER_ONLY recovery state"
}

test_concurrent_fifo_and_dedupe(){
  local box pids="" pid i expected actual bodies expected_bodies first duplicate
  create_state concurrent
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=""
  FAKE_AMBIGUOUS_TARGET=""
  box="$DUET_DIR/inbox/kimi-1"

  for i in $(seq 1 50); do
    env DUET_DIR="$DUET_DIR" DUET_SESSION_ID="$DUET_SESSION_ID" \
      DUET_SESSION="$DUET_SESSION" DUET_STATE_ROOT="$DUET_STATE_ROOT" \
      WORKDIR="$WORKDIR" DUET_TMUX_SOCKET="$DUET_TMUX_SOCKET" \
      DUET_TMUX_SERVER_PID="$DUET_TMUX_SERVER_PID" \
      /bin/bash -c '
        . "$1"
        duet_daemon_alive(){ return 0; }
        duet_enqueue_message kimi-1 claude kimi-1 NORMAL "$2"
      ' _ "$COMMON" "concurrent-$i" \
      > "$DUET_DIR/enqueue-$i.out" 2> "$DUET_DIR/enqueue-$i.err" &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent enqueue process $pid failed"
  done
  assert_eq 50 "$(active_count "$box")" "50 intact concurrent enqueues"

  expected="$DUET_DIR/expected.ids"
  actual="$DUET_DIR/actual.ids"
  bodies="$DUET_DIR/enqueued.bodies"
  expected_bodies="$DUET_DIR/expected.bodies"
  : > "$expected"
  : > "$bodies"
  for i in "$box"/N-*.msg; do
    [ -f "$i" ] || continue
    duet_read_message "$i" || {
      fail "invalid concurrent envelope $i"
      continue
    }
    printf '%s\t%s\n' "$DUET_MESSAGE_ID" "$DUET_MESSAGE_BODY" >> "$expected"
    printf '%s\n' "$DUET_MESSAGE_BODY" >> "$bodies"
  done
  : > "$expected_bodies"
  for i in $(seq 1 50); do printf 'concurrent-%s\n' "$i"; done \
    | LC_ALL=C sort > "$expected_bodies"
  LC_ALL=C sort "$bodies" > "$bodies.sorted"
  cmp -s "$expected_bodies" "$bodies.sorted" \
    || fail "concurrent enqueue bodies were lost, duplicated, or corrupted"
  for i in $(seq 1 50); do
    duet_deliverd_pass || {
      fail "FIFO pass $i failed"
      break
    }
  done
  awk -F '\t' '{ print $1 "\t" $3 }' "$FAKE_LOG" > "$actual"
  cmp -s "$expected" "$actual" \
    || fail "delivery order or body fidelity differs from the queue"
  assert_eq 50 "$(delivered_count "$box")" "all 50 delivered"
  assert_eq 0 "$(active_count "$box")" "queue completed"

  first="$(find "$box/delivered" -name 'N-*.msg' -type f | LC_ALL=C sort | head -n 1)"
  duplicate="$box/N-0000000051.msg"
  cp "$first" "$duplicate"
  duet_deliverd_pass || fail "duplicate suppression pass failed"
  assert_eq 50 "$(wc -l < "$FAKE_LOG" | tr -d ' ')" \
    "duplicate stable ID not reinjected"
  assert_file "$box/delivered/N-0000000051.msg" "duplicate archived"
  assert_contains "$DUET_DIR/deliverd.log" "suppressed duplicate" \
    "duplicate suppression logged"
}

run_case 'Kimi marker is exact and cursor-row scoped' \
  test_kimi_marker_cursor_scope
run_case 'verified send pastes once and retries Enter only' \
  test_verified_send_fsm
run_case 'failed head preserves FIFO without blocking peers' \
  test_failed_head_is_fair_and_fifo
run_case 'post-paste ambiguity marks session unhealthy' \
  test_ambiguous_delivery_stops_loudly
run_case '50 concurrent enqueues preserve FIFO and dedupe IDs' \
  test_concurrent_fifo_and_dedupe

if [ "$FAILURES" -eq 0 ]; then
  printf '==== ALL V4 M1 DELIVERY TESTS PASS ====\n'
  exit 0
fi
printf '==== %s V4 M1 ASSERTION(S) FAILED ====\n' "$FAILURES" >&2
exit 1
