#!/usr/bin/env bash

DUET_HARNESS_BOOT_RE='OpenAI Codex'
DUET_HARNESS_BRIEF_FILE='AGENTS.md'
DUET_CODEX_SESSION_HOOK_SUPPORTED=1

duet_harness_check(){
  command -v codex >/dev/null 2>&1 || {
    echo "duet: 'codex' CLI not found on PATH" >&2
    return 1
  }
}

duet_harness_pretrust(){
  local workdir="${1:?workdir required}" native_home="${2:-}" config escaped
  local feature_home=()
  DUET_CODEX_SESSION_HOOK_SUPPORTED=1
  [ -z "${DUET_CODEX_SKIP_PRETRUST:-}" ] || return 0
  if [ -n "${DUET_DISABLE_CODEX_SESSION_HOOK:-}" ]; then
    DUET_CODEX_SESSION_HOOK_SUPPORTED=""
  else
    [ -z "$native_home" ] || feature_home=("CODEX_HOME=$native_home")
    if ! env ${feature_home[@]+"${feature_home[@]}"} \
        "$(command -v codex)" features list 2>/dev/null \
        | LC_ALL=C awk '$1=="hooks" { found=1 } END { exit !found }'; then
      DUET_CODEX_SESSION_HOOK_SUPPORTED=""
      echo "duet: warning: this Codex build has no usable SessionStart hook; the worker will still launch, but native pairing may remain incomplete." >&2
    fi
  fi
  case "$workdir" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "duet: Codex pretrust refuses workdirs containing control characters." >&2
      return 1
      ;;
  esac

  if [ -n "$native_home" ]; then
    config="$native_home/config.toml"
  elif [ -n "${CODEX_HOME:-}" ]; then
    config="$CODEX_HOME/config.toml"
  else
    [ -n "${HOME:-}" ] || {
      echo "duet: HOME or CODEX_HOME is required to pretrust a Codex workdir." >&2
      return 1
    }
    config="$HOME/.codex/config.toml"
  fi
  escaped="${workdir//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  grep -qF "[projects.\"$escaped\"]" "$config" 2>/dev/null && return 0

  mkdir -p "$(dirname "$config")"
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$escaped" >> "$config"
  echo "duet: marked $workdir trusted for codex"
}

duet_harness_launch_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" assigned_id="${4:-}" native_home="${5:-}"
  local bin sandbox approval session_id model model_arg=""
  local reasoning_effort reasoning_arg=""
  local codex_home_arg="" registration_args="" hook_args="" hook_value value
  bin="$(command -v codex)"
  sandbox="${DUET_CODEX_SANDBOX:-danger-full-access}"
  approval="${DUET_CODEX_APPROVAL:-never}"
  model="${DUET_CODEX_MODEL:-}"
  reasoning_effort="${DUET_CODEX_REASONING_EFFORT:-}"
  [ -z "$model" ] || printf -v model_arg ' -m %q' "$model"
  [ -z "$reasoning_effort" ] \
    || printf -v reasoning_arg ' -c %q' "model_reasoning_effort=$reasoning_effort"
  if [ -n "$native_home" ]; then
    printf -v codex_home_arg ' %q' "CODEX_HOME=$native_home"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf -v codex_home_arg ' %q' "CODEX_HOME=$CODEX_HOME"
  fi
  if [ -n "${DUET_NATIVE_REGISTRATION_FILE:-}" ] \
      && [ -n "${DUET_CODEX_SESSION_HOOK_SUPPORTED:-}" ]; then
    for value in \
      "DUET_NATIVE_REGISTRATION_FILE=${DUET_NATIVE_REGISTRATION_FILE:-}" \
      "DUET_NATIVE_REGISTRATION_NONCE=${DUET_NATIVE_REGISTRATION_NONCE:-}" \
      "DUET_NATIVE_REGISTRATION_NAME=${DUET_NATIVE_REGISTRATION_NAME:-}" \
      "DUET_NATIVE_REGISTRATION_HARNESS=${DUET_NATIVE_REGISTRATION_HARNESS:-}" \
      "DUET_NATIVE_REGISTRATION_HELPER=${DUET_NATIVE_REGISTRATION_HELPER:-}" \
      "DUET_NATIVE_EXPECTED_ID=${DUET_NATIVE_EXPECTED_ID:-}"; do
      [ -z "${value#*=}" ] || printf -v registration_args '%s %q' "$registration_args" "$value"
    done
    hook_value='[{matcher="startup|resume",hooks=[{type="command",command="exec node \"$DUET_NATIVE_REGISTRATION_HELPER\"",timeout=5}]}]'
    printf -v hook_args ' --dangerously-bypass-hook-trust --enable hooks -c %q' \
      "hooks.SessionStart=$hook_value"
  fi
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env -u DUET_SESSION -u DUET_CONFIG -u DUET_SELF -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u KIMI_SESSION_ID -u DUET_NATIVE_REGISTRATION_FILE -u DUET_NATIVE_REGISTRATION_NONCE -u DUET_NATIVE_REGISTRATION_NAME -u DUET_NATIVE_REGISTRATION_HARNESS -u DUET_NATIVE_REGISTRATION_HELPER -u DUET_NATIVE_EXPECTED_ID %q %q %q%s%s %q%s%s%s -c %q --add-dir %q -s %q -a %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$codex_home_arg" "$registration_args" \
    "$bin" "$hook_args" "$model_arg" "$reasoning_arg" \
    'check_for_update_on_startup=false' \
    "$duet_dir" "$sandbox" "$approval"
}

