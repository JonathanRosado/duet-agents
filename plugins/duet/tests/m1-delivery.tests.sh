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
  # A renamed or deleted case must fail the suite rather than silently pass.
  if ! declare -F "$fn" >/dev/null; then
    fail "test function '$fn' is not defined"
    return
  fi
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

test_marker_cursor_scope(){
  if ! (
    local token
    _duet_tmux(){
      case "$1" in
        display-message) printf '2\n' ;;
        capture-pane)
          printf '%s\n' \
            'history [Pasted text #2 +9 lines]' \
            'ordinary history' \
            '[Pasted text #7 +74 lines]' \
            'paste again to expand'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' claude)"
    [ "$token" = claudePastedtext774lines ]
  ); then
    fail "active-row Claude marker was not normalized exactly"
  fi
  if ! (
    local token
    _duet_tmux(){
      case "$1" in
        display-message) printf '2\n' ;;
        capture-pane)
          printf '%s\n' \
            'history [Pasted text #2 +9 lines]' \
            'paste again to expand' \
            'empty active composer'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' claude)"
    [ -z "$token" ]
  ); then
    fail "Claude marker in history was mistaken for the active composer"
  fi
  if ! (
    local token
    _duet_tmux(){
      case "$1" in
        display-message) printf '2\n' ;;
        capture-pane)
          printf '%s\n' \
            'history [Pasted Content 12 chars]' \
            'ordinary history' \
            '[Pasted Content 987 chars]'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' codex)"
    [ "$token" = codexPastedContent987chars ]
  ); then
    fail "active-row Codex marker was not normalized exactly"
  fi
  if ! (
    local token
    _duet_tmux(){
      case "$1" in
        display-message) printf '2\n' ;;
        capture-pane)
          printf '%s\n' \
            'history [Pasted Content 12 chars]' \
            '[Pasted Content 987 chars]' \
            'empty active composer'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' codex)"
    [ -z "$token" ]
  ); then
    fail "Codex marker in history was mistaken for the active composer"
  fi
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
  if ! (
    local cursor_reads="$TEST_ROOT/marker-cursor-reads" token
    printf '0\n' > "$cursor_reads"
    _duet_tmux(){
      local reads
      case "$1" in
        display-message)
          reads="$(cat "$cursor_reads")"
          printf '%s\n' "$((reads + 1))" > "$cursor_reads"
          if [ "$reads" -eq 0 ]; then printf '2\n'; else printf '3\n'; fi
          ;;
        capture-pane)
          printf '%s\n' \
            'ordinary history' \
            'ordinary history' \
            '[paste #7 +74 lines]' \
            'new active row'
          ;;
      esac
    }
    token="$(_duet_paste_marker '%1' kimi)"
    [ -z "$token" ]
  ); then
    fail "marker was accepted across a cursor-row redraw"
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
    _duet_sample_marker(){
      DUET_PASTE_MARKER=""
      DUET_PASTE_MARKER_INDETERMINATE=""
      case "$(cat "$state")" in
        existing) DUET_PASTE_MARKER='kimipaste174lines' ;;
        landed)
          [ "$mode" = no-evidence ] || DUET_PASTE_MARKER='kimipaste174lines'
          ;;
        submitted)
          # A pane whose composer row cannot be read stably. It is NOT an
          # empty composer, and must never be scored as an accepted message.
          [ "$mode" != unreadable ] || DUET_PASTE_MARKER_INDETERMINATE=1
          ;;
      esac
      return 0
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

