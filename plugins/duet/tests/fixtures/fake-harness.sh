#!/usr/bin/env bash
# Tiny interactive TUI used only by isolated lifecycle smokes.
set -u

harness="$(basename "$0")"
if [ "$harness" = kimi ] && [ "${1:-}" = doctor ]; then
  exit 0
fi
if [ "$harness" = codex ] && [ "${1:-}" = features ] \
    && [ "${2:-}" = list ]; then
  if [ "${DUET_FAKE_CODEX_HOOK_STATE:-true}" != absent ]; then
    printf 'hooks                                stable             %s\n' \
      "${DUET_FAKE_CODEX_HOOK_STATE:-true}"
  fi
  exit 0
fi

case "$harness" in
  claude) banner='Claude Code' ;;
  codex) banner='OpenAI Codex' ;;
  kimi) banner='Welcome to Kimi Code!' ;;
  *) banner='Duet fake harness' ;;
esac

name="${DUET_SELF:-$harness}"
accept_root="${DUET_FAKE_ACCEPT_ROOT:-}"
if [ -n "$accept_root" ]; then
  mkdir -p "$accept_root"
  accept_log="$accept_root/$name.log"
else
  accept_log=""
fi

# Record the invocation for rejoin/resume assertions.
[ -z "${DUET_FAKE_ARGV_LOG:-}" ] \
  || printf '%s\t%s\n' "$name" "$*" >> "$DUET_FAKE_ARGV_LOG"

fake_uuid(){
  local h
  h="$(LC_ALL=C od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# Simulate the harness's on-disk native session store, so pairing capture and
# rejoin validation can run without a real CLI. Each store is written only
# when its DUET_FAKE_* override is set; resume invocations reuse the given id.
workdir="$(pwd -P)"
native_id_for_hook=""
native_source=startup
case "$harness" in
  claude)
    if [ -n "${DUET_FAKE_CLAUDE_PROJECTS:-}" ]; then
      claude_id=""
      prev=""
      for arg in "$@"; do
        case "$prev" in --session-id|--resume) claude_id="$arg";; esac
        prev="$arg"
      done
      [ -n "$claude_id" ] || claude_id="${CLAUDE_CODE_SESSION_ID:-}"
      [ -n "$claude_id" ] || claude_id="$(fake_uuid)"
      for arg in "$@"; do
        [ "$arg" != --resume ] || native_source=resume
      done
      slug="$(printf '%s' "$workdir" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
      mkdir -p "$DUET_FAKE_CLAUDE_PROJECTS/$slug"
      : > "$DUET_FAKE_CLAUDE_PROJECTS/$slug/$claude_id.jsonl"
      native_id_for_hook="$claude_id"
    fi
    ;;
  codex)
    if [ -n "${DUET_FAKE_CODEX_SESSIONS:-}" ]; then
      codex_id=""
      previous=""
      for arg in "$@"; do
        if [ "$previous" = resume ]; then
          codex_id="$arg"
          native_source=resume
          break
        fi
        previous="$arg"
      done
      if [ -z "$codex_id" ]; then
        codex_id="${CODEX_THREAD_ID:-}"
        [ -n "$codex_id" ] || codex_id="$(fake_uuid)"
        ts="$(date -u '+%Y-%m-%dT%H-%M-%S')"
        mkdir -p "$DUET_FAKE_CODEX_SESSIONS"
        printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' \
          "$codex_id" "$workdir" \
          > "$DUET_FAKE_CODEX_SESSIONS/rollout-$ts-$codex_id.jsonl"
      fi
      native_id_for_hook="$codex_id"
    fi
    ;;
  kimi)
    if [ -n "${DUET_FAKE_KIMI_INDEX:-}" ]; then
      kimi_id=""
      prev=""
      for arg in "$@"; do
        case "$prev" in
          --session|-S) kimi_id="$arg"; native_source=resume ;;
        esac
        prev="$arg"
      done
      if [ -z "$kimi_id" ]; then
        kimi_id="${KIMI_SESSION_ID:-}"
        [ -n "$kimi_id" ] || kimi_id="session_$(fake_uuid)"
        mkdir -p "${DUET_FAKE_KIMI_SESSIONS:-$workdir}/wd_fake/$kimi_id"
        printf '{"sessionId":"%s","sessionDir":"%s/wd_fake/%s","workDir":"%s"}\n' \
          "$kimi_id" "${DUET_FAKE_KIMI_SESSIONS:-$workdir}" "$kimi_id" "$workdir" \
          >> "$DUET_FAKE_KIMI_INDEX"
      fi
      native_id_for_hook="$kimi_id"
    fi
    ;;
