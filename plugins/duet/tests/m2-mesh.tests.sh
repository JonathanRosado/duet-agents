#!/usr/bin/env bash
# Deterministic v4 M2 mesh, sender-auth, and wire-schema tests.
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
COMMON="$SCRIPTS/duet-common.sh"
SEND="$SCRIPTS/duet-send.sh"
DELIVERD="$SCRIPTS/duet-deliverd.sh"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)" || exit 1
ROOT="$(mktemp -d "$TMP_BASE/duet-v4-m2.XXXXXX")" || exit 1
STATE_ROOT="$ROOT/state"
WORKDIR="$ROOT/work"
DUET_DIR="$STATE_ROOT/m2-session"
CONFIG="$DUET_DIR/duet.env"
TMUX_LABEL="duet-v4-m2-$PPID-${RANDOM:-0}"
TMUX_SESSION=m2
FAILURES=0
DAEMON_PID=""

fail(){
  FAILURES=$((FAILURES + 1))
  printf '  FAIL %s\n' "$*" >&2
}

assert_eq(){
  local expected="$1" actual="$2" label="$3"
  [ "$expected" = "$actual" ] \
    || fail "$label: expected '$expected', got '$actual'"
}

cleanup(){
  local child
  : > "$DUET_DIR/.ended" 2>/dev/null || true
  case "$DAEMON_PID" in
    ''|*[!0-9]*) : ;;
    *)
      for child in $(pgrep -P "$DAEMON_PID" 2>/dev/null || true); do
        kill -TERM "$child" 2>/dev/null || true
      done
      kill -TERM "$DAEMON_PID" 2>/dev/null || true
      wait "$DAEMON_PID" 2>/dev/null || true
      ;;
  esac
  command tmux -L "$TMUX_LABEL" kill-server >/dev/null 2>&1 || true
  case "$ROOT" in "$TMP_BASE"/duet-v4-m2.*) rm -rf -- "$ROOT" ;; esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

command -v tmux >/dev/null 2>&1 || {
  printf 'SKIP: tmux is not installed\n'
  exit 0
}
mkdir -p "$STATE_ROOT" "$WORKDIR" "$DUET_DIR/ready"
for name in claude codex-1 kimi-1; do
  mkdir -p "$DUET_DIR/inbox/$name/delivered"
  printf 'ok\n' > "$DUET_DIR/ready/$name"
done
: > "$DUET_DIR/transcript.md"

command tmux -L "$TMUX_LABEL" -f /dev/null new-session -d \
  -s "$TMUX_SESSION" -c "$WORKDIR" 'exec sleep 600'
CLAUDE_PANE="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$TMUX_SESSION" '#{pane_id}')"
CODEX_PANE="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" 'exec sleep 600')"
KIMI_PANE="$(command tmux -L "$TMUX_LABEL" split-window -d -P -F '#{pane_id}' \
  -t "$TMUX_SESSION" 'exec sleep 600')"
CLAUDE_PID="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$CLAUDE_PANE" '#{pane_pid}')"
CODEX_PID="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$CODEX_PANE" '#{pane_pid}')"
KIMI_PID="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t "$KIMI_PANE" '#{pane_pid}')"
SOCKET="$(command tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')"
SERVER_PID="$(command tmux -L "$TMUX_LABEL" display-message -p '#{pid}')"

{
  printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n'
  printf 'claude\tclaude\t%s\t%s\t0\t0\n' "$CLAUDE_PANE" "$CLAUDE_PID"
  printf 'codex-1\tcodex\t%s\t%s\t1\t1\n' "$CODEX_PANE" "$CODEX_PID"
  printf 'kimi-1\tkimi\t%s\t%s\t2\t1\n' "$KIMI_PANE" "$KIMI_PID"
} > "$DUET_DIR/roster.tsv"
{
  printf 'DUET_DIR=%q\n' "$DUET_DIR"
  printf 'DUET_STATE_ROOT=%q\n' "$STATE_ROOT"
  printf 'WORKDIR=%q\n' "$WORKDIR"
  printf 'PLUGIN_DIR=%q\n' "$PLUGIN_DIR"
  printf 'DUET_TMUX_SOCKET=%q\n' "$SOCKET"
  printf 'DUET_TMUX_SERVER_PID=%q\n' "$SERVER_PID"
  printf 'DUET_SESSION=%q\n' m2-session
  printf 'DUET_SESSION_ID=%q\n' m2-session
  printf 'DUET_INITIATOR=%q\n' claude
  printf 'DUET_INITIATOR_PANE=%q\n' "$CLAUDE_PANE"
} > "$CONFIG"

