# One live delivery daemon for one explicitly pinned Windows/psmux v4 session.
#
# Delivery state is intentionally process-local. A daemon crash invalidates the
# session; it is never restarted or replayed.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Session,
  [Parameter(Mandatory = $true)][string]$SessionId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir 'duet-common.ps1')

if (-not (Resolve-DuetConfig -SessionArg $Session -RequireEnvironment 1)) {
  Write-DuetError "duet: daemon could not resolve pinned session '$Session'"
  exit 1
}
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not $global:DUET_CONFIG_VALID -or
    -not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $SessionId -ConfigPath $cfgPath)) {
  exit 1
}
if ($cfg['DUET_SESSION_ID'] -ne $SessionId) {
  Write-DuetError 'duet: daemon command identity does not match the pinned session.'
  exit 1
}
Set-DuetSessionVariables -Config $cfg
$env:DUET_CONFIG = $cfgPath
$env:DUET_SESSION = $cfg['DUET_SESSION_ID']
$DuetDir = $global:DUET_DIR
$RosterPath = Join-Path $DuetDir 'roster.tsv'
. (Join-Path $SelfDir 'duet-deliverd.lib.ps1')

if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { exit 0 }
if (Test-Path -LiteralPath (Join-Path $DuetDir '.unhealthy')) {
  Write-DuetError 'duet: unhealthy sessions cannot restart their delivery daemon.'
  exit 1
}
$null = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) {
  Write-DuetError 'duet: session roster is invalid; daemon will not start.'
  exit 1
}
if (-not (Test-DuetServerMatches)) {
  Write-DuetError 'duet: psmux backend identity mismatch; daemon will not start.'
  exit 1
}

$pidPath = Join-Path $DuetDir 'daemon.pid'
$lockPath = Join-Path $DuetDir '.daemon.lock'
if ((Test-Path -LiteralPath $pidPath) -or (Test-Path -LiteralPath $lockPath)) {
  Set-DuetSessionUnhealthy 'stale daemon state found; session restart is forbidden'
  exit 1
}
if (-not (Lock-DuetAcquire $lockPath 1)) {
  Write-DuetError 'duet: another delivery daemon already owns this session.'
  exit 1
}

$daemonActive = $true
$orderlyStop = $false
$exitCode = 0
$pollMilliseconds = 100
$pollSeconds = [double]0
if ($env:DUET_DELIVERY_POLL_INTERVAL -and
    [double]::TryParse(
      $env:DUET_DELIVERY_POLL_INTERVAL,
      [Globalization.NumberStyles]::Float,
      [Globalization.CultureInfo]::InvariantCulture,
      [ref]$pollSeconds
    ) -and $pollSeconds -gt 0) {
  $pollMilliseconds = [Math]::Max(1, [Math]::Min(3600000, [int]($pollSeconds * 1000)))
}
try {
  if (-not (Write-DuetAtomicMultiline -Path $pidPath -Value ([string]$PID))) {
    Write-DuetError 'duet: could not publish daemon.pid.'
    $exitCode = 1
  }
  else {
    Write-DuetDeliverdLog "daemon up pid=$PID"
    while (-not (Test-Path -LiteralPath (Join-Path $DuetDir '.ended'))) {
      if (-not (Test-DuetServerMatches)) {
        Set-DuetSessionUnhealthy 'psmux backend identity changed'
        $exitCode = 1
        break
      }
      if (-not (Invoke-DuetDeliverdPass)) {
        if (-not (Test-Path -LiteralPath (Join-Path $DuetDir '.unhealthy'))) {
          Set-DuetSessionUnhealthy 'delivery pass failed'
        }
        $exitCode = 1
        break
      }
      Start-Sleep -Milliseconds $pollMilliseconds
    }
    if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) {
      $orderlyStop = $true
      Write-DuetDeliverdLog 'daemon stop'
    }
  }
}
catch {
  if (-not (Test-Path -LiteralPath (Join-Path $DuetDir '.ended'))) {
    Set-DuetSessionUnhealthy ("delivery daemon exception: " + $_.Exception.Message)
  }
  $exitCode = 1
}
finally {
  $recorded = Get-DuetFileText $pidPath
  if ($recorded -and $recorded.Trim() -eq [string]$PID) {
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
  }
  if (-not (Unlock-DuetRelease $lockPath)) {
    Write-DuetDeliverdLog "daemon lock cleanup failed owner=$(Get-DuetLockOwner $lockPath)"
  }
  if ($daemonActive -and -not $orderlyStop -and
      -not (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) -and
      -not (Test-Path -LiteralPath (Join-Path $DuetDir '.unhealthy'))) {
    Set-DuetSessionUnhealthy "delivery daemon exited unexpectedly (status $exitCode)"
  }
}
exit $exitCode
