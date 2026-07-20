#!/usr/bin/env bash
# Deterministic M3 failover, fencing, and session-isolation tests.
#
# The suite owns two isolated tmux servers whose panes run plain Bash only. It
# never starts Claude, Codex, or Kimi; never addresses the default tmux server;
# and never reads or writes ~/.duet/current.
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
COMMON_SCRIPT="$SCRIPTS_DIR/duet-common.sh"
DELIVERD_SCRIPT="$SCRIPTS_DIR/duet-deliverd.sh"
SEND_SCRIPT="$SCRIPTS_DIR/duet-send.sh"
STATUS_SCRIPT="$SCRIPTS_DIR/duet-status.sh"
DOCTOR_SCRIPT="$SCRIPTS_DIR/duet-doctor.sh"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)" || exit 1
TEST_ROOT="$(mktemp -d "$TMP_BASE/duet-m3-failover.XXXXXX")" || exit 1
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1
STATE_ROOT="$TEST_ROOT/state"
WORK_ROOT="$TEST_ROOT/work"
TMUX_LABEL_A="duet-m3-a-$PPID-${RANDOM:-0}"
TMUX_LABEL_B="duet-m3-b-$PPID-${RANDOM:-0}"
TMUX_SESSION_A=m3a
TMUX_SESSION_B=m3b
TMUX_SOCKET_A=""
TMUX_SOCKET_B=""
FAKE_DAEMON_PIDS=""
FAILURES=0
CURRENT_CASE=setup

mkdir -p "$STATE_ROOT" "$WORK_ROOT/a" "$WORK_ROOT/b"

fail(){
  FAILURES=$((FAILURES + 1))
  printf '  FAIL [%s] %s\n' "$CURRENT_CASE" "$*" >&2
}

assert_eq(){
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] \
    || fail "$label: expected '$expected', got '$actual'"
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

active_message_count(){
  local box="$1" file count=0
  for file in "$box"/N-*.msg "$box"/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

field(){
  awk -F '\t' -v key="$2" '$1 == key { sub(/^[^\t]*\t/, ""); print; exit }' \
    "$1" 2>/dev/null
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

cleanup(){
  local pid
  for pid in $FAKE_DAEMON_PIDS; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    kill -TERM "$pid" 2>/dev/null || true
  done
  command tmux -L "$TMUX_LABEL_A" kill-server >/dev/null 2>&1 || true
  command tmux -L "$TMUX_LABEL_B" kill-server >/dev/null 2>&1 || true
  case "$TMUX_SOCKET_A" in */tmux-*/"$TMUX_LABEL_A") rm -f -- "$TMUX_SOCKET_A";; esac
  case "$TMUX_SOCKET_B" in */tmux-*/"$TMUX_LABEL_B") rm -f -- "$TMUX_SOCKET_B";; esac
  case "$TEST_ROOT" in
    "$TMP_BASE"/duet-m3-failover.*) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'duet m3 test: refused unsafe cleanup path %s\n' "$TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

if ! command -v tmux >/dev/null 2>&1; then
  printf 'SKIP: tmux is not installed\n'
  exit 0
fi

if ! command tmux -L "$TMUX_LABEL_A" -f /dev/null new-session -d \
    -s "$TMUX_SESSION_A" -c "$WORK_ROOT/a" 'exec /bin/bash --noprofile --norc'; then
  printf 'FAIL: could not start isolated tmux server A\n' >&2
  exit 1
fi
if ! command tmux -L "$TMUX_LABEL_B" -f /dev/null new-session -d \
    -s "$TMUX_SESSION_B" -c "$WORK_ROOT/b" 'exec /bin/bash --noprofile --norc'; then
  printf 'FAIL: could not start isolated tmux server B\n' >&2
  exit 1
fi

A_INIT_PANE="$(command tmux -L "$TMUX_LABEL_A" display-message -p \
  -t "$TMUX_SESSION_A" '#{pane_id}')"
A_CODEX_PANE="$(command tmux -L "$TMUX_LABEL_A" split-window -d -P \
  -F '#{pane_id}' -t "$TMUX_SESSION_A" 'exec /bin/bash --noprofile --norc')"
A_KIMI_PANE="$(command tmux -L "$TMUX_LABEL_A" split-window -d -P \
  -F '#{pane_id}' -t "$TMUX_SESSION_A" 'exec /bin/bash --noprofile --norc')"
A_INIT_PID="$(command tmux -L "$TMUX_LABEL_A" display-message -p \
  -t "$A_INIT_PANE" '#{pane_pid}')"
A_CODEX_PID="$(command tmux -L "$TMUX_LABEL_A" display-message -p \
  -t "$A_CODEX_PANE" '#{pane_pid}')"
A_KIMI_PID="$(command tmux -L "$TMUX_LABEL_A" display-message -p \
  -t "$A_KIMI_PANE" '#{pane_pid}')"
TMUX_SOCKET_A="$(command tmux -L "$TMUX_LABEL_A" display-message -p '#{socket_path}')"
TMUX_SERVER_PID_A="$(command tmux -L "$TMUX_LABEL_A" display-message -p '#{pid}')"

B_INIT_PANE="$(command tmux -L "$TMUX_LABEL_B" display-message -p \
  -t "$TMUX_SESSION_B" '#{pane_id}')"
B_INIT_PID="$(command tmux -L "$TMUX_LABEL_B" display-message -p \
  -t "$B_INIT_PANE" '#{pane_pid}')"
TMUX_SOCKET_B="$(command tmux -L "$TMUX_LABEL_B" display-message -p '#{socket_path}')"
TMUX_SERVER_PID_B="$(command tmux -L "$TMUX_LABEL_B" display-message -p '#{pid}')"

# shellcheck disable=SC1090
. "$COMMON_SCRIPT"
# shellcheck disable=SC1090
. "$DELIVERD_SCRIPT"

write_config(){
  local config="$1"
  {
    printf 'DUET_DIR=%q\n' "$DUET_DIR"
    printf 'DUET_STATE_ROOT=%q\n' "$DUET_STATE_ROOT"
    printf 'WORKDIR=%q\n' "$WORKDIR"
    printf 'PLUGIN_DIR=%q\n' "$PLUGIN_DIR"
    printf 'DUET_TMUX_SOCKET=%q\n' "$DUET_TMUX_SOCKET"
    printf 'DUET_TMUX_SERVER_PID=%q\n' "$DUET_TMUX_SERVER_PID"
    printf 'DUET_SESSION_ID=%q\n' "$DUET_SESSION_ID"
    printf 'DUET_SESSION=%q\n' "$DUET_SESSION_ID"
    printf 'DUET_WORKDIR_KEY=%q\n' "$DUET_WORKDIR_KEY"
    printf 'DUET_INITIATOR=%q\n' claude
    printf 'DUET_INITIATOR_PANE=%q\n' "$A_INIT_PANE"
  } > "$config"
}

create_state(){
  local name="$1" queue
  DUET_DIR="$STATE_ROOT/$name"
  DUET_SESSION_ID="$name"
  DUET_SESSION="$name"
  DUET_STATE_ROOT="$STATE_ROOT"
  WORKDIR="$WORK_ROOT/a/$name"
  DUET_TMUX_SOCKET="$TMUX_SOCKET_A"
  DUET_TMUX_SERVER_PID="$TMUX_SERVER_PID_A"
  mkdir -p "$DUET_DIR" "$WORKDIR"
  DUET_WORKDIR_KEY="$(duet_workdir_key "$WORKDIR")" || {
    fail "could not derive fixture workdir key"
    return 1
  }
  mkdir -p "$DUET_STATE_ROOT/workdirs"
  duet_atomic_write "$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.active" \
    "$DUET_DIR" || {
      fail "could not register fixture workdir owner"
      return 1
    }
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
    printf 'claude\tclaude\t%s\t%s\t0\t0\n' "$A_INIT_PANE" "$A_INIT_PID"
    printf 'codex-1\tcodex\t%s\t%s\t1\t1\n' "$A_CODEX_PANE" "$A_CODEX_PID"
    printf 'kimi-1\tkimi\t%s\t%s\t2\t1\n' "$A_KIMI_PANE" "$A_KIMI_PID"
  } > "$DUET_DIR/roster.tsv"
  CURRENT_CONFIG="$DUET_DIR/duet.env"
  write_config "$CURRENT_CONFIG"
  export DUET_DIR DUET_SESSION_ID DUET_SESSION DUET_STATE_ROOT WORKDIR PLUGIN_DIR
  export DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID DUET_WORKDIR_KEY
}

# Unit tests keep enqueue, parsing, terminal moves, locks, and scheduler code
# real, replacing only daemon liveness and pane injection.
FAKE_LOG="$TEST_ROOT/fake.log"
FAKE_RC=0
FAKE_ENTER_RC=0
FAKE_ENTER_CLEAR=""
FAKE_LANDING_OBSERVED=""
FAKE_ENTER_OBSERVED=""
FAKE_ENTER_TOKEN=""
FAKE_FOREIGN_MARKER=""
FAKE_CLEAR_RC=0
FAKE_CLEAR_OBSERVED=1
duet_daemon_alive(){ return 0; }
duet_send_verified(){
  DUET_SEND_LANDING_OBSERVED="$FAKE_LANDING_OBSERVED"
  DUET_SEND_ENTER_TOKEN="$FAKE_ENTER_TOKEN"
  printf 'FULL\t%s\t%s\t%s\t%s\n' "$DUET_MESSAGE_ID" \
    "$DUET_TARGET_NAME" "$DUET_TARGET_PANE" "$DUET_MESSAGE_MODE" >> "$FAKE_LOG"
  return "$FAKE_RC"
}
duet_send_enter_only(){
  DUET_SEND_COMPOSER_CLEAR="$FAKE_ENTER_CLEAR"
  DUET_SEND_LANDING_OBSERVED="$FAKE_ENTER_OBSERVED"
  DUET_SEND_ENTER_TOKEN="$FAKE_ENTER_TOKEN"
  if [ -n "$FAKE_FOREIGN_MARKER" ]; then
    printf 'FOREIGN_MARKER\t%s\n' "$DUET_MESSAGE_ID" >> "$FAKE_LOG"
    return "$DUET_SEND_LANDED_UNVERIFIED"
  fi
  printf 'ENTER\t%s\t%s\t%s\t%s\n' "$DUET_MESSAGE_ID" \
    "$DUET_TARGET_NAME" "$DUET_TARGET_PANE" "$DUET_CURRENT_TERM" >> "$FAKE_LOG"
  return "$FAKE_ENTER_RC"
}
duet_clear_refused_composer(){
  DUET_SEND_COMPOSER_CLEAR="$FAKE_CLEAR_OBSERVED"
  printf 'CLEAR\t%s\t%s\t%s\n' "$DUET_MESSAGE_ID" \
    "$DUET_TARGET_NAME" "$DUET_TARGET_PANE" >> "$FAKE_LOG"
  return "$FAKE_CLEAR_RC"
}

