#!/usr/bin/env node
/*
 * duet-agents installer — installs (or updates/removes) the duet multi-agent
 * mesh for Claude Code, Codex CLI, and Kimi CLI.
 *
 *   duet-agents install   [--claude] [--codex] [--kimi]
 *   duet-agents update    [--claude] [--codex] [--kimi]
 *   duet-agents uninstall [--claude] [--codex] [--kimi]
 *
 * With no harness flags, every harness with a usable CLI on PATH is selected
 * (a stale config home alone only earns a skip note; pass a flag to force, and
 * uninstall additionally selects harnesses with an installed duet skill).
 * Claude Code is served through its plugin marketplace. Codex gets the skill
 * in ~/.agents/skills/duet; Kimi gets it in $KIMI_CODE_HOME/skills/duet
 * (default ~/.kimi-code/skills/duet).
 *
 * Runtime policy: Codex and Kimi share a versioned runtime under
 * ~/.duet/plugin/<version>. Runtime directories are IMMUTABLE — the installer
 * creates a version directory once, verifies and reuses it while it exists,
 * and never deletes runtimes (a live session pins its version's absolute path,
 * and there is no reliable way to prove none do; runtimes are small — remove
 * ~/.duet/plugin manually when no sessions are running).
 *
 * Safety: destinations are canonicalized through their nearest existing
 * ancestor (symlink aliases cannot bypass checks), then validated — no roots,
 * home, source-tree ancestors or descendants, and no overlap between
 * destinations. Existing directories are only ever used when they carry a duet
 * ownership marker; foreign directories are never adopted, overwritten, or
 * deleted. A runtime path is rendered into skill shell commands only when it
 * contains no shell-significant characters.
 *
 * Environment overrides (mainly for tests):
 *   DUET_PLUGIN_HOME             exact runtime directory (skips versioning;
 *                                still immutable once installed)
 *   DUET_AGENTS_CODEX_SKILL_DIR  Codex skill directory (default ~/.agents/skills/duet)
 *   DUET_AGENTS_KIMI_SKILL_DIR   Kimi skill directory (default $KIMI_CODE_HOME/skills/duet)
 *   DUET_AGENTS_FORCE_PLATFORM   'win32' renders the Windows skill template (tests)
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const PLUGIN_SRC = path.join(REPO_ROOT, 'plugins', 'duet');
const MARKETPLACE = 'JonathanRosado/duet-agents';
const MARKETPLACE_NAME = 'duet-agents';
const PLUGIN_REF = 'duet@duet-agents';
const RUNTIME_MARKER = '.duet-runtime';
const SKILL_MARKER = '.duet-skill';
const IS_WIN =
  process.env.DUET_AGENTS_FORCE_PLATFORM === 'win32' || process.platform === 'win32';
// Binary lookup and case folding always follow the real host; IS_WIN only
// selects the skill template and the final next-steps text.
const HOST_WIN = process.platform === 'win32';
const CASE_FOLD = IS_WIN || process.platform === 'darwin';

/* The required payload is every regular file in the copied plugin tree — a
 * reused runtime must be a complete copy, not just pass a spot check. */
function listRegularFiles(root) {
  const out = [];
  (function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.isFile()) out.push(path.relative(root, p));
    }
  })(root);
  return out;
}
const RUNTIME_REQUIRED_FILES = listRegularFiles(PLUGIN_SRC);

const VERSION = JSON.parse(
  fs.readFileSync(path.join(PLUGIN_SRC, '.claude-plugin', 'plugin.json'), 'utf8')
).version;

function usage() {
  console.log(`usage: duet-agents <install|update|uninstall> [--claude] [--codex] [--kimi]

install    Install duet for the selected (or all detected) harnesses.
update     Move an existing install to this version.
uninstall  Remove the per-harness duet skills and the Claude plugin. Runtime
           copies under ~/.duet/plugin are left in place (they are small and a
           live session may still pin one); remove that directory manually
           when no sessions are running. Session state is never touched.

Harness selection flags may be combined; with none, every harness whose CLI is
on PATH is selected. Codex reads ~/.agents/skills/duet; Kimi reads
$KIMI_CODE_HOME/skills/duet; both share the versioned runtime. Restart each
CLI afterwards.`);
}

