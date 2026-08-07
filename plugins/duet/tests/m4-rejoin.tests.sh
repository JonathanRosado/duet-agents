#!/usr/bin/env bash
# Isolated v4 M4 native-session pairing and rejoin gate. Fake harnesses only;
# no real CLI is launched. Covers: fresh capture, clean end + rejoin, abrupt
# mesh death + rejoin, initiator resumed from each harness, rejoin invoked
# from a former worker's native session, missing/corrupt/partial records, a
# still-live prior pane, a moved worktree, and no queue replay.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
COMMON="$SCRIPTS/duet-common.sh"
PAIRING="$SCRIPTS/duet-pairing.sh"
INIT="$SCRIPTS/duet-init.sh"
REJOIN="$SCRIPTS/duet-rejoin.sh"
END="$SCRIPTS/duet-end.sh"
FIXTURE="$TEST_DIR/fixtures/fake-harness.sh"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)"
ROOT="$(mktemp -d "$TMP_BASE/duet-v4-m4.XXXXXX")"
STATE_ROOT="$ROOT/state"
REPO="$ROOT/repo"
REPO2="$ROOT/repo2"
REPO3="$ROOT/repo3"
REPO_MOVE_A="$ROOT/repo-move-before"
REPO_MOVE_B="$ROOT/repo-move-after"
WT_A="$ROOT/worktrees/a"
WT_B="$ROOT/worktrees/b"
FAKEBIN="$ROOT/fakebin"
ARGV_LOG="$ROOT/argv.log"
CLAUDE_PROJECTS="$ROOT/native/claude/projects"
CODEX_SESSIONS="$ROOT/native/codex/sessions"
KIMI_SESSIONS="$ROOT/native/kimi/sessions"
KIMI_INDEX="$ROOT/native/kimi/session_index.jsonl"
ACCEPT="$ROOT/accepted"
TMUX_LABEL="${DUET_TEST_TMUX_LABEL:-duetm4smoke}"
TMUX_STARTED=""

CLAUDE_INIT_ID="11111111-1111-4111-8111-111111111111"
CODEX_INIT_ID="22222222-2222-4222-8222-222222222222"
KIMI_INIT_ID="session_33333333-3333-4333-8333-333333333333"

die(){
  printf 'M4 GATE FAIL: %s\n' "$*" >&2
  for log in "$ROOT"/run-*.log; do
    [ -f "$log" ] || continue
    printf '%s\n' "--- $(basename "$log") ---" >&2
    tail -n 40 "$log" >&2 || true
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
    "$TMP_BASE"/duet-v4-m4.*) rm -rf -- "$ROOT" ;;
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

pairing_field(){
  awk -F '\t' -v name="$2" -v col="$3" \
    'NR > 1 && $1 == name { print $col; exit }' "$1/pairing.tsv"
}

session_dirs(){
  find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-*' \
    ! -name pairings 2>/dev/null | LC_ALL=C sort
}

