#!/usr/bin/env bash
# Shared helpers for the tmux/bash ensemble path.

# duet_send_verified result codes. Success is the normal shell status 0.
DUET_SEND_DEAD=20
DUET_SEND_NOT_LANDED=21
DUET_SEND_LANDED_UNVERIFIED=22
DUET_LOCK_TOKEN="${BASHPID:-$$}-${RANDOM:-0}-${RANDOM:-0}"

# Always address the tmux server recorded for the session when one is known.
# This is what keeps detached smoke servers and status calls outside a pane from
# accidentally falling back to the user's default tmux server.
_duet_tmux(){
  if [ -n "${DUET_TMUX_SOCKET:-}" ]; then
    command tmux -S "$DUET_TMUX_SOCKET" "$@"
  else
    command tmux "$@"
  fi
}

# Normalize to ASCII alphanumerics. Besides whitespace, boxed TUIs insert border
# glyphs at visual row boundaries; ignoring punctuation lets one logical payload
# probe span those decorated rows without mistaking the border for message text.
_duet_strip(){ LC_ALL=C printf '%s' "${1:-}" | LC_ALL=C tr -cd '[:alnum:]'; }

# A distinctive tail of the payload (at most 48 normalized characters).
_duet_probe(){
  local s n
  s="$(_duet_strip "${1:-}")"
  n=${#s}
  if [ "$n" -gt 48 ]; then printf '%s' "${s: -48}"; else printf '%s' "$s"; fi
}

_duet_present(){
  [ -n "${2:-}" ] || return 1
  case "$1" in *"$2"*) return 0;; *) return 1;; esac
}

_duet_tail_strip(){
  _duet_tmux capture-pane -p -t "$1" 2>/dev/null \
    | awk 'NF' \
    | tail -n "${2:-6}" \
    | LC_ALL=C tr -cd '[:alnum:]'
}

# Claude collapses multiline bracketed paste to a composer token such as
# "[Pasted text #1 +3 lines]" instead of rendering the payload bytes. Return a
# normalized token when that marker is currently near the composer.
_duet_paste_marker(){
  _duet_tmux capture-pane -p -t "$1" 2>/dev/null \
    | tail -n 6 \
    | awk '
        tolower($0) ~ /pasted text #[0-9]+/ { line=$0 }
        tolower($0) ~ /paste again to expand/ { composer=1 }
        END { if (composer) print line }
      ' \
    | LC_ALL=C tr -cd '[:alnum:]'
}

duet_tmux_server_matches(){
  local expected="${DUET_TMUX_SERVER_PID:-}" actual
  [ -n "$expected" ] || return 0
  actual="$(_duet_tmux display-message -p '#{pid}' 2>/dev/null || true)"
  [ "$actual" = "$expected" ]
}

_duet_alive(){
  [ -n "${1:-}" ] || return 1
  duet_tmux_server_matches || return 1
  _duet_tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"
}

