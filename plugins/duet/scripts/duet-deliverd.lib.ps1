# In-process delivery core for one Windows/psmux v4 session.
#
# No state here is restartable. If the daemon exits unexpectedly, the session
# becomes unhealthy and must be discarded. Recipient failures remain scoped to
# that recipient so the rest of the mesh keeps moving.

$script:DuetNotLanded = @{}
$script:DuetProcessAttempted = $false
$script:DuetProcessTargetName = ''
$script:DuetProcessTargetPane = ''
$script:DuetTerminalFile = ''

function Write-DuetDeliverdLog {
  param([string]$Message)
  $line = '[{0}] {1}{2}' -f (Get-DuetUtcStamp), $Message, [Environment]::NewLine
  Write-DuetUtf8NoBom -Path (Join-Path $global:DUET_DIR 'deliverd.log') -Value $line -Append
}

function Set-DuetSessionUnhealthy {
  param([string]$Reason)
  $path = Join-Path $global:DUET_DIR '.unhealthy'
  if (-not (Test-Path -LiteralPath $path)) {
    [void](Write-DuetAtomicMultiline -Path $path -Value ("{0}`t{1}" -f (Get-DuetUtcStamp), $Reason))
  }
  Write-DuetDeliverdLog "UNHEALTHY: $Reason"
  Write-DuetError "duet: session unhealthy: $Reason"
}

function Get-DuetMessageSequence {
  param([string]$File)
  $base = Split-Path -Leaf $File
  if ($base -notmatch '^[NI]-([0-9]+)\.msg$') { return $null }
  $parsed = ConvertFrom-DuetDecimal -Value $Matches[1] -AllowLeadingZeros
  if ($null -eq $parsed) { return $null }
  return ('{0:D10}' -f $parsed)
}

# Interrupts are urgent, but FIFO is preserved within each mode. Older normal
# work remains queued after an interrupt.
function Get-DuetQueueNext {
  param([string]$Box)
  foreach ($prefix in @('I', 'N')) {
    $selected = $null
    $selectedSequence = ''
    foreach ($file in @(Get-ChildItem -LiteralPath $Box -Filter "$prefix-*.msg" -File -ErrorAction SilentlyContinue)) {
      if (Test-DuetReparsePoint $file.FullName) { return $file }
      $sequence = Get-DuetMessageSequence $file.FullName
      if ($null -eq $sequence) { return $file }
      if ($null -eq $selected -or [string]::CompareOrdinal($sequence, $selectedSequence) -lt 0) {
        $selected = $file
        $selectedSequence = $sequence
      }
    }
    if ($null -ne $selected) { return $selected }
  }
  return $null
}

function Test-DuetMessageIdDelivered {
  param([string]$Box, [string]$Id)
  $delivered = Join-Path $Box 'delivered'
  if (-not (Test-Path -LiteralPath $delivered -PathType Container)) { return $false }
  foreach ($file in @(Get-ChildItem -LiteralPath $delivered -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^[NI]-[0-9]+\.msg$' })) {
    if ((Get-DuetFirstLineValue -Path $file.FullName -Key 'id') -eq $Id) { return $true }
  }
  return $false
}

function Move-DuetDelivered {
  param([string]$File)
  $destinationDir = Join-Path (Split-Path -Parent $File) 'delivered'
  if (-not (Test-Path -LiteralPath $destinationDir)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
  }
  $destination = Join-Path $destinationDir (Split-Path -Leaf $File)
  if (-not (Move-DuetFileNoReplace -Source $File -Destination $destination)) { return $false }
  $script:DuetTerminalFile = $destination
  return $true
}

function Move-DuetRejected {
  param([string]$File, [string]$Reason)
  $rejected = Join-Path (Split-Path -Parent $File) 'rejected'
  if (-not (Test-Path -LiteralPath $rejected)) {
    New-Item -ItemType Directory -Path $rejected -Force | Out-Null
  }
  $destination = Join-Path $rejected (Split-Path -Leaf $File)
  if (Test-Path -LiteralPath $destination) {
    $destination += '.duplicate-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N')
  }
  if (-not (Move-DuetFileNoReplace -Source $File -Destination $destination)) { return $false }
  $reasonValue = "{0}`t{1}" -f (Get-DuetUtcStamp), $Reason
  if (-not (Write-DuetAtomicMultiline -Path ($destination + '.reason') -Value $reasonValue)) {
    Write-DuetDeliverdLog "REJECTED $(Split-Path -Leaf $File): $Reason (reason sidecar unavailable)"
    return $true
  }
  Write-DuetDeliverdLog "REJECTED $(Split-Path -Leaf $File): $Reason"
  Write-DuetError "duet: rejected $(Split-Path -Leaf $File): $Reason"
  return $true
}

