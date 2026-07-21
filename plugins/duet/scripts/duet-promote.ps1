# Hand leadership of a pinned duet session to one explicit live member.
# Native params: duet-promote.ps1 -To <roster-name> [-Session <cfg>]
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
$explicitSession = $PSBoundParameters.ContainsKey('Session') -and -not [string]::IsNullOrWhiteSpace($Session)
$hadCaller = Get-DuetCallerIdentity
$actualCallerSession = if ($hadCaller) { $global:DUET_CALLER_SESSION } else { '' }
$actualCallerServerPid = if ($hadCaller) { $global:DUET_CALLER_SERVER_PID } else { '' }

if ([string]::IsNullOrWhiteSpace($To)) { Write-DuetError "duet: -To is required for a manual handoff."; exit 2 }

if (-not (Resolve-DuetConfig $Session 0)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $callerPin -ConfigPath $cfgPath)) { exit 7 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = Get-DuetCanonicalPath $cfg['DUET_DIR']
$Sid = $cfg['DUET_SESSION_ID']
$RosterPath = Join-Path $DuetDir 'roster.tsv'
if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { Write-DuetError "duet: session has ended; refusing handoff."; exit 1 }
if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) { Write-DuetError "duet: delivery daemon is not alive; refusing handoff."; exit 6 }
if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { exit 1 }

$paneName = ''
if (Get-DuetCallerRosterName -RosterPath $RosterPath -ExpectedSession $cfg['DUET_PSMUX_SESSION'] -ExpectedServerPid $cfg['DUET_PSMUX_SERVER_PID']) { $paneName = $global:DUET_CALLER_NAME }
if ($paneName -and $callerSelf -and $paneName -ne $callerSelf) { Write-DuetError "duet: identity mismatch: pane is '$paneName' but DUET_SELF is '$callerSelf'."; exit 7 }
if (-not $paneName -and $hadCaller -and ($actualCallerSession -ne $cfg['DUET_PSMUX_SESSION'] -or $actualCallerServerPid -ne $cfg['DUET_PSMUX_SERVER_PID'])) {
  Write-DuetError "duet: caller belongs to psmux session '$actualCallerSession', not pinned session '$Sid'."
  exit 7
}
if (-not $paneName -and -not $explicitSession) { Write-DuetError "duet: an external shell must pin the target with -Session."; exit 7 }

$requested = Resolve-DuetRosterName -RosterPath $RosterPath -Token $To
if (-not $requested) { Write-DuetError "duet: unknown or ambiguous handoff target."; exit 2 }

$lock = Join-Path $DuetDir '.delivery.lock'
if (-not (Lock-DuetAcquire $lock 200)) { Write-DuetError "duet: could not acquire the delivery/handoff fence."; exit 1 }
try {
  if ((Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) -or (Test-Path -LiteralPath (Join-Path $DuetDir '.draining'))) { Write-DuetError "duet: session ended or began draining while the handoff waited; refusing mutation."; exit 1 }
  if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) { Write-DuetError "duet: delivery daemon stopped while the handoff waited; refusing mutation."; exit 6 }
  if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { exit 1 }
  $expTerm = $global:DUET_CURRENT_TERM
  $expLeader = $global:DUET_CURRENT_LEADER
  $reason = 'MANUAL:' + $(if ($paneName) { $paneName } else { 'operator' })
  $rc = Invoke-DuetPromoteLocked -DuetDir $DuetDir -SessionId $Sid -RosterPath $RosterPath -ExpectedTerm $expTerm -ExpectedLeader $expLeader -Reason $reason -Requested $requested
  switch ($rc) {
    0 { Write-Output "duet: handed off generation $($global:DUET_PROMOTED_TERM) to $($global:DUET_PROMOTED_LEADER); notice queued before the leader update." }
    11 { Write-DuetError "duet: handoff blocked by uncertain delivery. Let the delivery daemon finish recovery, then retry."; exit 5 }
    2 { Write-DuetError "duet: handoff lost the generation compare-and-swap; retry."; exit 4 }
    3 { Write-DuetError "duet: target must be a live, noncurrent session member."; exit 4 }
    4 { Write-DuetError "duet: durable manual handoff intent could not be verified."; exit 4 }
    default { Write-DuetError "duet: handoff transaction failed."; exit $rc }
  }
}
finally { [void](Unlock-DuetRelease $lock) }
exit 0
