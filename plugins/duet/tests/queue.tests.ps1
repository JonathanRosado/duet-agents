# Atomic DUETv4 queue, FIFO, and concurrent publication tests.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0
$script:Fail = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function CheckFalse([scriptblock]$Block, [string]$Name) {
  try { Check (-not (& $Block)) $Name } catch { Check $false "$Name (threw)" }
}

$plugin = Split-Path -Parent $PSScriptRoot
$common = Join-Path $plugin 'scripts\duet-common.ps1'
. $common
function Test-DuetDaemonAlive { return $true }

$scratch = Join-Path $env:TEMP ('duet-v4-queue-' + [guid]::NewGuid().ToString('N'))
$sid = 'queue-v4'
$duet = Join-Path $scratch $sid
$box = Join-Path $duet 'inbox\codex-1'
New-Item -ItemType Directory -Path (Join-Path $box 'delivered'), (Join-Path $box 'rejected') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $duet 'inbox\claude\delivered'), (Join-Path $duet 'inbox\claude\rejected') -Force | Out-Null
Write-DuetUtf8NoBom -Path (Join-Path $duet 'transcript.md') -Value ''
Write-DuetAtomicMultiline -Path (Join-Path $duet 'roster.tsv') -Value @"
name	harness	pane_id	pane_pid	rank	spawned
claude	claude	%1	101	0	0
codex-1	codex	%2	102	1	1
"@ | Out-Null

