# Windows harness-adapter contract and launch quoting tests.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:Pass++; Write-Host "  PASS $Name" }
  else { $script:Fail++; Write-Host "  FAIL $Name" }
}

$plugin = Split-Path -Parent $PSScriptRoot
. (Join-Path $plugin 'scripts\duet-common.ps1')
$scratch = Join-Path $env:TEMP ("duet adapters & O'Brien " + [guid]::NewGuid().ToString('N'))
$workdir = Join-Path $scratch "work tree & O'Brien"
$duetDir = Join-Path $scratch 'state dir\session-1'
New-Item -ItemType Directory -Path $workdir, $duetDir -Force | Out-Null
$fake = Join-Path $scratch "fake harness & O'Brien.ps1"
Write-DuetUtf8NoBom -Path $fake -Value @'
[IO.File]::WriteAllLines($env:DUET_CAPTURE, @(
  "cwd=$((Get-Location).Path)",
  "self=$env:DUET_SELF",
  "config=$env:DUET_CONFIG",
  "session=$env:DUET_SESSION",
  "args=$($args -join [char]31)"
), (New-Object Text.UTF8Encoding($false)))
'@

function Resolve-DuetExecutable { param([string]$Name) return $fake }
$saved = @{}
foreach ($name in @('DUET_CLAUDE_PERMISSION_FLAG', 'DUET_CLAUDE_MODEL', 'DUET_CODEX_SANDBOX',
    'DUET_CODEX_APPROVAL', 'DUET_CODEX_MODEL', 'DUET_CODEX_REASONING_EFFORT',
    'DUET_CODEX_SKIP_PRETRUST', 'DUET_KIMI_MODE_FLAG', 'DUET_KIMI_MODEL', 'DUET_CAPTURE')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$originalLocation = (Get-Location).Path

try {
  $env:DUET_CLAUDE_PERMISSION_FLAG = '--dangerously-skip-permissions'
  $env:DUET_CLAUDE_MODEL = 'claude model & one'
  $env:DUET_CODEX_SANDBOX = 'danger-full-access'
  $env:DUET_CODEX_APPROVAL = 'never'
  $env:DUET_CODEX_MODEL = 'codex model & two'
  $env:DUET_CODEX_REASONING_EFFORT = 'high'
  $env:DUET_CODEX_SKIP_PRETRUST = '1'
  $env:DUET_KIMI_MODE_FLAG = '--auto'
  $env:DUET_KIMI_MODEL = 'kimi model & three'

  $cases = @(
    [pscustomobject]@{ Harness = 'claude'; Name = 'claude-1'; Required = @('--dangerously-skip-permissions', '--model', 'claude model & one', '--add-dir', $duetDir, '--name', 'claude-1') },
    [pscustomobject]@{ Harness = 'codex'; Name = 'codex-1'; Required = @('-c', 'check_for_update_on_startup=false', '--add-dir', $duetDir, '-s', 'danger-full-access', '-a', 'never', '-m', 'codex model & two', '-c', 'model_reasoning_effort=high') },
    [pscustomobject]@{ Harness = 'kimi'; Name = 'kimi-1'; Required = @('--auto', '-m', 'kimi model & three', '--add-dir', $duetDir) }
  )

  foreach ($case in $cases) {
    $items = @(& (Join-Path $plugin ("harnesses\{0}.ps1" -f $case.Harness)))
    $adapter = if ($items.Count -eq 1) { $items[0] } else { $null }
    $contractOk = ($null -ne $adapter -and $adapter -is [hashtable])
    if ($contractOk) { foreach ($key in @('BootRegex', 'BriefFile', 'Check', 'Pretrust', 'LaunchCommand')) { if (-not $adapter.ContainsKey($key)) { $contractOk = $false } } }
    Check $contractOk "$($case.Harness) adapter exports the complete contract"
    Check ([bool](& $adapter['Pretrust'] $workdir)) "$($case.Harness) pretrust contract succeeds in the isolated fixture"
    $launchValues = @(& $adapter['LaunchCommand'] $workdir $duetDir $case.Name)
    Check ($launchValues.Count -eq 1 -and $launchValues[0] -is [string]) "$($case.Harness) launch adapter emits exactly one command"
    $command = [string]$launchValues[0]
    $parseOk = $true
    try { $block = [scriptblock]::Create($command) } catch { $parseOk = $false }
    Check $parseOk "$($case.Harness) launch command parses with spaces, ampersands, and apostrophes"
    $capture = Join-Path $scratch ("capture-{0}.txt" -f $case.Harness)
    $env:DUET_CAPTURE = $capture
    & $block | Out-Null
    $lines = [IO.File]::ReadAllLines($capture)
    $argLine = @($lines | Where-Object { $_.StartsWith('args=') })[0].Substring(5)
    $actualArgs = @($argLine -split [char]31)
    Check (($lines -contains "cwd=$workdir") -and ($lines -contains "self=$($case.Name)") -and
      ($lines -contains "config=$(Join-Path $duetDir 'duet.env')") -and ($lines -contains 'session=session-1')) "$($case.Harness) launch command preserves cwd and duet identity environment"
    Check (($actualArgs -join [char]31) -eq ($case.Required -join [char]31)) "$($case.Harness) launch command preserves every argument boundary"
    Set-Location -LiteralPath $originalLocation
  }
}
finally {
  Set-Location -LiteralPath $originalLocation
  foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nRESULT: $script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
