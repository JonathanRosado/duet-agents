# Deterministic v4 daemon tests: fairness, terminal states, and dedupe.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0
$script:Fail = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}

$plugin = Split-Path -Parent $PSScriptRoot
. (Join-Path $plugin 'scripts\duet-common.ps1')
. (Join-Path $plugin 'scripts\duet-deliverd.lib.ps1')
function Test-DuetDaemonAlive { return $true }

$script:DeadPanes = @{}
$script:UnknownPanes = @{}
$script:SendCodes = @{}
$script:Deliveries = @()
function Resolve-DuetPaneResolution {
  param([string]$PaneId, [string]$PanePid, [string]$Session, [string]$ServerPid)
  if ($script:UnknownPanes.ContainsKey($PaneId)) {
    return [pscustomobject]@{ Known = $false; Alive = $false; Target = $null }
  }
  if ($script:DeadPanes.ContainsKey($PaneId)) {
    return [pscustomobject]@{ Known = $true; Alive = $false; Target = $null }
  }
  return [pscustomobject]@{ Known = $true; Alive = $true; Target = "test:$PaneId" }
}
function Send-DuetVerified {
  param([string]$PaneId, [string]$PanePid, [string]$Payload, [bool]$Interrupt,
    [string]$Harness, [string]$Session, [string]$ServerPid, [string]$Registry)
  $code = if ($script:SendCodes.ContainsKey($PaneId)) { [int]$script:SendCodes[$PaneId] } else { 0 }
  $script:Deliveries += [pscustomobject]@{
    Pane = $PaneId
    Payload = $Payload
    Interrupt = $Interrupt
    Code = $code
  }
  return [pscustomobject]@{
    Code = $code
    Collapsed = $false
    LandingObserved = $(if ($code -eq 0) { 'probe' } else { '' })
    EnterToken = ''
    WireOutcome = ''
  }
}

