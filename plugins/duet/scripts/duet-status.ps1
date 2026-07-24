# Inspect exactly one explicitly pinned Windows/psmux v4 session.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Session)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

function Get-DuetInboxDepth {
  param([string]$DuetDir, [string]$Queue)
  $box = Join-Path (Join-Path $DuetDir 'inbox') $Queue
  if (-not (Test-Path -LiteralPath $box -PathType Container)) { return 0 }
  return @(Get-ChildItem -LiteralPath $box -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' }).Count
}

if (-not (Resolve-DuetConfig -SessionArg $Session -RequireEnvironment 0)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not $global:DUET_CONFIG_VALID -or
    -not (Test-DuetLoadedSession -Config $cfg -ConfigPath $cfgPath)) { exit 1 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = $global:DUET_DIR
$Sid = $global:DUET_SESSION_ID
$RosterPath = Join-Path $DuetDir 'roster.tsv'
$rosterRows = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) {
  Write-DuetError "duet: session roster is invalid: $RosterPath"
  exit 1
}

$lifecycle = if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { 'ended' } else { 'active' }
$daemonPid = Get-DuetFileText (Join-Path $DuetDir 'daemon.pid')
if ($daemonPid) { $daemonPid = $daemonPid.Trim() } else { $daemonPid = '-' }
$daemonState = if (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid) { 'alive' } else { 'dead' }
$backendState = if (Test-DuetServerMatches) { 'matched' } else { 'mismatch' }

Write-Output "session     : $Sid"
Write-Output "session dir : $DuetDir"
Write-Output "workdir     : $($cfg['WORKDIR'])"
Write-Output "psmux       : $backendState namespace=$($cfg['DUET_PSMUX_NAMESPACE']) session=$($cfg['DUET_PSMUX_SESSION']) backend=$($cfg['DUET_PSMUX_SERVER_PID'])"
Write-Output "lifecycle   : $lifecycle"
Write-Output "initiator   : $($cfg['DUET_INITIATOR'])"
Write-Output "daemon      : $daemonState pid=$daemonPid"
Write-Output "queues      : total=$(Get-DuetPendingCount $DuetDir)"
$unhealthy = Get-DuetFileText (Join-Path $DuetDir '.unhealthy')
if ($unhealthy) { Write-Output "unhealthy   : $($unhealthy.Trim())" }

Write-Output ''
Write-Output ('{0,-12} {1,-8} {2,4} {3,-6} {4,-8} {5,-9} {6,-5} {7,5}' -f
  'NAME', 'HARNESS', 'RANK', 'PANE', 'PID', 'STATE', 'READY', 'INBOX')
foreach ($row in $rosterRows) {
  $resolution = Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid
  $state = if (-not $resolution.Known) {
    'unknown'
  } elseif ($resolution.Alive) {
    'alive'
  } else { 'dead' }
  if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'dead') $row.name)) {
    $state = 'dead'
  }
  if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'blocked') $row.name)) {
    $state = 'blocked'
  }
  $ready = if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $row.name)) {
    'yes'
  } else { 'no' }
  $depth = Get-DuetInboxDepth -DuetDir $DuetDir -Queue $row.name
  Write-Output ('{0,-12} {1,-8} {2,4} {3,-6} {4,-8} {5,-9} {6,-5} {7,5}' -f
    $row.name, $row.harness, $row.rank, $row.pane_id, $row.pane_pid,
    $state, $ready, $depth)
}
exit 0
