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
$DuetRoot = Join-Path $HOME ".duet"

# Reap any prior session's agents BEFORE spawning new ones, so there is exactly
# one Codex per role and messages can't route to an orphaned, context-less agent
# (issue #3). We never touch the current Claude pane, only the prior Codex pane.
$PrevConfigPath = Join-Path $DuetRoot "current.env.ps1"
if (Test-Path -LiteralPath $PrevConfigPath) {
  try {
    $prev = Import-DuetConfig -Path $PrevConfigPath
    if ($prev.CODEX_PANE -and (Test-DuetPaneAlive -Pane $prev.CODEX_PANE)) {
      Write-Host "duet: reaping previous session's Codex (pane $($prev.CODEX_PANE), dir $($prev.DUET_DIR))"
    }
    Stop-DuetSessionByConfig -Config $prev -KillCodexPane
  } catch {
    Write-Warning "duet: could not fully reap previous session: $($_.Exception.Message)"
  }
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
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

# psmux 3.3.3 on Windows does NOT exec `split-window -- <exe> <args>` directly. Its
# default shell is `powershell.exe -NoLogo -Command "<...>"`, and it space-joins
# everything after `--` into that single outer -Command string. Passing our own
# `powershell.exe ... -Command <inline>` therefore gets DOUBLE-WRAPPED into
# `powershell -NoLogo -Command "powershell ... -Command <inline>"`, and the inline
# command's quotes/parens/semicolons are mangled by the second parse -> Codex never
# launches and the pane dies instantly. Writing the launch command to a .ps1 and
# invoking it with `-File <path>` sidesteps this: a script path has no nested quoting
# for the outer -Command to mangle. The path is single-quoted (ConvertTo-DuetPsLiteral)
# so it still survives the outer -Command's space tokenization when $HOME\.duet
# contains a space (e.g. a Windows username with a space).
$CodexLauncher = Join-Path $DuetDir "launch-codex.ps1"
Write-DuetUtf8NoBom -Path $CodexLauncher -Value $CodexCommand

$CodexPane = (& $psmux split-window -h -t $ClaudePane -P -F "#{pane_id}" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-DuetPsLiteral $CodexLauncher)).Trim()
if ($LASTEXITCODE -ne 0 -or -not $CodexPane) {
  throw "duet: failed to split psmux pane for Codex"
}
& $psmux select-pane -t $ClaudePane | Out-Null

# Record the panes' process ids so send-time can confirm a pane id wasn't
# recycled onto a different process (guards the duplicate-%N routing, issue #3).
$paneRecords = @(Get-DuetPaneRecords)
$claudeRec = @($paneRecords | Where-Object { $_.Id -eq $ClaudePane })
$codexRec = @($paneRecords | Where-Object { $_.Id -eq $CodexPane })
$ClaudePanePid = if ($claudeRec.Count -gt 0) { $claudeRec[0].Pid } else { "" }
$CodexPanePid = if ($codexRec.Count -gt 0) { $codexRec[0].Pid } else { "" }

$DuetRelay = if ($env:DUET_RELAY) { $env:DUET_RELAY } else { "" }
$EnvPath = Join-Path $DuetDir "duet.env.ps1"
$EnvText = @"
`$DUET_DIR = $(ConvertTo-DuetPsLiteral $DuetDir)
`$CLAUDE_PANE = $(ConvertTo-DuetPsLiteral $ClaudePane)
`$CODEX_PANE = $(ConvertTo-DuetPsLiteral $CodexPane)
`$CLAUDE_PANE_PID = $(ConvertTo-DuetPsLiteral $ClaudePanePid)
`$CODEX_PANE_PID = $(ConvertTo-DuetPsLiteral $CodexPanePid)
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
$null = Send-DuetPaste -Pane $CodexPane -Text $kick

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
(right split). You can still try sending; if it stalls, run duet-status.ps1 or
duet-doctor.ps1.
  claude=$ClaudePane  codex=$CodexPane   dir=$DuetDir
"@
}
