# End exactly one DUET_CONFIG-pinned Windows/psmux v4 session immediately.
[CmdletBinding()]
param()

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
    -not (Test-DuetLoadedSession -Config $cfg -ConfigPath $cfgPath)) { exit 1 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = $global:DUET_DIR
$RosterPath = Join-Path $DuetDir 'roster.tsv'
$rosterRows = @(Import-DuetRoster $RosterPath)
if (-not $global:DUET_ROSTER_VALID) {
  Write-DuetError 'duet: session roster is invalid; refusing pane teardown.'
  exit 9
}
if (-not (Get-DuetCallerRosterName -RosterPath $RosterPath `
    -ExpectedSession $cfg['DUET_PSMUX_SESSION'] `
    -ExpectedServerPid $cfg['DUET_PSMUX_SERVER_PID'])) {
  Write-DuetError "duet: caller pane is not exactly one member of session '$($cfg['DUET_SESSION_ID'])'."
  exit 7
}
if ($callerSelf -and $callerSelf -ne $global:DUET_CALLER_NAME) {
  Write-DuetError "duet: identity mismatch: caller pane is '$($global:DUET_CALLER_NAME)' but DUET_SELF is '$callerSelf'."
  exit 7
}

if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir '.ended') -Value '')) {
  Write-DuetError 'duet: could not publish the ended marker; session left intact.'
  exit 9
}

$failed = $false
if (-not (Stop-DuetDaemon -DuetDir $DuetDir -Loops 30)) {
  Write-DuetError 'duet: warning: delivery daemon did not stop cleanly.'
  $failed = $true
}
if (Test-DuetServerMatches) {
  if (-not (Stop-DuetSpawnedPanes -RosterPath $RosterPath `
      -ExemptPaneId $global:DUET_CALLER_PANE `
      -ExemptPanePid $global:DUET_CALLER_PANE_PID)) {
    Write-DuetError 'duet: invalid or ambiguous roster blocked recorded pane cleanup.'
    $failed = $true
  }
} else {
  Write-DuetError 'duet: psmux backend identity changed; skipped recorded pane cleanup.'
  $failed = $true
}
if (-not (Remove-DuetSessionAnchors -Workdir $cfg['WORKDIR'])) {
  Write-DuetError 'duet: could not strip session anchors.'
  $failed = $true
}

Write-Output "duet: ended. Transcript kept at $DuetDir\transcript.md"
if ($failed) { exit 1 }
exit 0
