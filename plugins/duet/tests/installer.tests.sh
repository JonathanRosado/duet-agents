#!/usr/bin/env bash
# Installer gate: the npx entrypoint stages the immutable runtime and renders
# the per-harness skills into an isolated HOME with explicit fake target
# overrides and stub codex/kimi binaries. Claude's marketplace path is not
# exercised here (it would touch the real plugin cache).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/bin/duet-agents.js"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)"
ROOT="$(mktemp -d "$TMP_BASE/duet-installer.XXXXXX")"
FAKE_HOME="$ROOT/home"
FAKEBIN="$ROOT/fakebin"

die(){
  printf 'INSTALLER GATE FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup(){
  case "$ROOT" in
    "$TMP_BASE"/duet-installer.*) rm -rf -- "$ROOT" ;;
    *) printf 'duet test: refused unsafe cleanup path %s\n' "$ROOT" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

command -v node >/dev/null 2>&1 || die "node is required for the duet-agents installer"
[ -f "$INSTALLER" ] || die "missing installer $INSTALLER"

mkdir -p "$FAKE_HOME" "$FAKEBIN"
# Hermetic harness CLIs: the installer requires a runnable codex/kimi binary
# for any selected harness, so the gate supplies stubs instead of depending on
# whatever happens to be installed on the developer machine. (The stale-home
# cases below deliberately use a node-only PATH to prove the skip/failure
# behavior when no harness CLI exists.)
for cli in codex kimi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$cli"
  chmod +x "$FAKEBIN/$cli"
done

PLUGIN_HOME="$ROOT/plugin-runtime"
CODEX_SKILL_DIR="$ROOT/codex-skills/duet"
KIMI_SKILL_DIR="$ROOT/kimi-skills/duet"

run_installer(){
  # Leading VAR=value arguments override the hermetic base environment.
  # Every invocation pins fake targets explicitly: a developer's real
  # DUET_PLUGIN_HOME / DUET_AGENTS_*_SKILL_DIR / CODEX_HOME / KIMI_CODE_HOME
  # must never leak into the gate, and the fake HOME and USERPROFILE keep
  # os.homedir()-derived defaults out on both POSIX and win32. Explicit
  # harness flags keep PATH-based claude detection (and any real
  # marketplace mutation) out of the gate.
  local assigns=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) assigns+=("$1"); shift ;;
      *) break ;;
    esac
  done
  env -u DUET_STATE_ROOT -u CODEX_HOME -u KIMI_CODE_HOME \
    HOME="$FAKE_HOME" \
    USERPROFILE="$FAKE_HOME" \
    PATH="$FAKEBIN:$PATH" \
    DUET_PLUGIN_HOME="$PLUGIN_HOME" \
    DUET_AGENTS_CODEX_SKILL_DIR="$CODEX_SKILL_DIR" \
    DUET_AGENTS_KIMI_SKILL_DIR="$KIMI_SKILL_DIR" \
    ${DUET_AGENTS_FORCE_PLATFORM:+DUET_AGENTS_FORCE_PLATFORM="$DUET_AGENTS_FORCE_PLATFORM"} \
    ${assigns[@]+"${assigns[@]}"} \
    node "$INSTALLER" "$@"
}

CODEX_SKILL="$CODEX_SKILL_DIR/SKILL.md"
KIMI_SKILL="$KIMI_SKILL_DIR/SKILL.md"

# --- unknown argument / command is a usage error
run_installer install --bogus >/dev/null 2>&1 \
  && die "unknown argument was accepted"
run_installer frobnicate >/dev/null 2>&1 \
  && die "unknown command was accepted"

# --- install for codex + kimi
run_installer install --codex --kimi >"$ROOT/install.log" 2>&1 \
  || { cat "$ROOT/install.log" >&2; die "install --codex --kimi failed"; }

[ -x "$PLUGIN_HOME/scripts/duet-init.sh" ] || die "runtime missing executable duet-init.sh"
[ -f "$PLUGIN_HOME/.duet-runtime" ] || die "runtime ownership marker missing"
[ -f "$PLUGIN_HOME/briefs/ENSEMBLE_BRIEF.md" ] || die "runtime missing briefs"
[ -f "$PLUGIN_HOME/harnesses/kimi.sh" ] || die "runtime missing harness adapters"
[ -f "$CODEX_SKILL" ] || die "codex skill not written"
[ -f "$KIMI_SKILL" ] || die "kimi skill not written"
[ -f "$CODEX_SKILL_DIR/.duet-skill" ] || die "codex skill ownership marker missing"
[ -f "$KIMI_SKILL_DIR/.duet-skill" ] || die "kimi skill ownership marker missing"

for skill in "$CODEX_SKILL" "$KIMI_SKILL"; do
  grep -q '^name: duet$' "$skill" || die "skill frontmatter missing name"
  grep -q '^description: ' "$skill" || die "skill frontmatter missing description"
  grep -qF "$PLUGIN_HOME/scripts/duet-init.sh" "$skill" \
    || die "skill does not reference the staged runtime path"
  grep -q '@DUET_PLUGIN_DIR@' "$skill" \
    && die "skill still contains an unrendered placeholder"
  grep -q 'CLAUDE_PLUGIN_ROOT' "$skill" \
    && die "skill leaked the Claude-only plugin root"