function Set-DuetRecipientDead {
  param([string]$Name, [string]$Reason)
  $dir = Join-Path $global:DUET_DIR 'dead'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (-not (Write-DuetAtomicMultiline -Path (Join-Path $dir $Name) -Value ("{0}`t{1}" -f (Get-DuetUtcStamp), $Reason))) {
    return $false
  }
  Write-DuetDeliverdLog "DEAD recipient ${Name}: $Reason"
  Write-DuetError "duet: recipient $Name is dead: $Reason"
  return $true
}

function Set-DuetRecipientBlocked {
  param([string]$Name, [string]$Reason)
  $dir = Join-Path $global:DUET_DIR 'blocked'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (-not (Write-DuetAtomicMultiline -Path (Join-Path $dir $Name) -Value ("{0}`t{1}" -f (Get-DuetUtcStamp), $Reason))) {
    return $false
  }
  Write-DuetDeliverdLog "BLOCKED recipient ${Name}: $Reason"
  Write-DuetError "duet: recipient $Name blocked: $Reason"
  return $true
}

function Set-DuetObservedHead {
  param([string]$Name, [string]$Head)
  if (-not $script:DuetNotLanded.ContainsKey($Name) -or
      $script:DuetNotLanded[$Name].Head -ne $Head) {
    $script:DuetNotLanded[$Name] = [pscustomobject]@{ Head = $Head; Count = [uint64]0 }
  }
}

function Reset-DuetNotLanded {
  param([string]$Name)
  if ($script:DuetNotLanded.ContainsKey($Name)) { $script:DuetNotLanded[$Name].Count = [uint64]0 }
}

function Add-DuetNotLanded {
  param([string]$Name)
  $limit = ConvertFrom-DuetDecimal -Value $env:DUET_NOT_LANDED_LIMIT
  if ($null -eq $limit -or $limit -eq 0) { $limit = [uint64]30 }
  if (-not $script:DuetNotLanded.ContainsKey($Name)) {
    $script:DuetNotLanded[$Name] = [pscustomobject]@{ Head = ''; Count = [uint64]0 }
  }
  $slot = $script:DuetNotLanded[$Name]
  $slot.Count = [uint64]$slot.Count + 1
  return [pscustomobject]@{ Count = $slot.Count; Limit = $limit }
}

