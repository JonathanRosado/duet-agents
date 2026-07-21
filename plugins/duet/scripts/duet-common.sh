#!/usr/bin/env bash
# Shared helpers for the tmux/bash ensemble path.

# duet_send_verified result codes. Success is the normal shell status 0.
DUET_SEND_DEAD=20
DUET_SEND_NOT_LANDED=21
DUET_SEND_LANDED_UNVERIFIED=22
# A positively identified Codex collapsed-paste marker remained in the active
# composer after the bounded Enter retries.  The caller must durably enter the
# clear/retry state before sending recovery keys; it must not paste again yet.
DUET_SEND_COMPOSER_REFUSED=23
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

# Resolve an explicitly pinned session to its config file. Agent-facing
# commands pass allow_current=0; human diagnostics may opt into the ambient
# current symlink with allow_current=1.
duet_resolve_config(){
  local session_arg="${1:-}" allow_current="${2:-0}"
  local state_root="${DUET_STATE_ROOT:-}" cfg="" cfg_dir
  local env_cfg="${DUET_CONFIG:-}" env_dir requested_dir canonical_root
  local require_under_root=""
  DUET_RESOLVED_CONFIG=""

  if [ -n "$session_arg" ]; then
    case "$session_arg" in
      */duet.env) cfg="$session_arg" ;;
      duet.env) cfg="$session_arg" ;;
      */*) cfg="${session_arg%/}/duet.env" ;;
      *)
        if [ -z "$state_root" ]; then
          [ -n "${HOME:-}" ] || {
            echo "duet: HOME or DUET_STATE_ROOT is required to resolve session id '$session_arg'." >&2
            return 1
          }
          state_root="$HOME/.duet"
        fi
        cfg="$state_root/$session_arg/duet.env"
        require_under_root=1
        ;;
    esac
    if [ -n "$env_cfg" ]; then
      [ -f "$env_cfg" ] && [ ! -L "$env_cfg" ] \
        && [ -f "$cfg" ] && [ ! -L "$cfg" ] || {
        echo "duet: DUET_CONFIG and --session do not resolve to the same existing session." >&2
        return 1
      }
      env_dir="$(cd "$(dirname "$env_cfg")" 2>/dev/null && pwd -P)" || return 1
      requested_dir="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd -P)" || return 1
      [ "$env_dir/$(basename "$env_cfg")" = "$requested_dir/$(basename "$cfg")" ] || {
        echo "duet: DUET_CONFIG and --session disagree; refusing ambiguous routing." >&2
        return 1
      }
    fi
  elif [ -n "$env_cfg" ]; then
    cfg="$env_cfg"
  elif [ -n "${DUET_SESSION:-}" ]; then
    if [ -z "$state_root" ]; then
      [ -n "${HOME:-}" ] || {
        echo "duet: HOME or DUET_STATE_ROOT is required to resolve DUET_SESSION." >&2
        return 1
      }
      state_root="$HOME/.duet"
    fi
    cfg="$state_root/$DUET_SESSION/duet.env"
    require_under_root=1
  elif [ "$allow_current" = 1 ]; then
    if [ -z "$state_root" ]; then
      [ -n "${HOME:-}" ] || {
        echo "duet: HOME or DUET_STATE_ROOT is required to resolve current." >&2
        return 1
      }
      state_root="$HOME/.duet"
    fi
    cfg="$state_root/current/duet.env"
    require_under_root=1
  else
    echo "duet: no session was pinned; set DUET_CONFIG/DUET_SESSION or pass --session." >&2
    return 1
  fi

  [ -f "$cfg" ] && [ ! -L "$cfg" ] || {
    echo "duet: pinned session config does not exist: $cfg" >&2
    return 1
  }
  cfg_dir="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd -P)" || return 1
  if [ -n "$require_under_root" ]; then
    canonical_root="$(cd "$state_root" 2>/dev/null && pwd -P)" || return 1
    case "$cfg_dir" in
      "$canonical_root"/*) : ;;
      *)
        echo "duet: resolved session escapes DUET_STATE_ROOT; refusing it." >&2
        return 1
        ;;
    esac
  fi
  DUET_RESOLVED_CONFIG="$cfg_dir/$(basename "$cfg")"
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

# Name the active session that actually owns the caller pane, for actionable
# cross-session refusal diagnostics.
duet_find_caller_session(){
  local state_root="${1:-${DUET_STATE_ROOT:-}}"
  local cfg found="" canonical_root config_parent
  if [ -z "$state_root" ]; then
    [ -n "${HOME:-}" ] || return 1
    state_root="$HOME/.duet"
  fi
  canonical_root="$(cd "$state_root" 2>/dev/null && pwd -P)" || return 1
  [ -n "${DUET_CALLER_PANE:-}" ] || duet_capture_caller_identity || return 1
  for cfg in "$state_root"/*/duet.env; do
    [ -f "$cfg" ] && [ ! -L "$cfg" ] || continue
    [ "$(basename "$(dirname "$cfg")")" != current ] || continue
    config_parent="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd -P)" || continue
    case "$config_parent" in "$canonical_root"/*) : ;; *) continue ;; esac
    [ ! -f "$(dirname "$cfg")/.ended" ] || continue
    found="$(
      (
        unset DUET_DIR DUET_TMUX_SOCKET DUET_TMUX_SERVER_PID DUET_SESSION_ID
        # shellcheck disable=SC1090
        . "$cfg" 2>/dev/null || exit 1
        declared_dir="$(cd "${DUET_DIR:-}" 2>/dev/null && pwd -P)" || exit 1
        [ "$declared_dir" = "$config_parent" ] || exit 1
        [ "${DUET_SESSION_ID:-}" = "$(basename "$config_parent")" ] || exit 1
        [ "${DUET_TMUX_SOCKET:-}" = "$DUET_CALLER_SOCKET" ] || exit 1
        [ "${DUET_TMUX_SERVER_PID:-}" = "$DUET_CALLER_SERVER_PID" ] || exit 1
        duet_validate_roster "${DUET_DIR:-$(dirname "$cfg")}/roster.tsv" || exit 1
        awk -F '\t' -v pane="$DUET_CALLER_PANE" -v pid="$DUET_CALLER_PANE_PID" \
          'NR > 1 && $3 == pane && $4 == pid { count++ }
           END { if (count == 1) print dir }' \
          dir="${DUET_DIR:-$(dirname "$cfg")}" "${DUET_DIR:-$(dirname "$cfg")}/roster.tsv"
      )
    )"
    [ -z "$found" ] || { printf '%s' "$found"; return 0; }
  done
  return 1
}

duet_workdir_key(){
  local workdir="${1:?workdir required}" canonical
  canonical="$(cd "$workdir" 2>/dev/null && pwd -P)" || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$canonical" | shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | sha256sum | awk '{ print $1 }'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$canonical" | openssl dgst -sha256 | awk '{ print $NF }'
  else
    echo "duet: no SHA-256 implementation is available for the workdir registry." >&2
    return 1
  fi
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

# Claude and Codex can collapse a long bracketed paste instead of rendering the
# payload bytes. Return a harness-prefixed normalized token while that marker
# still owns the active composer. Claude adds a nearby expansion hint; Codex's
# "[Pasted Content N chars]" must be read from the cursor row so an identical
# marker in accepted history is never mistaken for unsent input.
_duet_paste_marker(){
  local pane="${1:?pane required}" marker cursor row line
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

  cursor="$(_duet_tmux display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null || true)"
  case "$cursor" in ''|*[!0-9]*) return 0;; esac
  row=$((cursor + 1))
  line="$(_duet_tmux capture-pane -p -t "$pane" 2>/dev/null \
    | awk -v row="$row" 'NR == row { print; exit }')"
  if printf '%s\n' "$line" | grep -qiE '\[Pasted Content [0-9]+ chars\]'; then
    marker="$(LC_ALL=C printf '%s' "$line" | LC_ALL=C tr -cd '[:alnum:]')"
    [ -z "$marker" ] || printf 'codex%s' "$marker"
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
#   DUET_SEND_COMPOSER_REFUSED    an owned Codex collapsed marker remained
#                                 after Enter; persist clear/retry before keys
duet_send_verified(){
  local pane="${1:-}" payload="${2:-}" interrupt="${3:-}" harness="${4:-}"
  local probe buffer i e marker_before marker_now landing_kind="" landing_token=""
  local busy_snapshot="" interrupt_key=Escape
  DUET_SEND_ENTER_TOKEN=""
  DUET_SEND_COLLAPSED=""
  DUET_SEND_LANDING_OBSERVED=""

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
  if [ -n "$marker_before" ]; then
    echo "duet: target pane $pane already has a collapsed composer; not pasting." >&2
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

  for i in $(seq 1 20); do
    sleep 0.1
    if _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
      landing_kind=probe
      landing_token="$probe"
      DUET_SEND_LANDING_OBSERVED=probe
      break
    fi
    marker_now="$(_duet_paste_marker "$pane")"
    if [ -n "$marker_now" ] && [ "$marker_now" != "$marker_before" ]; then
      landing_kind=marker
      landing_token="$marker_now"
      DUET_SEND_ENTER_TOKEN="$marker_now"
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
          marker_now="$(_duet_paste_marker "$pane")"
          [ -n "$marker_now" ] || return 0
          if [ "$harness" = codex ] \
              && _duet_codex_marker_owned "$marker_now" "$landing_token"; then
            # A second placeholder can appear after the first sample.  Grow
            # the exact capability rather than mistaking that redraw for a
            # successful submission.
            landing_token="$marker_now"
            DUET_SEND_ENTER_TOKEN="$marker_now"
          elif [ "$marker_now" != "$landing_token" ]; then
            echo "duet: collapsed composer changed ownership in pane $pane" >&2
            return "$DUET_SEND_LANDED_UNVERIFIED"
          fi
          ;;
      esac
    done
  done

  if [ "$harness" = codex ] && [ "$landing_kind" = marker ] \
      && _duet_codex_marker_owned "$(_duet_paste_marker "$pane")" "$landing_token"; then
    echo "duet: Codex composer retained an owned collapsed paste after Enter." >&2
    return "$DUET_SEND_COMPOSER_REFUSED"
  fi
  echo "duet: payload landed in pane $pane but submission is unverified." >&2
  return "$DUET_SEND_LANDED_UNVERIFIED"
}

# Enter-only continuation for a payload that may already occupy the composer.
# It never pastes. DUET_SEND_COMPOSER_CLEAR distinguishes an unverifiable but
# absent payload from one whose probe/marker still visibly owns the composer.
duet_send_enter_only(){
  local pane="${1:-}" payload="${2:-}" marker_token="${3:-}" harness="${4:-}"
  local probe i e kind marker_now
  DUET_SEND_COMPOSER_CLEAR=""
  DUET_SEND_LANDING_OBSERVED=""
  DUET_SEND_ENTER_TOKEN=""
  _duet_alive "$pane" || return "$DUET_SEND_DEAD"
  probe="$(_duet_probe "$payload")"
  [ -n "$probe" ] || return "$DUET_SEND_LANDED_UNVERIFIED"
  if _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
    kind=probe
    DUET_SEND_LANDING_OBSERVED=probe
  else
    marker_now="$(_duet_paste_marker "$pane")"
  fi
  if [ -z "${kind:-}" ] && [ -n "$marker_token" ] \
      && { [ "$marker_now" = "$marker_token" ] \
           || { [ "$harness" = codex ] \
                && _duet_codex_marker_owned "$marker_now" "$marker_token"; }; }; then
    kind=marker
    DUET_SEND_LANDING_OBSERVED=marker
    marker_token="$marker_now"
    DUET_SEND_ENTER_TOKEN="$marker_now"
  elif [ -z "${kind:-}" ]; then
    # Submission remains unverifiable, but the uncertain payload no longer
    # owns the composer. This distinction lets the daemon release a promotion
    # fence without ever repasting the message.
    DUET_SEND_COMPOSER_CLEAR=1
    return "$DUET_SEND_LANDED_UNVERIFIED"
  fi
  for e in 1 2 3; do
    _duet_tmux send-keys -t "$pane" Enter
    for i in $(seq 1 12); do
      sleep 0.2
      _duet_alive "$pane" || return "$DUET_SEND_DEAD"
      case "$kind" in
        probe)
          if ! _duet_present "$(_duet_tail_strip "$pane" 4)" "$probe"; then
            DUET_SEND_COMPOSER_CLEAR=1
            return 0
          fi
          ;;
        marker)
          marker_now="$(_duet_paste_marker "$pane")"
          if [ -z "$marker_now" ]; then
            DUET_SEND_COMPOSER_CLEAR=1
            return 0
          fi
          if [ "$harness" = codex ] \
              && _duet_codex_marker_owned "$marker_now" "$marker_token"; then
            marker_token="$marker_now"
            DUET_SEND_ENTER_TOKEN="$marker_now"
          elif [ "$marker_now" != "$marker_token" ]; then
            return "$DUET_SEND_LANDED_UNVERIFIED"
          fi
          ;;
      esac
    done
  done
  if [ "$harness" = codex ] && [ "$kind" = marker ] \
      && _duet_codex_marker_owned "$(_duet_paste_marker "$pane")" "$marker_token"; then
    return "$DUET_SEND_COMPOSER_REFUSED"
  fi
  return "$DUET_SEND_LANDED_UNVERIFIED"
}

# Clear a composer only when the durable Codex marker capability still owns
# the cursor row.  Escape then Ctrl-U is the recovery sequence observed against
# the Codex TUI.  A missing marker is also a successful clear (the daemon may
# have crashed after the keys); a foreign/changed marker is never touched.
duet_clear_refused_composer(){
  local pane="${1:-}" marker_token="${2:-}" marker_now i
  DUET_SEND_COMPOSER_CLEAR=""
  _duet_alive "$pane" || return "$DUET_SEND_DEAD"
  printf '%s\n' "$marker_token" \
    | grep -qE '^codex(PastedContent[0-9]+chars)+$' \
    || return "$DUET_SEND_LANDED_UNVERIFIED"
  marker_now="$(_duet_paste_marker "$pane")"
  if [ -z "$marker_now" ]; then
    DUET_SEND_COMPOSER_CLEAR=1
    return 0
  fi
  _duet_codex_marker_owned "$marker_now" "$marker_token" \
    || return "$DUET_SEND_LANDED_UNVERIFIED"

  _duet_tmux send-keys -t "$pane" Escape
  sleep 0.1
  # Escape can itself submit, clear, or redraw the composer. Re-establish the
  # exact ownership capability before sending the destructive Ctrl-U key.
  marker_now="$(_duet_paste_marker "$pane")"
  if [ -z "$marker_now" ]; then
    DUET_SEND_COMPOSER_CLEAR=1
    return 0
  fi
  _duet_codex_marker_owned "$marker_now" "$marker_token" \
    || return "$DUET_SEND_LANDED_UNVERIFIED"
  _duet_tmux send-keys -t "$pane" C-u
  for i in $(seq 1 20); do
    sleep 0.1
    _duet_alive "$pane" || return "$DUET_SEND_DEAD"
    marker_now="$(_duet_paste_marker "$pane")"
    if [ -z "$marker_now" ]; then
      DUET_SEND_COMPOSER_CLEAR=1
      return 0
    fi
    _duet_codex_marker_owned "$marker_now" "$marker_token" \
      || return "$DUET_SEND_LANDED_UNVERIFIED"
  done
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
  local config_path
  local pid_live="" owner_live="" identity_valid=""
  [ -n "$dir" ] || return 0
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  session_id="$(basename "$dir")"
  config_path="$dir/duet.env"

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
  if duet_daemon_process_matches "$pid" "$config_path" "$session_id"; then
    kill -TERM "$pid" 2>/dev/null || true
  else
    echo "duet: daemon pid $pid does not identify session $dir; refusing to signal it." >&2
    return 1
  fi
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
        echo "duet: failed to reap spawned legacy pane $legacy_pane." >&2
        return 1
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
      echo "duet: failed to reap spawned pane $victim_pane." >&2
      failed=1
    fi
  done
  [ -z "$failed" ]
}

# Reap a previous session without ever killing the pane performing the re-init.
# args: duet_dir workdir tmux_socket exempt_pane [legacy_codex_pane]
#       [server_pid] [legacy_codex_pid]
duet_reap_session(){
  local dir="${1:-}" workdir="${2:-}" socket="${3:-}" exempt="${4:-}"
  local legacy_pane="${5:-}" expected_server_pid="${6:-}" actual_server_pid
  local legacy_pid="${7:-}"
  local saved_socket="${DUET_TMUX_SOCKET:-}"
  [ -n "$dir" ] || return 0
  if { [ -e "$dir/roster.tsv" ] || [ -L "$dir/roster.tsv" ]; } \
      && ! duet_validate_roster "$dir/roster.tsv"; then
    echo "duet: invalid previous-session roster; refusing reap before lifecycle mutation." >&2
    return 1
  fi

  if [ -d "$dir" ]; then
    duet_lock_acquire "$dir/.admission.lock" 200 || return 1
    if ! : > "$dir/.ended" 2>/dev/null; then
      duet_lock_release "$dir/.admission.lock" 2>/dev/null || true
      return 1
    fi
    duet_lock_release "$dir/.admission.lock" || return 1
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
  if ! duet_kill_spawned_panes "$dir/roster.tsv" "$exempt" "$legacy_pane" "$legacy_pid"; then
    DUET_TMUX_SOCKET="$saved_socket"
    return 1
  fi
  DUET_TMUX_SOCKET="$saved_socket"
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

# Read the atomically-published leadership state into DUET_CURRENT_TERM and
# DUET_CURRENT_LEADER. The file is data, never shell code.
duet_read_leader_state(){
  local file="${1:-${DUET_DIR:?}/leader}" state term leader
  DUET_CURRENT_TERM=""
  DUET_CURRENT_LEADER=""
  duet_regular_file_without_nul "$file" || {
    echo "duet: invalid leadership state in $file" >&2
    return 1
  }
  state="$(awk -F '\t' '
    {
      line=$0; sub(/\r$/, "", line)
      n=split(line, c, "\t")
      if (NR==1 && n==2 && c[1]=="term") term=c[2]
      else if (NR==2 && n==2 && c[1]=="leader") leader=c[2]
      else bad=1
    }
    END {
      if (!bad && NR==2 && term ~ /^[0-9]+$/ && leader ~ /^[A-Za-z0-9_-]+$/)
        print term "\t" leader
    }
  ' "$file" 2>/dev/null)"
  [ -n "$state" ] || { echo "duet: invalid leadership state in $file" >&2; return 1; }
  term="${state%%$'\t'*}"
  leader="${state#*$'\t'}"
  duet_decimal_d10 "$term" || {
    echo "duet: invalid leadership state in $file" >&2
    return 1
  }
  DUET_CURRENT_TERM="$DUET_DECIMAL_VALUE"
  DUET_CURRENT_LEADER="$leader"
}

duet_write_leader_state(){
  local term="${1:?term required}" leader="${2:?leader required}" tmp
  duet_decimal_d10 "$term" || return 1
  term="$DUET_DECIMAL_VALUE"
  case "$leader" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
  tmp="$(mktemp "${DUET_DIR:?}/.leader.XXXXXX")" || return 1
  if ! printf 'term\t%s\nleader\t%s\n' "$term" "$leader" > "$tmp" \
      || ! duet_publish_temp_file "$tmp" "$DUET_DIR/leader"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
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

# A complete binding published with INFLIGHT/ENTER_ONLY/CLEAR_RETRY means a verifier may
# already have placed bytes in a live TUI composer. Leadership must not advance
# while any such obligation exists: after the CAS it would be stale and could
# neither be submitted nor safely discarded, and promotion/fanout traffic
# could otherwise be pasted onto the same dirty composer.
duet_has_uncertain_delivery(){
  local box file phase bound_name bound_pane bound_term
  DUET_UNCERTAIN_FILE=""
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    for file in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$file" ] || continue
      phase="$(cat "$file.phase" 2>/dev/null || true)"
      case "$phase" in ENTER_ONLY|INFLIGHT|CLEAR_RETRY) : ;; *) continue ;; esac
      # CLEAR_RETRY is itself a durable assertion that a causally observed
      # marker may still own a pane.  Even damaged/missing binding sidecars
      # must fail closed and block a leadership CAS.
      if [ "$phase" = CLEAR_RETRY ]; then
        DUET_UNCERTAIN_FILE="$file"
        return 0
      fi
      bound_name="$(cat "$file.target_name" 2>/dev/null || true)"
      bound_pane="$(cat "$file.target_pane" 2>/dev/null || true)"
      bound_term="$(cat "$file.target_term" 2>/dev/null || true)"
      [ -n "$bound_name" ] && [ -n "$bound_pane" ] && [ -n "$bound_term" ] \
        || continue
      DUET_UNCERTAIN_FILE="$file"
      return 0
    done
  done
  return 1
}

# Complete one explicit operator handoff. The immutable handoff message is the
# crash journal: its MANUAL marker and prior/current tuple let the daemon finish
# this exact choice, but never choose a leader itself.
# Return codes: 0 complete, 1 state failure, 2 CAS lost, 3 invalid/dead target,
# 4 invalid durable intent, 11 blocked by an uncertain composer.
duet_promote_locked(){
  local expected_term="${1:?expected term required}" expected_leader="${2:?expected leader required}"
  local reason="${3:-MANUAL}" requested="${4:-}"
  local new_term body promotion_file safe_reason lock
  [ -z "${5:-}" ] || return 3
  [ -n "$requested" ] || return 3
  lock="${DUET_DIR:?}/.promotion.lock"
  duet_lock_acquire "$lock" 200 || return 1
  if ! duet_validate_roster "$DUET_DIR/roster.tsv"; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 1
  fi
  if ! duet_read_leader_state \
      || [ "$DUET_CURRENT_TERM" != "$expected_term" ] \
      || [ "$DUET_CURRENT_LEADER" != "$expected_leader" ]; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 2
  fi
  if ! duet_roster_has_name "$requested" \
      || [ "$requested" = "$expected_leader" ] \
      || ! duet_roster_member_alive "$requested"; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 3
  fi

  # The delivery lock serializes this check with composer binding publication.
  # Every possible owner must resolve under the old term. There is no bypass.
  if duet_has_uncertain_delivery; then
    DUET_PROMOTION_BLOCKER="$DUET_UNCERTAIN_FILE"
    duet_lock_release "$lock" 2>/dev/null || true
    return 11
  fi

  if ! duet_decimal_d10 "$expected_term" || [ "$DUET_DECIMAL_VALUE" = 9999999999 ]; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 1
  fi
  expected_term="$DUET_DECIMAL_VALUE"
  new_term=$((10#$expected_term + 1))
  safe_reason="$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
  body="Leadership handoff for session ${DUET_SESSION_ID:?}: you are leader for generation $new_term. Prior leader: $expected_leader. Operator record: $safe_reason. Read assignments.md, preserve disjoint scopes, and notify or reassign workers as needed."
  if ! DUET_INTERNAL_ENQUEUE=1 DUET_HANDOFF_MODE=MANUAL \
      DUET_HANDOFF_PRIOR_TERM="$expected_term" DUET_HANDOFF_PRIOR_LEADER="$expected_leader" \
      duet_enqueue_message promotions duet-system "$requested" "$new_term" \
      NORMAL SYSTEM "$requested" "$body" "promotion-$new_term"; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 1
  fi
  promotion_file="$DUET_ENQUEUED_FILE"
  if [ "$(dirname "$promotion_file")" != "$DUET_DIR/inbox/promotions" ] \
      || ! duet_read_message "$promotion_file" \
      || [ "$DUET_MESSAGE_SESSION" != "${DUET_SESSION_ID:?}" ] \
      || [ "$DUET_MESSAGE_TERM" != "$new_term" ] \
      || [ "$DUET_MESSAGE_RECIPIENT" != "$requested" ] \
      || [ "$DUET_MESSAGE_ORIGIN" != SYSTEM ] \
      || [ "$DUET_MESSAGE_DEDUPE" != "promotion-$new_term" ] \
      || [ "$DUET_MESSAGE_HANDOFF_MODE" != MANUAL ] \
      || [ "$DUET_MESSAGE_PRIOR_TERM" != "$expected_term" ] \
      || [ "$DUET_MESSAGE_PRIOR_LEADER" != "$expected_leader" ]; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 4
  fi
  if ! duet_atomic_write "$promotion_file.promotion_term" "$new_term" \
      || ! duet_write_leader_state "$new_term" "$requested"; then
    duet_lock_release "$lock" 2>/dev/null || true
    return 1
  fi
  DUET_PROMOTION_FILE="$promotion_file"
  DUET_PROMOTED_LEADER="$requested"
  DUET_PROMOTED_TERM="$new_term"
  duet_lock_release "$lock" || return 1
}

# Resolve an optional harness alias (for example `codex` -> `codex-1`) only
# when exactly one roster entry uses that harness.
duet_resolve_roster_name(){
  local token="${1:-}" exact matches
  duet_validate_roster "${DUET_DIR:?}/roster.tsv" || return 1
  if duet_roster_has_name "$token"; then printf '%s' "$token"; return 0; fi
  matches="$(awk -F '\t' -v harness="$token" 'NR > 1 && $2 == harness { print $1 }' \
    "${DUET_DIR:?}/roster.tsv" 2>/dev/null)"
  [ "$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')" -eq 1 ] || return 1
  printf '%s' "$matches"
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
  local held held_pid stale target target_name claim i
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
            if [ ! -e "$stale" ] && [ ! -L "$stale" ] \
                && mv "$lock" "$stale" 2>/dev/null; then
              if [ -L "$stale" ]; then
                target="$(readlink "$stale" 2>/dev/null || true)"
                rm -f "$stale" 2>/dev/null || true
                target_name="$(basename "$lock")"
                # A pre-0.2 lock could be a symlink to its private sibling
                # claim. Treat the link text as hostile: only an unqualified
                # generated sibling name may be cleaned up. Never follow an
                # absolute target or a relative path containing '/'.
                case "$target" in
                  */*) : ;;
                  "$target_name".claim-*)
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
  if ! printf '%s\n' "$next" > "$tmp" \
      || ! duet_publish_temp_file "$tmp" "$box/.counter"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Admission locking serializes every queue, so this counter gives messages in
