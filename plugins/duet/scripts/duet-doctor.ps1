# Validate one exact Windows/psmux ensemble session. -Reap is limited to ended
# sessions and still uses the recorded session/backend/pane/pid tuples.
[CmdletBinding()]
param(
  [string]$Session,
  [switch]$Reap
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

$script:IssueCount = 0
function Add-DuetDoctorIssue { param([string]$Message); $script:IssueCount++; Write-Output "ISSUE: $Message" }
function Add-DuetDoctorOk { param([string]$Message); Write-Output "OK: $Message" }

function Read-DuetDoctorRoster {
  param([string]$Path)
  $script:DoctorRoster = @()
  $text = Get-DuetFileText $Path
  if ($null -eq $text) { Add-DuetDoctorIssue "roster is missing: $Path"; return $false }
  $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
  if ($lines.Count -lt 1 -or $lines[0] -ne "name`tharness`tpane_id`tpane_pid`trank`tspawned") {
    Add-DuetDoctorIssue 'roster header is invalid'
    return $false
  }
  $names = @{}; $panes = @{}; $pids = @{}; $ranks = @{}
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = @($lines[$i].Split([char]9))
    if ($c.Count -ne 6) { Add-DuetDoctorIssue "roster row $($i + 1) does not have six fields"; continue }
    $name = $c[0]; $harness = $c[1]; $pane = $c[2]; $panePid = $c[3]; $rank = $c[4]; $spawned = $c[5]
    if ($name -notmatch '^[A-Za-z0-9_-]+$') { Add-DuetDoctorIssue "roster row $($i + 1) has an invalid name"; continue }
    if (@('claude', 'codex', 'kimi') -notcontains $harness) { Add-DuetDoctorIssue "member '$name' has unsupported harness '$harness'" }
    if ($pane -notmatch '^%[0-9]+$') { Add-DuetDoctorIssue "member '$name' has invalid pane id '$pane'" }
    $pidValue = 0; if (-not [int]::TryParse($panePid, [ref]$pidValue) -or $pidValue -le 0) { Add-DuetDoctorIssue "member '$name' has invalid pane pid '$panePid'" }
    $rankValue = 0; if (-not [int]::TryParse($rank, [ref]$rankValue) -or $rankValue -lt 0) { Add-DuetDoctorIssue "member '$name' has invalid rank '$rank'" }
    if (@('0', '1') -notcontains $spawned) { Add-DuetDoctorIssue "member '$name' has invalid spawned flag '$spawned'" }
    if ($names.ContainsKey($name)) { Add-DuetDoctorIssue "duplicate roster name '$name'" } else { $names[$name] = $true }
    if ($panes.ContainsKey($pane)) { Add-DuetDoctorIssue "duplicate roster pane '$pane'" } else { $panes[$pane] = $true }
    if ($pids.ContainsKey($panePid)) { Add-DuetDoctorIssue "duplicate roster pane pid '$panePid'" } else { $pids[$panePid] = $true }
    if ($ranks.ContainsKey($rank)) { Add-DuetDoctorIssue "duplicate roster rank '$rank'" } else { $ranks[$rank] = $true }
    $script:DoctorRoster += [pscustomobject]@{ name = $name; harness = $harness; pane_id = $pane; pane_pid = $panePid; rank = $rank; spawned = $spawned }
  }
  return ($script:DoctorRoster.Count -gt 0)
}

function Test-DuetDoctorWorkdirFence {
  param([hashtable]$Config, [string]$DuetDir, [bool]$Ended)
  $workdir = Get-DuetCanonicalPath $Config['WORKDIR']; $root = Get-DuetCanonicalPath $Config['DUET_STATE_ROOT']
  if (-not $workdir -or -not $root) { Add-DuetDoctorIssue 'workdir or state root is unavailable'; return }
  $key = Get-DuetWorkdirKey $workdir
  if (-not $key) { Add-DuetDoctorIssue 'workdir key cannot be derived'; return }
  if ($Config['DUET_WORKDIR_KEY'] -and $Config['DUET_WORKDIR_KEY'] -ne $key) { Add-DuetDoctorIssue 'config workdir key does not match the canonical workdir'; return }
  $active = Join-Path (Join-Path $root 'workdirs') ($key + '.active')
  $owner = Get-DuetFileText $active; if ($owner) { $owner = $owner.Trim() }
  if ($Ended) {
    if ($owner -eq $DuetDir) { Add-DuetDoctorIssue 'ended session still owns the workdir fence' } else { Add-DuetDoctorOk 'ended session released the workdir fence' }
  }
  elseif ($owner -eq $DuetDir) { Add-DuetDoctorOk 'active session owns the workdir fence' }
  elseif ($owner) { Add-DuetDoctorIssue "another session owns this active workdir: $owner" }
  else { Add-DuetDoctorIssue 'active session has no workdir fence owner' }
}

