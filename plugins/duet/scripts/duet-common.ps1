Set-StrictMode -Version 2.0

# =============================================================================
# Shared helpers for the Windows/psmux duet v4 mesh.
#
# Windows-native equivalents of the Bash/tmux v4 primitives:
#   * atomic publish  -> MoveFileEx(REPLACE_EXISTING|WRITE_THROUGH) + owner-first
#                        claim-dir publish for locks (no ownerless generation).
#   * advisory locks  -> directory-mkdir + Directory.Move publish + stale reaper.
#   * process liveness-> Get-Process existence (analogue of kill -0).
#   * base64/awk/sed  -> native .NET / PowerShell string ops.
#
# psmux fencing (verified against psmux 3.3.6 == tmux 3.3.6):
#   * ONE global session registry; `-S <socket>` does NOT isolate servers, so we
#     never fence by socket and never call kill-server.
#   * Pane IDs (%N) are NOT unique across sessions; pane *indices* renumber when
#     a sibling dies; `list-panes -t <session>` is WINDOW-local. So the durable
#     identity of a member is the tuple { session_name, backend server pid,
#     bare pane_id, pane_pid }, discovered via `list-panes -a` (spans all windows
#     and sessions) and filtered on the full tuple.
#   * The stable session-scoped command target is "<session>:<pane_id>"
#     (e.g. "1:%4"); it survives index renumbering and cannot collide.
#   * Caller-pane identity is resolved by PROCESS ANCESTRY (our process is a
#     descendant of its pane's pane_pid), never by a bare -t pane target and
#     never by the ambient/active pane.
# =============================================================================

# --- Send-DuetVerified result codes (mirror duet-common.sh) ------------------
$global:DUET_SEND_OK                = 0
$global:DUET_SEND_DEAD              = 20
$global:DUET_SEND_NOT_LANDED        = 21
$global:DUET_SEND_LANDED_UNVERIFIED = 22

# Send-DuetControlPaste outcomes. The distinction is load-bearing for A2: only a
# PREWRITE_FAILED proves no bytes were sent (safe to repaste); an uncertain wire
# write must never be repasted.
$global:DUET_PASTE_PREWRITE_FAILED = 'PREWRITE_FAILED'
$global:DUET_PASTE_WIRE_SENT       = 'WIRE_SENT'
$global:DUET_PASTE_UNCERTAIN       = 'WRITE_OR_ACK_UNCERTAIN'

$global:DUET_LOCK_TOKEN = "{0}-{1}-{2}" -f $PID, (Get-Random), (Get-Random)

# --- native atomic rename ----------------------------------------------------
if (-not ('Duet.Native' -as [type])) {
  Add-Type -Namespace Duet -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
'@
}
$global:DUET_MOVEFILE_REPLACE_EXISTING = 0x1
$global:DUET_MOVEFILE_WRITE_THROUGH    = 0x8

# Initialize optional out-variable / session globals so StrictMode reads never
# throw before they are populated. Guarded so re-dot-sourcing never clobbers a
# live value already set (e.g. by Set-DuetSessionVariables).
foreach ($__duetGlobal in @(
    'DUET_PSMUX_PATH', 'DUET_PSMUX_RC', 'DUET_PSMUX_SESSION', 'DUET_PSMUX_SERVER_PID',
    'DUET_PSMUX_REGISTRY', 'DUET_PSMUX_NAMESPACE',
    'DUET_RESOLVED_CONFIG',
    'DUET_CALLER_SESSION', 'DUET_CALLER_PANE', 'DUET_CALLER_PANE_PID',
    'DUET_CALLER_SERVER_PID', 'DUET_CALLER_NAME', 'DUET_CALLER_NAMESPACE', 'DUET_CALLER_REGISTRY',
    'DUET_ENQUEUED_ID', 'DUET_ENQUEUED_FILE',
    'DUET_SEQUENCE', 'DUET_MESSAGE_ID', 'DUET_MESSAGE_SESSION', 'DUET_MESSAGE_MODE',
    'DUET_MESSAGE_SENDER', 'DUET_MESSAGE_RECIPIENT', 'DUET_MESSAGE_BODY',
    'DUET_DIR', 'DUET_STATE_ROOT', 'WORKDIR', 'PLUGIN_DIR',
    'DUET_SESSION', 'DUET_SESSION_ID', 'DUET_INITIATOR', 'DUET_INITIATOR_PANE',
    'DUET_CONFIG_VALID', 'DUET_ROSTER_VALID')) {
  if (-not (Test-Path -LiteralPath ("Variable:global:" + $__duetGlobal))) {
    Set-Variable -Name $__duetGlobal -Scope Global -Value $null
  }
}
Remove-Variable __duetGlobal -ErrorAction SilentlyContinue
# Process-local map of held reaper mutexes (name -> Mutex). Guarded so a
# re-dot-source between lock calls never drops a live handle.
if (-not (Test-Path -LiteralPath 'Variable:global:DuetMutexMap')) { $global:DuetMutexMap = @{} }

# =============================================================================
# psmux discovery + invocation
# =============================================================================

function Get-DuetPsmux {
  if ($global:DUET_PSMUX_PATH -and (Test-Path -LiteralPath $global:DUET_PSMUX_PATH)) {
    return $global:DUET_PSMUX_PATH
  }
  $cmd = Get-Command psmux -ErrorAction SilentlyContinue
  if (-not $cmd) { $cmd = Get-Command tmux -ErrorAction SilentlyContinue }
  if (-not $cmd) { throw "duet: psmux not found on PATH" }
  $global:DUET_PSMUX_PATH = $cmd.Source
  return $cmd.Source
}

# Run psmux and return stdout lines (stderr discarded). No -S (psmux ignores it).
# For a namespaced session, prepend global `-L <namespace>` -- env pinning ALONE
# is overwritten whenever an explicit `-t session:` is parsed (main.rs:220-260),
# and a namespaced session is invisible without -L. PSMUX_TARGET_SESSION is also
# pinned to the registry base as defense. No namespace/registry -> prior behavior.
function Invoke-DuetPsmux {
  # Deliberately use the automatic $args array instead of a catch-all parameter.
  # PowerShell treats native-looking `-p` / `-t` tokens as parameter syntax and
  # either abbreviates or drops them when any param block is present.
  $__DuetArgv = @($args)
  # psmux legitimately errors (e.g. a gone session) and writes to stderr; that
  # must be an rc, never a throw, regardless of the caller's $ErrorActionPreference.
  $ErrorActionPreference = 'Continue'
  $psmux = Get-DuetPsmux
  $ns = $global:DUET_PSMUX_NAMESPACE
  $reg = $global:DUET_PSMUX_REGISTRY
  $finalArgs = if ($ns) { @('-L', $ns) + $__DuetArgv } else { $__DuetArgv }
  if ($reg) {
    $savedTS = $env:PSMUX_TARGET_SESSION
    $env:PSMUX_TARGET_SESSION = $reg
    try {
      $out = & $psmux @finalArgs 2>$null
      $global:DUET_PSMUX_RC = $LASTEXITCODE
    }
    finally { $env:PSMUX_TARGET_SESSION = $savedTS }
    return $out
  }
  $out = & $psmux @finalArgs 2>$null
  $global:DUET_PSMUX_RC = $LASTEXITCODE
  return $out
}

# Safe psmux session / registry-base / namespace name. Dotted names are valid
# (cli.rs:580); forbid path separators, colon, pipe, control chars, and traversal.
function Test-DuetSafeName {
  param([string]$Name)
  if (-not $Name) { return $false }
  if ($Name -notmatch '^[A-Za-z0-9._-]+$') { return $false }
  if ($Name -match '\.\.') { return $false }
  return $true
}

# Resolve an executable to an ABSOLUTE path against the current process PATH and,
# if not found there, the live Machine + User PATH. The long-lived psmux server
# process can carry a stale PATH that predates a harness install (e.g. Kimi), so
# panes must be launched by absolute path. Returns $null when unresolved.
function Resolve-DuetExecutable {
  param([string]$Name)
  if (-not $Name) { return $null }
  $cmd = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
  if ($cmd.Count -gt 0) { return $cmd[0].Source }
  $dirs = @()
  foreach ($scope in @('Machine', 'User')) {
    $p = [Environment]::GetEnvironmentVariable('Path', $scope)
    if ($p) { $dirs += ($p -split ';') }
  }
  $exts = @('.exe', '.cmd', '.bat', '.com', '')
  foreach ($dir in ($dirs | Where-Object { $_ })) {
    foreach ($ext in $exts) {
      $cand = Join-Path $dir ($Name + $ext)
      if (Test-Path -LiteralPath $cand -PathType Leaf) { return (Get-DuetCanonicalPath $cand) }
    }
  }
  return $null
}

# =============================================================================
# Time / temp / IO primitives
# =============================================================================

function Get-DuetUnixTime { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Get-DuetUtcStamp { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# Persisted protocol counters are bounded to the D10 space used by queue
# sequencing. Regex-only validation is insufficient: casting a hostile
# 1000-digit string throws before a caller can fail closed.
function ConvertFrom-DuetDecimal {
  param([AllowEmptyString()][AllowNull()][string]$Value, [uint64]$Maximum = 9999999999, [switch]$AllowLeadingZeros)
  $pattern = if ($AllowLeadingZeros) { '^[0-9]+$' } else { '^(0|[1-9][0-9]*)$' }
  if ($null -eq $Value -or $Value -notmatch $pattern) { return $null }
  [uint64]$parsed = 0
  if (-not [uint64]::TryParse($Value, [ref]$parsed) -or $parsed -gt $Maximum) { return $null }
  return $parsed
}

# Single-quote a string as a PowerShell string literal (double any embedded quote)
# so a path/argument containing spaces, $, ; or parens survives being embedded in a
# command string that psmux's outer -Command re-tokenizes. Returns '' for $null.
function ConvertTo-DuetPsLiteral {
  param([AllowEmptyString()][AllowNull()][string]$Value)
  if ($null -eq $Value) { $Value = '' }
  return "'" + $Value.Replace("'", "''") + "'"
}

# Encode a PowerShell command as UTF-16LE for powershell.exe -EncodedCommand.
# The resulting ASCII token is safe to copy through PowerShell, cmd, or Bash.
function ConvertTo-DuetPowerShellEncodedCommand {
  param([AllowEmptyString()][AllowNull()][string]$Command)
  if ($null -eq $Command) { $Command = '' }
  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

# A collision-resistant, filesystem-safe session id. The random suffix also
# prevents two init processes in the same millisecond from choosing one path.
function New-DuetSessionId {
  return ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
}

# Diagnostics go to real stderr (like bash `>&2`). Never Write-Error from the
# library: under a caller's $ErrorActionPreference='Stop' that becomes a
# terminating throw and defeats the return-$false failure contract.
function Write-DuetError { param([AllowEmptyString()][string]$Message) [Console]::Error.WriteLine($Message) }

function New-DuetTempFile {
  param([Parameter(Mandatory = $true)][string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
  for ($i = 0; $i -lt 20; $i++) {
    $path = Join-Path $Dir ('.duettmp-' + [System.IO.Path]::GetRandomFileName())
    try {
      $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
      $fs.Close(); return $path
    } catch { }
  }
  throw "duet: could not create a temp file in $Dir"
}

function Move-DuetFileAtomic {
  # NTFS-atomic replace-or-create rename for mutable counters and markers.
  # Refuses when the destination is a directory.
  param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
  if (Test-Path -LiteralPath $Destination -PathType Container) { return $false }
  $flags = $global:DUET_MOVEFILE_REPLACE_EXISTING -bor $global:DUET_MOVEFILE_WRITE_THROUGH
  if (-not [Duet.Native]::MoveFileEx($Source, $Destination, $flags)) { return $false }
  return ((Test-Path -LiteralPath $Destination -PathType Leaf) -and -not (Test-Path -LiteralPath $Destination -PathType Container))
}

# NO-REPLACE atomic move for IMMUTABLE publish (queue message final names) and
# terminal moves. [IO.File]::Move throws if the destination exists, so there is
# no Test-Path + replace TOCTOU that could silently overwrite a record.
function Move-DuetFileNoReplace {
  param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
  try { [System.IO.File]::Move($Source, $Destination) } catch { return $false }
  return (Test-Path -LiteralPath $Destination -PathType Leaf)
}

function Publish-DuetTempFile {
  param([Parameter(Mandatory = $true)][string]$Temp, [Parameter(Mandatory = $true)][string]$Destination)
  if (-not (Test-Path -LiteralPath $Temp -PathType Leaf)) { return $false }
  if (Test-Path -LiteralPath $Destination -PathType Container) { return $false }
  if (Move-DuetFileAtomic -Source $Temp -Destination $Destination) { return $true }
  try { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue } catch { }
  return $false
}

function Write-DuetUtf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value, [switch]$Append)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if ($Append) { [System.IO.File]::AppendAllText($Path, $Value, $encoding) }
  else { [System.IO.File]::WriteAllText($Path, $Value, $encoding) }
}

# Atomic write of a value with a trailing LF (embedded newlines preserved).
function Write-DuetAtomicMultiline {
  param([string]$Path, [AllowEmptyString()][string]$Value)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = New-DuetTempFile -Dir $dir
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, ($Value + "`n"), $enc)
    return (Publish-DuetTempFile -Temp $tmp -Destination $Path)
  } catch { try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }; return $false }
}
Set-Alias -Name Write-DuetAtomic -Value Write-DuetAtomicMultiline -Scope Global

