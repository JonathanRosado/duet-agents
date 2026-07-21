# Stop one duet session after atomically closing admission and draining every
# already-published queue item. Native params:  duet-end.ps1 [-Session <cfg>]
[CmdletBinding()]
param([string]$Session)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'duet-common.ps1')

$callerPin = $env:DUET_SESSION
if (-not (Resolve-DuetConfig $Session 0)) { exit 1 }
$cfgPath = $global:DUET_RESOLVED_CONFIG
$cfg = Import-DuetConfig $cfgPath
if (-not (Test-DuetLoadedSession -Config $cfg -ExpectedSession $callerPin -ConfigPath $cfgPath)) { exit 1 }
Set-DuetSessionVariables -Config $cfg
$DuetDir = Get-DuetCanonicalPath $cfg['DUET_DIR']
$Sid = $cfg['DUET_SESSION_ID']
$Workdir = Get-DuetCanonicalPath $cfg['WORKDIR']
$StateRoot = Get-DuetCanonicalPath $cfg['DUET_STATE_ROOT']
if (-not $Workdir -or -not $StateRoot) { Write-DuetError "duet: recorded workdir/state root unavailable; refusing teardown."; exit 9 }
$wkey = Get-DuetWorkdirKey $Workdir
if (-not $wkey) { exit 9 }
if ($cfg['DUET_WORKDIR_KEY'] -and $cfg['DUET_WORKDIR_KEY'] -ne $wkey) { Write-DuetError "duet: recorded workdir key mismatch; refusing teardown."; exit 9 }
$workdirsDir = Join-Path $StateRoot 'workdirs'
if (-not (Test-Path -LiteralPath $workdirsDir)) { New-Item -ItemType Directory -Path $workdirsDir -Force | Out-Null }
$activeFile = Join-Path $workdirsDir "$wkey.active"
$workdirLock = Join-Path $workdirsDir "$wkey.lock"