stage_message(){
  local queue="$1" sender="$2" recipient="$3" term="$4"
  local origin="$5" leader_at_send="$6" body="$7" mode="${8:-NORMAL}"
  local dedupe="${9:-}"
  duet_enqueue_message "$queue" "$sender" "$recipient" "$term" "$mode" \
    "$origin" "$leader_at_send" "$body" "$dedupe" || return 1
  STAGED_FILE="$DUET_ENQUEUED_FILE"
  STAGED_ID="$DUET_ENQUEUED_ID"
}

test_codex_collapsed_composer(){
  local result="$TEST_ROOT/codex-marker.result" log="$TEST_ROOT/codex-marker.log"
  local state="$TEST_ROOT/codex-marker.state" wedge="$TEST_ROOT/codex-marker.wedge"
  local foreign_on_escape="$TEST_ROOT/codex-marker.foreign-on-escape"
  : > "$log"
  printf 'blank\n' > "$state"
  (
    # Re-source to restore the production verifier inside this isolated model.
    # shellcheck disable=SC1090
    . "$COMMON_SCRIPT"
    sleep(){ :; }
    _duet_alive(){ return 0; }
    _duet_tmux(){
      local command_name="${1:-}" current
      current="$(cat "$state")"
      case "$command_name" in
        capture-pane)
          case "$current" in
            blank)
              printf 'history\n› [Pasted Content 2048 chars]\n\n\n\n› \nstatus\n\n\n\n'
              ;;
            marker)
              printf 'history\n› [Pasted Content 2048 chars]\n\n\n\n› [Pasted Content 2048 chars]\nstatus\n\n\n\n'
              ;;
            wedged-one)
              printf 'history\naccepted\n\n\n\n› [Pasted Content 2048 chars]\nstatus\n\n\n\n'
              ;;
            wedged-two|wedged-escaped)
              printf 'history\naccepted\n\n\n\n› [Pasted Content 2048 chars] [Pasted Content 2048 chars]\nstatus\n\n\n\n'
              ;;
            foreign)
              printf 'history\naccepted\n\n\n\n› [Pasted Content 999 chars]\nstatus\n\n\n\n'
              ;;
            cleared)
              printf 'history\naccepted\n\n\n\n› \nstatus\n\n\n\n'
              ;;
            submitted)
              printf 'history\n› [Pasted Content 2048 chars]\naccepted\n\n\n\n\n› \nstatus\n\n'
              ;;
          esac
          ;;
        display-message)
          case "$current" in
            blank|marker|wedged-one|wedged-two|wedged-escaped|foreign|cleared) printf '5\n' ;;
            submitted) printf '7\n' ;;
          esac
          ;;
        load-buffer) command cat >/dev/null ;;
        paste-buffer)
          printf 'PASTE\n' >> "$log"
          if [ -f "$wedge" ]; then
            printf 'wedged-one\n' > "$state"
          else
            printf 'marker\n' > "$state"
          fi
          ;;
        send-keys)
          case "${*: -1}" in
            Enter)
              printf 'ENTER\n' >> "$log"
              case "$current" in
                marker) printf 'submitted\n' > "$state" ;;
                wedged-one) printf 'wedged-two\n' > "$state" ;;
              esac
              ;;
            Escape)
              printf 'ESCAPE\n' >> "$log"
              if [ "$current" = wedged-two ]; then
                if [ -f "$foreign_on_escape" ]; then
                  printf 'foreign\n' > "$state"
                else
                  printf 'wedged-escaped\n' > "$state"
                fi
              fi
              ;;
            C-u)
              printf 'CTRL_U\n' >> "$log"
              [ "$current" != wedged-escaped ] || printf 'cleared\n' > "$state"
              ;;
          esac
          ;;
        delete-buffer) : ;;
        *) return 0 ;;
      esac
    }

    if duet_send_verified '%0' 'long payload with a distinctive verifier tail' '' codex; then
      rc=0
    else
      rc=$?
    fi
    printf 'rc=%s\ntoken=%s\nafter=%s\nfirst_pastes=%s\nfirst_enters=%s\n' \
      "$rc" "${DUET_SEND_ENTER_TOKEN:-}" "$(_duet_paste_marker '%0')" \
      "$(grep -c '^PASTE$' "$log" 2>/dev/null || true)" \
      "$(grep -c '^ENTER$' "$log" 2>/dev/null || true)" > "$result"

    : > "$log"
    printf 'marker\n' > "$state"
    if duet_send_enter_only '%0' 'long payload with a distinctive verifier tail' \
        codexPastedContent2048chars; then
      enter_rc=0
    else
      enter_rc=$?
    fi
    printf 'enter_rc=%s\nenter_only_enters=%s\nenter_only_pastes=%s\n' "$enter_rc" \
      "$(grep -c '^ENTER$' "$log" 2>/dev/null || true)" \
      "$(grep -c '^PASTE$' "$log" 2>/dev/null || true)" >> "$result"

    # An evidence-less INFLIGHT recovery must not adopt a collapsed marker
    # merely because it is current. It may belong to unrelated user input.
    : > "$log"
    printf 'marker\n' > "$state"
    if duet_send_enter_only '%0' 'different payload whose probe is absent' '' 1; then
      foreign_rc=0
    else
      foreign_rc=$?
    fi
    printf 'foreign_rc=%s\nforeign_observed=%s\nforeign_enters=%s\n' \
      "$foreign_rc" "${DUET_SEND_LANDING_OBSERVED:-}" \
      "$(grep -c '^ENTER$' "$log" 2>/dev/null || true)" >> "$result"

    # A marker present before this delivery is foreign composer state.  The
    # verifier neither pastes onto it nor lets the clear helper adopt it.
    : > "$log"
    printf 'marker\n' > "$state"
    if duet_send_verified '%0' 'payload must not join a foreign marker' '' codex; then
      occupied_rc=0
    else
      occupied_rc=$?
    fi
    if duet_clear_refused_composer '%0' codexPastedContent4096chars; then
      foreign_clear_rc=0
    else
      foreign_clear_rc=$?
    fi
    printf 'occupied_rc=%s\noccupied_pastes=%s\nforeign_clear_rc=%s\nforeign_clear_keys=%s\n' \
      "$occupied_rc" "$(grep -c '^PASTE$' "$log" 2>/dev/null || true)" \
      "$foreign_clear_rc" \
      "$(grep -Ec '^(ESCAPE|CTRL_U)$' "$log" 2>/dev/null || true)" >> "$result"

    # Model the live incident: one paste first renders one collapsed marker,
    # then a second placeholder appears while Enter remains refused.  The
    # verifier must not mistake the token change for accepted history.
    : > "$log"
    : > "$wedge"
    printf 'blank\n' > "$state"
    if duet_send_verified '%0' 'wedged payload with a distinctive verifier tail' '' codex; then
      wedge_rc=0
    else
      wedge_rc=$?
    fi
    wedge_token="${DUET_SEND_ENTER_TOKEN:-}"
    if duet_clear_refused_composer '%0' "$wedge_token"; then
      clear_rc=0
    else
      clear_rc=$?
    fi
    printf 'wedge_rc=%s\nwedge_token=%s\nwedge_pastes=%s\nwedge_enters=%s\n' \
      "$wedge_rc" "$wedge_token" \
      "$(grep -c '^PASTE$' "$log" 2>/dev/null || true)" \
      "$(grep -c '^ENTER$' "$log" 2>/dev/null || true)" >> "$result"
    printf 'clear_rc=%s\nescapes=%s\nctrl_us=%s\ncleared_marker=%s\n' \
      "$clear_rc" "$(grep -c '^ESCAPE$' "$log" 2>/dev/null || true)" \
      "$(grep -c '^CTRL_U$' "$log" 2>/dev/null || true)" \
      "$(_duet_paste_marker '%0')" >> "$result"

    # Escape is not a proof that ownership persisted. If it exposes a foreign
    # marker, recovery must stop before the destructive Ctrl-U key.
    : > "$log"
    : > "$foreign_on_escape"
    printf 'wedged-two\n' > "$state"
    if duet_clear_refused_composer '%0' "$wedge_token"; then
      foreign_escape_rc=0
    else
      foreign_escape_rc=$?
    fi
    rm -f "$foreign_on_escape"
    printf 'foreign_escape_rc=%s\nforeign_escape_keys=%s\nforeign_ctrl_us=%s\nforeign_after=%s\n' \
      "$foreign_escape_rc" \
      "$(grep -c '^ESCAPE$' "$log" 2>/dev/null || true)" \
      "$(grep -c '^CTRL_U$' "$log" 2>/dev/null || true)" \
      "$(_duet_paste_marker '%0')" >> "$result"
  )

  assert_contains "$result" 'rc=0' "collapsed composer submits successfully"
  assert_contains "$result" 'token=codexPastedContent2048chars' \
    "Codex marker becomes the persisted Enter token"
  assert_eq '' "$(sed -n 's/^after=//p' "$result")" \
    "accepted historical marker is ignored"
  assert_contains "$result" 'first_pastes=1' "full delivery pastes exactly once"
  assert_contains "$result" 'first_enters=1' "full delivery submits exactly once"
  assert_contains "$result" 'enter_rc=0' "Enter-only continuation recognizes Codex marker"
  assert_contains "$result" "foreign_rc=$DUET_SEND_LANDED_UNVERIFIED" \
    "foreign collapsed marker remains unresolved"
  assert_eq '' "$(sed -n 's/^foreign_observed=//p' "$result")" \
    "foreign collapsed marker never becomes landing evidence"
  assert_contains "$result" 'foreign_enters=0' \
    "foreign collapsed marker is never submitted"
  assert_contains "$result" "occupied_rc=$DUET_SEND_NOT_LANDED" \
    "pre-existing collapsed composer is a safe no-paste outcome"
  assert_contains "$result" 'occupied_pastes=0' \
    "full verifier never pastes onto a pre-existing marker"
  assert_contains "$result" "foreign_clear_rc=$DUET_SEND_LANDED_UNVERIFIED" \
    "clear helper rejects a foreign marker capability"
  assert_contains "$result" 'foreign_clear_keys=0' \
    "clear helper never sends keys to a foreign marker"
  assert_contains "$result" 'enter_only_pastes=0' \
    "Enter-only continuation never repastes"
  assert_contains "$result" 'enter_only_enters=1' \
    "Enter-only continuation presses Enter once"
  assert_contains "$result" "wedge_rc=$DUET_SEND_COMPOSER_REFUSED" \
    "late second marker is a distinct refused-composer outcome"
  assert_contains "$result" \
    'wedge_token=codexPastedContent2048charsPastedContent2048chars' \
    "late second marker extends the causally observed capability"
  assert_contains "$result" 'wedge_pastes=1' \
    "refused-composer detection never repastes"
  assert_contains "$result" 'wedge_enters=3' \
    "refused-composer classification follows bounded Enter retries"
  assert_contains "$result" 'clear_rc=0' \
    "owned refused composer clears successfully"
  assert_contains "$result" 'escapes=1' "clear recovery sends one Escape"
  assert_contains "$result" 'ctrl_us=1' "clear recovery sends one Ctrl-U"
  assert_eq '' "$(sed -n 's/^cleared_marker=//p' "$result")" \
    "clear recovery verifies the marker left the active composer"
  assert_contains "$result" \
    "foreign_escape_rc=$DUET_SEND_LANDED_UNVERIFIED" \
    "ownership change after Escape remains unresolved"
  assert_contains "$result" 'foreign_escape_keys=1' \
    "foreign-after-Escape fixture sends Escape once"
  assert_contains "$result" 'foreign_ctrl_us=0' \
    "ownership change after Escape receives no Ctrl-U"
  assert_contains "$result" 'foreign_after=codexPastedContent999chars' \
    "foreign composer survives recovery untouched"
}

