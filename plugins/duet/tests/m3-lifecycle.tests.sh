#!/usr/bin/env bash
# Isolated v4 M3 multi-session, teardown, and dead-peer gate.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
COMMON="$SCRIPTS/duet-common.sh"
INIT="$SCRIPTS/duet-init.sh"
SEND="$SCRIPTS/duet-send.sh"
END="$SCRIPTS/duet-end.sh"
STATUS="$SCRIPTS/duet-status.sh"
DOCTOR="$SCRIPTS/duet-doctor.sh"
FIXTURE="$TEST_DIR/fixtures/fake-harness.sh"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)"
ROOT="$(mktemp -d "$TMP_BASE/duet-v4-m3.XXXXXX")"
STATE_ROOT="$ROOT/state"
REPO="$ROOT/repo"
WT_A="$ROOT/worktrees/a"
WT_B="$ROOT/worktrees/b"
FAKEBIN="$ROOT/fakebin"
ACCEPT_A="$ROOT/accepted-a"
ACCEPT_B="$ROOT/accepted-b"
TMUX_LABEL="${DUET_TEST_TMUX_LABEL:-duetv4smoke}"
TMUX_STARTED=""
SEND_COUNTER=0
FOUND_FILE=""

die(){
  printf 'M3 GATE FAIL: %s\n' "$*" >&2
  for log in "$ROOT"/init-*.log "$ROOT"/end-*.log; do
    [ -f "$log" ] || continue
    printf '%s\n' "--- $(basename "$log") ---" >&2
    tail -n 80 "$log" >&2 || true
  done
  exit 1
}

cleanup(){
  if [ -n "${DUET_KEEP_TEST_ROOT:-}" ]; then
    printf 'duet test: preserved %s and tmux -L %s\n' "$ROOT" "$TMUX_LABEL" >&2
    return
  fi
  if [ -n "$TMUX_STARTED" ]; then
    command tmux -L "$TMUX_LABEL" kill-server >/dev/null 2>&1 || true
  fi
  case "$ROOT" in
    "$TMP_BASE"/duet-v4-m3.*) rm -rf -- "$ROOT" ;;
    *) printf 'duet test: refused unsafe cleanup path %s\n' "$ROOT" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

pane_alive(){
  command tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_id}' 2>/dev/null \
    | grep -qxF "$1"
}

pane_for(){
  awk -F '\t' -v name="$2" 'NR > 1 && $1 == name { print $3; exit }' \
    "$(dirname "$1")/roster.tsv"
}