wait_for_delivered(){
  local config="$1" body="$2" dir box file encoded i
  dir="$(dirname "$config")"
  encoded="$(printf '%s' "$body" | base64 | tr -d '\r\n')"
  for i in $(seq 1 240); do
    for box in "$dir"/inbox/*; do
      [ -d "$box/delivered" ] || continue
      for file in "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg; do
        [ -f "$file" ] || continue
        if awk -F '\t' -v encoded="$encoded" \
            '$1 == "body64" && $2 == encoded { found=1 }
             END { exit !found }' "$file"; then
          return 0
        fi
      done
    done
    sleep 0.05
  done
  return 1
}

# Start a detached tmux session running a fake initiator harness.
start_initiator_pane(){
  local label="$1" harness="$2" dir="$3" native_env="$4"
  printf -v launch 'exec env %q %q %q %q %q %q %q' \
    'DUET_CONFIG=' 'DUET_SESSION=' "DUET_SELF=$harness" \
    "$native_env" "DUET_FAKE_CLAUDE_PROJECTS=$CLAUDE_PROJECTS" \
    "DUET_FAKE_CODEX_SESSIONS=$CODEX_SESSIONS" "$FAKEBIN/$harness"
  command tmux -L "$TMUX_LABEL" -f /dev/null new-session -d \
    -s "$label" -c "$dir" "$launch"
  TMUX_STARTED=1
  command tmux -L "$TMUX_LABEL" display-message -p -t "$label" '#{pane_id}'
}

# Run init or rejoin as the given pane's agent. Extra env assignments follow
# the native id; the last parameter is the initiator harness (fake panes run
# scripts, so pane_current_command cannot carry it). Roster words are
# intentionally word-split; empty means none.
run_agent_cmd(){
  local workdir="$1" pane="$2" log="$3" script="$4" native_id="$5" init_h="$6"
  shift 6
  local init_flag=()
  [ -z "$init_h" ] || init_flag=(--initiator "$init_h")
  (
    cd "$workdir"
    # shellcheck disable=SC2086
    env PATH="$FAKEBIN:$PATH" \
      HOME="$HOME" \
      DUET_STATE_ROOT="$STATE_ROOT" \
      DUET_CONFIG= DUET_SELF= DUET_SESSION= \
      DUET_CODEX_SKIP_PRETRUST=1 \
      DUET_BOOT_TIMEOUT=5 DUET_READY_TIMEOUT=10 \
      DUET_PAIRING_CAPTURE_TRIES="${DUET_TEST_CAPTURE_TRIES:-20}" \
      DUET_CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS" \
      DUET_CODEX_SESSIONS_DIR="$CODEX_SESSIONS" \
      DUET_KIMI_SESSION_INDEX="$KIMI_INDEX" \
      DUET_KIMI_SESSIONS_DIR="$KIMI_SESSIONS" \
      DUET_INITIATOR_NATIVE_ID="$native_id" \
      TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$pane" \
      "$@" \
      bash "$script" ${init_flag[@]+"${init_flag[@]}"} $REMAINING_ROSTER
  ) > "$log" 2>&1
}

end_as(){
  local config="$1" caller="$2" pane
  pane="$(pane_for "$config" "$caller")"
  [ -n "$pane" ] || die "no pane for end caller $caller"
  env TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$pane" \
    DUET_SELF="$caller" DUET_CONFIG="$config" \
    bash "$END" > "$ROOT/run-end-$(basename "$(dirname "$config")").log" 2>&1
}

session_dir_from(){
  sed -n 's/^duet: session //p' "$1" | tail -n 1
}

argv_since(){
  local mark="$1" name="$2"
  tail -n +"$mark" "$ARGV_LOG" | awk -F '\t' -v n="$name" '$1 == n { print $2 }' \
    | tail -n 1
}

command -v tmux >/dev/null 2>&1 || { printf 'SKIP: tmux is not installed\n'; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'SKIP: git is not installed\n'; exit 0; }
[ -x "$FIXTURE" ] || die "fake harness fixture is not executable"
if command tmux -L "$TMUX_LABEL" has-session >/dev/null 2>&1; then
  die "isolated tmux server '$TMUX_LABEL' already exists"
fi

mkdir -p "$STATE_ROOT" "$REPO" "$REPO2" "$ROOT/worktrees" "$FAKEBIN" \
  "$CLAUDE_PROJECTS" "$CODEX_SESSIONS" "$KIMI_SESSIONS" "$ACCEPT" \
  "$REPO_MOVE_A"
: > "$ARGV_LOG"
for harness in claude codex kimi; do
  ln -s "$FIXTURE" "$FAKEBIN/$harness"
done

git -C "$REPO" init -q
printf 'base agents\n' > "$REPO/AGENTS.md"
printf 'base claude\n' > "$REPO/CLAUDE.md"
git -C "$REPO" add AGENTS.md CLAUDE.md
git -C "$REPO" -c user.name='Duet Test' -c user.email='duet@test.invalid' \
  commit -qm base
git -C "$REPO" worktree add -q -b m4-a "$WT_A"
git -C "$REPO" worktree add -q -b m4-b "$WT_B"
git -C "$REPO2" init -q
git -C "$REPO2" -c user.name='Duet Test' -c user.email='duet@test.invalid' \
  commit -q --allow-empty -m base
mkdir -p "$REPO3"
git -C "$REPO3" init -q
git -C "$REPO3" -c user.name='Duet Test' -c user.email='duet@test.invalid' \
  commit -q --allow-empty -m base
git -C "$REPO_MOVE_A" init -q
git -C "$REPO_MOVE_A" -c user.name='Duet Test' -c user.email='duet@test.invalid' \
  commit -q --allow-empty -m base

command tmux -L "$TMUX_LABEL" -f /dev/null new-session -d -s hold -x 200 -y 50
TMUX_STARTED=1
TMUX_SOCKET="$(command tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(command tmux -L "$TMUX_LABEL" display-message -p '#{pid}')"
command tmux -L "$TMUX_LABEL" set-environment -g DUET_FAKE_CLAUDE_PROJECTS "$CLAUDE_PROJECTS"
command tmux -L "$TMUX_LABEL" set-environment -g DUET_FAKE_CODEX_SESSIONS "$CODEX_SESSIONS"
command tmux -L "$TMUX_LABEL" set-environment -g DUET_FAKE_KIMI_INDEX "$KIMI_INDEX"
command tmux -L "$TMUX_LABEL" set-environment -g DUET_FAKE_KIMI_SESSIONS "$KIMI_SESSIONS"
command tmux -L "$TMUX_LABEL" set-environment -g DUET_FAKE_ARGV_LOG "$ARGV_LOG"
command tmux -L "$TMUX_LABEL" set-environment -g DUET_FAKE_ACCEPT_ROOT "$ACCEPT"

# ---- native-id capture/normalization checks (no tmux needed) --------------
(
  # shellcheck disable=SC1090,SC1091
  . "$COMMON"; . "$PAIRING"
  norm="$(duet_normalize_native_id kimi 66666666-6666-4666-8666-666666666666)"
  [ "$norm" = session_66666666-6666-4666-8666-666666666666 ] \
    || die "kimi bare uuid was not normalized: $norm"
  unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID KIMI_SESSION_ID
  if duet_capture_initiator_id codex "$WT_A" "" >/dev/null 2>&1; then
    die "initiator capture guessed an id without an exact argument or env"
  fi
  ORPHAN_HOME="$ROOT/kimi-orphan-home"
  ORPHAN_ID='session_69696969-6969-4969-8969-696969696969'
  ORPHAN_DIR="$ORPHAN_HOME/sessions/wd_test/$ORPHAN_ID"
  mkdir -p "$ORPHAN_DIR"
  : > "$ORPHAN_HOME/session_index.jsonl"
  if duet_native_id_resolvable kimi "$ORPHAN_ID" "$ORPHAN_HOME"; then
    die "Kimi orphan directory resolved without an exact index entry"
  fi
  printf '{"sessionId":"%s","sessionDir":"%s","workDir":"%s"}\n' \
    "$ORPHAN_ID" "$ORPHAN_DIR" "$WT_A" > "$ORPHAN_HOME/session_index.jsonl"
  duet_native_id_resolvable kimi "$ORPHAN_ID" "$ORPHAN_HOME" \
    || die "exact Kimi index entry plus sessionDir did not resolve"
  duet_native_session_resumable kimi "$ORPHAN_ID" "$ORPHAN_HOME" \
    "$WT_A" "$WT_A" \
    || die "same-workdir Kimi session was not resumable"
) || die "native-id capture unit checks failed"
printf 'PASS initiator capture is exact and never guesses from session stores\n'

# ---- exact registration helper unit checks -------------------------------
(
  REG_SESSION="$ROOT/20260807-010101-register"
  REG_DIR="$REG_SESSION/native-registration"
  REG_FILE="$REG_DIR/codex-1.json"
  REG_NONCE='register-nonce'
  REG_ID='77777777-7777-4777-8777-777777777777'
  mkdir -p "$REG_DIR"
  : > "$REG_SESSION/duet.env"
  printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s","cwd":"%s"}\n' \
    "$REG_ID" "$WT_A" \
    | env DUET_NATIVE_REGISTRATION_FILE="$REG_FILE" \
        DUET_NATIVE_REGISTRATION_HARNESS=codex \
        DUET_NATIVE_REGISTRATION_NAME=codex-1 \
        DUET_NATIVE_REGISTRATION_NONCE="$REG_NONCE" \
        DUET_NATIVE_REGISTRATION_HELPER="$PLUGIN_DIR/scripts/duet-native-register.js" \
        DUET_SESSION="$(basename "$REG_SESSION")" \
        DUET_CONFIG="$REG_SESSION/duet.env" DUET_SELF=codex-1 TMUX_PANE=%88 \
        node "$PLUGIN_DIR/scripts/duet-native-register.js"
  REG_PID="$(node -e \
    'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).pane_pid))' \
    "$REG_FILE")"
  REG_RESULT="$(node "$PLUGIN_DIR/scripts/duet-native-register.js" verify \
    "$REG_FILE" codex codex-1 "$REG_NONCE" "$(basename "$REG_SESSION")" \
    %88 "$REG_PID" "$WT_A")"
  [ "$REG_RESULT" = "$REG_ID"$'\t''startup' ] \
    || die "registration helper did not verify its exact startup record"
  if node "$PLUGIN_DIR/scripts/duet-native-register.js" verify \
      "$REG_FILE" codex codex-1 wrong-nonce "$(basename "$REG_SESSION")" \
      %88 "$REG_PID" "$WT_A" >/dev/null 2>&1; then
    die "registration helper accepted the wrong nonce"
  fi
  if DUET_NATIVE_EXPECTED_ID=88888888-8888-4888-8888-888888888888 \
      node "$PLUGIN_DIR/scripts/duet-native-register.js" verify \
      "$REG_FILE" codex codex-1 "$REG_NONCE" "$(basename "$REG_SESSION")" \
      %88 "$REG_PID" "$WT_A" >/dev/null 2>&1; then
    die "registration helper accepted the wrong expected resume id"
  fi
  if printf '{not-json}\n' | env \
      DUET_NATIVE_REGISTRATION_FILE="$REG_DIR/bad.json" \
      node "$PLUGIN_DIR/scripts/duet-native-register.js" >/dev/null 2>&1; then
    die "registration helper accepted malformed hook JSON"
  fi
  : > "$REG_SESSION/pairing.complete"
  printf '{"hook_event_name":"SessionStart","source":"resume","session_id":"%s","cwd":"%s"}\n' \
    '88888888-8888-4888-8888-888888888888' "$WT_A" \
    | env DUET_NATIVE_REGISTRATION_FILE="$REG_FILE" \
        DUET_NATIVE_REGISTRATION_HARNESS=codex \
        DUET_NATIVE_REGISTRATION_NAME=codex-1 \
        DUET_NATIVE_REGISTRATION_NONCE="$REG_NONCE" \
        DUET_SESSION="$(basename "$REG_SESSION")" \
        DUET_CONFIG="$REG_SESSION/duet.env" DUET_SELF=codex-1 TMUX_PANE=%88 \
        node "$PLUGIN_DIR/scripts/duet-native-register.js"
  [ ! -f "$REG_SESSION/pairing.complete" ] \
    || die "native session switch did not invalidate the published pairing"
  [ -f "$REG_SESSION/pairing.invalidated" ] \
    || die "native session switch left no invalidation diagnostic"

  KIMI_TRUST_HOME="$ROOT/kimi-trust-home"
  mkdir -p "$KIMI_TRUST_HOME"
  KIMI_CODE_HOME="$KIMI_TRUST_HOME" \
    node "$PLUGIN_DIR/scripts/duet-native-register.js" \
      trust-kimi-workspace "$WT_A"
  KIMI_CODE_HOME="$KIMI_TRUST_HOME" \
    node "$PLUGIN_DIR/scripts/duet-native-register.js" \
      trust-kimi-workspace "$WT_A"
  TRUST_FILE="$(find "$KIMI_TRUST_HOME/workspace-trust" -type f -maxdepth 1 \
    -print -quit)"
  [ -n "$TRUST_FILE" ] \
    || die "Kimi workspace pretrust did not publish a record"
  [ "$(find "$KIMI_TRUST_HOME/workspace-trust" -type f | wc -l | tr -d ' ')" = 1 ] \
    || die "idempotent Kimi workspace pretrust published duplicate records"
  TRUST_ROOT="$(node -e \
    'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).root)' \
    "$TRUST_FILE")"
  [ "$TRUST_ROOT" = "$(cd "$WT_A" && pwd -P)" ] \
    || die "Kimi workspace pretrust recorded the wrong root"
  printf '{"root":"/wrong","trustedAt":1}\n' > "$TRUST_FILE"
  if KIMI_CODE_HOME="$KIMI_TRUST_HOME" \
      node "$PLUGIN_DIR/scripts/duet-native-register.js" \
        trust-kimi-workspace "$WT_A" >/dev/null 2>&1; then
    die "Kimi workspace pretrust accepted a conflicting owned record"
  fi
  grep -qF '"root":"/wrong"' "$TRUST_FILE" \
    || die "Kimi workspace pretrust overwrote a conflicting record"
) || die "registration helper unit checks failed"
printf 'PASS exact registration and Kimi pretrust are ownership-safe\n'

# =================== Cycle A: claude initiator ==============================
PANE_A="$(start_initiator_pane cycle-a claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$CLAUDE_INIT_ID")"
MARK_A1="$(wc -l < "$ARGV_LOG" 2>/dev/null || printf 0)"
MARK_A1=$((MARK_A1 + 1))
REMAINING_ROSTER='codex kimi claude'
run_agent_cmd "$WT_A" "$PANE_A" "$ROOT/run-a1-init.log" "$INIT" "" claude \
  CLAUDE_CODE_SESSION_ID="$CLAUDE_INIT_ID" \
  || die "cycle A init failed"
DIR_A1="$(session_dir_from "$ROOT/run-a1-init.log")"
[ -d "$DIR_A1" ] || die "cycle A session dir missing"

# Fresh capture: complete record, correct ids and provenance.
[ -f "$DIR_A1/pairing.complete" ] || die "cycle A pairing not complete"
[ "$(cat "$DIR_A1/pairing.complete")" = "$(basename "$DIR_A1")" ] \
  || die "cycle A complete marker mismatches the session id"
[ "$(pairing_field "$DIR_A1" claude 3)" = "$CLAUDE_INIT_ID" ] \
  || die "initiator native id not captured from the environment"
[ "$(pairing_field "$DIR_A1" claude 4)" = env ] \
  || die "initiator provenance is not env"
CODEX_A_ID="$(pairing_field "$DIR_A1" codex-1 3)"
KIMI_A_ID="$(pairing_field "$DIR_A1" kimi-1 3)"
CLAUDE_W_ID="$(pairing_field "$DIR_A1" claude-1 3)"
[ -n "$CODEX_A_ID" ] || die "codex-1 native id not captured"
ls "$CODEX_SESSIONS" | grep -q -- "-$CODEX_A_ID\.jsonl" \
  || die "codex-1 native id does not resolve to a rollout file"
grep -qF "\"$KIMI_A_ID\"" "$KIMI_INDEX" \
  || die "kimi-1 native id missing from the session index"
[ "$(pairing_field "$DIR_A1" claude-1 4)" = assigned ] \
  || die "claude-1 provenance is not assigned"
argv_since "$MARK_A1" claude-1 | grep -q -- "--session-id $CLAUDE_W_ID" \
  || die "claude-1 was not launched with its assigned --session-id"
HISTORY_LINE="$(tail -n 1 "$STATE_ROOT/pairings/"*/history | awk -F '\t' '{print $2}')"
[ "$HISTORY_LINE" = "$DIR_A1" ] \
  || die "repo history does not name cycle A as its newest complete pairing"
[ "$(tail -n 1 "$STATE_ROOT/pairings/"*/by-id/"claude-"*-"$CLAUDE_INIT_ID")" = "$DIR_A1" ] \
  || die "by-id index does not name cycle A for the initiator's native id"
printf 'PASS fresh capture publishes a complete, provenance-tagged pairing\n'

# Leave one undelivered message behind: fence codex-1, then hand-craft the
# queue head exactly as enqueue would have published it (sequence 2 — the boot
# kick already consumed sequence 1, and a repeated id would be dedup-archived).
mkdir -p "$DIR_A1/blocked"
printf 'test\tfence\n' > "$DIR_A1/blocked/codex-1"
printf '2\n' > "$DIR_A1/inbox/codex-1/.counter"
{
  printf 'DUETv4\n'
  printf 'id\tm-%s-codex-1-0000000002\n' "$(basename "$DIR_A1")"
  printf 'session\t%s\n' "$(basename "$DIR_A1")"
  printf 'mode\tNORMAL\n'
  printf 'sender\tclaude\n'
  printf 'recipient\tcodex-1\n'
  printf 'body64\t%s\n' "$(printf 'undelivered' | base64 | tr -d '\r\n')"
} > "$DIR_A1/inbox/codex-1/N-0000000002.msg"
sleep 1
[ -f "$DIR_A1/inbox/codex-1/N-0000000002.msg" ] \
  || die "fenced queue head was delivered; cannot test no-replay"

