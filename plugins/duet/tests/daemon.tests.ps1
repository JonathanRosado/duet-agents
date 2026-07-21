# Deterministic daemon tests: delivery FSM outcomes, interrupt supersession, and
# the crash-window reconciliations (terminal moves, quarantine intent, and exact
# manual-handoff pre/post-CAS completion).
# The verified-send FSM is stubbed; real composer behavior is the live-TUI smoke.
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File daemon.tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
$scriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
. (Join-Path $scriptsDir 'duet-common.ps1')
$Sid = 'sess'
$RosterPath = ''
$DuetDir = ''
$DUET_DELIVERY_MAX_ATTEMPTS = 5

# Stubs (set BEFORE dot-sourcing the lib so the lib's calls resolve to these).
function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }
$script:StubMemberAlive = $true          # Get-DuetMemberResolution alive?
$script:StubSendCode = 0                  # verified-send outcome
function Get-DuetMemberResolution { param($RosterPath, $Name) return [pscustomobject]@{ Known = $true; Alive = $script:StubMemberAlive; Target = "s:$Name" } }
function Test-DuetMemberAlive { param($RosterPath, $Name) return $script:StubMemberAlive }
function Send-DuetVerified { param($PaneId, $PanePid, $Payload, $Interrupt, $Harness, $Session, $ServerPid, $Registry) return [pscustomobject]@{ Code = $script:StubSendCode; EnterToken = ''; Collapsed = $false; LandingObserved = 'probe'; ComposerClear = $false } }
function Send-DuetEnterOnly { param($PaneId, $PanePid, $Payload, $MarkerToken, $Harness, $Session, $ServerPid) return [pscustomobject]@{ Code = $script:StubSendCode; EnterToken = ''; LandingObserved = 'probe'; ComposerClear = $true } }
function Clear-DuetRefusedComposer { param($PaneId, $PanePid, $MarkerToken, $Session, $ServerPid) return [pscustomobject]@{ Code = 0; ComposerClear = $true } }

. (Join-Path $scriptsDir 'duet-deliverd.lib.ps1')

