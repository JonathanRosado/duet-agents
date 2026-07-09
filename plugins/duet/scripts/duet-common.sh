#!/usr/bin/env bash
# Shared duet helpers for the tmux/bash path. Sourced by duet-send.sh,
# duet-relay.sh, duet-init.sh, duet-end.sh, duet-doctor.sh. Mirrors the tested
# duet-common.ps1: a paste is confirmed to have LANDED in the composer, then Enter
# is sent and confirmed to have SUBMITTED (composer cleared), retrying Enter. This
# is the fix for the Enter-races-bracketed-paste silent drop (issues #1 and #2).
#
# NOTE: the .ps1 path is the one exercised/tested on Windows here; this .sh mirror
# is provided for macOS/Linux parity and has NOT been run against a live tmux TUI.

# Strip ALL whitespace so terminal soft-wrap row breaks don't defeat substring match.
_duet_strip(){ printf '%s' "${1:-}" | tr -d '[:space:]'; }

# A distinctive tail of the payload (<=48 non-ws chars) - what sits at the composer
# cursor right after a paste.
_duet_probe(){
  local s n
  s="$(_duet_strip "${1:-}")"; n=${#s}
  if [ "$n" -gt 48 ]; then printf '%s' "${s: -48}"; else printf '%s' "$s"; fi
}

# Is <probe> a substring of <stripped-haystack>?  args: haystack_stripped probe
_duet_present(){ [ -n "${2:-}" ] || return 1; case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

# Last N lines of a pane, whitespace-stripped.
_duet_tail_strip(){ tmux capture-pane -p -t "$1" 2>/dev/null | tail -n "${2:-6}" | tr -d '[:space:]'; }

# Is this pane id currently present on the server?
_duet_alive(){ tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"; }

# duet_send_verified <pane> <payload> <interrupt-flag>
# Returns 0 ONLY when submission is verified (never a false positive). Prints
# diagnostics to stderr; the caller owns the user-facing success/failure line.
duet_send_verified(){
  local pane="$1" payload="$2" interrupt="${3:-}"
  _duet_alive "$pane" || { echo "duet: target pane $pane is gone; not sending." >&2; return 1; }

  # Interrupt only aborts a BUSY peer; escaping an idle composer can swallow the paste.
  if [ -n "$interrupt" ]; then
    if tmux capture-pane -p -t "$pane" 2>/dev/null | tail -n 4 \
         | grep -qiE 'esc to interrupt|esc to cancel|ctrl\+c to|working|thinking|generating|running'; then
      tmux send-keys -t "$pane" Escape; sleep 0.4
    fi
  fi

  local probe buf landed="" a i
  probe="$(_duet_probe "$payload")"
  buf="duet-$$-${RANDOM:-0}"

  # Paste, then poll until it shows in the composer. Retry the paste once.
  for a in 1 2; do
    printf '%s' "$payload" | tmux load-buffer -b "$buf" -
    tmux paste-buffer -d -b "$buf" -p -t "$pane"
    if [ -z "$probe" ]; then landed=1; break; fi
    for i in $(seq 1 15); do
      sleep 0.1
      if _duet_present "$(_duet_tail_strip "$pane" 10)" "$probe"; then landed=1; break; fi
    done
    [ -n "$landed" ] && break
  done

  if [ -z "$landed" ]; then
    tmux send-keys -t "$pane" Enter
    echo "duet: could not confirm paste landed in pane $pane" >&2
    return 1
  fi

  # Submit: Enter, poll for the composer to clear, retry Enter (a later Enter
  # submits when the first raced the paste).
  local e
  for e in 1 2 3; do
    tmux send-keys -t "$pane" Enter
    for i in $(seq 1 12); do
      sleep 0.2
      if ! _duet_present "$(_duet_tail_strip "$pane" 4)" "$probe"; then
        return 0
      fi
    done
  done
  echo "duet: pasted into pane $pane but could not confirm submission." >&2
  return 1
}

# Reap a previous session (issue #3): signal its relay to stop and kill its Codex
# pane, so exactly one Codex exists per role. args: prev_duet_dir prev_codex_pane
duet_reap_prev(){
  local dir="${1:-}" codex="${2:-}"
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] && : > "$dir/.ended" 2>/dev/null || true
  if [ -n "$codex" ] && _duet_alive "$codex"; then
    tmux send-keys -t "$codex" C-c 2>/dev/null || true
    sleep 0.3
    tmux kill-pane -t "$codex" 2>/dev/null || true
  fi
}