# duet_send_verified <pane> <payload> <interrupt-flag> [harness]
#
# A successful return means the payload was observed in the composer and then
# observed leaving it after Enter. Non-zero outcomes are deliberately distinct:
#   DUET_SEND_DEAD                pane disappeared
#   DUET_SEND_NOT_LANDED          paste was not observed; caller may repaste
#   DUET_SEND_LANDED_UNVERIFIED   paste landed, but submission is uncertain;
#                                 caller must never paste the payload again
duet_send_verified(){
  local pane="${1:-}" payload="${2:-}" interrupt="${3:-}" harness="${4:-}"
  local probe buffer i e marker_before marker_now landing_kind="" landing_token=""
  local busy_snapshot="" interrupt_key=Escape
  DUET_SEND_ENTER_TOKEN=""

  if ! _duet_alive "$pane"; then
    echo "duet: target pane $pane is gone; not sending." >&2
    return "$DUET_SEND_DEAD"
  fi

  # Claude reserves one C-c as a hard interrupt: while busy it cancels the
  # current operation, and while idle it only clears input (a second C-c would
  # exit). Use it unconditionally because narrow panes can hide every visual
  # busy marker. Codex and Kimi use Escape only when visibly busy.
  if [ -n "$interrupt" ]; then
    if [ "$harness" = claude ]; then
      _duet_tmux send-keys -t "$pane" C-c
      # Let Claude finish cancelling before the urgent payload is pasted. The
      # bounded wait also covers a Ctrl-C delivered during a UI redraw.
      for i in $(seq 1 20); do
        sleep 0.1
        busy_snapshot="$(_duet_tmux capture-pane -p -t "$pane" 2>/dev/null | tail -n 12)"
        printf '%s\n' "$busy_snapshot" \
          | grep -qiE 'esc to interrupt|running [0-9]+ shell command|\([0-9]+s[^)]*(tokens|thinking)' \
          || break
      done
    else
      busy_snapshot="$(_duet_tmux capture-pane -p -t "$pane" 2>/dev/null | tail -n 6)"
      if printf '%s\n' "$busy_snapshot" \
           | grep -qiE 'esc to interrupt|esc to cancel|ctrl\+c to|working|thinking|generating|running|streaming'; then
        _duet_tmux send-keys -t "$pane" "$interrupt_key"
        sleep 0.4
      fi
    fi
  fi

  probe="$(_duet_probe "$payload")"
  [ -n "$probe" ] || {
    echo "duet: refusing to send an empty/unprobeable payload to $pane" >&2
    return "$DUET_SEND_NOT_LANDED"
  }
  marker_before="$(_duet_paste_marker "$pane")"

  buffer="duet-${BASHPID:-$$}-${RANDOM:-0}"
  if ! printf '%s' "$payload" | _duet_tmux load-buffer -b "$buffer" -; then
    echo "duet: could not load paste buffer for pane $pane" >&2
    return "$DUET_SEND_NOT_LANDED"
  fi
  if ! duet_tmux_server_matches; then
    return "$DUET_SEND_DEAD"
  fi
  if ! _duet_tmux paste-buffer -d -b "$buffer" -p -t "$pane"; then
    _duet_tmux delete-buffer -b "$buffer" 2>/dev/null || true
    if _duet_alive "$pane"; then
      echo "duet: paste command failed for pane $pane" >&2
      return "$DUET_SEND_NOT_LANDED"
    fi
    return "$DUET_SEND_DEAD"
  fi
  duet_tmux_server_matches || return "$DUET_SEND_LANDED_UNVERIFIED"

  for i in $(seq 1 20); do
    sleep 0.1
    if _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
      landing_kind=probe
      landing_token="$probe"
      break
    fi
    marker_now="$(_duet_paste_marker "$pane")"
    if [ -n "$marker_now" ] && [ "$marker_now" != "$marker_before" ]; then
      landing_kind=marker
      landing_token="$marker_now"
      DUET_SEND_ENTER_TOKEN="$marker_now"
      break
    fi
  done
  if [ -z "$landing_kind" ]; then
    echo "duet: paste command succeeded but landing is unverified in pane $pane" >&2
    return "$DUET_SEND_LANDED_UNVERIFIED"
  fi

  # Once landing has been observed, only retry Enter. Re-pasting here could
  # duplicate an already accepted task.
  for e in 1 2 3; do
    _duet_tmux send-keys -t "$pane" Enter
    for i in $(seq 1 12); do
      sleep 0.2
      if ! _duet_alive "$pane"; then
        return "$DUET_SEND_LANDED_UNVERIFIED"
      fi
      case "$landing_kind" in
        probe)
          _duet_present "$(_duet_tail_strip "$pane" 4)" "$landing_token" || return 0
          ;;
        marker)
          [ "$(_duet_paste_marker "$pane")" = "$landing_token" ] || return 0
          ;;
      esac
    done
  done

  echo "duet: payload landed in pane $pane but submission is unverified." >&2
  return "$DUET_SEND_LANDED_UNVERIFIED"
}