function Get-DuetFileText {
  param([string]$Path)
  if (-not $Path) { return $null }
  # A lock directory can be renamed or removed between namespace probes. On
  # Windows, Test-Path may surface that race as UnauthorizedAccessException.
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
  } catch { return $null }
}

function Get-DuetFirstLineValue {
  # First row whose tab-separated key column equals $Key -> its value column.
  param([string]$Path, [string]$Key)
  $text = Get-DuetFileText $Path
  if ($null -eq $text) { return $null }
  foreach ($line in ($text -split "`r?`n")) {
    if (-not $line) { continue }
    $parts = $line -split "`t", 2
    if ($parts[0] -eq $Key) { if ($parts.Count -gt 1) { return $parts[1] } else { return '' } }
  }
  return $null
}

function Test-DuetProcessAlive {
  param($ProcessId)
  $n = 0
  if (-not [int]::TryParse([string]$ProcessId, [ref]$n)) { return $false }
  if ($n -le 0) { return $false }
  try { $null = Get-Process -Id $n -ErrorAction Stop; return $true } catch { return $false }
}

function Get-DuetProcessParentMap {
  $map = @{}
  foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    $map[[int]$p.ProcessId] = [int]$p.ParentProcessId
  }
  return $map
}

# =============================================================================
# Advisory locks (owner-first claim-dir publish; stale-owner reaper)  (A1)
# =============================================================================

function Get-DuetLockOwner { param([string]$Lock); return (Get-DuetFileText (Join-Path $Lock 'owner')) }
function Get-DuetLockOwnerPid {
  param([string]$Lock)
  $owner = Get-DuetLockOwner $Lock
  if (-not $owner) { return '' }
  return (($owner -split "`t", 2)[0]).Trim()
}

function Get-DuetMutexName {
  param([string]$Lock)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Lock.ToLowerInvariant()))) | ForEach-Object { $_.ToString('x2') }) -join '' }
  finally { $sha.Dispose() }
  return ('Local\duet-reaper-' + $h.Substring(0, 40))
}

# Serialize stale-lock recovery with a NAMED KERNEL MUTEX. The kernel releases it
# automatically when the holder dies, so a crashed reaper can never deadlock
# future recovery (AbandonedMutexException on the next waiter == we now own it).
# The old public-directory marker had no owner and no crash release -- see review.
function Lock-DuetReaperAcquire {
  param([string]$Lock, [int]$TimeoutMs = 2000)
  $name = Get-DuetMutexName $Lock
  $m = New-Object System.Threading.Mutex($false, $name)
  $acquired = $false
  try { $acquired = $m.WaitOne($TimeoutMs) }
  catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { $m.Dispose(); return $false }
  $global:DuetMutexMap[$name] = $m
  return $true
}
function Lock-DuetReaperRelease {
  param([string]$Lock)
  $name = Get-DuetMutexName $Lock
  if ($global:DuetMutexMap.ContainsKey($name)) {
    $m = $global:DuetMutexMap[$name]
    try { $m.ReleaseMutex() } catch { }
    try { $m.Dispose() } catch { }
    $global:DuetMutexMap.Remove($name)
  }
}

