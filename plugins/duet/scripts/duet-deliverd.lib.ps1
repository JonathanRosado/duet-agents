# Delivery-daemon function library (dot-sourced by duet-deliverd.ps1 and by the
# daemon tests). Reads $DuetDir, $Sid, $RosterPath, $DUET_DELIVERY_MAX_ATTEMPTS
# from the dot-sourcing scope. All pane injection lives in the verified-send FSM
# (duet-common.ps1); this file owns the queue state machine, scheduler, and
# crash-window reconciliation.

function DLog([string]$Msg) {
  try { [System.IO.File]::AppendAllText((Join-Path $DuetDir 'deliverd.log'), ("[{0}] {1}`n" -f (Get-DuetUtcStamp), $Msg), (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function SC-Get([string]$File, [string]$Suffix) { $v = Get-DuetFileText ($File + '.' + $Suffix); if ($v) { return $v.Trim() } return '' }
function SC-Set([string]$File, [string]$Suffix, [string]$Value) { return (Write-DuetAtomicMultiline -Path ($File + '.' + $Suffix) -Value $Value) }
function SC-Remove([string]$File, [string]$Suffix) {
  $path = $File + '.' + $Suffix
  if (-not (Test-Path -LiteralPath $path)) { return $true }
  try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { return $false }
  return (-not (Test-Path -LiteralPath $path))
}
function SC-Clear([string]$File) {
  $ok = $true
  foreach ($s in @('phase', 'tries', 'retry_at', 'enter_token', 'landing_observed', 'target_pane', 'target_name', 'target_term')) {
    if (-not (SC-Remove $File $s)) { $ok = $false }
  }
  return $ok
}
function Clear-TargetBinding([string]$File) {
  $ok = $true
  foreach ($s in @('target_pane', 'target_name', 'target_term')) { if (-not (SC-Remove $File $s)) { $ok = $false } }
  return $ok
}
function MsgSeq([string]$File) { $b = Split-Path -Leaf $File; $b = $b -replace '^[NI]-', ''; return ($b -replace '\.msg$', '') }

function Move-Terminal([string]$File, [string]$Directory) {
  $box = Split-Path -Parent $File
  $dest = Join-Path (Join-Path $box $Directory) (Split-Path -Leaf $File)
  # No-replace: a terminal record must never overwrite an existing one.
  if (-not (Move-DuetFileNoReplace -Source $File -Destination $dest)) { DLog "terminal move failed/collision for $(Split-Path -Leaf $File) in $Directory"; return $false }
  foreach ($s in @('reason', 'promotion_term', 'quarantine_reason')) {
    $src = $File + '.' + $s
    if (Test-Path -LiteralPath $src) {
      if (-not (Move-DuetFileNoReplace -Source $src -Destination ($dest + '.' + $s))) { return $false }
    }
  }
  if (-not (SC-Clear $File)) { return $false }
  $global:DUET_TERMINAL_FILE = $dest
  return $true
}

function Set-Backoff([string]$File, [uint64]$Attempts) {
  $base = 1
  if ($Attempts -ge 4) { $delay = $base * 8 } else { $delay = $base * [Math]::Pow(2, [Math]::Max(0, $Attempts - 1)) }
  return (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + [long]$delay)))
}
function Retry-Due([string]$File) {
  $ra = SC-Get $File 'retry_at'
  if (-not $ra) { return $true }
  $parsed = ConvertFrom-DuetDecimal $ra ([uint64]::MaxValue)
  if ($null -eq $parsed) { return $false }
  return ([uint64](Get-DuetUnixTime) -ge $parsed)
}

function Quarantine([string]$Box, [string]$File, [string]$Reason) {
  DLog "quarantined $(Split-Path -Leaf $File): $Reason"
  if (-not (SC-Set $File 'quarantine_reason' $Reason)) { return $false }
  if (-not (Move-Terminal $File 'quarantine')) { return $false }
  if (-not (SC-Set $global:DUET_TERMINAL_FILE 'reason' $Reason)) { return $false }
  return (SC-Remove $global:DUET_TERMINAL_FILE 'quarantine_reason')
}

function Queue-Next([string]$Box) {
  $global:DUET_NEXT_MESSAGE = ''
  $files = @(Get-ChildItem -LiteralPath $Box -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' })
  $best = ''
  foreach ($f in $files) {
    $phase = SC-Get $f.FullName 'phase'
    if (@('ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -notcontains $phase) { continue }
    $seq = MsgSeq $f.FullName
    if (-not $best -or $seq -lt $best) { $global:DUET_NEXT_MESSAGE = $f.FullName; $best = $seq }
  }
  if ($global:DUET_NEXT_MESSAGE) { return $true }
  $interrupts = @($files | Where-Object { $_.Name -match '^I-' } | Sort-Object Name)
  if ($interrupts.Count -gt 0) { $global:DUET_NEXT_MESSAGE = $interrupts[-1].FullName; return $true }
  $normals = @($files | Where-Object { $_.Name -match '^N-' } | Sort-Object Name)
  if ($normals.Count -gt 0) { $global:DUET_NEXT_MESSAGE = $normals[0].FullName; return $true }
  return $false
}

function Supersede-Before([string]$Box, [string]$WinningSeq) {
  $winner = ConvertFrom-DuetDecimal $WinningSeq -AllowLeadingZeros
  if ($null -eq $winner) { return $false }
  foreach ($f in @(Get-ChildItem -LiteralPath $Box -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' })) {
    $candidate = ConvertFrom-DuetDecimal (MsgSeq $f.FullName) -AllowLeadingZeros
    if ($null -eq $candidate) { return $false }
    if ($candidate -lt $winner) {
      DLog "superseded $($f.Name) by interrupt sequence $WinningSeq"
      if (-not (Move-Terminal $f.FullName 'superseded')) { return $false }
    }
  }
  return $true
}
function Complete-InterruptSupersede([string]$Box, [string]$TerminalFile) {
  $seq = MsgSeq $TerminalFile
  if (-not (Supersede-Before $Box $seq)) { return $false }
  return (SC-Set $TerminalFile 'supersede_done' $seq)
}

function Delivery-FailureNotice([string]$FailedName, [string]$Id, [string]$Outcome, [string]$FailedFile) {
  if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { return $false }
  $body = "Delivery to worker $FailedName failed permanently ($Outcome) for message $Id. Reassign its work if needed."
  if (Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue 'leader' -Sender 'duet-system' -Recipient 'leader' -Term $global:DUET_CURRENT_TERM -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend $global:DUET_CURRENT_LEADER -Body $body -Dedupe "failure-$Id" -Internal) {
    DLog "queued leader notice $($global:DUET_ENQUEUED_ID) for failed delivery $Id"
    return (SC-Set $FailedFile 'noticed' $global:DUET_ENQUEUED_ID)
  }
  DLog "could not queue leader notice for failed delivery $Id"
  return $false
}

function Validate-Envelope([string]$File) {
  $rawSession = Get-DuetFirstLineValue -Path $File -Key 'session'
  $rawId = Get-DuetFirstLineValue -Path $File -Key 'id'
  if (-not $rawSession) { $global:DUET_FENCE_REASON = 'missing-session'; return $false }
  if ($rawSession -ne $Sid) { $global:DUET_FENCE_REASON = 'foreign-session'; return $false }
  if ($rawId -notlike "m-$Sid-*") { $global:DUET_FENCE_REASON = 'foreign-message-id'; return $false }
  $global:DUET_FENCE_REASON = ''
  return $true
}

function Reconcile-FailureNotices {
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $DuetDir 'inbox') -Directory -ErrorAction SilentlyContinue)) {
    if ($f.Name -eq 'leader' -or $f.Name -eq 'promotions') { continue }
    $failedDir = Join-Path $f.FullName 'failed'
    if (-not (Test-Path -LiteralPath $failedDir)) { continue }
    foreach ($m in @(Get-ChildItem -LiteralPath $failedDir -Filter '*.msg' -File -ErrorAction SilentlyContinue)) {
      if (Test-Path -LiteralPath ($m.FullName + '.noticed')) { continue }
      if (-not (Read-DuetMessage $m.FullName)) { if (-not (SC-Set $m.FullName 'noticed' 'invalid-message')) { return $false }; continue }
      if ($global:DUET_MESSAGE_RECIPIENT -eq 'leader') { continue }
      if (-not (Delivery-FailureNotice $global:DUET_MESSAGE_RECIPIENT $global:DUET_MESSAGE_ID 'UNKNOWN' $m.FullName)) { return $false }
    }
  }
  return $true
}

function Reconcile-InterruptSupersedes {
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $DuetDir 'inbox') -Directory -ErrorAction SilentlyContinue)) {
    foreach ($sub in @('delivered', 'quarantine')) {
      $d = Join-Path $f.FullName $sub
      if (-not (Test-Path -LiteralPath $d)) { continue }
      foreach ($m in @(Get-ChildItem -LiteralPath $d -Filter 'I-*.msg' -File -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath ($m.FullName + '.supersede_done')) { continue }
        if (-not (Complete-InterruptSupersede $f.FullName $m.FullName)) { return $false }
      }
    }
  }
  return $true
}

. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-deliverd.process.ps1')

function Deliverd-Pass {
  $null = @(Import-DuetRoster $RosterPath)
  if (-not $global:DUET_ROSTER_VALID) { DLog 'roster validation failed; halting'; return $false }
  if (-not (Reconcile-TerminalMoves)) { return $false }
  if (-not (Reconcile-PromotionIntents)) { return $false }
  if (-not (Reconcile-InterruptSupersedes)) { return $false }
  if (-not (Reconcile-FailureNotices)) { return $false }
  if (-not (Reconcile-ForeignNotices)) { return $false }
  if (-not (Reconcile-PromotionFanout)) { return $false }
  $candidates = Collect-Candidates
  $seen = @{}
  foreach ($c in ($candidates | Sort-Object @{E = { $_.Priority } }, @{E = { $_.Order } })) {
    if ($seen.ContainsKey($c.Key)) { continue }
    $seen[$c.Key] = $true
    if (-not (Process-One $c.Box $c.File)) { return $false }
  }
  if (-not (Reconcile-PromotionFanout)) { return $false }
  return $true
}