if ($Reap -and -not $Session -and -not $env:DUET_CONFIG -and -not $env:DUET_SESSION) {
  Write-DuetError 'duet: -Reap requires -Session, DUET_CONFIG, or DUET_SESSION; ambient current.session is forbidden.'
  exit 2
}
$callerPin = $env:DUET_SESSION
$allowCurrent = if ($Reap) { 0 } else { 1 }
if (-not (Resolve-DuetConfig $Session $allowCurrent)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $callerPin -ConfigPath $cfgPath)) { exit 1 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = Get-DuetCanonicalPath $cfg['DUET_DIR']
$Sid = $cfg['DUET_SESSION_ID']
$RosterPath = Join-Path $DuetDir 'roster.tsv'
$ended = Test-Path -LiteralPath (Join-Path $DuetDir '.ended')

Write-Output '=== duet doctor ==='
Write-Output "session : $Sid"
Write-Output "dir     : $DuetDir"
Write-Output "psmux   : namespace=$($cfg['DUET_PSMUX_NAMESPACE']) session=$($cfg['DUET_PSMUX_SESSION']) backend=$($cfg['DUET_PSMUX_SERVER_PID'])"
Write-Output ''

if (Test-DuetServerMatches) { Add-DuetDoctorOk 'psmux backend identity' } else { Add-DuetDoctorIssue 'psmux backend identity mismatch or session unavailable' }
$daemonAlive = Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid
if ($ended) {
  if ($daemonAlive) { Add-DuetDoctorIssue 'ended session still has a live delivery daemon' } else { Add-DuetDoctorOk 'ended session has no live delivery daemon' }
}
elseif ($daemonAlive) { Add-DuetDoctorOk 'delivery daemon owns its PID and lifetime lock' }
else { Add-DuetDoctorIssue 'active session delivery daemon is not healthy' }

$rosterValid = Read-DuetDoctorRoster $RosterPath
if ($rosterValid) {
  if ($script:DoctorRoster.Count -gt 5) { Add-DuetDoctorIssue 'roster exceeds the five-agent cap' }
  $initiators = @($script:DoctorRoster | Where-Object { $_.name -eq $cfg['DUET_INITIATOR'] })
  if ($initiators.Count -ne 1) { Add-DuetDoctorIssue 'roster does not contain exactly one configured initiator' }
  else {
    $init = $initiators[0]
    if ($init.rank -ne '0' -or $init.spawned -ne '0' -or $init.pane_id -ne $cfg['DUET_INITIATOR_PANE']) { Add-DuetDoctorIssue 'initiator row does not match config/rank/spawn invariants' }
  }
  foreach ($row in $script:DoctorRoster) {
    if ($row.name -ne $cfg['DUET_INITIATOR'] -and $row.spawned -ne '1') { Add-DuetDoctorIssue "worker '$($row.name)' is not marked spawned" }
    $res = Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid
    $state = if (-not $res.Known) { 'UNKNOWN' } elseif ($res.Alive) { 'alive' } else { 'dead' }
    Write-Output ("PANE: {0} harness={1} rank={2} tuple={3}/{4} state={5}" -f $row.name, $row.harness, $row.rank, $row.pane_id, $row.pane_pid, $state)
    if (-not $res.Known) { Add-DuetDoctorIssue "member '$($row.name)' pane state is unknown" }
  }
  Add-DuetDoctorOk 'roster schema and tuple uniqueness checked'
}

if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { Add-DuetDoctorIssue 'leadership state is invalid' }
else {
  if ($global:DUET_CURRENT_LEADER -ne 'NONE' -and -not @($script:DoctorRoster | Where-Object { $_.name -eq $global:DUET_CURRENT_LEADER })) { Add-DuetDoctorIssue "leader '$($global:DUET_CURRENT_LEADER)' is not in the roster" }
  if ($global:DUET_CURRENT_LEADER -ne 'NONE' -and (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'failed-leaders') $global:DUET_CURRENT_LEADER))) { Add-DuetDoctorIssue 'current leader is also marked as a failed leader' }
}

$memberNames = @{}; foreach ($row in $script:DoctorRoster) { $memberNames[$row.name] = $true }
$failedDir = Join-Path $DuetDir 'failed-leaders'
if (Test-Path -LiteralPath $failedDir) {
  foreach ($file in @(Get-ChildItem -LiteralPath $failedDir -File -ErrorAction SilentlyContinue)) {
    if (-not $memberNames.ContainsKey($file.Name)) { Add-DuetDoctorIssue "failed-leader record names nonmember '$($file.Name)'" }
  }
}

$watchdog = Join-Path $DuetDir 'watchdog'
$wdSession = Get-DuetFirstLineValue $watchdog 'session'; $wdTerm = Get-DuetFirstLineValue $watchdog 'term'
$wdLeader = Get-DuetFirstLineValue $watchdog 'leader'; $wdCount = Get-DuetFirstLineValue $watchdog 'count'
if ($wdSession -ne $Sid) { Add-DuetDoctorIssue 'watchdog session does not match config' }
if ($wdTerm -ne $global:DUET_CURRENT_TERM -or $wdLeader -ne $global:DUET_CURRENT_LEADER) { Add-DuetDoctorIssue 'watchdog term/leader does not match leadership state' }
[long]$wdCountValue = 0; if (-not [long]::TryParse([string]$wdCount, [ref]$wdCountValue) -or $wdCountValue -lt 0) { Add-DuetDoctorIssue 'watchdog count is invalid' }

