# From inside a psmux pane running Claude, bring up the Codex peer on Windows.
[CmdletBinding()]
param(
  [int]$ReadyTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir "duet-common.ps1")

if (-not $env:TMUX) {
  throw "duet: not inside psmux. Start Claude with: psmux new-session -s duet -- claude"
}
if (-not $env:TMUX_PANE) {
  throw "duet: no TMUX_PANE"
}

$codex = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codex) {
  throw "duet: 'codex' CLI not found on PATH"
}

$psmux = Get-DuetPsmux
$PluginDir = (Resolve-Path (Join-Path $SelfDir "..")).Path
$ClaudePane = $env:TMUX_PANE
$Workdir = (Get-Location).Path
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$DuetRoot = Join-Path $HOME ".duet"
$DuetDir = Join-Path $DuetRoot $Stamp
$ToClaude = Join-Path $DuetDir "to-claude"
$Delivered = Join-Path $ToClaude "delivered"
New-Item -ItemType Directory -Path $Delivered -Force | Out-Null
Write-DuetUtf8NoBom -Path (Join-Path $DuetDir "transcript.md") -Value ""

function Render-DuetBrief {
  param([string]$Path)
  $text = [System.IO.File]::ReadAllText($Path)
  $text = $text.Replace("@DUET_DIR@", $DuetDir)
  $text = $text.Replace("@PLUGIN@", $PluginDir)
  return $text
}

function Add-DuetBlock {
  param(
    [string]$Path,
    [string]$BriefPath
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-DuetUtf8NoBom -Path $Path -Value ""
  }
  $existing = [System.IO.File]::ReadAllText($Path)
  if ($existing.Contains("DUET:BEGIN")) {
    return
  }
  $block = "`r`n<!-- DUET:BEGIN (added by duet-init; removed by duet-end) -->`r`n"
  $block += Render-DuetBrief -Path $BriefPath
  $block += "`r`n<!-- DUET:END -->`r`n"
  Write-DuetUtf8NoBom -Path $Path -Value $block -Append
}

Add-DuetBlock -Path (Join-Path $Workdir "AGENTS.md") -BriefPath (Join-Path $PluginDir "codex\AGENTS_BRIEF.md")
Add-DuetBlock -Path (Join-Path $Workdir "CLAUDE.md") -BriefPath (Join-Path $PluginDir "claude\CLAUDE_BRIEF.md")

$CodexConfig = Join-Path (Join-Path $HOME ".codex") "config.toml"
$TrustedProjectPath = $Workdir.ToLowerInvariant()
$TrustedKey = "[projects.$(ConvertTo-DuetTomlLiteral $TrustedProjectPath)]"
$trusted = $false
if (Test-Path -LiteralPath $CodexConfig) {
  $trusted = [System.IO.File]::ReadAllText($CodexConfig).Contains($TrustedKey)
}
if (-not $trusted) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $CodexConfig) -Force | Out-Null
  $entry = "`r`n$TrustedKey`r`ntrust_level = `"trusted`"`r`n"
  Write-DuetUtf8NoBom -Path $CodexConfig -Value $entry -Append
  Write-Host "duet: marked $Workdir trusted for codex"
}

$CxSandbox = if ($env:DUET_CODEX_SANDBOX) { $env:DUET_CODEX_SANDBOX } else { "danger-full-access" }
$CxApproval = if ($env:DUET_CODEX_APPROVAL) { $env:DUET_CODEX_APPROVAL } else { "never" }
$CodexPath = $codex.Source
$CodexCommand = @(
  "Set-Location -LiteralPath $(ConvertTo-DuetPsLiteral $Workdir)",
  "& $(ConvertTo-DuetPsLiteral $CodexPath) --add-dir $(ConvertTo-DuetPsLiteral $DuetDir) -s $(ConvertTo-DuetPsLiteral $CxSandbox) -a $(ConvertTo-DuetPsLiteral $CxApproval)"
) -join "; "

$CodexPane = (& $psmux split-window -h -t $ClaudePane -P -F "#{pane_id}" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $CodexCommand).Trim()
if ($LASTEXITCODE -ne 0 -or -not $CodexPane) {
  throw "duet: failed to split psmux pane for Codex"
}
& $psmux select-pane -t $ClaudePane | Out-Null

$DuetRelay = if ($env:DUET_RELAY) { $env:DUET_RELAY } else { "" }
$EnvPath = Join-Path $DuetDir "duet.env.ps1"
$EnvText = @"
`$DUET_DIR = $(ConvertTo-DuetPsLiteral $DuetDir)
`$CLAUDE_PANE = $(ConvertTo-DuetPsLiteral $ClaudePane)
`$CODEX_PANE = $(ConvertTo-DuetPsLiteral $CodexPane)
`$PLUGIN_DIR = $(ConvertTo-DuetPsLiteral $PluginDir)
`$WORKDIR = $(ConvertTo-DuetPsLiteral $Workdir)
`$DUET_RELAY = $(ConvertTo-DuetPsLiteral $DuetRelay)
"@
Write-DuetUtf8NoBom -Path $EnvPath -Value $EnvText
Write-DuetUtf8NoBom -Path (Join-Path $DuetRoot "current.env.ps1") -Value $EnvText
Write-DuetUtf8NoBom -Path (Join-Path $DuetRoot "current.txt") -Value $DuetDir

if ($DuetRelay) {
  $RelayPath = Join-Path $PluginDir "scripts\duet-relay.ps1"
  Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $RelayPath,
    "-Config", $EnvPath
  ) | Out-Null
}

for ($i = 0; $i -lt 25; $i++) {
  $paneText = (& $psmux capture-pane -t $CodexPane -p 2>$null) -join "`n"
  if ($paneText -match "OpenAI Codex|Codex") {
    break
  }
  Start-Sleep -Seconds 1
}

Start-Sleep -Seconds 5
$ReadyFile = Join-Path $DuetDir "codex-ready"
$kick = "You are briefed via AGENTS.md in this directory. Confirm now by running this shell command: Set-Content -LiteralPath $(ConvertTo-DuetPsLiteral $ReadyFile) -Value ok -NoNewline ; then wait for messages from Claude."
Send-DuetPaste -Pane $CodexPane -Text $kick

$ready = $false
for ($i = 0; $i -lt $ReadyTimeoutSeconds; $i++) {
  if (Test-Path -LiteralPath $ReadyFile) {
    $ready = $true
    break
  }
  Start-Sleep -Seconds 1
}

if ($ready) {
  @"
duet: up and Codex is READY.  claude=$ClaudePane  codex=$CodexPane   dir=$DuetDir
Send Codex the first message now, then END YOUR TURN and wait for its reply:
    @'
    <your message to Codex>
    '@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PluginDir\scripts\duet-send.ps1" codex
Codex's replies arrive IN THIS PANE as prompts prefixed "[DUET from codex]".
Barge in while Codex is working with -Interrupt.
"@
} else {
  @"
duet: session up but Codex did not confirm readiness in time. Check its pane
(right split). You can still try sending; if it stalls, run duet-status.ps1.
  claude=$ClaudePane  codex=$CodexPane   dir=$DuetDir
"@
}