test_refused_composer_clear_requeue(){
  local message message_id terminal rc
  create_state refused-clear-requeue
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  FAKE_RC=$DUET_SEND_COMPOSER_REFUSED
  FAKE_LANDING_OBSERVED=marker
  FAKE_ENTER_TOKEN=codexPastedContent2048charsPastedContent2048chars
  FAKE_CLEAR_RC=$DUET_SEND_LANDED_UNVERIFIED
  FAKE_CLEAR_OBSERVED=""

  stage_message codex-1 claude codex-1 0 LEADER claude \
    'stable-id assignment whose collapsed composer refuses Enter' \
    || { fail "could not stage refused-composer message"; return; }
  message="$STAGED_FILE"
  message_id="$STAGED_ID"
  duet_deliverd_pass || { fail "refused-composer pass failed"; return; }
  assert_eq CLEAR_RETRY "$(cat "$message.phase" 2>/dev/null || true)" \
    "refused composer enters durable clear/retry phase"
  assert_eq "$FAKE_ENTER_TOKEN" "$(cat "$message.enter_token" 2>/dev/null || true)" \
    "clear/retry persists exact marker capability"
  assert_eq marker "$(cat "$message.landing_observed" 2>/dev/null || true)" \
    "clear/retry persists causal marker evidence"
  assert_eq 1 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "initial refused delivery pastes exactly once"
  assert_eq 0 "$(grep -c '^CLEAR' "$FAKE_LOG" 2>/dev/null || true)" \
    "recovery keys wait until CLEAR_RETRY is durable"

  if duet_promote_locked 0 claude SOFT; then rc=0; else rc=$?; fi
  assert_eq 11 "$rc" "CLEAR_RETRY blocks promotion CAS"
  duet_atomic_write "$message.retry_at" 0 || fail "could not make failed clear due"
  duet_deliverd_pass || { fail "failed clear-recovery pass failed"; return; }
  assert_eq CLEAR_RETRY "$(cat "$message.phase" 2>/dev/null || true)" \
    "unverified clear remains pane-owning"
  assert_eq 1 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "uncleared composer never repastes"
  assert_eq 1 "$(grep -c '^CLEAR' "$FAKE_LOG" 2>/dev/null || true)" \
    "clear recovery is attempted without a full paste"

  FAKE_CLEAR_RC=0
  FAKE_CLEAR_OBSERVED=1
  duet_atomic_write "$message.retry_at" 0 || fail "could not make successful clear due"
  duet_deliverd_pass || { fail "successful clear-recovery pass failed"; return; }
  assert_eq READY "$(cat "$message.phase" 2>/dev/null || true)" \
    "verified empty composer requeues the message"
  assert_eq "$message_id" "$(field "$message" id)" \
    "clear/requeue preserves the stable message ID"
  assert_no_file "$message.enter_token" "READY requeue drops old marker capability"
  assert_eq 1 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "clear pass itself never repastes"

  FAKE_RC=0
  FAKE_LANDING_OBSERVED=""
  FAKE_ENTER_TOKEN=""
  duet_atomic_write "$message.retry_at" 0 || fail "could not make safe requeue due"
  duet_deliverd_pass || { fail "safe full-retry pass failed"; return; }
  terminal="$DUET_DIR/inbox/codex-1/delivered/$(basename "$message")"
  assert_file "$terminal" "same stable-ID message delivers after verified clear"
  assert_eq "$message_id" "$(field "$terminal" id)" \
    "terminal delivery retains the stable message ID"
  assert_eq 2 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "one full retry occurs only after verified clear"

  FAKE_RC=0
  FAKE_LANDING_OBSERVED=""
  FAKE_ENTER_TOKEN=""
  FAKE_CLEAR_RC=0
  FAKE_CLEAR_OBSERVED=1
}

test_clear_retry_raw_cas_poison(){
  local owner newer rc candidate
  create_state clear-retry-raw-cas
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  duet_write_leader_state 1 codex-1 || { fail "could not promote fixture leader"; return; }
  duet_watchdog_write 1 codex-1 0 || fail "could not stage fixture watchdog"
  FAKE_RC=$DUET_SEND_COMPOSER_REFUSED
  FAKE_LANDING_OBSERVED=marker
  FAKE_ENTER_TOKEN=codexPastedContent2048charsPastedContent2048chars

  stage_message leader kimi-1 leader 1 WORKER codex-1 \
    'worker reply owns the current Codex leader composer' \
    || { fail "could not stage symbolic refused-composer message"; return; }
  owner="$STAGED_FILE"
  duet_deliverd_pass || { fail "symbolic refused-composer pass failed"; return; }
  assert_eq CLEAR_RETRY "$(cat "$owner.phase" 2>/dev/null || true)" \
    "symbolic Codex owner enters CLEAR_RETRY"

  # Model the documented-unsafe raw leader edit.  The worker-origin message
  # is not a stale leader assignment, so its durable physical binding is the
  # only thing preventing the old pane from being released.
  duet_write_leader_state 2 kimi-1 || { fail "could not stage raw leader edit"; return; }
  duet_watchdog_write 2 kimi-1 0 || fail "could not stage raw-edit watchdog"
  duet_candidate_target leader "$owner" || fail "could not resolve owner candidate"
  candidate="$DUET_CANDIDATE_NAME:$DUET_CANDIDATE_PANE"
  assert_eq "codex-1:$A_CODEX_PANE" "$candidate" \
    "scheduler coalesces poison owner by its original physical pane"

  stage_message codex-1 kimi-1 codex-1 2 LEADER kimi-1 \
    'new-term traffic must wait behind the old pane owner' \
    || { fail "could not stage new-term traffic"; return; }
  newer="$STAGED_FILE"
  duet_atomic_write "$owner.retry_at" 0 || fail "could not make poison owner due"
  duet_deliverd_pass || { fail "raw-CAS poison pass failed"; return; }
  assert_file "$owner" "raw target change retains CLEAR_RETRY root"
  assert_eq CLEAR_RETRY "$(cat "$owner.phase" 2>/dev/null || true)" \
    "raw target change remains clear/retry poison"
  assert_no_file "$DUET_DIR/inbox/leader/quarantine/$(basename "$owner")" \
    "raw target change never terminalizes uncertain ownership"
  assert_file "$newer" "new-term traffic waits behind old physical pane owner"
  assert_eq 1 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "no later paste reaches the poison-owned pane"
  if duet_promote_locked 2 kimi-1 SOFT; then rc=0; else rc=$?; fi
  assert_eq 11 "$rc" "raw-CAS CLEAR_RETRY continues to block later promotion"

  FAKE_RC=0
  FAKE_LANDING_OBSERVED=""
  FAKE_ENTER_TOKEN=""
}