done

# --- a pre-existing foreign directory is never adopted, overwritten, or deleted
mkdir -p "$ROOT/foreign/duet"
printf 'do not touch\n' > "$ROOT/foreign/duet/reference.txt"
run_installer DUET_AGENTS_CODEX_SKILL_DIR="$ROOT/foreign/duet" \
  install --codex >"$ROOT/foreign.log" 2>&1 \
  && die "install adopted a foreign directory"
[ -f "$ROOT/foreign/duet/reference.txt" ] || die "foreign content was destroyed on install"
run_installer DUET_AGENTS_CODEX_SKILL_DIR="$ROOT/foreign/duet" \
  uninstall --codex >"$ROOT/foreign-uninstall.log" 2>&1 \
  || die "uninstall of an unowned skill should succeed as a no-op"
[ -f "$ROOT/foreign/duet/reference.txt" ] || die "foreign content was destroyed on uninstall"

# --- even an EMPTY unmarked destination is refused
mkdir -p "$ROOT/empty-runtime"
run_installer DUET_PLUGIN_HOME="$ROOT/empty-runtime" \
  install --codex >"$ROOT/empty.log" 2>&1 \
  && die "empty foreign runtime directory was adopted"
mkdir -p "$ROOT/empty-skill"
run_installer DUET_AGENTS_CODEX_SKILL_DIR="$ROOT/empty-skill" \
  install --codex >"$ROOT/empty-skill.log" 2>&1 \
  && die "empty foreign skill directory was adopted"

# --- symlink aliases cannot smuggle two lexical paths onto one physical dir
mkdir -p "$ROOT/physical"
ln -s "$ROOT/physical" "$ROOT/alias"
run_installer \
  DUET_PLUGIN_HOME="$ROOT/physical/runtime" \
  DUET_AGENTS_CODEX_SKILL_DIR="$ROOT/alias/runtime/skill" \
  install --codex >"$ROOT/symlink.log" 2>&1 \
  && die "symlinked overlap bypassed destination validation"
[ ! -e "$ROOT/physical/runtime" ] || die "runtime was staged despite the aliased overlap"

# --- shell-significant characters in the runtime path are rejected before staging
EVIL="$ROOT/evil"'$UNSET'"/runtime"
run_installer DUET_PLUGIN_HOME="$EVIL" \
  install --codex >"$ROOT/evil.log" 2>&1 \
  && die "a '\$'-bearing runtime path was rendered into a skill"
[ ! -e "$EVIL" ] || die "runtime was staged before the unsafe path was rejected"

# --- an apostrophe in the path is legitimate and renders fine
APOS="$ROOT/it's/runtime"
run_installer DUET_PLUGIN_HOME="$APOS" \
  install --codex >"$ROOT/apos.log" 2>&1 \
  || { cat "$ROOT/apos.log" >&2; die "apostrophe path install failed"; }
grep -qF "$APOS/scripts/duet-init.sh" "$CODEX_SKILL" \
  || die "skill does not reference the apostrophe runtime path"

# --- a stale config home without its CLI is skipped, not a success
mkdir -p "$ROOT/pathbin"
ln -s "$(command -v node)" "$ROOT/pathbin/node"
mkdir -p "$FAKE_HOME/.codex"
run_installer PATH="$ROOT/pathbin" \
  DUET_PLUGIN_HOME= DUET_AGENTS_CODEX_SKILL_DIR= DUET_AGENTS_KIMI_SKILL_DIR= \
  install >"$ROOT/stale.log" 2>&1 \
  && die "implicit install with only a stale config home reported success"
grep -q 'nothing was installed' "$ROOT/stale.log" \
  || die "stale-home run did not explain the skip"
[ ! -e "$FAKE_HOME/.agents" ] || die "skill written for a harness with no CLI"
run_installer PATH="$ROOT/pathbin" \
  DUET_PLUGIN_HOME= DUET_AGENTS_CODEX_SKILL_DIR= DUET_AGENTS_KIMI_SKILL_DIR= \
  install --codex >"$ROOT/stale-explicit.log" 2>&1 \
  && die "explicit --codex without the codex CLI reported success"
grep -q "CLI not found" "$ROOT/stale-explicit.log" \
  || die "explicit --codex without CLI did not fail with guidance"

# --- overlapping destinations are rejected before anything is written
run_installer DUET_AGENTS_CODEX_SKILL_DIR="$PLUGIN_HOME/skill" \
  install --codex >"$ROOT/overlap.log" 2>&1 \
  && die "overlapping runtime/skill destinations were accepted"

# --- update never mutates the immutable runtime (sentinel survives)
printf 'sentinel\n' >> "$PLUGIN_HOME/scripts/duet-init.sh"
run_installer update --codex --kimi >"$ROOT/update.log" 2>&1 \
  || { cat "$ROOT/update.log" >&2; die "update failed"; }
grep -q 'sentinel' "$PLUGIN_HOME/scripts/duet-init.sh" \
  || die "update mutated the pinned runtime"
