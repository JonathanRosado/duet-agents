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

# Relay path: codex->claude via the file queue + background injector. Only used
# when DUET_RELAY is set (e.g. Codex sandboxed below socket access). The relay
# process is what verifies submission and retries; we refuse to queue silently
# if no relay is actually running (that would be the old false-"delivered").
if ($Recipient -eq "claude" -and $cfg.DUET_RELAY) {
  $relayLog = Join-Path $cfg.DUET_DIR "relay.log"
  if (-not (Test-Path -LiteralPath $relayLog)) {
    Write-Warning "duet: DUET_RELAY is set but no relay.log exists - the relay may not be running. Falling back to direct send."
  } else {
    $box = Join-Path $cfg.DUET_DIR "to-claude"
    New-Item -ItemType Directory -Path $box -Force | Out-Null
    $existing = @(Get-ChildItem -LiteralPath $box -Filter "*.msg" -File -ErrorAction SilentlyContinue).Count
    $seq = "{0:D4}" -f ($existing + 1)
    $tmp = Join-Path $box ".$seq.tmp"
    $final = Join-Path $box "$seq.msg"
    $flag = if ($Interrupt) { "INTERRUPT" } else { "NORMAL" }
    Write-DuetUtf8NoBom -Path $tmp -Value "$flag`r`n$payload"
    Move-Item -LiteralPath $tmp -Destination $final -Force
    Write-Host "duet: queued for claude via relay$(if ($Interrupt) { ' (interrupt)' }) ($seq.msg)"
    exit 0
  }
}

# Direct path: paste into the recipient's pane and VERIFY it submitted.
if (-not (Test-DuetPaneAlive -Pane $pane)) {
  Write-Error "duet: $Recipient pane ($pane) is not alive - its agent is not running for this session. Re-init the duet (duet-init.ps1) or run duet-doctor.ps1."
  exit 4
}

$ok = Send-DuetPaste -Pane $pane -Text $payload -Interrupt:$Interrupt
if ($ok) {
  Write-Host "duet: submitted to $Recipient$(if ($Interrupt) { ' (interrupt)' })"
  exit 0
} else {
  Write-Error "duet: SENT BUT UNVERIFIED to $Recipient - could not confirm $Recipient received and submitted the message. Check its pane (duet-status.ps1); the peer may not have seen it. Do NOT assume it was delivered."
  exit 3
}
