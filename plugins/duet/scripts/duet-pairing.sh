#!/usr/bin/env bash
# Native harness session pairing: capture, persistence, and lookup helpers.
#
# A duet session is an ephemeral transport run. Pairing is the durable lineage
# layer: it records which harness-native session (claude --resume UUID, codex
# resume UUID, kimi --session session_<uuid>) each roster member was running,
# so a later `duet-rejoin.sh` can rebuild the mesh around those same native
# sessions instead of starting strangers.
#
# Storage layout:
#   <session>/pairing.tsv        one row per member (see header below)
#   <session>/pairing.complete   written LAST, only when every member's native
#                                id validated AND resolves on disk; content is
#                                the duet session id. Without it pairing.tsv is
#                                diagnostic only and unreachable by lookup.
#   $DUET_STATE_ROOT/pairings/<keyhash>/history  append-only diagnostic log of
#                                complete pairings for this repo's durable
#                                identity. Never used for lookup decisions.
#   $DUET_STATE_ROOT/pairings/<keyhash>/by-id/<harness>-<homehash>-<native_id>
#                                append-only index, one line per complete
#                                pairing naming that native session. Lookup
#                                reads ONLY the last line: the newest record
#                                for the exact (harness, id) is the candidate,
#                                and if it fails validation there is no
#                                candidate — lookup never rolls back to an
#                                older mapping for that id.
#
# Everything here is fail-closed: any doubt means "no pairing" / "no rejoin".

# pairing.tsv columns (13, tab-separated, no CR/NUL):
#   name harness native_id provenance pane_id pane_pid tmux_socket server_pid
#   workdir repo_key captured_at duet_session native_home
DUET_PAIRING_HEADER='name	harness	native_id	provenance	pane_id	pane_pid	tmux_socket	server_pid	workdir	repo_key	captured_at	duet_session	native_home'

duet_claude_projects_dir(){
  local native_home="${1:-}"
  if [ -n "$native_home" ]; then
    printf '%s/projects' "$native_home"
  else
    printf '%s' "${DUET_CLAUDE_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-${HOME:?}/.claude}/projects}"
  fi
}

duet_codex_sessions_dir(){
  local native_home="${1:-}"
  if [ -n "$native_home" ]; then
    printf '%s/sessions' "$native_home"
  else
    printf '%s' "${DUET_CODEX_SESSIONS_DIR:-${CODEX_HOME:-${HOME:?}/.codex}/sessions}"
  fi
}

duet_kimi_session_index(){
  local native_home="${1:-}"
  if [ -n "$native_home" ]; then
    printf '%s/session_index.jsonl' "$native_home"
  else
    printf '%s' "${DUET_KIMI_SESSION_INDEX:-${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}/session_index.jsonl}"
  fi
}

duet_kimi_sessions_dir(){
  local native_home="${1:-}"
  if [ -n "$native_home" ]; then
    printf '%s/sessions' "$native_home"
  else
    printf '%s' "${DUET_KIMI_SESSIONS_DIR:-${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}/sessions}"
  fi
}