function home() {
  return os.homedir();
}

function hasBinary(name) {
  const res = spawnSync(
    HOST_WIN ? 'where' : 'command',
    HOST_WIN ? [name] : ['-v', name],
    { shell: !HOST_WIN, stdio: 'ignore' }
  );
  return res.status === 0;
}

function runtimeDirRaw() {
  if (process.env.DUET_PLUGIN_HOME) return process.env.DUET_PLUGIN_HOME;
  return path.join(home(), '.duet', 'plugin', VERSION);
}

function codexSkillDirRaw() {
  return (
    process.env.DUET_AGENTS_CODEX_SKILL_DIR || path.join(home(), '.agents', 'skills', 'duet')
  );
}

function kimiSkillDirRaw() {
  const kimiHome = process.env.KIMI_CODE_HOME || path.join(home(), '.kimi-code');
  return process.env.DUET_AGENTS_KIMI_SKILL_DIR || path.join(kimiHome, 'skills', 'duet');
}

function hasMarker(dir, marker) {
  return fs.existsSync(path.join(dir, marker));
}

/* Resolve through the nearest existing ancestor so symlink aliases cannot
 * smuggle two lexical paths onto one physical directory. */
function canonicalize(p) {
  const resolved = path.resolve(p);
  let existing = resolved;
  const suffix = [];
  while (!fs.existsSync(existing)) {
    suffix.unshift(path.basename(existing));
    const parent = path.dirname(existing);
    if (parent === existing) break;
    existing = parent;
  }
  let canon;
  try {
    canon = fs.realpathSync(existing);
  } catch (_) {
    canon = existing;
  }
  return suffix.length ? path.join(canon, ...suffix) : canon;
}

function fold(p) {
  return CASE_FOLD ? p.toLowerCase() : p;
}