DUET_CONFIG="$CONFIG" DUET_SESSION=m2-session DUET_DELIVERY_POLL_INTERVAL=60 \
  bash "$DELIVERD" --session "$CONFIG" --session-id m2-session \
  > "$DUET_DIR/daemon.stdout" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 100); do
  [ -f "$DUET_DIR/daemon.pid" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.05
done
[ -f "$DUET_DIR/daemon.pid" ] || {
  printf 'FAIL: daemon did not start\n' >&2
  exit 1
}

pane_for(){
  awk -F '\t' -v name="$1" '$1 == name { print $3; exit }' "$DUET_DIR/roster.tsv"
}

send_as(){
  local sender="$1" recipient="$2" body="$3" pane output
  pane="$(pane_for "$sender")"
  output="$ROOT/send-$sender-$recipient-$RANDOM.out"
  if ! printf '%s' "$body" | env \
      TMUX="$SOCKET,$SERVER_PID,0" TMUX_PANE="$pane" DUET_SELF="$sender" \
      DUET_CONFIG="$CONFIG" DUET_SESSION=m2-session \
      bash "$SEND" "$recipient" --from "$sender" > "$output" 2>&1; then
    cat "$output" >&2
    return 1
  fi
  cat "$output"
}

active_count(){
  local queue="$1" file count=0
  for file in "$DUET_DIR/inbox/$queue"/N-*.msg \
      "$DUET_DIR/inbox/$queue"/I-*.msg; do
    [ -f "$file" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

printf 'TEST any-to-any direct enqueue and v4 wire schema\n'
send_as codex-1 kimi-1 codex-to-kimi >/dev/null || fail "codex-1 -> kimi-1 rejected"
send_as kimi-1 codex-1 kimi-to-codex >/dev/null || fail "kimi-1 -> codex-1 rejected"
send_as codex-1 claude codex-to-claude >/dev/null || fail "codex-1 -> claude rejected"
assert_eq 1 "$(active_count kimi-1)" "kimi direct queue depth"
assert_eq 1 "$(active_count codex-1)" "codex direct queue depth"
assert_eq 1 "$(active_count claude)" "claude direct queue depth"
DIRECT_FILE="$DUET_DIR/inbox/kimi-1/N-0000000001.msg"
# shellcheck disable=SC1090
. "$COMMON"
duet_read_message "$DIRECT_FILE" || fail "DUETv4 direct envelope rejected by parser"
assert_eq codex-1 "$DUET_MESSAGE_SENDER" "wire sender"
assert_eq kimi-1 "$DUET_MESSAGE_RECIPIENT" "wire recipient"
EXPECTED_KEYS='DUETv4
id
session
mode
sender
recipient
body64'
ACTUAL_KEYS="$(awk -F '\t' 'NR == 1 { print; next } { print $1 }' "$DIRECT_FILE")"
assert_eq "$EXPECTED_KEYS" "$ACTUAL_KEYS" "minimal wire fields"
PAYLOAD="$(duet_build_payload)"
printf '%s\n' "$PAYLOAD" \
  | grep -qF '[DUET session=m2-session id=m-m2-session-kimi-1-0000000001 from=codex-1 to=kimi-1]' \
  || fail "payload header does not carry exact from/to"
printf '  PASS\n'

printf 'TEST broadcast excludes sender and targets every other live member\n'
before_codex="$(active_count codex-1)"
before_claude="$(active_count claude)"
before_kimi="$(active_count kimi-1)"
send_as codex-1 all broadcast-body >/dev/null || fail "mesh broadcast rejected"
assert_eq "$before_codex" "$(active_count codex-1)" "broadcast sender exclusion"
assert_eq "$((before_claude + 1))" "$(active_count claude)" "broadcast Claude fanout"
assert_eq "$((before_kimi + 1))" "$(active_count kimi-1)" "broadcast Kimi fanout"
for file in "$DUET_DIR/inbox/claude/N-0000000002.msg" \
    "$DUET_DIR/inbox/kimi-1/N-0000000002.msg"; do
  duet_read_message "$file" || { fail "invalid broadcast envelope $file"; continue; }
  assert_eq all "$DUET_MESSAGE_RECIPIENT" "broadcast wire recipient"
done
printf '  PASS\n'

printf 'TEST sender identity and exact-recipient authorization\n'
if printf x | env TMUX="$SOCKET,$SERVER_PID,0" TMUX_PANE="$CODEX_PANE" \
    DUET_SELF=codex-1 DUET_CONFIG="$CONFIG" DUET_SESSION=m2-session \
    bash "$SEND" kimi-1 --from kimi-1 >/dev/null 2>&1; then
  fail "caller pane spoofed --from"
fi
if printf x | env TMUX="$SOCKET,$SERVER_PID,0" TMUX_PANE="$CODEX_PANE" \
    DUET_SELF=kimi-1 DUET_CONFIG="$CONFIG" DUET_SESSION=m2-session \
    bash "$SEND" kimi-1 >/dev/null 2>&1; then
  fail "mismatched DUET_SELF was accepted"
fi
if printf x | env TMUX="$SOCKET,$SERVER_PID,0" TMUX_PANE="$CODEX_PANE" \
    DUET_SELF=codex-1 DUET_CONFIG="$CONFIG" DUET_SESSION=m2-session \
    bash "$SEND" kimi >/dev/null 2>&1; then
  fail "harness alias was accepted instead of exact roster name"
fi
if printf x | env -u TMUX -u TMUX_PANE DUET_CONFIG="$CONFIG" \
    DUET_SESSION=m2-session bash "$SEND" kimi-1 >/dev/null 2>&1; then
  fail "nonmember caller was accepted"
fi
printf '  PASS\n'

printf 'TEST runtime contains no authority/election surface\n'
if rg -n -i 'leader|generation|promot|handoff|watchdog|failover' \
    "$SCRIPTS/duet-common.sh" "$SCRIPTS/duet-send.sh" \
    "$SCRIPTS/duet-deliverd.sh" "$SCRIPTS/duet-init.sh" \
    "$SCRIPTS/duet-status.sh" "$SCRIPTS/duet-doctor.sh" >/dev/null; then
  fail "authority/election vocabulary remains in Bash runtime"
fi
[ ! -e "$SCRIPTS/duet-promote.sh" ] \
  || fail "duet-promote.sh still exists"
if rg -n 'INITIATOR_NAME=claude|printf .* claude .*INITIATOR_PANE' \
    "$SCRIPTS/duet-init.sh" >/dev/null; then
  fail "init still hardcodes Claude as roster row zero"
fi
printf '  PASS\n'

if [ "$FAILURES" -eq 0 ]; then
  printf '==== ALL V4 M2 MESH TESTS PASS ====\n'
  exit 0
fi
printf '==== %s V4 M2 ASSERTION(S) FAILED ====\n' "$FAILURES" >&2
exit 1
