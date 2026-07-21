# Delivery state machine + fair scheduler for duet-deliverd.ps1 (dot-sourced;
# shares $DuetDir, $Sid, $RosterPath, and the helpers/log in duet-deliverd.ps1).
# Phases: READY -> INFLIGHT -> (delivered | ENTER_ONLY -> CLEAR_RETRY | failed).

function Foreign-PayloadNotice([string]$TerminalFile) {
  if (Test-Path -LiteralPath ($TerminalFile + '.noticed')) { return $true }
  $queue = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $TerminalFile))
  $session = Get-DuetFirstLineValue -Path $TerminalFile -Key 'session'; if (-not $session) { $session = 'missing' }
  $id = Get-DuetFirstLineValue -Path $TerminalFile -Key 'id'; if (-not $id) { $id = 'missing' }
  $safeSession = ($session -replace '[^A-Za-z0-9_.-]', ''); if (-not $safeSession) { $safeSession = 'invalid' }
  $safeId = ($id -replace '[^A-Za-z0-9_.-]', ''); if (-not $safeId) { $safeId = 'invalid' }
  $body = "Quarantined a foreign-session payload in local queue $queue (declared session $safeSession, id $safeId). No foreign body was delivered."
  if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { return $false }
  if (Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue 'leader' -Sender 'duet-system' -Recipient 'leader' -Term $global:DUET_CURRENT_TERM -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend $global:DUET_CURRENT_LEADER -Body $body -Dedupe ("foreign-$queue-" + (Split-Path -Leaf $TerminalFile)) -Internal) {
    DLog "queued foreign-payload notice $($global:DUET_ENQUEUED_ID)"
    return (SC-Set $TerminalFile 'noticed' $global:DUET_ENQUEUED_ID)
  }
  return $false
}

function Reconcile-ForeignNotices {
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $DuetDir 'inbox') -Directory -ErrorAction SilentlyContinue)) {
    $q = Join-Path $f.FullName 'quarantine'
    if (-not (Test-Path -LiteralPath $q)) { continue }
    foreach ($m in @(Get-ChildItem -LiteralPath $q -Filter '*.msg' -File -ErrorAction SilentlyContinue)) {
      if (Test-Path -LiteralPath ($m.FullName + '.noticed')) { continue }
      $reason = Get-DuetFileText ($m.FullName + '.reason'); if ($reason) { $reason = $reason.Trim() }
      if (@('foreign-session', 'missing-session', 'foreign-message-id') -contains $reason) {
        if (-not (Foreign-PayloadNotice $m.FullName)) { return $false }
      }
    }
  }
  return $true
}

# After a manual handoff notice reaches the new leader, fan a notice to every
# other live roster member once, then mark the handoff done.
function Reconcile-PromotionFanout {
  $box = Join-Path $DuetDir 'inbox\promotions'
  foreach ($sub in @('delivered', 'quarantine')) {
    $d = Join-Path $box $sub
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($m in @(Get-ChildItem -LiteralPath $d -Filter 'N-*.msg' -File -ErrorAction SilentlyContinue)) {
      if (Test-Path -LiteralPath ($m.FullName + '.fanout_done')) { continue }
      $pterm = Get-DuetFileText ($m.FullName + '.promotion_term'); if ($pterm) { $pterm = $pterm.Trim() }
      if ($null -eq (ConvertFrom-DuetDecimal $pterm)) { continue }
      $reason = Get-DuetFileText ($m.FullName + '.reason'); if ($reason) { $reason = $reason.Trim() }
      if (@('obsolete-promotion', 'foreign-session', 'missing-session', 'foreign-message-id') -contains $reason) { if (-not (SC-Set $m.FullName 'fanout_done' 'skip')) { return $false }; continue }
      if (-not (Read-DuetMessage $m.FullName) -or $global:DUET_MESSAGE_SESSION -ne $Sid `
          -or $global:DUET_MESSAGE_HANDOFF_MODE -ne 'MANUAL' -or $global:DUET_MESSAGE_ORIGIN -ne 'SYSTEM' `
          -or $global:DUET_MESSAGE_TERM -ne $pterm -or $global:DUET_MESSAGE_DEDUPE -ne "promotion-$pterm") { if (-not (SC-Set $m.FullName 'fanout_done' 'invalid')) { return $false }; continue }
      $recipient = $global:DUET_MESSAGE_RECIPIENT
      if (-not (Read-DuetLeaderState -DuetDir $DuetDir) -or $global:DUET_CURRENT_TERM -ne $pterm -or $global:DUET_CURRENT_LEADER -ne $recipient) { if (-not (SC-Set $m.FullName 'fanout_done' 'superseded')) { return $false }; continue }
      foreach ($r in (Import-DuetRoster $RosterPath)) {
        if (-not $r.name -or $r.name -eq $recipient) { continue }
        if (-not (Test-DuetMemberAlive -RosterPath $RosterPath -Name $r.name)) { continue }
        $marker = 'fanout-' + $r.name
        if (Test-Path -LiteralPath ($m.FullName + '.' + $marker)) { continue }
        $body = "Leadership handoff for session ${Sid}: generation $pterm leader is $recipient. Prior leader was $($global:DUET_MESSAGE_PRIOR_LEADER). Read the leader file before continuing work."
        if (-not (Add-DuetMessage -DuetDir $DuetDir -SessionId $Sid -Queue $r.name -Sender 'duet-system' -Recipient $r.name -Term $pterm -Mode 'NORMAL' -Origin 'SYSTEM' -LeaderAtSend $recipient -Body $body -Dedupe "promotion-fanout-$pterm-$($r.name)" -Internal)) { return $false }
        if (-not (SC-Set $m.FullName $marker $global:DUET_ENQUEUED_ID)) { return $false }
      }
      if (-not (SC-Set $m.FullName 'fanout_done' 'complete')) { return $false }
    }
  }
  return $true
}

