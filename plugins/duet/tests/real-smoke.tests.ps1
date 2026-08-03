# Real Claude/Codex/Kimi Windows/psmux transport smoke.
#
# Claude and Codex must be authenticated. With -AllowUnconfiguredKimi, an
# installed Kimi TUI with no configured model is accepted for transport-only
# coverage; model-executed readiness remains mandatory without that switch.
[CmdletBinding()]
param([switch]$AllowUnconfiguredKimi)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0
$script:Fail = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds, [string]$Label) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 250
  }
  Write-Host "  TIMEOUT $Label" -ForegroundColor Red
  return $false
}

$plugin = Split-Path -Parent $PSScriptRoot
$common = Join-Path $plugin 'scripts\duet-common.ps1'
$initScript = Join-Path $plugin 'scripts\duet-init.ps1'
$sendScript = Join-Path $plugin 'scripts\duet-send.ps1'
$endScript = Join-Path $plugin 'scripts\duet-end.ps1'
. $common

foreach ($required in @('psmux', 'claude', 'codex', 'kimi', 'git')) {
  if (-not (Resolve-DuetExecutable $required)) {
    Write-DuetError "REAL SMOKE FAIL: required command unavailable: $required"
    exit 1
  }
}
$savedProbePreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $kimiProbeOutput = @(& kimi -p 'Reply with exactly KIMI_REAL_SMOKE_OK.' 2>&1)
  $kimiConfigured = ($LASTEXITCODE -eq 0)
}
finally { $ErrorActionPreference = $savedProbePreference }
$kimiExpectedUnconfigured = (-not $kimiConfigured -and
  (($kimiProbeOutput -join "`n") -match 'No model configured'))
if (-not $kimiConfigured -and -not ($AllowUnconfiguredKimi -and $kimiExpectedUnconfigured)) {
  Write-DuetError 'REAL SMOKE FAIL: Kimi has no usable model; authenticate/configure it or pass -AllowUnconfiguredKimi.'
  exit 1
}

$mux = Get-DuetPsmux
$namespace = 'duetv4real' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$muxSession = 'real'
$scratch = Join-Path $env:TEMP ('duet-v4-real-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $scratch 'state'
$workdir = Join-Path $scratch 'work'
$smokeCodexHome = Join-Path $scratch 'codex-home'
New-Item -ItemType Directory -Path $stateRoot, $workdir, $smokeCodexHome -Force | Out-Null
& git -C $workdir init -q
if ($LASTEXITCODE -ne 0) { throw 'could not initialize real-smoke workdir' }
$realCodexHome = if ($env:CODEX_HOME) {
  $env:CODEX_HOME
} elseif ($env:USERPROFILE) {
  Join-Path $env:USERPROFILE '.codex'
} else { '' }
foreach ($file in @('auth.json', 'config.toml', 'models_cache.json', 'version.json')) {
  $source = Join-Path $realCodexHome $file
  if (Test-Path -LiteralPath $source -PathType Leaf) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $smokeCodexHome $file)
  }
}
if (-not (Test-Path -LiteralPath (Join-Path $smokeCodexHome 'auth.json'))) {
  throw "Codex auth unavailable at $realCodexHome"
}
if (-not (Test-Path -LiteralPath (Join-Path $smokeCodexHome 'config.toml'))) {
  Write-DuetUtf8NoBom -Path (Join-Path $smokeCodexHome 'config.toml') -Value ''
}

