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

duet_harness_launch_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" bin permission_flag session_id model model_arg=""
  bin="$(command -v claude)"
  permission_flag="${DUET_CLAUDE_PERMISSION_FLAG:---dangerously-skip-permissions}"
  model="${DUET_CLAUDE_MODEL:-}"
  [ -z "$model" ] || printf -v model_arg ' --model %q' "$model"
  session_id="$(basename "$duet_dir")"

  printf 'cd %q && exec env %q %q %q %q %q%s --add-dir %q --name %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "DUET_SESSION=$session_id" "$bin" "$permission_flag" "$model_arg" "$duet_dir" "$name"
}
