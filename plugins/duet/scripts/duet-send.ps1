[CmdletBinding()]
param(
  [Parameter(Position=0, Mandatory=$true)]
  [ValidateSet("codex", "claude")]
  [string]$Recipient,

  [switch]$Interrupt,

  [string]$Config
)

$ErrorActionPreference = "Stop"
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir "duet-common.ps1")

$cfg = Import-DuetConfig -Path $Config
$body = [Console]::In.ReadToEnd()

switch ($Recipient) {
  "codex" {
    $sender = "claude"
    $pane = $cfg.CODEX_PANE
  }
  "claude" {
    $sender = "codex"
    $pane = $cfg.CLAUDE_PANE
  }
}

$ts = Get-Date -Format "HH:mm:ss"
$suffix = if ($Interrupt) { "  (INTERRUPT)" } else { "" }
$entry = "`r`n----- $ts  $sender -> $Recipient$suffix -----`r`n$body`r`n"
Write-DuetUtf8NoBom -Path (Join-Path $cfg.DUET_DIR "transcript.md") -Value $entry -Append

$payload = "[DUET from $sender]`n$body"

if ($Recipient -eq "claude" -and $cfg.DUET_RELAY) {
  $box = Join-Path $cfg.DUET_DIR "to-claude"
  New-Item -ItemType Directory -Path $box -Force | Out-Null
  $existing = @(Get-ChildItem -LiteralPath $box -Filter "*.msg" -File -ErrorAction SilentlyContinue).Count
  $seq = "{0:D4}" -f ($existing + 1)
  $tmp = Join-Path $box ".$seq.tmp"
  $final = Join-Path $box "$seq.msg"
  $flag = if ($Interrupt) { "INTERRUPT" } else { "NORMAL" }
  Write-DuetUtf8NoBom -Path $tmp -Value "$flag`r`n$payload"
  Move-Item -LiteralPath $tmp -Destination $final -Force
  Write-Host "duet: queued for claude via relay$(if ($Interrupt) { ' (interrupt)' })"
  exit 0
}

Send-DuetPaste -Pane $pane -Text $payload -Interrupt:$Interrupt
Write-Host "duet: delivered to $Recipient$(if ($Interrupt) { ' (interrupt)' })"
