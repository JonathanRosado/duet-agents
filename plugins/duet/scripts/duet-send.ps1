# Enqueue one message in an explicitly pinned Windows/psmux v4 session.
# Pane injection belongs exclusively to duet-deliverd.
[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory = $true)][string]$Recipient,
  [switch]$Interrupt,
  [string]$From
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

$callerSelf = $env:DUET_SELF
if (-not (Get-DuetCallerIdentity)) {
  Write-DuetError 'duet: caller is not an identifiable psmux pane.'
  exit 7
}
if (-not (Resolve-DuetConfig -SessionArg '' -RequireEnvironment 1)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not $global:DUET_CONFIG_VALID -or
    -not (Test-DuetLoadedSession -Config $cfg -ConfigPath $cfgPath)) { exit 7 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = $global:DUET_DIR
$Sid = $global:DUET_SESSION_ID
$RosterPath = Join-Path $DuetDir 'roster.tsv'

if (Test-Path -LiteralPath (Join-Path $DuetDir '.ended')) {
  Write-DuetError 'duet: session has ended; refusing to enqueue.'
  exit 1
}
$rosterRows = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) {
  Write-DuetError 'duet: session roster is invalid; refusing to enqueue.'
  exit 1
}
if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) {
  Write-DuetError 'duet: delivery daemon is not alive; message was not queued.'
  exit 6
}
if (-not (Get-DuetCallerRosterName -RosterPath $RosterPath `
    -ExpectedSession $cfg['DUET_PSMUX_SESSION'] `
    -ExpectedServerPid $cfg['DUET_PSMUX_SERVER_PID'])) {
  Write-DuetError "duet: caller pane is not exactly one member of session '$Sid'."
  exit 7
}
$sender = $global:DUET_CALLER_NAME
if ($callerSelf -and $callerSelf -ne $sender) {
  Write-DuetError "duet: identity mismatch: caller pane is '$sender' but DUET_SELF is '$callerSelf'."
  exit 7
}
if ($From -and $From -ne $sender) {
  Write-DuetError "duet: -From '$From' does not match caller pane identity '$sender'."
  exit 7
}

if ($Recipient -ne 'all' -and
    -not (Test-DuetRosterHasName -RosterPath $RosterPath -Name $Recipient)) {
  Write-DuetError "duet: recipient '$Recipient' is not an exact roster name."
  exit 2
}
if ($Recipient -ne 'all' -and
    -not (Test-DuetMemberAlive -RosterPath $RosterPath -Name $Recipient)) {
  Write-DuetError "duet: recipient '$Recipient' is not live; message was not queued."
  exit 8
}
if ($Recipient -ne 'all' -and
    (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'blocked') $Recipient))) {
  Write-DuetError "duet: recipient '$Recipient' is blocked after ambiguous delivery; message was not queued."
  exit 8
}

$body = [Console]::In.ReadToEnd()
$mode = if ($Interrupt) { 'INTERRUPT' } else { 'NORMAL' }
function Add-OneDuetMessage {
  param([string]$Queue, [string]$WireRecipient)
  if (-not (Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue $Queue `
      -Sender $sender -Recipient $WireRecipient -Mode $mode -Body $body)) {
    return $false
  }
  [Console]::Out.WriteLine(('duet: queued {0} for {1}{2}' -f
      $global:DUET_ENQUEUED_ID, $Queue, $(if ($Interrupt) { ' (interrupt)' } else { '' })))
  return $true
}

if ($Recipient -ne 'all') {
  if (Add-OneDuetMessage -Queue $Recipient -WireRecipient $Recipient) { exit 0 }
  exit 1
}

$fanout = 0
foreach ($row in $rosterRows) {
  if ($row.name -eq $sender) { continue }
  if (-not (Test-DuetMemberAlive -RosterPath $RosterPath -Name $row.name)) { continue }
  if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'blocked') $row.name)) { continue }
  if (-not (Add-OneDuetMessage -Queue $row.name -WireRecipient 'all')) { exit 1 }
  $fanout++
}
if ($fanout -eq 0) {
  Write-DuetError 'duet: broadcast has no other live recipients.'
  exit 8
}
exit 0