# different inbox roots one durable total order for pane-coalesced scheduling.
duet_next_message_order(){
  local file="${DUET_DIR:?}/.message-order" current next
  if [ -f "$file" ]; then
    current="$(cat "$file" 2>/dev/null || true)"
    if ! duet_decimal_d10 "$current"; then
      echo "duet: corrupt global message order in $file" >&2
      return 1
    fi
    current="$DUET_DECIMAL_VALUE"
  else
    current=0
  fi
  if [ "$current" = 9999999999 ]; then
    echo "duet: message-order exhausted (D10 cap)" >&2
    return 1
  fi
  next=$((current + 1))
  duet_atomic_write "$file" "$next" || return 1
  printf -v DUET_MESSAGE_ORDER_ALLOC '%010d' "$next"
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
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    duet_read_message "$file" || continue
    [ "$DUET_MESSAGE_SESSION" = "${DUET_SESSION_ID:?}" ] || continue
    value="$DUET_MESSAGE_DEDUPE"
    [ "$value" = "$key" ] || continue
    DUET_DEDUPE_FILE="$file"
    DUET_DEDUPE_ID="$DUET_MESSAGE_ID"
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
  local handoff_mode="${DUET_HANDOFF_MODE:-}"
  local handoff_prior_term="${DUET_HANDOFF_PRIOR_TERM:-}"
  local handoff_prior_leader="${DUET_HANDOFF_PRIOR_LEADER:-}"
  local handoff_expected_term
  local enqueue_lock_attempts="${DUET_ENQUEUE_LOCK_ATTEMPTS:-1200}"
  case "$queue" in ''|*[!A-Za-z0-9_-]*) echo "duet: invalid queue '$queue'" >&2; return 1;; esac
  case "$mode" in NORMAL) prefix=N;; INTERRUPT) prefix=I;; *) echo "duet: invalid mode '$mode'" >&2; return 1;; esac
  case "$origin" in LEADER|WORKER|SYSTEM) :;; *) echo "duet: invalid origin role '$origin'" >&2; return 1;; esac
  if ! duet_decimal_d10 "$term"; then
    echo "duet: invalid term '$term'" >&2
    return 1
  fi
  term="$DUET_DECIMAL_VALUE"
  case "${DUET_SESSION_ID:-}${sender}${recipient}${leader_at_send}" in
    ''|*[!A-Za-z0-9_-]*) echo "duet: invalid message metadata" >&2; return 1;;
  esac
  case "$dedupe" in *$'\t'*|*$'\r'*|*$'\n'*) echo "duet: invalid dedupe key" >&2; return 1;; esac
  if [ -n "$handoff_mode" ] || [ -n "$handoff_prior_term" ] \
      || [ -n "$handoff_prior_leader" ]; then
    if [ "$handoff_mode" != MANUAL ] || [ "$queue" != promotions ] \
        || [ "$sender" != duet-system ] || [ "$origin" != SYSTEM ] \
        || [ "$leader_at_send" != "$recipient" ] \
        || [ "$dedupe" != "promotion-$term" ]; then
      echo "duet: invalid manual handoff envelope" >&2
      return 1
    fi
    if ! duet_decimal_d10 "$handoff_prior_term"; then
      echo "duet: invalid prior handoff term" >&2
      return 1
    fi
    handoff_prior_term="$DUET_DECIMAL_VALUE"
    case "$handoff_prior_leader" in ''|*[!A-Za-z0-9_-]*) echo "duet: invalid prior leader" >&2; return 1;; esac
    [ "$handoff_prior_leader" != "$recipient" ] \
      || { echo "duet: handoff target already leads" >&2; return 1; }
    [ "$handoff_prior_term" != 9999999999 ] \
      || { echo "duet: prior handoff term exhausted the D10 space" >&2; return 1; }
    handoff_expected_term=$((10#$handoff_prior_term + 1))
    [ "$term" = "$handoff_expected_term" ] \
      || { echo "duet: handoff term is not the next generation" >&2; return 1; }
  fi
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
  if ! duet_next_message_order || ! duet_next_sequence "$box"; then
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
    printf 'session\t%s\n' "${DUET_SESSION_ID:?}"
    printf 'order\t%s\n' "$DUET_MESSAGE_ORDER_ALLOC"
    printf 'mode\t%s\n' "$mode"
    printf 'sender\t%s\n' "$sender"
    printf 'recipient\t%s\n' "$recipient"
    printf 'term\t%s\n' "$term"
    printf 'origin\t%s\n' "$origin"
    printf 'leader_at_send\t%s\n' "$leader_at_send"
    printf 'dedupe\t%s\n' "$dedupe"
    if [ -n "$handoff_mode" ]; then
      printf 'handoff_mode\t%s\n' "$handoff_mode"
      printf 'prior_term\t%s\n' "$handoff_prior_term"
      printf 'prior_leader\t%s\n' "$handoff_prior_leader"
    fi
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

_duet_message_structure_valid(){
  # Bash 3.2 has no associative arrays, so use POSIX awk for the wire-schema
  # pass.  LC_ALL=C makes [:cntrl:] exactly the ASCII C0/DEL set that the
  # PowerShell parser rejects.  Strip one terminal CR per line only as CRLF
  # framing; a second CR remains metadata and is rejected.
  duet_regular_file_without_nul "$1" || return 1
  LC_ALL=C awk '
    BEGIN {
      known["id"]; known["session"]; known["order"]; known["mode"]
      known["sender"]; known["recipient"]; known["term"]; known["origin"]
      known["leader_at_send"]; known["dedupe"]; known["handoff_mode"]
      known["prior_term"]; known["prior_leader"]; known["body64"]
      required["id"]; required["session"]; required["order"]; required["mode"]
      required["sender"]; required["recipient"]; required["term"]
      required["origin"]; required["leader_at_send"]; required["dedupe"]
      required["body64"]
      cr = sprintf("%c", 13)
    }
    {
      line = $0
      if (substr(line, length(line), 1) == cr) {
        line = substr(line, 1, length(line) - 1)
      }
      if (NR == 1) {
        if (line != "DUETv1") bad = 1
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

_duet_message_decimal_valid(){ duet_decimal_d10 "$@"; }

duet_read_message(){
  local file="${1:?message file required}" encoded decoded handoff_expected_term
  local handoff_field_count decoded_file decode_rc LC_ALL=C

  DUET_MESSAGE_ID=""
  DUET_MESSAGE_SESSION=""
  DUET_MESSAGE_ORDER=""
  DUET_MESSAGE_MODE=""
  DUET_MESSAGE_SENDER=""
  DUET_MESSAGE_RECIPIENT=""
  DUET_MESSAGE_TERM=""
  DUET_MESSAGE_ORIGIN=""
  DUET_MESSAGE_LEADER_AT_SEND=""
  DUET_MESSAGE_DEDUPE=""
  DUET_MESSAGE_HANDOFF_MODE=""
  DUET_MESSAGE_PRIOR_TERM=""
  DUET_MESSAGE_PRIOR_LEADER=""
  DUET_MESSAGE_BODY=""

  _duet_message_structure_valid "$file" || return 1
  DUET_MESSAGE_ID="$(_duet_message_field "$file" id)" || return 1
  DUET_MESSAGE_SESSION="$(_duet_message_field "$file" session)" || return 1
  DUET_MESSAGE_ORDER="$(_duet_message_field "$file" order)" || return 1
  DUET_MESSAGE_MODE="$(_duet_message_field "$file" mode)" || return 1
  DUET_MESSAGE_SENDER="$(_duet_message_field "$file" sender)" || return 1
  DUET_MESSAGE_RECIPIENT="$(_duet_message_field "$file" recipient)" || return 1
  DUET_MESSAGE_TERM="$(_duet_message_field "$file" term)" || return 1
  DUET_MESSAGE_ORIGIN="$(_duet_message_field "$file" origin)" || return 1
  DUET_MESSAGE_LEADER_AT_SEND="$(_duet_message_field "$file" leader_at_send)" || return 1
  DUET_MESSAGE_DEDUPE="$(_duet_message_field "$file" dedupe)" || return 1
  DUET_MESSAGE_HANDOFF_MODE="$(_duet_message_field "$file" handoff_mode)" || return 1
  DUET_MESSAGE_PRIOR_TERM="$(_duet_message_field "$file" prior_term)" || return 1
  DUET_MESSAGE_PRIOR_LEADER="$(_duet_message_field "$file" prior_leader)" || return 1
  encoded="$(_duet_message_field "$file" body64)" || return 1
  handoff_field_count="$(LC_ALL=C awk '
    BEGIN { cr = sprintf("%c", 13) }
    {
      line = $0
      if (substr(line, length(line), 1) == cr) {
        line = substr(line, 1, length(line) - 1)
      }
      tab = index(line, "\t")
      key = tab ? substr(line, 1, tab - 1) : line
      if (key == "handoff_mode" || key == "prior_term" || key == "prior_leader") n++
    }
    END { print n + 0 }
  ' "$file")" || return 1
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
  case "$DUET_MESSAGE_ID$DUET_MESSAGE_SESSION$DUET_MESSAGE_SENDER$DUET_MESSAGE_RECIPIENT$DUET_MESSAGE_LEADER_AT_SEND" in
    *[!A-Za-z0-9_-]*) return 1;;
  esac
  [ -n "$DUET_MESSAGE_ID" ] && [ -n "$DUET_MESSAGE_SESSION" ] \
    && [ -n "$DUET_MESSAGE_SENDER" ] && [ -n "$DUET_MESSAGE_RECIPIENT" ] \
    && [ -n "$DUET_MESSAGE_LEADER_AT_SEND" ] || return 1
  _duet_message_decimal_valid "$DUET_MESSAGE_ORDER" 1 || return 1
  case "$DUET_MESSAGE_MODE" in NORMAL|INTERRUPT) :;; *) return 1;; esac
  case "$DUET_MESSAGE_ORIGIN" in LEADER|WORKER|SYSTEM) :;; *) return 1;; esac
  _duet_message_decimal_valid "$DUET_MESSAGE_TERM" || return 1
  if [ "$handoff_field_count" -ne 0 ]; then
    [ "$handoff_field_count" -eq 3 ] \
      && [ "$DUET_MESSAGE_HANDOFF_MODE" = MANUAL ] \
      && [ "$DUET_MESSAGE_SENDER" = duet-system ] \
      && [ "$DUET_MESSAGE_ORIGIN" = SYSTEM ] \
      && [ "$DUET_MESSAGE_LEADER_AT_SEND" = "$DUET_MESSAGE_RECIPIENT" ] \
      && [ "$DUET_MESSAGE_DEDUPE" = "promotion-$DUET_MESSAGE_TERM" ] \
      || return 1
    _duet_message_decimal_valid "$DUET_MESSAGE_PRIOR_TERM" || return 1
    case "$DUET_MESSAGE_PRIOR_LEADER" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
    [ "$DUET_MESSAGE_PRIOR_LEADER" != "$DUET_MESSAGE_RECIPIENT" ] || return 1
    [ "$DUET_MESSAGE_PRIOR_TERM" != 9999999999 ] || return 1
    handoff_expected_term=$((10#$DUET_MESSAGE_PRIOR_TERM + 1))
    [ "$DUET_MESSAGE_TERM" = "$handoff_expected_term" ] || return 1
  fi
}

duet_build_payload(){
  printf '[DUET session=%s id=%s term=%s from=%s]\n%s\n[DUET session=%s id=%s end]' \
    "$DUET_MESSAGE_SESSION" "$DUET_MESSAGE_ID" "$DUET_MESSAGE_TERM" \
    "$DUET_MESSAGE_SENDER" "$DUET_MESSAGE_BODY" \
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

# Failed named-recipient messages retain a durable notice obligation until the
# daemon has queued the corresponding leader notification and marked it.
duet_notice_obligation_count(){
  local box file root count=0 reason
  for box in "${DUET_DIR:?}"/inbox/*; do
    [ -d "$box" ] || continue
    if [ "$(basename "$box")" != leader ] \
        && [ "$(basename "$box")" != promotions ]; then
      for file in "$box"/failed/*.msg; do
        [ -f "$file" ] || continue
        [ -f "$file.noticed" ] && continue
        count=$((count + 1))
      done
    fi
    for file in "$box"/quarantine/*.msg; do
      [ -f "$file" ] || continue
      [ -f "$file.noticed" ] && continue
      reason="$(cat "$file.reason" 2>/dev/null || true)"
      case "$reason" in
        foreign-session|missing-session|foreign-message-id) count=$((count + 1)) ;;
      esac
    done
    # A daemon may die after moving the immutable root but before moving or
    # finalizing its transition metadata. Keep end's drain barrier closed until
    # a restarted daemon reconciles these orphan sidecars.
    for file in "$box"/N-*.msg.quarantine_reason \
        "$box"/I-*.msg.quarantine_reason \
        "$box"/N-*.msg.promotion_term "$box"/I-*.msg.promotion_term; do
      [ -f "$file" ] || continue
      root="${file%.*}"
      [ -f "$root" ] && continue
      count=$((count + 1))
    done
    for file in "$box"/delivered/*.msg.quarantine_reason \
        "$box"/failed/*.msg.quarantine_reason \
        "$box"/quarantine/*.msg.quarantine_reason \
        "$box"/superseded/*.msg.quarantine_reason; do
      [ -f "$file" ] || continue
      count=$((count + 1))
    done
  done
  box="${DUET_DIR:?}/inbox/promotions"
  if [ -d "$box" ]; then
    for file in "$box"/delivered/*.msg "$box"/quarantine/*.msg; do
      [ -f "$file" ] || continue
      [ -f "$file.promotion_term" ] || continue
      [ -f "$file.fanout_done" ] && continue
      count=$((count + 1))
    done
  fi
  printf '%s' "$count"
}
