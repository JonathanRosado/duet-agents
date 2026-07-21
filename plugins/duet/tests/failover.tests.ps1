# Deterministic tests for the fenced promotion CAS, uncertain-delivery fence, and
# process-fenced spawned-pane teardown. Run:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File failover.tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1')
$enc = New-Object System.Text.UTF8Encoding($false)
function WriteMsg([string]$Path, [string[]]$Lines) { [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc) }

# Deterministic: no live daemon; control member liveness.
function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }

$root = Join-Path $env:TEMP ("duet-fo-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-TestDuet {
  $d = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $d | Out-Null
  Write-DuetLeaderState -DuetDir $d -Term '0' -Leader 'claude' | Out-Null
  Write-DuetWatchdog -DuetDir $d -Session 'sess' -Term '0' -Leader 'claude' -Count '0' | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $d 'roster.tsv') -Value ("name`tharness`tpane_id`tpane_pid`trank`tspawned`nclaude`tclaude`t%1`t111`t0`t0`ncodex-1`tcodex`t%4`t222`t1`t1`nkimi-1`tkimi`t%7`t333`t2`t1") | Out-Null
  return $d
}
function Promote($d, $term, $leader, $reason, $req) {
  Invoke-DuetPromoteLocked -DuetDir $d -SessionId 'sess' -RosterPath (Join-Path $d 'roster.tsv') -ExpectedTerm $term -ExpectedLeader $leader -Reason $reason -Requested $req
}

