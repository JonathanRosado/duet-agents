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

# Resolve exactly one absolute config. Runtime commands require DUET_CONFIG;
# read-only diagnostics may instead pass the same absolute path explicitly.
# Session IDs, directories, `current`, and newest-session scans are never
# routing inputs.
duet_resolve_config(){
  local session_arg="${1:-}" require_env="${2:-1}"
  local cfg="" cfg_dir canonical
  DUET_RESOLVED_CONFIG=""

  if [ "$require_env" = 1 ]; then
    cfg="${DUET_CONFIG:-}"
    [ -n "$cfg" ] || {
      echo "duet: DUET_CONFIG must name an absolute duet.env." >&2
      return 1
    }
    if [ -n "$session_arg" ] && [ "$session_arg" != "$cfg" ]; then
      echo "duet: --session disagrees with DUET_CONFIG." >&2
      return 1
    fi
  else
    cfg="$session_arg"
    [ -n "$cfg" ] || {
      echo "duet: an explicit absolute --session duet.env is required." >&2
      return 1
    }
  fi

  case "$cfg" in
    /*/duet.env) : ;;
    *) echo "duet: config must be an absolute path ending in /duet.env." >&2; return 1 ;;
  esac
  [ -f "$cfg" ] && [ ! -L "$cfg" ] || {
    echo "duet: pinned session config does not exist: $cfg" >&2
    return 1
  }
  cfg_dir="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd -P)" || return 1
  canonical="$cfg_dir/duet.env"
  [ "$cfg" = "$canonical" ] || {
    echo "duet: config path must be canonical: $canonical" >&2
    return 1
  }
  DUET_RESOLVED_CONFIG="$canonical"
}

# Validate the identity fields after a generated duet.env has been sourced.
duet_validate_loaded_session(){
  local expected_session="${1:-}" config_path="${2:-${DUET_RESOLVED_CONFIG:-}}"
  local config_dir canonical_dir canonical_root
  [ -n "${DUET_DIR:-}" ] && [ -n "${DUET_SESSION_ID:-}" ] \
    && [ -n "${DUET_STATE_ROOT:-}" ] || {
    echo "duet: session config is missing DUET_DIR, DUET_STATE_ROOT, or DUET_SESSION_ID." >&2
    return 1
  }
  case "$DUET_SESSION_ID" in
    *[!A-Za-z0-9_-]*)
      echo "duet: session id contains unsupported characters." >&2
      return 1
      ;;
  esac
  case "${DUET_DIR}${DUET_STATE_ROOT:-}" in
    *$'\t'*|*$'\r'*|*$'\n'*)
      echo "duet: session/state paths containing TAB, CR, or LF are unsupported." >&2
      return 1
      ;;
  esac
  canonical_dir="$(cd "$DUET_DIR" 2>/dev/null && pwd -P)" || return 1
  canonical_root="$(cd "$DUET_STATE_ROOT" 2>/dev/null && pwd -P)" || return 1
  [ "$canonical_root" != / ] || {
    echo "duet: DUET_STATE_ROOT may not be the filesystem root." >&2
    return 1
  }
  case "$canonical_dir" in
    "$canonical_root"/*) : ;;
    *)
      echo "duet: session directory escapes its declared DUET_STATE_ROOT." >&2
      return 1
      ;;
  esac
  [ "$(basename "$DUET_DIR")" = "$DUET_SESSION_ID" ] || {
    echo "duet: session id '$DUET_SESSION_ID' does not match directory '$DUET_DIR'." >&2
    return 1
  }
  [ -n "${DUET_SESSION:-}" ] && [ "$DUET_SESSION" = "$DUET_SESSION_ID" ] || {
    echo "duet: config DUET_SESSION does not match DUET_SESSION_ID '$DUET_SESSION_ID'." >&2
    return 1
  }
  if [ -n "$config_path" ]; then
    config_dir="$(cd "$(dirname "$config_path")" 2>/dev/null && pwd -P)" || return 1
    [ "$config_dir" = "$canonical_dir" ] || {
      echo "duet: config path does not belong to its declared session directory." >&2
      return 1
    }
  fi
  [ -z "$expected_session" ] || [ "$expected_session" = "$DUET_SESSION_ID" ] || {
    echo "duet: caller is pinned to session '$expected_session', not '$DUET_SESSION_ID'." >&2
    return 1
  }
}

# Capture the caller's actual tmux identity before the target session's socket
# is used. Pane IDs are only server-local, so membership is the tuple
# (socket, server pid, pane id, pane pid), not TMUX_PANE alone.
duet_capture_caller_identity(){
  local caller_socket data
  DUET_CALLER_SOCKET=""
  DUET_CALLER_SERVER_PID=""
  DUET_CALLER_PANE=""
  DUET_CALLER_PANE_PID=""
  [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ] || return 1
  caller_socket="${TMUX%%,*}"
  [ -n "$caller_socket" ] || return 1
  data="$(command tmux -S "$caller_socket" display-message -p -t "$TMUX_PANE" \
    '#{socket_path}|#{pid}|#{pane_id}|#{pane_pid}' 2>/dev/null)" || return 1
  IFS='|' read -r DUET_CALLER_SOCKET DUET_CALLER_SERVER_PID \
    DUET_CALLER_PANE DUET_CALLER_PANE_PID <<< "$data"
  [ "$DUET_CALLER_PANE" = "$TMUX_PANE" ] \
    && [ -n "$DUET_CALLER_SOCKET" ] \
    && [ -n "$DUET_CALLER_SERVER_PID" ] \
    && [ -n "$DUET_CALLER_PANE_PID" ]
}

duet_caller_roster_name(){
  local entry roster_pid
  DUET_CALLER_NAME=""
  duet_capture_caller_identity || return 1
  [ "$DUET_CALLER_SOCKET" = "${DUET_TMUX_SOCKET:-}" ] || return 1
  [ "$DUET_CALLER_SERVER_PID" = "${DUET_TMUX_SERVER_PID:-}" ] || return 1
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  entry="$(awk -F '\t' -v pane="$DUET_CALLER_PANE" \
    'NR > 1 && $3 == pane { value=$1 "|" $4; count++ }
     END { if (count == 1) print value }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null)"
  [ -n "$entry" ] || return 1
  roster_pid="${entry#*|}"
  [ "$roster_pid" = "$DUET_CALLER_PANE_PID" ] || return 1
  DUET_CALLER_NAME="${entry%%|*}"
}

duet_publish_temp_file(){
  local tmp="${1:?temporary file required}" file="${2:?destination required}"
  local before after
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || return 1
  # BSD mv treats an existing directory (including a symlink to one) as a
  # destination container and returns success. Refuse that shape and verify
  # that the inode staged by this caller became the destination.
  [ ! -d "$file" ] || return 1
  before="$(LC_ALL=C ls -di "$tmp" 2>/dev/null | awk '{ print $1; exit }')"
  [ -n "$before" ] || return 1
  mv -f "$tmp" "$file" || return 1
  [ -f "$file" ] && [ ! -L "$file" ] && [ ! -d "$file" ] || return 1
  after="$(LC_ALL=C ls -di "$file" 2>/dev/null | awk '{ print $1; exit }')"
  [ -n "$after" ] && [ "$after" = "$before" ]
}

duet_atomic_write(){
  local file="${1:?file required}" value="${2-}" tmp
  tmp="$(mktemp "$(dirname "$file")/.atomic.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" > "$tmp" \
      || ! duet_publish_temp_file "$tmp" "$file"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
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

# Claude, Codex, and Kimi can collapse a long bracketed paste instead of
# rendering the payload bytes. Return a harness-prefixed normalized token only
# while that harness's marker owns the active composer. Codex and Kimi markers
# are cursor-row scoped so an identical marker in accepted history cannot be
# mistaken for unsent input.
_duet_paste_marker(){
  local pane="${1:?pane required}" harness="${2:-}"
  local marker cursor row line

  if [ -z "$harness" ] || [ "$harness" = claude ]; then
    marker="$(_duet_tmux capture-pane -p -t "$pane" 2>/dev/null \
      | tail -n 6 \
      | awk '
          tolower($0) ~ /pasted text #[0-9]+/ { line=$0 }
          tolower($0) ~ /paste again to expand/ { composer=1 }
          END { if (composer) print line }
        ' \
      | LC_ALL=C tr -cd '[:alnum:]')"
    if [ -n "$marker" ]; then
      printf 'claude%s' "$marker"
      return 0
    fi
    [ -z "$harness" ] || return 0
  fi

  cursor="$(_duet_tmux display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null || true)"
  case "$cursor" in ''|*[!0-9]*) return 0;; esac
  row=$((cursor + 1))
  line="$(_duet_tmux capture-pane -p -t "$pane" 2>/dev/null \
    | awk -v row="$row" 'NR == row { print; exit }')"

  if { [ -z "$harness" ] || [ "$harness" = codex ]; } \
      && printf '%s\n' "$line" | grep -qiE '\[Pasted Content [0-9]+ chars\]'; then
    marker="$(LC_ALL=C printf '%s' "$line" | LC_ALL=C tr -cd '[:alnum:]')"
    [ -z "$marker" ] || printf 'codex%s' "$marker"
    return 0
  fi

  if { [ -z "$harness" ] || [ "$harness" = kimi ]; } \
      && printf '%s\n' "$line" \
        | grep -qiE '\[paste #[0-9]+ \+[0-9]+ lines\]'; then
    marker="$(printf '%s\n' "$line" \
      | grep -ioE '\[paste #[0-9]+ \+[0-9]+ lines\]' \
      | head -n 1 \
      | LC_ALL=C tr -cd '[:alnum:]')"
    [ -z "$marker" ] || printf 'kimi%s' "$marker"
  fi
}

# Codex can render a single bracketed paste as more than one collapsed marker,
# with the later marker appearing after the verifier first sampled the cursor
# row.  Accept only an exact token or an extension made solely of additional
# normalized Codex paste markers.  Arbitrary echoed characters and a different
# marker are deliberately not treated as ours.
_duet_codex_marker_owned(){
  local current="${1:-}" token="${2:-}" remainder
  [ -n "$current" ] && [ -n "$token" ] || return 1
  printf '%s\n' "$token" \
    | grep -qE '^codex(PastedContent[0-9]+chars)+$' || return 1
  [ "$current" = "$token" ] && return 0
  case "$current" in "$token"*) remainder="${current#"$token"}" ;; *) return 1;; esac
  printf '%s\n' "$remainder" \
    | grep -qE '^(PastedContent[0-9]+chars)+$'
}

_duet_marker_owned(){
  local harness="${1:-}" current="${2:-}" token="${3:-}"
  [ -n "$current" ] && [ -n "$token" ] || return 1
  [ "$current" = "$token" ] && return 0
  [ "$harness" = codex ] \
    && _duet_codex_marker_owned "$current" "$token"
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
# observed leaving it after Enter. The entire READY -> LANDED -> SUBMITTED state
# machine is bounded and in-process:
#   DUET_SEND_DEAD                pane disappeared before a verified landing
#   DUET_SEND_NOT_LANDED          no paste occurred; caller may retry later
#   DUET_SEND_LANDED_UNVERIFIED   paste may have landed, but submission is
#                                 ambiguous; that recipient must stop
duet_send_verified(){
  local pane="${1:-}" payload="${2:-}" interrupt="${3:-}" harness="${4:-}"
  local probe buffer i e marker_before marker_now landing_kind="" landing_token=""
  local landing_checks="${DUET_LANDING_CHECKS:-20}"
  local submit_attempts="${DUET_SUBMIT_ATTEMPTS:-3}"
  local submit_checks="${DUET_SUBMIT_CHECKS:-12}"
  local landing_sleep="${DUET_LANDING_SLEEP:-0.1}"
  local submit_sleep="${DUET_SUBMIT_SLEEP:-0.2}"
  DUET_SEND_COLLAPSED=""
  DUET_SEND_LANDING_OBSERVED=""
  DUET_SEND_SUBMITTED=""

  case "$landing_checks" in ''|*[!0-9]*) landing_checks=20;; esac
  case "$submit_attempts" in ''|*[!0-9]*) submit_attempts=3;; esac
  case "$submit_checks" in ''|*[!0-9]*) submit_checks=12;; esac

  if ! _duet_alive "$pane"; then
    echo "duet: target pane $pane is gone; not sending." >&2
    return "$DUET_SEND_DEAD"
  fi

  # Interrupt is deliberately a live adapter action, not a durable
  # supersession protocol. All supported TUIs accept Escape as cancellation.
  if [ -n "$interrupt" ]; then
    _duet_tmux send-keys -t "$pane" Escape
    sleep 0.4
  fi

  probe="$(_duet_probe "$payload")"
  [ -n "$probe" ] || {
    echo "duet: refusing to send an empty/unprobeable payload to $pane" >&2
    return "$DUET_SEND_NOT_LANDED"
  }
  marker_before="$(_duet_paste_marker "$pane" "$harness")"
  if [ -n "$marker_before" ]; then
    echo "duet: target pane $pane already has a $harness paste marker; not pasting." >&2
    return "$DUET_SEND_NOT_LANDED"
  fi

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

  for i in $(seq 1 "$landing_checks"); do
    sleep "$landing_sleep"
    if _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
      landing_kind=probe
      landing_token="$probe"
      DUET_SEND_LANDING_OBSERVED=probe
      break
    fi
    marker_now="$(_duet_paste_marker "$pane" "$harness")"
    if [ -n "$marker_now" ] && [ "$marker_now" != "$marker_before" ]; then
      landing_kind=marker
      landing_token="$marker_now"
      DUET_SEND_COLLAPSED=1
      DUET_SEND_LANDING_OBSERVED=marker
      break
    fi
  done
  if [ -z "$landing_kind" ]; then
    echo "duet: paste command succeeded but landing is unverified in pane $pane" >&2
    return "$DUET_SEND_LANDED_UNVERIFIED"
  fi

  # Once landing has been observed, only retry Enter. Re-pasting here could
  # duplicate an already accepted task.
  for e in $(seq 1 "$submit_attempts"); do
    _duet_tmux send-keys -t "$pane" Enter
    for i in $(seq 1 "$submit_checks"); do
      sleep "$submit_sleep"
      if ! _duet_alive "$pane"; then
        echo "duet: target pane $pane disappeared after payload landing; submission is ambiguous." >&2
        return "$DUET_SEND_LANDED_UNVERIFIED"
      fi
      case "$landing_kind" in
        probe)
          if ! _duet_present "$(_duet_tail_strip "$pane" 4)" "$landing_token"; then
            DUET_SEND_SUBMITTED=1
            return 0
          fi
          ;;
        marker)
          marker_now="$(_duet_paste_marker "$pane" "$harness")"
          if [ -z "$marker_now" ]; then
            DUET_SEND_SUBMITTED=1
            return 0
          fi
          if [ "$harness" = codex ] \
              && _duet_codex_marker_owned "$marker_now" "$landing_token"; then
            # A second placeholder can appear after the first sample.  Grow
            # the exact capability rather than mistaking that redraw for a
            # successful submission.
            landing_token="$marker_now"
          elif ! _duet_marker_owned "$harness" "$marker_now" "$landing_token"; then
            echo "duet: collapsed composer changed ownership in pane $pane" >&2
            return "$DUET_SEND_LANDED_UNVERIFIED"
          fi
          ;;
      esac
    done
  done

  echo "duet: payload landed in pane $pane but submission is unverified." >&2
  return "$DUET_SEND_LANDED_UNVERIFIED"
}

# Remove only the delimited block owned by duet. Existing surrounding content
# and even an otherwise-empty user-created anchor file are preserved.
duet_strip_anchor_file(){
  [ -n "${1:-}" ] || return 0
  [ ! -L "$1" ] || {
    echo "duet: refusing to edit symlinked instruction file: $1" >&2
    return 1
  }
  [ -f "$1" ] || return 0
  perl -0777 -pi -e 's/\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\n?//sg' "$1" 2>/dev/null
}

duet_strip_session_anchors(){
  local workdir="${1:-}"
  [ -n "$workdir" ] || return 0
  duet_strip_anchor_file "$workdir/AGENTS.md" || return 1
  duet_strip_anchor_file "$workdir/CLAUDE.md"
}

duet_daemon_process_matches(){
  local pid="${1:-}" config_path="${2:-}" session_id="${3:-}" command_line
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  [ -n "$config_path" ] && [ -n "$session_id" ] || return 1
  command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *duet-deliverd.sh*) : ;;
    *) return 1 ;;
  esac
  # Keep the wildcards outside the quoted segment. Quoting makes every byte
  # of the canonical config path literal even when a state-root component
  # contains shell-pattern characters such as '*', '?', or '['.
  case " $command_line " in
    *" --session $config_path --session-id $session_id "*) return 0 ;;
    *) return 1 ;;
  esac
}

duet_stop_daemon(){
  local dir="${1:-}" loops="${2:-30}" pid owner owner_pid i session_id
  local config_path pid_path lock_path
  [ -n "$dir" ] || return 0
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  session_id="$(basename "$dir")"
  config_path="$dir/duet.env"
  pid_path="$dir/daemon.pid"
  lock_path="$dir/.daemon.lock"

  pid="$(cat "$pid_path" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*)
      if [ -e "$pid_path" ] || [ -L "$pid_path" ]; then
        echo "duet: daemon state is incomplete; refusing unverified cleanup." >&2
        return 1
      fi
      # The daemon removes its pid file immediately before releasing its lock.
      # If end observes that gap, wait for the verified owner to finish rather
      # than reporting a stale-lock failure.
      for i in $(seq 1 "$loops"); do
        if [ ! -e "$lock_path" ] && [ ! -L "$lock_path" ]; then
          return 0
        fi
        sleep 0.1
      done
      echo "duet: daemon exited without completing lock cleanup." >&2
      return 1
      ;;
  esac
  # duet-end publishes .ended before calling here. Give the daemon one short
  # poll window to take that orderly path; signaling while its EXIT trap is
  # already removing daemon.pid can otherwise interrupt lock cleanup.
  if [ -f "$dir/.ended" ]; then
    for i in 1 2 3 4 5; do
      if ! kill -0 "$pid" 2>/dev/null \
          && [ ! -e "$pid_path" ] && [ ! -L "$pid_path" ] \
          && [ ! -e "$lock_path" ] && [ ! -L "$lock_path" ]; then
        return 0
      fi
      sleep 0.1
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    owner="$(duet_lock_owner_read "$lock_path")"
    owner_pid="${owner%%$'\t'*}"
    if [ "$owner_pid" != "$pid" ] \
        || ! duet_daemon_process_matches "$pid" "$config_path" "$session_id"; then
      echo "duet: daemon identity is inconsistent; refusing to signal pid $pid." >&2
      return 1
    fi
    kill -TERM "$pid" 2>/dev/null || true
  fi

  # Cleanup removes daemon.pid just before releasing .daemon.lock. Wait for
  # both artifacts as well as process exit so end cannot race that tiny gap.
  for i in $(seq 1 "$loops"); do
    if ! kill -0 "$pid" 2>/dev/null \
        && [ ! -e "$pid_path" ] && [ ! -L "$pid_path" ] \
        && [ ! -e "$lock_path" ] && [ ! -L "$lock_path" ]; then
      return 0
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "duet: delivery daemon $pid did not exit after TERM." >&2
  else
    echo "duet: delivery daemon $pid exited without completing cleanup." >&2
  fi
  return 1
}

# Kill only panes explicitly marked as spawned. The caller pane is fenced even
# if a malformed roster marks it spawned.
duet_kill_spawned_panes(){
  local roster="${1:-}" exempt="${2:-}" legacy_pane="${3:-}"
  local legacy_pid="${4:-}"
  local pane recorded_pid spawned actual_pid
  local victims="" victim victim_pane victim_pid failed=""
  if [ ! -e "$roster" ] && [ ! -L "$roster" ]; then
    # v0.1.x recorded CODEX_PANE_PID even though it had no roster. Require that
    # exact process identity; a server-local pane ID alone is never kill proof.
    actual_pid="$(_duet_tmux display-message -p -t "$legacy_pane" '#{pane_pid}' 2>/dev/null || true)"
    if [ -n "$legacy_pane" ] && [ "$legacy_pane" != "$exempt" ] \
        && [ -n "$legacy_pid" ] && [ "$actual_pid" = "$legacy_pid" ]; then
      _duet_tmux send-keys -t "$legacy_pane" C-c 2>/dev/null || true
      sleep 0.3
      actual_pid="$(_duet_tmux display-message -p -t "$legacy_pane" '#{pane_pid}' 2>/dev/null || true)"
      if [ "$actual_pid" = "$legacy_pid" ] \
          && ! _duet_tmux kill-pane -t "$legacy_pane" 2>/dev/null; then
        # The process may exit between the identity check and kill-pane. A
        # missing/recycled pane means the recorded victim is already gone.
        actual_pid="$(_duet_tmux display-message -p -t "$legacy_pane" '#{pane_pid}' 2>/dev/null || true)"
        if [ "$actual_pid" = "$legacy_pid" ]; then
          echo "duet: failed to stop spawned legacy pane $legacy_pane." >&2
          return 1
        fi
      fi
    fi
    return 0
  fi
  if ! duet_validate_roster "$roster"; then
    echo "duet: invalid roster cannot authorize pane teardown: $roster" >&2
    return 1
  fi

  while IFS='|' read -r pane recorded_pid spawned; do
    [ "$spawned" = 1 ] || continue
    [ -n "$pane" ] || continue
    [ -n "$recorded_pid" ] || continue
    [ "$pane" = "$exempt" ] && continue
    actual_pid="$(_duet_tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
    [ "$actual_pid" = "$recorded_pid" ] || continue
    _duet_tmux send-keys -t "$pane" C-c 2>/dev/null || true
    victims="${victims}${victims:+ }$pane|$recorded_pid"
  done < <(awk -F '\t' 'NR > 1 { sub(/\r$/, "", $6); print $3 "|" $4 "|" $6 }' "$roster")

  [ -n "$victims" ] || return 0
  sleep 0.3
  for victim in $victims; do
    victim_pane="${victim%%|*}"
    victim_pid="${victim#*|}"
    [ "$victim_pane" = "$exempt" ] && continue
    actual_pid="$(_duet_tmux display-message -p -t "$victim_pane" '#{pane_pid}' 2>/dev/null || true)"
    if [ "$actual_pid" = "$victim_pid" ] \
        && ! _duet_tmux kill-pane -t "$victim_pane" 2>/dev/null; then
      # send-keys may have made the pane exit after the identity check. Only a
      # still-matching tuple is a teardown failure; absence or reuse is safe.
      actual_pid="$(_duet_tmux display-message -p -t "$victim_pane" '#{pane_pid}' 2>/dev/null || true)"
      if [ "$actual_pid" = "$victim_pid" ]; then
        echo "duet: failed to stop spawned pane $victim_pane." >&2
        failed=1
      fi
    fi
  done
  [ -z "$failed" ]
}

# Validate the immutable session roster before using any row as an identity,
# liveness, routing, or teardown capability. This mirrors Import-DuetRoster on
# Windows and keeps ambiguous/corrupt tuples UNKNOWN rather than DEAD.
duet_validate_roster(){
  local roster="${1:-${DUET_DIR:?}/roster.tsv}"
  DUET_ROSTER_VALID=""
  duet_regular_file_without_nul "$roster" || return 1
  if LC_ALL=C awk '
    function reject(){ bad=1; exit }
    function int32(s, positive, t){
      if (s !~ /^[0-9]+$/) return 0
      t=s; sub(/^0+/, "", t); if (t=="") t="0"
      if (positive && t=="0") return 0
      if (length(t)>10 || (length(t)==10 && ("x" t) > "x2147483647")) return 0
      return 1
    }
    {
      line=$0; sub(/\r$/, "", line)
      if (NR==1) {
        if (line != "name\tharness\tpane_id\tpane_pid\trank\tspawned") reject()
        header=1; next
      }
      if (line=="") next
      n=split(line,c,"\t"); if (n != 6) reject()
      name=c[1]; harness=c[2]; pane=c[3]; pid=c[4]; rank=c[5]; spawned=c[6]
      if (name !~ /^[A-Za-z0-9_-]+$/) reject()
      if (harness!="claude" && harness!="codex" && harness!="kimi") reject()
      if (pane !~ /^%[0-9]+$/ || !int32(pid,1) || !int32(rank,0)) reject()
      if (spawned!="0" && spawned!="1") reject()
      folded_name=tolower(name)
      if ((folded_name in names)||(pane in panes)||(pid in pids)||(rank in ranks)) reject()
      names[folded_name]=1; panes[pane]=1; pids[pid]=1; ranks[rank]=1; rows++
      if (rows > 5) reject()
    }
    END { exit (bad || !header || rows < 1) }
  ' "$roster"; then
    DUET_ROSTER_VALID=1
    return 0
  fi
  return 1
}

# awk and shell variables cannot faithfully represent NUL bytes. Reject them
# at the raw-file boundary before parsing metadata or identity capabilities.
duet_regular_file_without_nul(){
  local file="${1:?file required}"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  LC_ALL=C tr -d '\000' < "$file" | cmp -s "$file" -
}

# Parse the protocol's bounded decimal space without feeding untrusted text to
# Bash arithmetic. By default the representation must be canonical (only zero
# itself may start with zero); order/sequence callers may allow zero padding.
duet_decimal_d10(){
  local value="${1-}" allow_leading_zeros="${2:-0}" prefix normalized
  DUET_DECIMAL_VALUE=""
  case "$value" in ''|*[!0-9]*) return 1;; esac
  if [ "$allow_leading_zeros" = 1 ]; then
    [ "${#value}" -le 10 ] || return 1
    prefix="${value%%[!0]*}"
    normalized="${value#"$prefix"}"
    [ -n "$normalized" ] || normalized=0
  else
    case "$value" in
      0) normalized=0 ;;
      0*) return 1 ;;
      *) normalized="$value" ;;
    esac
  fi
  [ "${#normalized}" -le 10 ] || return 1
  DUET_DECIMAL_VALUE="$normalized"
}

duet_roster_has_name(){
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  awk -F '\t' -v name="${1:-}" \
    'NR > 1 && $1 == name { count++ } END { exit !(count == 1) }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

duet_roster_name_for_pane(){
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  awk -F '\t' -v pane="${1:-}" \
    'NR > 1 && $3 == pane { value=$1; count++ } END { if (count == 1) print value }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

duet_roster_pane_for_name(){
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  awk -F '\t' -v name="${1:-}" \
    'NR > 1 && $1 == name { value=$3; count++ } END { if (count == 1) print value }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

duet_roster_harness_for_name(){
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  awk -F '\t' -v name="${1:-}" \
    'NR > 1 && $1 == name { value=$2; count++ } END { if (count == 1) print value }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null
}

# Pane IDs can be reused. A member is live only when both its pane and the
# roster's recorded pane process still match on the pinned tmux server.
duet_roster_member_alive(){
  local name="${1:?name required}" entry pane roster_pid actual_pid
  duet_tmux_server_matches || return 1
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  entry="$(awk -F '\t' -v name="$name" \
    'NR > 1 && $1 == name { value=$3 "|" $4; count++ }
     END { if (count == 1) print value }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null)"
  [ -n "$entry" ] || return 1
  pane="${entry%%|*}"
  roster_pid="${entry#*|}"
  [ -n "$pane" ] && [ -n "$roster_pid" ] || return 1
  actual_pid="$(_duet_tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
  [ "$actual_pid" = "$roster_pid" ]
}

duet_daemon_alive(){
  local pid_file="${DUET_DIR:?}/daemon.pid" pid owner config_path
  [ -f "$pid_file" ] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  owner="$(duet_lock_owner_read "$DUET_DIR/.daemon.lock")"
  [ "${owner%%$'\t'*}" = "$pid" ] || return 1
  config_path="$(cd "$DUET_DIR" 2>/dev/null && pwd -P)/duet.env" || return 1
  duet_daemon_process_matches "$pid" "$config_path" "${DUET_SESSION_ID:?}"
}

duet_lock_owner_read(){
  local lock="${1:?lock path required}"
  [ -d "$lock" ] || return 0
  cat "$lock/owner" 2>/dev/null || true
}

# Small in-process serialization primitive. A process crash may leave the
# directory behind; v4 deliberately does not recover that session.
duet_lock_acquire(){
  local lock="${1:?lock path required}" attempts="${2:-200}"
  local owner_pid="${BASHPID:-$$}" i
  for i in $(seq 1 "$attempts"); do
    if mkdir "$lock" 2>/dev/null; then
      if printf '%s\t%s\n' "$owner_pid" "$DUET_LOCK_TOKEN" > "$lock/owner"; then
        return 0
      fi
      rmdir "$lock" 2>/dev/null || true
      return 1
    fi
    sleep 0.05
  done
  echo "duet: timed out acquiring lock $lock" >&2
  return 1
}

duet_lock_release(){
  local lock="${1:?lock path required}" owner="$DUET_LOCK_TOKEN" held
  held="$(duet_lock_owner_read "$lock")"
  [ "${held#*$'\t'}" = "$owner" ] || return 1
  rm -f "$lock/owner" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null
}

duet_next_sequence(){
  local box="${1:?queue directory required}" current next tmp existing sequence_dir
  if [ -f "$box/.counter" ]; then
    current="$(cat "$box/.counter" 2>/dev/null || true)"
    if ! duet_decimal_d10 "$current"; then
      echo "duet: corrupt counter in $box" >&2
      return 1
    fi
    current="$DUET_DECIMAL_VALUE"
  else
    existing="$(find "$box" -type f \( -name 'N-*.msg' -o -name 'I-*.msg' \) -print -quit 2>/dev/null)"
    [ -z "$existing" ] || { echo "duet: missing counter in non-empty queue $box" >&2; return 1; }
    current=0
  fi
  if [ "$current" = 9999999999 ]; then
    echo "duet: sequence exhausted (D10 cap) in $box" >&2
    return 1
  fi
  next=$((current + 1))
  printf -v DUET_SEQUENCE '%010d' "$next"
  # A manually rolled-back but syntactically valid counter must not reuse a
  # stable ID that already exists in either the active root or a terminal
  # archive. Sidecars count too: they prove that sequence was once allocated.
  for sequence_dir in "$box" "$box/delivered" "$box/rejected"; do
    for existing in "$sequence_dir/N-$DUET_SEQUENCE.msg"* \
        "$sequence_dir/I-$DUET_SEQUENCE.msg"*; do
      [ ! -e "$existing" ] || {
        echo "duet: counter rollback would reuse sequence $DUET_SEQUENCE in $box" >&2
        return 1
      }
    done
  done
  tmp="$(mktemp "$box/.counter.XXXXXX")" || return 1
  if ! printf '%s\n' "$next" > "$tmp" \
      || ! duet_publish_temp_file "$tmp" "$box/.counter"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

duet_append_transcript(){
  local id="${1:?message id required}" sender="${2:?sender required}"
  local recipient="${3:?recipient required}" mode="${4:?mode required}"
  local body="${5-}" lock="${DUET_DIR:?}/.transcript.lock"
  local ts
  duet_lock_acquire "$lock" || return 1
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if ! printf '\n----- %s  id=%s  %s -> %s  (%s) -----\n%s\n' \
      "$ts" "$id" "$sender" "$recipient" "$mode" "$body" \
      >> "$DUET_DIR/transcript.md"; then
    duet_lock_release "$lock" || true
    return 1
  fi
  duet_lock_release "$lock" || true
}

# Enqueue one immutable message. The queue lock remains held through transcript
# append and final publish, so transcript order matches sequence order for a
# recipient. Sets DUET_ENQUEUED_ID, DUET_ENQUEUED_FILE, and DUET_SEQUENCE.
# args: physical-queue sender wire-recipient mode body
duet_enqueue_message(){
  local queue="${1:?queue required}" sender="${2:?sender required}"
  local recipient="${3:?recipient required}" mode="${4:?mode required}" body="${5-}"
  local box lock tmp prefix final id encoded
  local enqueue_lock_attempts="${DUET_ENQUEUE_LOCK_ATTEMPTS:-1200}"
  case "$queue" in ''|*[!A-Za-z0-9_-]*) echo "duet: invalid queue '$queue'" >&2; return 1;; esac
  case "$mode" in NORMAL) prefix=N;; INTERRUPT) prefix=I;; *) echo "duet: invalid mode '$mode'" >&2; return 1;; esac
  case "${DUET_SESSION_ID:-}${sender}${recipient}" in
    ''|*[!A-Za-z0-9_-]*) echo "duet: invalid message metadata" >&2; return 1;;
  esac
  duet_roster_has_name "$queue" \
    || { echo "duet: queue '$queue' is not a roster member" >&2; return 1; }
  if [ "$recipient" != all ] && [ "$recipient" != "$queue" ]; then
    echo "duet: recipient '$recipient' does not match queue '$queue'" >&2
    return 1
  fi
  duet_roster_has_name "$sender" \
    || { echo "duet: sender '$sender' is not a roster member" >&2; return 1; }
  case "$enqueue_lock_attempts" in ''|*[!0-9]*) enqueue_lock_attempts=1200;; esac

  if [ -f "${DUET_DIR:?}/.ended" ]; then
    echo "duet: session has ended; message was not queued." >&2
    return 1
  fi
  if ! duet_daemon_alive; then
    echo "duet: delivery daemon is not alive; message was not queued." >&2
    return 1
  fi
  box="$DUET_DIR/inbox/$queue"
  mkdir -p "$box/delivered" "$box/rejected" || return 1
  lock="$box/.enqueue.lock"
  duet_lock_acquire "$lock" "$enqueue_lock_attempts" || return 1
  if [ -f "$DUET_DIR/.ended" ]; then
    duet_lock_release "$lock" || true
    echo "duet: session has ended; message was not queued." >&2
    return 1
  fi
  if ! duet_next_sequence "$box"; then
    duet_lock_release "$lock" || true
    return 1
  fi

  id="m-${DUET_SESSION_ID:?}-${queue}-${DUET_SEQUENCE}"
  tmp="$(mktemp "$box/.message.XXXXXX")" || {
    duet_lock_release "$lock" || true
    return 1
  }
  if ! encoded="$(printf '%s' "$body" | base64 | tr -d '\r\n')"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    return 1
  fi
  if ! {
    printf 'DUETv4\n'
    printf 'id\t%s\n' "$id"
    printf 'session\t%s\n' "${DUET_SESSION_ID:?}"
    printf 'mode\t%s\n' "$mode"
    printf 'sender\t%s\n' "$sender"
    printf 'recipient\t%s\n' "$recipient"
    printf 'body64\t%s\n' "$encoded"
  } > "$tmp"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    return 1
  fi

  if ! duet_append_transcript "$id" "$sender" "$recipient" "$mode" "$body"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    return 1
  fi
  final="$box/${prefix}-${DUET_SEQUENCE}.msg"
  if [ -e "$final" ] || ! mv "$tmp" "$final"; then
    rm -f "$tmp"
    duet_lock_release "$lock" || true
    return 1
  fi
  duet_lock_release "$lock" || true
  DUET_ENQUEUED_ID="$id"
  DUET_ENQUEUED_FILE="$final"
}

_duet_message_structure_valid(){
  # Bash 3.2 has no associative arrays, so use POSIX awk for the wire-schema
  # pass.  LC_ALL=C makes [:cntrl:] exactly the ASCII C0/DEL set that the
  # PowerShell parser rejects.  Strip one terminal CR per line only as CRLF
  # framing; a second CR remains metadata and is rejected.
  duet_regular_file_without_nul "$1" || return 1
  LC_ALL=C awk '
    BEGIN {
      known["id"]; known["session"]; known["mode"]; known["sender"]
      known["recipient"]; known["body64"]
      required["id"]; required["session"]; required["mode"]
      required["sender"]; required["recipient"]; required["body64"]
      cr = sprintf("%c", 13)
    }
    {
      line = $0
      if (substr(line, length(line), 1) == cr) {
        line = substr(line, 1, length(line) - 1)
      }
      if (NR == 1) {
        if (line != "DUETv4") bad = 1
        next
      }
      if (line == "") next
      tab = index(line, "\t")
      if (tab) {
        key = substr(line, 1, tab - 1)
        value = substr(line, tab + 1)
      } else {
        key = line
        value = ""
      }
      if (!(key in known) || (key in seen)) {
        bad = 1
        next
      }
      seen[key] = 1
      if (key != "body64" && value ~ /[[:cntrl:]]/) bad = 1
    }
    END {
      if (NR < 1) bad = 1
      for (key in required) if (!(key in seen)) bad = 1
      exit bad ? 1 : 0
    }
  ' "$1"
}

_duet_message_field(){
  LC_ALL=C awk -v wanted="$2" '
    BEGIN { cr = sprintf("%c", 13) }
    {
      line = $0
      if (substr(line, length(line), 1) == cr) {
        line = substr(line, 1, length(line) - 1)
      }
      tab = index(line, "\t")
      key = tab ? substr(line, 1, tab - 1) : line
      if (key == wanted) {
        if (tab) print substr(line, tab + 1)
        else print ""
        exit
      }
    }
  ' "$1"
}

duet_read_message(){
  local file="${1:?message file required}" encoded decoded decoded_file decode_rc
  local LC_ALL=C

  DUET_MESSAGE_ID=""
  DUET_MESSAGE_SESSION=""
  DUET_MESSAGE_MODE=""
  DUET_MESSAGE_SENDER=""
  DUET_MESSAGE_RECIPIENT=""
  DUET_MESSAGE_BODY=""

  _duet_message_structure_valid "$file" || return 1
  DUET_MESSAGE_ID="$(_duet_message_field "$file" id)" || return 1
  DUET_MESSAGE_SESSION="$(_duet_message_field "$file" session)" || return 1
  DUET_MESSAGE_MODE="$(_duet_message_field "$file" mode)" || return 1
  DUET_MESSAGE_SENDER="$(_duet_message_field "$file" sender)" || return 1
  DUET_MESSAGE_RECIPIENT="$(_duet_message_field "$file" recipient)" || return 1
  encoded="$(_duet_message_field "$file" body64)" || return 1
  decoded_file="$(mktemp "${TMPDIR:-/tmp}/duet-message-body.XXXXXX")" || return 1
  if printf '' | base64 -d >/dev/null 2>&1; then
    if printf '%s' "$encoded" | base64 -d > "$decoded_file" 2>/dev/null; then
      decode_rc=0
    else
      decode_rc=$?
    fi
  else
    if printf '%s' "$encoded" | base64 -D > "$decoded_file" 2>/dev/null; then
      decode_rc=0
    else
      decode_rc=$?
    fi
  fi
  if [ "$decode_rc" -ne 0 ] \
      || ! duet_regular_file_without_nul "$decoded_file" \
      || ! command -v iconv >/dev/null 2>&1 \
      || ! iconv -f UTF-8 -t UTF-8 "$decoded_file" >/dev/null 2>&1; then
    rm -f "$decoded_file"
    return 1
  fi
  decoded="$(command cat "$decoded_file"; printf '.')"
  decode_rc=$?
  rm -f "$decoded_file"
  [ "$decode_rc" -eq 0 ] || return 1
  DUET_MESSAGE_BODY="${decoded%.}"
  case "$DUET_MESSAGE_ID$DUET_MESSAGE_SESSION$DUET_MESSAGE_SENDER$DUET_MESSAGE_RECIPIENT" in
    *[!A-Za-z0-9_-]*) return 1;;
  esac
  [ -n "$DUET_MESSAGE_ID" ] && [ -n "$DUET_MESSAGE_SESSION" ] \
    && [ -n "$DUET_MESSAGE_SENDER" ] && [ -n "$DUET_MESSAGE_RECIPIENT" ] \
    || return 1
  case "$DUET_MESSAGE_MODE" in NORMAL|INTERRUPT) :;; *) return 1;; esac
}

duet_build_payload(){
  printf '[DUET session=%s id=%s from=%s to=%s]\n%s\n[DUET session=%s id=%s end]' \
    "$DUET_MESSAGE_SESSION" "$DUET_MESSAGE_ID" \
    "$DUET_MESSAGE_SENDER" "$DUET_MESSAGE_RECIPIENT" "$DUET_MESSAGE_BODY" \
    "$DUET_MESSAGE_SESSION" "$DUET_MESSAGE_ID"
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