test_promotion_cas_exclusion_no_successor(){
  local rc
  create_state promotion-cas
  : > "$FAKE_LOG"

  if duet_promote_locked 0 claude HARD; then rc=0; else rc=$?; fi
  assert_eq 0 "$rc" "first promotion succeeds"
  duet_read_leader_state || { fail "could not read first promoted state"; return; }
  assert_eq 1 "$DUET_CURRENT_TERM" "first promotion term"
  assert_eq codex-1 "$DUET_CURRENT_LEADER" "rank-one successor"
  assert_file "$DUET_DIR/failed-leaders/claude" "failed incumbent exclusion"
  assert_file "$DUET_PROMOTION_FILE" "durable promotion intent"
  assert_eq 0 "$(cat "$DUET_PROMOTION_FILE.prior_term" 2>/dev/null || true)" \
    "promotion intent prior term"
  assert_eq 1 "$(cat "$DUET_PROMOTION_FILE.promotion_term" 2>/dev/null || true)" \
    "promotion intent target term"

  if duet_promote_locked 0 claude HARD; then rc=0; else rc=$?; fi
  assert_eq 2 "$rc" "stale promotion CAS is rejected"
  duet_read_leader_state || return
  assert_eq 1 "$DUET_CURRENT_TERM" "stale CAS does not increment term"

  if duet_promote_locked 1 codex-1 HARD; then rc=0; else rc=$?; fi
  assert_eq 0 "$rc" "second promotion succeeds"
  duet_read_leader_state || return
  assert_eq kimi-1 "$DUET_CURRENT_LEADER" \
    "failed rank-zero incumbent is never re-elected"
  assert_file "$DUET_DIR/failed-leaders/codex-1" "second incumbent exclusion"

  if duet_promote_locked 2 kimi-1 HARD; then rc=0; else rc=$?; fi
  assert_eq 10 "$rc" "no-live-successor outcome"
  duet_read_leader_state || return
  assert_eq 3 "$DUET_CURRENT_TERM" "terminal term increments once"
  assert_eq NONE "$DUET_CURRENT_LEADER" "terminal leader is NONE"
  assert_file "$DUET_DIR/no-successor" "durable no-successor marker"
  assert_eq 3 "$(field "$DUET_DIR/no-successor" term)" "no-successor term"
}

test_force_rejected_and_manual_eligible_target(){
  local rc leader_before watchdog_before counter_before output
  create_state force-rejected || return

  if duet_promote_locked 0 claude HARD; then rc=0; else rc=$?; fi
  assert_eq 0 "$rc" "initial failure promotes to rank-one successor"
  assert_file "$DUET_DIR/failed-leaders/claude" \
    "initial failed leader is automatically excluded"
  leader_before="$(cat "$DUET_DIR/leader")"
  watchdog_before="$(cat "$DUET_DIR/watchdog")"
  counter_before="$(cat "$DUET_DIR/inbox/promotions/.counter")"

  if duet_promote_locked 1 codex-1 MANUAL claude 1; then rc=0; else rc=$?; fi
  assert_eq 3 "$rc" "internal force bypass is rejected"
  assert_eq "$leader_before" "$(cat "$DUET_DIR/leader")" \
    "rejected internal force leaves leader state unchanged"
  assert_eq "$watchdog_before" "$(cat "$DUET_DIR/watchdog")" \
    "rejected internal force leaves watchdog unchanged"
  assert_eq "$counter_before" "$(cat "$DUET_DIR/inbox/promotions/.counter")" \
    "rejected internal force publishes no promotion"
  assert_file "$DUET_DIR/failed-leaders/claude" \
    "rejected internal force preserves permanent exclusion"
  assert_no_file "$DUET_DIR/failed-leaders/codex-1" \
    "rejected internal force does not exclude incumbent"

  output="$TEST_ROOT/force-rejected.out"
  if DUET_CONFIG="$CURRENT_CONFIG" bash "$SCRIPTS_DIR/duet-promote.sh" \
      --session "$CURRENT_CONFIG" --to claude --force > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 2 "$rc" "CLI rejects removed --force option"
  assert_contains "$output" 'force is not supported' \
    "CLI force refusal is actionable"
  assert_eq "$leader_before" "$(cat "$DUET_DIR/leader")" \
    "CLI force refusal leaves leader state unchanged"
  assert_eq "$counter_before" "$(cat "$DUET_DIR/inbox/promotions/.counter")" \
    "CLI force refusal publishes no promotion"

  if duet_promote_locked 1 codex-1 MANUAL kimi-1; then rc=0; else rc=$?; fi
  assert_eq 0 "$rc" "ordinary manual --to accepts an eligible member"
  duet_read_leader_state || return
  assert_eq 2 "$DUET_CURRENT_TERM" "ordinary manual promotion advances term"
  assert_eq kimi-1 "$DUET_CURRENT_LEADER" \
    "ordinary manual promotion selects requested eligible target"
}

test_promotion_dedupe_target_mismatch(){
  local existing counter_before rc
  create_state promotion-dedupe-mismatch || return
  stage_message promotions duet-system codex-1 1 SYSTEM codex-1 \
    'preexisting term-one promotion intent' NORMAL promotion-1 \
    || { fail "could not stage existing promotion intent"; return; }
  existing="$STAGED_FILE"
  counter_before="$(cat "$DUET_DIR/inbox/promotions/.counter" 2>/dev/null || true)"

  # A manual retry for the same old CAS must not commit to a different target
  # around the deduplicated durable notice addressed to codex-1.
  if duet_promote_locked 0 claude MANUAL kimi-1; then rc=0; else rc=$?; fi
  assert_eq 4 "$rc" "deduplicated promotion target mismatch is rejected"
  assert_eq '0:claude' \
    "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "mismatched manual target does not commit its leader CAS"
  assert_eq "$counter_before" \
    "$(cat "$DUET_DIR/inbox/promotions/.counter" 2>/dev/null || true)" \
    "mismatched retry does not publish a second promotion"
  assert_eq 1 "$(active_message_count "$DUET_DIR/inbox/promotions")" \
    "original promotion remains the sole durable obligation"
  duet_read_message "$existing" || { fail "existing promotion became unreadable"; return; }
  assert_eq codex-1 "$DUET_MESSAGE_RECIPIENT" \
    "dedupe mismatch cannot retarget the existing notice"

  # The daemon can still complete the original crash-safe intent; its target,
  # not the rejected manual request, wins the recovered CAS.
  duet_reconcile_promotion_intents \
    || { fail "original promotion could not recover after mismatch"; return; }
  assert_eq '1:codex-1' \
    "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "reconciliation commits only the original promotion target"
}

test_promotion_reconciliation(){
  local intent base before
  create_state promotion-reconcile
  stage_message promotions duet-system codex-1 1 SYSTEM codex-1 \
    'recover this promotion' NORMAL promotion-1 \
    || { fail "could not stage promotion intent"; return; }
  intent="$STAGED_FILE"
  duet_atomic_write "$intent.prior_term" 0 || fail "could not stage prior term"
  duet_atomic_write "$intent.failed" claude || fail "could not stage failed incumbent"
  duet_atomic_write "$intent.reason" RECOVERY || fail "could not stage reason"
  duet_atomic_write "$intent.promotion_term" 1 || fail "could not stage promotion term"

  duet_reconcile_promotion_intents || { fail "promotion intent reconciliation failed"; return; }
  duet_read_leader_state || return
  assert_eq 1 "$DUET_CURRENT_TERM" "recovered promotion term"
  assert_eq codex-1 "$DUET_CURRENT_LEADER" "recovered successor"
  assert_file "$DUET_DIR/failed-leaders/claude" "recovery persists incumbent exclusion"
  assert_file "$intent" "reconciled intent remains due for delivery"
  before="$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)"
  duet_reconcile_promotion_intents || fail "repeat promotion reconciliation failed"
  assert_eq "$before" "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "promotion reconciliation is idempotent"

  create_state no-successor-reconcile
  base="$DUET_DIR/no-successor"
  duet_atomic_write "$base" "$(printf 'session\t%s\nfrom_term\t0\nterm\t1\nfailed\tclaude\nreason\tRECOVERY' \
    "$DUET_SESSION_ID")" || { fail "could not stage no-successor intent"; return; }
  duet_reconcile_no_successor || { fail "no-successor reconciliation failed"; return; }
  duet_read_leader_state || return
  assert_eq 1 "$DUET_CURRENT_TERM" "recovered terminal term"
  assert_eq NONE "$DUET_CURRENT_LEADER" "recovered terminal leader"
  duet_reconcile_no_successor || fail "repeat no-successor reconciliation failed"
  assert_eq '1:NONE' "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "no-successor reconciliation is idempotent"
}

