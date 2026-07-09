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

Remove-DuetBlock -Path (Join-Path $cfg.WORKDIR "AGENTS.md")
Remove-DuetBlock -Path (Join-Path $cfg.WORKDIR "CLAUDE.md")

# Signals the relay to exit and kills the Codex pane - but only if that pane id
# still belongs to this session's Codex process (pid-guarded).
Stop-DuetSessionByConfig -Config $cfg -KillCodexPane

Write-Host "duet: ended. Transcript kept at $($cfg.DUET_DIR)\transcript.md"
exit 0
