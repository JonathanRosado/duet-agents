#!/usr/bin/env bash
# duet-init.sh — from inside a tmux pane running Claude, bring up the Codex peer:
# anchor the protocol in durable files, split the window, launch Codex (which reads
# its AGENTS.md brief at boot), and start the relay.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/duet-common.sh"
[ -n "${TMUX:-}" ]        || { echo "duet: not inside tmux. Start Claude with:  tmux new-session claude" >&2; exit 3; }
command -v codex >/dev/null || { echo "duet: 'codex' CLI not found on PATH" >&2; exit 4; }

CLAUDE_PANE="${TMUX_PANE:?duet: no TMUX_PANE}"
CODEX="$(command -v codex)"

# Reap any prior session's Codex before spawning a new one, so exactly one Codex
# exists per role and messages can't route to an orphaned, context-less agent
# (issue #3). Read the OLD current pointer before we repoint it below.
PREV_ENV="$HOME/.duet/current/duet.env"
if [ -f "$PREV_ENV" ]; then
  # shellcheck disable=SC1090
  ( . "$PREV_ENV"; duet_reap_prev "${DUET_DIR:-}" "${CODEX_PANE:-}" ) || true
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
DUET_DIR="$HOME/.duet/$STAMP"
mkdir -p "$DUET_DIR/to-claude/delivered"
ln -sfn "$DUET_DIR" "$HOME/.duet/current"
: > "$DUET_DIR/transcript.md"

# --- durable protocol anchors (survive /clear + compaction) ------------------
# Codex reads AGENTS.md at boot; Claude reads CLAUDE.md. Append a delimited block
# (create the file if absent); duet-end strips it. Never clobber existing content.
render(){ sed -e "s|@DUET_DIR@|$DUET_DIR|g" -e "s|@PLUGIN@|$PLUGIN_DIR|g" "$1"; }
append_block(){ # <file> <brief-src>
  touch "$1"
  grep -qF 'DUET:BEGIN' "$1" 2>/dev/null && return 0
  { echo; echo '<!-- DUET:BEGIN (added by duet-init; removed by duet-end) -->'; render "$2"; echo '<!-- DUET:END -->'; } >> "$1"
}
append_block "$PWD/AGENTS.md" "$PLUGIN_DIR/codex/AGENTS_BRIEF.md"
append_block "$PWD/CLAUDE.md" "$PLUGIN_DIR/claude/CLAUDE_BRIEF.md"

# --- trust the working dir for Codex (else it blocks on the boot trust dialog) --
CODEX_CFG="$HOME/.codex/config.toml"
grep -qF "[projects.\"$PWD\"]" "$CODEX_CFG" 2>/dev/null || {
  mkdir -p "$HOME/.codex"; printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$PWD" >> "$CODEX_CFG"
  echo "duet: marked $PWD trusted for codex"; }

# --- launch Codex bare in a right split; it reads AGENTS.md at boot -------------
# Codex runs as a full peer by default: full filesystem + network, no approval prompts.
# Override with DUET_CODEX_SANDBOX (read-only|workspace-write|danger-full-access) and
# DUET_CODEX_APPROVAL (untrusted|on-request|never). NOTE: any sandbox tighter than
# danger-full-access blocks Codex from the tmux socket, so also set DUET_RELAY=1 then.
CX_SANDBOX="${DUET_CODEX_SANDBOX:-danger-full-access}"
CX_APPROVAL="${DUET_CODEX_APPROVAL:-never}"
CODEX_PANE="$(tmux split-window -h -t "$CLAUDE_PANE" -P -F '#{pane_id}' \
  "cd $(printf %q "$PWD") && exec $(printf %q "$CODEX") --add-dir $(printf %q "$DUET_DIR") -s $(printf %q "$CX_SANDBOX") -a $(printf %q "$CX_APPROVAL")")"
tmux select-pane -t "$CLAUDE_PANE"

# Record pane pids for diagnostics (duet-status / duet-doctor). Not used to gate
# sends - tmux reports the transient foreground pid.
CLAUDE_PANE_PID="$(tmux display-message -p -t "$CLAUDE_PANE" '#{pane_pid}' 2>/dev/null || echo)"
CODEX_PANE_PID="$(tmux display-message -p -t "$CODEX_PANE" '#{pane_pid}' 2>/dev/null || echo)"

cat > "$DUET_DIR/duet.env" <<EOF
DUET_DIR=$DUET_DIR
CLAUDE_PANE=$CLAUDE_PANE
CODEX_PANE=$CODEX_PANE
CLAUDE_PANE_PID=$CLAUDE_PANE_PID
CODEX_PANE_PID=$CODEX_PANE_PID
PLUGIN_DIR=$PLUGIN_DIR
WORKDIR=$PWD
DUET_RELAY=${DUET_RELAY:-}
EOF

# Start the relay ONLY in the optional sandboxed-Codex mode. The default is direct
# inline delivery both ways (Codex drives tmux itself), so no relay is needed.
if [ -n "${DUET_RELAY:-}" ]; then
  DUET_CONFIG="$DUET_DIR/duet.env" nohup bash "$PLUGIN_DIR/scripts/duet-relay.sh" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# --- wait for Codex to boot, then kick it to confirm readiness -----------------
for _ in $(seq 1 25); do tmux capture-pane -t "$CODEX_PANE" -p 2>/dev/null | grep -q 'OpenAI Codex' && break; sleep 1; done
sleep 5
kick="You are briefed via AGENTS.md in this directory. Confirm now by running this shell command: printf ok > $DUET_DIR/codex-ready - then wait for messages from Claude."
duet_send_verified "$CODEX_PANE" "$kick" "" || true
ready=no; for _ in $(seq 1 30); do [ -f "$DUET_DIR/codex-ready" ] && { ready=yes; break; }; sleep 1; done

if [ "$ready" = yes ]; then
cat <<EOF
duet: up and Codex is READY.  claude=$CLAUDE_PANE  codex=$CODEX_PANE   dir=$DUET_DIR
Send Codex the first message now, then END YOUR TURN and wait for its reply:
    bash "$PLUGIN_DIR/scripts/duet-send.sh" codex <<'MSG'
    <your message to Codex>
    MSG
Codex's replies arrive IN THIS PANE as prompts prefixed "[DUET from codex]".
Barge in while Codex is working with --interrupt.
EOF
else
cat <<EOF
duet: session up but Codex did not confirm readiness in time. Check its pane
(right split). You can still try sending; if it stalls, run duet-status.sh or
duet-doctor.sh.
  claude=$CLAUDE_PANE  codex=$CODEX_PANE   dir=$DUET_DIR
EOF
fi