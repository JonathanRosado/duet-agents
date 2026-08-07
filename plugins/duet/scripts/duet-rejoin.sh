#!/usr/bin/env bash
# Rebuild a duet mesh around the harness-native sessions recorded by an
# earlier run's pairing, preserving stable roster names.
#
# Every rejoin is a brand-new transport run: new session dir, daemon, roster
# tuples, inboxes, and message-id namespace. Nothing is revived and no old
# queue is replayed. Lookup is fail-closed: any missing, stale, ambiguous, or
# unverifiable input falls back to an ordinary fresh duet-init. The one hard
# refusal is a still-live prior pane tuple (or a still-running daemon) on an
# un-ended session, because two meshes must never own the same agent.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-pairing.sh"

usage(){
  echo "usage: duet-rejoin.sh [--initiator claude|codex|kimi] [--initiator-native-id <id>] [--initiator-native-home <dir>] [codex|kimi|claude ...]" >&2
}

INIT="$SELF_DIR/duet-init.sh"
initiator_harness="${DUET_INITIATOR_HARNESS:-}"
initiator_native_id="${DUET_INITIATOR_NATIVE_ID:-}"
initiator_native_home="${DUET_INITIATOR_NATIVE_HOME:-}"
workers=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --initiator)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_harness="$2"; shift 2 ;;
    --initiator-native-id)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_native_id="$2"; shift 2 ;;
    --initiator-native-home)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      initiator_native_home="$2"; shift 2 ;;
    --) shift; workers+=("$@"); break ;;
    -*) usage; echo "duet: unknown option '$1'" >&2; exit 2 ;;
    *) workers+=("$1"); shift ;;
  esac
done

refuse(){
  echo "duet: rejoin refused: $1" >&2
  exit 3
}

tuple_is_live(){
  local socket="${1:-}" server_pid="${2:-}" pane="${3:-}" pane_pid="${4:-}"
  local actual_server actual_pid
  actual_server="$(tmux -S "$socket" display-message -p '#{pid}' 2>/dev/null || true)"
  [ -n "$actual_server" ] && [ "$actual_server" = "$server_pid" ] || return 1
  actual_pid="$(tmux -S "$socket" display-message -p -t "$pane" \
    '#{pane_pid}' 2>/dev/null || true)"
  [ "$actual_pid" = "$pane_pid" ]
}

