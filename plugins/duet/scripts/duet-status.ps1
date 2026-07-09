[CmdletBinding()]
param(
  [string]$Config
)

$ErrorActionPreference = "Stop"
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir "duet-common.ps1")

try {
  $cfg = Import-DuetConfig -Path $Config
} catch {
  Write-Host "duet: no active session"
  exit 0
}

$psmux = Get-DuetPsmux
$claudeAlive = Test-DuetPaneAlive -Pane $cfg.CLAUDE_PANE
$codexAlive = Test-DuetPaneAlive -Pane $cfg.CODEX_PANE
Write-Host "session : $($cfg.DUET_DIR)"
Write-Host "panes   : claude=$($cfg.CLAUDE_PANE) [$(if ($claudeAlive) { 'alive' } else { 'DEAD' })]  codex=$($cfg.CODEX_PANE) [$(if ($codexAlive) { 'alive' } else { 'DEAD' })]"
Write-Host "relay   : $(if ($cfg.DUET_RELAY) { 'on' } else { 'off (direct send)' })"
Write-Host "pending codex->claude : $(Get-DuetPendingCount -Dir $cfg.DUET_DIR)"
if (-not $codexAlive) {
  Write-Host "WARNING: codex pane is not alive for this session - re-init or run duet-doctor.ps1"
}
Write-Host "--- transcript (last 24 lines) ---"
$transcript = Join-Path $cfg.DUET_DIR "transcript.md"
if (Test-Path -LiteralPath $transcript) {
  Get-Content -LiteralPath $transcript -Tail 24
} else {
  Write-Host "(empty)"
}
Write-Host "--- relay (last 6) ---"
$relay = Join-Path $cfg.DUET_DIR "relay.log"
if (Test-Path -LiteralPath $relay) {
  Get-Content -LiteralPath $relay -Tail 6
} else {
  Write-Host "(none)"
}
Write-Host "--- codex pane (last 18 lines) ---"
try {
  & $psmux capture-pane -t $cfg.CODEX_PANE -p | Select-Object -Last 18
} catch {
  Write-Host "(pane gone)"
}
