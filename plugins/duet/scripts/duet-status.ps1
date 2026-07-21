# Print the state of one exact Windows/psmux ensemble session.
[CmdletBinding()]
param([string]$Session)

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

function Get-DuetWorkdirFenceState {
  param([hashtable]$Config, [string]$DuetDir)
  $workdir = Get-DuetCanonicalPath $Config['WORKDIR']
  $root = Get-DuetCanonicalPath $Config['DUET_STATE_ROOT']
  if (-not $workdir -or -not $root) { return [pscustomobject]@{ State = 'invalid-workdir'; Key = '-' } }
  $key = Get-DuetWorkdirKey $workdir
  if (-not $key) { return [pscustomobject]@{ State = 'invalid-workdir'; Key = '-' } }
  if ($Config['DUET_WORKDIR_KEY'] -and $Config['DUET_WORKDIR_KEY'] -ne $key) { return [pscustomobject]@{ State = 'key-mismatch'; Key = $key } }
  $active = Join-Path (Join-Path $root 'workdirs') ($key + '.active')
  $text = Get-DuetFileText $active
  if ($text) { $text = $text.Trim() }
  if ($text -and $text -eq $DuetDir) {
    $state = if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { 'stale-ended-owner' } else { 'owned' }
  }
  elseif ($text) { $state = 'other:' + $text }
  elseif (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { $state = 'released' }
  else { $state = 'missing' }
  return [pscustomobject]@{ State = $state; Key = $key }
}

$callerPin = $env:DUET_SESSION
if (-not (Resolve-DuetConfig $Session 1)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $callerPin -ConfigPath $cfgPath)) { exit 1 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = Get-DuetCanonicalPath $cfg['DUET_DIR']
$Sid = $cfg['DUET_SESSION_ID']
$RosterPath = Join-Path $DuetDir 'roster.tsv'
if (-not (Test-Path -LiteralPath $RosterPath -PathType Leaf)) { Write-DuetError "duet: session roster is missing: $RosterPath"; exit 1 }
$rosterRows = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) { Write-DuetError "duet: session roster is invalid: $RosterPath"; exit 1 }
if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { exit 1 }

$lifecycle = if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { 'ended' } elseif (Test-Path -LiteralPath (Join-Path $DuetDir '.draining')) { 'draining' } else { 'active' }
$daemonPid = Get-DuetFileText (Join-Path $DuetDir 'daemon.pid')
if ($daemonPid) { $daemonPid = $daemonPid.Trim() } else { $daemonPid = '-' }
$daemonState = if (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid) { 'alive' } else { 'DEAD' }
$backendState = if (Test-DuetServerMatches) { 'matched' } else { 'MISMATCH' }
$fence = Get-DuetWorkdirFenceState -Config $cfg -DuetDir $DuetDir

$promotionFiles = @()
$promotionBox = Join-Path (Join-Path $DuetDir 'inbox') 'promotions'
if (Test-Path -LiteralPath $promotionBox) {
  $promotionFiles = @(Get-ChildItem -LiteralPath $promotionBox -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' } | Sort-Object Name)
}
$promotionFirst = '-'; $promotionTerm = '-'; $promotionTarget = '-'
if ($promotionFiles.Count -gt 0) {
  $promotionFirst = Get-DuetFirstLineValue -Path $promotionFiles[0].FullName -Key 'id'
  $promotionTerm = Get-DuetFirstLineValue -Path $promotionFiles[0].FullName -Key 'term'
  $promotionTarget = Get-DuetFirstLineValue -Path $promotionFiles[0].FullName -Key 'recipient'
}

Write-Output "session       : $Sid"
Write-Output "session dir   : $DuetDir"
Write-Output "workdir       : $($cfg['WORKDIR'])"
Write-Output "workdir fence : $($fence.State) key=$($fence.Key)"
Write-Output "psmux         : $backendState namespace=$($cfg['DUET_PSMUX_NAMESPACE']) session=$($cfg['DUET_PSMUX_SESSION']) backend=$($cfg['DUET_PSMUX_SERVER_PID'])"
Write-Output "lifecycle     : $lifecycle"
Write-Output "leadership    : generation=$($global:DUET_CURRENT_TERM) leader=$($global:DUET_CURRENT_LEADER) (manual handoff only)"
Write-Output "daemon        : $daemonState pid=$daemonPid"
$queueLine = "queues        : total=$(Get-DuetPendingCount $DuetDir) symbolic-leader=$(Get-DuetInboxDepth $DuetDir 'leader') handoffs=$($promotionFiles.Count)"
if ($promotionFiles.Count -gt 0) { $queueLine += " first=$promotionFirst term=$promotionTerm target=$promotionTarget" }
Write-Output $queueLine

Write-Output ''
Write-Output ('{0,-12} {1,-8} {2,4} {3,-8} {4,-6} {5,-8} {6,-12} {7,-5} {8,5}' -f 'NAME', 'HARNESS', 'RANK', 'ROLE', 'PANE', 'PID', 'STATE', 'READY', 'INBOX')
foreach ($row in $rosterRows) {
  $res = Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid
  $state = if (-not $res.Known) { 'UNKNOWN' } elseif ($res.Alive) { 'alive' } else { 'dead' }
  $role = if ($row.name -eq $global:DUET_CURRENT_LEADER) { 'leader' } else { 'worker' }
  $ready = if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $row.name)) { 'yes' } else { 'no' }
  $depth = Get-DuetInboxDepth -DuetDir $DuetDir -Queue $row.name
  Write-Output ('{0,-12} {1,-8} {2,4} {3,-8} {4,-6} {5,-8} {6,-12} {7,-5} {8,5}' -f $row.name, $row.harness, $row.rank, $role, $row.pane_id, $row.pane_pid, $state, $ready, $depth)
}

$leaderRow = @($rosterRows | Where-Object { $_.name -eq $global:DUET_CURRENT_LEADER })
if ($leaderRow.Count -ne 1) {
  Write-Output ''
  Write-Output 'leader state  : UNKNOWN (leader is absent from the roster); no handoff target is recommended.'
}
else {
  $leaderResolution = Resolve-DuetPaneResolution -PaneId $leaderRow[0].pane_id -PanePid $leaderRow[0].pane_pid
  Write-Output ''
  if (-not $leaderResolution.Known) {
    Write-Output 'leader state  : UNKNOWN (pane identity could not be resolved); no handoff target is recommended.'
  }
  elseif ($leaderResolution.Alive) {
    Write-Output 'leader state  : alive; an operator may still hand off a wedged leader explicitly.'
  }
  else {
    Write-Output 'leader unavailable: confirmed dead. Choose one live target and run exactly one command:'
    $promoteScript = Join-Path $cfg['PLUGIN_DIR'] 'scripts\duet-promote.ps1'
    $liveTargets = @()
    foreach ($row in $rosterRows) {
      if ($row.name -eq $global:DUET_CURRENT_LEADER) { continue }
      $resolution = Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid
      if ($resolution.Known -and $resolution.Alive) { $liveTargets += $row }
    }
    foreach ($row in $liveTargets) {
      Write-Output ("  powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0} -To {1} -Session {2}" -f `
        (ConvertTo-DuetPsLiteral $promoteScript), (ConvertTo-DuetPsLiteral $row.name), (ConvertTo-DuetPsLiteral $cfgPath))
    }
    if ($liveTargets.Count -eq 0) { Write-Output '  (no live handoff target is currently confirmed)' }
  }
}

exit 0