# The native config home is part of session identity. Persisting it prevents a
# rejoin invoked from another harness (or another shell) from silently looking
# in that invoker's unrelated default store.
duet_native_home(){
  local harness="${1:?harness required}" explicit="${2:-}" home
  local probe parent base suffix="" canon
  if [ -n "$explicit" ]; then
    home="$explicit"
  else
    case "$harness" in
      claude)
        if [ -n "${DUET_CLAUDE_PROJECTS_DIR:-}" ]; then
          home="$(dirname "$DUET_CLAUDE_PROJECTS_DIR")"
        else
          home="${CLAUDE_CONFIG_DIR:-${HOME:?}/.claude}"
        fi
        ;;
      codex)
        if [ -n "${DUET_CODEX_SESSIONS_DIR:-}" ]; then
          home="$(dirname "$DUET_CODEX_SESSIONS_DIR")"
        else
          home="${CODEX_HOME:-${HOME:?}/.codex}"
        fi
        ;;
      kimi)
        if [ -n "${DUET_KIMI_SESSION_INDEX:-}" ]; then
          home="$(dirname "$DUET_KIMI_SESSION_INDEX")"
        else
          home="${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}"
        fi
        ;;
      *) return 1 ;;
    esac
  fi
  case "$home" in /*) : ;; *) return 1 ;; esac
  case "$home" in *$'\t'*|*$'\r'*|*$'\n'*) return 1;; esac
  command -v node >/dev/null 2>&1 || return 1
  home="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' \
    "$home" 2>/dev/null)" || return 1
  [ "$home" != / ] || return 1
  if [ -e "$home" ]; then
    [ -d "$home" ] || return 1
    (cd "$home" 2>/dev/null && pwd -P)
    return
  fi

  # A worker harness may never have been launched before, so its default
  # config home may not exist yet. Resolve the nearest existing ancestor
  # without creating anything; the adapter/harness creates the leaf during
  # preflight or startup, and strict pairing validation later requires it.
  probe="$home"
  while [ ! -e "$probe" ]; do
    parent="$(dirname "$probe")"
    [ "$parent" != "$probe" ] || return 1
    base="$(basename "$probe")"
    suffix="/$base$suffix"
    probe="$parent"
  done
  [ -d "$probe" ] || return 1
  canon="$(cd "$probe" 2>/dev/null && pwd -P)" || return 1
  printf '%s%s' "$canon" "$suffix"
}

# Read the stable id kept inside a git common directory.
_duet_repo_id_read(){
  local file="${1:?repo id file required}" id lines
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  duet_regular_file_without_nul "$file" || return 1
  lines="$(LC_ALL=C awk 'END { print NR+0 }' "$file" 2>/dev/null)" || return 1
  [ "$lines" = 1 ] || return 1
  id="$(cat "$file" 2>/dev/null)" || return 1
  duet_native_id_shape claude "$id" || return 1
  printf '%s' "$id"
}

# Create the stable repo id without an overwrite race. The temp file is fully
# written before an atomic hard-link publishes it; concurrent creators either
# win the link or read the winner. Failure to write (for example a read-only
# git dir) is reported to the caller, which can retain path-key behavior.
_duet_repo_id_create(){
  local common="${1:?git common dir required}" file tmp id existing
  file="$common/duet-agents-repo-id"
  if [ -e "$file" ] || [ -L "$file" ]; then
    _duet_repo_id_read "$file"
    return
  fi
  tmp="$(mktemp "$common/.duet-repo-id.XXXXXX" 2>/dev/null)" || return 1
  id="$(duet_uuidgen)" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$id" > "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ln "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    printf '%s' "$id"
    return
  fi
  rm -f "$tmp" 2>/dev/null || true
  # A concurrent publisher may have won the link; allow its fully written
  # file a short bounded visibility window.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    existing="$(_duet_repo_id_read "$file" 2>/dev/null || true)"
    [ -z "$existing" ] || { printf '%s' "$existing"; return 0; }
    sleep 0.02
  done
  return 1
}

# Repo identity: a durable id inside the git common directory survives linked
# worktrees and a plain move of the whole repository. Non-git workdirs (and
# read-only git metadata that cannot create the id) key on their canonical
# path. An existing malformed id fails closed instead of silently changing
# lineage.
duet_repo_key(){
  local workdir="${1:?workdir required}" git_common common id id_file
  git_common="$(git -C "$workdir" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$git_common" ]; then
    common="$(cd "$workdir" && cd "$git_common" 2>/dev/null && pwd -P)" \
      || return 1
    id_file="$common/duet-agents-repo-id"
    if [ -e "$id_file" ] || [ -L "$id_file" ]; then
      id="$(_duet_repo_id_read "$id_file")" || return 1
      printf 'git:%s' "$id"
      return
    fi
    id="$(_duet_repo_id_create "$common" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      printf 'git:%s' "$id"
    else
      printf 'git-path:%s' "$common"
    fi
    return
  fi
  common="$(cd "$workdir" 2>/dev/null && pwd -P)" || return 1
  printf 'workdir:%s' "$common"
}

duet_key_hash(){
  local key="${1:?key required}"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$key" | shasum -a 256 | LC_ALL=C awk '{ print substr($1, 1, 24) }'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$key" | sha256sum | LC_ALL=C awk '{ print substr($1, 1, 24) }'
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$key" | node -e '
      const hash = require("crypto").createHash("sha256");
      process.stdin.on("data", chunk => hash.update(chunk));
      process.stdin.on("end", () => process.stdout.write(hash.digest("hex").slice(0, 24)));
    '
  else
    printf '%s' "$key" | cksum | LC_ALL=C awk '{ print $1 }'
  fi
}

duet_pairing_dir_for(){
  local state_root="${1:?state root required}" workdir="${2:?workdir required}"
  local key hash
  key="$(duet_repo_key "$workdir")" || return 1
  [ -n "$key" ] || return 1
  hash="$(duet_key_hash "$key")" || return 1
  [ -n "$hash" ] || return 1
  printf '%s/pairings/%s' "$state_root" "$hash"
}

duet_uuidgen(){
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | LC_ALL=C tr 'A-F' 'a-f'
  elif command -v node >/dev/null 2>&1; then
    node -e 'process.stdout.write(require("crypto").randomUUID())'
  else
    LC_ALL=C od -An -tx1 -N16 /dev/urandom | LC_ALL=C tr -d ' \n' \
      | LC_ALL=C awk '{
          printf "%s-%s-%s-%s-%s\n", substr($0,1,8), substr($0,9,4),
            substr($0,13,4), substr($0,17,4), substr($0,21,12)
        }'
  fi
}

# Shape check only; resolvability is verified separately.
duet_native_id_shape(){
  local harness="${1:?harness required}" id="${2:-}"
  case "$harness" in
    claude|codex)
      printf '%s' "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      ;;
    kimi)
      printf '%s' "$id" \
        | grep -qE '^session_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      ;;
    *) return 1 ;;
  esac
}

# Canonicalize a reported id before storage: lowercase UUIDs, and accept the
# Kimi id with or without its on-disk `session_` prefix (the skill-template
# expansion `${KIMI_SESSION_ID}` may yield either).
duet_normalize_native_id(){
  local harness="${1:?harness required}" id="${2:-}"
  id="$(LC_ALL=C printf '%s' "$id" | tr 'A-F' 'a-f')"
  case "$harness" in
    kimi)
      case "$id" in
        session_*) : ;;
        *) printf '%s' "$id" | grep -qE '^[0-9a-f-]{36}$' && id="session_$id" ;;
      esac
      ;;
  esac
  printf '%s' "$id"
}

# Initiator identity is accepted only from an explicit argument or the
# harness's exact live-session contract. Session-store mtime/newest discovery
# is deliberately absent: one unrelated CLI can otherwise be attributed to
# the invoker and permanently pollute a complete pairing.
duet_capture_initiator_id(){
  local harness="${1:?harness required}" workdir="${2:?workdir required}"
  local explicit="${3:-}" id="" provenance=""
  if [ -n "$explicit" ]; then
    id="$explicit"; provenance="arg"
  else
    case "$harness" in
      claude) id="${CLAUDE_CODE_SESSION_ID:-}"; [ -z "$id" ] || provenance="env" ;;
      codex)  id="${CODEX_THREAD_ID:-}";      [ -z "$id" ] || provenance="env" ;;
      kimi)   id="${KIMI_SESSION_ID:-}";      [ -z "$id" ] || provenance="env" ;;
    esac
  fi
  [ -n "$id" ] || return 1
  id="$(duet_normalize_native_id "$harness" "$id")"
  duet_native_id_shape "$harness" "$id" || return 1
  printf '%s\t%s\n' "$id" "$provenance"
}

# Resolve the last exact Kimi index entry and print its recorded workdir.
# Kimi's native `--session <id>` lookup is index-backed; an orphan directory
# is not evidence that the CLI can resume it. JSON parsing and containment
# checks also prevent a substring match or an out-of-store sessionDir from
# making a pairing appear valid.
duet_kimi_session_workdir(){
  local id="${1:?id required}" native_home="${2:?native home required}"
  local index sessions
  duet_native_id_shape kimi "$id" || return 1
  index="$(duet_kimi_session_index "$native_home")"
  sessions="$(duet_kimi_sessions_dir "$native_home")"
  [ -f "$index" ] && [ ! -L "$index" ] && [ -d "$sessions" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    const fs = require("fs");
    const path = require("path");
    const [index, sessions, id] = process.argv.slice(1);
    let entry;
    for (const line of fs.readFileSync(index, "utf8").split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const value = JSON.parse(line);
        if (value && value.sessionId === id) entry = value;
      } catch (_) {}
    }
    if (!entry || typeof entry.sessionDir !== "string" ||
        !path.isAbsolute(entry.sessionDir) ||
        typeof entry.workDir !== "string" || !path.isAbsolute(entry.workDir) ||
        /[\0\r\n\t]/.test(entry.workDir)) process.exit(1);
    let root;
    let candidate;
    try {
      root = fs.realpathSync(sessions);
      candidate = fs.realpathSync(entry.sessionDir);
    } catch (_) {
      process.exit(1);
    }
    const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
    let stat;
    try {
      stat = fs.statSync(candidate);
    } catch (_) {
      process.exit(1);
    }
    if (!stat.isDirectory() || !candidate.startsWith(prefix) ||
        path.basename(candidate) !== id) process.exit(1);
    process.stdout.write(path.resolve(entry.workDir));
  ' "$index" "$sessions" "$id" 2>/dev/null
}

# The stored native id must still resolve to an on-disk session record;
# otherwise a rejoin would resume nothing and silently start a stranger.
duet_native_id_resolvable(){
  local harness="${1:?harness required}" id="${2:-}" native_home="${3:-}" found
  duet_native_id_shape "$harness" "$id" || return 1
  [ -z "$native_home" ] || native_home="$(duet_native_home "$harness" "$native_home")" \
    || return 1
  case "$harness" in
    claude)
      found="$(find "$(duet_claude_projects_dir "$native_home")" -type f -name "$id.jsonl" \
        -print -quit 2>/dev/null || true)"
      [ -n "$found" ]
      ;;
    codex)
      found="$(find "$(duet_codex_sessions_dir "$native_home")" -type f -name "rollout-*-$id.jsonl" \
        -print -quit 2>/dev/null || true)"
      [ -n "$found" ]
      ;;
    kimi)
      duet_kimi_session_workdir "$id" "$native_home" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Kimi currently refuses `--session <id>` when the launch cwd differs from the
# session's recorded workDir. Claude and Codex accept exact by-id resume across
# linked worktrees. Never rewrite a harness's session store to force a move.
duet_native_session_resumable(){
  local harness="${1:?harness required}" id="${2:?id required}"
  local native_home="${3:?native home required}" recorded_workdir="${4:?recorded workdir required}"
  local current_workdir="${5:?current workdir required}"
  local old_canon current_canon indexed_workdir indexed_canon
  duet_native_id_resolvable "$harness" "$id" "$native_home" || return 1
  [ "$harness" = kimi ] || return 0
  indexed_workdir="$(duet_kimi_session_workdir "$id" "$native_home")" || return 1
  old_canon="$(cd "$recorded_workdir" 2>/dev/null && pwd -P)" || return 1
  current_canon="$(cd "$current_workdir" 2>/dev/null && pwd -P)" || return 1
  indexed_canon="$(cd "$indexed_workdir" 2>/dev/null && pwd -P)" || return 1
  [ "$old_canon" = "$current_canon" ] && [ "$indexed_canon" = "$current_canon" ]
}

# Validate one pane-scoped SessionStart registration and print
# `<native-id><TAB><startup|resume>`. The Node helper performs strict JSON,
# nonce, member, pane, pid, cwd, and expected-resume-id checks.
duet_capture_registered_worker_id(){
  local helper="${1:?helper required}" file="${2:?file required}"
  local harness="${3:?harness required}" name="${4:?name required}"
  local nonce="${5:?nonce required}" duet_session="${6:?session required}"
  local pane="${7:?pane required}" pane_pid="${8:?pane pid required}"
  local workdir="${9:?workdir required}" expected_id="${10:-}"
  command -v node >/dev/null 2>&1 || return 1
  DUET_NATIVE_EXPECTED_ID="$expected_id" \
    node "$helper" verify "$file" "$harness" "$name" "$nonce" \
      "$duet_session" "$pane" "$pane_pid" "$workdir" 2>/dev/null
}

# Marker-independent validation used both for diagnostic records and before
# any by-id append. In strict mode every native id/provenance must be present.
# Rows must match the immutable roster's exact (name,harness,pane,pid) set.
duet_pairing_validate_tsv(){
  local session_dir="${1:?session dir required}" tsv="${2:?tsv required}"
  local strict="${3:-1}" session_id rowno rows harness id native_home
  duet_regular_file_without_nul "$tsv" || return 1
  duet_validate_roster "$session_dir/roster.tsv" || return 1
  session_id="$(basename "$session_dir")"
  LC_ALL=C awk -F '\t' -v header="$DUET_PAIRING_HEADER" -v sid="$session_id" \
    -v strict="$strict" '
    function reject(){ bad=1; exit }
    FNR==NR {
      line=$0; sub(/\r$/, "", line)
      if (FNR==1) {
        if (line!="name\tharness\tpane_id\tpane_pid\trank\tspawned") reject()
        next
      }
      if (line=="") next
      n=split(line,r,"\t"); if (n!=6) reject()
      roster_h[r[1]]=r[2]; roster_pane[r[1]]=r[3]; roster_pid[r[1]]=r[4]
      roster_rows++; next
    }
    {
      line=$0; sub(/\r$/, "", line)
      if (FNR==1) { if (line != header) reject(); next }
      if (line=="") next
      n=split(line,c,"\t"); if (n != 13) reject()
      if (c[1] !~ /^[A-Za-z0-9_-]+$/ || !(c[1] in roster_h)) reject()
      if (c[2]!="claude" && c[2]!="codex" && c[2]!="kimi") reject()
      if (c[2]!=roster_h[c[1]] || c[5]!=roster_pane[c[1]] || c[6]!=roster_pid[c[1]]) reject()
      if ((c[3]=="" && c[4]!="") || (c[3]!="" && c[4]=="")) reject()
      if (strict && (c[3]=="" || c[4]=="")) reject()
      if (c[3]!="" && c[3] !~ /^[A-Za-z0-9_-]+$/) reject()
      if (c[4]!="" && c[4] !~ /^(assigned|env|arg|hook)$/) reject()
      if (c[5] !~ /^%[0-9]+$/ || c[6] !~ /^[0-9]+$/ || c[8] !~ /^[0-9]+$/) reject()
      if (c[7]=="" || c[9]=="" || c[10]=="") reject()
      if (c[11] !~ /^[0-9TZ:-]+$/ || c[12] != sid) reject()
      if (c[13] !~ /^\//) reject()
      folded=tolower(c[1]); native_key=c[2] SUBSEP c[3]
      if ((folded in names) || (c[3]!="" && (native_key in ids))) reject()
      names[folded]=1; if (c[3]!="") ids[native_key]=1
      if (rows==0) {
        socket=c[7]; server=c[8]; workdir=c[9]; repo=c[10]
      } else if (c[7]!=socket || c[8]!=server || c[9]!=workdir || c[10]!=repo) reject()
      rows++; if (rows > 5) reject()
    }
    END { exit (bad || rows < 1 || rows != roster_rows) }
  ' "$session_dir/roster.tsv" "$tsv" || return 1

  rows="$(LC_ALL=C awk 'END { print NR+0 }' "$tsv")" || return 1
  for rowno in $(seq 2 "$rows"); do
    harness="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $2 }' "$tsv")"
    id="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $3 }' "$tsv")"
    native_home="$(LC_ALL=C awk -F '\t' -v n="$rowno" 'NR==n { print $13 }' "$tsv")"
    [ -z "$id" ] || duet_native_id_shape "$harness" "$id" || return 1
    [ -d "$native_home" ] || return 1
    [ "$(duet_native_home "$harness" "$native_home" 2>/dev/null || true)" = "$native_home" ] \
      || return 1
  done
}

# Complete-candidate validation additionally requires a marker whose content
# equals the directory basename. A partial or transplanted record is never
# selected.
duet_pairing_validate(){
  local session_dir="${1:?session dir required}"
  local tsv="$session_dir/pairing.tsv" marker="$session_dir/pairing.complete"
  local session_id
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  session_id="$(basename "$session_dir")"
  [ "$(cat "$marker" 2>/dev/null)" = "$session_id" ] || return 1
  duet_pairing_validate_tsv "$session_dir" "$tsv" 1
}

duet_pairing_field(){
  local session_dir="${1:?dir required}" name="${2:?name required}" col="${3:?col required}"
  LC_ALL=C awk -F '\t' -v name="$name" -v col="$col" \
    'NR > 1 && $1 == name { value=$col; count++ }
     END { if (count == 1) print value }' \
    "$session_dir/pairing.tsv" 2>/dev/null
}

# The candidate for an exact (harness, native_id) is the LAST line of that
# id's append-only index — the newest record naming it. That one record is
# validated; if it is missing, corrupt, foreign-keyed, or does not actually
# contain the member, there is no candidate. Older records for the same id
# are deliberately never consulted: a polluted newer entry must fail closed,
# not silently resurrect a stale mapping.
duet_pairing_latest_for_id(){
  local state_root="${1:?state root required}" workdir="${2:?workdir required}"
  local harness="${3:?harness required}" native_id="${4:?id required}"
  local native_home="${5:?native home required}" pdir index key dir home_hash
  native_home="$(duet_native_home "$harness" "$native_home")" || return 1
  pdir="$(duet_pairing_dir_for "$state_root" "$workdir")" || return 1
  home_hash="$(duet_key_hash "$native_home")" || return 1
  index="$pdir/by-id/$harness-$home_hash-$native_id"
  [ -f "$index" ] && [ ! -L "$index" ] || return 1
  key="$(duet_repo_key "$workdir")" || return 1
  dir="$(LC_ALL=C awk 'NF { last=$0 } END { if (last) print last }' "$index")"
  # Entries outside the state root are never followed.
  [ -n "$dir" ] && [ "${dir#"$state_root"/}" != "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  duet_pairing_validate "$dir" 2>/dev/null || return 1
  LC_ALL=C awk -F '\t' -v h="$harness" -v id="$native_id" -v key="$key" \
    -v home="$native_home" \
    'NR > 1 && $2 == h && $3 == id && $10 == key && $13 == home { found=1 }
     END { exit !found }' "$dir/pairing.tsv" 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

# Publish pairing.tsv rows ($5.. as preformatted TSV lines) atomically.
# Publication order is the integrity story, so it is strict:
#   1. pairing.tsv
#   2. every by-id index append, then the diagnostic history line
#   3. pairing.complete — always LAST
# An interrupted complete publication therefore leaves the newest by-id
# entries pointing at a markerless record, which lookup fails closed; members
# whose ids were never appended still point at an older mapping, and rejoin's
# reciprocal check refuses to select that stale set. Any index failure aborts
# before the marker, so a partially indexed record is never completable.
duet_pairing_publish(){
  local session_dir="${1:?session dir required}" state_root="${2:?state root required}"
  local workdir="${3:?workdir required}" complete="${4:-0}"
  local tsv_tmp marker_tmp pdir history
  tsv_tmp="$(mktemp "$session_dir/.pairing.XXXXXX")" || return 1
  {
    printf '%s\n' "$DUET_PAIRING_HEADER"
    shift 4
    for row in "$@"; do printf '%s\n' "$row"; done
  } > "$tsv_tmp" || { rm -f "$tsv_tmp"; return 1; }
  # Validate the exact staged bytes against the roster before they can affect
  # any durable index. This is strict for a complete publication and allows
  # empty id/provenance pairs only for diagnostic records.
  if ! duet_pairing_validate_tsv "$session_dir" "$tsv_tmp" \
      "$([ "$complete" = 1 ] && printf 1 || printf 0)"; then
    rm -f "$tsv_tmp" 2>/dev/null || true
    return 1
  fi
  if ! duet_publish_temp_file "$tsv_tmp" "$session_dir/pairing.tsv"; then
    rm -f "$tsv_tmp" 2>/dev/null || true
    return 1
  fi
  [ "$complete" = 1 ] || return 0
  pdir="$(duet_pairing_dir_for "$state_root" "$workdir")" || return 1
  mkdir -p "$pdir/by-id" || return 1
  # Per-member append-only index: one line per complete pairing naming that
  # exact (harness, native_id). Lookup trusts only the last line.
  local row m_harness m_id m_home home_hash
  for row in "$@"; do
    m_harness="$(printf '%s' "$row" | LC_ALL=C awk -F '\t' '{ print $2 }')"
    m_id="$(printf '%s' "$row" | LC_ALL=C awk -F '\t' '{ print $3 }')"
    m_home="$(printf '%s' "$row" | LC_ALL=C awk -F '\t' '{ print $13 }')"
    case "$m_harness" in claude|codex|kimi) : ;; *) return 1 ;; esac
    case "$m_id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    home_hash="$(duet_key_hash "$m_home")" || return 1
    printf '%s\n' "$session_dir" >> "$pdir/by-id/$m_harness-$home_hash-$m_id" \
      2>/dev/null || return 1
  done
  history="$pdir/history"
  [ -f "$history" ] || : > "$history" 2>/dev/null || true
  printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$session_dir" >> "$history" \
    2>/dev/null || true
  # The complete marker is published only after every index append succeeded.
  marker_tmp="$(mktemp "$session_dir/.pairing-complete.XXXXXX")" || return 1
  if ! printf '%s\n' "$(basename "$session_dir")" > "$marker_tmp" \
      || ! duet_publish_temp_file "$marker_tmp" "$session_dir/pairing.complete"; then
    rm -f "$marker_tmp" 2>/dev/null || true
    return 1
  fi
}

duet_count_undelivered(){
  local session_dir="${1:?session dir required}" box file count=0
  for box in "$session_dir"/inbox/*; do
    [ -d "$box" ] || continue
    for file in "$box"/N-*.msg "$box"/I-*.msg; do
      [ -f "$file" ] || continue
      count=$((count + 1))
    done
  done
  printf '%s' "$count"
}