# Enter-only continuation for a payload that may already occupy the composer.
# It never pastes. If the unique payload probe is absent, submission cannot be
# proven and the caller must quarantine the message.
duet_send_enter_only(){
  local pane="${1:-}" payload="${2:-}" marker_token="${3:-}" probe i kind
  _duet_alive "$pane" || return "$DUET_SEND_DEAD"
  probe="$(_duet_probe "$payload")"
  [ -n "$probe" ] || return "$DUET_SEND_LANDED_UNVERIFIED"
  if _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
    kind=probe
  elif [ -n "$marker_token" ] && [ "$(_duet_paste_marker "$pane")" = "$marker_token" ]; then
    kind=marker
  else
    return "$DUET_SEND_LANDED_UNVERIFIED"
  fi
  _duet_tmux send-keys -t "$pane" Enter
  for i in $(seq 1 12); do
    sleep 0.2
    _duet_alive "$pane" || return "$DUET_SEND_DEAD"
    case "$kind" in
      probe) _duet_present "$(_duet_tail_strip "$pane" 4)" "$probe" || return 0 ;;
      marker) [ "$(_duet_paste_marker "$pane")" = "$marker_token" ] || return 0 ;;
    esac
  done
  return "$DUET_SEND_LANDED_UNVERIFIED"
}

# Remove only the delimited block owned by duet. Existing surrounding content
# and even an otherwise-empty user-created anchor file are preserved.
duet_strip_anchor_file(){
  [ -f "${1:-}" ] || return 0
  perl -0777 -pi -e 's/\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\n?//sg' "$1" 2>/dev/null
}

duet_strip_session_anchors(){
  local workdir="${1:-}"
  [ -n "$workdir" ] || return 0
  duet_strip_anchor_file "$workdir/AGENTS.md" || return 1
  duet_strip_anchor_file "$workdir/CLAUDE.md"
}

duet_stop_daemon(){
  local dir="${1:-}" loops="${2:-30}" pid owner owner_pid command_line i
  local pid_live="" owner_live="" identity_valid=""
  [ -n "$dir" ] || return 0

  # daemon.pid is published just after the lifetime lock is acquired and
  # removed just before that lock is released. Wait for those short windows to
  # converge. A dead/stale pid file never proves the daemon is stopped while a
  # different live process still owns this session's lock.
  for i in $(seq 1 "$loops"); do
    pid="$(cat "$dir/daemon.pid" 2>/dev/null || true)"
    owner="$(duet_lock_owner_read "$dir/.daemon.lock")"
    owner_pid="${owner%%$'\t'*}"
    pid_live=""
    owner_live=""
    case "$pid" in
      ''|*[!0-9]*) : ;;
      *) kill -0 "$pid" 2>/dev/null && pid_live=1 ;;
    esac
    case "$owner_pid" in
      ''|*[!0-9]*) : ;;
      *) kill -0 "$owner_pid" 2>/dev/null && owner_live=1 ;;
    esac

    if [ -n "$owner_live" ]; then
      if [ -n "$pid_live" ] && [ "$pid" = "$owner_pid" ]; then
        identity_valid=1
        break
      fi
      sleep 0.1
      continue
    fi
    if [ -n "$pid_live" ]; then
      echo "duet: daemon.pid does not own this session's live daemon lock; refusing to signal it." >&2
      return 1
    fi
    return 0
  done
  if [ -z "$identity_valid" ]; then
    echo "duet: daemon.pid does not own this session's live daemon lock; refusing to signal it." >&2
    return 1
  fi

  for i in $(seq 1 "$loops"); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  owner="$(duet_lock_owner_read "$dir/.daemon.lock")"
  owner_pid="${owner%%$'\t'*}"
  if [ "$owner_pid" != "$pid" ]; then
    echo "duet: daemon lock ownership changed; refusing to signal pid $pid." >&2
    return 1
  fi
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *duet-deliverd.sh*) kill -TERM "$pid" 2>/dev/null || true ;;
    *) echo "duet: daemon pid $pid was reused; refusing to signal it." >&2; return 1 ;;
  esac
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  echo "duet: delivery daemon $pid did not exit after TERM." >&2
  return 1
}