try {
  Check (Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'claude' -Recipient 'codex-1' -Mode 'NORMAL' -Body "one`nΩ") `
    'normal message enqueues'
  $first = $global:DUET_ENQUEUED_FILE
  Check ((Split-Path -Leaf $first) -eq 'N-0000000001.msg' -and
      $global:DUET_ENQUEUED_ID -eq "m-$sid-codex-1-0000000001") `
    'first message gets stable queue-scoped id'
  Check ((Read-DuetMessage $first) -and $global:DUET_MESSAGE_BODY -eq "one`nΩ" -and
      $global:DUET_MESSAGE_RECIPIENT -eq 'codex-1') `
    'published DUETv4 envelope preserves Unicode body'

  Check (Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'claude' -Recipient 'all' -Mode 'INTERRUPT' -Body 'urgent') `
    'broadcast fanout envelope accepts wire recipient all'
  Check ((Split-Path -Leaf $global:DUET_ENQUEUED_FILE) -eq 'I-0000000002.msg') `
    'interrupt uses I prefix without changing monotonic sequence'
  Check ((Get-DuetFileText (Join-Path $box '.counter')).Trim() -eq '2') `
    'queue counter advances atomically'
  $transcript = Get-DuetFileText (Join-Path $duet 'transcript.md')
  Check (($transcript.IndexOf('id=m-' + $sid + '-codex-1-0000000001') -lt
      $transcript.IndexOf('id=m-' + $sid + '-codex-1-0000000002'))) `
    'transcript order matches queue sequence'

  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'bad/queue' `
      -Sender 'claude' -Recipient 'bad/queue' -Mode 'NORMAL' -Body x
  } 'invalid queue name is rejected'
  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'ghost' `
      -Sender 'claude' -Recipient 'ghost' -Mode 'NORMAL' -Body x
  } 'nonmember queue is rejected'
  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'ghost' -Recipient 'codex-1' -Mode 'NORMAL' -Body x
  } 'nonmember sender is rejected'
  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'claude' -Recipient 'claude' -Mode 'NORMAL' -Body x
  } 'redirected physical queue is rejected'
  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'claude' -Recipient 'codex-1' -Mode 'BOGUS' -Body x
  } 'invalid mode is rejected'

  Write-DuetAtomicMultiline -Path (Join-Path $duet '.ended') -Value '' | Out-Null
  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'claude' -Recipient 'codex-1' -Mode 'NORMAL' -Body x
  } 'ended session rejects enqueue'
  Remove-Item -LiteralPath (Join-Path $duet '.ended') -Force
  function Test-DuetDaemonAlive { return $false }
  CheckFalse {
    Add-DuetMessage -DuetDir $duet -SessionId $sid -Queue 'codex-1' `
      -Sender 'claude' -Recipient 'codex-1' -Mode 'NORMAL' -Body x
  } 'dead daemon rejects enqueue'
  function Test-DuetDaemonAlive { return $true }

  Write-DuetAtomicMultiline -Path (Join-Path $box '.counter') -Value '0' | Out-Null
  CheckFalse { Get-DuetNextSequence -Box $box } `
    'counter rollback cannot reuse an allocated sequence'
  Write-DuetAtomicMultiline -Path (Join-Path $box '.counter') -Value '9999999999' | Out-Null
  CheckFalse { Get-DuetNextSequence -Box $box } 'D10 sequence exhaustion fails closed'

  Write-Host 'queue: concurrent publishers'
  $concurrentSid = 'concurrent-v4'
  $concurrent = Join-Path $scratch $concurrentSid
  $concurrentBox = Join-Path $concurrent 'inbox\codex-1'
  New-Item -ItemType Directory -Path (Join-Path $concurrentBox 'delivered'), (Join-Path $concurrentBox 'rejected') -Force | Out-Null
  Write-DuetUtf8NoBom -Path (Join-Path $concurrent 'transcript.md') -Value ''
  Write-DuetAtomicMultiline -Path (Join-Path $concurrent 'roster.tsv') -Value @"
name	harness	pane_id	pane_pid	rank	spawned
claude	claude	%1	201	0	0
codex-1	codex	%2	202	1	1
"@ | Out-Null
  $child = Join-Path $scratch 'enqueue-child.ps1'
  [IO.File]::WriteAllText($child, @'
param([string]$Common, [string]$DuetDir, [string]$Sid, [int]$Index, [string]$ErrorPath)
$ErrorActionPreference = 'Stop'
try {
  . $Common
  function Test-DuetDaemonAlive { return $true }
  if (-not (Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Mode 'NORMAL' -Body "concurrent-$Index")) {
    throw 'Add-DuetMessage returned false'
  }
} catch {
  [IO.File]::WriteAllText($ErrorPath, ($_ | Out-String), (New-Object Text.UTF8Encoding($false)))
  exit 1
}
'@, (New-Object Text.UTF8Encoding($false)))
  $children = @()
  for ($i = 1; $i -le 30; $i++) {
    $errorPath = Join-Path $scratch "enqueue-$i.error"
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Common "{1}" -DuetDir "{2}" -Sid "{3}" -Index {4} -ErrorPath "{5}"' -f
      $child, $common, $concurrent, $concurrentSid, $i, $errorPath
    $process = Start-Process powershell.exe -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
    $children += [pscustomobject]@{ Process = $process; ErrorPath = $errorPath; Index = $i }
  }
  foreach ($childProcess in $children) {
    $childProcess.Process.WaitForExit()
    $childProcess.Process.Refresh()
  }
  $failedChildren = @($children | Where-Object { $_.Process.ExitCode -ne 0 })
  foreach ($failedChild in $failedChildren) {
    $detail = Get-Content -LiteralPath $failedChild.ErrorPath -Raw -ErrorAction SilentlyContinue
    Write-Host ("    child {0} exit={1}: {2}" -f
      $failedChild.Index, $failedChild.Process.ExitCode, ([string]$detail).Trim()) -ForegroundColor DarkYellow
  }
  Check ($failedChildren.Count -eq 0) `
    '30 concurrent publisher processes succeed'
  $messages = @(Get-ChildItem -LiteralPath $concurrentBox -Filter 'N-*.msg' -File | Sort-Object Name)
  Check ($messages.Count -eq 30) '30 concurrent envelopes publish without loss'
  $bodies = @()
  $valid = $true
  foreach ($messageFile in $messages) {
    if (-not (Read-DuetMessage $messageFile.FullName)) { $valid = $false; continue }
    $bodies += $global:DUET_MESSAGE_BODY
  }
  Check ($valid -and @($bodies | Sort-Object -Unique).Count -eq 30) `
    'concurrent envelopes remain valid and body-unique'
  $expectedNames = 1..30 | ForEach-Object { 'N-{0:D10}.msg' -f $_ }
  Check (($messages.Name -join ',') -eq ($expectedNames -join ',')) `
    'concurrent sequence allocation is gap-free FIFO'
}
finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) `
  -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