test_terminal_move_reconciliation(){
  local metadata_active metadata_terminal intent_active intent_terminal
  local moved_active moved_terminal
  create_state terminal-move-reconcile || return

  # Crash after the immutable root reaches a terminal directory but before its
  # durable promotion metadata and mutable delivery state are moved/cleared.
  stage_message promotions duet-system codex-1 1 SYSTEM codex-1 \
    'terminal metadata recovery' NORMAL promotion-1 \
    || { fail "could not stage metadata fixture"; return; }
  metadata_active="$STAGED_FILE"
  metadata_terminal="$DUET_DIR/inbox/promotions/delivered/$(basename "$metadata_active")"
  duet_atomic_write "$metadata_active.prior_term" 0 || fail "could not stage prior term"
  duet_atomic_write "$metadata_active.failed" claude || fail "could not stage failed leader"
  duet_atomic_write "$metadata_active.reason" HARD || fail "could not stage failure reason"
  duet_atomic_write "$metadata_active.promotion_term" 1 \
    || fail "could not stage promotion term"
  duet_atomic_write "$metadata_active.phase" INFLIGHT || fail "could not stage phase"
  duet_atomic_write "$metadata_active.tries" 2 || fail "could not stage tries"
  duet_atomic_write "$metadata_active.target_name" codex-1 \
    || fail "could not stage target name"
  mv "$metadata_active" "$metadata_terminal" \
    || { fail "could not simulate terminal root move"; return; }

  # Crash after persisting quarantine intent but before moving the root.
  stage_message codex-1 claude codex-1 0 LEADER claude \
    'quarantine before root move' || { fail "could not stage quarantine intent"; return; }
  intent_active="$STAGED_FILE"
  intent_terminal="$DUET_DIR/inbox/codex-1/quarantine/$(basename "$intent_active")"
  duet_atomic_write "$intent_active.quarantine_reason" foreign-session \
    || fail "could not stage quarantine intent reason"
  duet_atomic_write "$intent_active.phase" INFLIGHT || fail "could not stage intent phase"
  duet_atomic_write "$intent_active.target_pane" "$A_CODEX_PANE" \
    || fail "could not stage intent target pane"

  # Crash after moving the root but before moving/finalizing its quarantine
  # intent. This covers the complementary half of the terminal metadata gap.
  stage_message kimi-1 claude kimi-1 0 LEADER claude \
    'quarantine after root move' || { fail "could not stage moved quarantine"; return; }
  moved_active="$STAGED_FILE"
  moved_terminal="$DUET_DIR/inbox/kimi-1/quarantine/$(basename "$moved_active")"
  duet_atomic_write "$moved_active.quarantine_reason" missing-session \
    || fail "could not stage moved quarantine reason"
  duet_atomic_write "$moved_active.retry_at" 99 || fail "could not stage retry state"
  mv "$moved_active" "$moved_terminal" \
    || { fail "could not simulate quarantine root move"; return; }

  duet_reconcile_terminal_moves \
    || { fail "terminal move reconciliation failed"; return; }

  assert_file "$metadata_terminal" "terminal metadata immutable root"
  assert_eq 0 "$(cat "$metadata_terminal.prior_term" 2>/dev/null || true)" \
    "terminal prior term recovered"
  assert_eq claude "$(cat "$metadata_terminal.failed" 2>/dev/null || true)" \
    "terminal failed leader recovered"
  assert_eq HARD "$(cat "$metadata_terminal.reason" 2>/dev/null || true)" \
    "terminal failure reason recovered"
  assert_eq 1 "$(cat "$metadata_terminal.promotion_term" 2>/dev/null || true)" \
    "terminal promotion term recovered"
  assert_no_file "$metadata_active.prior_term" "active prior-term sidecar removed"
  assert_no_file "$metadata_active.failed" "active failed sidecar removed"
  assert_no_file "$metadata_active.reason" "active reason sidecar removed"
  assert_no_file "$metadata_active.promotion_term" "active promotion sidecar removed"
  assert_no_file "$metadata_active.phase" "orphaned delivery phase cleared"
  assert_no_file "$metadata_active.tries" "orphaned retry count cleared"
  assert_no_file "$metadata_active.target_name" "orphaned target cleared"

  assert_file "$intent_terminal" "pre-move quarantine intent completed"
  assert_eq foreign-session "$(cat "$intent_terminal.reason" 2>/dev/null || true)" \
    "pre-move quarantine reason finalized"
  assert_no_file "$intent_terminal.quarantine_reason" \
    "pre-move quarantine intent consumed"
  assert_no_file "$intent_active.phase" "pre-move mutable phase cleared"
  assert_no_file "$intent_active.target_pane" "pre-move target pane cleared"

  assert_file "$moved_terminal" "post-move quarantine immutable root"
  assert_eq missing-session "$(cat "$moved_terminal.reason" 2>/dev/null || true)" \
    "post-move quarantine reason finalized"
  assert_no_file "$moved_terminal.quarantine_reason" \
    "post-move quarantine intent consumed"
  assert_no_file "$moved_active.quarantine_reason" \
    "post-move active intent sidecar removed"
  assert_no_file "$moved_active.retry_at" "post-move mutable retry cleared"

  duet_reconcile_terminal_moves || fail "repeat terminal move reconciliation failed"
  assert_eq foreign-session "$(cat "$intent_terminal.reason" 2>/dev/null || true)" \
    "terminal move reconciliation is idempotent"
}

test_promotion_intent_crash_windows(){
  local intent

  # The message root is durable before its promotion sidecars. Recover all
  # derivable metadata, the exclusion marker, leader CAS, and watchdog.
  create_state promotion-missing-sidecars || return
  stage_message promotions duet-system codex-1 1 SYSTEM codex-1 \
    'recover promotion without sidecars' NORMAL promotion-1 \
    || { fail "could not stage sidecar-free promotion"; return; }
  intent="$STAGED_FILE"
  duet_reconcile_promotion_intents \
    || { fail "sidecar-free promotion reconciliation failed"; return; }
  assert_eq 0 "$(cat "$intent.prior_term" 2>/dev/null || true)" \
    "missing prior term reconstructed"
  assert_eq claude "$(cat "$intent.failed" 2>/dev/null || true)" \
    "missing failed leader reconstructed"
  assert_eq RECOVERY "$(cat "$intent.reason" 2>/dev/null || true)" \
    "missing recovery reason reconstructed"
  assert_eq 1 "$(cat "$intent.promotion_term" 2>/dev/null || true)" \
    "missing promotion term reconstructed"
  assert_eq '1:codex-1' "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "sidecar-free promotion completes leader CAS"
  assert_file "$DUET_DIR/failed-leaders/claude" \
    "sidecar-free promotion excludes failed incumbent"
  assert_eq "$DUET_SESSION_ID" "$(field "$DUET_DIR/watchdog" session)" \
    "sidecar-free promotion watchdog session"
  assert_eq '1:codex-1:0' \
    "$(field "$DUET_DIR/watchdog" term):$(field "$DUET_DIR/watchdog" leader):$(field "$DUET_DIR/watchdog" count)" \
    "sidecar-free promotion initializes watchdog"

  # Crash after the leader CAS but before the next-term watchdog write. A
  # stale prior-term watchdog models the state left by a normally running M2.
  create_state promotion-cas-before-watchdog || return
  stage_message promotions duet-system codex-1 1 SYSTEM codex-1 \
    'recover promotion watchdog after CAS' NORMAL promotion-1 \
    || { fail "could not stage post-CAS promotion"; return; }
  intent="$STAGED_FILE"
  duet_atomic_write "$intent.prior_term" 0 || fail "could not stage post-CAS prior term"
  duet_atomic_write "$intent.failed" claude || fail "could not stage post-CAS failed leader"
  duet_atomic_write "$intent.reason" HARD || fail "could not stage post-CAS reason"
  duet_atomic_write "$intent.promotion_term" 1 \
    || fail "could not stage post-CAS promotion term"
  duet_mark_failed_leader claude 0 HARD || fail "could not stage failed incumbent"
  duet_watchdog_write 0 claude 2 || fail "could not stage stale watchdog"
  duet_write_leader_state 1 codex-1 || fail "could not stage completed leader CAS"

  duet_reconcile_promotion_intents \
    || { fail "post-CAS watchdog reconciliation failed"; return; }
  assert_eq '1:codex-1' "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "post-CAS recovery does not advance leadership twice"
  assert_eq "$DUET_SESSION_ID" "$(field "$DUET_DIR/watchdog" session)" \
    "post-CAS watchdog session repaired"
  assert_eq '1:codex-1:0' \
    "$(field "$DUET_DIR/watchdog" term):$(field "$DUET_DIR/watchdog" leader):$(field "$DUET_DIR/watchdog" count)" \
    "post-CAS watchdog is repaired to promoted term"
  duet_reconcile_promotion_intents || fail "repeat post-CAS reconciliation failed"
  assert_eq '1:codex-1' "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "post-CAS recovery is idempotent"
}

test_no_successor_cas_before_watchdog(){
  local journal
  create_state no-successor-cas-before-watchdog || return
  journal="$DUET_DIR/no-successor"
  duet_atomic_write "$journal" "$(printf 'session\t%s\nfrom_term\t0\nterm\t1\nfailed\tclaude\nreason\tHARD' \
    "$DUET_SESSION_ID")" || { fail "could not stage no-successor journal"; return; }
  duet_mark_failed_leader claude 0 HARD || fail "could not stage terminal exclusion"
  duet_watchdog_write 0 claude 3 || fail "could not stage terminal stale watchdog"
  duet_write_leader_state 1 NONE || fail "could not stage terminal leader CAS"

  duet_reconcile_no_successor \
    || { fail "post-CAS no-successor reconciliation failed"; return; }
  assert_eq '1:NONE' "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "no-successor recovery preserves terminal leadership"
  assert_eq "$DUET_SESSION_ID" "$(field "$DUET_DIR/watchdog" session)" \
    "no-successor watchdog session repaired"
  assert_eq '1:NONE:0' \
    "$(field "$DUET_DIR/watchdog" term):$(field "$DUET_DIR/watchdog" leader):$(field "$DUET_DIR/watchdog" count)" \
    "no-successor watchdog is repaired after leader CAS"
  assert_file "$journal" "no-successor journal remains durable"
  assert_file "$DUET_DIR/failed-leaders/claude" \
    "no-successor recovery preserves incumbent exclusion"
  duet_reconcile_no_successor || fail "repeat post-CAS no-successor reconciliation failed"
  assert_eq '1:NONE:0' \
    "$(field "$DUET_DIR/watchdog" term):$(field "$DUET_DIR/watchdog" leader):$(field "$DUET_DIR/watchdog" count)" \
    "post-CAS no-successor recovery is idempotent"
}

test_watchdog_counter_and_soft_promotion(){
  create_state watchdog-soft
  duet_watchdog_failure 0 claude || fail "first watchdog failure write"
  duet_watchdog_failure 0 claude || fail "second watchdog failure write"
  duet_watchdog_count 0 claude || fail "watchdog count read"
  assert_eq 2 "$DUET_WATCHDOG_COUNT" "two failures do not yet promote"
  duet_watchdog_write 0 claude 0 || fail "watchdog success reset"
  duet_watchdog_count 0 claude || fail "watchdog reset read"
  assert_eq 0 "$DUET_WATCHDOG_COUNT" "successful leader delivery resets failures"
  duet_watchdog_failure 0 claude || fail "soft failure one"
  duet_watchdog_failure 0 claude || fail "soft failure two"
  duet_watchdog_failure 0 claude || fail "soft failure three"
  duet_watchdog_check || { fail "soft watchdog promotion failed"; return; }
  duet_read_leader_state || return
  assert_eq 1 "$DUET_CURRENT_TERM" "third consecutive failure promotes"
  assert_eq codex-1 "$DUET_CURRENT_LEADER" "soft promotion successor"
  assert_contains "$DUET_DIR/failed-leaders/claude" $'reason\tSOFT' \
    "soft incumbent exclusion reason"
}

test_delivery_watchdog_integration(){
  local message
  create_state delivery-watchdog
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  FAKE_RC=$DUET_SEND_NOT_LANDED
  stage_message leader codex-1 leader 0 WORKER claude 'leader failure probe' \
    || { fail "could not stage leader failure probe"; return; }
  message="$STAGED_FILE"

  duet_deliverd_pass || { fail "first failed delivery pass"; return; }
  duet_watchdog_count 0 claude || fail "first integrated watchdog count"
  assert_eq 1 "$DUET_WATCHDOG_COUNT" "leader verifier failure increments watchdog"
  duet_atomic_write "$message.retry_at" 0 || fail "could not make retry due"
  duet_deliverd_pass || { fail "second failed delivery pass"; return; }
  duet_watchdog_count 0 claude || fail "second integrated watchdog count"
  assert_eq 2 "$DUET_WATCHDOG_COUNT" "second leader failure increments watchdog"

  FAKE_RC=0
  duet_atomic_write "$message.retry_at" 0 || fail "could not make success retry due"
  duet_deliverd_pass || { fail "successful leader delivery pass"; return; }
  duet_watchdog_count 0 claude || fail "integrated watchdog reset read"
  assert_eq 0 "$DUET_WATCHDOG_COUNT" "leader delivery success resets watchdog"
}

