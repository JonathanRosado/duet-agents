# Windows/psmux reap-safety tests. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File plugins/duet/tests/reap-guard.tests.ps1
$ErrorActionPreference = 'Stop'
$common = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1'
. $common

$script:passed = 0
$script:failed = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:passed++; Write-Host "  PASS $Name" }
  else { $script:failed++; Write-Host "  FAIL $Name" }
}

$tmp = Join-Path $env:TEMP ("duet-reap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$roster = Join-Path $tmp 'roster.tsv'

function Write-Roster([string[]]$Rows) {
  $content = @("name`tharness`tpane_id`tpane_pid`trank`tspawned") + $Rows
  [System.IO.File]::WriteAllLines($roster, $content, (New-Object System.Text.UTF8Encoding($false)))
}

$script:ResolvePlan = @{}
$script:ResolveCalls = @{}
$script:Killed = @()
$script:LivePids = @{}
function Resolve-DuetPaneResolution {
  param([string]$Session, [string]$ServerPid, [string]$PaneId, [string]$PanePid)
  $index = if ($script:ResolveCalls.ContainsKey($PaneId)) { [int]$script:ResolveCalls[$PaneId] } else { 0 }
  $script:ResolveCalls[$PaneId] = $index + 1
  $plan = @($script:ResolvePlan[$PaneId])
  if ($plan.Count -eq 0) { return [pscustomobject]@{ Known = $false; Alive = $false; Target = '' } }
  if ($index -ge $plan.Count) { $index = $plan.Count - 1 }
  return $plan[$index]
}
function Stop-Process {
  param([int]$Id, [switch]$Force, $ErrorAction)
  $script:Killed += $Id
  $script:LivePids[[string]$Id] = $false
}
function Test-DuetProcessAlive([string]$ProcessId) { return [bool]$script:LivePids[[string]$ProcessId] }
function Resolution([bool]$Known, [bool]$Alive, [string]$Target = '') {
  return [pscustomobject]@{ Known = $Known; Alive = $Alive; Target = $Target }
}
function Reset-Fixture {
  $script:ResolvePlan = @{}; $script:ResolveCalls = @{}; $script:Killed = @(); $script:LivePids = @{}
}

try {
  Reset-Fixture
  Write-Roster @("worker`tcodex`t%2`t222`t1`t1")
  $script:ResolvePlan['%2'] = @(Resolution $true $false)
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ($result -and $script:Killed.Count -eq 0) 'known-dead tuple is already stopped'

  Reset-Fixture
  $script:ResolvePlan['%2'] = @(Resolution $false $false)
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ((-not $result) -and $script:Killed.Count -eq 0) 'unknown tuple fails closed without signaling a pid'

  Reset-Fixture
  $script:ResolvePlan['%2'] = @((Resolution $true $true 's:%2'), (Resolution $true $true 's:%2'))
  $script:LivePids['222'] = $true
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ($result -and ($script:Killed -join ',') -eq '222') 'live tuple is re-resolved and only its recorded pid is stopped'

  Reset-Fixture
  $script:ResolvePlan['%2'] = @((Resolution $true $true 's:%2'), (Resolution $false $false))
  $script:LivePids['222'] = $true
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ((-not $result) -and $script:Killed.Count -eq 0) 'identity becoming unknown in the resolve-to-stop window blocks Stop-Process'

  Reset-Fixture
  Write-Roster @("caller`tclaude`t%1`t111`t0`t1")
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ($result -and $script:Killed.Count -eq 0 -and $script:ResolveCalls.Count -eq 0) 'exact caller tuple is exempt before resolution'

  Reset-Fixture
  Write-Roster @("recycled`tclaude`t%1`t222`t0`t1")
  $script:ResolvePlan['%1'] = @((Resolution $true $true 's:%1'), (Resolution $true $true 's:%1'))
  $script:LivePids['222'] = $true
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ($result -and ($script:Killed -join ',') -eq '222') 'pane id alone is not exempt when pane_pid differs'

  Reset-Fixture
  Write-Roster @("broken`tcodex`t`t222`t1`t1")
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ((-not $result) -and $script:Killed.Count -eq 0) 'spawned row missing a tuple fails closed'

  Reset-Fixture
  Write-Roster @("broken`tcodex`t%2`tnot-a-pid`t1`t1")
  $script:ResolvePlan['%2'] = @(Resolution $true $true 's:%2')
  $result = Stop-DuetSpawnedPanes -RosterPath $roster -ExemptPaneId '%1' -ExemptPanePid '111'
  Check ((-not $result) -and $script:Killed.Count -eq 0) 'non-numeric pane_pid is never passed to Stop-Process'

  $result = Stop-DuetSpawnedPanes -RosterPath (Join-Path $tmp 'missing.tsv') -ExemptPaneId '%1' -ExemptPanePid '111'
  Check (-not $result) 'missing roster cannot authorize process teardown'
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nRESULT: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
