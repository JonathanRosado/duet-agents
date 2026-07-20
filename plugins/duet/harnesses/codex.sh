#!/usr/bin/env bash

DUET_HARNESS_BOOT_RE='OpenAI Codex'
DUET_HARNESS_BRIEF_FILE='AGENTS.md'

duet_harness_check(){
  command -v codex >/dev/null 2>&1 || {
    echo "duet: 'codex' CLI not found on PATH" >&2
    return 1
  }
}

duet_harness_pretrust(){
  local workdir="${1:?workdir required}" config escaped
  [ -z "${DUET_CODEX_SKIP_PRETRUST:-}" ] || return 0
  case "$workdir" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "duet: Codex pretrust refuses workdirs containing control characters." >&2
      return 1
      ;;
  esac

  if [ -n "${CODEX_HOME:-}" ]; then
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
  local name="${3:?name required}" bin sandbox approval session_id model model_arg=""
  local reasoning_effort reasoning_arg=""
  local codex_home_arg=""
  bin="$(command -v codex)"
  sandbox="${DUET_CODEX_SANDBOX:-danger-full-access}"
  approval="${DUET_CODEX_APPROVAL:-never}"
  model="${DUET_CODEX_MODEL:-}"
  reasoning_effort="${DUET_CODEX_REASONING_EFFORT:-}"
  [ -z "$model" ] || printf -v model_arg ' -m %q' "$model"
  [ -z "$reasoning_effort" ] \
    || printf -v reasoning_arg ' -c %q' "model_reasoning_effort=$reasoning_effort"
  [ -z "${CODEX_HOME:-}" ] \
    || printf -v codex_home_arg ' %q' "CODEX_HOME=$CODEX_HOME"
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env %q %q %q%s %q%s%s -c %q --add-dir %q -s %q -a %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$codex_home_arg" "$bin" "$model_arg" "$reasoning_arg" \
    'check_for_update_on_startup=false' \
    "$duet_dir" "$sandbox" "$approval"
}
