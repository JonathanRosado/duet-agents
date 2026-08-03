# Tiny bracketed-paste-aware interactive TUI for isolated Windows/psmux tests.
$ErrorActionPreference = 'Stop'
$harness = if ($env:DUET_FAKE_HARNESS) { $env:DUET_FAKE_HARNESS } else { 'fake' }
$banner = switch ($harness) {
  claude { 'Claude Code' }
  codex { 'OpenAI Codex' }
  kimi { 'Welcome to Kimi Code!' }
  default { 'Duet fake harness' }
}
$name = if ($env:DUET_SELF) { $env:DUET_SELF } else { $harness }
$sessionDir = ''
if ($env:DUET_CONFIG) { $sessionDir = Split-Path -Parent $env:DUET_CONFIG }
if ($sessionDir) {
  $readyDir = Join-Path $sessionDir 'ready'
  if (-not (Test-Path -LiteralPath $readyDir)) {
    New-Item -ItemType Directory -Path $readyDir -Force | Out-Null
  }
  [IO.File]::WriteAllText((Join-Path $readyDir $name), 'ok')
}
$acceptLog = ''
if ($env:DUET_FAKE_ACCEPT_ROOT) {
  if (-not (Test-Path -LiteralPath $env:DUET_FAKE_ACCEPT_ROOT)) {
    New-Item -ItemType Directory -Path $env:DUET_FAKE_ACCEPT_ROOT -Force | Out-Null
  }
  $acceptLog = Join-Path $env:DUET_FAKE_ACCEPT_ROOT ($name + '.log')
}

[Console]::WriteLine($banner)
[Console]::WriteLine("fake harness ready: $name")
[Console]::Write(([char]27).ToString() + '[?2004h> ')
$buffer = New-Object Text.StringBuilder
$control = New-Object Text.StringBuilder
$inPaste = $false

while ($true) {
  $key = [Console]::ReadKey($true)
  $ch = $key.KeyChar
  if ($control.Length -gt 0) {
    if ([int]$ch -eq 27) {
      $control.Clear() | Out-Null
      $control.Append($ch) | Out-Null
      continue
    }
    $control.Append($ch) | Out-Null
    $sequence = $control.ToString()
    if ($sequence -eq (([char]27).ToString() + '[200~')) {
      $inPaste = $true
      $control.Clear() | Out-Null
      continue
    }
    if ($sequence -eq (([char]27).ToString() + '[201~')) {
      $inPaste = $false
      $control.Clear() | Out-Null
      continue
    }
    if ($control.Length -ge 8) { $control.Clear() | Out-Null }
    continue
  }
  if ([int]$ch -eq 27) {
    $buffer.Clear() | Out-Null
    $control.Append($ch) | Out-Null
    continue
  }
  if ($key.Key -eq [ConsoleKey]::Enter -or [int]$ch -eq 10 -or [int]$ch -eq 13) {
    if ($inPaste) {
      $buffer.Append("`n") | Out-Null
      [Console]::WriteLine()
      continue
    }
    if ($acceptLog) {
      [IO.File]::AppendAllText($acceptLog, $buffer.ToString() + "`n---ACCEPT---`n")
    }
    $buffer.Clear() | Out-Null
    [Console]::WriteLine()
    [Console]::WriteLine("accepted: $name")
    [Console]::WriteLine('ready: 1')
    [Console]::WriteLine('ready: 2')
    [Console]::WriteLine('ready: 3')
    [Console]::WriteLine('ready: 4')
    [Console]::Write('> ')
    continue
  }
  if ([int]$ch -gt 0) {
    $buffer.Append($ch) | Out-Null
    [Console]::Write($ch)
  }
}
