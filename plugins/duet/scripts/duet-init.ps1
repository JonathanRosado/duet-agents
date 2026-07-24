# Start a two-to-five agent v4 mesh from a supported harness's psmux pane.
[CmdletBinding()]
param(
  [string]$Initiator,
  [string]$InitiatorName,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Harnesses,
  [int]$ReadyTimeoutSeconds = 75
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir 'duet-common.ps1')

$script:InitExitCode = 7
function Stop-DuetInit {
  param([string]$Message, [int]$Code = 7)
  $script:InitExitCode = $Code
  throw $Message
}

function Get-DuetHarnessAdapter {
  param([string]$Harness, [string]$PluginDir)
  $path = Join-Path (Join-Path $PluginDir 'harnesses') ($Harness + '.ps1')
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $items = @(& $path)
  if ($items.Count -ne 1 -or -not ($items[0] -is [hashtable])) { return $null }
  $adapter = $items[0]
  foreach ($key in @('BootRegex', 'BriefFile', 'Check', 'Pretrust', 'LaunchCommand')) {
    if (-not $adapter.ContainsKey($key) -or $null -eq $adapter[$key]) { return $null }
  }
  if (-not ($adapter['Check'] -is [scriptblock]) -or
      -not ($adapter['Pretrust'] -is [scriptblock]) -or
      -not ($adapter['LaunchCommand'] -is [scriptblock])) { return $null }
  return $adapter
}

function Invoke-DuetAdapterBoolean {
  param([scriptblock]$Block, [object[]]$Arguments = @())
  $values = @(& $Block @Arguments)
  if ($values.Count -eq 0) { return $false }
  for ($i = 0; $i -lt ($values.Count - 1); $i++) {
    [Console]::Out.WriteLine([string]$values[$i])
  }
  return [bool]$values[-1]
}

function Add-DuetRenderedAnchor {
  param([string]$Path, [string]$Rendered)
  if ((Test-Path -LiteralPath $Path) -and (Test-DuetReparsePoint $Path)) {
    Write-DuetError "duet: refusing symlinked instruction file: $Path"
    return $false
  }
  $existing = Get-DuetFileText $Path
  if ($null -eq $existing) {
    if (Test-Path -LiteralPath $Path) {
      Write-DuetError "duet: could not read instruction file: $Path"
      return $false
    }
    $existing = ''
  }
  $stripped = [regex]::Replace(
    $existing,
    "(?s)\r?\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\r?\n?",
    ''
  )
  $prefix = if ($stripped.Length -gt 0 -and -not $stripped.EndsWith("`n")) { "`n" } else { '' }
  $block = "<!-- DUET:BEGIN (added by duet-init; removed by duet-end) -->`n" +
    $Rendered.TrimEnd("`r", "`n") + "`n<!-- DUET:END -->"
  return (Write-DuetAtomicMultiline -Path $Path -Value ($stripped + $prefix + $block))
}

function New-DuetStateDirectory {
  param([string]$StateRoot)
  for ($i = 0; $i -lt 30; $i++) {
    $sid = New-DuetSessionId
    $path = Join-Path $StateRoot $sid
    if (Test-Path -LiteralPath $path) { continue }
    try {
      New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
      return [pscustomobject]@{ Id = $sid; Path = (Get-DuetCanonicalPath $path) }
    } catch { }
  }
  return $null
}