# A missing/polluted index is not permission to start a second mesh. Before
# every fresh fallback, scan diagnostic records for (a) this exact live pane
# tuple or (b) a live prior owner of the same native session. This scan never
# resumes an older mapping; it is an ownership fence only.
refuse_live_fallback_ownership(){
  local dir tsv ended contains_id row_name row_harness row_id pane pane_pid socket server_pid
  local daemon_pid rowno row_count
  [ -d "${DUET_STATE_ROOT:-}" ] || return 0
  duet_capture_caller_identity || return 0
  for dir in "$DUET_STATE_ROOT"/*-*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    tsv="$dir/pairing.tsv"
    # This is an ownership fence, not a resume candidate. Inspect exact tuple
    # fields even when the diagnostic TSV's header or another row is corrupt:
    # corrupting metadata must never become permission to start a second mesh.
    duet_regular_file_without_nul "$tsv" || continue
    ended=""
    [ ! -f "$dir/.ended" ] || ended=1

    # The exact caller tuple catches an active incomplete mesh even when no
    # native id was captured and therefore no by-id index exists.
    if LC_ALL=C awk -F '\t' \
        -v socket="$DUET_CALLER_SOCKET" -v spid="$DUET_CALLER_SERVER_PID" \
        -v pane="$DUET_CALLER_PANE" -v ppid="$DUET_CALLER_PANE_PID" \
        'NR > 1 && $5==pane && $6==ppid && $7==socket && $8==spid { found=1 }
         END { exit !found }' "$tsv" 2>/dev/null; then
      [ -n "$ended" ] \
        || refuse "the invoking pane still belongs to active or incomplete run $dir; end it first"
    fi

    contains_id=""
    if [ -n "${invoker_id:-}" ] \
        && LC_ALL=C awk -F '\t' -v h="$initiator_harness" -v id="$invoker_id" \
          -v home="${invoker_home:-}" \
          'NR > 1 && $2==h && $3==id && $13==home { found=1 }
           END { exit !found }' "$tsv" 2>/dev/null; then
      contains_id=1
    fi
    [ -n "$contains_id" ] || continue

    if [ -z "$ended" ]; then
      daemon_pid="$(cat "$dir/daemon.pid" 2>/dev/null || true)"
      case "$daemon_pid" in
        ''|*[!0-9]*) : ;;
        *)
          if kill -0 "$daemon_pid" 2>/dev/null \
              && duet_daemon_process_matches "$daemon_pid" "$dir/duet.env" \
                "$(basename "$dir")"; then
            refuse "native session $invoker_id still has a live prior daemon in $dir"
          fi
          ;;
      esac
    fi

    row_count="$(LC_ALL=C awk 'END { print NR+0 }' "$tsv")"
    for rowno in $(seq 2 "$row_count"); do
      row_name="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $1 }' "$tsv")"
      pane="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $5 }' "$tsv")"
      pane_pid="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $6 }' "$tsv")"
      socket="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $7 }' "$tsv")"
      server_pid="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $8 }' "$tsv")"
      if tuple_is_live "$socket" "$server_pid" "$pane" "$pane_pid"; then
        # A clean end may leave exactly the invoking member's own pane alive.
        if [ -n "$ended" ] \
            && [ "$pane" = "$DUET_CALLER_PANE" ] \
            && [ "$pane_pid" = "$DUET_CALLER_PANE_PID" ] \
            && [ "$socket" = "$DUET_CALLER_SOCKET" ] \
            && [ "$server_pid" = "$DUET_CALLER_SERVER_PID" ]; then
          continue
        fi
        refuse "native session $invoker_id still has live prior pane $pane ($row_name) in $dir"
      fi
    done
  done
}

fallback_fresh(){
  local pass_id="${invoker_id:-${initiator_native_id:-}}"
  local pass_home="${invoker_home:-${initiator_native_home:-}}"
  local id_args=()
  local home_args=()
  refuse_live_fallback_ownership
  [ -z "$pass_id" ] || id_args=(--initiator-native-id "$pass_id")
  [ -z "$pass_home" ] || home_args=(--initiator-native-home "$pass_home")
  echo "duet: rejoin unavailable ($1); starting a fresh, unpaired ensemble." >&2
  # No harness words: the normal no-arg path gets the standard fresh default.
  # Explicit words keep their exact roster on the fresh fallback too.
  if [ "${#workers[@]}" -eq 0 ]; then
    exec bash "$INIT" --initiator "$initiator_harness" \
      ${id_args[@]+"${id_args[@]}"} ${home_args[@]+"${home_args[@]}"} codex kimi
  fi
  exec bash "$INIT" --initiator "$initiator_harness" \
    ${id_args[@]+"${id_args[@]}"} ${home_args[@]+"${home_args[@]}"} "${workers[@]}"
}

[ -n "${TMUX:-}" ] || {
  echo "duet: not inside tmux. Start a supported harness in tmux first." >&2
  exit 3
}
command -v tmux >/dev/null 2>&1 || { echo "duet: tmux not found on PATH" >&2; exit 3; }

WORKDIR="$(pwd -P)"
INITIATOR_PANE="${TMUX_PANE:?duet: initiating pane has no TMUX_PANE}"

if [ -z "$initiator_harness" ]; then
  pane_command="$(tmux display-message -p -t "$INITIATOR_PANE" \
    '#{pane_current_command}' 2>/dev/null || true)"
  case "$pane_command" in
    claude|codex|kimi) initiator_harness="$pane_command" ;;
    *)
      echo "duet: could not infer the invoking harness; pass --initiator claude, codex, or kimi." >&2
      exit 2
      ;;
  esac
fi
case "$initiator_harness" in
  claude|codex|kimi) : ;;
  *) usage; echo "duet: unsupported initiator harness '$initiator_harness'" >&2; exit 2 ;;
esac

if [ -z "${DUET_STATE_ROOT:-}" ]; then
  [ -n "${HOME:-}" ] || {
    echo "duet: set DUET_STATE_ROOT or HOME before rejoining a session." >&2
    exit 7
  }
  DUET_STATE_ROOT="$HOME/.duet"
fi
# First-ever invocation: the state root may not exist yet; there can be no
# pairing, so defer to the fresh-ensemble fallback after canonicalizing.
if [ ! -d "$DUET_STATE_ROOT" ]; then
  mkdir -p "$DUET_STATE_ROOT" 2>/dev/null || fallback_fresh "no state root exists yet"
fi
DUET_STATE_ROOT="$(cd "$DUET_STATE_ROOT" && pwd -P)"
invoker_home="$(duet_native_home "$initiator_harness" \
  "$initiator_native_home" 2>/dev/null || true)"
[ -n "$invoker_home" ] \
  || fallback_fresh "the invoking $initiator_harness native config home is unavailable"

# Who is asking? The invoking agent's current native session id decides which
# paired member it is — this is what lets a former worker rejoin the mesh from
# its own resumed native session and keep its stable roster name.
invoker_capture="$(duet_capture_initiator_id "$initiator_harness" "$WORKDIR" \
  "$initiator_native_id" 2>/dev/null || true)"
invoker_id="${invoker_capture%%$'\t'*}"
[ -n "$invoker_id" ] && [ "$invoker_id" != "$invoker_capture" ] \
  || fallback_fresh "the invoking $initiator_harness session has no capturable native id"

# Fence every known live owner before either selecting a valid mapping or
# falling back. This also catches an active diagnostic run left behind by a
# failed resume while the durable by-id index still names an older good map.
refuse_live_fallback_ownership

# Lookup is keyed by the exact native session, not by the repo: the candidate
# is the newest complete pairing containing (harness, native_id).
candidate="$(duet_pairing_latest_for_id "$DUET_STATE_ROOT" "$WORKDIR" \
  "$initiator_harness" "$invoker_id" "$invoker_home" || true)"
[ -n "$candidate" ] \
  || fallback_fresh "no complete pairing in this repo names the invoking native session"

# The invoker must be exactly one paired member, on the matching harness.
invoker_matches="$(LC_ALL=C awk -F '\t' -v id="$invoker_id" \
  -v h="$initiator_harness" -v home="$invoker_home" \
  'NR > 1 && $2 == h && $3 == id && $13 == home { print $1 "\t" $2; count++ }
   END { exit !(count == 1) }' "$candidate/pairing.tsv" 2>/dev/null)" \
  || fallback_fresh "the invoking native session is not a paired member of $candidate"
invoker_name="${invoker_matches%%$'\t'*}"
invoker_pair_harness="${invoker_matches#*$'\t'}"
[ "$invoker_pair_harness" = "$initiator_harness" ] \
  || fallback_fresh "paired member $invoker_name is a $invoker_pair_harness session, not $initiator_harness"

# Reciprocal freshness: for every candidate member, the candidate must still be
# the newest complete pairing naming that member's native id. If any member has
# since been re-paired into a different run, this mapping is superseded and
# rejoining it would reconstruct a split-brain set — fail closed instead.
superseded=""
while IFS=$'\t' read -r m_name m_harness m_id m_home; do
  [ -n "$m_name" ] || continue
  member_latest="$(duet_pairing_latest_for_id "$DUET_STATE_ROOT" "$WORKDIR" \
    "$m_harness" "$m_id" "$m_home" || true)"
  [ "$member_latest" = "$candidate" ] || superseded="$superseded $m_name"
done <<EOF
$(LC_ALL=C awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $13 }' "$candidate/pairing.tsv")
EOF
[ -z "$superseded" ] \
  || fallback_fresh "pairing at $candidate is superseded for member(s):$superseded"

# Roster selection: no harness words means the whole paired roster; otherwise
# the requested harness multiset must match the remaining paired rows exactly.
paired_workers="$(LC_ALL=C awk -F '\t' -v skip="$invoker_name" \
  'NR > 1 && $1 != skip { print $1 "\t" $2 "\t" $3 "\t" $13 }' \
  "$candidate/pairing.tsv")"
paired_worker_count="$(printf '%s\n' "$paired_workers" | awk 'NF' | wc -l | tr -d ' ')"
if [ "${#workers[@]}" -eq 0 ]; then
  [ "$paired_worker_count" -ge 1 ] \
    || fallback_fresh "the pairing has no workers besides $invoker_name"
else
  requested="$(printf '%s\n' "${workers[@]}" | LC_ALL=C sort)"
  paired_harnesses="$(printf '%s\n' "$paired_workers" | awk 'NF { print $2 }' | LC_ALL=C sort)"
  [ "$requested" = "$paired_harnesses" ] \
    || fallback_fresh "requested roster does not exactly match the paired roster"
fi

# Every paired native id must still resolve to an on-disk harness session.
unresolvable=""
unresumable=""
old_workdir="$(duet_pairing_field "$candidate" "$invoker_name" 9)"
resumability_rows="$(
  printf '%s\n' "$paired_workers" \
    | LC_ALL=C awk -F '\t' -v wd="$old_workdir" \
        'NF { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" wd }'
  printf '%s\t%s\t%s\t%s\t%s\n' "$invoker_name" "$invoker_pair_harness" \
    "$invoker_id" "$invoker_home" "$old_workdir"
)"
while IFS=$'\t' read -r p_name p_harness p_id p_home p_old_workdir; do
  [ -n "$p_name" ] || continue
  duet_native_id_resolvable "$p_harness" "$p_id" "$p_home" \
    || unresolvable="$unresolvable $p_name"
  duet_native_session_resumable "$p_harness" "$p_id" "$p_home" \
    "$p_old_workdir" "$WORKDIR" || unresumable="$unresumable $p_name"
done <<EOF
$resumability_rows
EOF
[ -z "$unresolvable" ] \
  || fallback_fresh "native session no longer resolvable for:$unresolvable"
[ -z "$unresumable" ] \
  || fallback_fresh "native session cannot be resumed from this workdir for:$unresumable"

# Prior ownership, verified against the live process/pane identity — never a
# bare kill -0, so a recycled unrelated pid cannot refuse or be signaled.
old_config="$candidate/duet.env"
old_session_id="$(basename "$candidate")"
old_daemon_pid="$(cat "$candidate/daemon.pid" 2>/dev/null || true)"
case "$old_daemon_pid" in
  ''|*[!0-9]*) : ;;
  *)
    if kill -0 "$old_daemon_pid" 2>/dev/null \
        && duet_daemon_process_matches "$old_daemon_pid" "$old_config" "$old_session_id"; then
      refuse "the previous run's delivery daemon (pid $old_daemon_pid) is still alive; end that session first"
    fi
    ;;
esac
# On an un-ended run every recorded tuple must be dead — including the old
# initiator's; the classical native-resume happens in a NEW pane. On a cleanly
# ended run the invoker's own surviving pane may be adopted (that is the normal
# end-then-rejoin flow), but any other recorded live tuple still refuses.
while IFS=$'\t' read -r p_name p_harness p_id p_pane p_pid p_socket p_spid; do
  [ -n "$p_name" ] || continue
  if [ -f "$candidate/.ended" ]; then
    [ "$p_name" = "$invoker_name" ] \
      && [ "$p_pane" = "$DUET_CALLER_PANE" ] \
      && [ "$p_pid" = "$DUET_CALLER_PANE_PID" ] \
      && [ "$p_socket" = "$DUET_CALLER_SOCKET" ] \
      && [ "$p_spid" = "$DUET_CALLER_SERVER_PID" ] \
      && continue
  fi
  # A dead, unreachable, or replaced recorded server counts as dead.
  actual_server="$(tmux -S "$p_socket" display-message -p '#{pid}' 2>/dev/null || true)"
  [ -n "$actual_server" ] && [ "$actual_server" = "$p_spid" ] || continue
  actual_pid="$(tmux -S "$p_socket" display-message -p -t "$p_pane" \
    '#{pane_pid}' 2>/dev/null || true)"
  [ "$actual_pid" = "$p_pid" ] \
    && refuse "prior pane $p_pane ($p_name) is still live; end the previous session first"
done <<EOF
$(LC_ALL=C awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $5 "\t" $6 "\t" $7 "\t" $8 }' "$candidate/pairing.tsv")
EOF

member_args=()
member_id_args=()
member_home_args=()
while IFS=$'\t' read -r p_name p_harness p_id p_home; do
  [ -n "$p_name" ] || continue
  member_args+=("--member" "$p_name=$p_harness")
  member_id_args+=("--member-native-id" "$p_name=$p_id")
  member_home_args+=("--member-native-home" "$p_name=$p_home")
done <<EOF
$paired_workers
EOF

echo "duet: rejoining ensemble from pairing at $candidate (initiator=$invoker_name)."
exec bash "$INIT" \
  --initiator "$initiator_harness" \
  --initiator-name "$invoker_name" \
  --initiator-native-id "$invoker_id" \
  --initiator-native-home "$invoker_home" \
  --rejoin-from "$candidate" \
  ${member_args[@]+"${member_args[@]}"} \
  ${member_id_args[@]+"${member_id_args[@]}"} \
  ${member_home_args[@]+"${member_home_args[@]}"}
