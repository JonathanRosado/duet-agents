# Deterministic daemon tests: delivery FSM outcomes, interrupt supersession, and
# the crash-window RECONCILIATIONS (terminal moves, quarantine-intent, promotion
# pre/post-CAS recovery, obsolete-intent quarantine, no-successor recovery).
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
  Write-DuetWatchdog -DuetDir $d -Session $Sid -Term '0' -Leader 'claude' -Count '0' | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $d 'roster.tsv') -Value ("name`tharness`tpane_id`tpane_pid`trank`tspawned`nclaude`tclaude`t%1`t111`t0`t0`ncodex-1`tcodex`t%4`t222`t1`t1`nkimi-1`tkimi`t%7`t333`t2`t1") | Out-Null
  return $d
}
function Enq([string]$Queue, [string]$Recipient, [string]$Mode, [string]$Origin, [string]$Term, [string]$Sender, [string]$Body, [string]$Dedupe) {
  Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue $Queue -Sender $Sender -Recipient $Recipient -Term $Term -Mode $Mode -Origin $Origin -LeaderAtSend 'claude' -Body $Body -Dedupe $Dedupe -Internal | Out-Null
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

  # --- 7. RECONCILE promotion-intent PRE-CAS (crash after enqueue, before CAS) --
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  $script:StubMemberAlive = $true
  [void](Enq 'promotions' 'codex-1' 'NORMAL' 'SYSTEM' '1' 'duet-system' 'you are leader term 1' 'promotion-1')
  # leader state still at term 0 / claude (CAS never ran).
  Check (Reconcile-PromotionIntents) "Reconcile-PromotionIntents returns true"
  Read-DuetLeaderState -DuetDir $DuetDir | Out-Null
  Check ($global:DUET_CURRENT_TERM -eq '1' -and $global:DUET_CURRENT_LEADER -eq 'codex-1') "pre-CAS promotion intent recovered: leader advanced to term 1 / codex-1"
  Check (Test-Path -LiteralPath (Join-Path $DuetDir 'failed-leaders\claude')) "recovered promotion excluded the failed incumbent"

  # --- 8. RECONCILE obsolete promotion intent -> quarantine --------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  Write-DuetLeaderState -DuetDir $DuetDir -Term '2' -Leader 'kimi-1' | Out-Null   # already advanced past term 1
  $pf = Enq 'promotions' 'codex-1' 'NORMAL' 'SYSTEM' '1' 'duet-system' 'stale promotion' 'promotion-1'
  # Sidecars a real promotion transaction wrote before the state moved on.
  Set-Content -LiteralPath ($pf + '.prior_term') -Value '0' -Encoding ascii
  Set-Content -LiteralPath ($pf + '.failed') -Value 'claude' -Encoding ascii
  Set-Content -LiteralPath ($pf + '.promotion_term') -Value '1' -Encoding ascii
  $pbox = Join-Path (Join-Path $DuetDir 'inbox') 'promotions'
  Check (Reconcile-PromotionIntents) "Reconcile-PromotionIntents returns true (obsolete)"
  Check (@(Get-ChildItem -LiteralPath (Join-Path $pbox 'quarantine') -Filter 'N-*.msg' -File -ErrorAction SilentlyContinue).Count -eq 1) "obsolete promotion intent quarantined"

  # --- 9. RECONCILE no-successor terminal state --------------------------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  Write-DuetAtomicMultiline -Path (Join-Path $DuetDir 'no-successor') -Value ("session`t$Sid`nfrom_term`t0`nterm`t1`nfailed`tclaude`nreason`tHARD") | Out-Null
  # leader still at from_term 0 / claude (CAS never ran).
  Check (Reconcile-NoSuccessor) "Reconcile-NoSuccessor returns true"
  Read-DuetLeaderState -DuetDir $DuetDir | Out-Null
  Check ($global:DUET_CURRENT_TERM -eq '1' -and $global:DUET_CURRENT_LEADER -eq 'NONE') "no-successor recovered: term 1 / leader NONE"

  # --- 10. RECONCILE promotion POST-CAS (leader advanced, metadata unfinished) -
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  Write-DuetLeaderState -DuetDir $DuetDir -Term '1' -Leader 'codex-1' | Out-Null    # CAS already applied
  Write-DuetWatchdog -DuetDir $DuetDir -Session $Sid -Term '0' -Leader 'claude' -Count '0' | Out-Null  # stale (pre-CAS)
  $pf = Enq 'promotions' 'codex-1' 'NORMAL' 'SYSTEM' '1' 'duet-system' 'you are leader' 'promotion-1'
  Set-Content -LiteralPath ($pf + '.prior_term') -Value '0' -Encoding ascii
  Set-Content -LiteralPath ($pf + '.failed') -Value 'claude' -Encoding ascii
  Set-Content -LiteralPath ($pf + '.promotion_term') -Value '1' -Encoding ascii
  Check (Reconcile-PromotionIntents) "Reconcile-PromotionIntents returns true (post-CAS)"
  Check (Test-Path -LiteralPath (Join-Path $DuetDir 'failed-leaders\claude')) "post-CAS repair marks the failed incumbent"
  Check ((Get-DuetFirstLineValue -Path (Join-Path $DuetDir 'watchdog') -Key 'term') -eq '1' -and (Get-DuetFirstLineValue -Path (Join-Path $DuetDir 'watchdog') -Key 'leader') -eq 'codex-1') "post-CAS repair rewrites the watchdog to the new term/leader"

  # --- 11. RECONCILE no-successor POST-CAS (leader already NONE) --------------
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  Write-DuetLeaderState -DuetDir $DuetDir -Term '1' -Leader 'NONE' | Out-Null
  Write-DuetWatchdog -DuetDir $DuetDir -Session $Sid -Term '0' -Leader 'claude' -Count '0' | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $DuetDir 'no-successor') -Value ("session`t$Sid`nfrom_term`t0`nterm`t1`nfailed`tclaude`nreason`tHARD") | Out-Null
  Check (Reconcile-NoSuccessor) "Reconcile-NoSuccessor returns true (post-CAS NONE)"
  Check (Test-Path -LiteralPath (Join-Path $DuetDir 'failed-leaders\claude')) "post-CAS no-successor marks the failed incumbent"
  Check ((Get-DuetFirstLineValue -Path (Join-Path $DuetDir 'watchdog') -Key 'leader') -eq 'NONE' -and (Get-DuetFirstLineValue -Path (Join-Path $DuetDir 'watchdog') -Key 'term') -eq '1') "post-CAS no-successor rewrites the watchdog to NONE/term 1"

  # --- 12. Promotion-intent recovery DEFERRED behind an uncertain delivery ----
  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'   # leader still term 0 / claude
  [void](Enq 'promotions' 'codex-1' 'NORMAL' 'SYSTEM' '1' 'duet-system' 'promo' 'promotion-1')
  $ubox = Join-Path $DuetDir 'inbox\codex-1'; New-Item -ItemType Directory -Path $ubox -Force | Out-Null
  WriteRaw (Join-Path $ubox 'N-0000000001.msg') @('DUETv1', "id`tm-sess-codex-1-1", "session`tsess", "order`t1", "mode`tNORMAL", "sender`tclaude", "recipient`tcodex-1", "term`t0", "origin`tLEADER")
  Set-Content -LiteralPath (Join-Path $ubox 'N-0000000001.msg.phase') -Value 'CLEAR_RETRY' -Encoding ascii
  Check (Reconcile-PromotionIntents) "Reconcile-PromotionIntents returns true (deferred)"
  Read-DuetLeaderState -DuetDir $DuetDir | Out-Null
  Check ($global:DUET_CURRENT_TERM -eq '0' -and $global:DUET_CURRENT_LEADER -eq 'claude') "promotion CAS deferred while an uncertain delivery is pending"

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

  $DuetDir = New-Duet; $RosterPath = Join-Path $DuetDir 'roster.tsv'
  Write-DuetWatchdog -DuetDir $DuetDir -Session 'foreign' -Term '0' -Leader 'claude' -Count '2' | Out-Null
  Check (-not (Watchdog-Check)) "foreign-session watchdog state fails closed"
  Write-DuetAtomicMultiline -Path (Join-Path $DuetDir 'no-successor') -Value ("session`t$Sid`nfrom_term`t$('9' * 1000)`nterm`t1`nfailed`tclaude`nreason`tHARD") | Out-Null
  Check (-not (Reconcile-NoSuccessor)) "oversized no-successor term is rejected without throwing"
}
finally { try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