# Terminalization moves the immutable root BEFORE its durable metadata; repair
# the bounded crash window on restart. (duet_reconcile_terminal_moves)
function Reconcile-TerminalMoves {
  foreach ($box in @(Get-ChildItem -LiteralPath (Join-Path $DuetDir 'inbox') -Directory -ErrorAction SilentlyContinue)) {
    # A quarantine intent persisted before the root was moved -> complete it.
    foreach ($root in @(Get-ChildItem -LiteralPath $box.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' })) {
      if (-not (Test-Path -LiteralPath ($root.FullName + '.quarantine_reason'))) { continue }
      $fr = Get-DuetFileText ($root.FullName + '.quarantine_reason'); if ($fr) { $fr = $fr.Trim() }
      if (-not $fr) { return $false }
      if (-not (Move-Terminal $root.FullName 'quarantine')) { return $false }
      if (-not (SC-Set $global:DUET_TERMINAL_FILE 'reason' $fr)) { return $false }
      if (-not (SC-Remove $global:DUET_TERMINAL_FILE 'quarantine_reason')) { return $false }
    }
    foreach ($directory in @('delivered', 'failed', 'quarantine', 'superseded')) {
      $dpath = Join-Path $box.FullName $directory
      if (-not (Test-Path -LiteralPath $dpath)) { continue }
      foreach ($file in @(Get-ChildItem -LiteralPath $dpath -Filter '*.msg' -File -ErrorAction SilentlyContinue)) {
        $root = Join-Path $box.FullName $file.Name
        foreach ($suffix in @('reason', 'promotion_term', 'quarantine_reason')) {
          $rootSc = $root + '.' + $suffix
          if (-not (Test-Path -LiteralPath $rootSc)) { continue }
          $fileSc = $file.FullName + '.' + $suffix
          if (-not (Test-Path -LiteralPath $fileSc)) { if (-not (Move-DuetFileNoReplace -Source $rootSc -Destination $fileSc)) { return $false } }
          elseif (Test-Path -LiteralPath $fileSc -PathType Leaf) { if (-not (SC-Remove $root $suffix)) { return $false } }
          else { return $false }
        }
        if (Test-Path -LiteralPath ($file.FullName + '.quarantine_reason')) {
          $fr = Get-DuetFileText ($file.FullName + '.quarantine_reason'); if ($fr) { $fr = $fr.Trim() }
          if (-not $fr) { return $false }
          if (-not (SC-Set $file.FullName 'reason' $fr)) { return $false }
          if (-not (SC-Remove $file.FullName 'quarantine_reason')) { return $false }
        }
        if (-not (SC-Clear $root)) { return $false }
      }
    }
  }
  return $true
}

# A MANUAL handoff message is the operator's immutable crash journal. Complete
# only its exact prior/current tuple; never infer a target or react to health.
function Reconcile-PromotionIntents {
  $box = Join-Path $DuetDir 'inbox\promotions'
  if (-not (Test-Path -LiteralPath $box)) { return $true }
  foreach ($m in @(Get-ChildItem -LiteralPath $box -Filter 'N-*.msg' -File -ErrorAction SilentlyContinue)) {
    $file = $m.FullName
    $rawSession = Get-DuetFirstLineValue -Path $file -Key 'session'
    if (-not $rawSession) { if (-not (Quarantine $box $file 'missing-session')) { return $false }; continue }
    if ($rawSession -ne $Sid) { if (-not (Quarantine $box $file 'foreign-session')) { return $false }; continue }
    $rawId = Get-DuetFirstLineValue -Path $file -Key 'id'
    if ($rawId -notlike "m-$Sid-*") { if (-not (Quarantine $box $file 'foreign-message-id')) { return $false }; continue }
    if (-not (Read-DuetMessage $file)) { if (-not (Quarantine $box $file 'invalid-promotion-envelope')) { return $false }; continue }
    $mt = $global:DUET_MESSAGE_TERM
    $recipient = $global:DUET_MESSAGE_RECIPIENT
    $prior = $global:DUET_MESSAGE_PRIOR_TERM
    $priorLeader = $global:DUET_MESSAGE_PRIOR_LEADER
    if ($global:DUET_MESSAGE_HANDOFF_MODE -ne 'MANUAL' -or $global:DUET_MESSAGE_ORIGIN -ne 'SYSTEM' `
        -or $global:DUET_MESSAGE_DEDUPE -ne "promotion-$mt" `
        -or -not (Test-DuetRosterHasName -RosterPath $RosterPath -Name $priorLeader) `
        -or -not (Test-DuetRosterHasName -RosterPath $RosterPath -Name $recipient)) {
      if (-not (Quarantine $box $file 'invalid-promotion-envelope')) { return $false }
      continue
    }
    if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { return $false }
    if ($global:DUET_CURRENT_TERM -eq $prior -and $global:DUET_CURRENT_LEADER -eq $priorLeader) {
      if (Test-DuetUncertainDelivery -DuetDir $DuetDir) { DLog "deferred manual handoff completion behind uncertain"; continue }
      if (-not (Test-Path -LiteralPath ($file + '.promotion_term')) -and -not (SC-Set $file 'promotion_term' $mt)) { return $false }
      if (-not (Write-DuetLeaderState -DuetDir $DuetDir -Term $mt -Leader $recipient)) { return $false }
      DLog "completed recorded manual handoff term $mt -> $recipient"
    }
    elseif ($global:DUET_CURRENT_TERM -eq $mt -and $global:DUET_CURRENT_LEADER -eq $recipient) {
      if (-not (Test-Path -LiteralPath ($file + '.promotion_term')) -and -not (SC-Set $file 'promotion_term' $mt)) { return $false }
    }
    else { DLog "quarantined obsolete manual handoff $(Split-Path -Leaf $file)"; if (-not (Quarantine $box $file 'obsolete-promotion')) { return $false } }
  }
  return $true
}

# --- candidate collection (fair scheduling: one per pane per pass) ------------
function Candidate-Target([string]$Queue, [string]$File) {
  $phase = SC-Get $File 'phase'
  if (@('ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -contains $phase) {
    $bn = SC-Get $File 'target_name'; $bp = SC-Get $File 'target_pane'
    if ($bn -and $bp) { return [pscustomobject]@{ Name = $bn; Key = "pane:$bp" } }
  }
  $name = switch ($Queue) {
    'promotions' { Get-DuetFirstLineValue -Path $File -Key 'recipient' }
    'leader' { if (Read-DuetLeaderState -DuetDir $DuetDir) { $global:DUET_CURRENT_LEADER } else { '' } }
    default { $Queue }
  }
  $pane = ''
  $row = Get-DuetRosterRow -RosterPath $RosterPath -Name $name
  if ($row) { $pane = $row.pane_id }
  if ($pane) { return [pscustomobject]@{ Name = $name; Key = "pane:$pane" } }
  return [pscustomobject]@{ Name = $name; Key = "unresolved:$Queue" }
}

function Collect-Candidates {
  $out = @()
  foreach ($box in @(Get-ChildItem -LiteralPath (Join-Path $DuetDir 'inbox') -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Queue-Next $box.FullName)) { continue }
    $file = $global:DUET_NEXT_MESSAGE
    $queue = $box.Name
    if ($queue -eq 'promotions') {
      $mterm = Get-DuetFirstLineValue -Path $file -Key 'term'
      if (-not (Read-DuetLeaderState -DuetDir $DuetDir) -or $mterm -ne $global:DUET_CURRENT_TERM) { continue }
    }
    $phase = SC-Get $file 'phase'
    $base = Split-Path -Leaf $file
    if (@('ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -contains $phase) { $priority = 0 }
    elseif ($queue -eq 'promotions') { $priority = 1 }
    elseif ($base -like 'I-*') { $priority = 2 }
    else { $priority = 3 }
    if ($priority -eq 3 -and -not (Retry-Due $file)) { continue }
    $order = Get-DuetFirstLineValue -Path $file -Key 'order'; if ($order -notmatch '^[0-9]+$') { $order = '0000000000' }
    $ct = Candidate-Target $queue $file
    $out += [pscustomobject]@{ Priority = $priority; Order = $order; Key = $ct.Key; Box = $box.FullName; File = $file }
  }
  return $out
}

# =============================================================================
# Process ONE message (at most one pane operation). The heart of delivery.
# =============================================================================
function Process-One([string]$Box, [string]$File) {
  if (-not (Test-Path -LiteralPath $File)) { return $true }
  if (-not (Retry-Due $File)) { return $true }
  $queue = Split-Path -Leaf $Box

  if (-not (Validate-Envelope $File)) {
    $reason = $global:DUET_FENCE_REASON
    DLog "foreign envelope $(Split-Path -Leaf $File) -> quarantine ($reason)"
    if (-not (Quarantine $Box $File $reason)) { return $false }
    if (-not (Foreign-PayloadNotice $global:DUET_TERMINAL_FILE)) { return $false }
    return $true
  }
  if (-not (Read-DuetMessage $File)) {
    DLog "invalid message $(Split-Path -Leaf $File) -> failed"
    if (-not (Move-Terminal $File 'failed')) { return $false }
    return (SC-Set $global:DUET_TERMINAL_FILE 'noticed' 'invalid-message')
  }

  # Physical-queue routing capability.
  $symbolic = $false
  switch ($queue) {
    'leader' { if ($global:DUET_MESSAGE_RECIPIENT -ne 'leader') { return (Finish-Quarantine $Box $File 'recipient-queue-mismatch') }; $symbolic = $true }
    'promotions' { if ($global:DUET_MESSAGE_ORIGIN -ne 'SYSTEM' -or $global:DUET_MESSAGE_HANDOFF_MODE -ne 'MANUAL' -or $global:DUET_MESSAGE_RECIPIENT -eq 'leader') { return (Finish-Quarantine $Box $File 'invalid-promotion-envelope') }; $symbolic = $true }
    default { if ($global:DUET_MESSAGE_RECIPIENT -ne $queue) { return (Finish-Quarantine $Box $File 'recipient-queue-mismatch') } }
  }

  $phase = SC-Get $File 'phase'
  if ($phase -eq '' -and (Test-Path -LiteralPath ($File + '.phase'))) { return (Finish-Quarantine $Box $File 'empty-delivery-phase') }
  if ($phase -ne '' -and @('READY', 'ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -notcontains $phase) { return (Finish-Quarantine $Box $File "invalid-delivery-phase-$phase") }

  if (-not (Read-DuetLeaderState -DuetDir $DuetDir)) { return $false }
  $curTerm = $global:DUET_CURRENT_TERM; $curLeader = $global:DUET_CURRENT_LEADER

  # Term fences.
  if ($global:DUET_MESSAGE_ORIGIN -eq 'LEADER' -and ($global:DUET_MESSAGE_TERM -ne $curTerm -or $global:DUET_MESSAGE_SENDER -ne $curLeader -or $global:DUET_MESSAGE_LEADER_AT_SEND -ne $curLeader)) {
    if (@('ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -contains $phase) {
      DLog "poison-fenced stale uncertain $($global:DUET_MESSAGE_ID)"
      if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 8)))) { return $false }; return $true
    }
    return (Finish-Quarantine $Box $File 'stale-leader-term')
  }
  if ($queue -eq 'promotions') {
    if ($global:DUET_MESSAGE_TERM -ne $curTerm -or $global:DUET_MESSAGE_RECIPIENT -ne $curLeader -or $global:DUET_MESSAGE_DEDUPE -ne "promotion-$($global:DUET_MESSAGE_TERM)") {
      return (Finish-Quarantine $Box $File 'obsolete-promotion')
    }
  }
  elseif ($global:DUET_MESSAGE_ORIGIN -eq 'SYSTEM' -and $global:DUET_MESSAGE_DEDUPE -like 'promotion-fanout-*') {
    if ($global:DUET_MESSAGE_TERM -ne $curTerm -or $global:DUET_MESSAGE_LEADER_AT_SEND -ne $curLeader) { return (Finish-Quarantine $Box $File 'stale-promotion-fanout') }
  }

  $payload = Build-DuetPayload
  $interrupt = ($global:DUET_MESSAGE_MODE -eq 'INTERRUPT')

  $targetName = if ($queue -eq 'promotions') { $global:DUET_MESSAGE_RECIPIENT } elseif ($global:DUET_MESSAGE_RECIPIENT -eq 'leader') { $curLeader } else { $global:DUET_MESSAGE_RECIPIENT }
  $targetTerm = $curTerm

  # Target binding (persisted before INFLIGHT so a crash is recoverable). Every
  # durable write is checked: a failed write MUST halt the pass, never advance.
  $bn = SC-Get $File 'target_name'; $bp = SC-Get $File 'target_pane'; $bt = SC-Get $File 'target_term'
  $bindingComplete = ($bn -and $bp -and $bt)
  if (($bn -or $bp -or $bt) -and -not $bindingComplete) {
    if ($phase -eq 'CLEAR_RETRY') {
      # A causally observed marker may still own the pane: poison-fence, do not quarantine.
      DLog "poison-fenced CLEAR_RETRY with incomplete target binding for $($global:DUET_MESSAGE_ID)"
      if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 8)))) { return $false }
      return $true
    }
    elseif ($phase -eq 'ENTER_ONLY') { return (Finish-Quarantine $Box $File 'incomplete-target-binding') }
    elseif ($phase -eq 'INFLIGHT') { if (-not (SC-Set $File 'phase' 'READY') -or -not (Clear-TargetBinding $File)) { return $false }; $phase = 'READY'; $bn = ''; $bp = ''; $bt = '' }
    else { if (-not (Clear-TargetBinding $File)) { return $false }; $bn = ''; $bp = ''; $bt = ''; $bindingComplete = $false }
  }
  if ($bindingComplete -and @('ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -notcontains $phase) {
    if (-not (Clear-TargetBinding $File)) { return $false }; $bn = ''; $bp = ''; $bt = ''; $bindingComplete = $false
  }
  $row = Get-DuetRosterRow -RosterPath $RosterPath -Name $targetName
  $targetPane = if ($row) { $row.pane_id } else { '' }
  if ($bindingComplete) {
    if ($bn -ne $targetName -or $bp -ne $targetPane -or ($symbolic -and $bt -ne $targetTerm)) {
      if (@('ENTER_ONLY', 'INFLIGHT', 'CLEAR_RETRY') -contains $phase) {
        DLog "poison-fenced target change for $($global:DUET_MESSAGE_ID)"
        if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 8)))) { return $false }
        return $true
      }
      return (Finish-Quarantine $Box $File 'target-changed-after-possible-landing')
    }
    $targetName = $bn; $targetPane = $bp; $targetTerm = $bt
    $row = Get-DuetRosterRow -RosterPath $RosterPath -Name $targetName
  }

  $harness = if ($row) { $row.harness } else { '' }
  $panePid = if ($row) { $row.pane_pid } else { '' }
  $memberRes = if ($targetName -and $row) { Get-DuetMemberResolution -RosterPath $RosterPath -Name $targetName } else { [pscustomobject]@{ Known = $true; Alive = $false; Target = $null } }

  $attemptText = SC-Get $File 'tries'
  if (-not $attemptText) { [uint64]$attempts = 0 }
  else {
    $attemptNumber = ConvertFrom-DuetDecimal $attemptText
    if ($null -eq $attemptNumber) { return (Finish-Quarantine $Box $File 'invalid-delivery-attempt-count') }
    [uint64]$attempts = $attemptNumber
  }
  if ($attempts -ge 9999999999) { return (Finish-Quarantine $Box $File 'delivery-attempt-count-exhausted') }
  [uint64]$max = $DUET_DELIVERY_MAX_ATTEMPTS

  $enterToken = SC-Get $File 'enter_token'
  $landingObs = SC-Get $File 'landing_observed'
  $result = $null
  $continuation = $false; $clearRecovery = $false

  if (-not $targetPane -or -not ($memberRes.Known -and $memberRes.Alive)) {
    if ($memberRes.Known) { $result = [pscustomobject]@{ Code = $global:DUET_SEND_DEAD } }
    else { DLog "target $targetName unresolved (UNKNOWN); deferring $($global:DUET_MESSAGE_ID)"; if (-not (Set-Backoff $File ([Math]::Max(1, $attempts)))) { return $false }; return $true }
  }
  elseif ($phase -eq 'CLEAR_RETRY') {
    $clearRecovery = $true
    if ($harness -ne 'codex' -or $landingObs -ne 'marker' -or -not $enterToken) { $result = [pscustomobject]@{ Code = $global:DUET_SEND_LANDED_UNVERIFIED } }
    else { $result = Clear-DuetRefusedComposer -PaneId $targetPane -PanePid $panePid -MarkerToken $enterToken }
  }
  elseif ($phase -eq 'ENTER_ONLY' -or ($phase -eq 'INFLIGHT' -and $bindingComplete)) {
    $continuation = $true
    $result = Send-DuetEnterOnly -PaneId $targetPane -PanePid $panePid -Payload $payload -MarkerToken $enterToken -Harness $harness
    if ($result.EnterToken) { if (-not (SC-Set $File 'enter_token' $result.EnterToken)) { return $false }; $enterToken = $result.EnterToken }
    if ($result.LandingObserved) { if (-not (SC-Set $File 'landing_observed' $result.LandingObserved)) { return $false }; $landingObs = $result.LandingObserved }
  }
  else {
    if (-not $bindingComplete) {
      if (-not (SC-Set $File 'target_name' $targetName) -or -not (SC-Set $File 'target_pane' $targetPane) -or -not (SC-Set $File 'target_term' $targetTerm)) { return $false }
    }
    if (-not (SC-Remove $File 'enter_token') -or -not (SC-Remove $File 'landing_observed')) { return $false }
    if (-not (SC-Set $File 'phase' 'INFLIGHT')) { DLog "could not persist INFLIGHT for $($global:DUET_MESSAGE_ID); halting"; return $false }
    $result = Send-DuetVerified -PaneId $targetPane -PanePid $panePid -Payload $payload -Interrupt $interrupt -Harness $harness
    if ($result.EnterToken) { if (-not (SC-Set $File 'enter_token' $result.EnterToken)) { return $false }; $enterToken = $result.EnterToken }
    if ($result.LandingObserved) { if (-not (SC-Set $File 'landing_observed' $result.LandingObserved)) { return $false }; $landingObs = $result.LandingObserved }
  }
  $rc = [int]$result.Code

  # CLEAR_RETRY outcome handling.
  if ($clearRecovery) {
    if ($rc -eq 0) {
      if (-not $result.ComposerClear) { if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 8)))) { return $false }; return $true }
      DLog "cleared refused Codex composer for $($global:DUET_MESSAGE_ID); requeueing stable id"
      if (-not $symbolic -and $attempts -ge $max) {
        if (-not (Move-Terminal $File 'failed')) { return $false }
        return (Delivery-FailureNotice $targetName $global:DUET_MESSAGE_ID 'COMPOSER_REFUSED' $global:DUET_TERMINAL_FILE)
      }
      if (-not (SC-Set $File 'phase' 'READY')) { return $false }
      if (-not (SC-Remove $File 'enter_token') -or -not (SC-Remove $File 'landing_observed') -or -not (SC-Remove $File 'retry_at')) { return $false }
      if (-not (Set-Backoff $File ([Math]::Max(1, $attempts)))) { return $false }
      if (-not (Clear-TargetBinding $File)) { return $false }
      return $true
    }
    elseif ($rc -eq $global:DUET_SEND_LANDED_UNVERIFIED) { if (-not (SC-Set $File 'phase' 'CLEAR_RETRY')) { return $false }; if (-not (Set-Backoff $File ([Math]::Max(1, $attempts)))) { return $false }; return $true }
    elseif ($rc -ne $global:DUET_SEND_DEAD) { if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 8)))) { return $false }; return $true }
    # DEAD falls through to common handling.
  }

  if ($continuation -and $rc -ne 0 -and $rc -ne $global:DUET_SEND_LANDED_UNVERIFIED -and $rc -ne $global:DUET_SEND_COMPOSER_REFUSED) {
    return (Finish-Quarantine $Box $File "enter-only-outcome-$rc")
  }

  switch ($rc) {
    0 {
      DLog "delivered $($global:DUET_MESSAGE_ID) -> $targetName"
      if (-not (Move-Terminal $File 'delivered')) { return $false }
      if ($global:DUET_MESSAGE_MODE -eq 'INTERRUPT') { if (-not (Complete-InterruptSupersede $Box $global:DUET_TERMINAL_FILE)) { return $false } }
      return $true
    }
    { $_ -eq $global:DUET_SEND_LANDED_UNVERIFIED } {
      if ($continuation) {
        if (-not (SC-Set $File 'phase' 'ENTER_ONLY')) { return $false }
        $clearable = ($landingObs -eq 'probe') -or ($enterToken)
        if ($result.ComposerClear -and $clearable) { return (Finish-Quarantine $Box $File 'enter-only-unverified') }
        $attempts++; if (-not (SC-Set $File 'tries' ([string]$attempts))) { return $false }; if (-not (Set-Backoff $File $attempts)) { return $false }; return $true
      }
      DLog "enter-only continuation scheduled for $($global:DUET_MESSAGE_ID)"
      if (-not (SC-Set $File 'phase' 'ENTER_ONLY')) { return $false }; if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 1)))) { return $false }; return $true
    }
    { $_ -eq $global:DUET_SEND_COMPOSER_REFUSED } {
      if ($harness -ne 'codex' -or $landingObs -ne 'marker' -or -not $enterToken) {
        DLog "refused-composer lacked Codex marker for $($global:DUET_MESSAGE_ID)"
        if (-not (SC-Set $File 'phase' 'ENTER_ONLY')) { return $false }; if (-not (SC-Set $File 'retry_at' ([string]([long](Get-DuetUnixTime) + 8)))) { return $false }; return $true
      }
      $attempts++
      if (-not (SC-Set $File 'tries' ([string]$attempts))) { return $false }
      if (-not (SC-Set $File 'phase' 'CLEAR_RETRY')) { return $false }
      if (-not (Set-Backoff $File $attempts)) { return $false }
      DLog "Codex composer refused Enter for $($global:DUET_MESSAGE_ID); clear recovery scheduled"; return $true
    }
    { $_ -eq $global:DUET_SEND_NOT_LANDED } {
      $attempts++
      if (-not $symbolic -and $attempts -ge $max) {
        DLog "failed $($global:DUET_MESSAGE_ID) after $attempts NOT_LANDED"
        if (-not (Move-Terminal $File 'failed')) { return $false }
        return (Delivery-FailureNotice $targetName $global:DUET_MESSAGE_ID 'NOT_LANDED' $global:DUET_TERMINAL_FILE)
      }
      if (-not (SC-Set $File 'phase' 'READY')) { return $false }; if (-not (SC-Set $File 'tries' ([string]$attempts))) { return $false }; if (-not (Set-Backoff $File $attempts)) { return $false }; if (-not (Clear-TargetBinding $File)) { return $false }; return $true
    }
    { $_ -eq $global:DUET_SEND_DEAD } {
      $attempts++
      if (-not $symbolic -and $attempts -ge $max) {
        DLog "failed $($global:DUET_MESSAGE_ID): worker $targetName dead"
        if (-not (Move-Terminal $File 'failed')) { return $false }
        return (Delivery-FailureNotice $targetName $global:DUET_MESSAGE_ID 'DEAD' $global:DUET_TERMINAL_FILE)
      }
      if (-not (SC-Set $File 'phase' 'READY')) { return $false }; if (-not (SC-Set $File 'tries' ([string]$attempts))) { return $false }; if (-not (Set-Backoff $File $attempts)) { return $false }; if (-not (Clear-TargetBinding $File)) { return $false }; return $true
    }
    default { return (Finish-Quarantine $Box $File "unexpected-verifier-outcome-$rc") }
  }
}

function Finish-Quarantine([string]$Box, [string]$File, [string]$Reason) {
  if (-not (Quarantine $Box $File $Reason)) { return $false }
  if ($global:DUET_MESSAGE_MODE -eq 'INTERRUPT') { if (-not (Complete-InterruptSupersede $Box $global:DUET_TERMINAL_FILE)) { return $false } }
  return $true
}