# Process at most one physical queue head. A definitely-not-landed head gets a
# bounded number of passes; ambiguity after paste blocks immediately and is
# never retried or repasted.
function Invoke-DuetProcessOne {
  param([string]$Box, [string]$ExactFile = '')
  $script:DuetProcessAttempted = $false
  $script:DuetProcessTargetName = ''
  $script:DuetProcessTargetPane = ''
  $file = if ($ExactFile) {
    if (-not (Test-Path -LiteralPath $ExactFile -PathType Leaf)) { return $true }
    $ExactFile
  } else {
    $next = Get-DuetQueueNext -Box $Box
    if ($null -eq $next) { return $true }
    $next.FullName
  }
  $boxCanonical = Get-DuetCanonicalPath $Box
  $parentCanonical = Get-DuetCanonicalPath (Split-Path -Parent $file)
  if (-not $boxCanonical -or -not $parentCanonical -or
      -not $boxCanonical.Equals($parentCanonical, [StringComparison]::OrdinalIgnoreCase)) {
    return $false
  }

  $queue = Split-Path -Leaf $Box
  Set-DuetObservedHead -Name $queue -Head $file
  if ((Test-DuetReparsePoint $file) -or $null -eq (Get-DuetMessageSequence $file)) {
    if (-not (Move-DuetRejected -File $file -Reason "invalid message filename in inbox/$queue")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason "could not reject $(Split-Path -Leaf $file)")
    }
    return $true
  }
  if (-not (Read-DuetMessage $file)) {
    if (-not (Move-DuetRejected -File $file -Reason "invalid message envelope in inbox/$queue")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason "could not reject $(Split-Path -Leaf $file)")
    }
    return $true
  }
  if ($global:DUET_MESSAGE_SESSION -ne $global:DUET_SESSION_ID) {
    if (-not (Move-DuetRejected -File $file -Reason "message $($global:DUET_MESSAGE_ID) names session $($global:DUET_MESSAGE_SESSION)")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason 'could not reject foreign message')
    }
    return $true
  }

  $rosterPath = Join-Path $global:DUET_DIR 'roster.tsv'
  if (-not (Test-DuetRosterHasName -RosterPath $rosterPath -Name $queue)) {
    Set-DuetSessionUnhealthy "queue inbox/$queue is not a roster recipient"
    return $false
  }
  if (-not (Test-DuetRosterHasName -RosterPath $rosterPath -Name $global:DUET_MESSAGE_SENDER)) {
    if (-not (Move-DuetRejected -File $file -Reason "message $($global:DUET_MESSAGE_ID) names nonmember sender $($global:DUET_MESSAGE_SENDER)")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason 'could not reject nonmember message')
    }
    return $true
  }
  if ($global:DUET_MESSAGE_RECIPIENT -ne $queue -and $global:DUET_MESSAGE_RECIPIENT -ne 'all') {
    if (-not (Move-DuetRejected -File $file -Reason "message $($global:DUET_MESSAGE_ID) redirects inbox/$queue")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason 'could not reject redirected message')
    }
    return $true
  }
  $idPrefix = "m-$($global:DUET_SESSION_ID)-$queue-"
  $idSequence = if ($global:DUET_MESSAGE_ID.StartsWith($idPrefix)) {
    $global:DUET_MESSAGE_ID.Substring($idPrefix.Length)
  } else { '' }
  if ($idSequence.Length -ne 10 -or
      $null -eq (ConvertFrom-DuetDecimal -Value $idSequence -AllowLeadingZeros)) {
    if (-not (Move-DuetRejected -File $file -Reason "message id $($global:DUET_MESSAGE_ID) is invalid for inbox/$queue")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason 'could not reject mismatched message id')
    }
    return $true
  }

  if (Test-DuetMessageIdDelivered -Box $Box -Id $global:DUET_MESSAGE_ID) {
    Write-DuetDeliverdLog "suppressed duplicate $($global:DUET_MESSAGE_ID) -> $queue"
    if (-not (Move-DuetDelivered -File $file)) {
      Set-DuetSessionUnhealthy "could not archive duplicate $($global:DUET_MESSAGE_ID)"
      return $false
    }
    return $true
  }

  $row = Get-DuetRosterRow -RosterPath $rosterPath -Name $queue
  if (-not $global:DUET_ROSTER_VALID -or -not $row) {
    Set-DuetSessionUnhealthy "recipient $queue vanished from the roster"
    return $false
  }
  $script:DuetProcessTargetName = $queue
  $script:DuetProcessTargetPane = $row.pane_id
  $resolution = Resolve-DuetPaneResolution -PaneId $row.pane_id -PanePid $row.pane_pid
  if ($resolution.Known -and -not $resolution.Alive) {
    $reason = 'pane is absent or no longer matches its roster identity'
    [void](Set-DuetRecipientDead -Name $queue -Reason $reason)
    if (-not (Move-DuetRejected -File $file -Reason "recipient $queue is dead")) {
      [void](Set-DuetRecipientBlocked -Name $queue -Reason 'could not reject message for dead recipient')
    }
    return $true
  }

  $payload = Build-DuetPayload
  $script:DuetProcessAttempted = $true
  $result = Send-DuetVerified -PaneId $row.pane_id -PanePid $row.pane_pid -Payload $payload `
    -Interrupt ($global:DUET_MESSAGE_MODE -eq 'INTERRUPT') -Harness $row.harness
  if ($result.Collapsed) {
    Write-DuetDeliverdLog "observed $($row.harness) collapsed composer for $($global:DUET_MESSAGE_ID) -> $queue"
  }
  if ([int]$result.Code -ne 0) {
    $wireOutcome = if ($result.PSObject.Properties['WireOutcome']) {
      $result.WireOutcome
    } else { '' }
    Write-DuetDeliverdLog (
      "verifier outcome code=$($result.Code) wire=$wireOutcome landing=$($result.LandingObserved) " +
      "collapsed=$($result.Collapsed) enter=$($result.EnterToken) " +
      "for $($global:DUET_MESSAGE_ID) -> $queue"
    )
  }

  switch ([int]$result.Code) {
    0 {
      if (-not (Move-DuetDelivered -File $file)) {
        Set-DuetSessionUnhealthy "could not archive delivered message $($global:DUET_MESSAGE_ID)"
        return $false
      }
      Reset-DuetNotLanded -Name $queue
      Write-DuetDeliverdLog "delivered $($global:DUET_MESSAGE_ID) -> $queue"
    }
    21 {
      $stall = Add-DuetNotLanded -Name $queue
      if ($stall.Count -ge $stall.Limit) {
        $reason = "composer wedged: $($stall.Count) consecutive delivery attempts for $($global:DUET_MESSAGE_ID) did not land"
        if (-not (Set-DuetRecipientBlocked -Name $queue -Reason $reason)) {
          Write-DuetDeliverdLog "could not persist recipient block after $reason"
        }
      } else {
        Write-DuetDeliverdLog "stalled $($global:DUET_MESSAGE_ID) -> $queue before landing ($($stall.Count)/$($stall.Limit))"
      }
    }
    20 {
      $reason = "died while delivering $($global:DUET_MESSAGE_ID)"
      [void](Set-DuetRecipientDead -Name $queue -Reason $reason)
      if (-not (Move-DuetRejected -File $file -Reason "recipient $queue $reason")) {
        [void](Set-DuetRecipientBlocked -Name $queue -Reason 'could not reject message for dead recipient')
      }
    }
    22 {
      if (-not (Set-DuetRecipientBlocked -Name $queue -Reason "delivery-ambiguous after paste for $($global:DUET_MESSAGE_ID)")) {
        Set-DuetSessionUnhealthy "could not fence ambiguous delivery for $($global:DUET_MESSAGE_ID) -> $queue"
        return $false
      }
    }
    default {
      if (-not (Set-DuetRecipientBlocked -Name $queue -Reason "unexpected verifier outcome $($result.Code) for $($global:DUET_MESSAGE_ID)")) {
        Set-DuetSessionUnhealthy "could not fence unexpected outcome $($result.Code) for $($global:DUET_MESSAGE_ID)"
        return $false
      }
    }
  }
  return $true
}

# Give every roster member at most one bounded head attempt per pass.
function Invoke-DuetDeliverdPass {
  $rosterPath = Join-Path $global:DUET_DIR 'roster.tsv'
  $rows = @(Import-DuetRoster $rosterPath)
  if (-not $global:DUET_ROSTER_VALID) {
    Set-DuetSessionUnhealthy 'roster validation failed'
    return $false
  }
  foreach ($row in $rows) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $global:DUET_DIR 'blocked') $row.name)) { continue }
    $box = Join-Path (Join-Path $global:DUET_DIR 'inbox') $row.name
    if (-not (Test-Path -LiteralPath $box -PathType Container)) { continue }
    $next = Get-DuetQueueNext -Box $box
    if ($null -eq $next) { continue }
    if (-not (Invoke-DuetProcessOne -Box $box -ExactFile $next.FullName)) { return $false }
  }
  return $true
}