# Kill only panes explicitly marked as spawned. The caller pane is fenced even
# if a malformed roster marks it spawned.
duet_kill_spawned_panes(){
  local roster="${1:-}" exempt="${2:-}" legacy_pane="${3:-}"
  local pane spawned
  local victims="" victim
  if [ ! -f "$roster" ]; then
    # v0.1.x compatibility: its env recorded one spawned CODEX_PANE and had no
    # roster. Preserve the same never-self fence during the v0.2 transition.
    if [ -n "$legacy_pane" ] && [ "$legacy_pane" != "$exempt" ] && _duet_alive "$legacy_pane"; then
      _duet_tmux send-keys -t "$legacy_pane" C-c 2>/dev/null || true
      sleep 0.3
      _duet_alive "$legacy_pane" && _duet_tmux kill-pane -t "$legacy_pane" 2>/dev/null || true
    fi
    return 0
  fi

  while IFS='|' read -r pane spawned; do
    [ "$spawned" = 1 ] || continue
    [ -n "$pane" ] || continue
    [ "$pane" = "$exempt" ] && continue
    _duet_alive "$pane" || continue
    _duet_tmux send-keys -t "$pane" C-c 2>/dev/null || true
    victims="${victims}${victims:+ }$pane"
  done < <(awk -F '\t' 'NR > 1 { print $3 "|" $6 }' "$roster")

  [ -n "$victims" ] || return 0
  sleep 0.3
  for victim in $victims; do
    [ "$victim" = "$exempt" ] && continue
    _duet_alive "$victim" && _duet_tmux kill-pane -t "$victim" 2>/dev/null || true
  done
}

# Reap a previous session without ever killing the pane performing the re-init.
# args: duet_dir workdir tmux_socket exempt_pane [legacy_codex_pane] [server_pid]
duet_reap_session(){
  local dir="${1:-}" workdir="${2:-}" socket="${3:-}" exempt="${4:-}"
  local legacy_pane="${5:-}" expected_server_pid="${6:-}" actual_server_pid
  local saved_socket="${DUET_TMUX_SOCKET:-}"
  [ -n "$dir" ] || return 0

  if [ -d "$dir" ]; then
    : > "$dir/.ended" 2>/dev/null || return 1
  fi
  duet_stop_daemon "$dir" 20 || return 1
  duet_strip_session_anchors "$workdir" || return 1

  DUET_TMUX_SOCKET="$socket"
  if [ -n "$expected_server_pid" ]; then
    actual_server_pid="$(_duet_tmux display-message -p '#{pid}' 2>/dev/null || true)"
    if [ "$actual_server_pid" != "$expected_server_pid" ]; then
      echo "duet: previous tmux server identity changed; refusing to reap its recorded panes." >&2
      DUET_TMUX_SOCKET="$saved_socket"
      return 0
    fi
  fi
  duet_kill_spawned_panes "$dir/roster.tsv" "$exempt" "$legacy_pane"
  DUET_TMUX_SOCKET="$saved_socket"
}

# Read the atomically-published leadership state into DUET_CURRENT_TERM and
# DUET_CURRENT_LEADER. The file is data, never shell code.
duet_read_leader_state(){
  local file="${1:-${DUET_DIR:?}/leader}" state
  state="$(awk -F '\t' '
    $1 == "term" { term=$2 }
    $1 == "leader" { leader=$2 }
    END { if (term ~ /^[0-9]+$/ && leader != "") print term "\t" leader }
  ' "$file" 2>/dev/null)"
  [ -n "$state" ] || { echo "duet: invalid leadership state in $file" >&2; return 1; }
  DUET_CURRENT_TERM="${state%%$'\t'*}"
  DUET_CURRENT_LEADER="${state#*$'\t'}"
}

