# Single-session delivery daemon for the Windows/psmux ensemble path. Fairly
# advances at most one message per logical recipient queue per pass; ALL pane
# injection lives in the tuple-bound verified-send FSM (duet-common.ps1). Launched
# detached by duet-init.ps1; exits when <DUET_DIR>\.ended appears.
# NATIVE PowerShell params (GNU --flags mis-bind under -File):
#   powershell -File duet-deliverd.ps1 -Session <duet.env|dir|id> -SessionId <id>
[CmdletBinding()]
param(
  [string]$Session,
  [string]$SessionId
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir 'duet-common.ps1')

if (-not (Resolve-DuetConfig $Session 0)) { [Console]::Error.WriteLine("duet: daemon could not resolve session '$Session'"); exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $SessionId -ConfigPath $cfgPath)) { exit 1 }
if ($cfg['DUET_SESSION_ID'] -ne $SessionId) { [Console]::Error.WriteLine("duet: daemon session-id mismatch"); exit 1 }
Set-DuetSessionVariables -Config $cfg

$DuetDir = Get-DuetCanonicalPath $cfg['DUET_DIR']
$Sid = $cfg['DUET_SESSION_ID']
$RosterPath = Join-Path $DuetDir 'roster.tsv'
$DUET_DELIVERY_MAX_ATTEMPTS = 5
. (Join-Path $SelfDir 'duet-deliverd.lib.ps1')

if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { exit 0 }

# Backend-pid identity: refuse to start against a changed/absent server. Exact
# (list-panes -s -t) equality, not the -a scan; a missing/mismatched pid rejects.
if (-not (Test-DuetServerMatches)) { [Console]::Error.WriteLine("duet: backend identity mismatch; daemon will not start."); exit 1 }

if (-not (Lock-DuetAcquire (Join-Path $DuetDir '.daemon.lock') 40)) { [Console]::Error.WriteLine("duet: another delivery daemon already owns this session."); exit 1 }
try {
  if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir 'daemon.pid') -Value ([string]$PID))) { [Console]::Error.WriteLine("duet: could not publish daemon.pid; not starting."); exit 1 }
  DLog "daemon up pid=$PID"
  while (-not (Test-Path -LiteralPath (Join-Path $DuetDir '.ended'))) {
    if (-not (Test-DuetServerMatches)) { DLog "backend identity changed; halting"; break }
    if (-not (Lock-DuetAcquire (Join-Path $DuetDir '.delivery.lock') 40)) { DLog "could not acquire delivery-pass fence; halting"; break }
    $ok = $false
    try { $ok = Deliverd-Pass } finally { [void](Unlock-DuetRelease (Join-Path $DuetDir '.delivery.lock')) }
    if (-not $ok) { DLog "delivery state transition failed; halting"; break }
    Start-Sleep -Milliseconds 200
  }
  DLog "daemon stop"
}
finally {
  $rec = Get-DuetFileText (Join-Path $DuetDir 'daemon.pid'); if ($rec) { $rec = $rec.Trim() }
  if ($rec -eq [string]$PID) { Remove-Item -LiteralPath (Join-Path $DuetDir 'daemon.pid') -Force -ErrorAction SilentlyContinue }
  [void](Unlock-DuetRelease (Join-Path $DuetDir '.daemon.lock'))
}
