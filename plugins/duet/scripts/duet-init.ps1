# Start a two-to-five agent ensemble from a supported harness's psmux pane.
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
  for ($i = 0; $i -lt ($values.Count - 1); $i++) { [Console]::Out.WriteLine([string]$values[$i]) }
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
    if (Test-Path -LiteralPath $Path) { Write-DuetError "duet: could not read instruction file: $Path"; return $false }
    $existing = ''
  }
  $stripped = [regex]::Replace($existing, "(?s)\r?\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\r?\n?", '')
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
      $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
      return [pscustomobject]@{ Id = $sid; Path = (Get-DuetCanonicalPath $path) }
    }
    catch { }
  }
  return $null
}

function Stop-DuetInitWorkers {
  param([object[]]$Workers)
  $ok = $true
  foreach ($worker in @($Workers | Sort-Object Rank -Descending)) {
    if (-not $worker.PaneId -or -not $worker.PanePid) { continue }
    $res = Resolve-DuetPaneResolution -PaneId $worker.PaneId -PanePid $worker.PanePid
    if (-not $res.Known) { $ok = $false; continue }
    if (-not $res.Alive) { continue }
    $res = Resolve-DuetPaneResolution -PaneId $worker.PaneId -PanePid $worker.PanePid
    if (-not ($res.Known -and $res.Alive)) { if (-not $res.Known) { $ok = $false }; continue }
    $n = 0
    if (-not [int]::TryParse([string]$worker.PanePid, [ref]$n) -or $n -le 0) { $ok = $false; continue }
    try { Stop-Process -Id $n -Force -ErrorAction Stop } catch { }
    $gone = $false
    for ($j = 0; $j -lt 20; $j++) {
      if (-not (Test-DuetProcessAlive $n)) { $gone = $true; break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $gone) { $ok = $false }
  }
  return $ok
}

# Before the workdir-owner index existed, a live session could be known only by
# its immutable config. Mirror the Bash predecessor scan: inspect immediate
# session children, require the same canonical workdir, and refuse ambiguity.
function Find-DuetPreIndexPredecessor {
  param([string]$StateRoot, [string]$Workdir)
  $script:PredecessorScanValid = $true
  $matches = @()
  foreach ($child in @(Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue)) {
    $configPath = Join-Path $child.FullName 'duet.env'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $child.FullName '.ended'))) { continue }
    if (Test-DuetReparsePoint $configPath) { $script:PredecessorScanValid = $false; return $null }
    $candidate = Import-DuetConfig $configPath
    if (-not $global:DUET_CONFIG_VALID) { continue }
    $candidateWorkdir = Get-DuetCanonicalPath $candidate['WORKDIR']
    if (-not $candidateWorkdir -or $candidateWorkdir -ne $Workdir) { continue }
    if (-not (Test-DuetLoadedSession -Config $candidate -ConfigPath $configPath)) { $script:PredecessorScanValid = $false; return $null }
    $matches += (Get-DuetCanonicalPath $child.FullName)
  }
  if ($matches.Count -gt 1) { $script:PredecessorScanValid = $false; return $null }
  if ($matches.Count -eq 1) { return $matches[0] }
  return $null
}

if (-not $env:TMUX -or -not $env:TMUX_PANE) {
  Write-DuetError 'duet: not inside psmux. Start claude, codex, or kimi inside psmux first.'
  exit 3
}

