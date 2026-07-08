[CmdletBinding()]
param(
  [string]$Config
)

$ErrorActionPreference = "Continue"
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir "duet-common.ps1")

$cfg = Import-DuetConfig -Path $Config
$box = Join-Path $cfg.DUET_DIR "to-claude"
$sent = Join-Path $box "delivered"
$log = Join-Path $cfg.DUET_DIR "relay.log"
New-Item -ItemType Directory -Path $sent -Force | Out-Null
Write-DuetUtf8NoBom -Path $log -Value "[$(Get-Date -Format HH:mm:ss)] relay up -> claude pane $($cfg.CLAUDE_PANE)`r`n" -Append

while ($true) {
  Get-ChildItem -LiteralPath $box -Filter "*.msg" -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object {
      $f = $_.FullName
      $content = [System.IO.File]::ReadAllText($f)
      $parts = $content -split "`r?`n", 2
      $flag = $parts[0]
      $body = if ($parts.Count -gt 1) { $parts[1] } else { "" }
      Send-DuetPaste -Pane $cfg.CLAUDE_PANE -Text $body -Interrupt:($flag -eq "INTERRUPT")
      Write-DuetUtf8NoBom -Path $log -Value "[$(Get-Date -Format HH:mm:ss)] injected $($_.Name) ($flag)`r`n" -Append
      Move-Item -LiteralPath $f -Destination $sent -Force
    }

  if (Test-Path -LiteralPath (Join-Path $cfg.DUET_DIR ".ended")) {
    Write-DuetUtf8NoBom -Path $log -Value "[$(Get-Date -Format HH:mm:ss)] relay stop`r`n" -Append
    exit 0
  }
  Start-Sleep -Milliseconds 200
}