$scratch = Join-Path $env:TEMP ('duet-v4-daemon-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:FixtureNumber = 0
function New-Fixture {
  $script:FixtureNumber++
  $sid = "daemon-v4-$($script:FixtureNumber)"
  $dir = Join-Path $scratch $sid
  foreach ($name in @('claude', 'codex-1', 'kimi-1')) {
    New-Item -ItemType Directory -Path (Join-Path $dir "inbox\$name\delivered"),
      (Join-Path $dir "inbox\$name\rejected") -Force | Out-Null
  }
  Write-DuetUtf8NoBom -Path (Join-Path $dir 'transcript.md') -Value ''
  Write-DuetAtomicMultiline -Path (Join-Path $dir 'roster.tsv') -Value @"
name	harness	pane_id	pane_pid	rank	spawned
claude	claude	%1	101	0	0
codex-1	codex	%2	102	1	1
kimi-1	kimi	%3	103	2	1
"@ | Out-Null
  $global:DUET_DIR = $dir
  $global:DUET_SESSION = $sid
  $global:DUET_SESSION_ID = $sid
  $global:DUET_PSMUX_SESSION = 'test'
  $global:DUET_PSMUX_SERVER_PID = '999'
  $global:DUET_PSMUX_REGISTRY = 'test'
  $global:DUET_PSMUX_NAMESPACE = ''
  $script:DuetNotLanded = @{}
  $script:DeadPanes = @{}
  $script:UnknownPanes = @{}
  $script:SendCodes = @{}
  $script:Deliveries = @()
  return $dir
}
function Enqueue([string]$Queue, [string]$Sender, [string]$Recipient,
    [string]$Mode, [string]$Body) {
  if (-not (Add-DuetMessage -DuetDir $global:DUET_DIR -SessionId $global:DUET_SESSION_ID `
      -Queue $Queue -Sender $Sender -Recipient $Recipient -Mode $Mode -Body $Body)) {
    throw 'fixture enqueue failed'
  }
  return $global:DUET_ENQUEUED_FILE
}
function ActiveCount([string]$Name) {
  return @(Get-ChildItem -LiteralPath (Join-Path $global:DUET_DIR "inbox\$Name") -File |
      Where-Object { $_.Name -match '^[NI]-.*\.msg$' }).Count
}
function DeliveredCount([string]$Name) {
  return @(Get-ChildItem -LiteralPath (Join-Path $global:DUET_DIR "inbox\$Name\delivered") -File |
      Where-Object { $_.Name -match '^[NI]-.*\.msg$' }).Count
}
function RejectedCount([string]$Name) {
  return @(Get-ChildItem -LiteralPath (Join-Path $global:DUET_DIR "inbox\$Name\rejected") -File |
      Where-Object { $_.Name -match '^[NI]-.*\.msg$' }).Count
}

try {
  Write-Host 'daemon: interrupt priority and FIFO'
  $dir = New-Fixture
  $normal = Enqueue codex-1 claude codex-1 NORMAL 'normal-first'
  $interrupt = Enqueue codex-1 claude codex-1 INTERRUPT 'urgent-second'
  Check (Invoke-DuetDeliverdPass) 'interrupt pass succeeds'
  Check ((DeliveredCount codex-1) -eq 1 -and (Test-Path -LiteralPath $normal) -and
      -not (Test-Path -LiteralPath $interrupt)) `
    'interrupt is delivered first while older normal work remains'
  Check ($script:Deliveries[0].Interrupt -and $script:Deliveries[0].Payload.Contains('urgent-second')) `
    'interrupt flag and urgent body reach the verifier'
  Check ((Invoke-DuetDeliverdPass) -and (DeliveredCount codex-1) -eq 2 -and
      (ActiveCount codex-1) -eq 0) `
    'normal FIFO resumes after interrupt'

  Write-Host 'daemon: fair persistent pre-landing stall'
  $dir = New-Fixture
  $script:SendCodes['%2'] = 21
  $env:DUET_NOT_LANDED_LIMIT = '3'
  $null = Enqueue codex-1 claude codex-1 NORMAL 'stalled-head'
  $null = Enqueue codex-1 claude codex-1 NORMAL 'stalled-second'
  $null = Enqueue kimi-1 claude kimi-1 NORMAL 'healthy-1'
  $null = Enqueue kimi-1 claude kimi-1 NORMAL 'healthy-2'
  $null = Enqueue kimi-1 claude kimi-1 NORMAL 'healthy-3'
  1..3 | ForEach-Object { Check (Invoke-DuetDeliverdPass) "fair pass $_ succeeds" }
  Check (Test-Path -LiteralPath (Join-Path $dir 'blocked\codex-1')) `
    'bounded repeated pre-landing failures block only that recipient'
  Check ((ActiveCount codex-1) -eq 2) 'blocked queue remains intact for diagnosis'
  Check ((DeliveredCount kimi-1) -eq 3 -and (ActiveCount kimi-1) -eq 0) `
    'healthy peer advances once during every stalled pass'
  Check (-not (Test-Path -LiteralPath (Join-Path $dir '.unhealthy'))) `
    'recipient stall does not make the session unhealthy'
  $env:DUET_NOT_LANDED_LIMIT = ''

  Write-Host 'daemon: post-paste ambiguity'
  $dir = New-Fixture
  $script:SendCodes['%2'] = 22
  $null = Enqueue codex-1 claude codex-1 NORMAL 'ambiguous'
  $null = Enqueue kimi-1 claude kimi-1 NORMAL 'healthy'
  Check (Invoke-DuetDeliverdPass) 'ambiguous pass continues'
  Check ((Test-Path -LiteralPath (Join-Path $dir 'blocked\codex-1')) -and
      (ActiveCount codex-1) -eq 1) `
    'post-paste ambiguity blocks and retains the exact head'
  Check ((DeliveredCount kimi-1) -eq 1) `
    'another peer delivers in the same ambiguous pass'
  Check (@(Get-ChildItem -LiteralPath (Join-Path $dir 'inbox\codex-1') -Filter '*.phase' -File).Count -eq 0) `
    'no restart or enter-only sidecar is created'

  Write-Host 'daemon: dead recipient and invalid envelope'
  $dir = New-Fixture
  $script:DeadPanes['%2'] = $true
  $null = Enqueue codex-1 claude codex-1 NORMAL 'dead-target'
  $null = Enqueue kimi-1 codex-1 kimi-1 NORMAL 'direct-peer-message'
  Check (Invoke-DuetDeliverdPass) 'dead-peer pass continues'
  Check ((Test-Path -LiteralPath (Join-Path $dir 'dead\codex-1')) -and
      (RejectedCount codex-1) -eq 1) `
    'confirmed-dead peer is surfaced and its head rejected'
  Check ((DeliveredCount kimi-1) -eq 1 -and
      $script:Deliveries[-1].Payload.Contains('from=codex-1 to=kimi-1')) `
    'direct peer-to-peer message is delivered with exact identities'

  $dir = New-Fixture
  $bad = Join-Path $dir 'inbox\codex-1\N-0000000001.msg'
  Write-DuetUtf8NoBom -Path $bad -Value "DUETv3`ninvalid"
  $null = Enqueue kimi-1 claude kimi-1 NORMAL 'healthy'
  Check (Invoke-DuetDeliverdPass) 'malformed-envelope pass continues'
  Check ((RejectedCount codex-1) -eq 1 -and (DeliveredCount kimi-1) -eq 1) `
    'malformed envelope is rejected without sinking another recipient'

  Write-Host 'daemon: stable-id duplicate suppression'
  $dir = New-Fixture
  $first = Enqueue kimi-1 codex-1 kimi-1 NORMAL 'dedupe-body'
  Check (Invoke-DuetDeliverdPass) 'original message delivers'
  $deliveredOriginal = Join-Path $dir ('inbox\kimi-1\delivered\' + (Split-Path -Leaf $first))
  $duplicate = Join-Path $dir 'inbox\kimi-1\N-0000000002.msg'
  Copy-Item -LiteralPath $deliveredOriginal -Destination $duplicate
  $deliveryCountBefore = $script:Deliveries.Count
  Check (Invoke-DuetDeliverdPass) 'duplicate pass succeeds'
  Check ($script:Deliveries.Count -eq $deliveryCountBefore) `
    'already-delivered stable id is not reinjected'
  Check ((Test-Path -LiteralPath (Join-Path $dir 'inbox\kimi-1\delivered\N-0000000002.msg')) -and
      (Get-DuetFileText (Join-Path $dir 'deliverd.log')).Contains('suppressed duplicate')) `
    'duplicate is archived and logged'

  Write-Host 'daemon: session-wide structural failure'
  $dir = New-Fixture
  $ghostBox = Join-Path $dir 'inbox\ghost'
  New-Item -ItemType Directory -Path (Join-Path $ghostBox 'delivered'), (Join-Path $ghostBox 'rejected') -Force | Out-Null
  $body64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ghost'))
  Write-DuetUtf8NoBom -Path (Join-Path $ghostBox 'N-0000000001.msg') -Value @"
DUETv4
id	m-$($global:DUET_SESSION_ID)-ghost-0000000001
session	$($global:DUET_SESSION_ID)
mode	NORMAL
sender	claude
recipient	ghost
body64	$body64
"@
  Check (-not (Invoke-DuetProcessOne -Box $ghostBox)) `
    'non-roster queue is a session-wide structural failure'
  Check (Test-Path -LiteralPath (Join-Path $dir '.unhealthy')) `
    'structural failure writes the unhealthy marker'
}
finally {
  $env:DUET_NOT_LANDED_LIMIT = ''
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) `
  -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