test_partial_inflight_binding_recovery(){
  local message terminal
  create_state partial-inflight-binding || return
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  FAKE_RC=$DUET_SEND_NOT_LANDED
  stage_message codex-1 claude codex-1 0 LEADER claude \
    'resume only after a proven safe outcome' \
    || { fail "could not stage partial-binding message"; return; }
  message="$STAGED_FILE"

  # Model a daemon crash while clearing the durable binding after a prior
  # NOT_LANDED/DEAD result: INFLIGHT remains, but one binding sidecar is gone.
  duet_atomic_write "$message.phase" INFLIGHT || fail "could not stage INFLIGHT phase"
  duet_atomic_write "$message.target_name" codex-1 || fail "could not stage bound name"
  duet_atomic_write "$message.target_term" 0 || fail "could not stage bound term"
  assert_no_file "$message.target_pane" "partial binding omits pane sidecar"

  duet_process_one "$DUET_DIR/inbox/codex-1" "$message" \
    || { fail "partial INFLIGHT recovery failed"; FAKE_RC=0; return; }
  assert_file "$message" "safe verifier outcome keeps message retryable"
  assert_eq READY "$(cat "$message.phase" 2>/dev/null || true)" \
    "partial INFLIGHT binding normalizes to READY"
  assert_eq 1 "$(cat "$message.tries" 2>/dev/null || true)" \
    "safe retry records one NOT_LANDED attempt"
  assert_no_file "$message.target_name" "safe outcome clears recovered target name"
  assert_no_file "$message.target_pane" "safe outcome clears recovered target pane"
  assert_no_file "$message.target_term" "safe outcome clears recovered target term"
  assert_eq 1 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "recovered message makes one full verifier attempt"
  assert_contains "$FAKE_LOG" $'\tcodex-1\t' \
    "recovered message re-resolves its intended recipient"
  terminal="$DUET_DIR/inbox/codex-1/quarantine/$(basename "$message")"
  assert_no_file "$terminal" "safe partial binding is not quarantined"
  FAKE_RC=0
}

test_term_fencing_and_worker_reroute(){
  local stale stale_terminal reply
  create_state term-fence
  duet_write_leader_state 1 codex-1 || { fail "could not stage promoted state"; return; }
  duet_watchdog_write 1 codex-1 0 || fail "could not stage promoted watchdog"
  : > "$FAKE_LOG"

  stage_message codex-1 claude codex-1 0 LEADER claude \
    'stale assignment must not land' || { fail "could not stage stale assignment"; return; }
  stale="$STAGED_FILE"
  duet_process_one "$DUET_DIR/inbox/codex-1" || fail "stale-term processing failed"
  stale_terminal="$DUET_DIR/inbox/codex-1/quarantine/$(basename "$stale")"
  assert_file "$stale_terminal" "stale leader assignment quarantine"
  assert_eq 0 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "stale leader assignment never reaches verifier"

  stage_message leader kimi-1 leader 0 WORKER claude \
    'old-term worker reply survives promotion' || { fail "could not stage worker reply"; return; }
  reply="$STAGED_FILE"
  duet_process_one "$DUET_DIR/inbox/leader" || fail "old-term worker reply processing failed"
  assert_file "$DUET_DIR/inbox/leader/delivered/$(basename "$reply")" \
    "old-term worker reply reroutes to new leader"
  assert_contains "$FAKE_LOG" $'\tcodex-1\t' "worker reply resolves to promoted leader pane"
}

test_uncertain_composer_blocks_promotion_cas(){
  local uncertain uncertain_id promotion promotion_id first_full rc
  create_state uncertain-before-promotion
  : > "$FAKE_LOG"
  DUET_DELIVERY_RETRY_BASE=0
  FAKE_RC=0
  FAKE_ENTER_RC=$DUET_SEND_LANDED_UNVERIFIED
  FAKE_ENTER_CLEAR=1
  FAKE_ENTER_OBSERVED=""

  # The old leader's paste owns codex-1's composer when the soft watchdog
  # fires. The original paste-buffer succeeded without a verified landing, so
  # later probe absence alone is not positive evidence that the composer is
  # clean. The term must remain old until a verified continuation resolves.
  stage_message codex-1 claude codex-1 0 LEADER claude \
    'possibly landed old-term assignment' \
    || { fail "could not stage uncertain assignment"; return; }
  uncertain="$STAGED_FILE"
  uncertain_id="$STAGED_ID"
  duet_atomic_write "$uncertain.target_name" codex-1 \
    || fail "could not bind uncertain target name"
  duet_atomic_write "$uncertain.target_pane" "$A_CODEX_PANE" \
    || fail "could not bind uncertain target pane"
  duet_atomic_write "$uncertain.target_term" 0 \
    || fail "could not bind uncertain target term"
  assert_no_file "$uncertain.enter_token" \
    "unobserved landing has no durable marker token"
  duet_atomic_write "$uncertain.phase" ENTER_ONLY \
    || fail "could not persist uncertain phase"
  duet_atomic_write "$uncertain.retry_at" 0 \
    || fail "could not make uncertain continuation due"
  duet_watchdog_write 0 claude 3 || fail "could not arm soft watchdog"

  if duet_promote_locked 0 claude SOFT; then rc=0; else rc=$?; fi
  assert_eq 11 "$rc" "direct promotion reports the uncertain-composer fence"
  assert_eq '0:claude' \
    "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "promotion CAS is deferred before any stale term exists"
  assert_no_file "$DUET_DIR/failed-leaders/claude" \
    "deferred promotion does not exclude the incumbent"

  duet_deliverd_pass \
    || { fail "dirty-composer watchdog pass failed"; return; }
  assert_eq '0:claude' \
    "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "unobserved landing keeps leadership on the old term despite probe absence"
  assert_file "$uncertain" \
    "unobserved composer remains a durable active obligation"
  assert_eq ENTER_ONLY "$(cat "$uncertain.phase" 2>/dev/null || true)" \
    "unobserved composer retains Enter-only phase"
  assert_no_file "$DUET_DIR/inbox/codex-1/quarantine/$(basename "$uncertain")" \
    "probe absence without landing evidence is not terminalized"
  assert_eq 0 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "no promotion or ordinary payload is pasted while composer is dirty"

  # A later verified Enter clears/submits the old assignment while term zero
  # is still authoritative. The post-attempt watchdog may then CAS term one.
  FAKE_ENTER_RC=0
  FAKE_ENTER_CLEAR=""
  duet_atomic_write "$uncertain.retry_at" 0 \
    || fail "could not retry uncertain continuation"
  duet_deliverd_pass \
    || { fail "resolved-composer watchdog pass failed"; return; }
  assert_file "$DUET_DIR/inbox/codex-1/delivered/$(basename "$uncertain")" \
    "resolved old-term assignment reaches a terminal delivery state"
  assert_eq 0 "$(awk -F '\t' -v id="$uncertain_id" \
    '$1 == "ENTER" && $2 == id { print $5; exit }' "$FAKE_LOG")" \
    "old assignment is submitted only while its original term is current"
  assert_eq '1:codex-1' \
    "$(field "$DUET_DIR/leader" term):$(field "$DUET_DIR/leader" leader)" \
    "watchdog promotes only after composer resolution"
  promotion="$(find "$DUET_DIR/inbox/promotions" -maxdepth 1 -name 'N-*.msg' -print -quit)"
  assert_file "$promotion" "promotion notice is queued after the guarded CAS"
  promotion_id="$(field "$promotion" id)"
  assert_eq 0 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "promotion notice waits for the next rebuilt scheduler pass"

  duet_deliverd_pass \
    || { fail "post-composer promotion pass failed"; return; }
  first_full="$(awk -F '\t' '$1 == "FULL" { print $2; exit }' "$FAKE_LOG")"
  assert_eq "$promotion_id" "$first_full" \
    "promotion notice is the first new payload after composer resolution"
  FAKE_ENTER_RC=0
  FAKE_ENTER_CLEAR=""
  FAKE_ENTER_OBSERVED=""
}