duet_roster_has_name(){
  awk -F '\t' -v name="${1:-}" 'NR > 1 && $1 == name { found=1 } END { exit !found }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

duet_roster_name_for_pane(){
  awk -F '\t' -v pane="${1:-}" 'NR > 1 && $3 == pane { print $1; exit }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

duet_roster_pane_for_name(){
  awk -F '\t' -v name="${1:-}" 'NR > 1 && $1 == name { print $3; exit }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

duet_roster_harness_for_name(){
  awk -F '\t' -v name="${1:-}" 'NR > 1 && $1 == name { print $2; exit }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

# Resolve an optional harness alias (for example `codex` -> `codex-1`) only
# when exactly one roster entry uses that harness.
duet_resolve_roster_name(){
  local token="${1:-}" exact matches
  if duet_roster_has_name "$token"; then printf '%s' "$token"; return 0; fi
  matches="$(awk -F '\t' -v harness="$token" 'NR > 1 && $2 == harness { print $1 }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null)"
  [ "$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')" -eq 1 ] || return 1
  printf '%s' "$matches"
}

duet_daemon_alive(){
  local pid_file="${DUET_DIR:?}/daemon.pid" pid owner command_line
  [ -f "$pid_file" ] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  owner="$(duet_lock_owner_read "$DUET_DIR/.daemon.lock")"
  [ "${owner%%$'\t'*}" = "$pid" ] || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in *duet-deliverd.sh*) return 0;; *) return 1;; esac
}

duet_lock_owner_read(){
  local lock="${1:?lock path required}"
  if [ -d "$lock" ]; then
    cat "$lock/owner" 2>/dev/null || true
  else
    cat "$lock" 2>/dev/null || true
  fi
}

# Serialize stale-lock recovery separately from ordinary ownership. macOS's
# shlock uses link(2) and PID validation; the mkdir fallback stays fail-closed
# if its tiny reaper critical section itself crashes.
duet_reaper_acquire(){
  local marker="${1:?lock path required}.reaper" owner_pid="${BASHPID:-$$}"
  local attempts="${2:-40}" i
  for i in $(seq 1 "$attempts"); do
    if command -v shlock >/dev/null 2>&1; then
      shlock -f "$marker" -p "$owner_pid" 2>/dev/null && return 0
    else
      mkdir "$marker" 2>/dev/null && return 0
    fi
    sleep 0.05
  done
  return 1
}

duet_reaper_release(){
  local marker="${1:?lock path required}.reaper" owner_pid="${BASHPID:-$$}"
  local held
  if [ -d "$marker" ]; then
    rmdir "$marker" 2>/dev/null
    return
  fi
  held="$(cat "$marker" 2>/dev/null || true)"
  [ "$held" = "$owner_pid" ] || return 1
  rm -f "$marker" 2>/dev/null
}

# Portable atomic lock: populate an owner inside a private mkdir, then publish
# that already-written inode at the canonical path with link(2). Stale recovery
# is separately serialized and re-reads the owner inside that fence, preventing
# both ownerless-publication and stale-generation ABA races.
duet_lock_acquire(){
  local lock="${1:?lock path required}" attempts="${2:-200}"
  local owner_pid="${BASHPID:-$$}" owner="$DUET_LOCK_TOKEN"
  local held held_pid stale target claim i
  claim="${lock}.claim-${owner_pid}-${RANDOM:-0}-${RANDOM:-0}"
  if ! mkdir "$claim" 2>/dev/null; then
    claim="${lock}.claim-${owner_pid}-${RANDOM:-0}-${RANDOM:-0}-${RANDOM:-0}"
    mkdir "$claim" 2>/dev/null || return 1
  fi
  if ! printf '%s\t%s\n' "$owner_pid" "$owner" > "$claim/owner"; then
    rm -f "$claim/owner" 2>/dev/null || true
    rmdir "$claim" 2>/dev/null || true
    return 1
  fi

  for i in $(seq 1 "$attempts"); do
    # New locks are regular hard links. Avoid ln's existing-directory behavior
    # while a pre-0.2 directory lock is being drained/recovered.
    if [ ! -d "$lock" ] && ln "$claim/owner" "$lock" 2>/dev/null; then
      rm -f "$claim/owner" 2>/dev/null || true
      rmdir "$claim" 2>/dev/null || true
      return 0
    fi

    held="$(duet_lock_owner_read "$lock")"
    held_pid="${held%%$'\t'*}"
    if [ -n "$held_pid" ] && ! kill -0 "$held_pid" 2>/dev/null; then
      if duet_reaper_acquire "$lock" 40; then
        held="$(duet_lock_owner_read "$lock")"
        held_pid="${held%%$'\t'*}"
        if [ -n "$held_pid" ] && ! kill -0 "$held_pid" 2>/dev/null; then
          stale="${lock}.stale-${owner_pid}-${RANDOM:-0}"
          if [ -d "$lock" ]; then
            if mv "$lock" "$stale" 2>/dev/null; then
              if [ -L "$stale" ]; then
                target="$(readlink "$stale" 2>/dev/null || true)"
                rm -f "$stale" 2>/dev/null || true
                case "$target" in
                  *.claim-*)
                    rm -f "$(dirname "$lock")/$target/owner" 2>/dev/null || true
                    rmdir "$(dirname "$lock")/$target" 2>/dev/null || true
                    ;;
                esac
              else
                rm -f "$stale/owner" 2>/dev/null || true
                rmdir "$stale" 2>/dev/null || true
              fi
            fi
          else
            rm -f "$lock" 2>/dev/null || true
          fi
        fi
        duet_reaper_release "$lock" || true
        continue
      fi
    fi
    sleep 0.05
  done
  rm -f "$claim/owner" 2>/dev/null || true
  rmdir "$claim" 2>/dev/null || true
  echo "duet: timed out acquiring lock $lock" >&2
  return 1
}

duet_lock_release(){
  local lock="${1:?lock path required}" owner="$DUET_LOCK_TOKEN" held
  held="$(duet_lock_owner_read "$lock")"
  [ "${held#*$'\t'}" = "$owner" ] || return 1
  if [ -d "$lock" ]; then
    rm -f "$lock/owner" 2>/dev/null || return 1
    rmdir "$lock" 2>/dev/null || return 1
  else
    rm -f "$lock" 2>/dev/null || return 1
  fi
}

duet_next_sequence(){
  local box="${1:?queue directory required}" current next tmp existing sequence_dir
  if [ -f "$box/.counter" ]; then
    current="$(cat "$box/.counter" 2>/dev/null || true)"
    case "$current" in ''|*[!0-9]*) echo "duet: corrupt counter in $box" >&2; return 1;; esac
    current=$((10#$current))
  else
    existing="$(find "$box" -type f \( -name 'N-*.msg' -o -name 'I-*.msg' \) -print -quit 2>/dev/null)"
    [ -z "$existing" ] || { echo "duet: missing counter in non-empty queue $box" >&2; return 1; }
    current=0
  fi
  next=$((current + 1))
  printf -v DUET_SEQUENCE '%010d' "$next"
  # A manually rolled-back but syntactically valid counter must not reuse a
  # stable ID that already exists in either the active root or a terminal
  # archive. Sidecars count too: they prove that sequence was once allocated.
  for sequence_dir in "$box" "$box/delivered" "$box/failed" \
      "$box/quarantine" "$box/superseded"; do
    for existing in "$sequence_dir/N-$DUET_SEQUENCE.msg"* \
        "$sequence_dir/I-$DUET_SEQUENCE.msg"*; do
      [ ! -e "$existing" ] || {
        echo "duet: counter rollback would reuse sequence $DUET_SEQUENCE in $box" >&2
        return 1
      }
    done
  done
  tmp="$(mktemp "$box/.counter.XXXXXX")" || return 1
  if ! printf '%s\n' "$next" > "$tmp" || ! mv -f "$tmp" "$box/.counter"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

duet_find_dedupe_message(){
  local box="${1:?queue directory required}" key="${2:?dedupe key required}"
  local file value
  DUET_DEDUPE_FILE=""
  DUET_DEDUPE_ID=""
  for file in "$box"/N-*.msg "$box"/I-*.msg \
      "$box"/delivered/N-*.msg "$box"/delivered/I-*.msg \
      "$box"/failed/N-*.msg "$box"/failed/I-*.msg \
      "$box"/quarantine/N-*.msg "$box"/quarantine/I-*.msg \
      "$box"/superseded/N-*.msg "$box"/superseded/I-*.msg; do
    [ -f "$file" ] || continue
    value="$(awk -F '\t' '$1 == "dedupe" { sub(/^[^\t]*\t/, ""); print; exit }' "$file")"
    [ "$value" = "$key" ] || continue
    DUET_DEDUPE_FILE="$file"
    DUET_DEDUPE_ID="$(awk -F '\t' '$1 == "id" { print $2; exit }' "$file")"
    [ -n "$DUET_DEDUPE_ID" ] && return 0
  done
  return 1
}

duet_append_transcript(){
  local id="${1:?message id required}" sender="${2:?sender required}"
  local recipient="${3:?recipient required}" term="${4:?term required}"
  local mode="${5:?mode required}" body="${6-}" lock="${DUET_DIR:?}/.transcript.lock"
  local ts
  duet_lock_acquire "$lock" || return 1
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if ! printf '\n----- %s  id=%s  term=%s  %s -> %s  (%s) -----\n%s\n' \
      "$ts" "$id" "$term" "$sender" "$recipient" "$mode" "$body" \
      >> "$DUET_DIR/transcript.md"; then
    duet_lock_release "$lock" || true
    return 1
  fi
  duet_lock_release "$lock" || true
}

# Enqueue one immutable message. The queue lock remains held through transcript
# append and final publish, so transcript order matches sequence order for a
# recipient. Sets DUET_ENQUEUED_ID, DUET_ENQUEUED_FILE, and DUET_SEQUENCE.
# args: queue sender recipient term mode origin-role leader-at-send body [dedupe-key]
duet_enqueue_message(){
  local queue="${1:?queue required}" sender="${2:?sender required}"
  local recipient="${3:?recipient required}" term="${4:?term required}"
  local mode="${5:?mode required}" origin="${6:?origin role required}"
  local leader_at_send="${7:?leader at send required}" body="${8-}"
  local dedupe="${9-}" box lock admission tmp prefix final id encoded
  local enqueue_lock_attempts="${DUET_ENQUEUE_LOCK_ATTEMPTS:-1200}"
  case "$queue" in ''|*[!A-Za-z0-9_-]*) echo "duet: invalid queue '$queue'" >&2; return 1;; esac
  case "$mode" in NORMAL) prefix=N;; INTERRUPT) prefix=I;; *) echo "duet: invalid mode '$mode'" >&2; return 1;; esac
  case "$origin" in LEADER|WORKER|SYSTEM) :;; *) echo "duet: invalid origin role '$origin'" >&2; return 1;; esac
  case "$term" in ''|*[!0-9]*) echo "duet: invalid term '$term'" >&2; return 1;; esac
  case "$dedupe" in *$'\t'*|*$'\n'*) echo "duet: invalid dedupe key" >&2; return 1;; esac
  case "$enqueue_lock_attempts" in ''|*[!0-9]*) enqueue_lock_attempts=1200;; esac

  box="${DUET_DIR:?}/inbox/$queue"
  mkdir -p "$box/delivered" "$box/failed" "$box/quarantine" "$box/superseded" || return 1
  admission="$DUET_DIR/.admission.lock"
  duet_lock_acquire "$admission" "$enqueue_lock_attempts" || return 1
  if [ -f "$DUET_DIR/.ended" ] \
      || { [ -f "$DUET_DIR/.draining" ] \
           && { [ "${DUET_INTERNAL_ENQUEUE:-}" != 1 ] || [ "$origin" != SYSTEM ]; }; }; then
    duet_lock_release "$admission" || true
    echo "duet: session is draining or ended; message was not queued." >&2
    return 1
  fi
  if ! duet_daemon_alive; then
    duet_lock_release "$admission" || true
    echo "duet: delivery daemon is not alive; message was not queued." >&2
    return 1
  fi
  lock="$box/.enqueue.lock"
  duet_lock_acquire "$lock" "$enqueue_lock_attempts" \
    || { duet_lock_release "$admission" || true; return 1; }
  if [ -n "$dedupe" ] && duet_find_dedupe_message "$box" "$dedupe"; then
    DUET_ENQUEUED_ID="$DUET_DEDUPE_ID"
    DUET_ENQUEUED_FILE="$DUET_DEDUPE_FILE"
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 0
  fi
  if ! duet_next_sequence "$box"; then
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 1
  fi

  id="m-${DUET_SESSION_ID:?}-${queue}-${DUET_SEQUENCE}"
  tmp="$(mktemp "$box/.message.XXXXXX")" || {
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 1
  }
  if ! encoded="$(printf '%s' "$body" | base64 | tr -d '\r\n')"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 1
  fi
  if ! {
    printf 'DUETv1\n'
    printf 'id\t%s\n' "$id"
    printf 'mode\t%s\n' "$mode"
    printf 'sender\t%s\n' "$sender"
    printf 'recipient\t%s\n' "$recipient"
    printf 'term\t%s\n' "$term"
    printf 'origin\t%s\n' "$origin"
    printf 'leader_at_send\t%s\n' "$leader_at_send"
    printf 'dedupe\t%s\n' "$dedupe"
    printf 'body64\t%s\n' "$encoded"
  } > "$tmp"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 1
  fi

  if ! duet_append_transcript "$id" "$sender" "$recipient" "$term" "$mode" "$body"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 1
  fi
  final="$box/${prefix}-${DUET_SEQUENCE}.msg"
  if [ -e "$final" ] || ! mv "$tmp" "$final"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    duet_lock_release "$admission" || true
    return 1
  fi
  duet_lock_release "$lock" || true
  duet_lock_release "$admission" || true
  DUET_ENQUEUED_ID="$id"
  DUET_ENQUEUED_FILE="$final"
}