function Lock-DuetAcquire {
  # Owner is written INSIDE a private claim dir, then the populated claim is
  # atomically published (Directory.Move) to the canonical path -- so the lock
  # is never observable without an owner (fixes the A1 ownerless-publication race).
  param([string]$Lock, [int]$Attempts = 200)
  $token = $global:DUET_LOCK_TOKEN
  $claim = "$Lock.claim-$PID-$(Get-Random)-$(Get-Random)"
  try { New-Item -ItemType Directory -Path $claim -ErrorAction Stop | Out-Null } catch { return $false }
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $claim 'owner'), ("{0}`t{1}`n" -f $PID, $token), $enc)
  } catch {
    try { Remove-Item -LiteralPath $claim -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    return $false
  }
  try {
    for ($i = 0; $i -lt $Attempts; $i++) {
      try { [System.IO.Directory]::Move($claim, $Lock); return $true } catch { }
      $heldPid = Get-DuetLockOwnerPid $Lock
      if ($heldPid -and -not (Test-DuetProcessAlive $heldPid)) {
        if (Lock-DuetReaperAcquire $Lock 2000) {
          try {
            $heldPid = Get-DuetLockOwnerPid $Lock
            if ($heldPid -and -not (Test-DuetProcessAlive $heldPid)) {
              # Take the dead generation aside atomically, then remove it. A
              # concurrent fresh publish to the now-free canonical path is safe.
              $stale = "$Lock.stale-$PID-$(Get-Random)"
              $moved = $false
              try { [System.IO.Directory]::Move($Lock, $stale); $moved = $true } catch { }
              if ($moved) { try { Remove-Item -LiteralPath $stale -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
            }
          } finally { Lock-DuetReaperRelease $Lock }
          continue
        }
      }
      Start-Sleep -Milliseconds 50
    }
    Write-DuetError "duet: timed out acquiring lock $Lock"
    return $false
  } finally {
    if (Test-Path -LiteralPath $claim) {
      try { Remove-Item -LiteralPath $claim -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
  }
}

function Unlock-DuetRelease {
  param([string]$Lock)
  $owner = Get-DuetLockOwner $Lock
  if ($null -eq $owner) { return $false }
  $held = $owner -split "`t", 2
  $heldToken = if ($held.Count -gt 1) { $held[1].TrimEnd("`r", "`n") } else { '' }
  if ($heldToken -ne $global:DUET_LOCK_TOKEN) { return $false }
  try { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction Stop; return $true } catch { return $false }
}

# =============================================================================
# Session config: parse / resolve / validate  (A7 / A8 pinning + fencing)
# duet.env is a KEY=VALUE data file -- parsed here, never dot-sourced as code.
# =============================================================================

function Import-DuetConfig {
  param([string]$Path)
  $global:DUET_CONFIG_VALID = $false
  $cfg = @{}
  $text = Get-DuetFileText $Path
  if ($null -eq $text) { return $cfg }
  $known = @('DUET_DIR', 'DUET_STATE_ROOT', 'WORKDIR', 'PLUGIN_DIR', 'DUET_PSMUX_SESSION',
    'DUET_PSMUX_SERVER_PID', 'DUET_PSMUX_REGISTRY', 'DUET_PSMUX_NAMESPACE', 'DUET_SESSION',
    'DUET_SESSION_ID', 'DUET_INITIATOR', 'DUET_INITIATOR_PANE')
  foreach ($line in ($text -split "`r?`n")) {
    if (-not $line -or $line.StartsWith('#')) { continue }
    $idx = $line.IndexOf('=')
    if ($idx -lt 1) { return @{} }
    $key = $line.Substring(0, $idx)
    $value = $line.Substring($idx + 1)
    if ($known -notcontains $key -or $cfg.ContainsKey($key) -or $value -match "[\t\r\n]") { return @{} }
    $cfg[$key] = $value
  }
  foreach ($key in $known) { if (-not $cfg.ContainsKey($key)) { return @{} } }
  $global:DUET_CONFIG_VALID = $true
  return $cfg
}

function Set-DuetSessionVariables {
  param([hashtable]$Config)
  foreach ($k in @('DUET_DIR', 'DUET_STATE_ROOT', 'WORKDIR', 'PLUGIN_DIR', 'DUET_SESSION',
      'DUET_SESSION_ID', 'DUET_INITIATOR', 'DUET_INITIATOR_PANE',
      'DUET_PSMUX_SESSION', 'DUET_PSMUX_SERVER_PID', 'DUET_PSMUX_REGISTRY', 'DUET_PSMUX_NAMESPACE')) {
    $val = if ($Config.ContainsKey($k)) { $Config[$k] } else { $null }
    Set-Variable -Name $k -Value $val -Scope Global
  }
}

function Get-DuetCanonicalPath {
  param([string]$Path)
  if (-not $Path) { return $null }
  try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath } catch { return $null }
}

function Test-DuetReparsePoint {
  param([string]$Path)
  if (-not $Path) { return $false }
  try { $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $false }
  return [bool]($it.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Walk the RAW supplied path upward (bounded at $StopAt) and report a reparse
# point on any existing component. Resolve-Path silently resolves through a
# junction/symlink, so canonicalized paths cannot reveal this -- inspect raw.
function Test-DuetPathChainHasReparse {
  param([string]$Path, [string]$StopAt)
  $cur = $Path
  $stop = if ($StopAt) { Get-DuetCanonicalPath $StopAt } else { $null }
  $seen = @{}
  while ($cur -and -not $seen[$cur]) {
    $seen[$cur] = $true
    if ((Test-Path -LiteralPath $cur) -and (Test-DuetReparsePoint $cur)) { return $true }
    if ($stop) { $c = Get-DuetCanonicalPath $cur; if ($c -and $c -eq $stop) { break } }
    $parent = Split-Path -Parent $cur
    if (-not $parent -or $parent -eq $cur) { break }
    $cur = $parent
  }
  return $false
}

function Test-DuetPathUnderRoot {
  param([string]$Child, [string]$Root)
  if (-not $Child -or -not $Root) { return $false }
  if ($Child.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  $sep = [IO.Path]::DirectorySeparatorChar
  return ($Child + $sep).StartsWith($Root + $sep, [StringComparison]::OrdinalIgnoreCase)
}

# Resolve exactly one absolute config. Mutation commands require DUET_CONFIG;
# read-only diagnostics pass that same absolute path explicitly. Session IDs,
# directories, current pointers, and newest-session scans are never routing
# inputs.
function Resolve-DuetConfig {
  param([string]$SessionArg, [int]$RequireEnvironment = 1)
  $global:DUET_RESOLVED_CONFIG = ''
  $envCfg = $env:DUET_CONFIG
  if ($RequireEnvironment -eq 1) {
    if (-not $envCfg) {
      Write-DuetError 'duet: DUET_CONFIG must name an absolute duet.env.'
      return $false
    }
    $cfg = $envCfg
    if ($SessionArg) {
      $argCanonical = Get-DuetCanonicalPath $SessionArg
      $envCanonical = Get-DuetCanonicalPath $envCfg
      if (-not $argCanonical -or -not $envCanonical -or
          -not $argCanonical.Equals($envCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        Write-DuetError 'duet: -Session disagrees with DUET_CONFIG.'
        return $false
      }
    }
  }
  else {
    if (-not $SessionArg) {
      Write-DuetError 'duet: an explicit absolute -Session duet.env is required.'
      return $false
    }
    $cfg = $SessionArg
  }

  if (-not [IO.Path]::IsPathRooted($cfg) -or (Split-Path -Leaf $cfg) -ne 'duet.env') {
    Write-DuetError 'duet: config must be an absolute path ending in duet.env.'
    return $false
  }
  if (-not (Test-Path -LiteralPath $cfg -PathType Leaf) -or (Test-DuetReparsePoint $cfg)) {
    Write-DuetError "duet: pinned session config does not exist or is a reparse point: $cfg"
    return $false
  }
  try { $full = [IO.Path]::GetFullPath($cfg) } catch { return $false }
  $canonical = Get-DuetCanonicalPath $cfg
  if (-not $canonical -or -not $full.Equals($canonical, [StringComparison]::OrdinalIgnoreCase)) {
    Write-DuetError "duet: config path must be canonical: $canonical"
    return $false
  }
  $global:DUET_RESOLVED_CONFIG = $canonical
  return $true
}

function Test-DuetLoadedSession {
  param([hashtable]$Config, [string]$ExpectedSession, [string]$ConfigPath)
  if ($null -eq $Config) { Write-DuetError "duet: session config is unavailable."; return $false }
  foreach ($required in @('DUET_DIR', 'DUET_STATE_ROOT', 'WORKDIR', 'PLUGIN_DIR', 'DUET_PSMUX_SESSION',
      'DUET_PSMUX_SERVER_PID', 'DUET_PSMUX_REGISTRY', 'DUET_PSMUX_NAMESPACE', 'DUET_SESSION',
      'DUET_SESSION_ID', 'DUET_INITIATOR', 'DUET_INITIATOR_PANE')) {
    if (-not $Config.ContainsKey($required)) { Write-DuetError "duet: config missing $required."; return $false }
  }
  $dir = $Config['DUET_DIR']; $sid = $Config['DUET_SESSION_ID']; $root = $Config['DUET_STATE_ROOT']
  if (-not $dir -or -not $sid -or -not $root) { Write-DuetError "duet: config missing DUET_DIR, DUET_STATE_ROOT, or DUET_SESSION_ID."; return $false }
  if ($sid -notmatch '^[A-Za-z0-9_-]+$') { Write-DuetError "duet: session id contains unsupported characters."; return $false }
  $workdir = $Config['WORKDIR']; $pluginDir = $Config['PLUGIN_DIR']
  $initiator = $Config['DUET_INITIATOR']; $initiatorPane = $Config['DUET_INITIATOR_PANE']
  if (-not $workdir -or -not $pluginDir -or -not $initiator -or -not $initiatorPane) {
    Write-DuetError "duet: config is missing a workdir, plugin, ownership, or initiator fence."; return $false
  }
  if (($dir + $root + $workdir + $pluginDir) -match "[\t\r\n]") { Write-DuetError "duet: session paths with TAB, CR, or LF are unsupported."; return $false }
  if ($initiator -notmatch '^[A-Za-z0-9_-]+$' -or $initiatorPane -notmatch '^%[0-9]+$') { Write-DuetError "duet: initiator identity is invalid."; return $false }
  # Reject reparse points on the RAW supplied paths BEFORE canonicalizing --
  # Resolve-Path silently resolves through a junction/symlink and hides it.
  if (Test-DuetReparsePoint $dir) { Write-DuetError "duet: session directory is a reparse point; refusing it."; return $false }
  if ($ConfigPath -and (Test-DuetReparsePoint $ConfigPath)) { Write-DuetError "duet: session config is a reparse point; refusing it."; return $false }
  if (Test-DuetPathChainHasReparse -Path $dir -StopAt $root) { Write-DuetError "duet: a session path component is a reparse point; refusing it."; return $false }
  $canonDir = Get-DuetCanonicalPath $dir
  $canonRoot = Get-DuetCanonicalPath $root
  $canonWorkdir = Get-DuetCanonicalPath $workdir
  $canonPlugin = Get-DuetCanonicalPath $pluginDir
  if (-not $canonDir -or -not $canonRoot -or -not $canonWorkdir -or -not $canonPlugin) { Write-DuetError "duet: session paths are unavailable."; return $false }
  $sep = [IO.Path]::DirectorySeparatorChar
  if ($canonRoot -eq ((Split-Path -Qualifier $canonRoot) + $sep)) { Write-DuetError "duet: DUET_STATE_ROOT may not be a drive root."; return $false }
  if (-not (Test-DuetPathUnderRoot $canonDir $canonRoot)) { Write-DuetError "duet: session directory escapes its declared DUET_STATE_ROOT."; return $false }
  if ((Split-Path -Leaf $canonDir) -ne $sid) { Write-DuetError "duet: session id '$sid' does not match directory."; return $false }
  if ($Config['DUET_SESSION'] -ne $sid) { Write-DuetError "duet: config DUET_SESSION does not match DUET_SESSION_ID."; return $false }
  # The psmux session name + backend server pid are the socket/server fence
  # analogue and are MANDATORY before any routing.
  $psmuxSession = $Config['DUET_PSMUX_SESSION']; $psmuxPid = $Config['DUET_PSMUX_SERVER_PID']
  $psmuxReg = $Config['DUET_PSMUX_REGISTRY']; $psmuxNs = $Config['DUET_PSMUX_NAMESPACE']
  if (-not $psmuxSession -or -not $psmuxPid -or -not $psmuxReg) { Write-DuetError "duet: config missing DUET_PSMUX_SESSION, DUET_PSMUX_SERVER_PID, or DUET_PSMUX_REGISTRY."; return $false }
  if (-not (Test-DuetSafeName $psmuxSession)) { Write-DuetError "duet: DUET_PSMUX_SESSION is not a safe session name."; return $false }
  if (-not (Test-DuetSafeName $psmuxReg)) { Write-DuetError "duet: DUET_PSMUX_REGISTRY is not a safe registry base."; return $false }
  if ($psmuxNs -and -not (Test-DuetSafeName $psmuxNs)) { Write-DuetError "duet: DUET_PSMUX_NAMESPACE is not a safe namespace."; return $false }
  # Exact registry relation: <session> when no namespace, else <namespace>__<session>.
  $expectedReg = if ($psmuxNs) { ("{0}__{1}" -f $psmuxNs, $psmuxSession) } else { $psmuxSession }
  if ($psmuxReg -ne $expectedReg) { Write-DuetError "duet: DUET_PSMUX_REGISTRY must equal '$expectedReg'."; return $false }
  $pidInt = 0
  if (-not [int]::TryParse($psmuxPid, [ref]$pidInt) -or $pidInt -le 0) { Write-DuetError "duet: DUET_PSMUX_SERVER_PID must be a positive process id."; return $false }
  if ($ConfigPath) {
    $cd = Get-DuetCanonicalPath (Split-Path -Parent $ConfigPath)
    if ($cd -ne $canonDir) { Write-DuetError "duet: config path does not belong to its session directory."; return $false }
  }
  if ($ExpectedSession -and $ExpectedSession -ne $sid) { Write-DuetError "duet: caller is pinned to session '$ExpectedSession', not '$sid'."; return $false }
  return $true
}

function Get-DuetWorkdirKey {
  param([string]$Workdir)
  $canonical = Get-DuetCanonicalPath $Workdir
  if (-not $canonical) { return $null }
  # Windows paths are case-insensitive: normalize casing so one workdir cannot
  # yield two distinct active-session owners.
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical.ToLowerInvariant()))
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

# =============================================================================
# psmux identity + fencing  (the load-bearing resolver)
# `list-panes -a` spans all windows/sessions; `-t <session>` is window-local.
# =============================================================================

function Get-DuetAllPaneRecords {
  # DISCOVERY ONLY (caller ancestry / init server-pid). NEVER for runtime tuple
  # liveness/capture/key/teardown -- `-a` enumerates registry files and silently
  # skips an unreachable one at rc 0. Use Resolve-DuetPaneResolution for liveness.
  # Every pane across the registry: Session, ServerPid, PaneId, PanePid.
  # Returns $null when the psmux query itself failed (rc != 0) so callers can
  # fail closed -- an empty array means "queried OK, no panes", never "unknown".
  # A foreign session name may contain '|', so anchor the three trailing numeric/
  # id fields from the RIGHT rather than left-splitting.
  $out = Invoke-DuetPsmux list-panes -a -F '#{session_name}|#{pid}|#{pane_id}|#{pane_pid}'
  if ($global:DUET_PSMUX_RC -ne 0) { return $null }
  $recs = @()
  foreach ($ln in @($out)) {
    if (-not $ln) { continue }
    if ($ln -match '^(.*)\|([0-9]+)\|(%[0-9]+)\|([0-9]+)$') {
      $recs += [pscustomobject]@{ Session = $Matches[1]; ServerPid = $Matches[2]; PaneId = $Matches[3]; PanePid = $Matches[4] }
    }
  }
  return , $recs
}

function Get-DuetSessionServerPid {
  # Return the backend pid ONLY if every pane in the session agrees on exactly
  # one -- an ambiguous/split registry must not yield a first-record-wins fence.
  param([string]$Session)
  if (-not $Session) { return $null }
  $recs = Get-DuetAllPaneRecords
  if ($null -eq $recs) { return $null }
  $pids = @{}
  foreach ($r in $recs) { if ($r.Session -eq $Session -and $r.ServerPid) { $pids[$r.ServerPid] = $true } }
  if ($pids.Count -ne 1) { return $null }
  return @($pids.Keys)[0]
}

# Fail closed AND cheap: the exact per-session query's backend pid must equal the
# recorded one. Never the -a all-session scan (500ms/registry, silently skips
# outages) -- the daemon calls this every pass.
function Test-DuetServerMatches {
  $expected = $global:DUET_PSMUX_SERVER_PID
  $session = $global:DUET_PSMUX_SESSION
  if (-not $expected -or -not $session) { return $false }
  $out = Invoke-DuetPsmux list-panes -s -t $session -F '#{pid}'
  if ($global:DUET_PSMUX_RC -ne 0) { return $false }
  $seen = 0
  foreach ($ln in @($out)) {
    $pidText = ("$ln").Trim()
    if (-not $pidText) { continue }
    if ($pidText -ne $expected) { return $false }
    $seen++
  }
  return ($seen -gt 0)
}

# THE runtime resolver. Query the EXACT session (`list-panes -s -t <session>`,
# with -L namespace prepended by Invoke-DuetPsmux) -- NEVER the -a all-session
# scan, which enumerates registry files and silently skips an unreachable one at
# rc 0, turning our own registry outage into a false "pane gone". Tri-state:
#   Known=$false             -> the query itself failed (UNKNOWN); never assert dead
#   Known=$true, Alive=$false -> queried OK but the tuple is absent/ambiguous (DEAD)
#   Known=$true, Alive=$true  -> resolved; Target = "<session>:<pane_id>"
function Resolve-DuetPaneResolution {
  param([string]$PaneId, [string]$PanePid,
        [string]$Session = $global:DUET_PSMUX_SESSION,
        [string]$ServerPid = $global:DUET_PSMUX_SERVER_PID)
  $dead = [pscustomobject]@{ Known = $true; Alive = $false; Target = $null }
  if (-not (Test-DuetSafeName $Session)) { return $dead }
  if ($ServerPid -notmatch '^[0-9]+$' -or $PaneId -notmatch '^%[0-9]+$' -or $PanePid -notmatch '^[0-9]+$') { return $dead }
  $out = Invoke-DuetPsmux list-panes -s -t $Session -F '#{session_name}|#{pid}|#{pane_id}|#{pane_pid}'
  if ($global:DUET_PSMUX_RC -ne 0) { return [pscustomobject]@{ Known = $false; Alive = $false; Target = $null } }
  $matched = 0
  foreach ($ln in @($out)) {
    if (-not $ln) { continue }
    if ($ln -match '^(.*)\|([0-9]+)\|(%[0-9]+)\|([0-9]+)$') {
      if ($Matches[1] -eq $Session -and $Matches[2] -eq $ServerPid -and $Matches[3] -eq $PaneId -and $Matches[4] -eq $PanePid) { $matched++ }
    }
  }
  if ($matched -eq 1) { return [pscustomobject]@{ Known = $true; Alive = $true; Target = "${Session}:${PaneId}" } }
  return $dead
}

# Thin helper for callers that only need the bounded target (null unless a live
# exact match). Callers needing the UNKNOWN/DEAD distinction use the resolution.
function Resolve-DuetPaneTarget {
  param([string]$PaneId, [string]$PanePid,
        [string]$Session = $global:DUET_PSMUX_SESSION,
        [string]$ServerPid = $global:DUET_PSMUX_SERVER_PID)
  $r = Resolve-DuetPaneResolution -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid
  if ($r.Known -and $r.Alive) { return $r.Target }
  return $null
}

function Test-DuetPaneTupleAlive {
  param([string]$PaneId, [string]$PanePid,
        [string]$Session = $global:DUET_PSMUX_SESSION,
        [string]$ServerPid = $global:DUET_PSMUX_SERVER_PID)
  $r = Resolve-DuetPaneResolution -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid
  return ($r.Known -and $r.Alive)
}

# (Bare-target pane reads intentionally removed: all pane capture/display/send-key
# operations go through the tuple-bound wrappers in the verified-send section,
# which re-resolve the durable tuple immediately before each single psmux op.)

# =============================================================================
# Caller identity (membership fence) via PROCESS ANCESTRY  (A7 / A8)
# Our process descends from its pane's pane_pid, so among the possibly-many
# panes sharing a bare id, the one whose pane_pid is our ancestor is ours.
# =============================================================================

function Get-DuetCallerIdentity {
  $global:DUET_CALLER_SESSION = ''; $global:DUET_CALLER_PANE = ''
  $global:DUET_CALLER_PANE_PID = ''; $global:DUET_CALLER_SERVER_PID = ''
  $global:DUET_CALLER_NAMESPACE = ''; $global:DUET_CALLER_REGISTRY = ''
  # Derive the caller's namespace from its inherited registry base
  # (PSMUX_TARGET_SESSION = "<namespace>__<raw>" under -L). psmux `list-panes -a`
  # excludes every base containing "__" unless -L is passed, so a namespaced
  # caller is invisible without it. A bare-id scan is acceptable ONLY for this
  # one caller-discovery query, which is then fenced by process ancestry.
  $callerBase = $env:PSMUX_TARGET_SESSION
  $ns = ''
  if ($callerBase -and $callerBase.Contains('__')) {
    $idx = $callerBase.IndexOf('__')
    if ($idx -gt 0) { $ns = $callerBase.Substring(0, $idx) }
  }
  $psmux = Get-DuetPsmux
  $fmt = '#{session_name}|#{pid}|#{pane_id}|#{pane_pid}'
  $qargs = if ($ns) { @('-L', $ns, 'list-panes', '-a', '-F', $fmt) } else { @('list-panes', '-a', '-F', $fmt) }
  $out = & $psmux @qargs 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  $byPid = @{}; $dup = @{}
  foreach ($ln in @($out)) {
    if (-not $ln) { continue }
    if ($ln -match '^(.*)\|([0-9]+)\|(%[0-9]+)\|([0-9]+)$') {
      $pp = 0; if (-not [int]::TryParse($Matches[4], [ref]$pp)) { continue }
      $rec = [pscustomobject]@{ Session = $Matches[1]; ServerPid = $Matches[2]; PaneId = $Matches[3]; PanePid = $Matches[4] }
      if ($byPid.ContainsKey($pp)) { $dup[$pp] = $true } else { $byPid[$pp] = $rec }
    }
  }
  if ($byPid.Count -eq 0) { return $false }
  $parent = Get-DuetProcessParentMap
  $cur = $PID; $seen = @{}
  while ($cur -gt 0 -and $parent.ContainsKey($cur) -and -not $seen[$cur]) {
    $seen[$cur] = $true
    if ($byPid.ContainsKey($cur)) {
      if ($dup.ContainsKey($cur)) { return $false }   # ambiguous pane_pid -> fail closed
      $r = $byPid[$cur]
      if ($env:TMUX_PANE -and $env:TMUX_PANE -ne $r.PaneId) { return $false }
      $global:DUET_CALLER_SESSION = $r.Session
      $global:DUET_CALLER_PANE = $r.PaneId
      $global:DUET_CALLER_PANE_PID = $r.PanePid
      $global:DUET_CALLER_SERVER_PID = $r.ServerPid
      $global:DUET_CALLER_NAMESPACE = $ns
      $global:DUET_CALLER_REGISTRY = if ($ns) { ("{0}__{1}" -f $ns, $r.Session) } else { $r.Session }
      return $true
    }
    $cur = $parent[$cur]
  }
  return $false
}

function Get-DuetCallerRosterName {
  param([string]$RosterPath, [string]$ExpectedSession, [string]$ExpectedServerPid)
  $global:DUET_CALLER_NAME = ''
  if (-not (Get-DuetCallerIdentity)) { return $false }
  if ($ExpectedSession -and $global:DUET_CALLER_SESSION -ne $ExpectedSession) { return $false }
  if ($ExpectedServerPid -and $global:DUET_CALLER_SERVER_PID -ne $ExpectedServerPid) { return $false }
  $row = Get-DuetRosterRowByPane -RosterPath $RosterPath -PaneId $global:DUET_CALLER_PANE
  if (-not $row) { return $false }
  if ($row.pane_pid -ne $global:DUET_CALLER_PANE_PID) { return $false }
  $global:DUET_CALLER_NAME = $row.name
  return $true
}

# =============================================================================
# Roster access  (schema: name harness pane_id pane_pid rank spawned)
# =============================================================================

function Import-DuetRoster {
  param([string]$RosterPath)
  $global:DUET_ROSTER_VALID = $false
  $rows = @()
  $text = Get-DuetFileText $RosterPath
  if ($null -eq $text) { return $rows }
  $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
  if ($lines.Count -lt 2 -or $lines[0] -ne "name`tharness`tpane_id`tpane_pid`trank`tspawned") { return $rows }
  $names = @{}; $panes = @{}; $pids = @{}; $ranks = @{}
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = @($lines[$i].Split([char]9))
    if ($c.Count -ne 6) { return @() }
    $name = $c[0]; $harness = $c[1]; $pane = $c[2]; $panePid = $c[3]; $rank = $c[4]; $spawned = $c[5]
    $pidValue = 0; $rankValue = 0
    if ($name -notmatch '^[A-Za-z0-9_-]+$' -or @('claude', 'codex', 'kimi') -notcontains $harness `
        -or $pane -notmatch '^%[0-9]+$' -or -not [int]::TryParse($panePid, [ref]$pidValue) -or $pidValue -le 0 `
        -or -not [int]::TryParse($rank, [ref]$rankValue) -or $rankValue -lt 0 -or @('0', '1') -notcontains $spawned) {
      return @()
    }
    if ($names.ContainsKey($name) -or $panes.ContainsKey($pane) -or $pids.ContainsKey($panePid) -or $ranks.ContainsKey($rank)) { return @() }
    $names[$name] = $true; $panes[$pane] = $true; $pids[$panePid] = $true; $ranks[$rank] = $true
    $rows += [pscustomobject]@{ name = $name; harness = $harness; pane_id = $pane; pane_pid = $panePid; rank = $rank; spawned = $spawned }
    if ($rows.Count -gt 5) { return @() }
  }
  if ($rows.Count -lt 1) { return @() }
  $global:DUET_ROSTER_VALID = $true
  return $rows
}
function Get-DuetRosterRow { param([string]$RosterPath, [string]$Name); $rows = @(Import-DuetRoster $RosterPath); if (-not $global:DUET_ROSTER_VALID) { return $null }; foreach ($r in $rows) { if ($r.name -eq $Name) { return $r } }; return $null }
function Get-DuetRosterRowByPane { param([string]$RosterPath, [string]$PaneId); $rows = @(Import-DuetRoster $RosterPath); if (-not $global:DUET_ROSTER_VALID) { return $null }; foreach ($r in $rows) { if ($r.pane_id -eq $PaneId) { return $r } }; return $null }
function Test-DuetRosterHasName { param([string]$RosterPath, [string]$Name); return ($null -ne (Get-DuetRosterRow -RosterPath $RosterPath -Name $Name)) }

# Tri-state resolution keeps confirmed-dead members distinct from identity
# uncertainty.
function Get-DuetMemberResolution {
  param([string]$RosterPath, [string]$Name)
  $row = Get-DuetRosterRow -RosterPath $RosterPath -Name $Name
  if (-not $global:DUET_ROSTER_VALID -or -not $row) { return [pscustomobject]@{ Known = $false; Alive = $false; Target = $null } }
  return (Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid)
}

# Confirmed-alive convenience (UNKNOWN counts as not confirmed alive).
function Test-DuetMemberAlive {
  param([string]$RosterPath, [string]$Name)
  $r = Get-DuetMemberResolution -RosterPath $RosterPath -Name $Name
  return ($r.Known -and $r.Alive)
}

# =============================================================================
# Anchors (durable brief blocks in AGENTS.md / CLAUDE.md)
# =============================================================================

function Remove-DuetAnchorFile {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
  try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $false }
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Write-DuetError "duet: refusing to edit symlinked instruction file: $Path"; return $false }
  try { $text = [System.IO.File]::ReadAllText($Path) } catch { return $false }
  $updated = [regex]::Replace($text, "(?s)\r?\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\r?\n?", "")
  if ($updated -ne $text) { return (Write-DuetAtomicMultiline -Path $Path -Value $updated.TrimEnd("`r", "`n")) }
  return $true
}
function Remove-DuetSessionAnchors {
  param([string]$Workdir)
  if (-not $Workdir) { return $true }
  if (-not (Remove-DuetAnchorFile (Join-Path $Workdir 'AGENTS.md'))) { return $false }
  return (Remove-DuetAnchorFile (Join-Path $Workdir 'CLAUDE.md'))
}

# =============================================================================
# Daemon identity + shutdown
# =============================================================================

function Test-DuetCommandLineOption {
  param([string]$CommandLine, [string]$Option, [string]$Value)
  if (-not $CommandLine -or -not $Option -or -not $Value) { return $false }
  $escapedValue = [regex]::Escape($Value)
  $valuePattern = '(?:"' + $escapedValue + '"|''' + $escapedValue + '''|' + $escapedValue + ')'
  $pattern = '(?:^|\s)' + [regex]::Escape($Option) + '\s+' + $valuePattern + '(?=\s|$)'
  return [regex]::IsMatch($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-DuetDaemonProcessMatches {
  param($ProcessId, [string]$ConfigPath, [string]$SessionId)
  $n = 0
  if (-not [int]::TryParse([string]$ProcessId, [ref]$n) -or $n -le 0) { return $false }
  if (-not $ConfigPath -or -not $SessionId) { return $false }
  $canonicalConfig = Get-DuetCanonicalPath $ConfigPath
  if (-not $canonicalConfig) { return $false }
  $daemonConfig = Import-DuetConfig $canonicalConfig
  if (-not $global:DUET_CONFIG_VALID) { return $false }
  $plugin = Get-DuetCanonicalPath $daemonConfig['PLUGIN_DIR']
  if (-not $plugin) { return $false }
  $daemonScript = Get-DuetCanonicalPath (Join-Path (Join-Path $plugin 'scripts') 'duet-deliverd.ps1')
  if (-not $daemonScript) { return $false }
  try { $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$n" -ErrorAction Stop } catch { return $false }
  if (-not $cim) { return $false }
  $cl = [string]$cim.CommandLine
  if (-not (Test-DuetCommandLineOption -CommandLine $cl -Option '-File' -Value $daemonScript)) { return $false }
  if (-not (Test-DuetCommandLineOption -CommandLine $cl -Option '-Session' -Value $canonicalConfig)) { return $false }
  if (-not (Test-DuetCommandLineOption -CommandLine $cl -Option '-SessionId' -Value $SessionId)) { return $false }
  return $true
}

function Test-DuetDaemonAlive {
  param([string]$DuetDir, [string]$SessionId)
  $daemonPid = (Get-DuetFileText (Join-Path $DuetDir 'daemon.pid'))
  if ($daemonPid) { $daemonPid = $daemonPid.Trim() }
  if (-not $daemonPid -or $daemonPid -notmatch '^[0-9]+$') { return $false }
  if (-not (Test-DuetProcessAlive $daemonPid)) { return $false }
  if ((Get-DuetLockOwnerPid (Join-Path $DuetDir '.daemon.lock')) -ne $daemonPid) { return $false }
  $canon = Get-DuetCanonicalPath $DuetDir
  if (-not $canon) { return $false }
  if (-not $SessionId) { $SessionId = Split-Path -Leaf $canon }
  return (Test-DuetDaemonProcessMatches -ProcessId $daemonPid -ConfigPath (Join-Path $canon 'duet.env') -SessionId $SessionId)
}

function Stop-DuetDaemon {
  param([string]$DuetDir, [int]$Loops = 30)
  if (-not $DuetDir) { return $true }
  $canon = Get-DuetCanonicalPath $DuetDir
  if (-not $canon) { return $false }
  $sessionId = Split-Path -Leaf $canon
  $configPath = Join-Path $canon 'duet.env'
  $pidFile = Join-Path $canon 'daemon.pid'
  $lock = Join-Path $canon '.daemon.lock'
  $daemonPid = $null; $identityValid = $false
  for ($i = 0; $i -lt $Loops; $i++) {
    $daemonPid = (Get-DuetFileText $pidFile); if ($daemonPid) { $daemonPid = $daemonPid.Trim() }
    $ownerPid = Get-DuetLockOwnerPid $lock
    $pidLive = ($daemonPid -match '^[0-9]+$') -and (Test-DuetProcessAlive $daemonPid)
    $ownerLive = ($ownerPid -match '^[0-9]+$') -and (Test-DuetProcessAlive $ownerPid)
    if ($ownerLive) {
      if ($pidLive -and $daemonPid -eq $ownerPid) { $identityValid = $true; break }
      Start-Sleep -Milliseconds 100; continue
    }
    if ($pidLive) { Write-DuetError "duet: daemon.pid does not own this session's live daemon lock; refusing to signal it."; return $false }
    return $true
  }
  if (-not $identityValid) { Write-DuetError "duet: daemon.pid does not own this session's live daemon lock; refusing to signal it."; return $false }
  if (-not (Test-DuetDaemonProcessMatches -ProcessId $daemonPid -ConfigPath $configPath -SessionId $sessionId)) {
    # The daemon may observe .ended, exit, and remove its lifetime lock in the
    # interval after the live pid/owner pair above. That is success, not an
    # identity failure. A still-live process that still owns the lock remains
    # fenced: it might be an unrelated PID or a forged/stale owner record.
    if (-not (Test-DuetProcessAlive $daemonPid) -or (Get-DuetLockOwnerPid $lock) -ne $daemonPid) { return $true }
    Write-DuetError "duet: daemon pid $daemonPid does not identify session $canon; refusing to signal it."; return $false
  }
  try { Write-DuetUtf8NoBom -Path (Join-Path $canon '.ended') -Value '' } catch { }
  for ($i = 0; $i -lt 20; $i++) { if (-not (Test-DuetProcessAlive $daemonPid)) { return $true }; Start-Sleep -Milliseconds 100 }
  # Re-validate ownership + command-line identity IMMEDIATELY before a forced
  # stop: during the wait the pid may have exited and been recycled to an
  # unrelated process. Never Stop-Process a recycled/foreign pid.
  if ((Get-DuetLockOwnerPid $lock) -ne $daemonPid -or -not (Test-DuetDaemonProcessMatches -ProcessId $daemonPid -ConfigPath $configPath -SessionId $sessionId)) {
    return $true   # the daemon we identified is no longer that process; it has stopped
  }
  try { Stop-Process -Id ([int]$daemonPid) -Force -ErrorAction Stop } catch { }
  for ($i = 0; $i -lt 20; $i++) { if (-not (Test-DuetProcessAlive $daemonPid)) { return $true }; Start-Sleep -Milliseconds 100 }
  Write-DuetError "duet: delivery daemon $daemonPid did not exit after TERM."
  return $false
}

# =============================================================================
# Teardown / reap  (A6)
# =============================================================================

# Kill only roster members marked spawned=1, by their VERIFIED pane pid after a
# fresh exact-session resolve. Never Stop a pid whose tuple no longer resolves
# (may be recycled). Exempt ONLY the exact caller (pane_id AND pane_pid). Returns
# $false if any spawned pane could not be confirmed stopped (UNKNOWN or still-live).
function Stop-DuetSpawnedPanes {
  param([string]$RosterPath, [string]$ExemptPaneId, [string]$ExemptPanePid)
  if (-not $RosterPath -or -not (Test-Path -LiteralPath $RosterPath -PathType Leaf)) { return $false }
  $rows = @(Import-DuetRoster $RosterPath)
  if (-not $global:DUET_ROSTER_VALID) { return $false }
  $allOk = $true
  foreach ($r in $rows) {
    if ($r.spawned -ne '1') { continue }
    if (-not $r.pane_id -or -not $r.pane_pid) { $allOk = $false; continue }
    if ($ExemptPaneId -and $ExemptPanePid -and $r.pane_id -eq $ExemptPaneId -and $r.pane_pid -eq $ExemptPanePid) { continue }
    $res = Resolve-DuetPaneResolution -PaneId $r.pane_id -PanePid $r.pane_pid
    if (-not $res.Known) { $allOk = $false; continue }   # UNKNOWN: cannot safely stop -> not done
    if (-not $res.Alive) { continue }                    # already gone
    $n = 0
    if (-not ([int]::TryParse($r.pane_pid, [ref]$n)) -or $n -le 0) { $allOk = $false; continue }
    # Close the resolve-to-kill window. If the pane vanished or became unknown,
    # do not signal the recorded PID; it may already have been recycled.
    $res = Resolve-DuetPaneResolution -PaneId $r.pane_id -PanePid $r.pane_pid
    if (-not $res.Known) { $allOk = $false; continue }
    if (-not $res.Alive) { continue }
    try { Stop-Process -Id $n -Force -ErrorAction Stop } catch { $allOk = $false; continue }
    $gone = $false
    for ($i = 0; $i -lt 20; $i++) { if (-not (Test-DuetProcessAlive $n)) { $gone = $true; break }; Start-Sleep -Milliseconds 100 }
    if (-not $gone) { $allOk = $false }
  }
  return $allOk
}

# =============================================================================
# Atomic message queue -- byte-identical DUETv4 wire format
# =============================================================================

function Get-DuetNextSequence {
  param([string]$Box)
  $counter = Join-Path $Box '.counter'
  $subs = @('', 'delivered', 'rejected')
  [uint64]$current = 0
  $txt = Get-DuetFileText $counter
  if ($null -ne $txt) {
    $t = $txt.Trim()
    $parsed = ConvertFrom-DuetDecimal $t
    if ($null -eq $parsed) { Write-DuetError "duet: corrupt counter in $Box"; return $false }
    $current = $parsed
  }
  else {
    # No counter: the box must contain NO allocated message OR sidecar anywhere
    # (root or any terminal archive), else restarting at 1 could later collide.
    foreach ($sub in $subs) {
      $d = if ($sub) { Join-Path $Box $sub } else { $Box }
      if (-not (Test-Path -LiteralPath $d)) { continue }
      if (@(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg' }).Count -gt 0) {
        Write-DuetError "duet: missing counter in non-empty queue $Box"; return $false
      }
    }
  }
  if ($current -ge 9999999999) { Write-DuetError "duet: sequence exhausted (D10 cap) in $Box"; return $false }
  [uint64]$next = $current + 1
  $seq = '{0:D10}' -f $next
  foreach ($sub in $subs) {
    $d = if ($sub) { Join-Path $Box $sub } else { $Box }
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($pfx in @('N', 'I')) {
      if (@(Get-ChildItem -LiteralPath $d -Filter "$pfx-$seq.msg*" -File -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-DuetError "duet: counter rollback would reuse sequence $seq in $Box"; return $false
      }
    }
  }
  if (-not (Write-DuetAtomicMultiline -Path $counter -Value "$next")) { return $false }
  $global:DUET_SEQUENCE = $seq
  return $true
}

function Add-DuetTranscript {
  param([string]$DuetDir, [string]$Id, [string]$Sender, [string]$Recipient,
    [string]$Mode, [AllowEmptyString()][string]$Body)
  $lock = Join-Path $DuetDir '.transcript.lock'
  if (-not (Lock-DuetAcquire $lock 1200)) { return $false }
  try {
    $entry = "`n----- {0}  id={1}  {2} -> {3}  ({4}) -----`n{5}`n" -f
      (Get-DuetUtcStamp), $Id, $Sender, $Recipient, $Mode, $Body
    Write-DuetUtf8NoBom -Path (Join-Path $DuetDir 'transcript.md') -Value $entry -Append
    return $true
  } finally { Unlock-DuetRelease $lock | Out-Null }
}

# Enqueue one immutable message. The enqueue lock is held through the transcript
# append and the final atomic publish, so transcript order matches queue order
# for a recipient. Sets DUET_ENQUEUED_ID / DUET_ENQUEUED_FILE / DUET_SEQUENCE.
function Add-DuetMessage {
  param(
    [string]$DuetDir, [string]$SessionId, [string]$Queue, [string]$Sender,
    [string]$Recipient, [string]$Mode, [AllowEmptyString()][string]$Body
  )
  $global:DUET_ENQUEUED_ID = ''; $global:DUET_ENQUEUED_FILE = ''
  if ($Queue -notmatch '^[A-Za-z0-9_-]+$') { Write-DuetError "duet: invalid queue '$Queue'"; return $false }
  $prefix = switch ($Mode) { 'NORMAL' { 'N' } 'INTERRUPT' { 'I' } default { '' } }
  if (-not $prefix) { Write-DuetError "duet: invalid mode '$Mode'"; return $false }
  foreach ($meta in @($SessionId, $Sender, $Recipient)) {
    if (-not $meta -or $meta -notmatch '^[A-Za-z0-9_-]+$') { Write-DuetError "duet: invalid message metadata"; return $false }
  }
  $rosterPath = Join-Path $DuetDir 'roster.tsv'
  if (-not (Test-DuetRosterHasName -RosterPath $rosterPath -Name $Queue)) {
    Write-DuetError "duet: queue '$Queue' is not a roster member"; return $false
  }
  if ($Recipient -ne 'all' -and $Recipient -ne $Queue) {
    Write-DuetError "duet: recipient '$Recipient' does not match queue '$Queue'"; return $false
  }
  if (-not (Test-DuetRosterHasName -RosterPath $rosterPath -Name $Sender)) {
    Write-DuetError "duet: sender '$Sender' is not a roster member"; return $false
  }
  if ($Body.Contains([char]0)) { Write-DuetError 'duet: message body contains NUL'; return $false }
  if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) {
    Write-DuetError 'duet: session has ended; message was not queued.'; return $false
  }
  if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $SessionId)) {
    Write-DuetError 'duet: delivery daemon is not alive; message was not queued.'; return $false
  }
  $box = Join-Path (Join-Path $DuetDir 'inbox') $Queue
  foreach ($sub in @('delivered', 'rejected')) {
    $d = Join-Path $box $sub
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }
  $attempts = 1200
  $configuredAttempts = 0
  if ($env:DUET_ENQUEUE_LOCK_ATTEMPTS -and
      [int]::TryParse($env:DUET_ENQUEUE_LOCK_ATTEMPTS, [ref]$configuredAttempts) -and
      $configuredAttempts -gt 0) {
    $attempts = $configuredAttempts
  }
  $enqLock = Join-Path $box '.enqueue.lock'
  if (-not (Lock-DuetAcquire $enqLock $attempts)) { return $false }
  try {
    if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) {
      Write-DuetError 'duet: session has ended; message was not queued.'; return $false
    }
    if (-not (Get-DuetNextSequence -Box $box)) { return $false }
    $seq = $global:DUET_SEQUENCE
    $id = "m-$SessionId-$Queue-$seq"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Body))
    $content = "DUETv4`n" +
      "id`t$id`n" +
      "session`t$SessionId`n" +
      "mode`t$Mode`n" +
      "sender`t$Sender`n" +
      "recipient`t$Recipient`n" +
      "body64`t$encoded`n"
    $tmp = New-DuetTempFile -Dir $box
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $content, $enc)
    if (-not (Add-DuetTranscript -DuetDir $DuetDir -Id $id -Sender $Sender -Recipient $Recipient -Mode $Mode -Body $Body)) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      return $false
    }
    $final = Join-Path $box "$prefix-$seq.msg"
    if (-not (Move-DuetFileNoReplace -Source $tmp -Destination $final)) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      return $false
    }
    $global:DUET_ENQUEUED_ID = $id
    $global:DUET_ENQUEUED_FILE = $final
    return $true
  } finally { Unlock-DuetRelease $enqLock | Out-Null }
}

function Read-DuetMessage {
  # Strict parser: reject duplicate known fields, unknown fields, control chars
  # in any metadata value (incl. CR), and invalid-UTF8 bodies. Matches bash's
  # first-wins-by-refusing-duplicates so two tools never disagree on an envelope.
  param([string]$File)
  $known = @('id', 'session', 'mode', 'sender', 'recipient', 'body64')
  foreach ($g in @('DUET_MESSAGE_ID', 'DUET_MESSAGE_SESSION', 'DUET_MESSAGE_MODE',
      'DUET_MESSAGE_SENDER', 'DUET_MESSAGE_RECIPIENT', 'DUET_MESSAGE_BODY')) {
    Set-Variable -Name $g -Scope Global -Value ''
  }
  $text = Get-DuetFileText $File
  if ($null -eq $text) { return $false }
  $lines = $text -split "`n"
  if ($lines.Count -lt 1 -or ($lines[0].TrimEnd("`r")) -ne 'DUETv4') { return $false }
  $fields = @{}; $seen = @{}
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }   # tolerate CRLF framing
    if ($line -eq '') { continue }
    $kv = $line -split "`t", 2
    $k = $kv[0]; $v = if ($kv.Count -gt 1) { $kv[1] } else { '' }
    if ($known -notcontains $k) { return $false }             # unknown field
    if ($seen.ContainsKey($k)) { return $false }              # duplicate field
    $seen[$k] = $true
    if ($k -ne 'body64' -and $v -match "[\x00-\x1f\x7f]") { return $false }   # control chars incl. CR
    $fields[$k] = $v
  }
  foreach ($req in @('id', 'session', 'mode', 'sender', 'recipient', 'body64')) {
    if (-not $seen.ContainsKey($req)) { return $false }
  }
  $global:DUET_MESSAGE_ID = $fields['id']
  $global:DUET_MESSAGE_SESSION = $fields['session']
  $global:DUET_MESSAGE_MODE = $fields['mode']
  $global:DUET_MESSAGE_SENDER = $fields['sender']
  $global:DUET_MESSAGE_RECIPIENT = $fields['recipient']
  if ($seen.ContainsKey('body64')) {
    $strict = New-Object System.Text.UTF8Encoding($false, $true)   # throw on invalid bytes
    try { $global:DUET_MESSAGE_BODY = $strict.GetString([Convert]::FromBase64String($fields['body64'])) } catch { return $false }
    if ($global:DUET_MESSAGE_BODY.Contains([char]0)) { return $false }
  }
  if ($global:DUET_MESSAGE_ID -notmatch '^[A-Za-z0-9_-]+$' -or $global:DUET_MESSAGE_SESSION -notmatch '^[A-Za-z0-9_-]+$' `
      -or $global:DUET_MESSAGE_SENDER -notmatch '^[A-Za-z0-9_-]+$' -or $global:DUET_MESSAGE_RECIPIENT -notmatch '^[A-Za-z0-9_-]+$') { return $false }
  if (@('NORMAL', 'INTERRUPT') -notcontains $global:DUET_MESSAGE_MODE) { return $false }
  return $true
}

function Build-DuetPayload {
  return ("[DUET session={0} id={1} from={2} to={3}]`n{4}`n[DUET session={0} id={1} end]" -f `
      $global:DUET_MESSAGE_SESSION, $global:DUET_MESSAGE_ID, $global:DUET_MESSAGE_SENDER,
      $global:DUET_MESSAGE_RECIPIENT, $global:DUET_MESSAGE_BODY)
}

function Get-DuetPendingCount {
  param([string]$DuetDir)
  $count = 0
  $inbox = Join-Path $DuetDir 'inbox'
  if (-not (Test-Path -LiteralPath $inbox)) { return 0 }
  foreach ($box in @(Get-ChildItem -LiteralPath $inbox -Directory -ErrorAction SilentlyContinue)) {
    $count += @(Get-ChildItem -LiteralPath $box.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[NI]-.*\.msg$' }).Count
  }
  return $count
}

# =============================================================================
# Verified send FSM  (A2)  -- base64 send-paste is the ONLY full-payload path.
# `load-buffer` mangles CR/LF into literal \r\n and unscoped `set-buffer` lands
# on the wrong backend (psmux 3.3.6 source), so both are invalid here. Every
# pane op re-resolves the durable tuple before issuing the bounded command.
# =============================================================================

function Get-DuetAlnum { param([AllowEmptyString()][string]$Text); if ($null -eq $Text) { return '' }; return ($Text -replace '[^0-9A-Za-z]', '') }
function Get-DuetProbe {
  param([AllowEmptyString()][string]$Payload)
  $s = Get-DuetAlnum $Payload
  if ($s.Length -gt 48) { return $s.Substring($s.Length - 48) }
  return $s
}
function Test-DuetPresent {
  param([AllowEmptyString()][string]$Haystack, [AllowEmptyString()][string]$Probe)
  if (-not $Probe) { return $false }
  return ((Get-DuetAlnum $Haystack).Contains((Get-DuetAlnum $Probe)))
}
# --- Tuple-bound pane operations ---------------------------------------------
# Each re-resolves the durable tuple immediately before ONE psmux op and reports
# structured state. Ok=$false means the command FAILED (UNKNOWN) -- never treat
# it as evidence of absence. Alive=$false means a fresh resolver said the pane is
# gone. Operational targets are never passed between calls.

# Alive=$false is returned ONLY on a confirmed-dead resolution (Known + not Alive).
# An UNKNOWN resolution or a failed op returns Alive=$true, Ok=$false (never dead,
# never issues a keystroke to an unresolved tuple).
function Invoke-DuetPaneCapture {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid)
  $r = Resolve-DuetPaneResolution -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid
  if (-not $r.Known) { return [pscustomobject]@{ Alive = $true; Ok = $false; Lines = @() } }
  if (-not $r.Alive) { return [pscustomobject]@{ Alive = $false; Ok = $false; Lines = @() } }
  $out = Invoke-DuetPsmux capture-pane -p -t $r.Target
  if ($global:DUET_PSMUX_RC -ne 0) { return [pscustomobject]@{ Alive = $true; Ok = $false; Lines = @() } }
  return [pscustomobject]@{ Alive = $true; Ok = $true; Lines = @($out) }
}

function Invoke-DuetPaneGeometry {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid)
  $r = Resolve-DuetPaneResolution -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid
  if (-not $r.Known) { return [pscustomobject]@{ Alive = $true; Ok = $false; CursorY = ''; Height = '' } }
  if (-not $r.Alive) { return [pscustomobject]@{ Alive = $false; Ok = $false; CursorY = ''; Height = '' } }
  $out = Invoke-DuetPsmux display-message -p -t $r.Target '#{cursor_y}|#{pane_height}'
  if ($global:DUET_PSMUX_RC -ne 0) { return [pscustomobject]@{ Alive = $true; Ok = $false; CursorY = ''; Height = '' } }
  $parts = (("$out").Trim() -split '\|', 2)
  if ($parts.Count -ne 2) { return [pscustomobject]@{ Alive = $true; Ok = $false; CursorY = ''; Height = '' } }
  return [pscustomobject]@{ Alive = $true; Ok = $true; CursorY = $parts[0]; Height = $parts[1] }
}

# Read exactly one physical pane row. psmux trims trailing blank rows from a
# full `capture-pane -p`, while `#{cursor_y}` still addresses the untrimmed
# screen. An exact blank-row capture therefore succeeds with zero stdout lines;
# that is positive evidence of an empty row, not an UNKNOWN read.
function Invoke-DuetPaneRowCapture {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid, [long]$Row)
  if ($Row -lt 0) { return [pscustomobject]@{ Alive = $true; Ok = $false; Line = '' } }
  $r = Resolve-DuetPaneResolution -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid
  if (-not $r.Known) { return [pscustomobject]@{ Alive = $true; Ok = $false; Line = '' } }
  if (-not $r.Alive) { return [pscustomobject]@{ Alive = $false; Ok = $false; Line = '' } }
  $out = @(Invoke-DuetPsmux capture-pane -p -S ([string]$Row) -E ([string]$Row) -t $r.Target)
  if ($global:DUET_PSMUX_RC -ne 0 -or $out.Count -gt 1) {
    return [pscustomobject]@{ Alive = $true; Ok = $false; Line = '' }
  }
  $line = if ($out.Count -eq 1) { [string]$out[0] } else { '' }
  return [pscustomobject]@{ Alive = $true; Ok = $true; Line = $line }
}

function Send-DuetPaneKey {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid, [string[]]$Keys)
  $r = Resolve-DuetPaneResolution -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid
  if (-not $r.Known) { return [pscustomobject]@{ Alive = $true; Ok = $false } }   # UNKNOWN: issue no key
  if (-not $r.Alive) { return [pscustomobject]@{ Alive = $false; Ok = $false } }  # DEAD: issue no key
  $a = @('send-keys', '-t', $r.Target) + $Keys
  Invoke-DuetPsmux @a | Out-Null
  return [pscustomobject]@{ Alive = $true; Ok = ($global:DUET_PSMUX_RC -eq 0) }
}

# Capture -> normalized alnum tail. Ok=$false => could not read.
function Get-DuetTailAlnumT {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid, [int]$Lines = 6)
  $cap = Invoke-DuetPaneCapture -Session $Session -ServerPid $ServerPid -PaneId $PaneId -PanePid $PanePid
  if (-not $cap.Ok) { return [pscustomobject]@{ Ok = $false; Alive = $cap.Alive; Text = '' } }
  $ne = @($cap.Lines | Where-Object { $_ -match '\S' } | Select-Object -Last $Lines)
  return [pscustomobject]@{ Ok = $true; Alive = $true; Text = (Get-DuetAlnum ($ne -join '')) }
}

# Tuple-bound collapsed-paste marker. Marker='' means "none after a SUCCESSFUL
# read"; Ok=$false means "could not read" (UNKNOWN). Claude 2.1 renders the
# owned composer marker on the cursor row as `[Pastedtext#N+Mlines]` (spacing
# varies); older builds add a nearby "paste again to expand" hint. Codex uses
# `[Pasted Content N chars]` on the cursor row.
function Get-DuetClaudeComposerMarker {
  param([AllowEmptyString()][string]$Line)
  if ($null -eq $Line) { return '' }
  if ($Line -match '(?i)\[\s*Pasted\s*text\s*#[0-9]+(?:\s*\+\s*[0-9]+\s*lines?)?\s*\]') {
    $token = Get-DuetAlnum $Matches[0]
    if ($token) { return ('claude' + $token) }
  }
  return ''
}

function Get-DuetPaneMarker {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid,
    [string]$Harness = '')
  $cap = Invoke-DuetPaneCapture -Session $Session -ServerPid $ServerPid -PaneId $PaneId -PanePid $PanePid
  if (-not $cap.Ok) { return [pscustomobject]@{ Ok = $false; Alive = $cap.Alive; Marker = '' } }
  $lines = @($cap.Lines)
  $legacyLine = ''; $legacyComposer = $false; $framedClaudeMarker = ''
  # psmux may retain several blank physical rows below a TUI's status bar.
  # Scope the legacy active-composer pair over nonblank tail rows so those
  # blanks cannot hide a visible marker + "paste again" hint.
  foreach ($l in @($lines | Where-Object { $_ -match '\S' } | Select-Object -Last 10)) {
    if (Get-DuetClaudeComposerMarker $l) { $legacyLine = $l }
    if ($l -match '(?i)paste again to expand') { $legacyComposer = $true }
  }
  # Claude can leave the terminal cursor on its status row while a collapsed
  # paste occupies the composer. In that state cursor-row capture misses the
  # marker, but the active composer remains uniquely framed by its two bottom
  # horizontal rules. Limit this fallback to the physical tail and require the
  # nearest nonblank rows on both sides to be those rules; a marker appearing
  # only in transcript scrollback is never enough.
  if (-not $Harness -or $Harness -eq 'claude') {
    $tailStart = [Math]::Max(0, $lines.Count - 12)
    for ($lineIndex = $tailStart; $lineIndex -lt $lines.Count; $lineIndex++) {
      $candidate = Get-DuetClaudeComposerMarker $lines[$lineIndex]
      if (-not $candidate) { continue }
      $before = $lineIndex - 1
      while ($before -ge $tailStart -and $lines[$before] -notmatch '\S') { $before-- }
      $after = $lineIndex + 1
      while ($after -lt $lines.Count -and $lines[$after] -notmatch '\S') { $after++ }
      if ($before -lt $tailStart -or $after -ge $lines.Count) { continue }
      $beforeBars = ($lines[$before] -replace '[^\u2500\u2501\u2550-]', '').Length
      $afterBars = ($lines[$after] -replace '[^\u2500\u2501\u2550-]', '').Length
      if ($beforeBars -ge 8 -and $afterBars -ge 8) {
        $framedClaudeMarker = $candidate
      }
    }
  }
  if ((!$Harness -or $Harness -eq 'claude') -and $legacyComposer -and $legacyLine) {
    return [pscustomobject]@{
      Ok = $true
      Alive = $true
      Marker = (Get-DuetClaudeComposerMarker $legacyLine)
    }
  }
  if ($framedClaudeMarker) {
    return [pscustomobject]@{ Ok = $true; Alive = $true; Marker = $framedClaudeMarker }
  }
  $geometry = Invoke-DuetPaneGeometry -Session $Session -ServerPid $ServerPid -PaneId $PaneId -PanePid $PanePid
  if (-not $geometry.Ok) { return [pscustomobject]@{ Ok = $false; Alive = $geometry.Alive; Marker = '' } }
  # Malformed / overflowing / out-of-range cursor data is UNKNOWN (Ok=$false),
  # NEVER a "successfully empty composer" (which callers read as submitted).
  $cyval = [long]0; $height = [long]0
  if (-not [long]::TryParse(("$($geometry.CursorY)").Trim(), [ref]$cyval) `
      -or -not [long]::TryParse(("$($geometry.Height)").Trim(), [ref]$height) `
      -or $cyval -lt 0 -or $height -le 0 -or $cyval -ge $height) {
    return [pscustomobject]@{ Ok = $false; Alive = $true; Marker = '' }
  }
  $row = Invoke-DuetPaneRowCapture -Session $Session -ServerPid $ServerPid -PaneId $PaneId -PanePid $PanePid -Row $cyval
  if (-not $row.Ok) { return [pscustomobject]@{ Ok = $false; Alive = $row.Alive; Marker = '' } }
  # A redraw between the cursor query and row capture can otherwise make a
  # successful read refer to the wrong physical row. Treat movement as UNKNOWN.
  $geometryAfter = Invoke-DuetPaneGeometry -Session $Session -ServerPid $ServerPid -PaneId $PaneId -PanePid $PanePid
  if (-not $geometryAfter.Ok) { return [pscustomobject]@{ Ok = $false; Alive = $geometryAfter.Alive; Marker = '' } }
  $cyAfter = [long]0; $heightAfter = [long]0
  if (-not [long]::TryParse(("$($geometryAfter.CursorY)").Trim(), [ref]$cyAfter) `
      -or -not [long]::TryParse(("$($geometryAfter.Height)").Trim(), [ref]$heightAfter) `
      -or $cyAfter -ne $cyval -or $heightAfter -ne $height) {
    return [pscustomobject]@{ Ok = $false; Alive = $true; Marker = '' }
  }
  $rowline = $row.Line
  $claudeMarker = if (-not $Harness -or $Harness -eq 'claude') {
    Get-DuetClaudeComposerMarker $rowline
  } else { '' }
  if ($claudeMarker) {
    return [pscustomobject]@{ Ok = $true; Alive = $true; Marker = $claudeMarker }
  }
  if ((!$Harness -or $Harness -eq 'codex') -and $rowline -match '(?i)\[Pasted Content [0-9]+ chars\]') {
    $m = Get-DuetAlnum $Matches[0]
    if ($m) { return [pscustomobject]@{ Ok = $true; Alive = $true; Marker = ('codex' + $m) } }
  }
  if ((!$Harness -or $Harness -eq 'kimi') -and
      $rowline -match '(?i)\[paste #[0-9]+ \+[0-9]+ lines\]') {
    $m = Get-DuetAlnum $Matches[0]
    if ($m) { return [pscustomobject]@{ Ok = $true; Alive = $true; Marker = ('kimi' + $m) } }
  }
  return [pscustomobject]@{ Ok = $true; Alive = $true; Marker = '' }
}

function Test-DuetCodexMarkerOwned {
  param([string]$Current, [string]$Token)
  if (-not $Current -or -not $Token) { return $false }
  if ($Token -notmatch '^codex(PastedContent[0-9]+chars)+$') { return $false }
  if ($Current -eq $Token) { return $true }
  if (-not $Current.StartsWith($Token)) { return $false }
  return ($Current.Substring($Token.Length) -match '^(PastedContent[0-9]+chars)+$')
}

# Read + validate a session's psmux control registry (port + 16-hex key) keyed by
# the REGISTRY BASE (`<namespace>__<session>` under -L, else `<session>`).
function Get-DuetPsmuxRegistry {
  param([string]$Registry)
  if (-not (Test-DuetSafeName $Registry)) { return $null }
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $null }
  if (-not $userHome) { return $null }
  $dir = Join-Path $userHome '.psmux'
  $portTxt = Get-DuetFileText (Join-Path $dir ($Registry + '.port'))
  $keyTxt = Get-DuetFileText (Join-Path $dir ($Registry + '.key'))
  if ($null -eq $portTxt -or $null -eq $keyTxt) { return $null }
  $portTxt = $portTxt.Trim(); $keyTxt = $keyTxt.Trim()
  $port = 0
  if (-not [int]::TryParse($portTxt, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return $null }
  if ($keyTxt -notmatch '^[0-9a-f]{16}$') { return $null }
  return [pscustomobject]@{ Port = $port; Key = $keyTxt }
}

# The registry port MUST be owned by exactly one 127.0.0.1 listener whose pid is
# the recorded backend server pid, else a recycled/stale port could receive bytes.
function Test-DuetPortOwner {
  param([int]$Port, [string]$ExpectedPid)
  if (-not $ExpectedPid -or $ExpectedPid -notmatch '^[0-9]+$') { return $false }
  $owners = $null
  try {
    $conns = @(Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction Stop)
    $owners = @($conns | ForEach-Object { [string]$_.OwningProcess } | Sort-Object -Unique)
  }
  catch { $owners = Get-DuetPortOwnerNetstat -Port $Port }
  if ($null -eq $owners) { return $false }
  $owners = @($owners)
  if ($owners.Count -ne 1) { return $false }
  return ($owners[0] -eq $ExpectedPid)
}

# Fallback owner lookup via netstat when Get-NetTCPConnection is unavailable.
function Get-DuetPortOwnerNetstat {
  param([int]$Port)
  $pids = @{}
  foreach ($line in (netstat -ano -p tcp 2>$null)) {
    if ($line -notmatch 'LISTENING') { continue }
    $cols = ($line.Trim() -split '\s+')
    if ($cols.Count -lt 5) { continue }
    if ($cols[1] -ne "127.0.0.1:$Port") { continue }
    $pids[$cols[4]] = $true
  }
  return @($pids.Keys)
}

# Accumulate through the FIRST LF (bounded 64 bytes + stream timeout); return the
# first line with any trailing CR removed. TCP reads are partial by nature.
function Read-DuetControlOkLine {
  param($Stream)
  $acc = New-Object System.Collections.Generic.List[byte]
  $one = New-Object byte[] 1
  for ($i = 0; $i -lt 64; $i++) {
    $n = 0
    try { $n = $Stream.Read($one, 0, 1) } catch { break }
    if ($n -le 0) { break }
    if ($one[0] -eq 10) { break }
    $acc.Add($one[0])
  }
  return ([System.Text.Encoding]::ASCII.GetString($acc.ToArray())).TrimEnd("`r")
}

# The ONLY full-payload paste. psmux authenticated one-shot TCP send-paste,
# argv-free (the CLI base64 arg hits the ~32,767-char Windows CreateProcess
# ceiling near a 24 KB raw payload). Models psmux src/session.rs:765-793. Wire
# (UTF-8, newline-framed):
#   AUTH <key>\n  TARGET <session>:<pane_id>\n  send-paste <base64-utf8>\n
# Returns DUET_PASTE_PREWRITE_FAILED / _WIRE_SENT / _UNCERTAIN. The server's `OK`
# is only the AUTH ack (emitted before it reads the command), so a completed wire
# write WITHOUT an exact OK is UNCERTAIN (never repaste), not a clean failure.
function Send-DuetControlPaste {
  param([string]$Session, [string]$PaneId, [string]$PanePid, [string]$ServerPid, [AllowEmptyString()][string]$Payload,
    [string]$Registry = $global:DUET_PSMUX_REGISTRY)
  if (-not $Registry) { $Registry = $Session }   # non-namespaced: registry base == raw session
  $reg = Get-DuetPsmuxRegistry -Registry $Registry
  if (-not $reg) { Write-DuetError "duet: no psmux control registry (.port/.key) for '$Registry'"; return $global:DUET_PASTE_PREWRITE_FAILED }
  if (-not (Resolve-DuetPaneTarget -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid)) { return $global:DUET_PASTE_PREWRITE_FAILED }
  if (-not (Test-DuetPortOwner -Port $reg.Port -ExpectedPid $ServerPid)) {
    Write-DuetError "duet: registry port $($reg.Port) is not owned solely by backend pid $ServerPid; refusing to send."
    return $global:DUET_PASTE_PREWRITE_FAILED
  }
  # Listener-owner inspection can take >1s; re-resolve the tuple once more,
  # immediately before connect, so pane recycling during that window cannot
  # slip past the fence.
  if (-not (Resolve-DuetPaneTarget -PaneId $PaneId -PanePid $PanePid -Session $Session -ServerPid $ServerPid)) { return $global:DUET_PASTE_PREWRITE_FAILED }
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Payload))
  $bytes = [System.Text.Encoding]::UTF8.GetBytes("AUTH $($reg.Key)`nTARGET ${Session}:${PaneId}`nsend-paste $b64`n")
  $client = New-Object System.Net.Sockets.TcpClient
  $wireStarted = $false
  try {
    $iar = $client.BeginConnect('127.0.0.1', $reg.Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(1500)) { return $global:DUET_PASTE_PREWRITE_FAILED }
    $client.EndConnect($iar)
    $client.NoDelay = $true; $client.SendTimeout = 5000; $client.ReceiveTimeout = 2000
    $stream = $client.GetStream()
    $wireStarted = $true
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    if ((Read-DuetControlOkLine -Stream $stream) -eq 'OK') { return $global:DUET_PASTE_WIRE_SENT }
    return $global:DUET_PASTE_UNCERTAIN
  }
  catch {
    if ($wireStarted) { return $global:DUET_PASTE_UNCERTAIN }
    Write-DuetError "duet: control-paste connect error: $($_.Exception.Message)"
    return $global:DUET_PASTE_PREWRITE_FAILED
  }
  finally { try { $client.Close() } catch { } }
}

function New-DuetSendResult {
  param([int]$Code, [string]$EnterToken = '', [bool]$Collapsed = $false,
    [string]$LandingObserved = '', [bool]$ComposerClear = $false,
    [string]$WireOutcome = '')
  return [pscustomobject]@{
    Code = $Code
    EnterToken = $EnterToken
    Collapsed = $Collapsed
    LandingObserved = $LandingObserved
    ComposerClear = $ComposerClear
    WireOutcome = $WireOutcome
  }
}

# Paste, confirm it landed (probe or collapsed marker), Enter, confirm the
# composer cleared; retry Enter (a later Enter submits when the first raced the
# paste). Returns Code 0 ONLY on verified submission.
function Send-DuetVerified {
  param([string]$PaneId, [string]$PanePid, [AllowEmptyString()][string]$Payload, [bool]$Interrupt, [string]$Harness,
    [string]$Session = $global:DUET_PSMUX_SESSION, [string]$ServerPid = $global:DUET_PSMUX_SERVER_PID,
    [string]$Registry = $global:DUET_PSMUX_REGISTRY)
  $fence = @{ Session = $Session; ServerPid = $ServerPid; PaneId = $PaneId; PanePid = $PanePid }
  $entry = Resolve-DuetPaneResolution @fence
  if (-not $entry.Known) { Write-DuetError "duet: target pane $PaneId is unresolvable (unknown); not sending."; return (New-DuetSendResult -Code $global:DUET_SEND_NOT_LANDED) }
  if (-not $entry.Alive) { Write-DuetError "duet: target pane $PaneId is gone; not sending."; return (New-DuetSendResult -Code $global:DUET_SEND_DEAD) }

  if ($Interrupt) {
    $interruptKey = Send-DuetPaneKey @fence -Keys @('Escape')
    if (-not $interruptKey.Alive) { return (New-DuetSendResult -Code $global:DUET_SEND_DEAD) }
    if (-not $interruptKey.Ok) { return (New-DuetSendResult -Code $global:DUET_SEND_NOT_LANDED) }
    # Full-screen Windows TUIs redraw through psmux more slowly than tmux's
    # POSIX path. Give cancellation a bounded settle before reading/pasting.
    Start-Sleep -Milliseconds $(if ($Harness -eq 'claude') { 1000 } else { 600 })
  }

  $probe = Get-DuetProbe $Payload
  if (-not $probe) { Write-DuetError "duet: refusing to send an empty/unprobeable payload to $PaneId"; return (New-DuetSendResult -Code $global:DUET_SEND_NOT_LANDED) }

  # A clean composer must be POSITIVELY confirmed (successful read) before paste.
  $mb = Get-DuetPaneMarker @fence -Harness $Harness
  if (-not $mb.Alive) { return (New-DuetSendResult -Code $global:DUET_SEND_DEAD) }
  if (-not $mb.Ok) { Write-DuetError "duet: could not read composer state of $PaneId; not pasting."; return (New-DuetSendResult -Code $global:DUET_SEND_NOT_LANDED) }
  if ($mb.Marker) { Write-DuetError "duet: target pane $PaneId already has a collapsed composer; not pasting."; return (New-DuetSendResult -Code $global:DUET_SEND_NOT_LANDED) }
  $markerBefore = $mb.Marker

  $pasteOutcome = Send-DuetControlPaste -Session $Session -PaneId $PaneId -PanePid $PanePid -ServerPid $ServerPid -Registry $Registry -Payload $Payload
  if ($pasteOutcome -eq $global:DUET_PASTE_UNCERTAIN) {
    # Bytes may already occupy the composer -- NEVER repaste. Continue only
    # through the normal visual landing proof below; if the exact probe/owned
    # marker appears, an Enter-only continuation is safe and still requires a
    # successful read proving that the composer cleared.
    Write-DuetError "duet: paste acknowledgment from pane $PaneId is uncertain; verifying visible landing without repaste."
  }
  elseif ($pasteOutcome -ne $global:DUET_PASTE_WIRE_SENT) {
    # PREWRITE_FAILED: provably nothing was sent. DEAD only when confirmed dead.
    $pr = Resolve-DuetPaneResolution @fence
    if ($pr.Known -and -not $pr.Alive) { return (New-DuetSendResult -Code $global:DUET_SEND_DEAD) }
    Write-DuetError "duet: paste prewrite failed for pane $PaneId"; return (New-DuetSendResult -Code $global:DUET_SEND_NOT_LANDED)
  }

  # Landing poll -- a landing is concluded ONLY from a successful read.
  $landingKind = ''; $landingToken = ''; $enterToken = ''; $collapsed = $false
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 100
    $ta = Get-DuetTailAlnumT @fence -Lines 12
    if ($ta.Ok -and (Test-DuetPresent $ta.Text $probe)) { $landingKind = 'probe'; $landingToken = $probe; break }
    $mk = Get-DuetPaneMarker @fence -Harness $Harness
    if ($mk.Ok -and $mk.Marker -and $mk.Marker -ne $markerBefore) { $landingKind = 'marker'; $landingToken = $mk.Marker; $enterToken = $mk.Marker; $collapsed = $true; break }
  }
  if (-not $landingKind) {
    Write-DuetError "duet: paste succeeded but landing is unverified in pane $PaneId"
    return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED `
        -WireOutcome $pasteOutcome)
  }
  $landingObserved = $landingKind

  # Enter, then confirm submission ONLY via a successful read showing absence.
  for ($e = 0; $e -lt 3; $e++) {
    $k = Send-DuetPaneKey @fence -Keys @('Enter')
    if (-not $k.Alive) { return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED -EnterToken $enterToken -Collapsed $collapsed -LandingObserved $landingObserved) }
    if (-not $k.Ok) { continue }   # Enter send failed; retry, never claim success this round
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 200
      if ($landingKind -eq 'probe') {
        $ta = Get-DuetTailAlnumT @fence -Lines 4
        if (-not $ta.Alive) { return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED -LandingObserved $landingObserved) }
        if ($ta.Ok -and -not (Test-DuetPresent $ta.Text $landingToken)) { return (New-DuetSendResult -Code 0 -LandingObserved $landingObserved) }
      }
      else {
        $mk = Get-DuetPaneMarker @fence -Harness $Harness
        if (-not $mk.Alive) { return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED -EnterToken $enterToken -Collapsed $collapsed -LandingObserved $landingObserved) }
        if ($mk.Ok) {
          if (-not $mk.Marker) { return (New-DuetSendResult -Code 0 -EnterToken $enterToken -Collapsed $collapsed -LandingObserved $landingObserved) }
          if ($Harness -eq 'codex' -and (Test-DuetCodexMarkerOwned $mk.Marker $landingToken)) { $landingToken = $mk.Marker; $enterToken = $mk.Marker }
          elseif ($mk.Marker -ne $landingToken) { Write-DuetError "duet: collapsed composer changed ownership in pane $PaneId"; return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED -EnterToken $enterToken -Collapsed $collapsed -LandingObserved $landingObserved) }
        }
      }
    }
  }
  $mfinal = Get-DuetPaneMarker @fence -Harness $Harness
  if ($Harness -eq 'codex' -and $landingKind -eq 'marker' -and $mfinal.Ok -and (Test-DuetCodexMarkerOwned $mfinal.Marker $landingToken)) {
    Write-DuetError "duet: Codex composer retained an owned collapsed paste after Enter."
    return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED -EnterToken $enterToken -Collapsed $collapsed -LandingObserved 'marker')
  }
  Write-DuetError "duet: payload landed in pane $PaneId but submission is unverified."
  return (New-DuetSendResult -Code $global:DUET_SEND_LANDED_UNVERIFIED -EnterToken $enterToken `
      -Collapsed $collapsed -LandingObserved $landingObserved -WireOutcome $pasteOutcome)
}

Write-Verbose "duet-common.ps1 loaded"