test_inflight_owner_precedes_newer_interrupt(){
  local owner owner_id interrupt interrupt_id first_operation rc
  create_state inflight-before-interrupt
  : > "$FAKE_LOG"
  FAKE_RC=0
  FAKE_ENTER_CLEAR=""
  FAKE_ENTER_OBSERVED=""
  FAKE_FOREIGN_MARKER=1

  stage_message codex-1 claude codex-1 0 LEADER claude \
    'crash-window composer owner' \
    || { fail "could not stage INFLIGHT owner"; return; }
  owner="$STAGED_FILE"
  owner_id="$STAGED_ID"
  duet_atomic_write "$owner.target_name" codex-1 || fail "could not bind owner name"
  duet_atomic_write "$owner.target_pane" "$A_CODEX_PANE" || fail "could not bind owner pane"
  duet_atomic_write "$owner.target_term" 0 || fail "could not bind owner term"
  duet_atomic_write "$owner.phase" INFLIGHT || fail "could not stage INFLIGHT phase"

  stage_message codex-1 claude codex-1 0 LEADER claude \
    'newer urgent redirect' INTERRUPT \
    || { fail "could not stage newer interrupt"; return; }
  interrupt="$STAGED_FILE"
  interrupt_id="$STAGED_ID"

  duet_deliverd_pass || { fail "INFLIGHT foreign-marker pass failed"; return; }
  assert_file "$owner" \
    "evidence-less INFLIGHT owner remains active beside a foreign marker"
  assert_eq ENTER_ONLY "$(cat "$owner.phase" 2>/dev/null || true)" \
    "evidence-less INFLIGHT normalizes to a poisoned Enter-only obligation"
  assert_no_file "$DUET_DIR/inbox/codex-1/delivered/$(basename "$owner")" \
    "foreign marker cannot terminalize the INFLIGHT owner"
  assert_eq 0 "$(grep -c '^ENTER' "$FAKE_LOG" 2>/dev/null || true)" \
    "foreign collapsed marker is never submitted"
  assert_eq 0 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "evidence-less INFLIGHT recovery never repastes"
  assert_file "$interrupt" "newer interrupt waits behind poisoned ownership"
  if duet_promote_locked 0 claude SOFT; then rc=0; else rc=$?; fi
  assert_eq 11 "$rc" "poisoned INFLIGHT recovery continues to fence promotion"

  FAKE_FOREIGN_MARKER=""
  FAKE_ENTER_RC=0
  duet_atomic_write "$owner.retry_at" 0 || fail "could not retry INFLIGHT owner"
  : > "$FAKE_LOG"
  duet_deliverd_pass || { fail "INFLIGHT ownership pass failed"; return; }
  first_operation="$(awk -F '\t' 'NF { print $1 ":" $2; exit }' "$FAKE_LOG")"
  assert_eq "ENTER:$owner_id" "$first_operation" \
    "INFLIGHT composer owner gets a no-repaste continuation first"
  assert_eq 0 "$(awk -F '\t' -v id="$owner_id" \
    '$1 == "FULL" && $2 == id { n++ } END { print n + 0 }' "$FAKE_LOG")" \
    "complete INFLIGHT recovery never repastes the possible owner"
  assert_file "$DUET_DIR/inbox/codex-1/delivered/$(basename "$owner")" \
    "INFLIGHT owner resolves first"
  assert_file "$interrupt" "newer interrupt waits behind INFLIGHT ownership"
  assert_eq 0 "$(awk -F '\t' -v id="$interrupt_id" \
    '$2 == id { n++ } END { print n + 0 }' "$FAKE_LOG")" \
    "newer interrupt cannot paste onto a possible prior composer"
  FAKE_FOREIGN_MARKER=""
}

test_marker_evidence_without_token_stays_poisoned(){
  local owner rc
  create_state marker-evidence-without-token
  : > "$FAKE_LOG"
  FAKE_RC=0
  FAKE_ENTER_RC=$DUET_SEND_LANDED_UNVERIFIED
  FAKE_ENTER_CLEAR=1
  FAKE_ENTER_OBSERVED=""
  FAKE_FOREIGN_MARKER=1

  stage_message codex-1 claude codex-1 0 LEADER claude \
    'collapsed marker crash window' \
    || { fail "could not stage marker crash-window owner"; return; }
  owner="$STAGED_FILE"
  duet_atomic_write "$owner.target_name" codex-1 || fail "could not bind marker owner name"
  duet_atomic_write "$owner.target_pane" "$A_CODEX_PANE" || fail "could not bind marker owner pane"
  duet_atomic_write "$owner.target_term" 0 || fail "could not bind marker owner term"
  duet_atomic_write "$owner.phase" INFLIGHT || fail "could not stage marker INFLIGHT phase"
  # Model the old unsafe publication order: marker-kind evidence reached disk,
  # then the daemon crashed before publishing the exact marker token.
  duet_atomic_write "$owner.landing_observed" marker \
    || fail "could not stage marker-only landing evidence"
  assert_no_file "$owner.enter_token" "marker crash window omits exact token"

  duet_deliverd_pass || { fail "marker-without-token pass failed"; return; }
  assert_file "$owner" "marker evidence without a token remains active"
  assert_eq ENTER_ONLY "$(cat "$owner.phase" 2>/dev/null || true)" \
    "marker-only evidence becomes a poisoned Enter-only obligation"
  assert_no_file "$owner.enter_token" "foreign marker is never adopted as this message's token"
  assert_eq 0 "$(grep -c '^ENTER' "$FAKE_LOG" 2>/dev/null || true)" \
    "marker evidence without an exact token never presses Enter"
  assert_eq 0 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "marker evidence without an exact token never repastes"
  assert_no_file "$DUET_DIR/inbox/codex-1/delivered/$(basename "$owner")" \
    "marker-only crash state is not delivered"
  assert_no_file "$DUET_DIR/inbox/codex-1/quarantine/$(basename "$owner")" \
    "apparent composer absence cannot terminalize marker-only crash state"
  if duet_promote_locked 0 claude SOFT; then rc=0; else rc=$?; fi
  assert_eq 11 "$rc" "marker-only crash state continues to fence promotion"

  FAKE_ENTER_RC=0
  FAKE_ENTER_CLEAR=""
  FAKE_FOREIGN_MARKER=""
}

test_foreign_payload_quarantine(){
  local original staged terminal notice counter_before malicious
  create_state foreign-payload
  : > "$FAKE_LOG"
  malicious='NEVER-ECHO-FOREIGN-BODY'
  stage_message codex-1 claude codex-1 0 LEADER claude "$malicious" \
    || { fail "could not stage foreign payload"; return; }
  original="$STAGED_FILE"
  staged="$DUET_DIR/inbox/codex-1/.foreign.test"
  awk -F '\t' 'BEGIN { OFS="\t" } $1 == "session" { $2="other-session" } { print }' \
    "$original" > "$staged"
  mv "$staged" "$original"

  duet_process_one "$DUET_DIR/inbox/codex-1" || fail "foreign payload processing failed"
  terminal="$DUET_DIR/inbox/codex-1/quarantine/$(basename "$original")"
  if [ ! -f "$terminal" ]; then
    fail "foreign payload was not quarantined"
    return
  fi
  assert_eq 0 "$(grep -c '^FULL' "$FAKE_LOG" 2>/dev/null || true)" \
    "foreign payload never reaches verifier"
  assert_contains "$terminal.reason" foreign-session "foreign quarantine reason"
  duet_reconcile_foreign_notices || { fail "foreign notice reconciliation failed"; return; }
  assert_file "$terminal.noticed" "durable foreign notice obligation"
  notice="$(find "$DUET_DIR/inbox/leader" -maxdepth 1 -name 'N-*.msg' -print -quit)"
  if [ -z "$notice" ]; then
    fail "foreign payload did not queue a leader notice"
    return
  fi
  duet_read_message "$notice" || { fail "foreign notice is not parseable"; return; }
  case "$DUET_MESSAGE_BODY" in
    *"$malicious"*) fail "foreign notice echoed untrusted body" ;;
  esac
  case "$DUET_MESSAGE_BODY" in
    *foreign-session*) : ;;
    *) fail "foreign notice omits the sanitized reason" ;;
  esac
  counter_before="$(cat "$DUET_DIR/inbox/leader/.counter")"
  duet_reconcile_foreign_notices || fail "repeat foreign notice reconciliation failed"
  assert_eq "$counter_before" "$(cat "$DUET_DIR/inbox/leader/.counter")" \
    "foreign notice reconciliation is deduplicated"
}

test_pane_coalescing_and_promotion_priority(){
  local promotion promotion_id concrete symbolic other codex_calls first_codex_id
  create_state pane-coalesce
  : > "$FAKE_LOG"
  FAKE_RC=0
  duet_promote_locked 0 claude HARD || { fail "could not stage promotion"; return; }
  promotion="$DUET_PROMOTION_FILE"
  promotion_id="$(field "$promotion" id)"
  stage_message codex-1 duet-system codex-1 1 SYSTEM codex-1 \
    'ordinary concrete traffic' || { fail "could not stage concrete traffic"; return; }
  concrete="$STAGED_FILE"
  stage_message leader kimi-1 leader 0 WORKER claude \
    'pending symbolic reply' || { fail "could not stage symbolic traffic"; return; }
  symbolic="$STAGED_FILE"
  stage_message kimi-1 duet-system kimi-1 1 SYSTEM codex-1 \
    'independent recipient traffic' || { fail "could not stage independent traffic"; return; }
  other="$STAGED_FILE"

  duet_deliverd_pass || { fail "coalesced scheduler pass failed"; return; }
  codex_calls="$(awk -F '\t' '$1 == "FULL" && $3 == "codex-1" { n++ } END { print n + 0 }' \
    "$FAKE_LOG")"
  first_codex_id="$(awk -F '\t' '$1 == "FULL" && $3 == "codex-1" { print $2; exit }' \
    "$FAKE_LOG")"
  assert_eq 1 "$codex_calls" "one bounded attempt per resolved pane per pass"
  assert_eq "$promotion_id" "$first_codex_id" "promotion notice is strictly first"
  assert_file "$DUET_DIR/inbox/promotions/delivered/$(basename "$promotion")" \
    "promotion notice delivered"
  assert_file "$concrete" "concrete traffic waits behind promotion"
  assert_file "$symbolic" "symbolic traffic waits behind promotion"
  assert_file "$DUET_DIR/inbox/kimi-1/delivered/$(basename "$other")" \
    "independent pane advances during promotion pass"
}

write_membership_state(){
  local name="$1" socket="$2" server_pid="$3" pane="$4" pane_pid="$5" work="$6"
  local dir="$STATE_ROOT/$name" config="$STATE_ROOT/$name/duet.env"
  mkdir -p "$dir/inbox/claude/delivered" "$dir/inbox/claude/failed" \
    "$dir/inbox/claude/quarantine" "$dir/inbox/claude/superseded" \
    "$dir/inbox/leader/delivered" "$dir/inbox/leader/failed" \
    "$dir/inbox/leader/quarantine" "$dir/inbox/leader/superseded"
  : > "$dir/transcript.md"
  printf 'term\t0\nleader\tclaude\n' > "$dir/leader"
  {
    printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n'
    printf 'claude\tclaude\t%s\t%s\t0\t0\n' "$pane" "$pane_pid"
  } > "$dir/roster.tsv"
  {
    printf 'DUET_DIR=%q\n' "$dir"
    printf 'DUET_STATE_ROOT=%q\n' "$STATE_ROOT"
    printf 'WORKDIR=%q\n' "$work"
    printf 'PLUGIN_DIR=%q\n' "$PLUGIN_DIR"
    printf 'DUET_TMUX_SOCKET=%q\n' "$socket"
    printf 'DUET_TMUX_SERVER_PID=%q\n' "$server_pid"
    printf 'DUET_SESSION_ID=%q\n' "$name"
    printf 'DUET_SESSION=%q\n' "$name"
    printf 'DUET_INITIATOR=%q\n' claude
    printf 'DUET_INITIATOR_PANE=%q\n' "$pane"
  } > "$config"
  printf '%s' "$config"
}

