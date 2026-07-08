Set-StrictMode -Version 2.0

function Get-DuetPsmux {
  $cmd = Get-Command psmux -ErrorAction SilentlyContinue
  if (-not $cmd) {
    $cmd = Get-Command tmux -ErrorAction SilentlyContinue
  }
  if (-not $cmd) {
    throw "duet: psmux not found on PATH"
  }
  return $cmd.Source
}

function ConvertTo-DuetPsLiteral {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { $Value = "" }
  return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-DuetTomlLiteral {
  param([string]$Value)
  return "'" + $Value.Replace("'", "''") + "'"
}

function Write-DuetUtf8NoBom {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value,
    [switch]$Append
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if ($Append) {
    [System.IO.File]::AppendAllText($Path, $Value, $encoding)
  } else {
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
  }
}

function Import-DuetConfig {
  param([string]$Path)
  if (-not $Path) {
    $Path = $env:DUET_CONFIG
  }
  if (-not $Path) {
    $Path = Join-Path (Join-Path $HOME ".duet") "current.env.ps1"
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "duet: no session ($Path). run duet-init first."
  }

  . $Path

  return [pscustomobject]@{
    DUET_DIR = $DUET_DIR
    CLAUDE_PANE = $CLAUDE_PANE
    CODEX_PANE = $CODEX_PANE
    PLUGIN_DIR = $PLUGIN_DIR
    WORKDIR = $WORKDIR
    DUET_RELAY = $DUET_RELAY
    ConfigPath = $Path
  }
}

function Send-DuetPaste {
  param(
    [Parameter(Mandatory=$true)][string]$Pane,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
    [switch]$Interrupt
  )

  $psmux = Get-DuetPsmux
  if ($Interrupt) {
    & $psmux send-keys -t $Pane Escape | Out-Null
    & $psmux send-keys -t $Pane Escape | Out-Null
  }

  $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
  & $psmux -t $Pane send-paste $payload | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "duet: psmux send-paste failed for pane $Pane"
  }
  Start-Sleep -Milliseconds 1500
  & $psmux send-keys -t $Pane Enter | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "duet: psmux send-keys Enter failed for pane $Pane"
  }
}

function Get-DuetPendingCount {
  param([string]$Dir)
  $box = Join-Path $Dir "to-claude"
  if (-not (Test-Path -LiteralPath $box)) {
    return 0
  }
  return @(
    Get-ChildItem -LiteralPath $box -Filter "*.msg" -File -ErrorAction SilentlyContinue
  ).Count
}

function Remove-DuetBlock {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    return
  }

  $text = [System.IO.File]::ReadAllText($Path)
  $updated = [regex]::Replace(
    $text,
    "(?s)\r?\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\r?\n?",
    ""
  )
  if ($updated.Trim().Length -eq 0) {
    Remove-Item -LiteralPath $Path -Force
  } elseif ($updated -ne $text) {
    Write-DuetUtf8NoBom -Path $Path -Value $updated
  }
}