function isSameOrAncestor(maybeAncestor, p) {
  const rel = path.relative(fold(maybeAncestor), fold(p));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

const HOME_CANON = canonicalize(home());
const REPO_CANON = canonicalize(REPO_ROOT);

/* Canonicalize and validate a directory we may write into. */
function safeDestination(dir, label) {
  const canon = canonicalize(dir);
  const problems = [];
  if (canon === path.parse(canon).root) problems.push('is a filesystem root');
  if (fold(canon) === fold(HOME_CANON)) problems.push('is the home directory');
  if (isSameOrAncestor(canon, REPO_CANON) || isSameOrAncestor(REPO_CANON, canon)) {
    problems.push('is the duet-agents source tree, an ancestor, or inside it');
  }
  const depth = canon.split(path.sep).filter(Boolean).length;
  if (depth < 3) problems.push('is too shallow to manage safely');
  if (String(dir).trim() !== String(dir) || String(dir).includes('\0')) {
    problems.push('has unsafe characters');
  }
  if (problems.length) {
    throw new Error(`refusing to use ${label} '${canon}': it ${problems.join(' and ')}`);
  }
  return canon;
}

/* No two destinations may be the same directory or contain one another. */
function assertNoOverlap(destinations) {
  for (let i = 0; i < destinations.length; i++) {
    for (let j = i + 1; j < destinations.length; j++) {
      const a = destinations[i];
      const b = destinations[j];
      if (isSameOrAncestor(a.dir, b.dir) || isSameOrAncestor(b.dir, a.dir)) {
        throw new Error(
          `refusing overlapping destinations: ${a.label} '${a.dir}' and ${b.label} '${b.dir}'`
        );
      }
    }
  }
}

/* The runtime path lands inside quoted shell/PowerShell commands in the
 * rendered skill. Anything the shell or PowerShell could interpret there must
 * be rejected outright instead of escaped into correctness-by-luck. */
function assertShellSafeForRender(p) {
  const bad = /[$`"\n\r\t]/.test(p) || (!IS_WIN && p.includes('\\'));
  if (bad) {
    throw new Error(
      `refusing to render the runtime path '${p}' into a skill: it contains ` +
        'shell-significant characters; set DUET_PLUGIN_HOME to a plain path'
    );
  }
}

function rmrf(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function readMarkerVersion(dir, marker) {
  try {
    const text = fs.readFileSync(path.join(dir, marker), 'utf8');
    const line = text.split('\n').find((l) => l.startsWith('version='));
    return line ? line.slice('version='.length).trim() : null;
  } catch (_) {
    return null;
  }
}

/*
 * Create the runtime directory once and never modify it again. An existing
 * marker-owned directory is verified and reused verbatim (immutability is what
 * keeps live sessions pinned); any unmarked directory is refused.
 */
function installRuntime(notes) {
  const dest = safeDestination(runtimeDirRaw(), 'runtime directory');
  if (fs.existsSync(dest)) {
    if (!hasMarker(dest, RUNTIME_MARKER)) {
      throw new Error(
        `refusing to use '${dest}': it exists but was not installed by duet-agents`
      );
    }
    const missing = RUNTIME_REQUIRED_FILES.filter(
      (f) => !fs.existsSync(path.join(dest, f))
    );
    if (missing.length) {
      throw new Error(
        `runtime at '${dest}' is incomplete (missing ${missing.join(', ')}); ` +
          'remove the directory manually and reinstall'
      );
    }
    const markerVersion = readMarkerVersion(dest, RUNTIME_MARKER);
    if (!process.env.DUET_PLUGIN_HOME && markerVersion !== VERSION) {
      throw new Error(
        `runtime at '${dest}' is marked version '${markerVersion}' but this installer is ` +
          `${VERSION}; remove the directory manually and reinstall`
      );
    }
    notes.push(`runtime reused unchanged at ${dest} (immutable; remove it manually to force a refresh)`);
    return dest;
  }
  const parent = path.dirname(dest);
  fs.mkdirSync(parent, { recursive: true });
  const staging = fs.mkdtempSync(path.join(parent, '.duet-staging-'));
  try {
    fs.cpSync(PLUGIN_SRC, staging, { recursive: true });
    fs.writeFileSync(
      path.join(staging, RUNTIME_MARKER),
      `version=${VERSION}\ninstalled=${new Date().toISOString()}\n`
    );
    if (!IS_WIN) {
      for (const sub of ['scripts', 'harnesses']) {
        for (const entry of fs.readdirSync(path.join(staging, sub))) {
          if (entry.endsWith('.sh')) fs.chmodSync(path.join(staging, sub, entry), 0o755);
        }
      }
    }
    // Only our own mkdtemp staging directory is ever removed, and the rename
    // target does not exist yet, so a failed rename cannot lose data.
    fs.renameSync(staging, dest);
  } finally {
    if (fs.existsSync(staging)) rmrf(staging);
  }
  notes.push(`runtime installed at ${dest}`);
  return dest;
}

function renderSkillInto(dir) {
  const dest = safeDestination(dir, 'skill directory');
  if (fs.existsSync(dest) && !hasMarker(dest, SKILL_MARKER)) {
    throw new Error(
      `refusing to use '${dest}': a directory not installed by duet-agents lives there; move it aside or remove it yourself`
    );
  }
  const runtime = safeDestination(runtimeDirRaw(), 'runtime directory');
  assertShellSafeForRender(runtime);
  const templateName = IS_WIN ? 'agents-skill.win.md' : 'agents-skill.posix.md';
  const rendered = fs
    .readFileSync(path.join(PLUGIN_SRC, 'templates', templateName), 'utf8')
    .split('@DUET_PLUGIN_DIR@')
    .join(runtime);
  fs.mkdirSync(dest, { recursive: true });
  fs.writeFileSync(path.join(dest, 'SKILL.md'), rendered);
  fs.writeFileSync(
    path.join(dest, SKILL_MARKER),
    `version=${VERSION}\ninstalled=${new Date().toISOString()}\n`
  );
  return path.join(dest, 'SKILL.md');
}

/* Remove a skill only when we own it. Returns true when nothing is left blocking. */
function removeSkill(dir, label, notes, failures) {
  if (!fs.existsSync(dir)) {
    notes.push(`${label}: no skill installed`);
    return true;
  }
  if (!hasMarker(dir, SKILL_MARKER)) {
    notes.push(`${label}: '${canonicalize(dir)}' was not installed by duet-agents; leaving it untouched`);
    return true;
  }
  try {
    rmrf(safeDestination(dir, `${label} skill directory`));
    notes.push(`${label}: removed skill ${path.join(canonicalize(dir), 'SKILL.md')}`);
    return true;
  } catch (err) {
    failures.push(`${label}: ${err.message}`);
    return false;
  }
}

function runClaude(args) {
  const res = spawnSync('claude', args, { stdio: 'inherit', shell: HOST_WIN });
  return res.status === 0;
}

function parseArgs(argv) {
  const selected = { claude: false, codex: false, kimi: false };
  let command = null;
  let explicit = false;
  for (const arg of argv) {
    switch (arg) {
      case 'install':
      case 'update':
      case 'uninstall':
        if (command) return { error: `unexpected extra command '${arg}'` };
        command = arg;
        break;
      case '--claude':
      case '--codex':
      case '--kimi':
        selected[arg.slice(2)] = true;
        explicit = true;
        break;
      case '-h':
      case '--help':
        return { help: true };
      default:
        return { error: `unknown argument '${arg}'` };
    }
  }
  return { command: command || 'install', selected, explicit };
}

function detection() {
  const h = home();
  return {
    claude: {
      binary: hasBinary('claude'),
      home: fs.existsSync(path.join(h, '.claude')),
      artifact: false,
    },
    codex: {
      binary: hasBinary('codex'),
      home: fs.existsSync(process.env.CODEX_HOME || path.join(h, '.codex')),
      artifact: hasMarker(canonicalize(codexSkillDirRaw()), SKILL_MARKER),
    },
    kimi: {
      binary: hasBinary('kimi'),
      home: fs.existsSync(process.env.KIMI_CODE_HOME || path.join(h, '.kimi-code')),
      artifact: hasMarker(canonicalize(kimiSkillDirRaw()), SKILL_MARKER),
    },
  };
}

function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    usage();
    process.exit(0);
  }
  if (parsed.error) {
    console.error(`duet-agents: ${parsed.error}`);
    usage();
    process.exit(2);
  }
  const { command } = parsed;

  const det = detection();
  const selected = { claude: false, codex: false, kimi: false };
  if (parsed.explicit) {
    Object.assign(selected, parsed.selected);
  } else {
    for (const name of ['claude', 'codex', 'kimi']) {
      // Install/update need a runnable CLI; uninstall also serves harnesses
      // whose CLI is gone but a duet artifact remains.
      selected[name] =
        det[name].binary || det[name].home || (command === 'uninstall' && det[name].artifact);
    }
  }
  if (!selected.claude && !selected.codex && !selected.kimi) {
    console.error(
      'duet-agents: no supported harness detected (looked for claude, codex, kimi ' +
        'binaries, their config homes, and installed duet skills). ' +
        'Pass --claude, --codex, and/or --kimi to select explicitly.'
    );
    process.exit(1);
  }

  const notes = [];
  const failures = [];

  if (command === 'uninstall') {
    if (selected.codex) removeSkill(codexSkillDirRaw(), 'codex', notes, failures);
    if (selected.kimi) removeSkill(kimiSkillDirRaw(), 'kimi', notes, failures);
    if (selected.codex || selected.kimi) {
      let runtimeDisplay;
      try {
        runtimeDisplay = safeDestination(runtimeDirRaw(), 'runtime directory');
      } catch (_) {
        runtimeDisplay = canonicalize(runtimeDirRaw()); // display only; no mutation here
      }
      if (fs.existsSync(runtimeDisplay)) {
        notes.push(
          process.env.DUET_PLUGIN_HOME
            ? `runtime left in place at ${runtimeDisplay} (immutable; remove it yourself when no sessions are running)`
            : `runtime left in place at ${runtimeDisplay} (immutable; a live session may still pin it — remove ~/.duet/plugin manually when no sessions are running)`
        );
      }
    }
    if (selected.claude) {
      if (!det.claude.binary) {
        failures.push('claude: CLI not on PATH; uninstall the plugin from inside Claude Code');
      } else if (runClaude(['plugin', 'uninstall', PLUGIN_REF])) {
        notes.push('claude: plugin uninstalled');
      } else {
        failures.push(`claude: 'claude plugin uninstall ${PLUGIN_REF}' failed`);
      }
    }
    for (const n of notes) console.log(`duet-agents: ${n}`);
    for (const f of failures) console.error(`duet-agents: ${f}`);
    console.log(
      failures.length
        ? 'duet-agents: uninstall incomplete (see above). Session state was left untouched.'
        : 'duet-agents: uninstall complete. Session state was left untouched.'
    );
    process.exit(failures.length ? 1 : 0);
  }

  // install / update: every selected harness must have a runnable CLI.
  const succeeded = { claude: false, codex: false, kimi: false };
  const cliRequired = { codex: 'codex', kimi: 'kimi' };
  for (const name of ['codex', 'kimi']) {
    if (!selected[name]) continue;
    if (det[name].binary) continue;
    if (parsed.explicit) {
      failures.push(`${name}: '${cliRequired[name]}' CLI not found on PATH; install it first`);
    } else {
      notes.push(
        `${name}: config home found but no '${cliRequired[name]}' CLI on PATH; skipping (pass --${name} to force)`
      );
    }
    selected[name] = false;
  }

  if (selected.codex || selected.kimi) {
    try {
      const destinations = [{ label: 'runtime directory', dir: safeDestination(runtimeDirRaw(), 'runtime directory') }];
      if (selected.codex) destinations.push({ label: 'codex skill directory', dir: safeDestination(codexSkillDirRaw(), 'codex skill directory') });
      if (selected.kimi) destinations.push({ label: 'kimi skill directory', dir: safeDestination(kimiSkillDirRaw(), 'kimi skill directory') });
      assertNoOverlap(destinations);
      assertShellSafeForRender(destinations[0].dir); // fail before staging anything
      installRuntime(notes);
      if (selected.codex) {
        notes.push(`codex skill written to ${renderSkillInto(codexSkillDirRaw())}`);
        succeeded.codex = true;
      }
      if (selected.kimi) {
        notes.push(`kimi skill written to ${renderSkillInto(kimiSkillDirRaw())}`);
        succeeded.kimi = true;
      }
    } catch (err) {
      failures.push(err.message);
    }
  }

  if (selected.claude) {
    if (!det.claude.binary) {
      if (parsed.explicit) {
        failures.push('claude: CLI not found on PATH; install Claude Code first');
      } else {
        notes.push('claude: config home found but CLI not on PATH; skipping (pass --claude to force)');
      }
    } else if (command === 'update') {
      runClaude(['plugin', 'marketplace', 'update', MARKETPLACE_NAME]); // best-effort refresh
      if (runClaude(['plugin', 'update', PLUGIN_REF])) {
        notes.push('claude: plugin updated (restart Claude Code to apply)');
        succeeded.claude = true;
      } else {
        failures.push(`claude: 'claude plugin update ${PLUGIN_REF}' failed`);
      }
    } else {
      if (!runClaude(['plugin', 'marketplace', 'add', MARKETPLACE])) {
        notes.push('claude: marketplace add reported a problem (may already be registered); trying install anyway');
      }
      if (runClaude(['plugin', 'install', PLUGIN_REF])) {
        notes.push('claude: plugin installed from the marketplace (restart Claude Code to apply)');
        succeeded.claude = true;
      } else {
        failures.push(
          `claude: marketplace install failed; try 'claude plugin marketplace add ${MARKETPLACE}' then 'claude plugin install ${PLUGIN_REF}'`
        );
      }
    }
  }

  for (const n of notes) console.log(`duet-agents: ${n}`);
  for (const f of failures) console.error(`duet-agents: ${f}`);

  if (!succeeded.claude && !succeeded.codex && !succeeded.kimi && failures.length === 0) {
    console.error(
      'duet-agents: nothing was installed — every detected harness was skipped ' +
        '(config home without its CLI). Pass --claude, --codex, and/or --kimi to select explicitly.'
    );
    process.exit(1);
  }

  if (failures.length === 0) {
    console.log('');
    console.log('Restart each CLI, then start a session from any of them:');
    const shell = IS_WIN ? 'psmux new-session -s duet --' : 'tmux new-session';
    if (succeeded.claude) console.log(`  Claude Code:  ${shell} claude   then  /duet:duet`);
    if (succeeded.codex) console.log(`  Codex:        ${shell} codex    then  $duet (or pick duet from /skills)`);
    if (succeeded.kimi) console.log(`  Kimi:         ${shell} kimi     then  /skill:duet`);
  }
  process.exit(failures.length ? 1 : 0);
}

main();
