# Deterministic tests for the atomic queue (enqueue/read/dedupe/FIFO/gates).
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File queue.tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function CheckReturnsFalse([scriptblock]$Block, [string]$Name) {
  try { $r = & $Block; Check (-not $r) $Name } catch { Check $false "$Name (threw: $($_.Exception.Message))" }
}

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1')
# Deterministic queue tests run without a live daemon: stub the liveness gate.
function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }

$scratch = Join-Path $env:TEMP ("duet-qtests-" + [guid]::NewGuid().ToString('N'))
$duet = Join-Path $scratch 'sess'; $sid = 'sess'
New-Item -ItemType Directory -Path $duet -Force | Out-Null

try {
  $box = Join-Path (Join-Path $duet 'inbox') 'codex-1'
  $bodies = @(
    "hello world",
    "line1`nline2`twith tab, punctuation !@#, unicode: cafe u+2603 snowman and CJK",
    "third message"
  )
  foreach ($b in $bodies) {
    Check (Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'NORMAL' -Origin 'LEADER' -LeaderAtSend 'claude' -Body $b) "enqueue normal message"
  }
  $files = @(Get-ChildItem -LiteralPath $box -Filter 'N-*.msg' -File | Sort-Object Name)
  Check ($files.Count -eq 3) "3 normal files present"
  Check ($files[0].Name -eq 'N-0000000001.msg' -and $files[2].Name -eq 'N-0000000003.msg') "monotonic zero-padded sequence"

  # Read back: bodies byte-identical (base64 round-trip through the wire format).
  for ($i = 0; $i -lt 3; $i++) {
    Check (Read-DuetMessage $files[$i].FullName) "read message $($i+1)"
    Check ($global:DUET_MESSAGE_BODY -eq $bodies[$i]) "body $($i+1) round-trips byte-for-byte"
    Check ($global:DUET_MESSAGE_ORDER -eq ('{0:D10}' -f ($i + 1))) "global order $($i+1) monotonic"
    Check ($global:DUET_MESSAGE_ID -eq "m-$sid-codex-1-$('{0:D10}' -f ($i+1))") "stable id $($i+1)"
  }
  # Payload wrapper shape.
  Read-DuetMessage $files[0].FullName | Out-Null
  $payload = Build-DuetPayload
  Check ($payload -match "^\[DUET session=$sid id=m-$sid-codex-1-0000000001 term=0 from=claude\]") "payload header well-formed"
  Check ($payload.EndsWith("[DUET session=$sid id=m-$sid-codex-1-0000000001 end]")) "payload footer well-formed"

  # Interrupt gets the I- prefix and continues the per-box sequence.
  Check (Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'INTERRUPT' -Origin 'LEADER' -LeaderAtSend 'claude' -Body 'stop') "enqueue interrupt"
  Check (Test-Path -LiteralPath (Join-Path $box 'I-0000000004.msg')) "interrupt uses I- prefix, seq 4"

  # Dedupe: a repeated key returns the same id and creates no second file.
  Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend 'claude' -Body 'first' -Dedupe 'k1' | Out-Null
  $id1 = $global:DUET_ENQUEUED_ID
  Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend 'claude' -Body 'second (ignored)' -Dedupe 'k1' | Out-Null
  $id2 = $global:DUET_ENQUEUED_ID
  Check ($id1 -and $id1 -eq $id2) "dedupe key returns the same message id"
  Check (@(Get-ChildItem -LiteralPath $box -Filter 'N-*.msg' -File).Count -eq 4) "dedupe created no second file (3 + 1 deduped)"

  Check ((Get-DuetPendingCount $duet) -eq 5) "pending count = 5 (3 normal + 1 interrupt + 1 dedupe)"

  # Validation refusals.
  CheckReturnsFalse { Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'x' -Recipient 'y' -Term '0' -Mode 'BOGUS' -Origin 'LEADER' -LeaderAtSend 'claude' -Body 'z' } "invalid mode rejected"
  CheckReturnsFalse { Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'bad/queue' -Sender 'x' -Recipient 'y' -Term '0' -Mode 'NORMAL' -Origin 'LEADER' -LeaderAtSend 'claude' -Body 'z' } "invalid queue name rejected"

  # Admission gates.
  Check (Test-Path -LiteralPath (Join-Path $duet 'inbox\codex-1')) "box exists"
  function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $false }
  CheckReturnsFalse { Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'NORMAL' -Origin 'LEADER' -LeaderAtSend 'claude' -Body 'nope' } "enqueue refused when daemon is not alive"
  function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }
  Write-DuetUtf8NoBom -Path (Join-Path $duet '.draining') -Value ''
  CheckReturnsFalse { Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'NORMAL' -Origin 'WORKER' -LeaderAtSend 'claude' -Body 'nope' } "normal enqueue refused while draining"
  Check (Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'leader' -Sender 'duet-system' -Recipient 'leader' -Term '0' -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend 'claude' -Body 'system notice' -Dedupe 'sysnote' -Internal) "internal SYSTEM enqueue allowed while draining"
  Write-DuetUtf8NoBom -Path (Join-Path $duet '.ended') -Value ''
  CheckReturnsFalse { Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'leader' -Sender 'duet-system' -Recipient 'leader' -Term '0' -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend 'claude' -Body 'nope' -Internal } "all enqueue refused once ended"
}
finally { try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
