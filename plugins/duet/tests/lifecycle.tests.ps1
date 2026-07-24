# Full fake-harness Windows/psmux v4 lifecycle: init, verified delivery,
# diagnostics, recipient failure isolation, and immediate end.
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
    Start-Sleep -Milliseconds 100
  }
  Write-Host "  TIMEOUT $Label" -ForegroundColor Red
  return $false
}

$plugin = Split-Path -Parent $PSScriptRoot
$common = Join-Path $plugin 'scripts\duet-common.ps1'
$initScript = Join-Path $plugin 'scripts\duet-init.ps1'
$sendScript = Join-Path $plugin 'scripts\duet-send.ps1'
$statusScript = Join-Path $plugin 'scripts\duet-status.ps1'
$doctorScript = Join-Path $plugin 'scripts\duet-doctor.ps1'
$endScript = Join-Path $plugin 'scripts\duet-end.ps1'
$fakeHarness = Join-Path $PSScriptRoot 'fixtures\fake-harness.ps1'
. $common
$mux = Get-DuetPsmux
$namespace = 'duetv4m3' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$muxSession = 'lifecycle'
$scratch = Join-Path $env:TEMP ('duet-v4-lifecycle-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $scratch 'state'
$workdir = Join-Path $scratch 'work'
$fakeBin = Join-Path $scratch 'bin'
$acceptRoot = Join-Path $scratch 'accepted'
New-Item -ItemType Directory -Path $stateRoot, $workdir, $fakeBin, $acceptRoot -Force | Out-Null
$duetDir = ''
$configPath = ''
$initiatorPane = ''
$codexPane = ''
$kimiPane = ''

function Invoke-IsolatedMux {
  $argv = @('-L', $namespace) + @($args)
  $output = & $mux @argv 2>$null
  $script:LastMuxRc = $LASTEXITCODE
  return $output
}
function Invoke-PaneCommand {
  param([string]$Pane, [string]$Command, [string]$Label, [int]$TimeoutSeconds = 90)
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
  if (-not (Wait-Until { Test-Path -LiteralPath $donePath } $TimeoutSeconds $Label)) {
    $capture = @(Invoke-IsolatedMux capture-pane -p -S -120 -t "${muxSession}:$Pane")
    throw "$Label command timed out`n$($capture -join "`n")"
  }
  $rc = [int](Get-DuetFileText $donePath).Trim()
  return [pscustomobject]@{ Rc = $rc; Output = (Get-DuetFileText $outputPath) }
}
function DeliveredBody([string]$Name, [string]$Needle) {
  $archive = Join-Path $duetDir "inbox\$Name\delivered"
  if (-not (Test-Path -LiteralPath $archive)) { return $false }
  foreach ($file in @(Get-ChildItem -LiteralPath $archive -Filter '*.msg' -File -ErrorAction SilentlyContinue)) {
    if ((Read-DuetMessage $file.FullName) -and $global:DUET_MESSAGE_BODY.Contains($Needle)) { return $true }
  }
  return $false
}
function Accepted([string]$Name, [string]$Needle) {
  $text = Get-DuetFileText (Join-Path $acceptRoot "$Name.log")
  return [bool]($text -and $text.Contains($Needle))
}

$savedPath = $env:Path
$savedStateRoot = $env:DUET_STATE_ROOT
$savedAcceptRoot = $env:DUET_FAKE_ACCEPT_ROOT
$savedSkipTrust = $env:DUET_CODEX_SKIP_PRETRUST
$savedBootTimeout = $env:DUET_BOOT_TIMEOUT
$savedReadyTimeout = $env:DUET_READY_TIMEOUT
try {
  foreach ($harness in @('claude', 'codex', 'kimi')) {
    $wrapper = Join-Path $fakeBin "$harness.cmd"
    $doctorLine = if ($harness -eq 'kimi') {
      'if /I "%1"=="doctor" exit /b 0'
    } else { '' }
    $content = @(
      '@echo off'
      "set DUET_FAKE_HARNESS=$harness"
      "set DUET_FAKE_ACCEPT_ROOT=$acceptRoot"
      $doctorLine
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakeHarness`" %*"
    ) | Where-Object { $_ }
    [IO.File]::WriteAllLines($wrapper, $content, (New-Object Text.ASCIIEncoding))
  }
  $env:Path = "$fakeBin;$savedPath"
  $env:DUET_STATE_ROOT = $stateRoot
  $env:DUET_FAKE_ACCEPT_ROOT = $acceptRoot
  $env:DUET_CODEX_SKIP_PRETRUST = '1'
  $env:DUET_BOOT_TIMEOUT = '10'
  $env:DUET_READY_TIMEOUT = '20'

  Invoke-IsolatedMux new-session -d -s $muxSession -c $workdir `
    'powershell.exe -NoLogo -NoProfile -NoExit' | Out-Null
  if ($script:LastMuxRc -ne 0) { throw 'could not create lifecycle psmux session' }
  $initiatorPane = ([string](@(Invoke-IsolatedMux display-message -p -t $muxSession '#{pane_id}'))[-1]).Trim()
  # psmux may reuse an already-running backend whose environment predates this
  # test, so make every init dependency explicit inside the initiating pane.
  $initCommand = (
    '$env:Path={0}; $env:DUET_STATE_ROOT={1}; $env:DUET_FAKE_ACCEPT_ROOT={2}; ' +
    '$env:DUET_CODEX_SKIP_PRETRUST=''1''; $env:DUET_BOOT_TIMEOUT=''10''; ' +
    '$env:DUET_READY_TIMEOUT=''20''; ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {3} -Initiator claude codex kimi'
  ) -f (ConvertTo-DuetPsLiteral "$fakeBin;$savedPath"),
    (ConvertTo-DuetPsLiteral $stateRoot), (ConvertTo-DuetPsLiteral $acceptRoot),
    (ConvertTo-DuetPsLiteral $initScript)
  $initResult = Invoke-PaneCommand -Pane $initiatorPane -Command $initCommand -Label init -TimeoutSeconds 90
  Check ($initResult.Rc -eq 0) 'v4 init completes with fake Codex and Kimi peers'
  if ($initResult.Output -match '(?m)^duet: session (.+)$') {
    $duetDir = $Matches[1].Trim()
  }
  Check ([bool]$duetDir -and (Test-Path -LiteralPath $duetDir -PathType Container)) `
    'init reports a durable session directory'
  if (-not $duetDir) { throw "init output did not contain session path`n$($initResult.Output)" }
  $configPath = Join-Path $duetDir 'duet.env'
  $cfg = Import-DuetConfig $configPath
  Check ($global:DUET_CONFIG_VALID -and (Test-DuetLoadedSession -Config $cfg -ConfigPath $configPath)) `
    'init publishes a valid exact v4 config'
  Set-DuetSessionVariables -Config $cfg
  $roster = @(Import-DuetRoster (Join-Path $duetDir 'roster.tsv'))
  Check ($global:DUET_ROSTER_VALID -and ($roster.name -join ',') -eq 'claude,codex-1,kimi-1') `
    'init publishes the expected leaderless roster'
  $codexPane = ($roster | Where-Object { $_.name -eq 'codex-1' }).pane_id
  $kimiPane = ($roster | Where-Object { $_.name -eq 'kimi-1' }).pane_id
  Check (-not (Test-Path -LiteralPath (Join-Path $duetDir 'leader')) -and
      -not (Test-Path -LiteralPath (Join-Path $stateRoot 'current.session')) -and
      -not (Test-Path -LiteralPath (Join-Path $stateRoot 'workdirs'))) `
    'init creates no leader, current pointer, or workdir-owner index'
  Check ((Test-DuetDaemonAlive -DuetDir $duetDir -SessionId $cfg['DUET_SESSION_ID'])) `
    'one delivery daemon is alive'
  Check ((Wait-Until { Accepted codex-1 '[DUET boot]' } 20 'Codex boot delivery') -and
      (Wait-Until { Accepted kimi-1 '[DUET boot]' } 20 'Kimi boot delivery')) `
    'boot kicks use the normal verified-delivery path'

  Write-Host 'lifecycle: verified delivery and diagnostics'
  $deliveryToken = 'FAKE-E2E-' + [guid]::NewGuid().ToString('N')
  $sendCommand = (
    '$env:DUET_SELF=''claude''; $env:DUET_CONFIG={0}; {1} | ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {2} codex-1 -From claude'
  ) -f (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $deliveryToken),
    (ConvertTo-DuetPsLiteral $sendScript)
  $sendResult = Invoke-PaneCommand -Pane $initiatorPane -Command $sendCommand -Label direct-send -TimeoutSeconds 30
  Check ($sendResult.Rc -eq 0 -and $sendResult.Output.Contains('duet: queued')) `
    'initiator publishes a direct message through duet-send'
  Check ((Wait-Until { DeliveredBody codex-1 $deliveryToken } 30 'direct archive') -and
      (Wait-Until { Accepted codex-1 $deliveryToken } 30 'direct fake-TUI acceptance')) `
    'daemon pastes once, submits, and archives verified fake-TUI delivery'

  $broadcastToken = 'FAKE-BROADCAST-' + [guid]::NewGuid().ToString('N')
  $broadcastCommand = (
    '$env:DUET_SELF=''claude''; $env:DUET_CONFIG={0}; {1} | ' +
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {2} all -From claude'
  ) -f (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $broadcastToken),
    (ConvertTo-DuetPsLiteral $sendScript)
  $broadcastResult = Invoke-PaneCommand -Pane $initiatorPane -Command $broadcastCommand -Label broadcast -TimeoutSeconds 30
  Check ($broadcastResult.Rc -eq 0) 'initiator broadcast publishes'
  Check ((Wait-Until { Accepted codex-1 $broadcastToken } 30 'Codex broadcast') -and
      (Wait-Until { Accepted kimi-1 $broadcastToken } 30 'Kimi broadcast')) `
    'broadcast reaches every other fake peer'

  $statusOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $statusScript -Session $configPath 2>&1
  Check ($LASTEXITCODE -eq 0 -and ($statusOutput -join "`n").Contains('initiator   : claude') -and
      -not ($statusOutput -join "`n").Contains('leadership')) `
    'status reports v4 mesh state without an authority role'
  $doctorOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $doctorScript -Session $configPath 2>&1
  Check ($LASTEXITCODE -eq 0 -and ($doctorOutput -join "`n").Contains('doctor: healthy')) `
    'doctor reports the active fake session healthy'

  Write-Host 'lifecycle: recipient-scoped rejection and death'
  $badFile = Join-Path $duetDir 'inbox\codex-1\N-9999999999.msg'
  Write-DuetUtf8NoBom -Path $badFile -Value "DUETv3`ninvalid"
  Check (Wait-Until {
      Test-Path -LiteralPath (Join-Path $duetDir 'inbox\codex-1\rejected\N-9999999999.msg')
    } 20 'malformed rejection') `
    'malformed queue head is rejected without stopping the daemon'
  Check (Test-DuetDaemonAlive -DuetDir $duetDir -SessionId $cfg['DUET_SESSION_ID']) `
    'daemon remains alive after recipient-scoped rejection'

  Invoke-IsolatedMux kill-pane -t "${muxSession}:$kimiPane" | Out-Null
  Check (Wait-Until {
      $r = Get-DuetMemberResolution -RosterPath (Join-Path $duetDir 'roster.tsv') -Name 'kimi-1'
      $r.Known -and -not $r.Alive
    } 10 'Kimi pane death') 'Kimi pane death is confirmed by exact tuple'
  # Stage through the queue primitive: send correctly refuses a dead peer, while
  # the daemon must terminalize an already-published/racing head.
  Set-DuetSessionVariables -Config $cfg
  Check (Add-DuetMessage -DuetDir $duetDir -SessionId $cfg['DUET_SESSION_ID'] `
      -Queue 'kimi-1' -Sender 'claude' -Recipient 'kimi-1' -Mode 'NORMAL' -Body 'raced-death') `
    'a racing head can be staged before the daemon observes death'
  Check (Wait-Until {
      Test-Path -LiteralPath (Join-Path $duetDir 'dead\kimi-1')
    } 20 'dead recipient marker') `
    'daemon surfaces the dead recipient'
  Check (Wait-Until {
      @(Get-ChildItem -LiteralPath (Join-Path $duetDir 'inbox\kimi-1\rejected') -Filter '*.msg' -File |
        Where-Object { (Get-DuetFileText ($_.FullName + '.reason')) -match 'dead' }).Count -gt 0
    } 20 'dead recipient rejection') `
    'message for dead recipient reaches rejected terminal state'
  Check (Test-DuetDaemonAlive -DuetDir $duetDir -SessionId $cfg['DUET_SESSION_ID']) `
    'dead peer does not sink the remaining mesh'

  Write-Host 'lifecycle: immediate isolated teardown'
  $endCommand = '$env:DUET_SELF=''claude''; $env:DUET_CONFIG={0}; powershell.exe -NoProfile -ExecutionPolicy Bypass -File {1}' -f
    (ConvertTo-DuetPsLiteral $configPath), (ConvertTo-DuetPsLiteral $endScript)
  $endResult = Invoke-PaneCommand -Pane $initiatorPane -Command $endCommand -Label end -TimeoutSeconds 45
  Check ($endResult.Rc -eq 0 -and $endResult.Output.Contains('duet: ended')) `
    'any live member can end immediately'
  Check ((Test-Path -LiteralPath (Join-Path $duetDir '.ended')) -and
      -not (Test-DuetDaemonAlive -DuetDir $duetDir -SessionId $cfg['DUET_SESSION_ID'])) `
    'end marks lifecycle terminal and stops the daemon'
  $codexResolution = Resolve-DuetPaneResolution -PaneId $codexPane `
    -PanePid (($roster | Where-Object { $_.name -eq 'codex-1' }).pane_pid)
  $initiatorResolution = Resolve-DuetPaneResolution -PaneId $initiatorPane `
    -PanePid (($roster | Where-Object { $_.name -eq 'claude' }).pane_pid)
  Check ($codexResolution.Known -and -not $codexResolution.Alive -and
      $initiatorResolution.Known -and $initiatorResolution.Alive) `
    'end kills only recorded spawned peers and preserves its caller'
  $agentAnchor = Get-DuetFileText (Join-Path $workdir 'AGENTS.md')
  $claudeAnchor = Get-DuetFileText (Join-Path $workdir 'CLAUDE.md')
  Check (-not ($agentAnchor -and $agentAnchor.Contains('DUET:BEGIN')) -and
      -not ($claudeAnchor -and $claudeAnchor.Contains('DUET:BEGIN'))) `
    'end strips only duet instruction anchors'
  Check (Test-Path -LiteralPath (Join-Path $duetDir 'transcript.md')) `
    'end preserves the transcript'
}
finally {
  $env:Path = $savedPath
  $env:DUET_STATE_ROOT = $savedStateRoot
  $env:DUET_FAKE_ACCEPT_ROOT = $savedAcceptRoot
  $env:DUET_CODEX_SKIP_PRETRUST = $savedSkipTrust
  $env:DUET_BOOT_TIMEOUT = $savedBootTimeout
  $env:DUET_READY_TIMEOUT = $savedReadyTimeout
  if ($duetDir -and (Test-Path -LiteralPath $duetDir)) {
    Write-DuetUtf8NoBom -Path (Join-Path $duetDir '.ended') -Value ''
    $daemonPid = Get-DuetFileText (Join-Path $duetDir 'daemon.pid')
    if ($daemonPid -and (Test-DuetProcessAlive $daemonPid.Trim())) {
      Stop-Process -Id ([int]$daemonPid.Trim()) -Force -ErrorAction SilentlyContinue
    }
  }
  try { Invoke-IsolatedMux kill-server | Out-Null } catch { }
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) `
  -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