$duetDir = ''
$configPath = ''
$controllerPane = ''
$daemonPid = 0
$success = $false
function Invoke-IsolatedMux {
  $argv = @('-L', $namespace) + @($args)
  $output = & $mux @argv 2>$null
  $script:LastMuxRc = $LASTEXITCODE
  return $output
}
function Start-PaneCommand {
  param([string]$Pane, [string]$Command, [string]$Label)
  $token = [guid]::NewGuid().ToString('N')
  $outputPath = Join-Path $scratch "$token.out"
  $donePath = Join-Path $scratch "$token.done"
  $wrapped = (
    '& {{ {0} }} *> {1}; $duetPaneRc=$LASTEXITCODE; ' +
    '[IO.File]::WriteAllText({2},[string]$duetPaneRc)'
  ) -f $Command, (ConvertTo-DuetPsLiteral $outputPath), (ConvertTo-DuetPsLiteral $donePath)
  Invoke-IsolatedMux send-keys -t "${muxSession}:$Pane" -l $wrapped | Out-Null
  if ($script:LastMuxRc -ne 0) { throw "could not type $Label command" }
  Invoke-IsolatedMux send-keys -t "${muxSession}:$Pane" Enter | Out-Null
  if ($script:LastMuxRc -ne 0) { throw "could not submit $Label command" }
  return [pscustomobject]@{ Done = $donePath; Output = $outputPath; Label = $Label }
}
function Complete-PaneCommand {
  param($Handle, [int]$TimeoutSeconds)
  if (-not (Wait-Until { Test-Path -LiteralPath $Handle.Done } $TimeoutSeconds $Handle.Label)) {
    $capture = @(Invoke-IsolatedMux capture-pane -p -S -120 -t "${muxSession}:$controllerPane")
    throw "$($Handle.Label) command timed out`n$($capture -join "`n")"
  }
  $rc = [int](Get-DuetFileText $Handle.Done).Trim()
  return [pscustomobject]@{
    Rc = $rc
    Output = [string](Get-DuetFileText $Handle.Output)
  }
}
function Invoke-ControllerCommand {
  param([string]$Command, [string]$Label, [int]$TimeoutSeconds = 90)
  return Complete-PaneCommand (Start-PaneCommand $controllerPane $Command $Label) $TimeoutSeconds
}
function Capture-Member([string]$Pane) {
  return (@(Invoke-IsolatedMux capture-pane -p -S -160 -t "${muxSession}:$Pane") -join "`n")
}
function DeliveredBody([string]$Name, [string]$Needle) {
  $archive = Join-Path $duetDir "inbox\$Name\delivered"
  if (-not (Test-Path -LiteralPath $archive)) { return $false }
  foreach ($file in @(Get-ChildItem -LiteralPath $archive -Filter '*.msg' -File -ErrorAction SilentlyContinue)) {
    if ((Read-DuetMessage $file.FullName) -and $global:DUET_MESSAGE_BODY.Contains($Needle)) { return $true }
  }
  return $false
}

try {
  $versions = "Claude $(& claude --version), Codex $(& codex --version), Kimi $(& kimi --version)"
  Write-Host "real smoke: $versions"
  Invoke-IsolatedMux new-session -d -s $muxSession -c $workdir `
    'powershell.exe -NoLogo -NoProfile -NoExit' | Out-Null
  if ($script:LastMuxRc -ne 0) { throw 'could not create isolated real-smoke psmux session' }
  $controllerPane = ([string](@(
    Invoke-IsolatedMux display-message -p -t $muxSession '#{pane_id}'
  ))[-1]).Trim()

  $currentPath = $env:Path
  $initCommand = (
    '$env:Path={0}; $env:DUET_STATE_ROOT={1}; $env:CODEX_HOME={2}; ' +
    '$env:DUET_CLAUDE_MODEL=''haiku''; ' +
    '$env:DUET_CODEX_REASONING_EFFORT=''low''; ' +
    '$env:DUET_BOOT_TIMEOUT=''25''; $env:DUET_READY_TIMEOUT=''60''; ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {3} ' +
    '-Initiator claude -InitiatorName controller -ReadyTimeoutSeconds 60 claude codex kimi'
  ) -f (ConvertTo-DuetPsLiteral $currentPath), (ConvertTo-DuetPsLiteral $stateRoot),
    (ConvertTo-DuetPsLiteral $smokeCodexHome), (ConvertTo-DuetPsLiteral $initScript)
  $initHandle = Start-PaneCommand $controllerPane $initCommand init

  Check (Wait-Until {
      @(Get-ChildItem -LiteralPath $stateRoot -Directory -ErrorAction SilentlyContinue).Count -eq 1
    } 30 'real session allocation') 'real init allocates one isolated session'
  $sessionDirs = @(Get-ChildItem -LiteralPath $stateRoot -Directory -ErrorAction SilentlyContinue)
  if ($sessionDirs.Count -ne 1) { throw 'real init did not allocate exactly one session' }
  $duetDir = $sessionDirs[0].FullName
  $configPath = Join-Path $duetDir 'duet.env'
  Check (Wait-Until {
      (Test-Path -LiteralPath $configPath) -and
      (Test-Path -LiteralPath (Join-Path $duetDir 'roster.tsv'))
    } 120 'real roster/config publication') 'real init publishes config and roster'

  $cfg = Import-DuetConfig $configPath
  if (-not $global:DUET_CONFIG_VALID -or
      -not (Test-DuetLoadedSession -Config $cfg -ConfigPath $configPath)) {
    throw 'real init published an invalid session config'
  }
  Set-DuetSessionVariables -Config $cfg
  $roster = @(Import-DuetRoster (Join-Path $duetDir 'roster.tsv'))
  Check ($global:DUET_ROSTER_VALID -and
      ($roster.name -join ',') -eq 'controller,claude-1,codex-1,kimi-1') `
    'real Claude, Codex, and Kimi panes have exact roster identities'
  $claudePane = ($roster | Where-Object name -eq 'claude-1').pane_id
  $codexPane = ($roster | Where-Object name -eq 'codex-1').pane_id
  $kimiPane = ($roster | Where-Object name -eq 'kimi-1').pane_id

  $initResult = Complete-PaneCommand $initHandle 180
  Check (($initResult.Output -match '(?m)^\s*claude-1\s+claude\s+%[0-9]+\s+ready\s+') -and
      ($initResult.Output -match '(?m)^\s*codex-1\s+codex\s+%[0-9]+\s+ready\s+') -and
      ($initResult.Output -match '(?m)^\s*kimi-1\s+kimi\s+%[0-9]+\s+ready\s+')) `
    'all three real interactive TUIs reach their boot composers'
  Check (Wait-Until {
      (DeliveredBody claude-1 '[DUET boot]') -and
      (DeliveredBody codex-1 '[DUET boot]') -and
      (DeliveredBody kimi-1 '[DUET boot]')
    } 30 'real boot delivery') 'boot kicks traverse verified delivery to all real TUIs'

  $claudeReady = Test-Path -LiteralPath (Join-Path $duetDir 'ready\claude-1')
  $codexReady = Test-Path -LiteralPath (Join-Path $duetDir 'ready\codex-1')
  $kimiReady = Test-Path -LiteralPath (Join-Path $duetDir 'ready\kimi-1')
  Check ($claudeReady -and $codexReady) 'real Claude and Codex execute their readiness commands'
  if ($kimiReady) {
    Check ($initResult.Rc -eq 0) 'configured real Kimi executes readiness and init succeeds'
  } elseif ($AllowUnconfiguredKimi -and $kimiExpectedUnconfigured) {
    Check ($initResult.Rc -eq 5) 'unconfigured Kimi is surfaced as not ready without hiding the live session'
  } else {
    Check $false 'real Kimi executes readiness (or is explicitly allowed unconfigured)'
  }

  Write-Host 'real smoke: direct and broadcast delivery'
  New-Item -ItemType Directory -Path (Join-Path $duetDir 'blocked') -Force | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $duetDir 'blocked\controller') `
    -Value 'real-smoke controller is a shell, not a prompt TUI' | Out-Null

  $broadcastToken = 'REAL-BROADCAST-' + [guid]::NewGuid().ToString('N')
  $broadcastCommand = (
    '$env:DUET_SELF=''controller''; $env:DUET_CONFIG={0}; {1} | ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {2} all -From controller -Interrupt'
  ) -f (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $broadcastToken),
    (ConvertTo-DuetPsLiteral $sendScript)
  $broadcastResult = Invoke-ControllerCommand $broadcastCommand broadcast
  Check ($broadcastResult.Rc -eq 0 -and
      (Wait-Until {
          (DeliveredBody claude-1 $broadcastToken) -and
          (DeliveredBody codex-1 $broadcastToken) -and
          (DeliveredBody kimi-1 $broadcastToken)
        } 120 'real broadcast delivery')) `
    'interrupt broadcast fans out to every other real TUI and excludes the controller'
  Check (-not (DeliveredBody controller $broadcastToken)) 'broadcast does not enqueue to its sender'

  foreach ($target in @('claude-1', 'codex-1', 'kimi-1')) {
    $token = "REAL-DIRECT-$target-" + [guid]::NewGuid().ToString('N')
    $command = (
      '$env:DUET_SELF=''controller''; $env:DUET_CONFIG={0}; {1} | ' +
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {2} {3} -From controller -Interrupt'
    ) -f (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $token),
      (ConvertTo-DuetPsLiteral $sendScript), (ConvertTo-DuetPsLiteral $target)
    $sendResult = Invoke-ControllerCommand $command "direct-$target"
    Check ($sendResult.Rc -eq 0 -and
        (Wait-Until { DeliveredBody $target $token } 90 "direct delivery to $target")) `
      "controller delivers directly to real $target"
  }

  $replyToken = 'REAL-CODEX-PEER-' + [guid]::NewGuid().ToString('N')
  $replyBody = "Real mesh peer gate. Use PowerShell to send exactly this token and no other text to recipient kimi-1 with the pinned duet-send.ps1 command from AGENTS.md, add -Interrupt, then wait: $replyToken"
  $replyCommand = (
    '$env:DUET_SELF=''controller''; $env:DUET_CONFIG={0}; {1} | ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {2} codex-1 -From controller'
  ) -f (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $replyBody),
    (ConvertTo-DuetPsLiteral $sendScript)
  $replyRequest = Invoke-ControllerCommand $replyCommand codex-reply-request
  Check ($replyRequest.Rc -eq 0 -and
      (Wait-Until { DeliveredBody kimi-1 $replyToken } 240 'real Codex peer send')) `
    'real Codex sends peer-to-peer to real Kimi through duet-send'

  if ($script:Fail) {
    $captureDir = Join-Path $scratch 'captures'
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    foreach ($worker in @($roster | Where-Object spawned -eq '1')) {
      Write-DuetUtf8NoBom -Path (Join-Path $captureDir ($worker.name + '.txt')) `
        -Value (Capture-Member $worker.pane_id)
    }
  }

  Write-Host 'real smoke: immediate teardown'
  $endCommand = (
    '$env:DUET_SELF=''controller''; $env:DUET_CONFIG={0}; ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {1}'
  ) -f (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $endScript)
  $endResult = Invoke-ControllerCommand $endCommand end 120
  Check ($endResult.Rc -eq 0 -and (Test-Path -LiteralPath (Join-Path $duetDir '.ended'))) `
    'real session ends from its live controller member'
  Check (-not (Test-DuetDaemonAlive -DuetDir $duetDir -SessionId $cfg['DUET_SESSION_ID'])) `
    'real session daemon stops'
  foreach ($worker in @($roster | Where-Object spawned -eq '1')) {
    $resolution = Resolve-DuetPaneResolution -PaneId $worker.pane_id -PanePid $worker.pane_pid
    Check ($resolution.Known -and -not $resolution.Alive) "real $($worker.name) pane is reaped"
  }
  $controller = $roster | Where-Object name -eq 'controller'
  $controllerResolution = Resolve-DuetPaneResolution -PaneId $controller.pane_id -PanePid $controller.pane_pid
  Check ($controllerResolution.Known -and $controllerResolution.Alive) `
    'end preserves the exact caller pane'

  $success = ($script:Fail -eq 0)
}
catch {
  Write-Host ($_ | Out-String) -ForegroundColor Red
  $script:Fail++
}
finally {
  if ($duetDir -and (Test-Path -LiteralPath $duetDir)) {
    try { Write-DuetUtf8NoBom -Path (Join-Path $duetDir '.ended') -Value '' } catch { }
    try {
      $cfgCleanup = Import-DuetConfig (Join-Path $duetDir 'duet.env')
      if ($global:DUET_CONFIG_VALID) {
        Set-DuetSessionVariables -Config $cfgCleanup
        Stop-DuetDaemon -DuetDir $duetDir -Loops 30 | Out-Null
      }
    } catch { }
  }
  try { Invoke-IsolatedMux kill-server | Out-Null } catch { }
  if ($success) {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Write-Host "  diagnostics retained: $scratch" -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) `
  -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