# A resumed send must recognize the placeholder it left behind. Pressing Enter
# at a composer somebody else filled would submit their input, not ours.
test_resume_refuses_foreign_composer(){
  local enters="$TEST_ROOT/foreign.enters"
  printf '0\n' > "$enters"
  if ! (
    local rc=0
    _duet_alive(){ return 0; }
    duet_tmux_server_matches(){ return 0; }
    _duet_tail_strip(){ printf ''; }
    _duet_sample_marker(){
      DUET_PASTE_MARKER='kimipaste999lines'
      DUET_PASTE_MARKER_INDETERMINATE=""
      return 0
    }
    _duet_tmux(){
      local count
      if [ "$1" = send-keys ] && [ "${4:-}" = Enter ]; then
        count="$(cat "$enters")"
        printf '%s\n' "$((count + 1))" > "$enters"
      fi
    }
    DUET_SUBMIT_ATTEMPTS=1
    DUET_SUBMIT_CHECKS=1
    DUET_SUBMIT_SLEEP=0
    duet_send_verified_production '%1' 'payload with unique tail 8675309' '' kimi 1 \
      'kimipaste174lines' >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$DUET_SEND_LANDED_UNVERIFIED" ]
  ); then
    fail "resume accepted a composer holding an unrelated placeholder"
  fi
  assert_eq 0 "$(cat "$enters")" "resume pressed Enter at a foreign composer"

  # The same resume against our own placeholder, grown by a second marker,
  # is ours and must proceed.
  printf '0\n' > "$enters"
  if ! (
    local rc=0
    _duet_alive(){ return 0; }
    duet_tmux_server_matches(){ return 0; }
    _duet_tail_strip(){ printf ''; }
    _duet_sample_marker(){
      DUET_PASTE_MARKER='kimipaste174linespaste175lines'
      DUET_PASTE_MARKER_INDETERMINATE=""
      return 0
    }
    _duet_tmux(){
      local count
      if [ "$1" = send-keys ] && [ "${4:-}" = Enter ]; then
        count="$(cat "$enters")"
        printf '%s\n' "$((count + 1))" > "$enters"
      fi
    }
    DUET_SUBMIT_ATTEMPTS=1
    DUET_SUBMIT_CHECKS=1
    DUET_SUBMIT_SLEEP=0
    duet_send_verified_production '%1' 'payload with unique tail 8675309' '' kimi 1 \
      'kimipaste174lines' >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$DUET_SEND_LANDED_UNVERIFIED" ]
  ); then
    fail "resume did not recognize its own grown placeholder"
  fi
  assert_eq 1 "$(cat "$enters")" "resume did not retry Enter on its own payload"
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

  # A composer that cannot be read stably used to be indistinguishable from a
  # cleared one, so a busy peer's unsent message was recorded as delivered.
  run_verified_scenario unreadable
  assert_eq "$DUET_SEND_LANDED_UNVERIFIED" \
    "$(cat "$TEST_ROOT/verifier-unreadable.rc")" \
    "unreadable composer was scored as an accepted message"
  assert_eq 1 "$(cat "$TEST_ROOT/verifier-unreadable.pastes")" \
    "unreadable composer caused a repaste"
  assert_eq 3 "$(cat "$TEST_ROOT/verifier-unreadable.enters")" \
    "Enter was not retried while the composer stayed unreadable"
}

# shellcheck disable=SC1090
. "$DELIVERD"

FAKE_LOG=""
FAKE_STALLED_TARGET=""
FAKE_AMBIGUOUS_TARGET=""
# Empty means "ambiguous forever"; a count means that many ambiguous outcomes
# and then success, which is how a resumed send is exercised.
FAKE_AMBIGUOUS_REMAINING=""