grep -q 'reused unchanged' "$ROOT/update.log" || die "update did not report runtime reuse"

# --- an older owned version under an exact override is likewise never replaced
printf 'version=0.0.0-test\n' > "$PLUGIN_HOME/.duet-runtime"
run_installer update --codex >"$ROOT/update-old.log" 2>&1 \
  || { cat "$ROOT/update-old.log" >&2; die "update over an older marker failed"; }
grep -q 'sentinel' "$PLUGIN_HOME/scripts/duet-init.sh" \
  || die "update replaced an older owned runtime instead of leaving it for manual GC"
grep -q 'version=0.0.0-test' "$PLUGIN_HOME/.duet-runtime" \
  || die "update rewrote the runtime marker"
VERSION="$(node -p "require('$REPO_ROOT/plugins/duet/.claude-plugin/plugin.json').version")"
printf 'version=%s\n' "$VERSION" > "$PLUGIN_HOME/.duet-runtime"

# --- win32 template renders the .ps1 command path (forced; no Windows needed)
DUET_AGENTS_FORCE_PLATFORM=win32 run_installer install --codex >"$ROOT/win.log" 2>&1 \
  || { cat "$ROOT/win.log" >&2; die "forced-win32 install failed"; }
grep -q 'duet-init\.ps1' "$CODEX_SKILL" \
  || die "win32 skill does not reference the .ps1 init"
grep -q 'TMUX' "$CODEX_SKILL" \
  || die "win32 skill precondition does not check the psmux TMUX variables"
DUET_AGENTS_FORCE_PLATFORM= run_installer install --codex >/dev/null 2>&1 \
  || die "could not restore posix skill after win32 check"
grep -q 'duet-init\.sh' "$CODEX_SKILL" || die "posix skill not restored"

# --- default (versioned) layout lands under ~/.duet/plugin/<version>
run_installer DUET_PLUGIN_HOME= \
  install --codex >"$ROOT/versioned.log" 2>&1 \
  || { cat "$ROOT/versioned.log" >&2; die "versioned install failed"; }
[ -f "$FAKE_HOME/.duet/plugin/$VERSION/.duet-runtime" ] \
  || die "versioned runtime missing at ~/.duet/plugin/$VERSION"
grep -qF "$FAKE_HOME/.duet/plugin/$VERSION/scripts/duet-init.sh" "$CODEX_SKILL" \
  || die "skill does not reference the versioned runtime"

# --- selective uninstall: codex leaves kimi's skill and the runtime
run_installer install --codex --kimi >/dev/null 2>&1 || die "re-install failed"
run_installer uninstall --codex >"$ROOT/uninstall-codex.log" 2>&1 \
  || { cat "$ROOT/uninstall-codex.log" >&2; die "uninstall --codex failed"; }
[ ! -e "$CODEX_SKILL" ] || die "codex skill left behind"
[ -f "$KIMI_SKILL" ] || die "uninstall --codex removed kimi's skill"
[ -f "$PLUGIN_HOME/.duet-runtime" ] || die "uninstall removed the immutable runtime"

# --- uninstall leaves foreign content and session state alone, keeps runtimes
mkdir -p "$FAKE_HOME/.duet/20990101-000000-aaaaaa"
printf 'keep me\n' > "$FAKE_HOME/.duet/20990101-000000-aaaaaa/duet.env"
run_installer uninstall --kimi >"$ROOT/uninstall-kimi.log" 2>&1 \
  || { cat "$ROOT/uninstall-kimi.log" >&2; die "uninstall --kimi failed"; }
[ ! -e "$KIMI_SKILL" ] || die "kimi skill left behind"
[ -f "$PLUGIN_HOME/.duet-runtime" ] || die "uninstall removed the immutable runtime"
[ -f "$FAKE_HOME/.duet/20990101-000000-aaaaaa/duet.env" ] \
  || die "uninstall touched session state"
[ -f "$FAKE_HOME/.duet/plugin/$VERSION/.duet-runtime" ] \
  || die "uninstall disturbed the versioned runtime"

# --- a damaged owned runtime fails with manual-removal guidance (POSIX + Windows files)
rm "$PLUGIN_HOME/scripts/duet-common.sh" "$PLUGIN_HOME/harnesses/codex.ps1"
run_installer update --codex >"$ROOT/corrupt.log" 2>&1 \
  && die "a corrupt runtime was silently reused"
grep -q 'remove the directory manually' "$ROOT/corrupt.log" \
  || die "corrupt runtime error lacked manual-removal guidance"

# --- a version-marker mismatch on the default version path fails closed
printf 'version=0.0.0-wrong\n' > "$FAKE_HOME/.duet/plugin/$VERSION/.duet-runtime"
run_installer DUET_PLUGIN_HOME= \
  install --codex >"$ROOT/mismatch.log" 2>&1 \
  && die "a version-mismatched runtime was silently reused"
grep -q 'remove the directory manually' "$ROOT/mismatch.log" \
  || die "version-mismatch error lacked manual-removal guidance"

printf 'INSTALLER GATE PASS\n'
