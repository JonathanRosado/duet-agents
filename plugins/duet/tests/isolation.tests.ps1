# Live psmux namespace and tuple-isolation regression tests.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:Pass++; Write-Host "  PASS $Name" }
  else { $script:Fail++; Write-Host "  FAIL $Name" }
}
function Skip([string]$Name) { $script:Skip++; Write-Host "  SKIP $Name" }

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1')

function Get-ScratchNamespaceProcesses {
  param([string]$Namespace)
  $matches = @()
  foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -ErrorAction SilentlyContinue)) {
    $line = [string]$proc.CommandLine
    if (Test-DuetCommandLineOption -CommandLine $line -Option '-L' -Value $Namespace) { $matches += $proc }
  }
  return $matches
}

function Remove-ScratchNamespaceRegistry {
  param([string]$Namespace)
  $root = Get-DuetCanonicalPath (Join-Path $env:USERPROFILE '.psmux')
  if (-not $root) { return }
  $prefix = $Namespace + '__'
  foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
    if (-not $file.Name.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
    $full = Get-DuetCanonicalPath $file.FullName
    if ($full -and (Test-DuetPathUnderRoot -Child $full -Root $root)) {
      Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    }
  }
}

$haveMux = $true
try { $psmux = Get-DuetPsmux } catch { $haveMux = $false }

if (-not $haveMux) { Skip 'live namespace isolation (psmux unavailable)' }
else {
  $tag = [guid]::NewGuid().ToString('N').Substring(0, 10)
  $nsA = 'duetisoa' + $tag; $nsB = 'duetisob' + $tag; $raw = 'same'
  $saved = @{}
  foreach ($name in @('TMUX', 'TMUX_PANE', 'PSMUX_SESSION', 'PSMUX_TARGET_SESSION', 'PSMUX_NO_WARM')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
  }
  [Environment]::SetEnvironmentVariable('PSMUX_NO_WARM', '1', 'Process')
  $createdA = $false; $createdB = $false
  try {
    & $psmux -L $nsA new-session -d -s $raw -- powershell.exe -NoProfile -NoLogo -NoExit
    if ($LASTEXITCODE -ne 0) { throw 'could not create namespace A' }
    $createdA = $true
    & $psmux -L $nsB new-session -d -s $raw -- powershell.exe -NoProfile -NoLogo -NoExit
    if ($LASTEXITCODE -ne 0) { throw 'could not create namespace B' }
    $createdB = $true
    Start-Sleep -Milliseconds 500

    $fmt = '#{session_name}|#{pid}|#{pane_id}|#{pane_pid}'
    $lineA = @(& $psmux -L $nsA list-panes -s -t $raw -F $fmt)[0]
    $lineB = @(& $psmux -L $nsB list-panes -s -t $raw -F $fmt)[0]
    $a = $lineA -split '\|', 4; $b = $lineB -split '\|', 4
    Check ($a[0] -eq $raw -and $b[0] -eq $raw) 'two namespace backends may use the same raw session name'
    Check ($a[2] -eq $b[2]) 'the fixture reproduces duplicate bare pane ids across namespaces'
    Check ($a[1] -ne $b[1] -and $a[3] -ne $b[3]) 'duplicate raw identities have distinct backend and pane process ids'

    $global:DUET_PSMUX_NAMESPACE = $nsA; $global:DUET_PSMUX_REGISTRY = "${nsA}__${raw}"
    $global:DUET_PSMUX_SESSION = $raw; $global:DUET_PSMUX_SERVER_PID = $a[1]
    Check (Test-DuetServerMatches) 'namespace A server fence resolves only namespace A'
    $ownA = Resolve-DuetPaneResolution -PaneId $a[2] -PanePid $a[3]
    $foreignB = Resolve-DuetPaneResolution -PaneId $b[2] -PanePid $b[3]
    Check ($ownA.Known -and $ownA.Alive -and $ownA.Target -eq "${raw}:$($a[2])") 'namespace A exact tuple resolves to a bounded target'
    Check ($foreignB.Known -and -not $foreignB.Alive) 'namespace B recycled pane tuple is DEAD under namespace A, not ours'

    $global:DUET_PSMUX_NAMESPACE = $nsB; $global:DUET_PSMUX_REGISTRY = "${nsB}__${raw}"
    $global:DUET_PSMUX_SERVER_PID = $b[1]
    Check (Test-DuetServerMatches) 'namespace B server fence resolves only namespace B'
    $ownB = Resolve-DuetPaneResolution -PaneId $b[2] -PanePid $b[3]
    $foreignA = Resolve-DuetPaneResolution -PaneId $a[2] -PanePid $a[3]
    Check ($ownB.Known -and $ownB.Alive) 'namespace B exact tuple resolves'
    Check ($foreignA.Known -and -not $foreignA.Alive) 'namespace A tuple is DEAD under namespace B'
  }
  finally {
    if ($createdA) { & $psmux -L $nsA kill-session -t $raw 2>$null | Out-Null }
    if ($createdB) { & $psmux -L $nsB kill-session -t $raw 2>$null | Out-Null }
    for ($i = 0; $i -lt 50; $i++) {
      if (@(Get-ScratchNamespaceProcesses $nsA).Count -eq 0 -and @(Get-ScratchNamespaceProcesses $nsB).Count -eq 0) { break }
      Start-Sleep -Milliseconds 100
    }
    # A psmux build that ignores PSMUX_NO_WARM may still replenish a uniquely
    # named warm backend. Kill only processes carrying this test's exact -L token.
    $scratchProcesses = @()
    $scratchProcesses += @(Get-ScratchNamespaceProcesses $nsA)
    $scratchProcesses += @(Get-ScratchNamespaceProcesses $nsB)
    foreach ($proc in $scratchProcesses) {
      Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 20; $i++) {
      if (@(Get-ScratchNamespaceProcesses $nsA).Count -eq 0 -and @(Get-ScratchNamespaceProcesses $nsB).Count -eq 0) { break }
      Start-Sleep -Milliseconds 100
    }
    $noBackends = (@(Get-ScratchNamespaceProcesses $nsA).Count -eq 0 -and @(Get-ScratchNamespaceProcesses $nsB).Count -eq 0)
    Check $noBackends 'both namespaced scratch backends were torn down exactly'
    Remove-ScratchNamespaceRegistry $nsA
    Remove-ScratchNamespaceRegistry $nsB
    $registryRoot = Join-Path $env:USERPROFILE '.psmux'
    $leftA = @(Get-ChildItem -LiteralPath $registryRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($nsA + '__', [StringComparison]::Ordinal) }).Count
    $leftB = @(Get-ChildItem -LiteralPath $registryRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($nsB + '__', [StringComparison]::Ordinal) }).Count
    Check ($leftA -eq 0 -and $leftB -eq 0) 'scratch namespace registry entries were removed exactly'
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
  }
}

Write-Host "`nRESULT: $script:Pass passed, $script:Fail failed, $script:Skip skipped"
if ($script:Fail -gt 0) { exit 1 }
