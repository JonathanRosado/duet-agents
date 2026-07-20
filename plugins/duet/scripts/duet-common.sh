#!/usr/bin/env bash
# Shared helpers for the tmux/bash ensemble path.

# duet_send_verified result codes. Success is the normal shell status 0.
DUET_SEND_DEAD=20
DUET_SEND_NOT_LANDED=21
DUET_SEND_LANDED_UNVERIFIED=22

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

_duet_alive(){
  [ -n "${1:-}" ] || return 1
  _duet_tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"
}

# duet_send_verified <pane> <payload> <interrupt-flag>
#
# A successful return means the payload was observed in the composer and then
# observed leaving it after Enter. Non-zero outcomes are deliberately distinct:
#   DUET_SEND_DEAD                pane disappeared
#   DUET_SEND_NOT_LANDED          paste was not observed; caller may repaste
#   DUET_SEND_LANDED_UNVERIFIED   paste landed, but submission is uncertain;
#                                 caller must never paste the payload again
duet_send_verified(){
  local pane="${1:-}" payload="${2:-}" interrupt="${3:-}"
  local probe buffer i e

  if ! _duet_alive "$pane"; then
    echo "duet: target pane $pane is gone; not sending." >&2
    return "$DUET_SEND_DEAD"
  fi

  # Escape only a recognizably busy TUI. On an idle composer Escape can clear
  # input or close a modal and make the following paste disappear.
  if [ -n "$interrupt" ]; then
    if _duet_tmux capture-pane -p -t "$pane" 2>/dev/null \
         | tail -n 6 \
         | grep -qiE 'esc to interrupt|esc to cancel|ctrl\+c to|working|thinking|generating|running|streaming'; then
      _duet_tmux send-keys -t "$pane" Escape
      sleep 0.4
    fi
  fi

  probe="$(_duet_probe "$payload")"
  [ -n "$probe" ] || {
    echo "duet: refusing to send an empty/unprobeable payload to $pane" >&2
    return "$DUET_SEND_NOT_LANDED"
  }

  buffer="duet-${BASHPID:-$$}-${RANDOM:-0}"
  if ! printf '%s' "$payload" | _duet_tmux load-buffer -b "$buffer" -; then
    echo "duet: could not load paste buffer for pane $pane" >&2
    return "$DUET_SEND_NOT_LANDED"
  fi
  if ! _duet_tmux paste-buffer -d -b "$buffer" -p -t "$pane"; then
    _duet_tmux delete-buffer -b "$buffer" 2>/dev/null || true
    if _duet_alive "$pane"; then
      echo "duet: paste command failed for pane $pane" >&2
      return "$DUET_SEND_NOT_LANDED"
    fi
    return "$DUET_SEND_DEAD"
  fi

  for i in $(seq 1 20); do
    sleep 0.1
    if _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
      break
    fi
  done
  if [ "$i" -eq 20 ] && ! _duet_present "$(_duet_tail_strip "$pane" 12)" "$probe"; then
    if _duet_alive "$pane"; then
      echo "duet: could not confirm paste landed in pane $pane" >&2
      return "$DUET_SEND_NOT_LANDED"
    fi
    return "$DUET_SEND_DEAD"
  fi

  # Once landing has been observed, only retry Enter. Re-pasting here could
  # duplicate an already accepted task.
  for e in 1 2 3; do
    _duet_tmux send-keys -t "$pane" Enter
    for i in $(seq 1 12); do
      sleep 0.2
      if ! _duet_alive "$pane"; then
        return "$DUET_SEND_DEAD"
      fi
      if ! _duet_present "$(_duet_tail_strip "$pane" 4)" "$probe"; then
        return 0
      fi
    done
  done

  echo "duet: payload landed in pane $pane but submission is unverified." >&2
  return "$DUET_SEND_LANDED_UNVERIFIED"
}

# Remove only the delimited block owned by duet. Existing surrounding content
# and even an otherwise-empty user-created anchor file are preserved.
duet_strip_anchor_file(){
  [ -f "${1:-}" ] || return 0
  perl -0777 -pi -e 's/\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\n?//sg' "$1" 2>/dev/null || true
}

duet_strip_session_anchors(){
  local workdir="${1:-}"
  [ -n "$workdir" ] || return 0
  duet_strip_anchor_file "$workdir/AGENTS.md"
  duet_strip_anchor_file "$workdir/CLAUDE.md"
}

# Kill only panes explicitly marked as spawned. The caller pane is fenced even
# if a malformed roster marks it spawned.
duet_kill_spawned_panes(){
  local roster="${1:-}" exempt="${2:-}" legacy_pane="${3:-}"
  local name harness pane pane_pid rank spawned
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

  while IFS=$'\t' read -r name harness pane pane_pid rank spawned; do
    [ "$name" = name ] && continue
    [ "$spawned" = 1 ] || continue
    [ -n "$pane" ] || continue
    [ "$pane" = "$exempt" ] && continue
    _duet_alive "$pane" || continue
    _duet_tmux send-keys -t "$pane" C-c 2>/dev/null || true
    victims="${victims}${victims:+ }$pane"
  done < "$roster"

  [ -n "$victims" ] || return 0
  sleep 0.3
  for victim in $victims; do
    [ "$victim" = "$exempt" ] && continue
    _duet_alive "$victim" && _duet_tmux kill-pane -t "$victim" 2>/dev/null || true
  done
}

# Reap a previous session without ever killing the pane performing the re-init.
# args: duet_dir workdir tmux_socket exempt_pane [legacy_codex_pane]
duet_reap_session(){
  local dir="${1:-}" workdir="${2:-}" socket="${3:-}" exempt="${4:-}"
  local legacy_pane="${5:-}"
  local saved_socket="${DUET_TMUX_SOCKET:-}"
  [ -n "$dir" ] || return 0

  [ -d "$dir" ] && : > "$dir/.ended" 2>/dev/null || true
  duet_strip_session_anchors "$workdir"

  DUET_TMUX_SOCKET="$socket"
  duet_kill_spawned_panes "$dir/roster.tsv" "$exempt" "$legacy_pane"
  DUET_TMUX_SOCKET="$saved_socket"
}
