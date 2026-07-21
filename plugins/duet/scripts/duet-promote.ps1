# Manually advance a pinned duet session through the same fenced promotion
# transaction the delivery watchdog uses. Native params:
#   duet-promote.ps1 [-To <roster-name>] [-Session <cfg>]
[CmdletBinding()]
param(
  [string]$To,
  [string]$Session
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

$callerPin = $env:DUET_SESSION
$callerSelf = $env:DUET_SELF

if (-not (Resolve-DuetConfig $Session 0)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $callerPin -ConfigPath $cfgPath)) { exit 7 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = Get-DuetCanonicalPath $cfg['DUET_DIR']
$Sid = $cfg['DUET_SESSION_ID']
$RosterPath = Join-Path $DuetDir 'roster.tsv'
if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { Write-DuetError "duet: session has ended; refusing promotion."; exit 1 }
if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) { Write-DuetError "duet: delivery daemon is not alive; refusing promotion."; exit 6 }
if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { exit 1 }

$paneName = ''
if (Get-DuetCallerRosterName -RosterPath $RosterPath -ExpectedSession $cfg['DUET_PSMUX_SESSION'] -ExpectedServerPid $cfg['DUET_PSMUX_SERVER_PID']) { $paneName = $global:DUET_CALLER_NAME }
if ($paneName -and $callerSelf -and $paneName -ne $callerSelf) { Write-DuetError "duet: identity mismatch: pane is '$paneName' but DUET_SELF is '$callerSelf'."; exit 7 }
if (-not $paneName -and -not $env:DUET_ALLOW_PROMOTE_OVERRIDE) { Write-DuetError "duet: manual promotion requires the current leader pane or DUET_ALLOW_PROMOTE_OVERRIDE=1."; exit 7 }
if ($paneName -and $paneName -ne $global:DUET_CURRENT_LEADER) { Write-DuetError "duet: only current leader '$($global:DUET_CURRENT_LEADER)' may promote; caller is '$paneName'."; exit 7 }

$requested = ''
if ($To) {
  $requested = Resolve-DuetRosterName -RosterPath $RosterPath -Token $To
  if (-not $requested) { Write-DuetError "duet: unknown or ambiguous promotion target."; exit 2 }
}

$lock = Join-Path $DuetDir '.delivery.lock'
if (-not (Lock-DuetAcquire $lock 200)) { Write-DuetError "duet: could not acquire the delivery/promotion fence."; exit 1 }
try {
  if ((Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) -or (Test-Path -LiteralPath (Join-Path $DuetDir '.draining'))) { Write-DuetError "duet: session ended or began draining while promotion waited; refusing mutation."; exit 1 }
  if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) { Write-DuetError "duet: delivery daemon stopped while promotion waited; refusing mutation."; exit 6 }
  if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { exit 1 }
  $expTerm = $global:DUET_CURRENT_TERM
  $expLeader = $global:DUET_CURRENT_LEADER
  if ($paneName -and $paneName -ne $expLeader) { Write-DuetError "duet: leadership changed while waiting for the fence; retry from '$expLeader'."; exit 7 }
  $reason = 'MANUAL:' + $(if ($paneName) { $paneName } else { 'admin' })
  $rc = Invoke-DuetPromoteLocked -DuetDir $DuetDir -SessionId $Sid -RosterPath $RosterPath -ExpectedTerm $expTerm -ExpectedLeader $expLeader -Reason $reason -Requested $requested
  switch ($rc) {
    0 { Write-Output "duet: promoted term $($global:DUET_PROMOTED_TERM) leader $($global:DUET_PROMOTED_LEADER); notice queued first." }
    10 { Write-DuetError "duet: term advanced to $($global:DUET_PROMOTED_TERM) with no live eligible successor (leader NONE)." }
    11 { Write-DuetError "duet: promotion deferred until an uncertain composer is resolved by the delivery daemon."; exit 5 }
    2 { Write-DuetError "duet: promotion lost the term compare-and-swap; retry."; exit 4 }
    3 { Write-DuetError "duet: requested successor is dead, excluded, or the incumbent."; exit 4 }
    default { Write-DuetError "duet: promotion transaction failed."; exit $rc }
  }
}
finally { [void](Unlock-DuetRelease $lock) }
exit 0