function Stop-DuetInitWorkers {
  param([object[]]$Workers)
  $ok = $true
  foreach ($worker in @($Workers | Sort-Object Rank -Descending)) {
    if (-not $worker.PaneId -or -not $worker.PanePid) { continue }
    $resolution = Resolve-DuetPaneResolution -PaneId $worker.PaneId -PanePid $worker.PanePid
    if (-not $resolution.Known) { $ok = $false; continue }
    if (-not $resolution.Alive) { continue }
    $resolution = Resolve-DuetPaneResolution -PaneId $worker.PaneId -PanePid $worker.PanePid
    if (-not $resolution.Known) { $ok = $false; continue }
    if (-not $resolution.Alive) { continue }
    $pidNumber = 0
    if (-not [int]::TryParse([string]$worker.PanePid, [ref]$pidNumber) -or $pidNumber -le 0) {
      $ok = $false
      continue
    }
    try { Stop-Process -Id $pidNumber -Force -ErrorAction Stop } catch { }
    $gone = $false
    for ($j = 0; $j -lt 20; $j++) {
      if (-not (Test-DuetProcessAlive $pidNumber)) { $gone = $true; break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $gone) { $ok = $false }
  }
  return $ok
}

if (-not $env:TMUX -or -not $env:TMUX_PANE) {
  Write-DuetError 'duet: not inside psmux. Start claude, codex, or kimi inside psmux first.'
  exit 3
}

$Harnesses = @($Harnesses | Where-Object { $_ })
if ($Harnesses.Count -eq 0) { $Harnesses = @('codex') }
if ($Harnesses.Count -lt 1 -or $Harnesses.Count -gt 4) {
  Write-DuetError 'usage: duet-init.ps1 [-Initiator claude|codex|kimi] [-InitiatorName <name>] [codex|kimi|claude ...] (1-4 peers; default: codex)'
  exit 2
}

$PluginDir = Get-DuetCanonicalPath (Join-Path $SelfDir '..')
if (-not $PluginDir) { Write-DuetError 'duet: plugin directory is unavailable.'; exit 7 }
if (-not (Get-DuetCallerIdentity)) {
  Write-DuetError 'duet: could not prove the initiating psmux pane identity.'
  exit 3
}
if ($global:DUET_CALLER_PANE -ne $env:TMUX_PANE) {
  Write-DuetError 'duet: TMUX_PANE does not match the ancestry-derived initiating pane.'
  exit 3
}

$InitiatorPane = $global:DUET_CALLER_PANE
$InitiatorPanePid = $global:DUET_CALLER_PANE_PID
$PsmuxSession = $global:DUET_CALLER_SESSION
$PsmuxServerPid = $global:DUET_CALLER_SERVER_PID
$PsmuxNamespace = $global:DUET_CALLER_NAMESPACE
$PsmuxRegistry = $global:DUET_CALLER_REGISTRY
if (-not (Test-DuetSafeName $PsmuxSession) -or -not (Test-DuetSafeName $PsmuxRegistry)) {
  Write-DuetError 'duet: initiating psmux session or registry name is unsupported.'
  exit 3
}
$global:DUET_PSMUX_SESSION = $PsmuxSession
$global:DUET_PSMUX_SERVER_PID = $PsmuxServerPid
$global:DUET_PSMUX_NAMESPACE = $PsmuxNamespace
$global:DUET_PSMUX_REGISTRY = $PsmuxRegistry
if (-not (Test-DuetServerMatches)) {
  Write-DuetError 'duet: initiating psmux backend identity is unstable.'
  exit 3
}

$requestedInitiator = if ($PSBoundParameters.ContainsKey('Initiator')) {
  $Initiator
} elseif ($env:DUET_INITIATOR_HARNESS) {
  $env:DUET_INITIATOR_HARNESS
} else { '' }
if ($requestedInitiator) {
  $InitiatorHarness = ([string]$requestedInitiator).ToLowerInvariant()
} else {
  $paneCommandOut = @(Invoke-DuetPsmux display-message -p -t "${PsmuxSession}:${InitiatorPane}" '#{pane_current_command}')
  if ($global:DUET_PSMUX_RC -ne 0 -or $paneCommandOut.Count -ne 1) {
    Write-DuetError 'duet: could not infer the invoking harness; pass -Initiator claude, codex, or kimi.'
    exit 2
  }
  $paneCommand = ([string]$paneCommandOut[0]).Trim()
  $InitiatorHarness = [IO.Path]::GetFileNameWithoutExtension($paneCommand).ToLowerInvariant()
}
if (@('claude', 'codex', 'kimi') -notcontains $InitiatorHarness) {
  Write-DuetError "duet: unsupported initiator harness '$requestedInitiator'; expected claude, codex, or kimi."
  exit 2
}

$requestedInitiatorName = if ($PSBoundParameters.ContainsKey('InitiatorName')) {
  $InitiatorName
} elseif ($env:DUET_INITIATOR_NAME) {
  $env:DUET_INITIATOR_NAME
} else { '' }
if (-not $requestedInitiatorName) { $requestedInitiatorName = $InitiatorHarness }
if ($requestedInitiatorName -notmatch '^[A-Za-z0-9_-]+$' -or $requestedInitiatorName -eq 'all') {
  Write-DuetError "duet: initiator name must be a non-reserved name containing only letters, digits, '_' or '-'."
  exit 2
}
$InitiatorName = [string]$requestedInitiatorName

$initiatorAdapter = Get-DuetHarnessAdapter -Harness $InitiatorHarness -PluginDir $PluginDir
if (-not $initiatorAdapter) {
  Write-DuetError "duet: initiator harness adapter '$InitiatorHarness.ps1' is invalid."
  exit 2
}
if (-not (Invoke-DuetAdapterBoolean -Block $initiatorAdapter['Check'])) { exit 3 }

$counts = @{ codex = 0; kimi = 0; claude = 0 }
$specs = @()
foreach ($requestedHarness in $Harnesses) {
  $harness = ([string]$requestedHarness).ToLowerInvariant()
  if (-not $counts.ContainsKey($harness)) {
    Write-DuetError "duet: unsupported harness '$requestedHarness'"
    exit 2
  }
  $adapter = Get-DuetHarnessAdapter -Harness $harness -PluginDir $PluginDir
  if (-not $adapter) {
    Write-DuetError "duet: harness adapter '$harness.ps1' is invalid."
    exit 2
  }
  if (-not (Invoke-DuetAdapterBoolean -Block $adapter['Check'])) { exit 3 }
  do {
    $counts[$harness]++
    $workerName = '{0}-{1}' -f $harness, $counts[$harness]
  } while ($workerName -eq $InitiatorName)
  $specs += [pscustomobject]@{
    Harness = $harness
    Name = $workerName
    Adapter = $adapter
  }
}

$Workdir = Get-DuetCanonicalPath (Get-Location).Path
if (-not $Workdir -or $Workdir -match "[\t\r\n]") {
  Write-DuetError 'duet: current workdir is unavailable or contains a control character.'
  exit 7
}
$stateRootInput = if ($env:DUET_STATE_ROOT) {
  $env:DUET_STATE_ROOT
} elseif ($env:USERPROFILE) {
  Join-Path $env:USERPROFILE '.duet'
} elseif ($HOME) {
  Join-Path $HOME '.duet'
} else { '' }
if (-not $stateRootInput -or $stateRootInput -match "[\t\r\n]") {
  Write-DuetError 'duet: set DUET_STATE_ROOT or USERPROFILE before starting.'
  exit 7
}
if (-not (Test-Path -LiteralPath $stateRootInput)) {
  New-Item -ItemType Directory -Path $stateRootInput -Force | Out-Null
}
$StateRoot = Get-DuetCanonicalPath $stateRootInput
if (-not $StateRoot) { Write-DuetError 'duet: state root is unavailable.'; exit 7 }
$driveRoot = [IO.Path]::GetPathRoot($StateRoot).TrimEnd('\')
if ($StateRoot.TrimEnd('\') -eq $driveRoot) {
  Write-DuetError 'duet: DUET_STATE_ROOT may not be a drive root.'
  exit 7
}
if (Test-DuetPathChainHasReparse -Path $StateRoot) {
  Write-DuetError 'duet: DUET_STATE_ROOT may not contain a reparse point.'
  exit 7
}

$initComplete = $false
$DuetDir = ''
$ConfigPath = ''
$workers = @()
$daemonStarted = $false
$finalExit = 0
try {
  $created = New-DuetStateDirectory -StateRoot $StateRoot
  if (-not $created -or -not $created.Path) {
    Stop-DuetInit 'duet: could not allocate a unique session directory.'
  }
  $DuetDir = $created.Path
  $SessionId = $created.Id
  $ConfigPath = Join-Path $DuetDir 'duet.env'
  $global:DUET_DIR = $DuetDir
  $global:DUET_SESSION_ID = $SessionId
  $global:DUET_SESSION = $SessionId

  New-Item -ItemType Directory -Path (Join-Path $DuetDir 'ready') -Force | Out-Null
  foreach ($queue in @($InitiatorName) + @($specs | ForEach-Object { $_.Name })) {
    foreach ($sub in @('delivered', 'rejected')) {
      New-Item -ItemType Directory -Path (Join-Path (Join-Path (Join-Path $DuetDir 'inbox') $queue) $sub) -Force | Out-Null
    }
  }
  Write-DuetUtf8NoBom -Path (Join-Path $DuetDir 'transcript.md') -Value ''
  Write-DuetUtf8NoBom -Path (Join-Path $DuetDir 'assignments.md') -Value "# Duet assignments`n"
  if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir "ready\$InitiatorName") -Value 'ok')) {
    Stop-DuetInit 'duet: could not publish initial readiness state.'
  }

  $briefPath = Join-Path $PluginDir 'briefs\ENSEMBLE_BRIEF.win.md'
  $brief = Get-DuetFileText $briefPath
  if ($null -eq $brief) { Stop-DuetInit 'duet: Windows mesh brief is missing.' }
  $rendered = $brief.Replace('@DUET_DIR@', $DuetDir).
    Replace('@PLUGIN@', $PluginDir).
    Replace('@DUET_SESSION@', $SessionId).
    Replace('@INITIATOR@', $InitiatorName)
  if (-not (Add-DuetRenderedAnchor -Path (Join-Path $Workdir 'AGENTS.md') -Rendered $rendered) -or
      -not (Add-DuetRenderedAnchor -Path (Join-Path $Workdir 'CLAUDE.md') -Rendered $rendered)) {
    Stop-DuetInit 'duet: could not publish durable instruction anchors.'
  }

  for ($i = 0; $i -lt $specs.Count; $i++) {
    $spec = $specs[$i]
    if (-not (Invoke-DuetAdapterBoolean -Block $spec.Adapter['Pretrust'] -Arguments @($Workdir))) {
      Stop-DuetInit "duet: pretrust failed for $($spec.Name)."
    }
    $launchValues = @(& $spec.Adapter['LaunchCommand'] $Workdir $DuetDir $spec.Name)
    if ($launchValues.Count -ne 1 -or -not [string]$launchValues[0]) {
      Stop-DuetInit "duet: launch adapter failed for $($spec.Name)."
    }
    $launcher = Join-Path $DuetDir ("launch-{0}.ps1" -f $spec.Name)
    Write-DuetUtf8NoBom -Path $launcher -Value ([string]$launchValues[0])
    $splitArgs = @('split-window')
    if ($i -eq 0) { $splitArgs += '-h' }
    $splitArgs += @('-t', "${PsmuxSession}:${InitiatorPane}", '-P', '-F', '#{pane_id}', '--',
      'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      (ConvertTo-DuetPsLiteral $launcher))
    $out = @(Invoke-DuetPsmux @splitArgs)
    if ($global:DUET_PSMUX_RC -ne 0 -or $out.Count -eq 0) {
      Stop-DuetInit "duet: psmux could not launch $($spec.Name)."
    }
    $paneId = ([string]$out[-1]).Trim()
    if ($paneId -notmatch '^%[0-9]+$') {
      Stop-DuetInit "duet: psmux returned an invalid pane id for $($spec.Name)."
    }
    $pidOut = @(Invoke-DuetPsmux display-message -p -t "${PsmuxSession}:${paneId}" '#{pane_pid}')
    if ($global:DUET_PSMUX_RC -ne 0 -or $pidOut.Count -ne 1 -or
        ([string]$pidOut[0]).Trim() -notmatch '^[0-9]+$') {
      Stop-DuetInit "duet: psmux could not resolve the pane pid for $($spec.Name)."
    }
    $panePid = ([string]$pidOut[0]).Trim()
    if ($paneId -eq $InitiatorPane -and $panePid -eq $InitiatorPanePid) {
      Stop-DuetInit 'duet: psmux returned the initiating pane as a peer.'
    }
    $workers += [pscustomobject]@{
      Name = $spec.Name
      Harness = $spec.Harness
      Adapter = $spec.Adapter
      PaneId = $paneId
      PanePid = $panePid
      Rank = ($i + 1)
      Boot = 'pending'
      Trust = 'not-needed'
      Kick = 'pending'
      Ready = 'no'
    }
  }
  Invoke-DuetPsmux select-pane -t "${PsmuxSession}:${InitiatorPane}" | Out-Null
  if ($workers.Count -gt 1) { Invoke-DuetPsmux select-layout -t $PsmuxSession tiled | Out-Null }

  $rosterLines = @("name`tharness`tpane_id`tpane_pid`trank`tspawned")
  $rosterLines += ($InitiatorName, $InitiatorHarness, $InitiatorPane, $InitiatorPanePid, '0', '0') -join "`t"
  foreach ($worker in $workers) {
    $rosterLines += ($worker.Name, $worker.Harness, $worker.PaneId, $worker.PanePid,
      [string]$worker.Rank, '1') -join "`t"
  }
  $RosterPath = Join-Path $DuetDir 'roster.tsv'
  if (-not (Write-DuetAtomicMultiline -Path $RosterPath -Value ($rosterLines -join "`n"))) {
    Stop-DuetInit 'duet: could not publish the roster.'
  }
  $null = @(Import-DuetRoster $RosterPath)
  if (-not $global:DUET_ROSTER_VALID) {
    Stop-DuetInit 'duet: published roster failed validation.'
  }

  $configLines = @(
    "DUET_DIR=$DuetDir",
    "DUET_STATE_ROOT=$StateRoot",
    "WORKDIR=$Workdir",
    "PLUGIN_DIR=$PluginDir",
    "DUET_PSMUX_SESSION=$PsmuxSession",
    "DUET_PSMUX_SERVER_PID=$PsmuxServerPid",
    "DUET_PSMUX_REGISTRY=$PsmuxRegistry",
    "DUET_PSMUX_NAMESPACE=$PsmuxNamespace",
    "DUET_SESSION=$SessionId",
    "DUET_SESSION_ID=$SessionId",
    "DUET_INITIATOR=$InitiatorName",
    "DUET_INITIATOR_PANE=$InitiatorPane"
  )
  if (-not (Write-DuetAtomicMultiline -Path $ConfigPath -Value ($configLines -join "`n"))) {
    Stop-DuetInit 'duet: could not publish the session config.'
  }
  $cfgCheck = Import-DuetConfig $ConfigPath
  if (-not $global:DUET_CONFIG_VALID -or
      -not (Test-DuetLoadedSession -Config $cfgCheck -ExpectedSession $SessionId -ConfigPath $ConfigPath)) {
    Stop-DuetInit 'duet: published session config failed validation.'
  }

  $powershell = Resolve-DuetExecutable 'powershell.exe'
  if (-not $powershell) { $powershell = Join-Path $PSHOME 'powershell.exe' }
  $daemon = Join-Path $SelfDir 'duet-deliverd.ps1'
  $daemonArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Session "{1}" -SessionId "{2}"' -f
    $daemon, $ConfigPath, $SessionId
  $savedConfig = $env:DUET_CONFIG
  $savedSession = $env:DUET_SESSION
  try {
    $env:DUET_CONFIG = $ConfigPath
    $env:DUET_SESSION = $SessionId
    $proc = Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList $daemonArgs -PassThru
  }
  finally {
    $env:DUET_CONFIG = $savedConfig
    $env:DUET_SESSION = $savedSession
  }
  $daemonStarted = $true
  $daemonReady = $false
  for ($i = 0; $i -lt 50; $i++) {
    if (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $SessionId) {
      $daemonReady = $true
      break
    }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $daemonReady) {
    Stop-DuetInit "duet: delivery daemon failed to start; see $DuetDir\deliverd.log" 6
  }

  $bootTimeout = 35
  $parsedTimeout = 0
  if ($env:DUET_BOOT_TIMEOUT -and [int]::TryParse($env:DUET_BOOT_TIMEOUT, [ref]$parsedTimeout) -and
      $parsedTimeout -gt 0) {
    $bootTimeout = $parsedTimeout
  }
  if (-not $PSBoundParameters.ContainsKey('ReadyTimeoutSeconds') -and
      $env:DUET_READY_TIMEOUT -and
      [int]::TryParse($env:DUET_READY_TIMEOUT, [ref]$parsedTimeout) -and
      $parsedTimeout -gt 0) {
    $ReadyTimeoutSeconds = $parsedTimeout
  }
  if ($ReadyTimeoutSeconds -lt 1) { $ReadyTimeoutSeconds = 1 }

  $readyCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' +
    (ConvertTo-DuetPsLiteral (Join-Path $SelfDir 'duet-ready.ps1'))
  foreach ($worker in $workers) {
    $worker.Boot = 'timeout'
    $zoomTarget = "${PsmuxSession}:$($worker.PaneId)"
    $zoomed = $false
    Invoke-DuetPsmux resize-pane -Z -t $zoomTarget | Out-Null
    if ($global:DUET_PSMUX_RC -eq 0) { $zoomed = $true }
    try {
      for ($i = 0; $i -lt $bootTimeout; $i++) {
        $resolution = Resolve-DuetPaneResolution -PaneId $worker.PaneId -PanePid $worker.PanePid
        if ($resolution.Known -and -not $resolution.Alive) {
          $worker.Boot = 'dead'
          break
        }
        if ($resolution.Known -and $resolution.Alive) {
          # Inspect only the visible screen: scrollback retains a trust dialog
          # after it has been accepted and must not trigger a second Enter.
          $capture = @(Invoke-DuetPsmux capture-pane -p -t $resolution.Target)
          $screen = $capture -join "`n"
          if ($global:DUET_PSMUX_RC -eq 0 -and
              $worker.Adapter.ContainsKey('TrustRegex') -and
              $screen -match $worker.Adapter['TrustRegex']) {
            if ($worker.Trust -eq 'not-needed') {
              $trustKey = Send-DuetPaneKey -Session $PsmuxSession -ServerPid $PsmuxServerPid `
                -PaneId $worker.PaneId -PanePid $worker.PanePid -Keys @('Enter')
              if (-not $trustKey.Alive) {
                $worker.Boot = 'dead'
                break
              }
              if ($trustKey.Ok) { $worker.Trust = 'accepted' }
            }
            Start-Sleep -Milliseconds 500
            continue
          }
          if ($global:DUET_PSMUX_RC -eq 0 -and $screen -match $worker.Adapter['BootRegex']) {
            $worker.Boot = 'ready'
            break
          }
        }
        Start-Sleep -Seconds 1
      }

    }
    finally {
      if ($zoomed) { Invoke-DuetPsmux resize-pane -Z -t $zoomTarget | Out-Null }
    }

    # Boot banners need a zoomed pane to remain visible in a four-way split,
    # while psmux's cursor/row geometry used by verified delivery is reliable
    # only after restoring the tiled layout. Do not zoom the next worker until
    # this kick has either been archived or terminalized.
    $kick = "[DUET boot]`nYou are $($worker.Name) (harness: $($worker.Harness)). Read $($worker.Adapter['BriefFile']). Confirm readiness now by running exactly this shell command:`n$readyCommand`nThen wait for a task from a peer."
    if (Add-DuetMessage -DuetDir $DuetDir -SessionId $SessionId -Queue $worker.Name `
        -Sender $InitiatorName -Recipient $worker.Name -Mode 'NORMAL' -Body $kick) {
      $worker.Kick = 'queued:' + $global:DUET_ENQUEUED_ID
      $queuedFile = $global:DUET_ENQUEUED_FILE
      $queuedLeaf = Split-Path -Leaf $queuedFile
      $queuedBox = Split-Path -Parent $queuedFile
      $deliveredFile = Join-Path (Join-Path $queuedBox 'delivered') $queuedLeaf
      $rejectedFile = Join-Path (Join-Path $queuedBox 'rejected') $queuedLeaf
      $blockedFile = Join-Path (Join-Path $DuetDir 'blocked') $worker.Name
      for ($settle = 0; $settle -lt 600; $settle++) {
        if (-not (Test-Path -LiteralPath $queuedFile) -or
            (Test-Path -LiteralPath $deliveredFile) -or
            (Test-Path -LiteralPath $rejectedFile) -or
            (Test-Path -LiteralPath $blockedFile)) {
          break
        }
        Start-Sleep -Milliseconds 100
      }
    } else {
      $worker.Kick = 'failed'
    }
  }

  for ($i = 0; $i -lt $ReadyTimeoutSeconds; $i++) {
    $notReady = @($workers | Where-Object {
      -not (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $_.Name))
    })
    if ($notReady.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  }

  Write-Output "duet: session $DuetDir"
  Write-Output ('  {0,-12} {1,-8} {2,-6} {3,-10} {4,-35} {5}' -f
    'NAME', 'HARNESS', 'PANE', 'BOOT', 'KICK', 'READY')
  $failed = $false
  foreach ($worker in $workers) {
    $worker.Ready = if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $worker.Name)) {
      'yes'
    } else { 'no' }
    if ($worker.Ready -ne 'yes') { $failed = $true }
    Write-Output ('  {0,-12} {1,-8} {2,-6} {3,-10} {4,-35} {5}' -f
      $worker.Name, $worker.Harness, $worker.PaneId, $worker.Boot, $worker.Kick, $worker.Ready)
  }
  $initComplete = $true
  if ($failed) {
    Write-DuetError 'duet: one or more peers did not confirm readiness; session left running for diagnosis.'
    $finalExit = 5
  } else {
    Write-Output "duet: all peers READY; initiator=$InitiatorName harness=$InitiatorHarness"
  }
}
catch {
  Write-DuetError ([string]$_.Exception.Message)
  $finalExit = $script:InitExitCode
}
finally {
  if (-not $initComplete -and $DuetDir) {
    try { Write-DuetUtf8NoBom -Path (Join-Path $DuetDir '.ended') -Value '' } catch { }
    $daemonSafe = $true
    if ($daemonStarted) { $daemonSafe = Stop-DuetDaemon -DuetDir $DuetDir -Loops 30 }
    if (-not $daemonSafe) {
      Write-DuetError 'duet: init cleanup could not stop the delivery daemon cleanly.'
    }
    if (-not (Stop-DuetInitWorkers -Workers $workers)) {
      Write-DuetError 'duet: init cleanup could not prove every peer stopped.'
    }
    if (-not (Remove-DuetSessionAnchors -Workdir $Workdir)) {
      Write-DuetError 'duet: init cleanup could not strip session anchors.'
    }
  }
}
exit $finalExit