try {
  # --- 1. Hard failover: leader dead, workers alive -> lowest live rank ---------
  function Test-DuetMemberAlive { param($RosterPath, $Name) return ($Name -ne 'claude') }
  $d = New-TestDuet
  $rc = Promote $d '0' 'claude' 'HARD' ''
  Check ($rc -eq 0 -and $global:DUET_PROMOTED_LEADER -eq 'codex-1' -and $global:DUET_PROMOTED_TERM -eq '1') "hard failover claude -> codex-1 (lowest live rank), term 1"
  Read-DuetLeaderState -DuetDir $d | Out-Null
  Check ($global:DUET_CURRENT_LEADER -eq 'codex-1' -and $global:DUET_CURRENT_TERM -eq '1') "leader state advanced to term 1 / codex-1"
  Check (Test-Path -LiteralPath (Join-Path $d 'failed-leaders\claude')) "failed incumbent recorded"
  $pmsg = @(Get-ChildItem -LiteralPath (Join-Path $d 'inbox\promotions') -Filter 'N-*.msg' -File)
  Check ($pmsg.Count -eq 1) "one promotion notice enqueued to promotions queue"
  Check ((Read-DuetMessage $pmsg[0].FullName) -and $global:DUET_MESSAGE_RECIPIENT -eq 'codex-1' -and $global:DUET_MESSAGE_TERM -eq '1' -and $global:DUET_MESSAGE_ORIGIN -eq 'SYSTEM' -and $global:DUET_MESSAGE_DEDUPE -eq 'promotion-1') "promotion notice addressed to codex-1, term 1, dedupe promotion-1"
  Check (Test-Path -LiteralPath ($pmsg[0].FullName + '.promotion_term')) "promotion sidecar metadata published"

  # --- 2. Stale compare-and-swap -> 2 ------------------------------------------
  $rc = Promote $d '0' 'claude' 'HARD' ''      # term is now 1, not 0
  Check ($rc -eq 2) "stale CAS (wrong expected term) -> 2"

  # --- 3. Manual promotion to a requested successor ----------------------------
  function Test-DuetMemberAlive { param($RosterPath, $Name) return $true }
  $d = New-TestDuet
  $rc = Promote $d '0' 'claude' 'MANUAL' 'kimi-1'
  Check ($rc -eq 0 -and $global:DUET_PROMOTED_LEADER -eq 'kimi-1') "manual promote --to kimi-1"

  # --- 4. Requested successor is dead -> 3 -------------------------------------
  function Test-DuetMemberAlive { param($RosterPath, $Name) return ($Name -eq 'codex-1') }
  $d = New-TestDuet
  $rc = Promote $d '0' 'claude' 'MANUAL' 'kimi-1'
  Check ($rc -eq 3 -and -not (Test-Path -LiteralPath (Join-Path $d 'failed-leaders\claude'))) "requested dead successor -> 3 (incumbent NOT excluded)"

  # --- 5. No live eligible successor -> 10 / NONE ------------------------------
  function Test-DuetMemberAlive { param($RosterPath, $Name) return $false }
  $d = New-TestDuet
  $rc = Promote $d '0' 'claude' 'HARD' ''
  Check ($rc -eq 10 -and $global:DUET_PROMOTED_LEADER -eq 'NONE') "no live successor -> 10 (leader NONE)"
  Read-DuetLeaderState -DuetDir $d | Out-Null
  Check ($global:DUET_CURRENT_LEADER -eq 'NONE' -and $global:DUET_CURRENT_TERM -eq '1') "leader state = NONE, term 1"
  Check (Test-Path -LiteralPath (Join-Path $d 'no-successor')) "no-successor marker written"

  # --- 6. Uncertain delivery defers promotion -> 11 ----------------------------
  function Test-DuetMemberAlive { param($RosterPath, $Name) return $true }
  $d = New-TestDuet
  $ubox = Join-Path $d 'inbox\codex-1'; New-Item -ItemType Directory -Path $ubox -Force | Out-Null
  WriteMsg (Join-Path $ubox 'N-0000000001.msg') @('DUETv1', "id`tm-sess-codex-1-1", "session`tsess", "order`t1", "mode`tNORMAL", "sender`tclaude", "recipient`tcodex-1", "term`t0", "origin`tLEADER")
  Set-Content -LiteralPath (Join-Path $ubox 'N-0000000001.msg.phase') -Value 'CLEAR_RETRY' -Encoding ascii
  Check (Test-DuetUncertainDelivery -DuetDir $d) "Test-DuetUncertainDelivery true for a CLEAR_RETRY phase"
  $rc = Promote $d '0' 'claude' 'HARD' ''
  Check ($rc -eq 11 -and $global:DUET_PROMOTION_BLOCKER) "uncertain delivery defers promotion -> 11 (incumbent not yet excluded)"
  Check (-not (Test-Path -LiteralPath (Join-Path $d 'failed-leaders\claude'))) "deferred promotion did not exclude the incumbent"

  # --- 7. Teardown: never Stop a pid whose tuple does not resolve ---------------
  $d = New-TestDuet
  $script:stopped = @()
  function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stopped += $Id }
  function Test-DuetProcessAlive { param($ProcessId) return -not ($script:stopped -contains [int]$ProcessId) }
  function Resolve-DuetPaneResolution { param($PaneId, $PanePid, $Session, $ServerPid) return [pscustomobject]@{ Known = $true; Alive = $false; Target = $null } }
  [void](Stop-DuetSpawnedPanes -RosterPath (Join-Path $d 'roster.tsv') -ExemptPaneId '%1' -ExemptPanePid '111')
  Check ($script:stopped.Count -eq 0) "teardown Stops nothing when tuples resolve DEAD/UNKNOWN"
  # Now: resolve alive -> Stops only spawned, non-exempt members.
  function Resolve-DuetPaneResolution { param($PaneId, $PanePid, $Session, $ServerPid) return [pscustomobject]@{ Known = $true; Alive = $true; Target = "s:$PaneId" } }
  $script:stopped = @()
  [void](Stop-DuetSpawnedPanes -RosterPath (Join-Path $d 'roster.tsv') -ExemptPaneId '%1' -ExemptPanePid '111')
  Check (($script:stopped.Count -eq 2) -and ($script:stopped -contains 222) -and ($script:stopped -contains 333)) "teardown Stops the two spawned worker pids (222,333), never the initiator (actual=$($script:stopped -join ','))"
}
finally { try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