$noSuccessor = Join-Path $DuetDir 'no-successor'
if ($global:DUET_CURRENT_LEADER -eq 'NONE' -and -not (Test-Path -LiteralPath $noSuccessor)) { Add-DuetDoctorIssue 'leader is NONE but no-successor record is missing' }
if ($global:DUET_CURRENT_LEADER -ne 'NONE' -and (Test-Path -LiteralPath $noSuccessor)) { Add-DuetDoctorIssue 'stale no-successor record exists while a leader is active' }
if (Test-Path -LiteralPath $noSuccessor) {
  if ((Get-DuetFirstLineValue $noSuccessor 'session') -ne $Sid) { Add-DuetDoctorIssue 'no-successor record has a foreign session' }
  if ((Get-DuetFirstLineValue $noSuccessor 'term') -ne $global:DUET_CURRENT_TERM) { Add-DuetDoctorIssue 'no-successor record term does not match leadership state' }
}

$promotionObligations = 0
$inbox = Join-Path $DuetDir 'inbox'
if (-not (Test-Path -LiteralPath $inbox -PathType Container)) { Add-DuetDoctorIssue 'inbox directory is missing' }
else {
  foreach ($box in @(Get-ChildItem -LiteralPath $inbox -Directory -ErrorAction SilentlyContinue)) {
    if (@('leader', 'promotions') -notcontains $box.Name -and -not $memberNames.ContainsKey($box.Name)) { Add-DuetDoctorIssue "inbox exists for nonmember '$($box.Name)'" }
    foreach ($file in @(Get-ChildItem -LiteralPath $box.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' })) {
      if (-not (Read-DuetMessage $file.FullName)) { Add-DuetDoctorIssue "invalid active payload: $($file.FullName)"; continue }
      if ($global:DUET_MESSAGE_SESSION -ne $Sid) { Add-DuetDoctorIssue "foreign active payload $($file.Name) in inbox/$($box.Name)" }
      if ($global:DUET_MESSAGE_ID -notlike "m-$Sid-*") { Add-DuetDoctorIssue "foreign message id $($file.Name) in inbox/$($box.Name)" }
      if ($box.Name -eq 'leader' -and $global:DUET_MESSAGE_RECIPIENT -ne 'leader') { Add-DuetDoctorIssue "leader queue payload $($file.Name) redirects to $($global:DUET_MESSAGE_RECIPIENT)" }
      if (@('leader', 'promotions') -notcontains $box.Name -and $global:DUET_MESSAGE_RECIPIENT -ne $box.Name) { Add-DuetDoctorIssue "named queue payload $($file.Name) redirects to $($global:DUET_MESSAGE_RECIPIENT)" }
      if ($box.Name -eq 'promotions') {
        $promotionObligations++
        if ($global:DUET_MESSAGE_TERM -ne $global:DUET_CURRENT_TERM -or $global:DUET_MESSAGE_RECIPIENT -ne $global:DUET_CURRENT_LEADER) { Add-DuetDoctorIssue "pending promotion $($file.Name) does not target the current term/leader" }
      }
    }
  }
}
if ($promotionObligations -gt 1) { Add-DuetDoctorIssue "$promotionObligations simultaneous promotion obligations are active" }

Test-DuetDoctorWorkdirFence -Config $cfg -DuetDir $DuetDir -Ended $ended

if ($Reap) {
  if (-not $ended) { Write-DuetError 'duet: -Reap is allowed only after the session has ended.'; exit 2 }
  $exemptPane = ''; $exemptPid = ''
  if ($env:TMUX_PANE) {
    if (-not (Get-DuetCallerIdentity)) { Write-DuetError 'duet: could not prove caller identity; refusing reap.'; exit 9 }
    $exemptPane = $global:DUET_CALLER_PANE; $exemptPid = $global:DUET_CALLER_PANE_PID
  }
  if (-not (Test-DuetServerMatches)) { Write-DuetError 'duet: backend identity mismatch; refusing reap.'; exit 9 }
  if (-not (Stop-DuetSpawnedPanes -RosterPath $RosterPath -ExemptPaneId $exemptPane -ExemptPanePid $exemptPid)) { Write-DuetError 'duet: one or more spawned panes could not be proved stopped.'; exit 9 }
  Write-Output 'duet: ended-session spawned panes reaped.'
}

Write-Output ''
if ($script:IssueCount -eq 0) { Write-Output 'doctor: healthy'; exit 0 }
Write-Output "doctor: $($script:IssueCount) issue(s)"
exit 1