duet_read_message(){
  local file="${1:?message file required}" encoded decoded
  [ "$(sed -n '1p' "$file" 2>/dev/null)" = DUETv1 ] || return 1
  DUET_MESSAGE_ID="$(awk -F '\t' '$1 == "id" { print $2; exit }' "$file")"
  DUET_MESSAGE_MODE="$(awk -F '\t' '$1 == "mode" { print $2; exit }' "$file")"
  DUET_MESSAGE_SENDER="$(awk -F '\t' '$1 == "sender" { print $2; exit }' "$file")"
  DUET_MESSAGE_RECIPIENT="$(awk -F '\t' '$1 == "recipient" { print $2; exit }' "$file")"
  DUET_MESSAGE_TERM="$(awk -F '\t' '$1 == "term" { print $2; exit }' "$file")"
  DUET_MESSAGE_ORIGIN="$(awk -F '\t' '$1 == "origin" { print $2; exit }' "$file")"
  DUET_MESSAGE_LEADER_AT_SEND="$(awk -F '\t' '$1 == "leader_at_send" { print $2; exit }' "$file")"
  DUET_MESSAGE_DEDUPE="$(awk -F '\t' '$1 == "dedupe" { sub(/^[^\t]*\t/, ""); print; exit }' "$file")"
  encoded="$(awk -F '\t' '$1 == "body64" { sub(/^[^\t]*\t/, ""); print; exit }' "$file")"
  if printf '' | base64 -d >/dev/null 2>&1; then
    decoded="$(
      if ! printf '%s' "$encoded" | base64 -d 2>/dev/null; then exit 1; fi
      printf '.'
    )" || return 1
  else
    decoded="$(
      if ! printf '%s' "$encoded" | base64 -D 2>/dev/null; then exit 1; fi
      printf '.'
    )" || return 1
  fi
  DUET_MESSAGE_BODY="${decoded%.}"
  [ -n "$DUET_MESSAGE_ID" ] && [ -n "$DUET_MESSAGE_SENDER" ] \
    && [ -n "$DUET_MESSAGE_RECIPIENT" ] || return 1
  case "$DUET_MESSAGE_MODE" in NORMAL|INTERRUPT) :;; *) return 1;; esac
  case "$DUET_MESSAGE_ORIGIN" in LEADER|WORKER|SYSTEM) :;; *) return 1;; esac
  case "$DUET_MESSAGE_TERM" in ''|*[!0-9]*) return 1;; esac
}

duet_build_payload(){
  printf '[DUET id=%s term=%s from=%s]\n%s\n[DUET id=%s end]' \
    "$DUET_MESSAGE_ID" "$DUET_MESSAGE_TERM" "$DUET_MESSAGE_SENDER" \
    "$DUET_MESSAGE_BODY" "$DUET_MESSAGE_ID"
}

duet_pending_count(){
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

# Failed named-recipient messages retain a durable notice obligation until the
# daemon has queued the corresponding leader notification and marked it.
duet_notice_obligation_count(){
  local box file count=0
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    [ "$(basename "$box")" != leader ] || continue
    for file in "$box"/failed/*.msg; do
      [ -f "$file" ] || continue
      [ -f "$file.noticed" ] && continue
      count=$((count + 1))
    done
  done
  printf '%s' "$count"
}