$Harnesses = @($Harnesses | Where-Object { $_ })
if ($Harnesses.Count -eq 0) { $Harnesses = @('codex') }
if ($Harnesses.Count -lt 1 -or $Harnesses.Count -gt 4) {
  Write-DuetError 'usage: duet-init.ps1 [-Initiator claude|codex|kimi] [-InitiatorName <name>] [codex|kimi|claude ...] (1-4 workers; default: codex)'
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
if (-not (Test-DuetServerMatches)) { Write-DuetError 'duet: initiating psmux backend identity is unstable.'; exit 3 }

$requestedInitiator = if ($PSBoundParameters.ContainsKey('Initiator')) {
  $Initiator
}
elseif ($env:DUET_INITIATOR_HARNESS) {
  $env:DUET_INITIATOR_HARNESS
}
else {
  ''
}

if ($requestedInitiator) {
  $InitiatorHarness = ([string]$requestedInitiator).ToLowerInvariant()
}
else {
  $paneCommandOut = @(Invoke-DuetPsmux display-message -p -t "${PsmuxSession}:${InitiatorPane}" '#{pane_current_command}')
  if ($global:DUET_PSMUX_RC -ne 0 -or $paneCommandOut.Count -ne 1) {
    Write-DuetError 'duet: could not infer the invoking harness from the initiating pane; pass -Initiator claude, codex, or kimi.'
    exit 2
  }
  $paneCommand = ([string]$paneCommandOut[0]).Trim()
  $paneCommandName = [IO.Path]::GetFileNameWithoutExtension($paneCommand)
  $InitiatorHarness = if ($paneCommandName) { $paneCommandName.ToLowerInvariant() } else { '' }
  if (@('claude', 'codex', 'kimi') -notcontains $InitiatorHarness) {
    Write-DuetError "duet: could not infer the invoking harness from pane command '$paneCommand'; pass -Initiator claude, codex, or kimi."
    exit 2
  }
}
if (@('claude', 'codex', 'kimi') -notcontains $InitiatorHarness) {
  Write-DuetError "duet: unsupported initiator harness '$requestedInitiator'; expected claude, codex, or kimi."
  exit 2
}

$requestedInitiatorName = if ($PSBoundParameters.ContainsKey('InitiatorName')) {
  $InitiatorName
}
elseif ($env:DUET_INITIATOR_NAME) {
  $env:DUET_INITIATOR_NAME
}
else {
  ''
}
if (-not $requestedInitiatorName) { $requestedInitiatorName = $InitiatorHarness }
if ($requestedInitiatorName -notmatch '^[A-Za-z0-9_-]+$') {
  Write-DuetError 'duet: initiator name must contain only letters, digits, underscore, or hyphen.'
  exit 2
}
if (@('leader', 'promotions', 'all', 'duet-system') -contains $requestedInitiatorName) {
  Write-DuetError "duet: initiator name '$requestedInitiatorName' is reserved by the Windows protocol."
  exit 2
}
$InitiatorName = [string]$requestedInitiatorName

$initiatorAdapter = Get-DuetHarnessAdapter -Harness $InitiatorHarness -PluginDir $PluginDir
if (-not $initiatorAdapter) {
  Write-DuetError "duet: initiator harness adapter '$InitiatorHarness.ps1' is invalid."
  exit 2
}
if (-not (Invoke-DuetAdapterBoolean -Block $initiatorAdapter['Check'])) { exit 3 }

# Validate and name the full requested roster before touching session state or
# splitting a pane. Skip a generated worker name if it matches a custom initiator.
$counts = @{ codex = 0; kimi = 0; claude = 0 }
$specs = @()
foreach ($requestedHarness in $Harnesses) {
  $harness = ([string]$requestedHarness).ToLowerInvariant()
  if (-not $counts.ContainsKey($harness)) {
    Write-DuetError "duet: unsupported harness '$requestedHarness'"
    exit 2
  }
  $adapter = Get-DuetHarnessAdapter -Harness $harness -PluginDir $PluginDir
  if (-not $adapter) { Write-DuetError "duet: harness adapter '$harness.ps1' is invalid."; exit 2 }
  if (-not (Invoke-DuetAdapterBoolean -Block $adapter['Check'])) { exit 3 }
  do {
    $counts[$harness]++
    $workerName = ('{0}-{1}' -f $harness, $counts[$harness])
  } while ($workerName -eq $InitiatorName)
  $specs += [pscustomobject]@{
    Harness = $harness
    Name = $workerName
    Adapter = $adapter
  }
}

$Workdir = Get-DuetCanonicalPath (Get-Location).Path
if (-not $Workdir -or $Workdir -match "[\t\r\n]") { Write-DuetError 'duet: current workdir is unavailable or contains a control character.'; exit 7 }
$stateRootInput = if ($env:DUET_STATE_ROOT) { $env:DUET_STATE_ROOT } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.duet' } elseif ($HOME) { Join-Path $HOME '.duet' } else { '' }
if (-not $stateRootInput -or $stateRootInput -match "[\t\r\n]") { Write-DuetError 'duet: set DUET_STATE_ROOT or USERPROFILE before starting.'; exit 7 }
if (-not (Test-Path -LiteralPath $stateRootInput)) { New-Item -ItemType Directory -Path $stateRootInput -Force | Out-Null }
$StateRoot = Get-DuetCanonicalPath $stateRootInput
if (-not $StateRoot) { Write-DuetError 'duet: state root is unavailable.'; exit 7 }
$driveRoot = [IO.Path]::GetPathRoot($StateRoot).TrimEnd('\')
if ($StateRoot.TrimEnd('\') -eq $driveRoot) { Write-DuetError 'duet: DUET_STATE_ROOT may not be a drive root.'; exit 7 }
if (Test-DuetPathChainHasReparse -Path $StateRoot) { Write-DuetError 'duet: DUET_STATE_ROOT may not contain a reparse point.'; exit 7 }

$WorkdirKey = Get-DuetWorkdirKey $Workdir
if (-not $WorkdirKey) { Write-DuetError 'duet: could not derive the workdir identity.'; exit 7 }
$workdirsDir = Join-Path $StateRoot 'workdirs'
if (-not (Test-Path -LiteralPath $workdirsDir)) { New-Item -ItemType Directory -Path $workdirsDir -Force | Out-Null }
$activeFile = Join-Path $workdirsDir ($WorkdirKey + '.active')
$workdirLock = Join-Path $workdirsDir ($WorkdirKey + '.lock')

$workdirLockHeld = $false
$initComplete = $false
$DuetDir = ''
$ConfigPath = ''
$workers = @()
$activePublished = $false
$currentPublished = $false
$daemonStarted = $false
$finalExit = 0

try {
  if (-not (Lock-DuetAcquire $workdirLock 4000)) { Stop-DuetInit 'duet: another init/end owns the workdir transition lock.' }
  $workdirLockHeld = $true

  $prevRaw = ''
  $predecessorIndexed = $false
  if (Test-Path -LiteralPath $activeFile -PathType Leaf) {
    $prevText = Get-DuetFileText $activeFile
    if (-not $prevText) { Stop-DuetInit 'duet: corrupt empty active-session record.' }
    $prevRaw = $prevText.TrimEnd("`r", "`n")
    if (-not $prevRaw -or $prevRaw -match "[\r\n]") { Stop-DuetInit 'duet: corrupt active-session record.' }
    $predecessorIndexed = $true
  }
  else {
    $prevRaw = Find-DuetPreIndexPredecessor -StateRoot $StateRoot -Workdir $Workdir
    if (-not $script:PredecessorScanValid) { Stop-DuetInit 'duet: live predecessor scan was ambiguous or unsafe.' }
  }
  if ($prevRaw) {
    $prevDir = Get-DuetCanonicalPath $prevRaw
    if (-not $prevDir -or -not (Test-DuetPathUnderRoot -Child $prevDir -Root $StateRoot)) { Stop-DuetInit 'duet: active predecessor is unavailable or outside DUET_STATE_ROOT.' }
    $prevCfgPath = Join-Path $prevDir 'duet.env'
    if (-not (Test-Path -LiteralPath $prevCfgPath -PathType Leaf)) { Stop-DuetInit "duet: active predecessor config is missing: $prevCfgPath" }
    $prev = Import-DuetConfig $prevCfgPath
    if (-not (Test-DuetLoadedSession -Config $prev -ConfigPath $prevCfgPath)) { Stop-DuetInit 'duet: active predecessor config failed validation.' }
    $prevWorkdir = Get-DuetCanonicalPath $prev['WORKDIR']
    if ($prevWorkdir -ne $Workdir) { Stop-DuetInit 'duet: active predecessor claims a different canonical workdir.' }
    Write-Output "duet: reaping same-workdir predecessor $prevDir"
    if (-not (Invoke-DuetReapSession -DuetDir $prevDir -Workdir $prevWorkdir `
        -ExemptPaneId $InitiatorPane -ExemptPanePid $InitiatorPanePid `
        -PsmuxSession $prev['DUET_PSMUX_SESSION'] -PsmuxServerPid $prev['DUET_PSMUX_SERVER_PID'] `
        -PsmuxNamespace $prev['DUET_PSMUX_NAMESPACE'] -PsmuxRegistry $prev['DUET_PSMUX_REGISTRY'])) {
      Stop-DuetInit 'duet: same-workdir predecessor could not be fenced and reaped.'
    }
    if ($predecessorIndexed) {
      $still = Get-DuetFileText $activeFile
      if ($still -and $still.Trim() -eq $prevRaw) { Remove-Item -LiteralPath $activeFile -Force -ErrorAction Stop }
    }
  }

  $created = New-DuetStateDirectory -StateRoot $StateRoot
  if (-not $created -or -not $created.Path) { Stop-DuetInit 'duet: could not allocate a unique session directory.' }
  $DuetDir = $created.Path
  $SessionId = $created.Id
  $ConfigPath = Join-Path $DuetDir 'duet.env'

  New-Item -ItemType Directory -Path (Join-Path $DuetDir 'ready') -Force | Out-Null
  foreach ($queue in @($InitiatorName) + @($specs | ForEach-Object { $_.Name }) + @('leader', 'promotions')) {
    foreach ($sub in @('delivered', 'failed', 'quarantine', 'superseded')) {
      New-Item -ItemType Directory -Path (Join-Path (Join-Path (Join-Path $DuetDir 'inbox') $queue) $sub) -Force | Out-Null
    }
  }
  Write-DuetUtf8NoBom -Path (Join-Path $DuetDir 'transcript.md') -Value ''
  Write-DuetUtf8NoBom -Path (Join-Path $DuetDir 'assignments.md') -Value "# Duet assignments`n`nGeneration 0 leader: $InitiatorName`n"
  if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir "ready\$InitiatorName") -Value 'ok') -or
      -not (Write-DuetLeaderState -DuetDir $DuetDir -Term '0' -Leader $InitiatorName)) {
    Stop-DuetInit 'duet: could not publish initial session state.'
  }

  $briefPath = Join-Path $PluginDir 'briefs\ENSEMBLE_BRIEF.win.md'
  $brief = Get-DuetFileText $briefPath
  if ($null -eq $brief) { Stop-DuetInit 'duet: Windows ensemble brief is missing.' }
  $rendered = $brief.Replace('@DUET_DIR@', $DuetDir).Replace('@PLUGIN@', $PluginDir).Replace('@DUET_SESSION@', $SessionId).Replace('@INITIATOR@', $InitiatorName)
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
    if ($launchValues.Count -ne 1 -or -not [string]$launchValues[0]) { Stop-DuetInit "duet: launch adapter failed for $($spec.Name)." }
    $launcher = Join-Path $DuetDir ("launch-{0}.ps1" -f $spec.Name)
    Write-DuetUtf8NoBom -Path $launcher -Value ([string]$launchValues[0])
    $target = "${PsmuxSession}:${InitiatorPane}"
    $splitArgs = @('split-window')
    if ($i -eq 0) { $splitArgs += '-h' }
    $splitArgs += @('-t', $target, '-P', '-F', '#{pane_id}', '--',
      'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-DuetPsLiteral $launcher))
    $out = @(Invoke-DuetPsmux @splitArgs)
    if ($global:DUET_PSMUX_RC -ne 0 -or $out.Count -eq 0) { Stop-DuetInit "duet: psmux could not launch $($spec.Name)." }
    $line = ([string]$out[-1]).Trim()
    if ($line -notmatch '^%[0-9]+$') { Stop-DuetInit "duet: psmux returned an invalid pane id for $($spec.Name)." }
    $paneId = $line
    $pidOut = @(Invoke-DuetPsmux display-message -p -t "${PsmuxSession}:${paneId}" '#{pane_pid}')
    if ($global:DUET_PSMUX_RC -ne 0 -or $pidOut.Count -ne 1 -or ([string]$pidOut[0]).Trim() -notmatch '^[0-9]+$') {
      Stop-DuetInit "duet: psmux could not resolve the pane pid for $($spec.Name)."
    }
    $panePid = ([string]$pidOut[0]).Trim()
    $worker = [pscustomobject]@{
      Name = $spec.Name; Harness = $spec.Harness; Adapter = $spec.Adapter
      PaneId = $paneId; PanePid = $panePid; Rank = ($i + 1)
      Boot = 'pending'; Kick = 'pending'; Ready = 'no'
    }
    if ($worker.PaneId -eq $InitiatorPane -and $worker.PanePid -eq $InitiatorPanePid) { Stop-DuetInit 'duet: psmux returned the initiating pane as a worker.' }
    $workers += $worker
  }
  Invoke-DuetPsmux select-pane -t "${PsmuxSession}:${InitiatorPane}" | Out-Null
  if ($workers.Count -gt 1) { Invoke-DuetPsmux select-layout -t $PsmuxSession tiled | Out-Null }

  $rosterLines = @('name' + "`t" + 'harness' + "`t" + 'pane_id' + "`t" + 'pane_pid' + "`t" + 'rank' + "`t" + 'spawned')
  $rosterLines += ($InitiatorName, $InitiatorHarness, $InitiatorPane, $InitiatorPanePid, '0', '0') -join "`t"
  foreach ($worker in $workers) { $rosterLines += ($worker.Name, $worker.Harness, $worker.PaneId, $worker.PanePid, [string]$worker.Rank, '1') -join "`t" }
  if (-not (Write-DuetAtomicMultiline -Path (Join-Path $DuetDir 'roster.tsv') -Value ($rosterLines -join "`n"))) { Stop-DuetInit 'duet: could not publish the roster.' }
  $null = @(Import-DuetRoster (Join-Path $DuetDir 'roster.tsv'))
  if (-not $global:DUET_ROSTER_VALID) { Stop-DuetInit 'duet: published roster failed validation.' }

  $configLines = @(
    "DUET_DIR=$DuetDir", "DUET_STATE_ROOT=$StateRoot", "WORKDIR=$Workdir", "PLUGIN_DIR=$PluginDir",
    "DUET_PSMUX_SESSION=$PsmuxSession", "DUET_PSMUX_SERVER_PID=$PsmuxServerPid",
    "DUET_PSMUX_REGISTRY=$PsmuxRegistry", "DUET_PSMUX_NAMESPACE=$PsmuxNamespace",
    "DUET_SESSION=$SessionId", "DUET_SESSION_ID=$SessionId", "DUET_WORKDIR_KEY=$WorkdirKey",
    "DUET_INITIATOR=$InitiatorName", "DUET_INITIATOR_PANE=$InitiatorPane"
  )
  if (-not (Write-DuetAtomicMultiline -Path $ConfigPath -Value ($configLines -join "`n"))) { Stop-DuetInit 'duet: could not publish the session config.' }
  $cfgCheck = Import-DuetConfig $ConfigPath
  if (-not (Test-DuetLoadedSession -Config $cfgCheck -ExpectedSession $SessionId -ConfigPath $ConfigPath)) { Stop-DuetInit 'duet: published session config failed validation.' }

  if (-not (Write-DuetAtomicMultiline -Path $activeFile -Value $DuetDir)) { Stop-DuetInit 'duet: could not publish the workdir owner.' }
  $activePublished = $true
  $currentLock = Join-Path $StateRoot '.current.lock'
  if (-not (Lock-DuetAcquire $currentLock 80)) { Stop-DuetInit 'duet: could not acquire the current-session publication lock.' }
  $currentUnlockOk = $false
  try {
    if (-not (Write-DuetAtomicMultiline -Path (Join-Path $StateRoot 'current.session') -Value $DuetDir)) { Stop-DuetInit 'duet: could not publish current.session.' }
    $currentPublished = $true
  }
  finally { $currentUnlockOk = Unlock-DuetRelease $currentLock }
  if (-not $currentUnlockOk) { Stop-DuetInit 'duet: could not release the current-session publication lock.' }

  $powershell = Resolve-DuetExecutable 'powershell.exe'
  if (-not $powershell) { $powershell = Join-Path $PSHOME 'powershell.exe' }
  $daemon = Join-Path $SelfDir 'duet-deliverd.ps1'
  $daemonArgs = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Session "{1}" -SessionId "{2}"' -f $daemon, $ConfigPath, $SessionId)
  $proc = Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList $daemonArgs -PassThru
  $daemonStarted = $true
  $daemonReady = $false
  for ($i = 0; $i -lt 50; $i++) {
    if (Test-DuetDaemonAlive -DuetDir $DuetDir -SessionId $SessionId) { $daemonReady = $true; break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $daemonReady) { Stop-DuetInit "duet: delivery daemon failed to start; see $DuetDir\deliverd.log" 6 }

  $bootTimeout = 35
  $parsedTimeout = 0
  if ($env:DUET_BOOT_TIMEOUT -and [int]::TryParse($env:DUET_BOOT_TIMEOUT, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) { $bootTimeout = $parsedTimeout }
  if (-not $PSBoundParameters.ContainsKey('ReadyTimeoutSeconds') -and $env:DUET_READY_TIMEOUT -and
      [int]::TryParse($env:DUET_READY_TIMEOUT, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) { $ReadyTimeoutSeconds = $parsedTimeout }
  if ($ReadyTimeoutSeconds -lt 1) { $ReadyTimeoutSeconds = 1 }

  foreach ($worker in $workers) {
    $worker.Boot = 'timeout'
    for ($i = 0; $i -lt $bootTimeout; $i++) {
      $res = Resolve-DuetPaneResolution -PaneId $worker.PaneId -PanePid $worker.PanePid
      if ($res.Known -and -not $res.Alive) { $worker.Boot = 'dead'; break }
      if ($res.Known -and $res.Alive) {
        $cap = @(Invoke-DuetPsmux capture-pane -p -S -200 -t $res.Target)
        if ($global:DUET_PSMUX_RC -eq 0 -and (($cap -join "`n") -match $worker.Adapter['BootRegex'])) { $worker.Boot = 'ready'; break }
      }
      Start-Sleep -Seconds 1
    }
    $readyPath = Join-Path (Join-Path $DuetDir 'ready') $worker.Name
    $readyScript = "Set-Content -LiteralPath $(ConvertTo-DuetPsLiteral $readyPath) -Value ok -NoNewline"
    $readyCommand = 'powershell.exe -NoProfile -EncodedCommand ' + (ConvertTo-DuetPowerShellEncodedCommand $readyScript)
    $kick = "[DUET boot]`nYou are $($worker.Name) (harness: $($worker.Harness)). Read $($worker.Adapter['BriefFile']) and $DuetDir\leader. Confirm readiness now by running exactly this shell command:`n$readyCommand`nThen wait for a task from the leader."
    if (Add-DuetMessage -DuetDir $DuetDir -SessionId $SessionId -Queue $worker.Name -Sender $InitiatorName `
        -Recipient $worker.Name -Term '0' -Mode 'NORMAL' -Origin 'LEADER' -LeaderAtSend $InitiatorName -Body $kick) {
      $worker.Kick = 'queued:' + $global:DUET_ENQUEUED_ID
    }
    else { $worker.Kick = 'failed' }
  }

  for ($i = 0; $i -lt $ReadyTimeoutSeconds; $i++) {
    $notReady = @($workers | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $_.Name)) })
    if ($notReady.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  }

  Write-Output "duet: session $DuetDir"
  Write-Output ('  {0,-12} {1,-8} {2,-6} {3,-10} {4,-35} {5}' -f 'NAME', 'HARNESS', 'PANE', 'BOOT', 'KICK', 'READY')
  $failed = $false
  foreach ($worker in $workers) {
    $worker.Ready = if (Test-Path -LiteralPath (Join-Path (Join-Path $DuetDir 'ready') $worker.Name)) { 'yes' } else { 'no' }
    if ($worker.Ready -ne 'yes') { $failed = $true }
    Write-Output ('  {0,-12} {1,-8} {2,-6} {3,-10} {4,-35} {5}' -f $worker.Name, $worker.Harness, $worker.PaneId, $worker.Boot, $worker.Kick, $worker.Ready)
  }
  $initComplete = $true
  if ($failed) {
    Write-DuetError 'duet: one or more workers did not confirm readiness; session left running for diagnosis.'
    $finalExit = 5
  }
  else {
    Write-Output "duet: all workers READY; leader=$InitiatorName generation=0"
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
    $workersSafe = $false
    if ($daemonStarted) { $daemonSafe = Stop-DuetDaemon -DuetDir $DuetDir -Loops 20 }
    if ($daemonSafe) {
      $daemonLock = Join-Path $DuetDir '.daemon.lock'
      if (Lock-DuetAcquire $daemonLock 22) {
        $daemonUnlockOk = $false
        try { Remove-Item -LiteralPath (Join-Path $DuetDir 'daemon.pid') -Force -ErrorAction SilentlyContinue }
        finally { $daemonUnlockOk = Unlock-DuetRelease $daemonLock }
        if ($daemonUnlockOk) { $workersSafe = Stop-DuetInitWorkers -Workers $workers }
        if (-not $workersSafe) { Write-DuetError 'duet: init cleanup could not prove every worker stopped; ownership pointers were preserved.' }
      }
      else { Write-DuetError 'duet: init cleanup left workers intact because the daemon could not be fenced.' }
    }
    else { Write-DuetError 'duet: init cleanup left workers intact because the daemon could not be stopped.' }

    if ($workersSafe) {
      $activeText = Get-DuetFileText $activeFile
      if (-not $activeText -or $activeText.Trim() -eq $DuetDir) {
        [void](Remove-DuetSessionAnchors -Workdir $Workdir)
        if ($activePublished -and $activeText -and $activeText.Trim() -eq $DuetDir) { Remove-Item -LiteralPath $activeFile -Force -ErrorAction SilentlyContinue }
      }
    }
    if ($workersSafe -and $currentPublished) {
      $currentLock = Join-Path $StateRoot '.current.lock'
      if (Lock-DuetAcquire $currentLock 80) {
        try {
          $currentText = Get-DuetFileText (Join-Path $StateRoot 'current.session')
          if ($currentText -and $currentText.Trim() -eq $DuetDir) { Remove-Item -LiteralPath (Join-Path $StateRoot 'current.session') -Force -ErrorAction SilentlyContinue }
        }
        finally { [void](Unlock-DuetRelease $currentLock) }
      }
    }
  }
  if ($workdirLockHeld -and -not (Unlock-DuetRelease $workdirLock)) {
    Write-DuetError 'duet: could not release the workdir transition lock.'
    if ($finalExit -eq 0) { $finalExit = 7 }
  }
}

exit $finalExit