wait_for_path(){
  local path="$1" i
  for i in $(seq 1 160); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_delivered(){
  local config="$1" body="$2" dir box file encoded i
  dir="$(dirname "$config")"
  encoded="$(printf '%s' "$body" | base64 | tr -d '\r\n')"
  FOUND_FILE=""
  for i in $(seq 1 240); do
    for box in "$dir"/inbox/*; do
      [ -d "$box/delivered" ] || continue
      for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
        [ -f "$file" ] || continue
        if awk -F '\t' -v encoded="$encoded" \
            '$1 == "body64" && $2 == encoded { found=1 }
             END { exit !found }' "$file"; then
          FOUND_FILE="$file"
          return 0
        fi
      done
    done
    sleep 0.05
  done
  return 1
}

wait_for_accept(){
  local log="$1" token="$2" i
  for i in $(seq 1 240); do
    grep -qF "$token" "$log" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

send_as(){
  local config="$1" sender="$2" recipient="$3" body="$4"
  local pane output
  pane="$(pane_for "$config" "$sender")"
  [ -n "$pane" ] || die "no pane for $sender"
  SEND_COUNTER=$((SEND_COUNTER + 1))
  output="$ROOT/send-$SEND_COUNTER.log"
  if ! printf '%s' "$body" | env \
      TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$pane" \
      DUET_SELF="$sender" DUET_CONFIG="$config" \
      bash "$SEND" "$recipient" --from "$sender" > "$output" 2>&1; then
    cat "$output" >&2
    die "$sender -> $recipient enqueue failed"
  fi
  wait_for_delivered "$config" "$body" \
    || die "$sender -> $recipient did not complete"
}

end_as(){
  local config="$1" caller="$2" output="$3" pane
  pane="$(pane_for "$config" "$caller")"
  [ -n "$pane" ] || die "no pane for end caller $caller"
  env TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$pane" \
    DUET_SELF="$caller" DUET_CONFIG="$config" \
    bash "$END" > "$output" 2>&1
}

enqueue_direct(){
  local config="$1" sender="$2" recipient="$3" body="$4"
  DUET_CONFIG="$config" bash -c '
    . "$1"
    . "$2"
    duet_enqueue_message "$4" "$3" "$4" NORMAL "$5"
    printf "%s\n" "$DUET_ENQUEUED_FILE"
  ' _ "$COMMON" "$config" "$sender" "$recipient" "$body"
}

assert_no_ownership_artifacts(){
  local found
  found="$(find "$STATE_ROOT" -maxdepth 2 \
    \( -name current -o -name workdirs -o -name '*.active' \
       -o -name '.current.lock' \) -print 2>/dev/null)"
  [ -z "$found" ] || die "session-ownership artifact created: $found"
}

test_pane_exit_during_teardown(){
  local roster="$ROOT/teardown-race.tsv"
  local gone="$ROOT/teardown-race.gone"
  printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n' > "$roster"
  printf 'codex-1\tcodex\t%%9\t4242\t0\t1\n' >> "$roster"

  (
    # shellcheck disable=SC1090
    . "$COMMON"
    _duet_tmux(){
      case "$1" in
        display-message) [ ! -f "$gone" ] && printf '4242\n' ;;
        send-keys) return 0 ;;
        kill-pane) : > "$gone"; return 1 ;;
        *) return 1 ;;
      esac
    }
    duet_kill_spawned_panes "$roster" '%0'
  ) || die "pane exit racing kill-pane was reported as teardown failure"

  rm -f "$gone"
  if (
    # shellcheck disable=SC1090
    . "$COMMON"
    _duet_tmux(){
      case "$1" in
        display-message) printf '4242\n' ;;
        send-keys) return 0 ;;
        kill-pane) return 1 ;;
        *) return 1 ;;
      esac
    }
    duet_kill_spawned_panes "$roster" '%0'
  ) > /dev/null 2> "$ROOT/teardown-stuck.err"; then
    die "still-live pane was accepted after kill-pane failed"
  fi
  grep -q 'failed to stop spawned pane %9' "$ROOT/teardown-stuck.err" \
    || die "still-live pane failure was not surfaced"
  printf 'PASS teardown tolerates exit race but rejects a still-live victim\n'
}

command -v tmux >/dev/null 2>&1 || {
  printf 'SKIP: tmux is not installed\n'
  exit 0
}
command -v git >/dev/null 2>&1 || {
  printf 'SKIP: git is not installed\n'
  exit 0
}
[ -x "$FIXTURE" ] || die "fake harness fixture is not executable"
if command tmux -L "$TMUX_LABEL" has-session >/dev/null 2>&1; then
  die "isolated tmux server '$TMUX_LABEL' already exists"
fi

mkdir -p "$STATE_ROOT" "$REPO" "$ROOT/worktrees" "$FAKEBIN" \
  "$ACCEPT_A" "$ACCEPT_B"
test_pane_exit_during_teardown
for harness in claude codex kimi; do
  ln -s "$FIXTURE" "$FAKEBIN/$harness"
done

git -C "$REPO" init -q
printf 'base agents\n' > "$REPO/AGENTS.md"
printf 'base claude\n' > "$REPO/CLAUDE.md"
git -C "$REPO" add AGENTS.md CLAUDE.md
git -C "$REPO" -c user.name='Duet Test' -c user.email='duet@test.invalid' \
  commit -qm base
git -C "$REPO" worktree add -q -b session-a "$WT_A"
git -C "$REPO" worktree add -q -b session-b "$WT_B"

printf -v launch_a 'exec env %q %q %q %q %q' \
  'DUET_CONFIG=' 'DUET_SESSION=' 'DUET_SELF=claude' \
  "DUET_FAKE_ACCEPT_ROOT=$ACCEPT_A" "$FAKEBIN/claude"
printf -v launch_b 'exec env %q %q %q %q %q' \
  'DUET_CONFIG=' 'DUET_SESSION=' 'DUET_SELF=codex' \
  "DUET_FAKE_ACCEPT_ROOT=$ACCEPT_B" "$FAKEBIN/codex"
command tmux -L "$TMUX_LABEL" -f /dev/null new-session -d \
  -s session-a -c "$WT_A" "$launch_a"
TMUX_STARTED=1
command tmux -L "$TMUX_LABEL" new-session -d \
  -s session-b -c "$WT_B" "$launch_b"
PANE_A="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t session-a '#{pane_id}')"
PANE_B="$(command tmux -L "$TMUX_LABEL" display-message -p \
  -t session-b '#{pane_id}')"
TMUX_SOCKET="$(command tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(command tmux -L "$TMUX_LABEL" display-message -p '#{pid}')"

(
  cd "$WT_A"
  command tmux -L "$TMUX_LABEL" set-environment -g \
    DUET_FAKE_ACCEPT_ROOT "$ACCEPT_A"
  env PATH="$FAKEBIN:$PATH" DUET_STATE_ROOT="$STATE_ROOT" \
    DUET_CONFIG= \
    DUET_CODEX_SKIP_PRETRUST=1 DUET_BOOT_TIMEOUT=5 DUET_READY_TIMEOUT=10 \
    DUET_FAKE_ACCEPT_ROOT="$ACCEPT_A" \
    DUET_SELF=claude \
    TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_A" \
    bash "$INIT" --initiator claude codex kimi
) > "$ROOT/init-a.log" 2>&1 || die "session A init failed"
DIR_A="$(sed -n 's/^duet: session //p' "$ROOT/init-a.log" | tail -n 1)"
[ -d "$DIR_A" ] || die "session A path missing from init output"
CONFIG_A="$DIR_A/duet.env"

(
  cd "$WT_B"
  command tmux -L "$TMUX_LABEL" set-environment -g \
    DUET_FAKE_ACCEPT_ROOT "$ACCEPT_B"
  env PATH="$FAKEBIN:$PATH" DUET_STATE_ROOT="$STATE_ROOT" \
    DUET_CONFIG= \
    DUET_CODEX_SKIP_PRETRUST=1 DUET_BOOT_TIMEOUT=5 DUET_READY_TIMEOUT=10 \
    DUET_FAKE_ACCEPT_ROOT="$ACCEPT_B" \
    DUET_SELF=codex \
    TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_B" \
    bash "$INIT" --initiator codex claude kimi
) > "$ROOT/init-b.log" 2>&1 || die "session B init failed"
DIR_B="$(sed -n 's/^duet: session //p' "$ROOT/init-b.log" | tail -n 1)"
[ -d "$DIR_B" ] || die "session B path missing from init output"
CONFIG_B="$DIR_B/duet.env"
[ "$DIR_A" != "$DIR_B" ] || die "two inits reused one session directory"

grep -q '<!-- DUET:BEGIN' "$WT_A/AGENTS.md" \
  || die "session A AGENTS anchor missing"
grep -q '<!-- DUET:BEGIN' "$WT_B/AGENTS.md" \
  || die "session B AGENTS anchor missing"
assert_no_ownership_artifacts

send_as "$CONFIG_A" codex-1 kimi-1 'm3-a-codex-to-kimi'
wait_for_accept "$ACCEPT_A/kimi-1.log" 'm3-a-codex-to-kimi' \
  || die "session A payload absent from its target harness"
send_as "$CONFIG_B" claude-1 codex 'm3-b-claude-to-codex'
wait_for_accept "$ACCEPT_B/codex.log" 'm3-b-claude-to-codex' \
  || die "session B payload absent from its target harness"
! grep -qF 'm3-a-codex-to-kimi' "$ACCEPT_B/kimi-1.log" 2>/dev/null \
  || die "session A payload crossed into session B"
printf 'PASS two worktree sessions route independently\n'

if DUET_CONFIG="$CONFIG_A" bash "$STATUS" > "$ROOT/status-ambient.log" 2>&1; then
  die "status accepted ambient DUET_CONFIG without --session"
fi
if printf 'missing-config' | env -u DUET_CONFIG \
    TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" \
    TMUX_PANE="$(pane_for "$CONFIG_A" codex-1)" DUET_SELF=codex-1 \
    bash "$SEND" kimi-1 --from codex-1 > "$ROOT/send-unpinned.log" 2>&1; then
  die "send accepted an unpinned session"
fi
grep -q 'DUET_CONFIG must name an absolute duet.env' "$ROOT/send-unpinned.log" \
  || die "unpinned send did not explain the required absolute config"
bash "$STATUS" --session "$CONFIG_B" > "$ROOT/status-b.log" \
  || die "explicit status failed"
grep -q 'codex' "$ROOT/status-b.log" || die "status omitted roster harnesses"
bash "$DOCTOR" --session "$CONFIG_B" > "$ROOT/doctor-b.log" \
  || die "healthy explicit doctor failed"

A_CALLER_PANE="$(pane_for "$CONFIG_A" codex-1)"
A_KIMI_PANE="$(pane_for "$CONFIG_A" kimi-1)"
start_seconds="$(date +%s)"
end_as "$CONFIG_A" codex-1 "$ROOT/end-a.log" || die "session A teardown failed"
elapsed=$(( $(date +%s) - start_seconds ))
[ "$elapsed" -le 5 ] || die "session A teardown was not immediate (${elapsed}s)"
[ -f "$DIR_A/.ended" ] || die "session A ended marker missing"
pane_alive "$A_CALLER_PANE" || die "session A caller pane was killed"
pane_alive "$PANE_A" || die "session A initiator pane was killed"
! pane_alive "$A_KIMI_PANE" || die "session A spawned noncaller pane survived"
! grep -q '<!-- DUET:BEGIN' "$WT_A/AGENTS.md" \
  || die "session A anchor survived teardown"
grep -q '<!-- DUET:BEGIN' "$WT_B/AGENTS.md" \
  || die "session A teardown stripped session B anchor"
find "$DIR_A" -name '*.lock' -print -quit | grep -q . \
  && die "session A left a lock artifact"
assert_no_ownership_artifacts

if printf 'after-end' | env \
    TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$A_CALLER_PANE" \
    DUET_SELF=codex-1 DUET_CONFIG="$CONFIG_A" \
    bash "$SEND" claude --from codex-1 > "$ROOT/send-ended.log" 2>&1; then
  die "ended session accepted a message"
fi
grep -q 'session has ended' "$ROOT/send-ended.log" \
  || die "ended-session refusal was not explicit"
send_as "$CONFIG_B" codex claude-1 'm3-b-after-a-ended'
wait_for_accept "$ACCEPT_B/claude-1.log" 'm3-b-after-a-ended' \
  || die "session B stopped after session A teardown"
printf 'PASS immediate teardown is isolated and ended sends are refused\n'

B_KIMI_PANE="$(pane_for "$CONFIG_B" kimi-1)"
command tmux -L "$TMUX_LABEL" kill-pane -t "$B_KIMI_PANE"
dead_active="$(enqueue_direct "$CONFIG_B" codex kimi-1 'm3-dead-peer')"
dead_base="$(basename "$dead_active")"
wait_for_path "$DIR_B/dead/kimi-1" || die "dead peer was not surfaced"
wait_for_path "$DIR_B/inbox/kimi-1/rejected/$dead_base" \
  || die "dead-peer message was not rejected"
[ ! -f "$DIR_B/.unhealthy" ] || die "dead peer marked the mesh unhealthy"

printf 'broken envelope\n' > "$DIR_B/inbox/claude-1/I-0000000000.msg"
wait_for_path "$DIR_B/inbox/claude-1/rejected/I-0000000000.msg" \
  || die "invalid envelope was not rejected"
[ ! -f "$DIR_B/.unhealthy" ] || die "invalid envelope marked the mesh unhealthy"
send_as "$CONFIG_B" codex claude-1 'm3-live-after-dead-forward'
send_as "$CONFIG_B" claude-1 codex 'm3-live-after-dead-reverse'
wait_for_accept "$ACCEPT_B/claude-1.log" 'm3-live-after-dead-forward' \
  || die "living worker stopped after peer death"
wait_for_accept "$ACCEPT_B/codex.log" 'm3-live-after-dead-reverse' \
  || die "living initiator stopped after peer death"
printf 'PASS dead peer and invalid envelope are recipient-scoped\n'

B_CALLER_PANE="$(pane_for "$CONFIG_B" claude-1)"
end_as "$CONFIG_B" claude-1 "$ROOT/end-b.log" || die "session B teardown failed"
pane_alive "$B_CALLER_PANE" || die "session B caller pane was killed"
leftover_locks="$(find "$STATE_ROOT" -name '*.lock' -print)"
[ -z "$leftover_locks" ] \
  || die "ended sessions left a lock artifact: $leftover_locks"
assert_no_ownership_artifacts
printf 'PASS teardown kills only recorded spawned noncaller panes\n'
printf '==== ALL V4 M3 LIFECYCLE TESTS PASS ====\n'