esac

# Simulate the real SessionStart hook. Tests may disable, delay, or corrupt the
# registration to exercise fail-closed behavior without launching a paid CLI.
disable_registration="${DUET_FAKE_DISABLE_REGISTRATION:-}"
[ "${DUET_FAKE_DISABLE_REGISTRATION_NAME:-}" != "$name" ] \
  || disable_registration=1
if [ -n "${DUET_NATIVE_REGISTRATION_FILE:-}" ] \
    && [ -n "${DUET_NATIVE_REGISTRATION_HELPER:-}" ] \
    && [ -n "$native_id_for_hook" ] \
    && [ -z "$disable_registration" ]; then
  [ -z "${DUET_FAKE_REGISTRATION_DELAY:-}" ] \
    || sleep "$DUET_FAKE_REGISTRATION_DELAY"
  if [ "${DUET_FAKE_REGISTRATION_DELAY_NAME:-}" = "$name" ]; then
    sleep "${DUET_FAKE_REGISTRATION_DELAY_SECONDS:-0.5}"
  fi
  hook_id="${DUET_FAKE_REGISTRATION_ID:-$native_id_for_hook}"
  if [ "${DUET_FAKE_REGISTRATION_CORRUPT_NAME:-}" = "$name" ]; then
    case "$harness" in
      kimi) hook_id='session_99999999-9999-4999-8999-999999999999' ;;
      *) hook_id='99999999-9999-4999-8999-999999999999' ;;
    esac
  fi
  hook_name="${DUET_FAKE_REGISTRATION_NAME:-$name}"
  old_self="${DUET_SELF:-}"
  DUET_SELF="$hook_name"
  export DUET_SELF
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s","cwd":"%s"}\n' \
    "$native_source" "$hook_id" "$workdir" \
    | node "$DUET_NATIVE_REGISTRATION_HELPER" >/dev/null 2>&1 || true
  DUET_SELF="$old_self"
  export DUET_SELF
fi

# A resume can find and register the requested native session, then have its
# TUI process die before reaching the boot/readiness gate. This proves that
# resolvability alone cannot advance a pairing.
if [ "$native_source" = resume ] \
    && [ "${DUET_FAKE_EXIT_ON_RESUME_NAME:-}" = "$name" ]; then
  exit 42
fi

printf '%s\n' "$banner"
printf 'fake harness ready: %s\n' "$name"
session_dir="${DUET_DIR:-}"
if [ -z "$session_dir" ] && [ -n "${DUET_CONFIG:-}" ]; then
  session_dir="${DUET_CONFIG%/duet.env}"
fi
if [ -n "$session_dir" ]; then
  mkdir -p "$session_dir/ready"
  printf 'ok\n' > "$session_dir/ready/$name"
fi
# Tell tmux that this fake TUI understands bracketed paste, just like the real
# harnesses. That lets the byte loop distinguish pasted newlines from Enter.
printf '\033[?2004h> '

saved_stty="$(stty -g 2>/dev/null || true)"
[ -z "$saved_stty" ] || stty -echo -icanon min 1 time 0
trap '[ -z "$saved_stty" ] || stty "$saved_stty" 2>/dev/null || true' EXIT

buffer=""
control=""
in_paste=""
while IFS= read -r -n 1 character; do
  if [ -n "$control" ]; then
    if [ "$character" = $'\033' ]; then
      control=$'\033'
      continue
    fi
    control="${control}${character}"
    case "$control" in
      $'\033[200~') in_paste=1; control=""; continue ;;
      $'\033[201~') in_paste=""; control=""; continue ;;
    esac
    [ "${#control}" -lt 8 ] || control=""
    continue
  fi
  case "$character" in
    $'\r')
      [ -z "$accept_log" ] || printf '%s\n' "$buffer" >> "$accept_log"
      buffer=""
      printf '\r\naccepted: %s\nready: 1\nready: 2\nready: 3\nready: 4\n> ' "$name"
      ;;
    '')
      if [ -n "$in_paste" ]; then
        buffer="${buffer}"$'\n'
        printf '\r\n'
      else
        [ -z "$accept_log" ] || printf '%s\n' "$buffer" >> "$accept_log"
        buffer=""
        printf '\r\naccepted: %s\nready: 1\nready: 2\nready: 3\nready: 4\n> ' "$name"
      fi
      ;;
    $'\033')
      control=$'\033'
      ;;
    *)
      buffer="${buffer}${character}"
      printf '%s' "$character"
      ;;
  esac
done
