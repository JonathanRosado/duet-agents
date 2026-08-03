# Live-psmux v4 mesh routing and sender-auth gate. Delivery is intentionally
# paused after the daemon's first empty pass so this suite can inspect queues.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0
$script:Fail = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}

$plugin = Split-Path -Parent $PSScriptRoot
$common = Join-Path $plugin 'scripts\duet-common.ps1'
$sendScript = Join-Path $plugin 'scripts\duet-send.ps1'
$daemonScript = Join-Path $plugin 'scripts\duet-deliverd.ps1'
. $common
$mux = Get-DuetPsmux
$namespace = 'duetv4m2' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$muxSession = 'm2'
$registry = "${namespace}__${muxSession}"
$sid = 'm2-session'
$scratch = Join-Path $env:TEMP ('duet-v4-mesh-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $scratch 'state'
$workdir = Join-Path $scratch 'work'
$duetDir = Join-Path $stateRoot $sid
$configPath = Join-Path $duetDir 'duet.env'
$daemonProcess = $null
New-Item -ItemType Directory -Path $duetDir, $workdir -Force | Out-Null

function Invoke-IsolatedMux {
  $argv = @('-L', $namespace) + @($args)
  $output = & $mux @argv 2>$null
  $script:LastMuxRc = $LASTEXITCODE
  return $output
}
function ActiveCount([string]$Name) {
  return @(Get-ChildItem -LiteralPath (Join-Path $duetDir "inbox\$Name") -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^[NI]-.*\.msg$' }).Count
}
function Invoke-SendAs {
  param(
    [string]$Actor,
    [string]$SelfName,
    [string]$Recipient,
    [string]$Body,
    [string]$From = ''
  )
  $row = Get-DuetRosterRow -RosterPath (Join-Path $duetDir 'roster.tsv') -Name $Actor
  if (-not $row) { throw "missing actor $Actor" }
  $token = [guid]::NewGuid().ToString('N')
  $outputPath = Join-Path $scratch "$token.out"
  $donePath = Join-Path $scratch "$token.done"
  $fromArgs = if ($From) { ' -From ' + (ConvertTo-DuetPsLiteral $From) } else { '' }
  $command = (
    '$env:DUET_SELF={0}; $env:DUET_CONFIG={1}; $env:DUET_SESSION={2}; ' +
    '{3} | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File {4} {5}{6} *> {7}; ' +
    '$duetRc=$LASTEXITCODE; [IO.File]::WriteAllText({8},[string]$duetRc)'
  ) -f (ConvertTo-DuetPsLiteral $SelfName), (ConvertTo-DuetPsLiteral $configPath),
    (ConvertTo-DuetPsLiteral $sid), (ConvertTo-DuetPsLiteral $Body),
    (ConvertTo-DuetPsLiteral $sendScript), (ConvertTo-DuetPsLiteral $Recipient),
    $fromArgs, (ConvertTo-DuetPsLiteral $outputPath), (ConvertTo-DuetPsLiteral $donePath)
  Invoke-IsolatedMux send-keys -t "${muxSession}:$($row.pane_id)" -l $command | Out-Null
  if ($script:LastMuxRc -ne 0) { throw "could not type send command into $Actor" }
  Invoke-IsolatedMux send-keys -t "${muxSession}:$($row.pane_id)" Enter | Out-Null
  for ($i = 0; $i -lt 200 -and -not (Test-Path -LiteralPath $donePath); $i++) {
    Start-Sleep -Milliseconds 50
  }
  if (-not (Test-Path -LiteralPath $donePath)) {
    $capture = @(Invoke-IsolatedMux capture-pane -p -S -80 -t "${muxSession}:$($row.pane_id)")
    throw "send command timed out in $Actor`n$($capture -join "`n")"
  }
  $rc = [int](Get-DuetFileText $donePath).Trim()
  $output = Get-DuetFileText $outputPath
  return [pscustomobject]@{ Rc = $rc; Output = $output }
}

try {
  Invoke-IsolatedMux new-session -d -s $muxSession 'powershell.exe -NoLogo -NoProfile -NoExit' | Out-Null
  if ($script:LastMuxRc -ne 0) { throw 'could not create isolated psmux session' }
  $claudePane = ([string](@(Invoke-IsolatedMux display-message -p -t $muxSession '#{pane_id}'))[-1]).Trim()
  $codexPane = ([string](@(Invoke-IsolatedMux split-window -d -P -F '#{pane_id}' -t $muxSession 'powershell.exe -NoLogo -NoProfile -NoExit'))[-1]).Trim()
  $kimiPane = ([string](@(Invoke-IsolatedMux split-window -d -P -F '#{pane_id}' -t $muxSession 'powershell.exe -NoLogo -NoProfile -NoExit'))[-1]).Trim()
  $paneRecords = @{}
  foreach ($record in @(Invoke-IsolatedMux list-panes -s -t $muxSession -F '#{pane_id}|#{pane_pid}|#{pid}')) {
    $parts = ([string]$record).Split('|')
    if ($parts.Count -eq 3) { $paneRecords[$parts[0]] = $parts }
  }
  $serverPid = $paneRecords[$claudePane][2]

  foreach ($name in @('claude', 'codex-1', 'kimi-1')) {
    New-Item -ItemType Directory -Path (Join-Path $duetDir "inbox\$name\delivered"),
      (Join-Path $duetDir "inbox\$name\rejected") -Force | Out-Null
    Write-DuetAtomicMultiline -Path (Join-Path $duetDir "ready\$name") -Value ok | Out-Null
  }
  Write-DuetUtf8NoBom -Path (Join-Path $duetDir 'transcript.md') -Value ''
  Write-DuetAtomicMultiline -Path (Join-Path $duetDir 'roster.tsv') -Value @"
name	harness	pane_id	pane_pid	rank	spawned
claude	claude	$claudePane	$($paneRecords[$claudePane][1])	0	0
codex-1	codex	$codexPane	$($paneRecords[$codexPane][1])	1	1
kimi-1	kimi	$kimiPane	$($paneRecords[$kimiPane][1])	2	1
"@ | Out-Null
  $stateRoot = Get-DuetCanonicalPath $stateRoot
  $workdir = Get-DuetCanonicalPath $workdir
  $duetDir = Get-DuetCanonicalPath $duetDir
  $configPath = Join-Path $duetDir 'duet.env'
  Write-DuetAtomicMultiline -Path $configPath -Value @"
DUET_DIR=$duetDir
DUET_STATE_ROOT=$stateRoot
WORKDIR=$workdir
PLUGIN_DIR=$(Get-DuetCanonicalPath $plugin)
DUET_PSMUX_SESSION=$muxSession
DUET_PSMUX_SERVER_PID=$serverPid
DUET_PSMUX_REGISTRY=$registry
DUET_PSMUX_NAMESPACE=$namespace
DUET_SESSION=$sid
DUET_SESSION_ID=$sid
DUET_INITIATOR=claude
DUET_INITIATOR_PANE=$claudePane
"@ | Out-Null

  $global:DUET_PSMUX_SESSION = $muxSession
  $global:DUET_PSMUX_SERVER_PID = $serverPid
  $global:DUET_PSMUX_NAMESPACE = $namespace
  $global:DUET_PSMUX_REGISTRY = $registry
  $savedConfig = $env:DUET_CONFIG
  $savedSession = $env:DUET_SESSION
  $savedPoll = $env:DUET_DELIVERY_POLL_INTERVAL
  try {
    $env:DUET_CONFIG = $configPath
    $env:DUET_SESSION = $sid
    $env:DUET_DELIVERY_POLL_INTERVAL = '30'
    $daemonArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Session "{1}" -SessionId "{2}"' -f
      $daemonScript, $configPath, $sid
    $daemonProcess = Start-Process powershell.exe -ArgumentList $daemonArgs -WindowStyle Hidden -PassThru
  }
  finally {
    $env:DUET_CONFIG = $savedConfig
    $env:DUET_SESSION = $savedSession
    $env:DUET_DELIVERY_POLL_INTERVAL = $savedPoll
  }
  $daemonReady = $false
  for ($i = 0; $i -lt 100; $i++) {
    if (Test-DuetDaemonAlive -DuetDir $duetDir -SessionId $sid) { $daemonReady = $true; break }
    if ($daemonProcess.HasExited) { break }
    Start-Sleep -Milliseconds 50
  }
  Check $daemonReady 'isolated v4 daemon starts with exact namespace/session identity'
  if (-not $daemonReady) { throw 'daemon failed to start' }

  Write-Host 'mesh: any-to-any direct enqueue'
  Check ((Invoke-SendAs codex-1 codex-1 kimi-1 'codex-to-kimi' codex-1).Rc -eq 0) `
    'codex-1 can send directly to kimi-1'
  Check ((Invoke-SendAs kimi-1 kimi-1 codex-1 'kimi-to-codex' kimi-1).Rc -eq 0) `
    'kimi-1 can send directly to codex-1'
  Check ((Invoke-SendAs codex-1 codex-1 claude 'codex-to-claude' codex-1).Rc -eq 0) `
    'codex-1 can send directly to initiator'
  Check ((ActiveCount kimi-1) -eq 1 -and (ActiveCount codex-1) -eq 1 -and
      (ActiveCount claude) -eq 1) `
    'direct messages land in three exact recipient queues'
  $directFile = Join-Path $duetDir 'inbox\kimi-1\N-0000000001.msg'
  Check ((Read-DuetMessage $directFile) -and
      $global:DUET_MESSAGE_SENDER -eq 'codex-1' -and
      $global:DUET_MESSAGE_RECIPIENT -eq 'kimi-1') `
    'direct DUETv4 wire identity is exact'
  $keys = @((Get-DuetFileText $directFile) -split "`r?`n" |
      Where-Object { $_ } |
      ForEach-Object { if ($_ -eq 'DUETv4') { $_ } else { ($_ -split "`t", 2)[0] } })
  Check (($keys -join ',') -eq 'DUETv4,id,session,mode,sender,recipient,body64') `
    'wire schema contains only the minimal v4 fields'

  Write-Host 'mesh: broadcast and sender authorization'
  $before = @{
    claude = ActiveCount claude
    codex = ActiveCount codex-1
    kimi = ActiveCount kimi-1
  }
  Check ((Invoke-SendAs codex-1 codex-1 all 'broadcast-body' codex-1).Rc -eq 0) `
    'any member may broadcast'
  Check ((ActiveCount codex-1) -eq $before.codex -and
      (ActiveCount claude) -eq ($before.claude + 1) -and
      (ActiveCount kimi-1) -eq ($before.kimi + 1)) `
    'broadcast excludes sender and fans out to every other live member'
  $broadcastFiles = @(
    (Get-ChildItem -LiteralPath (Join-Path $duetDir 'inbox\claude') -Filter 'N-*.msg' -File | Sort-Object Name | Select-Object -Last 1),
    (Get-ChildItem -LiteralPath (Join-Path $duetDir 'inbox\kimi-1') -Filter 'N-*.msg' -File | Sort-Object Name | Select-Object -Last 1)
  )
  $broadcastValid = $true
  foreach ($file in $broadcastFiles) {
    if (-not (Read-DuetMessage $file.FullName) -or $global:DUET_MESSAGE_RECIPIENT -ne 'all') {
      $broadcastValid = $false
    }
  }
  Check $broadcastValid 'broadcast fanout retains wire recipient all'

  Check ((Invoke-SendAs codex-1 codex-1 kimi-1 'spoof-from' kimi-1).Rc -eq 7) `
    'caller pane cannot spoof -From'
  Check ((Invoke-SendAs codex-1 kimi-1 kimi-1 'spoof-self').Rc -eq 7) `
    'caller pane cannot spoof DUET_SELF'
  Check ((Invoke-SendAs codex-1 codex-1 kimi 'alias').Rc -eq 2) `
    'harness alias is not accepted as a roster name'

  New-Item -ItemType Directory -Path (Join-Path $duetDir 'blocked') -Force | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $duetDir 'blocked\kimi-1') -Value blocked | Out-Null
  $claudeBefore = ActiveCount claude
  $kimiBefore = ActiveCount kimi-1
  Check ((Invoke-SendAs codex-1 codex-1 all 'skip-blocked').Rc -eq 0) `
    'broadcast remains valid with one blocked peer'
  Check ((ActiveCount claude) -eq ($claudeBefore + 1) -and
      (ActiveCount kimi-1) -eq $kimiBefore) `
    'broadcast skips blocked peer'
  Remove-Item -LiteralPath (Join-Path $duetDir 'blocked\kimi-1') -Force

  $runtimeFiles = @(
    'duet-common.ps1', 'duet-send.ps1', 'duet-deliverd.ps1',
    'duet-deliverd.lib.ps1', 'duet-init.ps1', 'duet-status.ps1',
    'duet-doctor.ps1', 'duet-end.ps1', 'duet-ready.ps1'
  ) | ForEach-Object { Join-Path $plugin "scripts\$_" }
  $removedAuthorityPattern =
    'Read-DuetLeader|Write-DuetLeader|duet-promote|current\.session|\.draining|\.admission|handoff_mode|leader_at_send'
  $authority = @(Select-String -Path $runtimeFiles -Pattern $removedAuthorityPattern)
  Check ($authority.Count -eq 0) 'runtime contains no v3 authority, pointer, or drain surface'
}
finally {
  if ($duetDir -and (Test-Path -LiteralPath $duetDir)) {
    Write-DuetUtf8NoBom -Path (Join-Path $duetDir '.ended') -Value ''
  }
  if ($daemonProcess -and -not $daemonProcess.HasExited) {
    Stop-Process -Id $daemonProcess.Id -Force -ErrorAction SilentlyContinue
    $daemonProcess.WaitForExit()
  }
  try { Invoke-IsolatedMux kill-server | Out-Null } catch { }
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) `
  -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
