#!/usr/bin/env bash

DUET_HARNESS_BOOT_RE='Claude Code'
DUET_HARNESS_BRIEF_FILE='CLAUDE.md'

duet_harness_check(){
  command -v claude >/dev/null 2>&1 || {
    echo "duet: 'claude' CLI not found on PATH" >&2
    return 1
  }
}

duet_harness_pretrust(){ :; }

# $4 optionally assigns the harness-native session id at launch, so pairing
# never has to guess which on-disk session this pane became.
duet_harness_launch_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" assigned_id="${4:-}" native_home="${5:-}"
  local bin permission_flag session_id model model_arg="" id_arg=""
  local native_home_arg="" registration_args="" value
  bin="$(command -v claude)"
  permission_flag="${DUET_CLAUDE_PERMISSION_FLAG:---dangerously-skip-permissions}"
  model="${DUET_CLAUDE_MODEL:-}"
  [ -z "$model" ] || printf -v model_arg ' --model %q' "$model"
  [ -z "$assigned_id" ] || printf -v id_arg ' --session-id %q' "$assigned_id"
  [ -z "$native_home" ] \
    || printf -v native_home_arg ' %q' "CLAUDE_CONFIG_DIR=$native_home"
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

  printf 'cd %q && exec env -u DUET_SESSION -u DUET_CONFIG -u DUET_SELF -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u KIMI_SESSION_ID -u DUET_NATIVE_REGISTRATION_FILE -u DUET_NATIVE_REGISTRATION_NONCE -u DUET_NATIVE_REGISTRATION_NAME -u DUET_NATIVE_REGISTRATION_HARNESS -u DUET_NATIVE_REGISTRATION_HELPER -u DUET_NATIVE_EXPECTED_ID %q %q %q%s%s %q %q%s%s --add-dir %q --name %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$native_home_arg" "$registration_args" \
    "$bin" "$permission_flag" "$model_arg" "$id_arg" \
    "$duet_dir" "$name"
}

# Rejoin: resume the recorded native session instead of starting a stranger.
duet_harness_resume_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" native_id="${4:?native id required}"
  local native_home="${5:-}"
  local bin permission_flag session_id model model_arg=""
  local native_home_arg="" registration_args="" value
  bin="$(command -v claude)"
  permission_flag="${DUET_CLAUDE_PERMISSION_FLAG:---dangerously-skip-permissions}"
  model="${DUET_CLAUDE_MODEL:-}"
  [ -z "$model" ] || printf -v model_arg ' --model %q' "$model"
  [ -z "$native_home" ] \
    || printf -v native_home_arg ' %q' "CLAUDE_CONFIG_DIR=$native_home"
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

  printf 'cd %q && exec env -u DUET_SESSION -u DUET_CONFIG -u DUET_SELF -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u KIMI_SESSION_ID -u DUET_NATIVE_REGISTRATION_FILE -u DUET_NATIVE_REGISTRATION_NONCE -u DUET_NATIVE_REGISTRATION_NAME -u DUET_NATIVE_REGISTRATION_HARNESS -u DUET_NATIVE_REGISTRATION_HELPER -u DUET_NATIVE_EXPECTED_ID %q %q %q%s%s %q %q%s --resume %q --add-dir %q --name %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$native_home_arg" "$registration_args" \
    "$bin" "$permission_flag" "$model_arg" \
    "$native_id" "$duet_dir" "$name"
}