end_as "$DIR_A1/duet.env" claude || die "cycle A teardown failed"
[ -f "$DIR_A1/.ended" ] || die "cycle A ended marker missing"

# Clean end + rejoin: whole roster, stable names, native resume flags,
# diagnostics note, no queue replay.
MARK_A2=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_A" "$ROOT/run-a2-rejoin.log" "$REJOIN" \
  "$CLAUDE_INIT_ID" claude || die "cycle A rejoin failed"
DIR_A2="$(session_dir_from "$ROOT/run-a2-rejoin.log")"
[ -n "$DIR_A2" ] && [ "$DIR_A2" != "$DIR_A1" ] \
  || die "rejoin did not create a fresh transport run"
grep -q "rejoining ensemble from pairing at $DIR_A1" "$ROOT/run-a2-rejoin.log" \
  || die "rejoin did not announce its pairing source"
for name in codex-1 kimi-1 claude-1; do
  awk -F '\t' -v n="$name" 'NR > 1 && $1 == n && $6 == 1 { found=1 }
    END { exit !found }' "$DIR_A2/roster.tsv" \
    || die "rejoined roster lost spawned worker $name"
done
awk -F '\t' 'NR > 1 && $1 == "claude" && $5 == 0 && $6 == 0 { found=1 }
  END { exit !found }' "$DIR_A2/roster.tsv" \
  || die "rejoined roster does not keep claude as initiator"
argv_since "$MARK_A2" codex-1 | grep -q -- "resume $CODEX_A_ID" \
  || die "codex-1 was not relaunched with codex resume"
argv_since "$MARK_A2" kimi-1 | grep -q -- "--session $KIMI_A_ID" \
  || die "kimi-1 was not relaunched with kimi --session"
argv_since "$MARK_A2" claude-1 | grep -q -- "--resume $CLAUDE_W_ID" \
  || die "claude-1 was not relaunched with claude --resume"
grep -q 'Rejoined ensemble' "$WT_A/AGENTS.md" \
  || die "rejoin note missing from anchors"
grep -q 'stale' "$WT_A/AGENTS.md" || die "stale DUET_* warning missing"
grep -q '1 queued message(s)' "$WT_A/AGENTS.md" \
  || die "undelivered count missing from rejoin note"
grep -qF "$DIR_A1/transcript.md" "$WT_A/AGENTS.md" \
  || die "old transcript path missing from rejoin note"
if find "$DIR_A2/inbox" -name '*.msg' -print0 2>/dev/null \
    | xargs -0 grep -l "m-$(basename "$DIR_A1")-" 2>/dev/null | grep -q .; then
  die "rejoined run replayed or inherited old queue files"
fi
[ -f "$DIR_A2/pairing.complete" ] || die "rejoined run did not pair completely"
printf 'PASS clean end + rejoin resumes natives, keeps names, never replays\n'

# Ended run with a stray non-invoker pane: the invoker's own surviving tuple
# may be adopted, but any other recorded live tuple must refuse.
A2_PID="$(cat "$DIR_A2/daemon.pid")"
kill -9 "$A2_PID" 2>/dev/null || true
: > "$DIR_A2/.ended"
if run_agent_cmd "$WT_A" "$PANE_A" "$ROOT/run-a3-stray.log" "$REJOIN" \
    "$CLAUDE_INIT_ID" claude; then
  die "rejoin adopted an ended run while non-invoker panes were still live"
fi
grep -qE 'rejoin refused: .*prior pane' "$ROOT/run-a3-stray.log" \
  || die "ended-run stray pane did not refuse"
rm -f "$DIR_A2/.ended"
printf 'PASS ended run adopts the invoker pane but refuses stray live tuples\n'

# Abrupt mesh death, classical native-resume-in-a-new-pane: kill the whole old
# tmux session (initiator pane included), then rejoin from a NEW pane running
# the resumed native id. Every prior tuple is dead, so this must proceed.
command tmux -L "$TMUX_LABEL" kill-session -t cycle-a
sleep 0.5
PANE_A2="$(start_initiator_pane cycle-a2 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$CLAUDE_INIT_ID")"
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_A2" "$ROOT/run-a4-rejoin.log" "$REJOIN" \
  "$CLAUDE_INIT_ID" claude || die "rejoin after abrupt death failed"
DIR_A3="$(session_dir_from "$ROOT/run-a4-rejoin.log")"
[ -n "$DIR_A3" ] && [ "$DIR_A3" != "$DIR_A2" ] \
  || die "abrupt-death rejoin did not start a new run"
grep -q "rejoining ensemble" "$ROOT/run-a4-rejoin.log" \
  || die "abrupt-death rejoin did not use the pairing"
printf 'PASS abrupt full-session death rejoins from a new resumed pane\n'

# Un-ended run, daemon alive: refuse. Then daemon dead but the current old
# pane (the invoker's own recorded tuple) still live: also refuse — an
# un-ended run requires every recorded tuple dead.
PANE_A2_PROBE="$(start_initiator_pane cycle-a2-probe claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$CLAUDE_INIT_ID")"
if run_agent_cmd "$WT_A" "$PANE_A2_PROBE" "$ROOT/run-a5-refuse.log" "$REJOIN" \
    "$CLAUDE_INIT_ID" claude; then
  die "rejoin succeeded while the previous run's daemon was alive"
fi
grep -qE 'rejoin refused: .*live prior daemon' \
  "$ROOT/run-a5-refuse.log" || die "live-daemon rejoin was not refused"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-a2-probe 2>/dev/null || true
A3_PID="$(cat "$DIR_A3/daemon.pid")"
kill -9 "$A3_PID" 2>/dev/null || true
sleep 0.3
before_count="$(session_dirs | wc -l | tr -d ' ')"
if run_agent_cmd "$WT_A" "$PANE_A2" "$ROOT/run-a6-refuse.log" "$REJOIN" \
    "$CLAUDE_INIT_ID" claude; then
  die "rejoin succeeded while the invoker's own prior pane was still live"
fi
grep -q 'rejoin refused: the invoking pane still belongs' "$ROOT/run-a6-refuse.log" \
  || die "live prior invoker tuple did not refuse on an un-ended run"
after_count="$(session_dirs | wc -l | tr -d ' ')"
[ "$before_count" = "$after_count" ] \
  || die "a refused rejoin still created a session dir"
printf 'PASS un-ended run refuses on live daemon and on any live prior tuple\n'

command tmux -L "$TMUX_LABEL" kill-session -t cycle-a2 2>/dev/null || true
sleep 0.3

PANE_A3="$(start_initiator_pane cycle-a3 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$CLAUDE_INIT_ID")"

# Missing native id: delete the codex rollout, rejoin must fall back fresh.
codex_rollout="$(ls "$CODEX_SESSIONS"/rollout-*"-$CODEX_A_ID.jsonl" 2>/dev/null | head -n 1)"
[ -n "$codex_rollout" ] || die "test setup lost the codex rollout file"
rm -f "$codex_rollout"
MARK_A6=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER='codex kimi claude'
run_agent_cmd "$WT_A" "$PANE_A3" "$ROOT/run-a8-missing.log" "$REJOIN" \
  "$CLAUDE_INIT_ID" claude || die "missing-id fallback init failed"
grep -q 'no longer resolvable' "$ROOT/run-a8-missing.log" \
  || die "missing native id did not trigger the fallback"
grep -q 'fresh, unpaired ensemble' "$ROOT/run-a8-missing.log" \
  || die "missing-id fallback was not announced as fresh"
argv_since "$MARK_A6" codex-1 | grep -qE '(^| )resume [0-9a-f]' \
  && die "fallback launched codex with a resume flag"
DIR_A6="$(session_dir_from "$ROOT/run-a8-missing.log")"
[ -n "$DIR_A6" ] || die "missing-id fallback produced no session"
printf 'PASS a missing native id falls back to a fresh unpaired ensemble\n'
end_as "$DIR_A6/duet.env" claude || die "cycle A run 6 teardown failed"

# Stale Kimi index: the index line remains but its sessionDir was deleted.
# Resolvability must require the directory, so rejoin falls back fresh.
KIMI_A6_ID="$(pairing_field "$DIR_A6" kimi-1 3)"
[ -n "$KIMI_A6_ID" ] || die "cycle A run 6 kimi id missing"
rm -rf "$KIMI_SESSIONS/wd_fake/$KIMI_A6_ID"
REMAINING_ROSTER='codex kimi claude'
run_agent_cmd "$WT_A" "$PANE_A3" "$ROOT/run-a9-stalekimi.log" "$REJOIN" \
  "$CLAUDE_INIT_ID" claude || die "stale-kimi fallback init failed"
grep -q 'no longer resolvable for: kimi-1' "$ROOT/run-a9-stalekimi.log" \
  || die "stale kimi index entry did not fail resolvability"
grep -q 'fresh, unpaired ensemble' "$ROOT/run-a9-stalekimi.log" \
  || die "stale kimi index did not fall back fresh"
DIR_A9="$(session_dir_from "$ROOT/run-a9-stalekimi.log")"
end_as "$DIR_A9/duet.env" claude || die "cycle A run 9 teardown failed"
printf 'PASS a stale kimi index line (deleted sessionDir) falls back fresh\n'
command tmux -L "$TMUX_LABEL" kill-session -t cycle-a3 2>/dev/null || true

# =================== Cycle E: corrupt/foreign records (repo2) ===============
# Fresh native ids, so the only history entries for them are made here.
E_CLAUDE_ID="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
PANE_E="$(start_initiator_pane cycle-e claude "$REPO2" \
  "CLAUDE_CODE_SESSION_ID=$E_CLAUDE_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$REPO2" "$PANE_E" "$ROOT/run-e1-init.log" "$INIT" "$E_CLAUDE_ID" claude \
  || die "cycle E init failed"
DIR_E1="$(session_dir_from "$ROOT/run-e1-init.log")"
[ -f "$DIR_E1/pairing.complete" ] || die "cycle E pairing not complete"
end_as "$DIR_E1/duet.env" claude || die "cycle E teardown failed"

# A record whose complete marker is gone is diagnostic-only and unreachable.
mv "$DIR_E1/pairing.complete" "$DIR_E1/pairing.complete.aside"
run_agent_cmd "$REPO2" "$PANE_E" "$ROOT/run-e2-incomplete.log" "$REJOIN" \
  "$E_CLAUDE_ID" claude || die "incomplete-record fallback init failed"
grep -q 'no complete pairing in this repo names the invoking native session' \
  "$ROOT/run-e2-incomplete.log" \
  || die "marker-less record was still reachable by lookup"
DIR_E2="$(session_dir_from "$ROOT/run-e2-incomplete.log")"
end_as "$DIR_E2/duet.env" claude || die "cycle E run 2 teardown failed"