if (-not (Lock-DuetAcquire $workdirLock 4000)) { Write-DuetError "duet: another init/end owns the workdir transition lock."; exit 9 }
$workdirUnlockOk = $false
try {
  $activeTarget = Get-DuetFileText $activeFile; if ($activeTarget) { $activeTarget = $activeTarget.Trim() }
  $ownsWorkdir = ($activeTarget -eq $DuetDir)

  # Caller pane (exempt from teardown so a promoted worker can end cleanly).
  $exemptPane = ''; $exemptPanePid = ''
  if (Get-DuetCallerIdentity) { $exemptPane = $global:DUET_CALLER_PANE; $exemptPanePid = $global:DUET_CALLER_PANE_PID }
  elseif ($env:TMUX_PANE) { Write-DuetError 'duet: could not prove caller identity; refusing teardown from inside psmux.'; exit 9 }

  $deliveryFence = $false
  if (-not (Test-Path -LiteralPath (Join-Path $DuetDir '.ended'))) {
    $admission = Join-Path $DuetDir '.admission.lock'
    if (-not (Lock-DuetAcquire $admission 200)) { Write-DuetError "duet: could not close message admission."; exit 9 }
    if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir '.draining') -Value '')) { Unlock-DuetRelease $admission | Out-Null; Write-DuetError "duet: could not publish the draining marker."; exit 9 }
    if (-not (Unlock-DuetRelease $admission)) { Write-DuetError "duet: could not release the admission fence."; exit 9 }

    $drainTimeout = 30
    $parsedDrainTimeout = 0
    if ($env:DUET_DRAIN_TIMEOUT -and [int]::TryParse($env:DUET_DRAIN_TIMEOUT, [ref]$parsedDrainTimeout) -and $parsedDrainTimeout -gt 0) { $drainTimeout = [Math]::Min($parsedDrainTimeout, 3600) }
    $drained = $false
    for ($i = 0; $i -lt ($drainTimeout * 10 + 1); $i++) {
      $pending = Get-DuetPendingCount $DuetDir
      $notices = Get-DuetNoticeObligationCount $DuetDir
      if ($pending -eq 0 -and $notices -eq 0) {
        $attempts = if (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid) { 2 } else { 22 }
        if (Lock-DuetAcquire (Join-Path $DuetDir '.delivery.lock') $attempts) {
          if ((Get-DuetPendingCount $DuetDir) -eq 0 -and (Get-DuetNoticeObligationCount $DuetDir) -eq 0) { $deliveryFence = $true; $drained = $true; break }
          Unlock-DuetRelease (Join-Path $DuetDir '.delivery.lock') | Out-Null
        }
      }
      if (-not (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $Sid)) { break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $drained) {
      $pending = Get-DuetPendingCount $DuetDir; $notices = Get-DuetNoticeObligationCount $DuetDir
      if (Lock-DuetAcquire $admission 200) {
        $reopened = $false
        try { Remove-Item -LiteralPath (Join-Path $DuetDir '.draining') -Force -ErrorAction Stop; $reopened = $true } catch { }
        if (-not (Unlock-DuetRelease $admission)) { $reopened = $false }
        if (-not $reopened) { Write-DuetError "duet: could not reopen admission; draining marker remains as a safety fence." }
      }
      else { Write-DuetError "duet: could not reopen admission; draining marker remains as a safety fence." }
      Write-DuetError "duet: drain timed out with $pending pending message(s) and $notices notice obligation(s); session left running."; exit 9
    }
    if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir '.ended') -Value '')) { if ($deliveryFence) { Unlock-DuetRelease (Join-Path $DuetDir '.delivery.lock') | Out-Null }; Write-DuetError "duet: could not publish the ended marker; session left intact."; exit 9 }
    if ($deliveryFence -and -not (Unlock-DuetRelease (Join-Path $DuetDir '.delivery.lock'))) { Write-DuetError 'duet: could not release the delivery fence.'; exit 9 }
  }

  if (-not (Stop-DuetDaemon -DuetDir $DuetDir -Loops 50)) { Write-DuetError "duet: daemon did not stop; session left intact for diagnosis."; exit 9 }
  if (Lock-DuetAcquire (Join-Path $DuetDir '.daemon.lock') 22) {
    $daemonUnlocked = $false
    try { Remove-Item -LiteralPath (Join-Path $DuetDir 'daemon.pid') -Force -ErrorAction SilentlyContinue }
    finally { $daemonUnlocked = Unlock-DuetRelease (Join-Path $DuetDir '.daemon.lock') }
    if (-not $daemonUnlocked) { Write-DuetError "duet: could not release the daemon fence; teardown stopped."; exit 9 }
  }
  else { Write-DuetError "duet: could not prove the delivery daemon is fenced; teardown stopped."; exit 9 }

  if (-not (Test-DuetServerMatches)) { Write-DuetError 'duet: backend identity changed; teardown stopped before pane cleanup.'; exit 9 }
  if (-not (Stop-DuetSpawnedPanes -RosterPath (Join-Path $DuetDir 'roster.tsv') -ExemptPaneId $exemptPane -ExemptPanePid $exemptPanePid)) {
    Write-DuetError 'duet: one or more spawned panes could not be proved stopped; ownership pointers were preserved.'; exit 9
  }

  if ($ownsWorkdir) { if (-not (Remove-DuetSessionAnchors -Workdir $Workdir)) { Write-DuetError 'duet: could not strip session anchors; ownership pointers were preserved.'; exit 9 } }
  else { Write-DuetError "duet: a replacement session owns $Workdir; preserved its anchors and active index." }

  $activeNow = Get-DuetFileText $activeFile; if ($activeNow) { $activeNow = $activeNow.Trim() }
  if ($ownsWorkdir -and $activeNow -eq $DuetDir) {
    try { Remove-Item -LiteralPath $activeFile -Force -ErrorAction Stop } catch { Write-DuetError 'duet: could not release the workdir ownership pointer.'; exit 9 }
  }
  $curPtr = Join-Path $StateRoot 'current.session'
  if (Lock-DuetAcquire (Join-Path $StateRoot '.current.lock') 80) {
    $ct = Get-DuetFileText $curPtr; if ($ct) { $ct = $ct.Trim() }
    if ($ct -eq $DuetDir) {
      try { Remove-Item -LiteralPath $curPtr -Force -ErrorAction Stop } catch { [void](Unlock-DuetRelease (Join-Path $StateRoot '.current.lock')); Write-DuetError 'duet: could not release current.session.'; exit 9 }
    }
    if (-not (Unlock-DuetRelease (Join-Path $StateRoot '.current.lock'))) { Write-DuetError 'duet: could not release the current-session lock.'; exit 9 }
  }
  else { Write-DuetError 'duet: could not acquire the current-session lock.'; exit 9 }
}
finally { $workdirUnlockOk = Unlock-DuetRelease $workdirLock }

if (-not $workdirUnlockOk) { Write-DuetError 'duet: could not release the workdir transition lock.'; exit 9 }

Write-Output "duet: ended. Transcript kept at $DuetDir\transcript.md"
exit 0
