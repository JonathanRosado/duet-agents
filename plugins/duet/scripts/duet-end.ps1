[CmdletBinding()]
param(
  [string]$Config
)

$ErrorActionPreference = "Continue"
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir "duet-common.ps1")

try {
  $cfg = Import-DuetConfig -Path $Config
} catch {
  Write-Host "duet: no active session"
  exit 0
}

Write-DuetUtf8NoBom -Path (Join-Path $cfg.DUET_DIR ".ended") -Value ""
Remove-DuetBlock -Path (Join-Path $cfg.WORKDIR "AGENTS.md")
Remove-DuetBlock -Path (Join-Path $cfg.WORKDIR "CLAUDE.md")

if ($cfg.CODEX_PANE) {
  $psmux = Get-DuetPsmux
  & $psmux send-keys -t $cfg.CODEX_PANE C-c 2>$null | Out-Null
  & $psmux kill-pane -t $cfg.CODEX_PANE 2>$null | Out-Null
}

Write-Host "duet: ended. Transcript kept at $($cfg.DUET_DIR)\transcript.md"
exit 0
