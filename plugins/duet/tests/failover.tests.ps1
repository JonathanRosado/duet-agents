# Deterministic tests for explicit manual leadership handoff and its generation
# fences. Run with powershell.exe -NoProfile -File failover.tests.ps1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1')

# Queue admission and pane liveness are deterministic in this unit fixture.
function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }
function Test-DuetMemberAlive { param($RosterPath, $Name) return $true }

$root = Join-Path $env:TEMP ("duet-manual-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-TestDuet {
  $d = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $d | Out-Null
  Write-DuetLeaderState -DuetDir $d -Term '0' -Leader 'claude' | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $d 'roster.tsv') -Value ("name`tharness`tpane_id`tpane_pid`trank`tspawned`nclaude`tclaude`t%1`t111`t0`t0`ncodex-1`tcodex`t%4`t222`t1`t1`nkimi-1`tkimi`t%7`t333`t2`t1") | Out-Null
  return $d
}
function Handoff([string]$Dir, [string]$Term, [string]$Leader, [string]$Target) {
  return (Invoke-DuetPromoteLocked -DuetDir $Dir -SessionId 'sess' -RosterPath (Join-Path $Dir 'roster.tsv') `
    -ExpectedTerm $Term -ExpectedLeader $Leader -Reason 'MANUAL:test' -Requested $Target)
}

try {
  # Explicit target, immutable operator intent, and generation CAS.
  $d = New-TestDuet
  $rc = Handoff $d '0' 'claude' 'kimi-1'
  Check ($rc -eq 0 -and $global:DUET_PROMOTED_LEADER -eq 'kimi-1' -and $global:DUET_PROMOTED_TERM -eq '1') 'explicit target wins regardless of display rank'
  [void](Read-DuetLeaderState -DuetDir $d)
  Check ($global:DUET_CURRENT_TERM -eq '1' -and $global:DUET_CURRENT_LEADER -eq 'kimi-1') 'leader generation advances exactly once'
  $messages = @(Get-ChildItem -LiteralPath (Join-Path $d 'inbox\promotions') -Filter 'N-*.msg' -File)
  Check ($messages.Count -eq 1) 'one durable handoff intent is queued'
  $parsed = Read-DuetMessage $messages[0].FullName
  Check ($parsed -and $global:DUET_MESSAGE_HANDOFF_MODE -eq 'MANUAL' -and $global:DUET_MESSAGE_PRIOR_TERM -eq '0' `
      -and $global:DUET_MESSAGE_PRIOR_LEADER -eq 'claude' -and $global:DUET_MESSAGE_TERM -eq '1' `
      -and $global:DUET_MESSAGE_RECIPIENT -eq 'kimi-1') 'handoff message carries the exact prior/new tuple'
  Check (Test-Path -LiteralPath ($messages[0].FullName + '.promotion_term')) 'delivery obligation is published before the leader record'
  Check (-not (Test-Path -LiteralPath (Join-Path $d 'failed-leaders'))) 'handoff does not create permanent leader exclusions'

  # No default candidate and no automatic rank choice.
  $d2 = New-TestDuet
  $rc = Handoff $d2 '0' 'claude' ''
  Check ($rc -eq 3) 'missing explicit target is rejected'
  [void](Read-DuetLeaderState -DuetDir $d2)
  Check ($global:DUET_CURRENT_TERM -eq '0' -and $global:DUET_CURRENT_LEADER -eq 'claude') 'missing target cannot mutate leadership'

  # Generation fence and target liveness fence.
  $rc = Handoff $d '0' 'claude' 'codex-1'
  Check ($rc -eq 2) 'stale compare-and-swap is rejected'
  function Test-DuetMemberAlive { param($RosterPath, $Name) return ($Name -ne 'codex-1') }
  $d3 = New-TestDuet
  $rc = Handoff $d3 '0' 'claude' 'codex-1'
  Check ($rc -eq 3) 'confirmed-dead target is rejected before intent publication'
  Check (@(Get-ChildItem -LiteralPath (Join-Path $d3 'inbox\promotions') -Filter '*.msg' -File -ErrorAction SilentlyContinue).Count -eq 0) 'dead target leaves no handoff journal'

  # Uncertain composer ownership blocks the operator transaction with no bypass.
  function Test-DuetMemberAlive { param($RosterPath, $Name) return $true }
  $d4 = New-TestDuet
  $uncertain = Join-Path $d4 'inbox\codex-1\N-0000000001.msg'
  New-Item -ItemType Directory -Path (Split-Path -Parent $uncertain) -Force | Out-Null
  Write-DuetAtomicMultiline -Path $uncertain -Value 'placeholder' | Out-Null
  Write-DuetAtomicMultiline -Path ($uncertain + '.phase') -Value 'CLEAR_RETRY' | Out-Null
  $rc = Handoff $d4 '0' 'claude' 'kimi-1'
  Check ($rc -eq 11 -and $global:DUET_PROMOTION_BLOCKER -eq $uncertain) 'uncertain delivery blocks manual handoff'
  [void](Read-DuetLeaderState -DuetDir $d4)
  Check ($global:DUET_CURRENT_TERM -eq '0' -and $global:DUET_CURRENT_LEADER -eq 'claude') 'uncertain guard leaves the leader generation unchanged'

  # A prior leader can be selected again; there is no permanent exclusion set.
  function Test-DuetMemberAlive { param($RosterPath, $Name) return $true }
  $d5 = New-TestDuet
  Check ((Handoff $d5 '0' 'claude' 'codex-1') -eq 0) 'first handoff claude to codex succeeds'
  Check ((Handoff $d5 '1' 'codex-1' 'claude') -eq 0) 'explicit handoff back to the prior leader succeeds'
  [void](Read-DuetLeaderState -DuetDir $d5)
  Check ($global:DUET_CURRENT_TERM -eq '2' -and $global:DUET_CURRENT_LEADER -eq 'claude') 'promote-back preserves monotonic generation'

  # The strict parser rejects partial or forged manual intent fields.
  $forged = Join-Path $root 'forged.msg'
  $content = "DUETv1`nid`tm-sess-promotions-9`nsession`tsess`norder`t1`nmode`tNORMAL`nsender`tduet-system`nrecipient`tcodex-1`nterm`t1`norigin`tSYSTEM`nleader_at_send`tcodex-1`ndedupe`tpromotion-1`nhandoff_mode`tMANUAL`nbody64`tWA==`n"
  [IO.File]::WriteAllText($forged, $content, (New-Object Text.UTF8Encoding($false)))
  Check (-not (Read-DuetMessage $forged)) 'partial manual handoff envelope is rejected'
}
finally { try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