$root = Join-Path $env:TEMP ("duet-dtests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
function WriteRaw([string]$Path, [string[]]$Lines) { [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc) }
function New-Duet {
  $d = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $d | Out-Null
  Write-DuetLeaderState -DuetDir $d -Term '0' -Leader 'claude' | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $d 'roster.tsv') -Value ("name`tharness`tpane_id`tpane_pid`trank`tspawned`nclaude`tclaude`t%1`t111`t0`t0`ncodex-1`tcodex`t%4`t222`t1`t1`nkimi-1`tkimi`t%7`t333`t2`t1") | Out-Null
  return $d
}
function Enq([string]$Queue, [string]$Recipient, [string]$Mode, [string]$Origin, [string]$Term, [string]$Sender, [string]$Body, [string]$Dedupe) {
  Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue $Queue -Sender $Sender -Recipient $Recipient -Term $Term -Mode $Mode -Origin $Origin -LeaderAtSend 'claude' -Body $Body -Dedupe $Dedupe -Internal | Out-Null
  return $global:DUET_ENQUEUED_FILE
}
function EnqHandoff([string]$Recipient, [string]$Term, [string]$PriorTerm, [string]$PriorLeader) {
  Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue 'promotions' -Sender 'duet-system' `
    -Recipient $Recipient -Term $Term -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend $Recipient `
    -Body "manual handoff to $Recipient" -Dedupe "promotion-$Term" -HandoffMode 'MANUAL' `
    -PriorTerm $PriorTerm -PriorLeader $PriorLeader -Internal | Out-Null
  return $global:DUET_ENQUEUED_FILE
}

try {
  # --- 1. Happy-path delivery: verified send Code 0 -> delivered/ --------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $script:StubMemberAlive = $true; $script:StubSendCode = 0
  $f = Enq 'codex-1' 'codex-1' 'NORMAL' 'LEADER' '0' 'claude' 'do the thing' ''
  $box = Split-Path -Parent $f
  Check (Process-One $box $f) "Process-One returns true (delivery)"
  Check (Test-Path -LiteralPath (Join-Path $box "delivered\$(Split-Path -Leaf $f)")) "verified send Code 0 -> moved to delivered/"

  # --- 2. Stale leader-term message is quarantined ----------------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $f = Enq 'codex-1' 'codex-1' 'NORMAL' 'LEADER' '9' 'claude' 'stale' ''   # term 9 != current 0
  $box = Split-Path -Parent $f
  Check (Process-One $box $f) "Process-One returns true (stale-term)"
  Check (Test-Path -LiteralPath (Join-Path $box "quarantine\$(Split-Path -Leaf $f)")) "stale leader-term -> quarantined"

  # --- 3. Foreign-session envelope is quarantined + noticed --------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $box = Join-Path (Join-Path $DuetDir 'inbox') 'codex-1'
  New-Item -ItemType Directory -Path (Join-Path $box 'quarantine') -Force | Out-Null
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('hi'))
  $fm = Join-Path $box 'N-0000000001.msg'
  WriteRaw $fm @('DUETv1', "id`tm-OTHER-codex-1-1", "session`tOTHER", "order`t1", "mode`tNORMAL", "sender`tclaude", "recipient`tcodex-1", "term`t0", "origin`tLEADER", "body64`t$b64")
  Check (Process-One $box $fm) "Process-One returns true (foreign)"
  Check (Test-Path -LiteralPath (Join-Path $box "quarantine\N-0000000001.msg")) "foreign-session envelope -> quarantined"
  Check (@(Get-ChildItem -LiteralPath (Join-Path $DuetDir 'inbox\leader') -Filter 'N-*.msg' -File -ErrorAction SilentlyContinue).Count -ge 1) "foreign quarantine queued a leader notice"

  # --- 4. Interrupt supersedes older normal work ------------------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $n = Enq 'codex-1' 'codex-1' 'NORMAL' 'LEADER' '0' 'claude' 'old task' ''
  $i = Enq 'codex-1' 'codex-1' 'INTERRUPT' 'LEADER' '0' 'claude' 'STOP redirect' ''
  $box = Split-Path -Parent $n
  $script:StubSendCode = 0
  Check (Process-One $box $i) "Process-One delivers the interrupt"
  Check (Test-Path -LiteralPath (Join-Path $box "superseded\$(Split-Path -Leaf $n)")) "older normal work superseded by the interrupt"

  # --- 5. RECONCILE terminal quarantine-intent (crash before terminalization) --
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $box = Join-Path (Join-Path $DuetDir 'inbox') 'codex-1'
  New-Item -ItemType Directory -Path (Join-Path $box 'quarantine') -Force | Out-Null
  $fm = Join-Path $box 'N-0000000001.msg'
  WriteRaw $fm @('DUETv1', "id`tm-sess-codex-1-1", "session`tsess", "order`t1", "mode`tNORMAL", "sender`tclaude", "recipient`tcodex-1", "term`t0", "origin`tLEADER")
  Set-Content -LiteralPath ($fm + '.quarantine_reason') -Value 'foreign-session' -Encoding ascii
  Check (Reconcile-TerminalMoves) "Reconcile-TerminalMoves returns true"
  Check ((Test-Path -LiteralPath (Join-Path $box 'quarantine\N-0000000001.msg')) -and -not (Test-Path -LiteralPath $fm)) "persisted quarantine-intent completed to quarantine/"

  # --- 6. RECONCILE terminal metadata sidecar left on the root -----------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $box = Join-Path (Join-Path $DuetDir 'inbox') 'codex-1'
  New-Item -ItemType Directory -Path (Join-Path $box 'delivered') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $box 'delivered\N-0000000002.msg') -Value 'x' -Encoding ascii
  Set-Content -LiteralPath (Join-Path $box 'N-0000000002.msg.reason') -Value 'stale-leader-term' -Encoding ascii
  Check (Reconcile-TerminalMoves) "Reconcile-TerminalMoves returns true (metadata)"
  Check ((Test-Path -LiteralPath (Join-Path $box 'delivered\N-0000000002.msg.reason')) -and -not (Test-Path -LiteralPath (Join-Path $box 'N-0000000002.msg.reason'))) "orphan terminal metadata moved beside its terminal record"

  # --- 7. Exact MANUAL intent completes the crash window before the CAS --------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $script:StubMemberAlive = $true
  $pf = EnqHandoff 'codex-1' '1' '0' 'claude'
  Check (Reconcile-PromotionIntents) 'manual intent reconciliation succeeds pre-CAS'
  Read-DuetLeaderState -DuetDir $DuetDir | Out-Null
  Check ($global:DUET_CURRENT_TERM -eq '1' -and $global:DUET_CURRENT_LEADER -eq 'codex-1') 'pre-CAS manual intent advances the exact generation/target'
  Check (Test-Path -LiteralPath ($pf + '.promotion_term')) 'pre-CAS completion publishes the delivery obligation'
  Check (-not (Test-Path -LiteralPath (Join-Path $DuetDir 'failed-leaders'))) 'crash completion creates no permanent exclusion metadata'

  # --- 8. Post-CAS restart repairs only delivery metadata ----------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $pf = EnqHandoff 'codex-1' '1' '0' 'claude'
  Write-DuetLeaderState -DuetDir $DuetDir -Term '1' -Leader 'codex-1' | Out-Null
  Check (Reconcile-PromotionIntents) 'manual intent reconciliation succeeds post-CAS'
  Check (Test-Path -LiteralPath ($pf + '.promotion_term')) 'post-CAS restart repairs the delivery obligation'

  # --- 9. Obsolete and nonmanual intents cannot mutate leadership -------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $pf = EnqHandoff 'codex-1' '1' '0' 'claude'
  Write-DuetLeaderState -DuetDir $DuetDir -Term '2' -Leader 'kimi-1' | Out-Null
  $pbox = Join-Path $DuetDir 'inbox\promotions'
  Check (Reconcile-PromotionIntents) 'obsolete manual intent reconciliation returns cleanly'
  Check (Test-Path -LiteralPath (Join-Path $pbox "quarantine\$(Split-Path -Leaf $pf)")) 'obsolete manual intent is quarantined'
  [void](Read-DuetLeaderState -DuetDir $DuetDir)
  Check ($global:DUET_CURRENT_TERM -eq '2' -and $global:DUET_CURRENT_LEADER -eq 'kimi-1') 'obsolete intent does not change leadership'

  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $bad = Enq 'promotions' 'codex-1' 'NORMAL' 'SYSTEM' '1' 'duet-system' 'not an operator intent' 'promotion-1'
  Check (Reconcile-PromotionIntents) 'nonmanual promotion-shaped message is handled'
  Check (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $bad) "quarantine\$(Split-Path -Leaf $bad)")) 'nonmanual promotion-shaped message is quarantined'
  [void](Read-DuetLeaderState -DuetDir $DuetDir)
  Check ($global:DUET_CURRENT_TERM -eq '0' -and $global:DUET_CURRENT_LEADER -eq 'claude') 'nonmanual message cannot initiate leadership'

  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $foreignHandoff = EnqHandoff 'codex-1' '1' '0' 'claude'
  $foreignText = (Get-DuetFileText $foreignHandoff) -replace '(?m)^session\tsess$', "session`tOTHER"
  [IO.File]::WriteAllText($foreignHandoff, $foreignText, $enc)
  Check (Reconcile-PromotionIntents) 'foreign manual handoff is handled before scheduling'
  Check (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $foreignHandoff) "quarantine\$(Split-Path -Leaf $foreignHandoff)")) 'foreign handoff is terminalized instead of stalling the promotion queue'
  [void](Read-DuetLeaderState -DuetDir $DuetDir)
  Check ($global:DUET_CURRENT_TERM -eq '0' -and $global:DUET_CURRENT_LEADER -eq 'claude') 'foreign handoff cannot mutate leadership'

  # --- 10. Completion waits for uncertain composer ownership ------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  [void](EnqHandoff 'codex-1' '1' '0' 'claude')
  $ubox = Join-Path $DuetDir 'inbox\codex-1'; New-Item -ItemType Directory -Path $ubox -Force | Out-Null
  WriteRaw (Join-Path $ubox 'N-0000000001.msg') @('DUETv1', "id`tm-sess-codex-1-1", "session`tsess", "order`t1", "mode`tNORMAL", "sender`tclaude", "recipient`tcodex-1", "term`t0", "origin`tLEADER")
  Set-Content -LiteralPath (Join-Path $ubox 'N-0000000001.msg.phase') -Value 'CLEAR_RETRY' -Encoding ascii
  Check (Reconcile-PromotionIntents) 'manual intent recovery defers cleanly behind uncertain delivery'
  Read-DuetLeaderState -DuetDir $DuetDir | Out-Null
  Check ($global:DUET_CURRENT_TERM -eq '0' -and $global:DUET_CURRENT_LEADER -eq 'claude') 'uncertain composer prevents crash-completion CAS'

  # --- 11. Recorded operator choice completes without a new health decision ---
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  [void](EnqHandoff 'codex-1' '1' '0' 'claude')
  $script:StubMemberAlive = $false
  Check (Reconcile-PromotionIntents) 'recorded intent completion does not re-decide target by health'
  [void](Read-DuetLeaderState -DuetDir $DuetDir)
  Check ($global:DUET_CURRENT_TERM -eq '1' -and $global:DUET_CURRENT_LEADER -eq 'codex-1') 'exact recorded target is preserved across the crash window'
  $script:StubMemberAlive = $true

  # --- 12. Recovered ex-leader traffic is fenced after handoff ----------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $stale = Enq 'kimi-1' 'kimi-1' 'NORMAL' 'LEADER' '0' 'claude' 'old leader broadcast' ''
  Write-DuetLeaderState -DuetDir $DuetDir -Term '1' -Leader 'codex-1' | Out-Null
  Check (Process-One (Split-Path -Parent $stale) $stale) 'ex-leader message is processed under the new generation'
  Check (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $stale) "quarantine\$(Split-Path -Leaf $stale)")) 'ex-leader authority is rejected after handoff'

  # --- 13. A failed durable write HALTS the pass (fail-closed) ----------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $script:StubMemberAlive = $true; $script:StubSendCode = 0
  $f = Enq 'codex-1' 'codex-1' 'NORMAL' 'LEADER' '0' 'claude' 'body' ''
  $box = Split-Path -Parent $f
  $script:realSCSet = (Get-Command SC-Set).ScriptBlock
  function SC-Set { param($File, $Suffix, $Value) if ($Suffix -eq 'phase') { return $false } return (& $script:realSCSet $File $Suffix $Value) }
  Check (-not (Process-One $box $f)) "a failed durable 'phase' write halts the pass (Process-One -> false)"
  Check (-not (Test-Path -LiteralPath (Join-Path $box "delivered\$(Split-Path -Leaf $f)"))) "message NOT advanced to delivered when a durable write failed"
  Set-Item -Path Function:\SC-Set -Value $script:realSCSet

  # --- 14. Failed durable sidecar deletion also halts reconciliation ----------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $box = Join-Path $DuetDir 'inbox\codex-1'; $terminal = Join-Path $box 'delivered\N-0000000001.msg'
  New-Item -ItemType Directory -Path (Split-Path -Parent $terminal) -Force | Out-Null
  WriteRaw $terminal @('terminal')
  Set-Content -LiteralPath (Join-Path $box 'N-0000000001.msg.phase') -Value 'READY' -Encoding ascii
  $script:realSCRemove = (Get-Command SC-Remove).ScriptBlock
  function SC-Remove { param($File, $Suffix) if ($Suffix -eq 'phase') { return $false } return (& $script:realSCRemove $File $Suffix) }
  Check (-not (Reconcile-TerminalMoves)) "a failed sidecar removal halts terminal reconciliation"
  Check (Test-Path -LiteralPath (Join-Path $box 'N-0000000001.msg.phase')) "failed sidecar removal remains visible for diagnosis"
  Set-Item -Path Function:\SC-Remove -Value $script:realSCRemove

  # --- 15. Oversized persisted numerics never throw or wrap -------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $script:StubMemberAlive = $true; $script:StubSendCode = 0
  $f = Enq 'codex-1' 'codex-1' 'NORMAL' 'LEADER' '0' 'claude' 'body' ''
  Set-Content -LiteralPath ($f + '.tries') -Value ('9' * 1000) -Encoding ascii
  Check (Process-One (Split-Path -Parent $f) $f) "oversized attempt count is terminalized without a cast exception"
  Check ((Get-DuetFileText ((Join-Path (Split-Path -Parent $f) "quarantine\$(Split-Path -Leaf $f)") + '.reason')).Trim() -eq 'invalid-delivery-attempt-count') "oversized attempt count is quarantined with a durable reason"

  Check (-not (Get-Command Watchdog-Check -ErrorAction SilentlyContinue)) 'daemon has no autonomous leadership checker'
  Check (-not (Get-Command Reconcile-NoSuccessor -ErrorAction SilentlyContinue)) 'daemon has no inferred no-successor transition'
}
finally { try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