start_fake_daemon(){
  local dir="$1" helper="$TEST_ROOT/fixture-duet-deliverd.sh" pid session_id
  if [ ! -f "$helper" ]; then
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf '%s\n' "trap 'exit 0' INT TERM"
      printf '%s\n' 'while :; do sleep 1; done'
    } > "$helper"
    chmod +x "$helper"
  fi
  session_id="$(basename "$dir")"
  bash "$helper" --session "$dir/duet.env" --session-id "$session_id" \
    >/dev/null 2>&1 &
  pid=$!
  FAKE_DAEMON_PIDS="$FAKE_DAEMON_PIDS $pid"
  printf '%s\n' "$pid" > "$dir/daemon.pid"
  printf '%s\tfixture\n' "$pid" > "$dir/.daemon.lock"
  STARTED_FAKE_DAEMON_PID="$pid"
}

test_status_and_doctor_healthy_fixture(){
  local name status_output doctor_output daemon_pid status_rc doctor_rc
  create_state diagnostic-healthy || return
  mkdir -p "$DUET_DIR/ready"
  for name in claude codex-1 kimi-1; do
    duet_atomic_write "$DUET_DIR/ready/$name" ready \
      || fail "could not stage readiness for $name"
  done
  duet_watchdog_write 0 claude 0 || fail "could not stage healthy watchdog"
  assert_eq "$DUET_DIR" \
    "$(cat "$DUET_STATE_ROOT/workdirs/$DUET_WORKDIR_KEY.active" 2>/dev/null || true)" \
    "diagnostic fixture owns its active workdir registry"
  start_fake_daemon "$DUET_DIR"
  daemon_pid="$STARTED_FAKE_DAEMON_PID"
  sleep 0.1

  status_output="$TEST_ROOT/status-healthy.out"
  if env -u DUET_CONFIG -u DUET_SESSION -u TMUX -u TMUX_PANE -u DUET_SELF \
      DUET_STATE_ROOT="$DUET_STATE_ROOT" \
      bash "$STATUS_SCRIPT" --session "$CURRENT_CONFIG" \
      > "$status_output" 2>&1; then
    status_rc=0
  else
    status_rc=$?
  fi
  assert_eq 0 "$status_rc" "healthy status exits successfully"
  assert_contains "$status_output" "session       : $DUET_SESSION_ID" \
    "status reports pinned session"
  assert_contains "$status_output" 'workdir fence : owned key=' \
    "status reports owned workdir fence"
  assert_contains "$status_output" 'leadership    : term=0 leader=claude' \
    "status reports healthy leadership"
  assert_contains "$status_output" 'daemon        : alive pid=' \
    "status reports live daemon"
  assert_contains "$status_output" 'watchdog      : count=0 term=0 leader=claude' \
    "status reports synchronized watchdog"

  doctor_output="$TEST_ROOT/doctor-healthy.out"
  if env -u DUET_CONFIG -u DUET_SESSION -u TMUX -u TMUX_PANE -u DUET_SELF \
      DUET_STATE_ROOT="$DUET_STATE_ROOT" \
      bash "$DOCTOR_SCRIPT" --session "$CURRENT_CONFIG" \
      > "$doctor_output" 2>&1; then
    doctor_rc=0
  else
    doctor_rc=$?
  fi
  assert_eq 0 "$doctor_rc" "healthy doctor exits successfully"
  assert_contains "$doctor_output" 'ok   : tmux server identity' \
    "doctor validates isolated tmux identity"
  assert_contains "$doctor_output" 'ok   : delivery daemon owns its PID and lifetime lock' \
    "doctor validates daemon ownership"
  assert_contains "$doctor_output" 'doctor: healthy' "doctor reports healthy fixture"
  assert_not_contains "$doctor_output" 'ISSUE:' "healthy doctor emits no issue"

  kill -TERM "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -f "$DUET_DIR/daemon.pid" "$DUET_DIR/.daemon.lock"
}

test_explicit_session_and_membership_fence(){
  local config_a config_b dir_a dir_b daemon_pid output rc
  # Earlier unit fixtures intentionally reuse the same pane tuple. Give this
  # discovery test its own registry so there is exactly one truthful owner.
  STATE_ROOT="$TEST_ROOT/membership-state"
  mkdir -p "$STATE_ROOT"
  config_a="$(write_membership_state member-a "$TMUX_SOCKET_A" \
    "$TMUX_SERVER_PID_A" "$A_INIT_PANE" "$A_INIT_PID" "$WORK_ROOT/a")"
  config_b="$(write_membership_state member-b "$TMUX_SOCKET_B" \
    "$TMUX_SERVER_PID_B" "$B_INIT_PANE" "$B_INIT_PID" "$WORK_ROOT/b")"
  dir_a="$(dirname "$config_a")"
  dir_b="$(dirname "$config_b")"
  ln -sfn "$dir_b" "$STATE_ROOT/current"
  start_fake_daemon "$dir_b"
  daemon_pid="$STARTED_FAKE_DAEMON_PID"
  sleep 0.1

  output="$TEST_ROOT/no-pin.out"
  printf 'ambient routing must fail\n' | env -u DUET_CONFIG -u DUET_SESSION \
    -u TMUX -u TMUX_PANE -u DUET_SELF \
    DUET_STATE_ROOT="$STATE_ROOT" DUET_ALLOW_FROM_OVERRIDE=1 \
    bash "$SEND_SCRIPT" leader --from claude > "$output" 2>&1
  rc=$?
  assert_eq 1 "$rc" "agent send refuses ambient current"
  assert_contains "$output" 'no session was pinned' "explicit-session diagnostic"

  output="$TEST_ROOT/cross-session.out"
  printf 'must not cross sessions\n' | env -u DUET_SESSION -u DUET_SELF \
    TMUX="$TMUX_SOCKET_A,$TMUX_SERVER_PID_A,0" TMUX_PANE="$A_INIT_PANE" \
    DUET_CONFIG="$config_b" DUET_STATE_ROOT="$STATE_ROOT" \
    DUET_ALLOW_FROM_OVERRIDE=1 \
    bash "$SEND_SCRIPT" leader --from claude > "$output" 2>&1
  rc=$?
  assert_eq 7 "$rc" "cross-server colliding pane ID is refused"
  if ! grep -qF "$dir_a" "$output" 2>/dev/null; then
    fail "refusal names caller's actual session: expected '$dir_a'; output: $(tr '\n' ' ' < "$output")"
  fi
  assert_contains "$output" member-b "refusal names pinned target session"
  assert_no_file "$dir_b/inbox/leader/.counter" \
    "cross-session refusal publishes no message"

  kill -TERM "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -f "$dir_b/daemon.pid" "$dir_b/.daemon.lock"
}

test_leader_name_path_fence(){
  local escaped="$STATE_ROOT/escaped-leader" rc
  create_state leader-name-fence || return
  printf 'term\t0\nleader\t../../escaped-leader\n' > "$DUET_DIR/leader"
  if duet_read_leader_state >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_eq 1 "$rc" "leadership state rejects path-like leader name"
  if duet_mark_failed_leader ../../escaped-leader 0 TEST >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq 1 "$rc" "failed-leader sink rejects path-like name"
  assert_no_file "$escaped" "failed-leader marker cannot escape session directory"
}

run_case 'Codex cursor-row collapsed composer' test_codex_collapsed_composer
run_case 'Codex refused composer clear and stable-ID requeue' \
  test_refused_composer_clear_requeue
run_case 'CLEAR_RETRY raw-CAS poison and physical-pane coalescing' \
  test_clear_retry_raw_cas_poison
run_case 'promotion CAS, exclusions, and no successor' \
  test_promotion_cas_exclusion_no_successor
run_case 'force refusal and ordinary eligible manual target' \
  test_force_rejected_and_manual_eligible_target
run_case 'promotion dedupe target mismatch rejects alternate CAS' \
  test_promotion_dedupe_target_mismatch
run_case 'promotion and no-successor crash reconciliation' \
  test_promotion_reconciliation
run_case 'terminal metadata and quarantine-intent crash recovery' \
  test_terminal_move_reconciliation
run_case 'promotion sidecar and post-CAS watchdog crash recovery' \
  test_promotion_intent_crash_windows
run_case 'no-successor post-CAS watchdog crash recovery' \
  test_no_successor_cas_before_watchdog
run_case 'watchdog counter reset and soft promotion' \
  test_watchdog_counter_and_soft_promotion
run_case 'leader delivery watchdog integration' test_delivery_watchdog_integration
run_case 'partial INFLIGHT binding safe-outcome recovery' \
  test_partial_inflight_binding_recovery
run_case 'term fence and old worker reply reroute' test_term_fencing_and_worker_reroute
run_case 'uncertain composer fences promotion CAS until old-term resolution' \
  test_uncertain_composer_blocks_promotion_cas
run_case 'INFLIGHT composer owner precedes newer interrupt' \
  test_inflight_owner_precedes_newer_interrupt
run_case 'marker landing evidence without exact token stays poisoned' \
  test_marker_evidence_without_token_stays_poisoned
run_case 'foreign-session payload quarantine and notice' test_foreign_payload_quarantine
run_case 'pane coalescing and promotion-first scheduling' \
  test_pane_coalescing_and_promotion_priority
run_case 'status and doctor healthy active fixture' \
  test_status_and_doctor_healthy_fixture
run_case 'explicit session and cross-session membership fence' \
  test_explicit_session_and_membership_fence
run_case 'leader name path fence' test_leader_name_path_fence

if [ "$FAILURES" -eq 0 ]; then
  printf '==== ALL M3 FAILOVER TESTS PASS ====\n'
  exit 0
fi
printf '==== %s M3 FAILOVER ASSERTION(S) FAILED ====\n' "$FAILURES" >&2
exit 1