# Rejoin: `codex resume <uuid>` accepts the same model/sandbox/approval/add-dir
# flags as a fresh launch.
duet_harness_resume_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" native_id="${4:?native id required}"
  local native_home="${5:-}"
  local bin sandbox approval session_id model model_arg=""
  local reasoning_effort reasoning_arg=""
  local codex_home_arg="" registration_args="" hook_args="" hook_value value
  bin="$(command -v codex)"
  sandbox="${DUET_CODEX_SANDBOX:-danger-full-access}"
  approval="${DUET_CODEX_APPROVAL:-never}"
  model="${DUET_CODEX_MODEL:-}"
  reasoning_effort="${DUET_CODEX_REASONING_EFFORT:-}"
  [ -z "$model" ] || printf -v model_arg ' -m %q' "$model"
  [ -z "$reasoning_effort" ] \
    || printf -v reasoning_arg ' -c %q' "model_reasoning_effort=$reasoning_effort"
  if [ -n "$native_home" ]; then
    printf -v codex_home_arg ' %q' "CODEX_HOME=$native_home"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf -v codex_home_arg ' %q' "CODEX_HOME=$CODEX_HOME"
  fi
  if [ -n "${DUET_NATIVE_REGISTRATION_FILE:-}" ] \
      && [ -n "${DUET_CODEX_SESSION_HOOK_SUPPORTED:-}" ]; then
    for value in \
      "DUET_NATIVE_REGISTRATION_FILE=${DUET_NATIVE_REGISTRATION_FILE:-}" \
      "DUET_NATIVE_REGISTRATION_NONCE=${DUET_NATIVE_REGISTRATION_NONCE:-}" \
      "DUET_NATIVE_REGISTRATION_NAME=${DUET_NATIVE_REGISTRATION_NAME:-}" \
      "DUET_NATIVE_REGISTRATION_HARNESS=${DUET_NATIVE_REGISTRATION_HARNESS:-}" \
      "DUET_NATIVE_REGISTRATION_HELPER=${DUET_NATIVE_REGISTRATION_HELPER:-}" \
      "DUET_NATIVE_EXPECTED_ID=${DUET_NATIVE_EXPECTED_ID:-}"; do
      [ -z "${value#*=}" ] || printf -v registration_args '%s %q' "$registration_args" "$value"
    done
    hook_value='[{matcher="startup|resume",hooks=[{type="command",command="exec node \"$DUET_NATIVE_REGISTRATION_HELPER\"",timeout=5}]}]'
    printf -v hook_args ' --dangerously-bypass-hook-trust --enable hooks -c %q' \
      "hooks.SessionStart=$hook_value"
  fi
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env -u DUET_SESSION -u DUET_CONFIG -u DUET_SELF -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u KIMI_SESSION_ID -u DUET_NATIVE_REGISTRATION_FILE -u DUET_NATIVE_REGISTRATION_NONCE -u DUET_NATIVE_REGISTRATION_NAME -u DUET_NATIVE_REGISTRATION_HARNESS -u DUET_NATIVE_REGISTRATION_HELPER -u DUET_NATIVE_EXPECTED_ID %q %q %q%s%s %q%s%s%s -c %q --add-dir %q -s %q -a %q resume %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$codex_home_arg" "$registration_args" \
    "$bin" "$hook_args" "$model_arg" "$reasoning_arg" \
    'check_for_update_on_startup=false' "$duet_dir" "$sandbox" "$approval" \
    "$native_id"
}
