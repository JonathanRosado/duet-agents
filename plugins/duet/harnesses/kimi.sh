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

duet_harness_pretrust(){ :; }

duet_harness_launch_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" bin mode_flag session_id model model_arg=""
  bin="$(command -v kimi)"
  mode_flag="${DUET_KIMI_MODE_FLAG:---auto}"
  model="${DUET_KIMI_MODEL:-}"
  [ -z "$model" ] || printf -v model_arg ' -m %q' "$model"
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env %q %q %q %q %q%s --add-dir %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$bin" "$mode_flag" "$model_arg" "$duet_dir"
}