# Corrupt EVERY history entry for this id; lookup must find nothing rather
# than route a malformed record.
E_PAIRINGS="$STATE_ROOT/pairings"
for pdir in "$E_PAIRINGS"/*; do
  [ -f "$pdir/history" ] || continue
  while IFS=$'\t' read -r _ts pdir_session; do
    [ -f "$pdir_session/pairing.tsv" ] || continue
    LC_ALL=C awk -F '\t' 'NR == 1 { print; next } { $12=""; OFS="\t"; print }' \
      "$pdir_session/pairing.tsv" > "$pdir_session/pairing.tsv.bad" \
      && mv "$pdir_session/pairing.tsv.bad" "$pdir_session/pairing.tsv"
  done < "$pdir/history"
done
run_agent_cmd "$REPO2" "$PANE_E" "$ROOT/run-e3-corrupt.log" "$REJOIN" \
  "$E_CLAUDE_ID" claude || die "corrupt-record fallback init failed"
grep -q 'no complete pairing in this repo names the invoking native session' \
  "$ROOT/run-e3-corrupt.log" || die "corrupt records were still reachable"
DIR_E3="$(session_dir_from "$ROOT/run-e3-corrupt.log")"
end_as "$DIR_E3/duet.env" claude || die "cycle E run 3 teardown failed"

# A foreign newest line in the id's own index must fail closed — never route
# the foreign record, and never roll back to cycle E's older valid mapping.
for pdir in "$E_PAIRINGS"/*; do
  [ -f "$pdir/history" ] || continue
  case "$(cat "$pdir/history")" in
    *"$DIR_E1"*)
      for index in "$pdir"/by-id/claude-*-"$E_CLAUDE_ID"; do
        [ -f "$index" ] || continue
        printf '%s\n' "$DIR_A1" >> "$index"
      done
      ;;
  esac
done
run_agent_cmd "$REPO2" "$PANE_E" "$ROOT/run-e4-foreign.log" "$REJOIN" \
  "$E_CLAUDE_ID" claude || die "foreign-record fallback init failed"
grep -q 'no complete pairing in this repo names the invoking native session' \
  "$ROOT/run-e4-foreign.log" \
  || die "a foreign newest index line did not fail closed"
grep -q "pairing at $DIR_E3" "$ROOT/run-e4-foreign.log" \
  && die "lookup rolled back to an older mapping past a polluted newest entry"
DIR_E4="$(session_dir_from "$ROOT/run-e4-foreign.log")"
end_as "$DIR_E4/duet.env" claude || die "cycle E run 4 teardown failed"
printf 'PASS marker-less/corrupt records are unreachable; foreign entries fail closed\n'
command tmux -L "$TMUX_LABEL" kill-session -t cycle-e 2>/dev/null || true

# =================== Cycle B: codex initiator ===============================
PANE_B="$(start_initiator_pane cycle-b codex "$WT_A" \
  "CODEX_THREAD_ID=$CODEX_INIT_ID")"
MARK_B1=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER='kimi'
run_agent_cmd "$WT_A" "$PANE_B" "$ROOT/run-b1-init.log" "$INIT" "" codex \
  CODEX_THREAD_ID="$CODEX_INIT_ID" \
  || die "cycle B init failed"
DIR_B1="$(session_dir_from "$ROOT/run-b1-init.log")"
[ "$(pairing_field "$DIR_B1" codex 3)" = "$CODEX_INIT_ID" ] \
  || die "codex initiator native id not captured from CODEX_THREAD_ID"
[ -f "$DIR_B1/pairing.complete" ] || die "cycle B pairing not complete"
KIMI_B_ID="$(pairing_field "$DIR_B1" kimi-1 3)"
[ -n "$KIMI_B_ID" ] || die "cycle B kimi-1 id missing"
end_as "$DIR_B1/duet.env" codex || die "cycle B teardown failed"

run_agent_cmd "$WT_A" "$PANE_B" "$ROOT/run-b2-rejoin.log" "$REJOIN" \
  "$CODEX_INIT_ID" codex || die "cycle B rejoin from codex failed"
DIR_B2="$(session_dir_from "$ROOT/run-b2-rejoin.log")"
awk -F '\t' 'NR > 1 && $1 == "codex" && $6 == 0 { found=1 } END { exit !found }' \
  "$DIR_B2/roster.tsv" || die "cycle B rejoin lost the codex initiator"
printf 'PASS initiator natively resumed as Codex rejoins\n'
end_as "$DIR_B2/duet.env" codex || die "cycle B run 2 teardown failed"

# Rejoin invoked from the former worker's resumed native session: kimi-1
# becomes the initiator and keeps its stable name. The old initiator pane is
# an exact recorded tuple that survives a clean end, so it must be gone first
# (a live one would rightly refuse as a stray non-invoker pane).
command tmux -L "$TMUX_LABEL" kill-session -t cycle-b 2>/dev/null || true
sleep 0.3
PANE_BK="$(start_initiator_pane cycle-b-kimi kimi "$WT_A" "KIMI_SESSION_ID=$KIMI_B_ID")"
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_BK" "$ROOT/run-b3-rejoin.log" "$REJOIN" \
  "$KIMI_B_ID" kimi || die "cycle B rejoin from former worker failed"
DIR_B3="$(session_dir_from "$ROOT/run-b3-rejoin.log")"
awk -F '\t' 'NR > 1 && $1 == "kimi-1" && $2 == "kimi" && $5 == 0 && $6 == 0 { found=1 }
  END { exit !found }' "$DIR_B3/roster.tsv" \
  || die "former worker kimi-1 did not become the initiator"
awk -F '\t' 'NR > 1 && $1 == "codex" && $6 == 1 { found=1 } END { exit !found }' \
  "$DIR_B3/roster.tsv" || die "former initiator codex was not resumed as a worker"
printf 'PASS rejoin from a former worker preserves stable roster names\n'
end_as "$DIR_B3/duet.env" kimi-1 || die "cycle B run 3 teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-b 2>/dev/null || true
command tmux -L "$TMUX_LABEL" kill-session -t cycle-b-kimi 2>/dev/null || true

# =================== Cycle C: kimi initiator ================================
PANE_C="$(start_initiator_pane cycle-c kimi "$WT_A" "KIMI_SESSION_ID=$KIMI_INIT_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$WT_A" "$PANE_C" "$ROOT/run-c1-init.log" "$INIT" "$KIMI_INIT_ID" kimi \
  || die "cycle C init failed"
DIR_C1="$(session_dir_from "$ROOT/run-c1-init.log")"
[ "$(pairing_field "$DIR_C1" kimi 3)" = "$KIMI_INIT_ID" ] \
  || die "kimi initiator native id not captured from DUET_INITIATOR_NATIVE_ID"
end_as "$DIR_C1/duet.env" kimi || die "cycle C teardown failed"
run_agent_cmd "$WT_A" "$PANE_C" "$ROOT/run-c2-rejoin.log" "$REJOIN" \
  "$KIMI_INIT_ID" kimi || die "cycle C rejoin from kimi failed"
DIR_C2="$(session_dir_from "$ROOT/run-c2-rejoin.log")"
awk -F '\t' 'NR > 1 && $1 == "kimi" && $6 == 0 { found=1 } END { exit !found }' \
  "$DIR_C2/roster.tsv" || die "cycle C rejoin lost the kimi initiator"
printf 'PASS initiator natively resumed as Kimi rejoins\n'
end_as "$DIR_C2/duet.env" kimi || die "cycle C run 2 teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-c 2>/dev/null || true

# =================== Cycle D: partial capture (repo2) =======================
PANE_D="$(start_initiator_pane cycle-d claude "$REPO2" \
  "CLAUDE_CODE_SESSION_ID=$CLAUDE_INIT_ID")"
REMAINING_ROSTER='codex kimi'
DUET_TEST_CAPTURE_TRIES=2
(
  cd "$REPO2"
  env PATH="$FAKEBIN:$PATH" HOME="$HOME" \
    DUET_STATE_ROOT="$STATE_ROOT" DUET_CONFIG= DUET_SELF= DUET_SESSION= \
    DUET_CODEX_SKIP_PRETRUST=1 DUET_BOOT_TIMEOUT=5 DUET_READY_TIMEOUT=10 \
    DUET_PAIRING_CAPTURE_TRIES=2 \
    DUET_CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS" \
    DUET_CODEX_SESSIONS_DIR="$ROOT/native-codex-elsewhere" \
    DUET_KIMI_SESSION_INDEX="$KIMI_INDEX" \
    DUET_KIMI_SESSIONS_DIR="$KIMI_SESSIONS" \
    DUET_INITIATOR_NATIVE_ID="$CLAUDE_INIT_ID" \
    TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_D" \
    bash "$INIT" --initiator claude codex kimi
) > "$ROOT/run-d1-init.log" 2>&1 || die "cycle D init failed"
DIR_D1="$(session_dir_from "$ROOT/run-d1-init.log")"
[ -f "$DIR_D1/pairing.tsv" ] || die "partial capture left no diagnostic tsv"
[ ! -f "$DIR_D1/pairing.complete" ] \
  || die "partial capture published a complete marker"
grep -q 'pairing incomplete' "$ROOT/run-d1-init.log" \
  || die "partial capture was not reported"
# An active incomplete mesh is still an owner even if its diagnostic record
# is later corrupted: refuse a second invocation until it has been ended,
# then use the ordinary fresh fallback.
D1_CORRUPT="$DIR_D1/.pairing-corrupt"
{
  printf 'corrupt-header\n'
  tail -n +2 "$DIR_D1/pairing.tsv"
} > "$D1_CORRUPT"
mv "$D1_CORRUPT" "$DIR_D1/pairing.tsv"
if run_agent_cmd "$REPO2" "$PANE_D" "$ROOT/run-d2-active.log" "$REJOIN" \
    "$CLAUDE_INIT_ID" claude; then
  die "active incomplete mesh allowed a split-brain fallback"
fi
grep -q 'still belongs to active or incomplete run' "$ROOT/run-d2-active.log" \
  || die "active incomplete mesh was not ownership-fenced"
end_as "$DIR_D1/duet.env" claude || die "cycle D incomplete teardown failed"
run_agent_cmd "$REPO2" "$PANE_D" "$ROOT/run-d2-rejoin.log" "$REJOIN" \
  "$CLAUDE_INIT_ID" claude || die "cycle D fallback init failed after end"
grep -q 'no complete pairing in this repo names the invoking native session' \
  "$ROOT/run-d2-rejoin.log" \
  || die "rejoin did not report the absent pairing for this repo"
DIR_D2="$(session_dir_from "$ROOT/run-d2-rejoin.log")"
end_as "$DIR_D2/duet.env" claude || die "cycle D teardown failed"
printf 'PASS partial capture is fenced while live, then falls fresh after end\n'

# ======= Lookup unit checks: independence, corrupt, foreign (no tmux) =======
(
  # shellcheck disable=SC1090,SC1091
  . "$COMMON"; . "$PAIRING"
  U_STATE="$ROOT/unit-state"
  U_NATIVE_HOME="$ROOT/unit-native-home"
  mkdir -p "$U_STATE" "$U_NATIVE_HOME"
  U_KEY2="$(duet_repo_key "$REPO2")"
  U_KEYROOT="$(duet_repo_key "$ROOT")"
  mk_row(){
    # name harness id workdir key sid
    case "$1" in
      claude) row_pane=%1; row_pid=4101 ;;
      codex-1) row_pane=%2; row_pid=4102 ;;
      kimi-1) row_pane=%3; row_pid=4103 ;;
      *) row_pane=%4; row_pid=4104 ;;
    esac
    printf '%s\t%s\t%s\targ\t%s\t%s\t/sock\t4242\t%s\t%s\t2026-08-07T00:00:00Z\t%s\t%s' \
      "$1" "$2" "$3" "$row_pane" "$row_pid" "$4" "$5" "$6" "$U_NATIVE_HOME"
  }
  mk_sess(){
    mktemp -d "$U_STATE/20260807-000000-XXXXXX"
  }
  unit_publish(){
    local sess="$1" work="$2" complete="$3" row name harness pane pid rank=0 spawned
    shift 3
    printf 'name\tharness\tpane_id\tpane_pid\trank\tspawned\n' > "$sess/roster.tsv"
    for row in "$@"; do
      name="$(printf '%s' "$row" | awk -F '\t' '{ print $1 }')"
      harness="$(printf '%s' "$row" | awk -F '\t' '{ print $2 }')"
      pane="$(printf '%s' "$row" | awk -F '\t' '{ print $5 }')"
      pid="$(printf '%s' "$row" | awk -F '\t' '{ print $6 }')"
      [ "$rank" = 0 ] && spawned=0 || spawned=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$harness" "$pane" "$pid" "$rank" "$spawned" \
        >> "$sess/roster.tsv"
      rank=$((rank + 1))
    done
    duet_pairing_publish "$sess" "$U_STATE" "$work" "$complete" "$@"
  }
  U_P1="$(mk_sess)"; U_P2="$(mk_sess)"; U_P3="$(mk_sess)"
  unit_publish "$U_P1" "$REPO2" 1 \
    "$(mk_row claude claude dddddddd-dddd-4ddd-8ddd-dddddddddddd "$REPO2" "$U_KEY2" "$(basename "$U_P1")")" \
    "$(mk_row codex-1 codex eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee "$REPO2" "$U_KEY2" "$(basename "$U_P1")")" \
    || die "unit: publish P1 failed"
  unit_publish "$U_P2" "$REPO2" 1 \
    "$(mk_row claude claude ffffffff-ffff-4fff-8fff-ffffffffffff "$REPO2" "$U_KEY2" "$(basename "$U_P2")")" \
    "$(mk_row kimi-1 kimi session_12121212-1212-4212-8212-121212121212 "$REPO2" "$U_KEY2" "$(basename "$U_P2")")" \
    || die "unit: publish P2 failed"
  # Independent meshes under one repo key stay independently findable.
  [ "$(duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude dddddddd-dddd-4ddd-8ddd-dddddddddddd "$U_NATIVE_HOME")" = "$U_P1" ] \
    || die "unit: lookup by A's id did not return A"
  [ "$(duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude ffffffff-ffff-4fff-8fff-ffffffffffff "$U_NATIVE_HOME")" = "$U_P2" ] \
    || die "unit: lookup by B's id did not return B"
  [ "$(duet_pairing_latest_for_id "$U_STATE" "$REPO2" codex eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee "$U_NATIVE_HOME")" = "$U_P1" ] \
    || die "unit: lookup by A's worker id did not return A"
  # A corrupt record is unreachable even when it is the only match.
  LC_ALL=C awk -F '\t' 'NR == 1 { print; next } { $12=""; OFS="\t"; print }' \
    "$U_P1/pairing.tsv" > "$U_P1/pairing.tsv.bad"
  mv "$U_P1/pairing.tsv.bad" "$U_P1/pairing.tsv"
  if duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude dddddddd-dddd-4ddd-8ddd-dddddddddddd "$U_NATIVE_HOME" >/dev/null 2>&1; then
    die "unit: corrupt record was still reachable"
  fi
  # Pollution never rolls back: valid Q1 then valid Q2 with the SAME ids, Q2's
  # marker removed — lookup must return nothing, never the older Q1.
  U_Q1="$(mk_sess)"; U_Q2="$(mk_sess)"
  unit_publish "$U_Q1" "$REPO2" 1 \
    "$(mk_row claude claude 15151515-1515-4515-8515-151515151515 "$REPO2" "$U_KEY2" "$(basename "$U_Q1")")" \
    || die "unit: publish Q1 failed"
  unit_publish "$U_Q2" "$REPO2" 1 \
    "$(mk_row claude claude 15151515-1515-4515-8515-151515151515 "$REPO2" "$U_KEY2" "$(basename "$U_Q2")")" \
    || die "unit: publish Q2 failed"
  [ "$(duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude 15151515-1515-4515-8515-151515151515 "$U_NATIVE_HOME")" = "$U_Q2" ] \
    || die "unit: newest same-id record was not selected"
  rm -f "$U_Q2/pairing.complete"
  if duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude 15151515-1515-4515-8515-151515151515 "$U_NATIVE_HOME" >/dev/null 2>&1; then
    die "unit: lookup rolled back to an older mapping after pollution"
  fi
  # Interrupted publication: tsv and by-id append exist, but the process died
  # before the complete marker. The markerless newest entry must fail closed —
  # and the older Q1 must stay unreachable behind it.
  U_Q3="$(mk_sess)"
  unit_publish "$U_Q3" "$REPO2" 0 \
    "$(mk_row claude claude 15151515-1515-4515-8515-151515151515 "$REPO2" "$U_KEY2" "$(basename "$U_Q3")")" \
    || die "unit: markerless tsv publish failed"
  printf '%s\n' "$U_Q3" \
    >> "$U_STATE/pairings/$(duet_key_hash "$U_KEY2")/by-id/claude-$(duet_key_hash "$U_NATIVE_HOME")-15151515-1515-4515-8515-151515151515"
  if duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude 15151515-1515-4515-8515-151515151515 "$U_NATIVE_HOME" >/dev/null 2>&1; then
    die "unit: an interrupted publication produced a selectable record"
  fi
  # A valid but foreign-keyed record injected as the newest index line fails
  # closed too — it must not route, and must not unearth the older record.
  unit_publish "$U_P3" "$ROOT" 1 \
    "$(mk_row claude claude 13131313-1313-4313-8313-131313131313 "$ROOT" "$U_KEYROOT" "$(basename "$U_P3")")" \
    || die "unit: publish P3 failed"
  printf '%s\n' "$U_P3" \
    >> "$U_STATE/pairings/$(duet_key_hash "$U_KEY2")/by-id/claude-$(duet_key_hash "$U_NATIVE_HOME")-13131313-1313-4313-8313-131313131313"
  if duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude 13131313-1313-4313-8313-131313131313 "$U_NATIVE_HOME" >/dev/null 2>&1; then
    die "unit: foreign-keyed newest entry routed into this repo"
  fi
  # Lookup must not depend on GNU/BSD-only tools: shadow tail with a GNU-like
  # fake that rejects -r and prove lookup still works.
  U_BIN="$ROOT/unit-bin"; mkdir -p "$U_BIN"
  cat > "$U_BIN/tail" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" -r "*) echo "tail: invalid option -- r" >&2; exit 1;; esac
exec /usr/bin/tail "$@"
FAKE
  chmod +x "$U_BIN/tail"
  [ "$(PATH="$U_BIN:$PATH" duet_pairing_latest_for_id "$U_STATE" "$REPO2" claude ffffffff-ffff-4fff-8fff-ffffffffffff "$U_NATIVE_HOME")" = "$U_P2" ] \
    || die "unit: lookup broke without a -r-capable tail"

  # Staged validation runs before any durable index append. Duplicate native
  # ids inside one harness are rejected, while the same UUID in two harness
  # namespaces is legitimate.
  U_BAD="$(mk_sess)"
  U_BAD_ID='16161616-1616-4616-8616-161616161616'
  if unit_publish "$U_BAD" "$REPO2" 1 \
      "$(mk_row claude codex "$U_BAD_ID" "$REPO2" "$U_KEY2" "$(basename "$U_BAD")")" \
      "$(mk_row codex-1 codex "$U_BAD_ID" "$REPO2" "$U_KEY2" "$(basename "$U_BAD")")"; then
    die "unit: duplicate same-harness native ids were published"
  fi
  [ ! -f "$U_BAD/pairing.complete" ] \
    || die "unit: invalid staged record received a complete marker"
  [ ! -e "$U_STATE/pairings/$(duet_key_hash "$U_KEY2")/by-id/codex-$(duet_key_hash "$U_NATIVE_HOME")-$U_BAD_ID" ] \
    || die "unit: invalid staged record advanced a by-id index"
  U_NS="$(mk_sess)"
  unit_publish "$U_NS" "$REPO2" 1 \
    "$(mk_row claude claude "$U_BAD_ID" "$REPO2" "$U_KEY2" "$(basename "$U_NS")")" \
    "$(mk_row codex-1 codex "$U_BAD_ID" "$REPO2" "$U_KEY2" "$(basename "$U_NS")")" \
    || die "unit: harness-namespaced identical UUIDs were rejected"
) || die "lookup unit checks failed"
printf 'PASS lookup and staged publication are keyed, rollback-proof, and fail-closed\n'

# ======= Cycle F: independent meshes + supersession (one git common dir) ====
F_CLAUDE_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
F_CODEX_INIT_ID="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

PANE_FA="$(start_initiator_pane cycle-fa claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$F_CLAUDE_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$WT_A" "$PANE_FA" "$ROOT/run-f1-init.log" "$INIT" "$F_CLAUDE_ID" claude \
  || die "cycle F mesh A init failed"
DIR_FA="$(session_dir_from "$ROOT/run-f1-init.log")"
[ -f "$DIR_FA/pairing.complete" ] || die "cycle F mesh A pairing not complete"
FA_CODEX_ID="$(pairing_field "$DIR_FA" codex-1 3)"
[ -n "$FA_CODEX_ID" ] || die "cycle F mesh A codex id missing"
end_as "$DIR_FA/duet.env" claude || die "cycle F mesh A teardown failed"

PANE_FB="$(start_initiator_pane cycle-fb codex "$WT_B" \
  "CODEX_THREAD_ID=$F_CODEX_INIT_ID")"
REMAINING_ROSTER='kimi'
run_agent_cmd "$WT_B" "$PANE_FB" "$ROOT/run-f2-init.log" "$INIT" "$F_CODEX_INIT_ID" codex \
  || die "cycle F mesh B init failed"
DIR_FB="$(session_dir_from "$ROOT/run-f2-init.log")"
[ -f "$DIR_FB/pairing.complete" ] || die "cycle F mesh B pairing not complete"
end_as "$DIR_FB/duet.env" codex || die "cycle F mesh B teardown failed"

# B was published after A; rejoining A from A's native id must still find A.
MARK_F3=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_FA" "$ROOT/run-f3-rejoin.log" "$REJOIN" \
  "$F_CLAUDE_ID" claude || die "cycle F rejoin of mesh A failed"
DIR_FA2="$(session_dir_from "$ROOT/run-f3-rejoin.log")"
grep -q "rejoining ensemble from pairing at $DIR_FA" "$ROOT/run-f3-rejoin.log" \
  || die "rejoin did not select mesh A's own mapping"
argv_since "$MARK_F3" codex-1 | grep -q -- "resume $FA_CODEX_ID" \
  || die "mesh A rejoin did not resume A's codex worker id"
awk -F '\t' 'NR > 1 && $1 == "codex-1" && $6 == 1 { found=1 } END { exit !found }' \
  "$DIR_FA2/roster.tsv" || die "mesh A rejoin lost the stable codex-1 name"
printf 'PASS independent meshes coexist; A rejoins from A after B publishes\n'
end_as "$DIR_FA2/duet.env" claude || die "cycle F mesh A2 teardown failed"
# A clean end intentionally leaves its invoking pane alive. Close it before a
# different former member tries to fall back fresh; the ownership fence must
# not permit two live panes from the same historical native-session set.
command tmux -L "$TMUX_LABEL" kill-pane -t "$PANE_FA" 2>/dev/null || true

# Overlapping supersession: mesh C reuses A's claude native id with a
# different roster. Rejoining A from A's codex worker (an old-only member)
# must fail closed rather than reconstruct a split-brain set.
PANE_FC="$(start_initiator_pane cycle-fc claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$F_CLAUDE_ID")"
REMAINING_ROSTER='kimi'
run_agent_cmd "$WT_A" "$PANE_FC" "$ROOT/run-f4-init.log" "$INIT" "$F_CLAUDE_ID" claude \
  || die "cycle F mesh C init failed"
DIR_FC="$(session_dir_from "$ROOT/run-f4-init.log")"
[ -f "$DIR_FC/pairing.complete" ] || die "cycle F mesh C pairing not complete"
end_as "$DIR_FC/duet.env" claude || die "cycle F mesh C teardown failed"

PANE_FX="$(start_initiator_pane cycle-fx codex "$WT_A" \
  "CODEX_THREAD_ID=$FA_CODEX_ID")"
MARK_F5=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_FX" "$ROOT/run-f5-rejoin.log" "$REJOIN" \
  "$FA_CODEX_ID" codex || die "cycle F superseded fallback init failed"
grep -q 'superseded' "$ROOT/run-f5-rejoin.log" \
  || die "superseded mapping was not detected"
grep -q 'fresh, unpaired ensemble' "$ROOT/run-f5-rejoin.log" \
  || die "superseded mapping did not fall back fresh"
argv_since "$MARK_F5" codex-1 | grep -qE '(^| )resume [0-9a-f]' \
  && die "superseded fallback resumed a worker it should not own"
DIR_FX="$(session_dir_from "$ROOT/run-f5-rejoin.log")"
end_as "$DIR_FX/duet.env" codex || die "cycle F fallback teardown failed"
printf 'PASS overlapping supersession fails closed from an old-only member\n'

for s in cycle-fa cycle-fb cycle-fc cycle-fx; do
  command tmux -L "$TMUX_LABEL" kill-session -t "$s" 2>/dev/null || true
done

# ======= Cycle G: first-ever no-arg run (the literal normal skill path) =====
# No state root, no mapping, no harness words, native id passed as a CLI
# option: rejoin must create the state root, fall back to the standard fresh
# codex+kimi default, and propagate the id to init's pairing.
G_CLAUDE_ID="14141414-1414-4414-8414-141414141414"
G_STATE="$ROOT/fresh-state"
PANE_G="$(start_initiator_pane cycle-g claude "$REPO3" \
  "CLAUDE_CODE_SESSION_ID=$G_CLAUDE_ID")"
(
  cd "$REPO3"
  env PATH="$FAKEBIN:$PATH" HOME="$HOME" \
    DUET_STATE_ROOT="$G_STATE" DUET_CONFIG= DUET_SELF= DUET_SESSION= \
    DUET_CODEX_SKIP_PRETRUST=1 DUET_BOOT_TIMEOUT=5 DUET_READY_TIMEOUT=10 \
    DUET_CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS" \
    DUET_CODEX_SESSIONS_DIR="$CODEX_SESSIONS" \
    DUET_KIMI_SESSION_INDEX="$KIMI_INDEX" \
    DUET_KIMI_SESSIONS_DIR="$KIMI_SESSIONS" \
    TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_G" \
    bash "$REJOIN" --initiator claude --initiator-native-id "$G_CLAUDE_ID"
) > "$ROOT/run-g1-firstever.log" 2>&1 || die "first-ever no-arg run failed"
[ -d "$G_STATE" ] || die "rejoin did not create a missing state root"
grep -q 'fresh, unpaired ensemble' "$ROOT/run-g1-firstever.log" \
  || die "first-ever run did not announce the fresh fallback"
DIR_G1="$(session_dir_from "$ROOT/run-g1-firstever.log")"
[ -n "$DIR_G1" ] || die "first-ever run produced no session"
for name in codex-1 kimi-1; do
  awk -F '\t' -v n="$name" 'NR > 1 && $1 == n { found=1 } END { exit !found }' \
    "$DIR_G1/roster.tsv" || die "first-ever no-arg run did not spawn $name"
done
[ "$(pairing_field "$DIR_G1" claude 3)" = "$G_CLAUDE_ID" ] \
  || die "CLI-passed --initiator-native-id was not propagated to the fallback"
[ "$(pairing_field "$DIR_G1" claude 4)" = arg ] \
  || die "propagated initiator id lost its arg provenance"
end_as "$DIR_G1/duet.env" claude || die "cycle G teardown failed"
printf 'PASS first-ever no-arg run spawns the codex+kimi default and keeps the CLI id\n'
command tmux -L "$TMUX_LABEL" kill-session -t cycle-g 2>/dev/null || true

# ======= Cycle H: stale ambient DUET_* on a former worker's fallback ========
# A resumed former worker keeps the old run's DUET_SELF and DUET_SESSION in
# its parent environment; no child script can rewrite them. Lookup fails
# closed (marker removed), the fresh fallback renames the invoker
# (codex-1 -> codex), and the pinned send/end must still work — while the
# same mismatch inside the CURRENT session stays refused.
H_CLAUDE_ID="17171717-1717-4717-8717-171717171717"
PANE_H="$(start_initiator_pane cycle-h claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$H_CLAUDE_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$WT_A" "$PANE_H" "$ROOT/run-h1-init.log" "$INIT" "$H_CLAUDE_ID" claude \
  || die "cycle H init failed"
DIR_H1="$(session_dir_from "$ROOT/run-h1-init.log")"
H_CODEX_ID="$(pairing_field "$DIR_H1" codex-1 3)"
[ -n "$H_CODEX_ID" ] || die "cycle H codex id missing"
end_as "$DIR_H1/duet.env" claude || die "cycle H teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-h 2>/dev/null || true
rm -f "$DIR_H1/pairing.complete"

# The resumed former worker's pane carries the OLD run's ambient metadata.
printf -v launch_h2 'exec env %q %q %q %q %q %q %q' \
  'DUET_CONFIG=' "DUET_SESSION=$(basename "$DIR_H1")" 'DUET_SELF=codex-1' \
  "CODEX_THREAD_ID=$H_CODEX_ID" "DUET_FAKE_CLAUDE_PROJECTS=$CLAUDE_PROJECTS" \
  "DUET_FAKE_CODEX_SESSIONS=$CODEX_SESSIONS" "$FAKEBIN/codex"
command tmux -L "$TMUX_LABEL" new-session -d -s cycle-h2 -c "$WT_A" "$launch_h2"
PANE_H2="$(command tmux -L "$TMUX_LABEL" display-message -p -t cycle-h2 '#{pane_id}')"
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_H2" "$ROOT/run-h2-rejoin.log" "$REJOIN" \
  "$H_CODEX_ID" codex || die "cycle H fallback init failed"
grep -q 'fresh, unpaired ensemble' "$ROOT/run-h2-rejoin.log" \
  || die "cycle H did not fall back fresh past the polluted mapping"
DIR_H2="$(session_dir_from "$ROOT/run-h2-rejoin.log")"
[ -n "$DIR_H2" ] || die "cycle H fallback produced no session"
awk -F '\t' 'NR > 1 && $1 == "codex" && $5 == 0 && $6 == 0 { found=1 } END { exit !found }' \
  "$DIR_H2/roster.tsv" || die "fallback did not rename the former worker to codex"

# The pinned send works from the stale ambient pair, and says so.
printf 'stale-env-send' | env \
  TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_H2" \
  DUET_SELF=codex-1 DUET_SESSION="$(basename "$DIR_H1")" \
  DUET_CONFIG="$DIR_H2/duet.env" \
  bash "$SCRIPTS/duet-send.sh" kimi-1 --from codex > "$ROOT/run-h3-send.log" 2>&1 \
  || { cat "$ROOT/run-h3-send.log" >&2; die "pinned send from stale ambient env failed"; }
grep -q "ignoring stale DUET_SELF/DUET_SESSION" "$ROOT/run-h3-send.log" \
  || die "stale ambient pair was not reported"
grep -q 'queued m-' "$ROOT/run-h3-send.log" || die "stale-env send was not queued"
wait_for_delivered "$DIR_H2/duet.env" 'stale-env-send' \
  || die "stale-env send was not delivered"

# A mismatched DUET_SELF naming THIS session is still refused.
if printf 'x' | env TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_H2" \
    DUET_SELF=codex-1 DUET_SESSION="$(basename "$DIR_H2")" \
    DUET_CONFIG="$DIR_H2/duet.env" \
    bash "$SCRIPTS/duet-send.sh" kimi-1 --from codex > "$ROOT/run-h4-send.log" 2>&1; then
  die "current-session DUET_SELF mismatch was accepted"
fi
grep -q 'identity mismatch' "$ROOT/run-h4-send.log" \
  || die "current-session mismatch was not the identity error"
grep -q 'may retain an earlier run' "$WT_A/AGENTS.md" \
  || die "fresh fallback anchor is missing the stale-context warning"
grep -q "$DIR_H2" "$WT_A/AGENTS.md" \
  || die "fresh fallback anchor does not pin the new session dir"

# The pinned end works from the stale ambient pair too; the caller survives.
env TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0" TMUX_PANE="$PANE_H2" \
  DUET_SELF=codex-1 DUET_SESSION="$(basename "$DIR_H1")" \
  DUET_CONFIG="$DIR_H2/duet.env" \
  bash "$SCRIPTS/duet-end.sh" > "$ROOT/run-h5-end.log" 2>&1 \
  || { cat "$ROOT/run-h5-end.log" >&2; die "pinned end from stale ambient env failed"; }
[ -f "$DIR_H2/.ended" ] || die "stale-env end did not publish .ended"
pane_alive "$PANE_H2" || die "stale-env end killed the caller pane"
printf 'PASS stale ambient DUET_* from a former worker neither blocks nor authorizes\n'
command tmux -L "$TMUX_LABEL" kill-session -t cycle-h2 2>/dev/null || true

# ======= Cycle I: every initiator + four repeated workers ==================
# Claude -> four Codex workers. codex-1 deliberately registers last while an
# unrelated rollout appears first; exact pane-hook attribution must still
# produce four unique worker ids and preserve each one on rejoin.
I_CLAUDE_ID='18181818-1818-4818-8818-181818181818'
I_UNRELATED_ID='19191919-1919-4919-8919-191919191919'
PANE_I1="$(start_initiator_pane cycle-i1 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$I_CLAUDE_ID")"
command tmux -L "$TMUX_LABEL" set-environment -g \
  DUET_FAKE_REGISTRATION_DELAY_NAME codex-1
command tmux -L "$TMUX_LABEL" set-environment -g \
  DUET_FAKE_REGISTRATION_DELAY_SECONDS 0.7
(
  sleep 0.1
  mkdir -p "$CODEX_SESSIONS/2099/01/01"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' \
    "$I_UNRELATED_ID" "$WT_A" \
    > "$CODEX_SESSIONS/2099/01/01/rollout-2099-01-01T00-00-00-$I_UNRELATED_ID.jsonl"
) &
I_UNRELATED_PID=$!
REMAINING_ROSTER='codex codex codex codex'
run_agent_cmd "$WT_A" "$PANE_I1" "$ROOT/run-i1-init.log" "$INIT" \
  "$I_CLAUDE_ID" claude \
  || die "cycle I Claude + four Codex init failed"
command tmux -L "$TMUX_LABEL" set-environment -gu \
  DUET_FAKE_REGISTRATION_DELAY_NAME
command tmux -L "$TMUX_LABEL" set-environment -gu \
  DUET_FAKE_REGISTRATION_DELAY_SECONDS
wait "$I_UNRELATED_PID"
DIR_I1="$(session_dir_from "$ROOT/run-i1-init.log")"
[ -f "$DIR_I1/pairing.complete" ] || die "four Codex workers did not pair"
[ "$(awk -F '\t' 'NR > 1 && $2=="codex" { n++ } END { print n+0 }' \
    "$DIR_I1/pairing.tsv")" -eq 4 ] || die "four Codex rows were not published"
awk -F '\t' -v unrelated="$I_UNRELATED_ID" '
  NR > 1 && $2=="codex" {
    if ($3==unrelated || $4!="hook" || seen[$3]++) exit 1
    n++
  }
  END { exit !(n==4) }
' "$DIR_I1/pairing.tsv" || die "repeated Codex hook attribution was polluted"
I1_CODEX_IDS=()
for i in 1 2 3 4; do
  I1_CODEX_IDS+=("$(pairing_field "$DIR_I1" "codex-$i" 3)")
done
end_as "$DIR_I1/duet.env" claude || die "cycle I1 teardown failed"
MARK_I1=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_I1" "$ROOT/run-i1-rejoin.log" "$REJOIN" \
  "$I_CLAUDE_ID" claude || die "cycle I Claude + four Codex rejoin failed"
DIR_I1R="$(session_dir_from "$ROOT/run-i1-rejoin.log")"
for i in 1 2 3 4; do
  [ "$(pairing_field "$DIR_I1R" "codex-$i" 3)" = "${I1_CODEX_IDS[$((i - 1))]}" ] \
    || die "codex-$i did not retain its native session"
  argv_since "$MARK_I1" "codex-$i" \
    | grep -q -- "resume ${I1_CODEX_IDS[$((i - 1))]}" \
    || die "codex-$i did not receive its exact resume id"
done
end_as "$DIR_I1R/duet.env" claude || die "cycle I1 rejoin teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-i1 2>/dev/null || true

# Codex -> four Kimi workers.
I_CODEX_ID='20202020-2020-4020-8020-202020202020'
PANE_I2="$(start_initiator_pane cycle-i2 codex "$WT_A" \
  "CODEX_THREAD_ID=$I_CODEX_ID")"
REMAINING_ROSTER='kimi kimi kimi kimi'
run_agent_cmd "$WT_A" "$PANE_I2" "$ROOT/run-i2-init.log" "$INIT" \
  "$I_CODEX_ID" codex || die "cycle I Codex + four Kimi init failed"
DIR_I2="$(session_dir_from "$ROOT/run-i2-init.log")"
[ -f "$DIR_I2/pairing.complete" ] || die "four Kimi workers did not pair"
awk -F '\t' '
  NR > 1 && $2=="kimi" { if ($4!="hook" || seen[$3]++) exit 1; n++ }
  END { exit !(n==4) }
' "$DIR_I2/pairing.tsv" || die "repeated Kimi hook attribution was not unique"
I2_KIMI_IDS=()
for i in 1 2 3 4; do
  I2_KIMI_IDS+=("$(pairing_field "$DIR_I2" "kimi-$i" 3)")
done
end_as "$DIR_I2/duet.env" codex || die "cycle I2 teardown failed"
MARK_I2=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_I2" "$ROOT/run-i2-rejoin.log" "$REJOIN" \
  "$I_CODEX_ID" codex || die "cycle I Codex + four Kimi rejoin failed"
DIR_I2R="$(session_dir_from "$ROOT/run-i2-rejoin.log")"
for i in 1 2 3 4; do
  [ "$(pairing_field "$DIR_I2R" "kimi-$i" 3)" = "${I2_KIMI_IDS[$((i - 1))]}" ] \
    || die "kimi-$i did not retain its native session"
  argv_since "$MARK_I2" "kimi-$i" \
    | grep -q -- "--session ${I2_KIMI_IDS[$((i - 1))]}" \
    || die "kimi-$i did not receive its exact resume id"
done
end_as "$DIR_I2R/duet.env" codex || die "cycle I2 rejoin teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-i2 2>/dev/null || true

# Kimi -> four Claude workers.
I_KIMI_ID='session_21212121-2121-4121-8121-212121212121'
PANE_I3="$(start_initiator_pane cycle-i3 kimi "$WT_A" \
  "KIMI_SESSION_ID=$I_KIMI_ID")"
REMAINING_ROSTER='claude claude claude claude'
run_agent_cmd "$WT_A" "$PANE_I3" "$ROOT/run-i3-init.log" "$INIT" \
  "$I_KIMI_ID" kimi || die "cycle I Kimi + four Claude init failed"
DIR_I3="$(session_dir_from "$ROOT/run-i3-init.log")"
[ -f "$DIR_I3/pairing.complete" ] || die "four Claude workers did not pair"
awk -F '\t' '
  NR > 1 && $2=="claude" { if ($4!="assigned" || seen[$3]++) exit 1; n++ }
  END { exit !(n==4) }
' "$DIR_I3/pairing.tsv" || die "repeated Claude assigned ids were not unique"
I3_CLAUDE_IDS=()
for i in 1 2 3 4; do
  I3_CLAUDE_IDS+=("$(pairing_field "$DIR_I3" "claude-$i" 3)")
done
end_as "$DIR_I3/duet.env" kimi || die "cycle I3 teardown failed"
MARK_I3=$(( $(wc -l < "$ARGV_LOG") + 1 ))
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_I3" "$ROOT/run-i3-rejoin.log" "$REJOIN" \
  "$I_KIMI_ID" kimi || die "cycle I Kimi + four Claude rejoin failed"
DIR_I3R="$(session_dir_from "$ROOT/run-i3-rejoin.log")"
for i in 1 2 3 4; do
  [ "$(pairing_field "$DIR_I3R" "claude-$i" 3)" = "${I3_CLAUDE_IDS[$((i - 1))]}" ] \
    || die "claude-$i did not retain its native session"
  argv_since "$MARK_I3" "claude-$i" \
    | grep -q -- "--resume ${I3_CLAUDE_IDS[$((i - 1))]}" \
    || die "claude-$i did not receive its exact resume id"
done
end_as "$DIR_I3R/duet.env" kimi || die "cycle I3 rejoin teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-i3 2>/dev/null || true
printf 'PASS all initiators restore four repeated workers with exact native ids\n'

# ======= Cycle J: non-alphabetic mixed order + former-worker initiator =====
J_KIMI_ID='session_22222222-aaaa-4222-8222-222222222222'
PANE_J1="$(start_initiator_pane cycle-j1 kimi "$WT_A" \
  "KIMI_SESSION_ID=$J_KIMI_ID")"
REMAINING_ROSTER='kimi claude codex kimi'
run_agent_cmd "$WT_A" "$PANE_J1" "$ROOT/run-j1-init.log" "$INIT" \
  "$J_KIMI_ID" kimi || die "cycle J mixed init failed"
DIR_J1="$(session_dir_from "$ROOT/run-j1-init.log")"
J_CLAUDE_ID="$(pairing_field "$DIR_J1" claude-1 3)"
[ -n "$J_CLAUDE_ID" ] || die "cycle J former-worker id missing"
J_ORDER="$(awk -F '\t' 'NR > 1 { out=out (out?",":"") $1 } END { print out }' \
  "$DIR_J1/roster.tsv")"
[ "$J_ORDER" = 'kimi,kimi-1,claude-1,codex-1,kimi-2' ] \
  || die "cycle J initial roster order changed: $J_ORDER"
end_as "$DIR_J1/duet.env" kimi || die "cycle J teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-j1 2>/dev/null || true

PANE_J2="$(start_initiator_pane cycle-j2 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$J_CLAUDE_ID")"
REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_J2" "$ROOT/run-j2-rejoin.log" "$REJOIN" \
  "$J_CLAUDE_ID" claude || die "cycle J former-worker rejoin failed"
DIR_J2="$(session_dir_from "$ROOT/run-j2-rejoin.log")"
J_REJOIN_ORDER="$(awk -F '\t' 'NR > 1 { out=out (out?",":"") $1 } END { print out }' \
  "$DIR_J2/roster.tsv")"
[ "$J_REJOIN_ORDER" = 'claude-1,kimi,kimi-1,codex-1,kimi-2' ] \
  || die "cycle J rejoin sorted or renamed the roster: $J_REJOIN_ORDER"
end_as "$DIR_J2/duet.env" claude-1 || die "cycle J rejoin teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-j2 2>/dev/null || true
printf 'PASS former-worker rejoin preserves stable names and original row order\n'

# ======= Cycle K: missing/corrupt hook registration stays diagnostic =======
K_CLAUDE_ID='23232323-2323-4323-8323-232323232323'
PANE_K1="$(start_initiator_pane cycle-k1 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$K_CLAUDE_ID")"
command tmux -L "$TMUX_LABEL" set-environment -g \
  DUET_FAKE_DISABLE_REGISTRATION_NAME codex-2
REMAINING_ROSTER='codex codex'
run_agent_cmd "$WT_A" "$PANE_K1" "$ROOT/run-k1-missing-hook.log" "$INIT" \
  "$K_CLAUDE_ID" claude \
  || die "cycle K missing-hook transport init failed"
command tmux -L "$TMUX_LABEL" set-environment -gu \
  DUET_FAKE_DISABLE_REGISTRATION_NAME
DIR_K1="$(session_dir_from "$ROOT/run-k1-missing-hook.log")"
[ -f "$DIR_K1/pairing.tsv" ] && [ ! -f "$DIR_K1/pairing.complete" ] \
  || die "missing one hook registration did not remain diagnostic"
end_as "$DIR_K1/duet.env" claude || die "cycle K1 teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-k1 2>/dev/null || true

K2_CLAUDE_ID='24242424-2424-4424-8424-242424242424'
PANE_K2="$(start_initiator_pane cycle-k2 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$K2_CLAUDE_ID")"
command tmux -L "$TMUX_LABEL" set-environment -g \
  DUET_FAKE_REGISTRATION_CORRUPT_NAME codex-1
REMAINING_ROSTER='codex'
run_agent_cmd "$WT_A" "$PANE_K2" "$ROOT/run-k2-corrupt-hook.log" "$INIT" \
  "$K2_CLAUDE_ID" claude \
  || die "cycle K corrupt-hook transport init failed"
command tmux -L "$TMUX_LABEL" set-environment -gu \
  DUET_FAKE_REGISTRATION_CORRUPT_NAME
DIR_K2="$(session_dir_from "$ROOT/run-k2-corrupt-hook.log")"
[ -f "$DIR_K2/pairing.tsv" ] && [ ! -f "$DIR_K2/pairing.complete" ] \
  || die "corrupt hook registration advanced a complete pairing"
end_as "$DIR_K2/duet.env" claude || die "cycle K2 teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-k2 2>/dev/null || true

K3_CLAUDE_ID='27272727-2727-4727-8727-272727272727'
PANE_K3="$(start_initiator_pane cycle-k3 claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$K3_CLAUDE_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$WT_A" "$PANE_K3" "$ROOT/run-k3-old-codex.log" "$INIT" \
  "$K3_CLAUDE_ID" claude DUET_CODEX_SKIP_PRETRUST= \
  DUET_FAKE_CODEX_HOOK_STATE=absent \
  || die "cycle K unsupported-hook Codex transport failed"
DIR_K3="$(session_dir_from "$ROOT/run-k3-old-codex.log")"
[ -f "$DIR_K3/pairing.tsv" ] && [ ! -f "$DIR_K3/pairing.complete" ] \
  || die "Codex without hook support published a pairing"
grep -q 'worker will still launch' "$ROOT/run-k3-old-codex.log" \
  || die "Codex hook capability fallback was not reported"
end_as "$DIR_K3/duet.env" claude || die "cycle K3 teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-k3 2>/dev/null || true
printf 'PASS missing/corrupt/unsupported hooks keep transport live and pairing unreachable\n'

# ======= Cycle L: resolvable resume that dies cannot supersede ==============
L_CLAUDE_ID='25252525-2525-4525-8525-252525252525'
PANE_L="$(start_initiator_pane cycle-l claude "$WT_A" \
  "CLAUDE_CODE_SESSION_ID=$L_CLAUDE_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$WT_A" "$PANE_L" "$ROOT/run-l1-init.log" "$INIT" \
  "$L_CLAUDE_ID" claude || die "cycle L base init failed"
DIR_L1="$(session_dir_from "$ROOT/run-l1-init.log")"
L_HOME="$(pairing_field "$DIR_L1" claude 13)"
end_as "$DIR_L1/duet.env" claude || die "cycle L base teardown failed"

REMAINING_ROSTER=''
command tmux -L "$TMUX_LABEL" set-environment -g \
  DUET_FAKE_EXIT_ON_RESUME_NAME codex-1
if run_agent_cmd "$WT_A" "$PANE_L" "$ROOT/run-l2-dead-resume.log" "$REJOIN" \
    "$L_CLAUDE_ID" claude DUET_BOOT_TIMEOUT=1 DUET_READY_TIMEOUT=1; then
  die "cycle L accepted a worker that died during native resume"
fi
command tmux -L "$TMUX_LABEL" set-environment -gu \
  DUET_FAKE_EXIT_ON_RESUME_NAME
DIR_L2="$(session_dir_from "$ROOT/run-l2-dead-resume.log")"
[ -n "$DIR_L2" ] && [ -f "$DIR_L2/pairing.tsv" ] \
  || die "cycle L failed resume left no diagnostic run"
[ ! -f "$DIR_L2/pairing.complete" ] \
  || die "cycle L failed resume superseded the complete mapping"
L_LATEST="$(
  # shellcheck disable=SC1090,SC1091
  . "$COMMON"; . "$PAIRING"
  duet_pairing_latest_for_id "$STATE_ROOT" "$WT_A" claude "$L_CLAUDE_ID" "$L_HOME"
)"
[ "$L_LATEST" = "$DIR_L1" ] \
  || die "cycle L failed resume advanced or lost the last good mapping"
if run_agent_cmd "$WT_A" "$PANE_L" "$ROOT/run-l2-active-retry.log" "$REJOIN" \
    "$L_CLAUDE_ID" claude; then
  die "cycle L retried while the failed diagnostic run was still active"
fi
grep -q 'still belongs to active or incomplete run' \
  "$ROOT/run-l2-active-retry.log" \
  || die "cycle L active diagnostic run was not ownership-fenced"
end_as "$DIR_L2/duet.env" claude || die "cycle L failed-run teardown failed"

REMAINING_ROSTER=''
run_agent_cmd "$WT_A" "$PANE_L" "$ROOT/run-l3-rejoin.log" "$REJOIN" \
  "$L_CLAUDE_ID" claude || die "cycle L could not retry the last good mapping"
DIR_L3="$(session_dir_from "$ROOT/run-l3-rejoin.log")"
grep -q "rejoining ensemble from pairing at $DIR_L1" "$ROOT/run-l3-rejoin.log" \
  || die "cycle L retry did not use the last good mapping"
end_as "$DIR_L3/duet.env" claude || die "cycle L retry teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-l 2>/dev/null || true
printf 'PASS failed native resume cannot advance indexes; the last good map retries\n'

# ======= Cycle M: repository move + Kimi cwd compatibility =================
M_CLAUDE_ID='26262626-2626-4626-8626-262626262626'
PANE_M1="$(start_initiator_pane cycle-m1 claude "$REPO_MOVE_A" \
  "CLAUDE_CODE_SESSION_ID=$M_CLAUDE_ID")"
REMAINING_ROSTER='codex'
run_agent_cmd "$REPO_MOVE_A" "$PANE_M1" "$ROOT/run-m1-init.log" "$INIT" \
  "$M_CLAUDE_ID" claude || die "cycle M pre-move init failed"
DIR_M1="$(session_dir_from "$ROOT/run-m1-init.log")"
[ -f "$REPO_MOVE_A/.git/duet-agents-repo-id" ] \
  || die "cycle M did not create the durable repo identity"
end_as "$DIR_M1/duet.env" claude || die "cycle M pre-move teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-m1 2>/dev/null || true
mv "$REPO_MOVE_A" "$REPO_MOVE_B"

PANE_M2="$(start_initiator_pane cycle-m2 claude "$REPO_MOVE_B" \
  "CLAUDE_CODE_SESSION_ID=$M_CLAUDE_ID")"
REMAINING_ROSTER=''
run_agent_cmd "$REPO_MOVE_B" "$PANE_M2" "$ROOT/run-m2-rejoin.log" "$REJOIN" \
  "$M_CLAUDE_ID" claude || die "cycle M whole-repo move rejoin failed"
DIR_M2="$(session_dir_from "$ROOT/run-m2-rejoin.log")"
grep -q "rejoining ensemble from pairing at $DIR_M1" "$ROOT/run-m2-rejoin.log" \
  || die "cycle M moved repository did not retain its lineage"
[ "$(pairing_field "$DIR_M2" claude 9)" = "$REPO_MOVE_B" ] \
  || die "cycle M did not re-anchor the new workdir"
grep -qF "$DIR_M2" "$REPO_MOVE_B/AGENTS.md" \
  || die "cycle M anchor did not pin the new transport"
end_as "$DIR_M2/duet.env" claude || die "cycle M moved-run teardown failed"
command tmux -L "$TMUX_LABEL" kill-session -t cycle-m2 2>/dev/null || true

I2_KIMI_HOME="$(pairing_field "$DIR_I2" kimi-1 13)"
if (
  # shellcheck disable=SC1090,SC1091
  . "$COMMON"; . "$PAIRING"
  duet_native_session_resumable kimi "${I2_KIMI_IDS[0]}" \
    "$I2_KIMI_HOME" "$WT_A" "$WT_B"
); then
  die "Kimi cross-workdir resume was treated as supported"
fi
printf 'PASS durable repo identity survives moves; incompatible Kimi cwd fails fresh\n'

printf '==== ALL V4 M4 REJOIN TESTS PASS ====\n'
