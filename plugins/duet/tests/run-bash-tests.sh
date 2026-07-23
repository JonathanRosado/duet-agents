#!/usr/bin/env bash
# Canonical Bash test entrypoint for duet v4.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="${BASH:-bash}"
SUITES='m1-delivery
m2-mesh
m3-lifecycle
v4-real-smoke'

suite_file(){
  case "$1" in
    m1-delivery) printf '%s/m1-delivery.tests.sh' "$TEST_DIR" ;;
    m2-mesh) printf '%s/m2-mesh.tests.sh' "$TEST_DIR" ;;
    m3-lifecycle) printf '%s/m3-lifecycle.tests.sh' "$TEST_DIR" ;;
    v4-real-smoke) printf '%s/v4-real-smoke.sh' "$TEST_DIR" ;;
    *) return 1 ;;
  esac
}

case "$#" in
  0) : ;;
  1)
    if [ "$1" = --list ]; then
      printf '%s\n' "$SUITES"
      exit 0
    fi
    printf 'usage: %s [--list]\n' "$0" >&2
    exit 2
    ;;
  *)
    printf 'usage: %s [--list]\n' "$0" >&2
    exit 2
    ;;
esac

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  printf '\n==== RUN %s ====\n' "$suite"
  "$BASH_BIN" "$(suite_file "$suite")"
done <<EOF
$SUITES
EOF

printf '\n==== ALL DUET V4 BASH SUITES PASS ====\n'
