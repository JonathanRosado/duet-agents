# Enqueue one duet message (injection is owned exclusively by duet-deliverd).
# Native params; body on stdin:
#   ... | duet-send.ps1 <recipient|leader|all> [-Interrupt] [-From <name>] [-Session <cfg>]
[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory = $true)][string]$Recipient,
  [switch]$Interrupt,
  [string]$From,
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
if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) { Write-DuetError "duet: session has ended; refusing to enqueue."; exit 1 }
if (-not (Test-Path -LiteralPath $RosterPath)) { Write-DuetError "duet: session roster is missing."; exit 1 }
$rosterRows = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) { Write-DuetError "duet: session roster is invalid."; exit 1 }
if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { exit 1 }
if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) { Write-DuetError "duet: delivery daemon is not alive; message was not queued."; exit 6 }

$paneName = ''
if (Get-DuetCallerRosterName -RosterPath $RosterPath -ExpectedSession $cfg['DUET_PSMUX_SESSION'] -ExpectedServerPid $cfg['DUET_PSMUX_SERVER_PID']) { $paneName = $global:DUET_CALLER_NAME }
if ($paneName -and $callerSelf -and $paneName -ne $callerSelf) { Write-DuetError "duet: identity mismatch: pane is '$paneName' but DUET_SELF is '$callerSelf'."; exit 7 }

$sender = ''
if ($From) {
  if (-not (Test-DuetRosterHasName -RosterPath $RosterPath -Name $From)) { Write-DuetError "duet: --From '$From' is not in the roster."; exit 7 }
  if ($paneName -and $paneName -ne $From -and -not $env:DUET_ALLOW_FROM_OVERRIDE) { Write-DuetError "duet: --From '$From' does not match caller pane identity '$paneName'."; exit 7 }
  if ($callerSelf -and $callerSelf -ne $From -and -not $env:DUET_ALLOW_FROM_OVERRIDE) { Write-DuetError "duet: --From '$From' does not match DUET_SELF '$callerSelf'."; exit 7 }
  if (-not $paneName -and -not $env:DUET_ALLOW_FROM_OVERRIDE) { Write-DuetError "duet: caller pane is not a member of session '$Sid'; override refused."; exit 7 }
  $sender = $From
}
else {
  if (-not $paneName) { Write-DuetError "duet: caller is not a member of session '$Sid'."; exit 7 }
  $sender = $paneName
}

$body = [Console]::In.ReadToEnd()
$mode = if ($Interrupt) { 'INTERRUPT' } else { 'NORMAL' }
$origin = if ($sender -eq $global:DUET_CURRENT_LEADER) { 'LEADER' } else { 'WORKER' }

function Enqueue-One([string]$Queue, [string]$Rcpt) {
  if (-not (Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue $Queue -Sender $sender -Recipient $Rcpt -Term $global:DUET_CURRENT_TERM -Mode $mode -Origin $origin -LeaderAtSend $global:DUET_CURRENT_LEADER -Body $body)) { return $false }
  [Console]::Out.WriteLine(("duet: queued {0} for {1}{2}" -f $global:DUET_ENQUEUED_ID, $Rcpt, $(if ($Interrupt) { ' (interrupt)' } else { '' })))
  return $true
}

if ($sender -eq $global:DUET_CURRENT_LEADER) {
  if ($Recipient -eq 'all') {
    foreach ($r in $rosterRows) {
      if (-not $r.name -or $r.name -eq $sender) { continue }
      if (-not (Enqueue-One $r.name $r.name)) { exit 1 }
    }
    exit 0
  }
  if ($Recipient -eq 'leader') { Write-DuetError "duet: leader '$sender' cannot send to itself through the leader alias."; exit 8 }
  $rcpt = Resolve-DuetRosterName -RosterPath $RosterPath -Token $Recipient
  if (-not $rcpt) { Write-DuetError "duet: unknown or ambiguous recipient '$Recipient'."; exit 2 }
  if ($rcpt -eq $sender) { Write-DuetError "duet: sender and recipient are both '$sender'."; exit 8 }
  if (-not (Enqueue-One $rcpt $rcpt)) { exit 1 }
  exit 0
}

# Worker traffic canonicalizes to the symbolic leader queue (survives promotion).
if ($Recipient -ne 'leader') {
  $rcpt = Resolve-DuetRosterName -RosterPath $RosterPath -Token $Recipient
  if (-not $rcpt) { Write-DuetError "duet: unknown or ambiguous recipient '$Recipient'."; exit 2 }
  if ($rcpt -ne $global:DUET_CURRENT_LEADER) { Write-DuetError "duet: hub violation: worker '$sender' may send only to leader '$($global:DUET_CURRENT_LEADER)'."; exit 8 }
}
if (-not (Enqueue-One 'leader' 'leader')) { exit 1 }
exit 0
