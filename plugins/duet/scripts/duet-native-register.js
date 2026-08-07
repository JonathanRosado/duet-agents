#!/usr/bin/env node
/*
 * Exact harness-native session registration.
 *
 * Codex and Kimi do not let Duet choose a fresh session id. Their
 * SessionStart hooks invoke this helper inside the spawned CLI process tree;
 * the hook JSON supplies the authoritative session id while pane-scoped
 * environment variables bind it to one Duet roster member. Claude uses the
 * same helper to expose its documented SessionStart id to later Bash tools.
 *
 * With no subcommand, read one hook event from stdin and (when Duet
 * registration variables are present) atomically publish a small JSON record.
 * `verify` is used by duet-init.sh to validate that record without parsing
 * untrusted JSON in shell. `install-kimi-hook` and `uninstall-kimi-hook`
 * manage only Duet's ownership-marked, otherwise inert Kimi config block.
 * `trust-kimi-workspace` publishes the same path-keyed trust document Kimi
 * writes after its startup dialog, so a spawned worker cannot consume its
 * first Duet prompt in that dialog.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const BEGIN = '# DUET-AGENTS:BEGIN kimi-session-hook';
const END = '# DUET-AGENTS:END kimi-session-hook';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const KIMI_RE =
  /^session_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const NAME_RE = /^[A-Za-z0-9_-]+$/;
const PANE_RE = /^%[0-9]+$/;

function die(message) {
  process.stderr.write(`duet: native registration: ${message}\n`);
  process.exit(1);
}

function normalizeId(harness, value) {
  let id = String(value || '').toLowerCase();
  if (harness === 'kimi' && UUID_RE.test(id)) id = `session_${id}`;
  return id;
}

function validId(harness, id) {
  return harness === 'kimi' ? KIMI_RE.test(id) : UUID_RE.test(id);
}

function readStdin() {
  return fs.readFileSync(0, 'utf8');
}

function atomicWrite(file, text, mode = 0o600) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = path.join(
    dir,
    `.duet-native.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}`
  );
  try {
    fs.writeFileSync(tmp, text, { encoding: 'utf8', mode, flag: 'wx' });
    fs.renameSync(tmp, file);
    try {
      fs.chmodSync(file, mode);
    } catch (_) {
      // The atomic contents and ownership checks matter; chmod is best effort
      // on filesystems that do not implement POSIX modes.
    }
  } finally {
    try {
      fs.unlinkSync(tmp);
    } catch (_) {
      // Already renamed or never created.
    }
  }
}

function shellSingleQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

function exposeClaudeSession(event) {
  const envFile = process.env.CLAUDE_ENV_FILE;
  if (!envFile || !UUID_RE.test(String(event.session_id || '').toLowerCase())) return;
  const id = String(event.session_id).toLowerCase();
  fs.appendFileSync(envFile, `export CLAUDE_CODE_SESSION_ID=${shellSingleQuote(id)}\n`, {
    encoding: 'utf8',
  });
}

function invalidatePublishedPairing(registrationFile, oldId, newId) {
  if (!oldId || oldId === newId) return;
  const sessionDir = path.dirname(path.dirname(registrationFile));
  const expectedConfig = path.join(sessionDir, 'duet.env');
  if (path.resolve(process.env.DUET_CONFIG || '') !== path.resolve(expectedConfig)) return;
  const marker = path.join(sessionDir, 'pairing.complete');
  try {
    fs.unlinkSync(marker);
    atomicWrite(
      path.join(sessionDir, 'pairing.invalidated'),
      `native session changed from ${oldId} to ${newId}\n`
    );
  } catch (err) {
    if (err && err.code !== 'ENOENT') {
      process.stderr.write(
        `duet: native registration: could not invalidate stale pairing: ${err.message}\n`
      );
    }
  }
}

function registerHookEvent() {
  let event;
  try {
    event = JSON.parse(readStdin());
  } catch (_) {
    die('hook stdin is not one JSON object');
  }

  if (event.hook_event_name !== 'SessionStart') return;
  exposeClaudeSession(event);

  const file = process.env.DUET_NATIVE_REGISTRATION_FILE || '';
  if (!file) return; // Ordinary, non-Duet Kimi/Claude/Codex session.

  const harness = process.env.DUET_NATIVE_REGISTRATION_HARNESS || '';
  const name = process.env.DUET_NATIVE_REGISTRATION_NAME || '';
  const nonce = process.env.DUET_NATIVE_REGISTRATION_NONCE || '';
  const duetSession = process.env.DUET_SESSION || '';
  const duetConfig = process.env.DUET_CONFIG || '';
  const self = process.env.DUET_SELF || '';
  const pane = process.env.TMUX_PANE || '';
  const source = String(event.source || '');
  const cwd = String(event.cwd || '');
  const nativeId = normalizeId(harness, event.session_id);

  if (!['claude', 'codex', 'kimi'].includes(harness)) die('unsupported harness');
  if (!NAME_RE.test(name) || self !== name) die('member identity is missing or inconsistent');
  if (!NAME_RE.test(duetSession)) die('Duet session id is missing or invalid');
  if (!nonce || nonce.length > 256 || /[\0\r\n\t]/.test(nonce)) die('nonce is invalid');
  if (!PANE_RE.test(pane)) die('TMUX_PANE is missing or invalid');
  if (!path.isAbsolute(file) || !path.isAbsolute(duetConfig)) die('paths must be absolute');
  const sessionDir = path.dirname(duetConfig);
  if (path.basename(duetConfig) !== 'duet.env') die('DUET_CONFIG is not a duet.env path');
  if (path.basename(sessionDir) !== duetSession) die('Duet config/session mismatch');
  if (
    path.resolve(path.dirname(file)) !==
    path.resolve(path.join(sessionDir, 'native-registration'))
  ) {
    die('registration file is outside this Duet session');
  }
  if (!['startup', 'resume'].includes(source)) die('unexpected SessionStart source');
  if (!validId(harness, nativeId)) die('native session id has an invalid shape');
  if (!path.isAbsolute(cwd) || /[\0\r\n\t]/.test(cwd)) die('hook cwd is invalid');

  const expected = normalizeId(harness, process.env.DUET_NATIVE_EXPECTED_ID || '');
  if (expected && !validId(harness, expected)) die('expected native id has an invalid shape');

  let previous = null;
  try {
    previous = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    if (err && err.code !== 'ENOENT') die('existing registration is not valid JSON');
  }
  if (previous) invalidatePublishedPairing(file, previous.native_id, nativeId);

  const record = {
    version: 1,
    hook_event_name: 'SessionStart',
    source,
    harness,
    name,
    nonce,
    duet_session: duetSession,
    pane_id: pane,
    // Each configured command uses `exec node`, so the hook process's parent
    // is the CLI process that tmux records as #{pane_pid}.
    pane_pid: process.ppid,
    cwd: path.resolve(cwd),
    native_id: nativeId,
    expected_native_id: expected,
    recorded_at: new Date().toISOString(),
  };
  atomicWrite(file, `${JSON.stringify(record)}\n`);
}

function verifyRegistration(argv) {
  if (argv.length !== 8) {
    die(
      'verify requires file, harness, name, nonce, duet-session, pane, pane-pid, workdir, and optional expected id'
    );
  }
  const [file, harness, name, nonce, duetSession, pane, panePid, workdir] = argv;
  const expected = normalizeId(harness, process.env.DUET_NATIVE_EXPECTED_ID || '');
  let record;
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) die('registration is not a regular file');
    record = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    if (err && err.code === 'ENOENT') process.exit(1);
    die('registration cannot be read or parsed');
  }
  const id = normalizeId(harness, record.native_id);
  const ok =
    record.version === 1 &&
    record.hook_event_name === 'SessionStart' &&
    ['startup', 'resume'].includes(record.source) &&
    record.harness === harness &&
    record.name === name &&
    record.nonce === nonce &&
    record.duet_session === duetSession &&
    record.pane_id === pane &&
    String(record.pane_pid) === String(panePid) &&
    path.resolve(String(record.cwd || '')) === path.resolve(workdir) &&
    validId(harness, id) &&
    (!expected || id === expected);
  if (!ok) process.exit(1);
  process.stdout.write(`${id}\t${record.source}\n`);
}

function kimiHome() {
  return process.env.KIMI_CODE_HOME || path.join(os.homedir(), '.kimi-code');
}

function kimiHookBlock() {
  const command =
    process.platform === 'win32'
      ? 'if defined DUET_NATIVE_REGISTRATION_HELPER node "%DUET_NATIVE_REGISTRATION_HELPER%"'
      : 'test -z "$DUET_NATIVE_REGISTRATION_HELPER" || exec node "$DUET_NATIVE_REGISTRATION_HELPER"';
  return `${BEGIN}
[[hooks]]
event = "SessionStart"
matcher = "^(startup|resume)$"
command = '${command}'
timeout = 5
${END}`;
}

function kimiWorkdirKey(workDir) {
  const normalized = workDir.replace(/\\/g, '/').replace(/\/+$/, '');
  let slug = (normalized.split('/').pop() || normalized)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/^-+|-+$/g, '');
  if (!slug || slug === '.' || slug === '..') slug = 'workspace';
  const hash = crypto.createHash('sha256').update(normalized).digest('hex').slice(0, 12);
  return `wd_${slug}_${hash}`;
}

function readKimiTrustFile(file, expectedRoot) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    configError('Kimi workspace trust record is not a regular file');
  }
  let record;
  try {
    record = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    configError('Kimi workspace trust record is invalid JSON');
  }
  if (
    !record ||
    record.root !== expectedRoot ||
    !Number.isSafeInteger(record.trustedAt) ||
    record.trustedAt <= 0
  ) {
    configError('Kimi workspace trust record does not match this workdir');
  }
}

function trustKimiWorkspace(argv) {
  if (argv.length !== 1) die('trust-kimi-workspace requires one absolute workdir');
  const requested = String(argv[0] || '');
  if (!path.isAbsolute(requested) || /[\0\r\n\t]/.test(requested)) {
    die('Kimi workdir is not a safe absolute path');
  }
  const rootStat = fs.lstatSync(requested);
  if (!rootStat.isDirectory()) die('Kimi workdir is not a directory');
  const root = fs.realpathSync(requested);
  if (root === path.parse(root).root) die('refusing to trust a filesystem root');

  fs.mkdirSync(kimiHome(), { recursive: true, mode: 0o700 });
  const home = fs.realpathSync(kimiHome());
  const scope = path.join(home, 'workspace-trust');
  try {
    const stat = fs.lstatSync(scope);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      configError('Kimi workspace-trust scope is not a real directory');
    }
  } catch (err) {
    if (!err || err.code !== 'ENOENT') throw err;
    try {
      fs.mkdirSync(scope, { mode: 0o700 });
    } catch (mkdirErr) {
      if (!mkdirErr || mkdirErr.code !== 'EEXIST') throw mkdirErr;
    }
    const stat = fs.lstatSync(scope);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      configError('Kimi workspace-trust scope is not a real directory');
    }
  }

  const file = path.join(scope, kimiWorkdirKey(root));
  try {
    readKimiTrustFile(file, root);
    return;
  } catch (err) {
    if (!err || err.code !== 'ENOENT') throw err;
  }

  const tmp = path.join(
    scope,
    `.duet-workspace-trust.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}`
  );
  try {
    fs.writeFileSync(
      tmp,
      `${JSON.stringify({ root, trustedAt: Date.now() })}\n`,
      { encoding: 'utf8', mode: 0o600, flag: 'wx' }
    );
    try {
      // Hard-link publication is no-overwrite and atomic. A concurrent Kimi
      // or Duet process may win; validate its complete record below.
      fs.linkSync(tmp, file);
    } catch (err) {
      if (!err || err.code !== 'EEXIST') throw err;
    }
    readKimiTrustFile(file, root);
    try {
      fs.chmodSync(file, 0o600);
    } catch (_) {}
  } finally {
    try {
      fs.unlinkSync(tmp);
    } catch (_) {}
  }
}

function sleepSync(milliseconds) {
  const cell = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(cell, 0, 0, milliseconds);
}

function configError(message) {
  throw new Error(message);
}

function acquireConfigLock(lock) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      fs.mkdirSync(lock, { mode: 0o700 });
      return;
    } catch (err) {
      if (!err || err.code !== 'EEXIST') throw err;
      sleepSync(50);
    }
  }
  configError('timed out waiting for the Kimi hook config lock');
}

function splitOwnedBlock(text) {
  const lines = text.split(/\n/);
  const begin = [];
  const end = [];
  lines.forEach((line, i) => {
    if (line === BEGIN) begin.push(i);
    if (line === END) end.push(i);
  });
  if (begin.length !== end.length || begin.length > 1) {
    configError('Kimi config has unmatched or duplicate Duet hook ownership markers');
  }
  if (!begin.length) return { without: text.replace(/\s*$/, ''), present: false };
  if (begin[0] >= end[0]) configError('Kimi hook ownership markers are out of order');
  const kept = lines.slice(0, begin[0]).concat(lines.slice(end[0] + 1));
  return { without: kept.join('\n').replace(/\s*$/, ''), present: true };
}

function updateKimiHook(install) {
  const home = path.resolve(kimiHome());
  const config = path.join(home, 'config.toml');
  const lock = path.join(home, '.duet-kimi-hook.lock');
  fs.mkdirSync(home, { recursive: true });
  acquireConfigLock(lock);
  try {
    let original = '';
    let mode = 0o600;
    try {
      const stat = fs.lstatSync(config);
      if (!stat.isFile() || stat.isSymbolicLink()) {
        configError('Kimi config is not a regular file');
      }
      mode = stat.mode & 0o777;
      original = fs.readFileSync(config, 'utf8');
    } catch (err) {
      if (err && err.code !== 'ENOENT') throw err;
    }
    const owned = splitOwnedBlock(original);
    let candidate = owned.without;
    if (install) candidate = `${candidate}${candidate ? '\n\n' : ''}${kimiHookBlock()}`;
    candidate = candidate ? `${candidate}\n` : '';
    if (candidate === original) return;

    const tmpDir = fs.mkdtempSync(path.join(home, '.duet-kimi-hook-'));
    const tmp = path.join(tmpDir, 'config.toml');
    try {
      fs.writeFileSync(tmp, candidate, { encoding: 'utf8', mode });
      if (install) {
        const doctor = spawnSync('kimi', ['doctor', 'config', tmp], {
          stdio: ['ignore', 'pipe', 'pipe'],
          encoding: 'utf8',
        });
        if (doctor.status !== 0) {
          const detail = String(doctor.stderr || doctor.stdout || '').trim().split('\n')[0];
          configError(`Kimi rejected the updated hook config${detail ? `: ${detail}` : ''}`);
        }
      }
      // A foreign editor does not know our lock. Refuse an observed
      // concurrent change instead of replacing it with our stale snapshot.
      let current = '';
      try {
        const currentStat = fs.lstatSync(config);
        if (!currentStat.isFile() || currentStat.isSymbolicLink()) {
          configError('Kimi config changed type while the hook update was staged');
        }
        current = fs.readFileSync(config, 'utf8');
      } catch (err) {
        if (err && err.code !== 'ENOENT') throw err;
      }
      if (current !== original) {
        configError('Kimi config changed concurrently; retry the operation');
      }
      fs.renameSync(tmp, config);
      try {
        fs.chmodSync(config, mode);
      } catch (_) {
        // Best effort on non-POSIX filesystems.
      }
    } finally {
      try {
        fs.unlinkSync(tmp);
      } catch (_) {}
      try {
        fs.rmdirSync(tmpDir);
      } catch (_) {}
    }
  } finally {
    try {
      fs.rmdirSync(lock);
    } catch (_) {}
  }
}

const command = process.argv[2] || '';
if (command === 'verify') verifyRegistration(process.argv.slice(3));
else if (command === 'trust-kimi-workspace') {
  try {
    trustKimiWorkspace(process.argv.slice(3));
  } catch (err) {
    die(err && err.message ? err.message : String(err));
  }
}
else if (command === 'install-kimi-hook' || command === 'uninstall-kimi-hook') {
  try {
    updateKimiHook(command === 'install-kimi-hook');
  } catch (err) {
    die(err && err.message ? err.message : String(err));
  }
}
else if (command) die(`unknown subcommand '${command}'`);
else registerHookEvent();
