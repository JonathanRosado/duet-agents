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

  config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  escaped="${workdir//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  grep -qF "[projects.\"$escaped\"]" "$config" 2>/dev/null && return 0

  mkdir -p "$(dirname "$config")"
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$escaped" >> "$config"
  echo "duet: marked $workdir trusted for codex"
}

duet_harness_launch_cmd(){
  local workdir="${1:?workdir required}" duet_dir="${2:?duet dir required}"
  local name="${3:?name required}" bin sandbox approval
  bin="$(command -v codex)"
  sandbox="${DUET_CODEX_SANDBOX:-danger-full-access}"
  approval="${DUET_CODEX_APPROVAL:-never}"

  printf 'cd %q && exec env %q %q %q -c %q --add-dir %q -s %q -a %q' \
    "$workdir" "DUET_SELF=$name" "DUET_CONFIG=$duet_dir/duet.env" \
    "$bin" 'check_for_update_on_startup=false' "$duet_dir" "$sandbox" "$approval"
}
