# Check the live basics for exactly one explicitly pinned Windows/psmux v4
# session. This command is diagnostic only; v4 has no recovery/reap mode.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Session)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

$script:IssueCount = 0
function Add-DuetDoctorIssue {
  param([string]$Message)
  $script:IssueCount++
  Write-Output "ISSUE: $Message"
}
function Add-DuetDoctorOk {
  param([string]$Message)
  Write-Output "ok   : $Message"
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
$ended = Test-Path -LiteralPath (Join-Path $DuetDir '.ended')

Write-Output '=== duet doctor ==='
Write-Output "session : $Sid"
Write-Output "dir     : $DuetDir"
Write-Output "psmux   : namespace=$($cfg['DUET_PSMUX_NAMESPACE']) session=$($cfg['DUET_PSMUX_SESSION']) backend=$($cfg['DUET_PSMUX_SERVER_PID'])"
Write-Output ''
Write-Output 'checks:'

if (Test-DuetServerMatches) {
  Add-DuetDoctorOk 'psmux backend identity'
} else {
  Add-DuetDoctorIssue 'psmux backend identity mismatch or session unavailable'
}

$rosterRows = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) {
  Add-DuetDoctorIssue 'roster schema or member identities are invalid'
  Write-Output ''
  Write-Output "doctor: $($script:IssueCount) issue(s)"
  exit 1
}
Add-DuetDoctorOk 'roster schema and member identities'

$initiators = @($rosterRows | Where-Object { $_.name -eq $cfg['DUET_INITIATOR'] })
if ($initiators.Count -ne 1 -or $initiators[0].rank -ne '0' -or
    $initiators[0].spawned -ne '0' -or
    $initiators[0].pane_id -ne $cfg['DUET_INITIATOR_PANE']) {
  Add-DuetDoctorIssue 'configured initiator does not match the rank-zero roster tuple'
}

$daemonAlive = Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid
if ($ended) {
  if ($daemonAlive) {
    Add-DuetDoctorIssue 'ended session still has a live delivery daemon'
  } else {
    Add-DuetDoctorOk 'ended session has no live delivery daemon'
  }
} elseif ($daemonAlive) {
  Add-DuetDoctorOk 'delivery daemon'
} else {
  Add-DuetDoctorIssue 'active session delivery daemon is not alive'
}

$unhealthy = Get-DuetFileText (Join-Path $DuetDir '.unhealthy')
if ($unhealthy) { Add-DuetDoctorIssue "session is unhealthy: $($unhealthy.Trim())" }

$memberNames = @{}
foreach ($row in $rosterRows) {
  $memberNames[$row.name] = $true
  $resolution = Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid
  $state = if (-not $resolution.Known) {
    'unknown'
  } elseif ($resolution.Alive) {
    'alive'
  } else { 'dead' }
  Write-Output ("PANE : {0} harness={1} rank={2} tuple={3}/{4} state={5}" -f
    $row.name, $row.harness, $row.rank, $row.pane_id, $row.pane_pid, $state)
  if (-not $ended -and $state -ne 'alive') {
    Add-DuetDoctorIssue "member '$($row.name)' pane is $state"
  }
  if (-not $ended -and
      -not (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $row.name))) {
    Add-DuetDoctorIssue "readiness marker missing for '$($row.name)'"
  }
  if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'dead') $row.name)) {
    Add-DuetDoctorIssue "recipient '$($row.name)' was marked dead"
  }
  if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'blocked') $row.name)) {
    Add-DuetDoctorIssue "recipient '$($row.name)' is blocked after ambiguous or repeated pre-landing failure"
  }
}

$inbox = Join-Path $DuetDir 'inbox'
if (-not (Test-Path -LiteralPath $inbox -PathType Container)) {
  Add-DuetDoctorIssue 'inbox directory is missing'
} else {
  foreach ($box in @(Get-ChildItem -LiteralPath $inbox -Directory -ErrorAction SilentlyContinue)) {
    if (-not $memberNames.ContainsKey($box.Name)) {
      Add-DuetDoctorIssue "inbox exists for nonmember '$($box.Name)'"
      continue
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $box.FullName -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[NI]-.*\.msg$' })) {
      if (-not (Read-DuetMessage $file.FullName)) {
        Add-DuetDoctorIssue "invalid active payload: $($file.FullName)"
        continue
      }
      if ($global:DUET_MESSAGE_SESSION -ne $Sid) {
        Add-DuetDoctorIssue "foreign active payload $($file.Name) in inbox/$($box.Name)"
      }
      if (-not $global:DUET_MESSAGE_ID.StartsWith("m-$Sid-$($box.Name)-")) {
        Add-DuetDoctorIssue "foreign message id $($file.Name) in inbox/$($box.Name)"
      }
      if ($global:DUET_MESSAGE_RECIPIENT -ne $box.Name -and
          $global:DUET_MESSAGE_RECIPIENT -ne 'all') {
        Add-DuetDoctorIssue "payload $($file.Name) redirects inbox/$($box.Name)"
      }
      if (-not $memberNames.ContainsKey($global:DUET_MESSAGE_SENDER)) {
        Add-DuetDoctorIssue "payload $($file.Name) names nonmember sender '$($global:DUET_MESSAGE_SENDER)'"
      }
    }
  }
}

Write-Output ''
if ($script:IssueCount -eq 0) {
  Write-Output 'doctor: healthy'
  exit 0
}
Write-Output "doctor: $($script:IssueCount) issue(s)"
exit 1
