# Publish readiness for the exact DUET_CONFIG-pinned caller pane.
# This internal boot helper keeps models from transcribing a long encoded
# command containing the session path.
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

$callerSelf = $env:DUET_SELF
if (-not (Get-DuetCallerIdentity)) {
  Write-DuetError 'duet: readiness caller is not an identifiable psmux pane.'
  exit 7
}
if (-not (Resolve-DuetConfig -SessionArg '' -RequireEnvironment 1)) { exit 1 }
$configPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $configPath
if (-not $global:DUET_CONFIG_VALID -or
    -not (Test-DuetLoadedSession -Config $cfg -ConfigPath $configPath)) { exit 7 }
Set-DuetSessionVariables -Config $cfg
$rosterPath = Join-Path $global:DUET_DIR 'roster.tsv'
if (-not (Get-DuetCallerRosterName -RosterPath $rosterPath `
    -ExpectedSession $cfg['DUET_PSMUX_SESSION'] `
    -ExpectedServerPid $cfg['DUET_PSMUX_SERVER_PID'])) {
  Write-DuetError 'duet: readiness caller is not exactly one pinned roster member.'
  exit 7
}
$name = $global:DUET_CALLER_NAME
if (-not $callerSelf -or $callerSelf -ne $name) {
  Write-DuetError "duet: readiness identity mismatch for '$name'."
  exit 7
}
$readyPath = Join-Path (Join-Path $global:DUET_DIR 'ready') $name
if (-not (Write-DuetAtomicMultiline -Path $readyPath -Value 'ok')) {
  Write-DuetError "duet: could not publish readiness for '$name'."
  exit 1
}
[Console]::Out.WriteLine("duet: $name READY")
exit 0