# The fourth column records the enter-only flag, so a test can prove a resumed
# message was never repasted.
duet_send_verified(){
  printf '%s\t%s\t%s\t%s\n' "$DUET_MESSAGE_ID" "$DUET_TARGET_NAME" \
    "$DUET_MESSAGE_BODY" "${5:-}" >> "$FAKE_LOG"
  if [ "$DUET_TARGET_NAME" = "$FAKE_STALLED_TARGET" ]; then
    return "$DUET_SEND_NOT_LANDED"
  fi
  if [ -n "$FAKE_AMBIGUOUS_TARGET" ] \
      && [ "$DUET_TARGET_NAME" = "$FAKE_AMBIGUOUS_TARGET" ]; then
    if [ -z "$FAKE_AMBIGUOUS_REMAINING" ]; then
      return "$DUET_SEND_LANDED_UNVERIFIED"
    fi
    if [ "$FAKE_AMBIGUOUS_REMAINING" -gt 0 ]; then
      FAKE_AMBIGUOUS_REMAINING=$((FAKE_AMBIGUOUS_REMAINING - 1))
      return "$DUET_SEND_LANDED_UNVERIFIED"
    fi
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

test_persistent_stall_blocks_only_recipient(){
  local codex_box kimi_box pass status_file
  local DUET_NOT_LANDED_LIMIT=3
  create_state bounded-stall
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=codex-1
  FAKE_AMBIGUOUS_TARGET=""
  enqueue_one codex-1 normal-head
  enqueue_one codex-1 normal-successor
  for pass in $(seq 1 7); do enqueue_one kimi-1 "healthy-peer-$pass"; done
  codex_box="$DUET_DIR/inbox/codex-1"
  kimi_box="$DUET_DIR/inbox/kimi-1"

  # Two failures accrue on the normal head.
  duet_deliverd_pass || fail "bounded-stall pass 1 failed"
  duet_deliverd_pass || fail "bounded-stall pass 2 failed"
  assert_no_file "$DUET_DIR/blocked/codex-1" \
    "recipient blocked before configured bound"

  # A high-priority head change starts a fresh window: its first failure must
  # not inherit the normal head's two failures.
  duet_enqueue_message codex-1 claude codex-1 INTERRUPT interrupt-head \
    || fail "could not enqueue interrupt head"
  duet_deliverd_pass || fail "bounded-stall interrupt failure pass failed"
  assert_no_file "$DUET_DIR/blocked/codex-1" \
    "head change did not reset consecutive failures"

  # The same interrupt head now succeeds, which resets its recipient counter.
  FAKE_STALLED_TARGET=""
  duet_deliverd_pass || fail "bounded-stall interrupt success pass failed"
  assert_eq 1 "$(delivered_count "$codex_box")" \
    "interrupt head did not deliver"

  # Returning to the old normal head is another head change. It gets a full
  # three fresh attempts before that recipient alone becomes blocked.
  FAKE_STALLED_TARGET=codex-1
  duet_deliverd_pass || fail "bounded-stall fresh pass 1 failed"
  duet_deliverd_pass || fail "bounded-stall fresh pass 2 failed"
  assert_no_file "$DUET_DIR/blocked/codex-1" \
    "successful delivery did not reset consecutive failures"
  duet_deliverd_pass || fail "bounded-stall terminal pass failed"

  assert_file "$DUET_DIR/blocked/codex-1" "wedged recipient block marker"
  assert_contains "$DUET_DIR/blocked/codex-1" \
    "composer wedged: 3 consecutive delivery attempts" \
    "wedged recipient reason"
  assert_contains "$DUET_DIR/deliverd.log" \
    "BLOCKED recipient codex-1: composer wedged: 3 consecutive delivery attempts" \
    "wedged recipient was not surfaced in daemon log"
  status_file="$DUET_DIR/status.out"
  if ! /bin/bash -c '. "$1"; duet_diag_print_roster' \
      _ "$PLUGIN_DIR/scripts/duet-status.sh" > "$status_file"; then
    fail "status could not render the blocked recipient"
  elif ! awk '$1 == "codex-1" && $6 == "blocked" { found=1 }
      END { exit !found }' "$status_file"; then
    fail "status did not surface codex-1 as blocked"
  fi
  assert_no_file "$DUET_DIR/.unhealthy" \
    "persistent stall marked whole session unhealthy"
  assert_eq 2 "$(active_count "$codex_box")" \
    "blocked recipient did not retain its head and successor"
  assert_eq 7 "$(delivered_count "$kimi_box")" \
    "healthy peer did not advance during every stalled pass"
}

# A single ambiguous observation used to end a recipient's session outright.
# A pane that is merely busy or redrawing produces exactly that observation, so
# ambiguity must be resumed enter-only and fenced only when it persists.
test_ambiguous_delivery_resumes_before_blocking(){
  local kimi_box
  local DUET_AMBIGUOUS_LIMIT=3
  create_state ambiguous
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=""
  FAKE_AMBIGUOUS_TARGET=kimi-1
  FAKE_AMBIGUOUS_REMAINING=""
  enqueue_one kimi-1 ambiguous-body
  enqueue_one codex-1 healthy-peer-body
  kimi_box="$DUET_DIR/inbox/kimi-1"

  duet_deliverd_pass || fail "ambiguous pass stopped the whole daemon"
  assert_no_file "$DUET_DIR/.unhealthy" "no session-wide unhealthy marker"
  assert_no_file "$DUET_DIR/blocked/kimi-1" \
    "one ambiguous observation blocked a live recipient"
  assert_eq 1 "$(active_count "$kimi_box")" \
    "ambiguous message left its queue before submission was confirmed"
  assert_eq 1 "$(delivered_count "$DUET_DIR/inbox/codex-1")" \
    "healthy peer advances despite another recipient's ambiguity"

  duet_deliverd_pass || fail "ambiguous resume pass failed"
  assert_no_file "$DUET_DIR/blocked/kimi-1" "second ambiguity blocked too early"
  assert_contains "$DUET_DIR/deliverd.log" "will resume enter-only" \
    "resume was not surfaced in the daemon log"
  if ! awk -F '\t' '$2 == "kimi-1" { n++; if (n > 1 && $4 != "1") bad = 1 }
      END { exit bad }' "$FAKE_LOG"; then
    fail "ambiguous head was repasted instead of resumed enter-only"
  fi

  duet_deliverd_pass || fail "ambiguous terminal pass failed"
  assert_file "$DUET_DIR/blocked/kimi-1" "unresolved ambiguity was never fenced"
  assert_contains "$DUET_DIR/blocked/kimi-1" \
    "submission unconfirmed after 3 enter-only resumes" \
    "bounded ambiguity reason"
  assert_eq 1 "$(active_count "$kimi_box")" \
    "blocked recipient did not retain its head for diagnosis"
}

# The ordinary case the old policy could never reach: the pane was simply busy,
# the next pass observes the composer clear, and the message is delivered.
test_ambiguous_delivery_resolves_on_resume(){
  local kimi_box
  create_state ambiguous-resolves
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=""
  FAKE_AMBIGUOUS_TARGET=kimi-1
  FAKE_AMBIGUOUS_REMAINING=2
  enqueue_one kimi-1 slow-peer-body
  kimi_box="$DUET_DIR/inbox/kimi-1"

  duet_deliverd_pass || fail "resolve pass 1 failed"
  duet_deliverd_pass || fail "resolve pass 2 failed"
  assert_no_file "$DUET_DIR/blocked/kimi-1" "busy peer was blocked while resuming"
  duet_deliverd_pass || fail "resolve pass 3 failed"

  assert_eq 1 "$(delivered_count "$kimi_box")" \
    "resumed message was never delivered"
  assert_eq 0 "$(active_count "$kimi_box")" "delivered message stayed queued"
  assert_no_file "$DUET_DIR/blocked/kimi-1" "resolved ambiguity still blocked"
  assert_eq 3 "$(awk -F '\t' '$2 == "kimi-1"' "$FAKE_LOG" | wc -l | tr -d ' ')" \
    "unexpected number of delivery attempts"
  if ! awk -F '\t' '$2 == "kimi-1" { n++; if (n == 1 && $4 != "") bad = 1 }
      END { exit bad }' "$FAKE_LOG"; then
    fail "first attempt should paste, not resume"
  fi
}

# Clearing the block file must also clear the in-process counters that produced
# it, or a resumed recipient is re-fenced by its own history.
test_operator_resume_restores_delivery(){
  local kimi_box
  local DUET_AMBIGUOUS_LIMIT=1
  create_state operator-resume
  FAKE_LOG="$DUET_DIR/fake.log"
  : > "$FAKE_LOG"
  FAKE_STALLED_TARGET=""
  FAKE_AMBIGUOUS_TARGET=kimi-1
  FAKE_AMBIGUOUS_REMAINING=""
  enqueue_one kimi-1 blocked-body
  kimi_box="$DUET_DIR/inbox/kimi-1"

  duet_deliverd_pass || fail "resume setup pass failed"
  assert_file "$DUET_DIR/blocked/kimi-1" "recipient was not fenced at bound 1"

  duet_deliverd_pass || fail "pass over a blocked recipient failed"
  assert_eq 0 "$(delivered_count "$kimi_box")" \
    "blocked recipient was still delivered to"

  # The operator clears the block; the peer is healthy again.
  rm -f "$DUET_DIR/blocked/kimi-1"
  FAKE_AMBIGUOUS_TARGET=""
  duet_deliverd_pass || fail "post-resume pass failed"
  assert_eq 1 "$(delivered_count "$kimi_box")" \
    "resumed recipient did not receive its queued head"
  assert_contains "$DUET_DIR/deliverd.log" \
    "resuming recipient kimi-1 after operator unblock" \
    "resume was not surfaced in the daemon log"
  # The head had already landed, so the resumed attempt must not repaste.
  if ! awk -F '\t' '$2 == "kimi-1" { n++; if (n > 1 && $4 != "1") bad = 1 }
      END { exit bad }' "$FAKE_LOG"; then
    fail "resumed head was repasted instead of continued enter-only"
  fi
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

run_case 'paste markers are exact and cursor-row scoped' \
  test_marker_cursor_scope
run_case 'verified send pastes once and retries Enter only' \
  test_verified_send_fsm
run_case 'resume only submits a composer it recognizes' \
  test_resume_refuses_foreign_composer
run_case 'failed head preserves FIFO without blocking peers' \
  test_failed_head_is_fair_and_fifo
run_case 'persistent pre-landing stall blocks only its recipient' \
  test_persistent_stall_blocks_only_recipient
run_case 'post-paste ambiguity resumes enter-only before blocking' \
  test_ambiguous_delivery_resumes_before_blocking
run_case 'post-paste ambiguity resolves when the peer was only busy' \
  test_ambiguous_delivery_resolves_on_resume
run_case 'operator resume restores delivery to a fenced recipient' \
  test_operator_resume_restores_delivery
run_case '50 concurrent enqueues preserve FIFO and dedupe IDs' \
  test_concurrent_fifo_and_dedupe

if [ "$FAILURES" -eq 0 ]; then
  printf '==== ALL V4 M1 DELIVERY TESTS PASS ====\n'
  exit 0
fi
printf '==== %s V4 M1 ASSERTION(S) FAILED ====\n' "$FAILURES" >&2
exit 1
