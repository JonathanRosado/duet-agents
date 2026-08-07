#!/usr/bin/env bash

DUET_HARNESS_BOOT_RE='Welcome to Kimi Code!'
DUET_HARNESS_BRIEF_FILE='AGENTS.md'

duet_harness_check(){
  command -v kimi >/dev/null 2>&1 || {
    echo "duet: 'kimi' CLI not found on PATH" >&2
    return 1
  }
  kimi doctor >/dev/null 2>&1 || {
    echo "duet: kimi configuration is invalid; run 'kimi doctor'" >&2
    return 1
  }
}

duet_harness_pretrust(){
  local workdir="${1:?workdir required}" native_home="${2:-}"
  local helper
  local home_env=()
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts/duet-native-register.js"
  [ -z "$native_home" ] || home_env=("KIMI_CODE_HOME=$native_home")
  if [ -z "${DUET_KIMI_SKIP_PRETRUST:-}" ] \
      && ! env ${home_env[@]+"${home_env[@]}"} \
        node "$helper" trust-kimi-workspace "$workdir" >/dev/null 2>&1; then
    echo "duet: warning: Kimi workspace pretrust failed; its startup trust dialog may require manual confirmation." >&2
  fi
  [ -z "${DUET_DISABLE_KIMI_SESSION_HOOK:-}" ] || return 0
  if ! env ${home_env[@]+"${home_env[@]}"} \
      node "$helper" install-kimi-hook >/dev/null 2>&1; then
    echo "duet: warning: Kimi SessionStart registration hook is unavailable; this mesh will run, but its native pairing may remain incomplete." >&2
  fi
  return 0
}

duet_harness_launch_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" assigned_id="${4:-}" native_home="${5:-}"
  local bin mode_flag session_id model model_arg="" native_home_arg=""
  local registration_args="" value
  bin="$(command -v kimi)"
  mode_flag="${DUET_KIMI_MODE_FLAG:---auto}"
  model="${DUET_KIMI_MODEL:-}"
  [ -z "$model" ] || printf -v model_arg ' -m %q' "$model"
  [ -z "$native_home" ] \
    || printf -v native_home_arg ' %q' "KIMI_CODE_HOME=$native_home"
  for value in \
    "DUET_NATIVE_REGISTRATION_FILE=${DUET_NATIVE_REGISTRATION_FILE:-}" \
    "DUET_NATIVE_REGISTRATION_NONCE=${DUET_NATIVE_REGISTRATION_NONCE:-}" \
    "DUET_NATIVE_REGISTRATION_NAME=${DUET_NATIVE_REGISTRATION_NAME:-}" \
    "DUET_NATIVE_REGISTRATION_HARNESS=${DUET_NATIVE_REGISTRATION_HARNESS:-}" \
    "DUET_NATIVE_REGISTRATION_HELPER=${DUET_NATIVE_REGISTRATION_HELPER:-}" \
    "DUET_NATIVE_EXPECTED_ID=${DUET_NATIVE_EXPECTED_ID:-}"; do
    [ -z "${value#*=}" ] || printf -v registration_args '%s %q' "$registration_args" "$value"
  done
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env -u DUET_SESSION -u DUET_CONFIG -u DUET_SELF -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u KIMI_SESSION_ID -u DUET_NATIVE_REGISTRATION_FILE -u DUET_NATIVE_REGISTRATION_NONCE -u DUET_NATIVE_REGISTRATION_NAME -u DUET_NATIVE_REGISTRATION_HARNESS -u DUET_NATIVE_REGISTRATION_HELPER -u DUET_NATIVE_EXPECTED_ID %q %q %q%s%s %q %q%s --add-dir %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$native_home_arg" "$registration_args" \
    "$bin" "$mode_flag" "$model_arg" "$duet_dir"
}

# Rejoin: `kimi --session <session_uuid>` resumes the recorded native session.
duet_harness_resume_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" native_id="${4:?native id required}"
  local native_home="${5:-}"
  local bin mode_flag session_id model model_arg="" native_home_arg=""
  local registration_args="" value
  bin="$(command -v kimi)"
  mode_flag="${DUET_KIMI_MODE_FLAG:---auto}"
  model="${DUET_KIMI_MODEL:-}"
  [ -z "$model" ] || printf -v model_arg ' -m %q' "$model"
  [ -z "$native_home" ] \
    || printf -v native_home_arg ' %q' "KIMI_CODE_HOME=$native_home"
  for value in \
    "DUET_NATIVE_REGISTRATION_FILE=${DUET_NATIVE_REGISTRATION_FILE:-}" \
    "DUET_NATIVE_REGISTRATION_NONCE=${DUET_NATIVE_REGISTRATION_NONCE:-}" \
    "DUET_NATIVE_REGISTRATION_NAME=${DUET_NATIVE_REGISTRATION_NAME:-}" \
    "DUET_NATIVE_REGISTRATION_HARNESS=${DUET_NATIVE_REGISTRATION_HARNESS:-}" \
    "DUET_NATIVE_REGISTRATION_HELPER=${DUET_NATIVE_REGISTRATION_HELPER:-}" \
    "DUET_NATIVE_EXPECTED_ID=${DUET_NATIVE_EXPECTED_ID:-}"; do
    [ -z "${value#*=}" ] || printf -v registration_args '%s %q' "$registration_args" "$value"
  done
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env -u DUET_SESSION -u DUET_CONFIG -u DUET_SELF -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u KIMI_SESSION_ID -u DUET_NATIVE_REGISTRATION_FILE -u DUET_NATIVE_REGISTRATION_NONCE -u DUET_NATIVE_REGISTRATION_NAME -u DUET_NATIVE_REGISTRATION_HARNESS -u DUET_NATIVE_REGISTRATION_HELPER -u DUET_NATIVE_EXPECTED_ID %q %q %q%s%s %q %q%s --session %q --add-dir %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$native_home_arg" "$registration_args" \
    "$bin" "$mode_flag" "$model_arg" \
    "$native_id" "$duet_dir"
}
