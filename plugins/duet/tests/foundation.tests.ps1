# Deterministic foundation tests for the Windows/psmux v4 mesh.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
function Check([bool]$Condition, [string]$Name) {
  if ($Condition) {
    $script:Pass++
    Write-Host "  PASS $Name" -ForegroundColor Green
  } else {
    $script:Fail++
    Write-Host "  FAIL $Name" -ForegroundColor Red
  }
}
function CheckFalse([scriptblock]$Block, [string]$Name) {
  try { Check (-not (& $Block)) $Name }
  catch { Check $false "$Name (threw: $($_.Exception.Message))" }
}
function Skip([string]$Name) {
  $script:Skip++
  Write-Host "  SKIP $Name" -ForegroundColor Yellow
}

$plugin = Split-Path -Parent $PSScriptRoot
$common = Join-Path $plugin 'scripts\duet-common.ps1'
. $common
$scratch = Join-Path $env:TEMP ('duet-v4-foundation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$encoding = New-Object Text.UTF8Encoding($false)

try {
  Write-Host 'foundation: psmux invocation and marker scope'
  $fakeMux = Join-Path $scratch 'fake-psmux.cmd'
  Write-DuetUtf8NoBom -Path $fakeMux -Value '@echo %*'
  $savedMuxPath = $global:DUET_PSMUX_PATH
  $savedMuxNs = $global:DUET_PSMUX_NAMESPACE
  $savedMuxReg = $global:DUET_PSMUX_REGISTRY
  try {
    $global:DUET_PSMUX_PATH = $fakeMux
    $global:DUET_PSMUX_NAMESPACE = ''
    $global:DUET_PSMUX_REGISTRY = ''
    $native = @(Invoke-DuetPsmux capture-pane -p -t live:1)
    Check ($global:DUET_PSMUX_RC -eq 0 -and ($native -join "`n").Trim() -eq 'capture-pane -p -t live:1') `
      'Invoke-DuetPsmux preserves native -p and -t arguments'
  }
  finally {
    $global:DUET_PSMUX_PATH = $savedMuxPath
    $global:DUET_PSMUX_NAMESPACE = $savedMuxNs
    $global:DUET_PSMUX_REGISTRY = $savedMuxReg
  }
  Check ((Get-DuetClaudeComposerMarker '> [Pasted text #12 + 3 lines]') -eq 'claudePastedtext123lines') `
    'Claude collapsed-paste marker is normalized'
  $framedClaudeMarker = & {
    . $common
    $composerRule = -join (([char]0x2500).ToString() * 36)
    function Invoke-DuetPaneCapture {
      [pscustomobject]@{
        Ok = $true
        Alive = $true
        Lines = @(
          'older transcript'
          ($composerRule + ' claude-1')
          '> [Pasted text #4 + 5 lines]'
          $composerRule
          'bypass permissions on'
        )
      }
    }
    function Invoke-DuetPaneGeometry {
      throw 'framed composer proof must not depend on cursor geometry'
    }
    function Invoke-DuetPaneRowCapture {
      [pscustomobject]@{ Ok = $true; Alive = $true; Line = 'bypass permissions on' }
    }
    Get-DuetPaneMarker -Session s -ServerPid 1 -PaneId '%1' -PanePid 2 -Harness claude
  }
  Check ($framedClaudeMarker.Ok -and
      $framedClaudeMarker.Marker -eq 'claudePastedtext45lines') `
    'Claude status-row cursor falls back to a composer-border-scoped marker'
  $hintedClaudeMarker = & {
    . $common
    function Invoke-DuetPaneCapture {
      [pscustomobject]@{
        Ok = $true
        Alive = $true
        Lines = @(
          '> [Pastedtext#7+9lines]'
          'paste again to expand'
          '', '', '', '', '', '', '', ''
        )
      }
    }
    function Invoke-DuetPaneGeometry {
      throw 'active composer hint proof must not depend on cursor geometry'
    }
    Get-DuetPaneMarker -Session s -ServerPid 1 -PaneId '%1' -PanePid 2 -Harness claude
  }
  Check ($hintedClaudeMarker.Ok -and
      $hintedClaudeMarker.Marker -eq 'claudePastedtext79lines') `
    'Claude active-composer hint survives trailing blank terminal rows'
  $historyClaudeMarker = & {
    . $common
    function Invoke-DuetPaneCapture {
      [pscustomobject]@{
        Ok = $true
        Alive = $true
        Lines = @('❯ [Pasted text #4 + 5 lines]', 'model output', 'status')
      }
    }
    function Invoke-DuetPaneGeometry {
      [pscustomobject]@{ Ok = $true; Alive = $true; CursorY = '8'; Height = '12' }
    }
    function Invoke-DuetPaneRowCapture {
      [pscustomobject]@{ Ok = $true; Alive = $true; Line = 'status' }
    }
    Get-DuetPaneMarker -Session s -ServerPid 1 -PaneId '%1' -PanePid 2 -Harness claude
  }
  Check ($historyClaudeMarker.Ok -and -not $historyClaudeMarker.Marker) `
    'Claude transcript-only marker is not mistaken for its active composer'
  Check (Test-DuetCodexMarkerOwned 'codexPastedContent10charsPastedContent20chars' 'codexPastedContent10chars') `
    'Codex split collapsed markers extend exact ownership'
  $kimiMarker = & {
    . $common
    function Invoke-DuetPaneCapture {
      [pscustomobject]@{ Ok = $true; Alive = $true; Lines = @('history') }
    }
    function Invoke-DuetPaneGeometry {
      [pscustomobject]@{ Ok = $true; Alive = $true; CursorY = '4'; Height = '10' }
    }
    function Invoke-DuetPaneRowCapture {
      [pscustomobject]@{ Ok = $true; Alive = $true; Line = '> [paste #7 +12 lines]' }
    }
    Get-DuetPaneMarker -Session s -ServerPid 1 -PaneId '%1' -PanePid 2 -Harness kimi
  }
  Check ($kimiMarker.Ok -and $kimiMarker.Marker -eq 'kimipaste712lines') `
    'Kimi collapsed-paste marker is cursor-row scoped'
  $wrongHarness = & {
    . $common
    function Invoke-DuetPaneCapture {
      [pscustomobject]@{ Ok = $true; Alive = $true; Lines = @('history') }
    }
    function Invoke-DuetPaneGeometry {
      [pscustomobject]@{ Ok = $true; Alive = $true; CursorY = '4'; Height = '10' }
    }
    function Invoke-DuetPaneRowCapture {
      [pscustomobject]@{ Ok = $true; Alive = $true; Line = '> [paste #7 +12 lines]' }
    }
    Get-DuetPaneMarker -Session s -ServerPid 1 -PaneId '%1' -PanePid 2 -Harness codex
  }
  Check ($wrongHarness.Ok -and -not $wrongHarness.Marker) `
    'one harness cannot claim another harness marker'

  Write-Host 'foundation: uncertain paste continuation'
  $continued = & {
    . $common
    $script:pasteCalls = 0
    $script:markerReads = 0
    $script:enterCalls = 0
    function Write-DuetError { param([string]$Message) }
    function Resolve-DuetPaneResolution {
      [pscustomobject]@{ Known = $true; Alive = $true; Target = 'fixture:%1' }
    }
    function Send-DuetControlPaste {
      $script:pasteCalls++
      return $global:DUET_PASTE_UNCERTAIN
    }
    function Get-DuetTailAlnumT {
      [pscustomobject]@{ Ok = $true; Alive = $true; Text = '' }
    }
    function Get-DuetPaneMarker {
      $script:markerReads++
      $marker = if ($script:markerReads -eq 2) { 'claudePastedtext15lines' } else { '' }
      [pscustomobject]@{ Ok = $true; Alive = $true; Marker = $marker }
    }
    function Send-DuetPaneKey {
      $script:enterCalls++
      [pscustomobject]@{ Ok = $true; Alive = $true }
    }
    $result = Send-DuetVerified -Session fixture -ServerPid 1 -PaneId '%1' -PanePid 2 `
      -Registry fixture -Payload 'unique uncertain payload' -Interrupt $false -Harness claude
    [pscustomobject]@{
      Code = $result.Code
      Landing = $result.LandingObserved
      PasteCalls = $script:pasteCalls
      EnterCalls = $script:enterCalls
    }
  }
  Check ($continued.Code -eq 0 -and $continued.Landing -eq 'marker') `
    'an uncertain acknowledgment can finish only after visible owned landing clears'
  Check ($continued.PasteCalls -eq 1 -and $continued.EnterCalls -eq 1) `
    'uncertain continuation never repastes and uses one Enter'

  Write-Host 'foundation: exact config pinning'
  $root = Join-Path $scratch 'state'
  $workdir = Join-Path $scratch 'work'
  $sid = 'v4-foundation'
  $sessionDir = Join-Path $root $sid
  New-Item -ItemType Directory -Path $sessionDir, $workdir -Force | Out-Null
  $root = Get-DuetCanonicalPath $root
  $workdir = Get-DuetCanonicalPath $workdir
  $pluginCanonical = Get-DuetCanonicalPath $plugin
  $sessionDir = Get-DuetCanonicalPath $sessionDir
  $configPath = Join-Path $sessionDir 'duet.env'
  $configText = @(
    "DUET_DIR=$sessionDir"
    "DUET_STATE_ROOT=$root"
    "WORKDIR=$workdir"
    "PLUGIN_DIR=$pluginCanonical"
    'DUET_PSMUX_SESSION=v4test'
    'DUET_PSMUX_SERVER_PID=12345'
    'DUET_PSMUX_REGISTRY=v4test'
    'DUET_PSMUX_NAMESPACE='
    "DUET_SESSION=$sid"
    "DUET_SESSION_ID=$sid"
    'DUET_INITIATOR=claude'
    'DUET_INITIATOR_PANE=%1'
  ) -join "`n"
  Write-DuetAtomicMultiline -Path $configPath -Value $configText | Out-Null
  $savedConfig = $env:DUET_CONFIG
  try {
    $env:DUET_CONFIG = ''
    CheckFalse { Resolve-DuetConfig -SessionArg '' -RequireEnvironment 1 } `
      'mutation config resolution rejects an absent DUET_CONFIG'
    Check (Resolve-DuetConfig -SessionArg $configPath -RequireEnvironment 0) `
      'diagnostics accept one explicit absolute duet.env'
    Check ($global:DUET_RESOLVED_CONFIG -eq $configPath) `
      'explicit config resolves to its canonical file'
    CheckFalse { Resolve-DuetConfig -SessionArg $sid -RequireEnvironment 0 } `
      'session-id routing fallback is absent'
    CheckFalse { Resolve-DuetConfig -SessionArg $sessionDir -RequireEnvironment 0 } `
      'session-directory routing fallback is absent'
    $env:DUET_CONFIG = $configPath
    Check (Resolve-DuetConfig -SessionArg '' -RequireEnvironment 1) `
      'mutation resolves the absolute DUET_CONFIG'
    $otherDir = Join-Path $root 'other'
    New-Item -ItemType Directory -Path $otherDir | Out-Null
    $otherConfig = Join-Path $otherDir 'duet.env'
    Write-DuetAtomicMultiline -Path $otherConfig -Value $configText | Out-Null
    CheckFalse { Resolve-DuetConfig -SessionArg $otherConfig -RequireEnvironment 1 } `
      'explicit daemon pin cannot disagree with DUET_CONFIG'
  }
  finally { $env:DUET_CONFIG = $savedConfig }

  $cfg = Import-DuetConfig $configPath
  Check ($global:DUET_CONFIG_VALID -and
      (Test-DuetLoadedSession -Config $cfg -ExpectedSession $sid -ConfigPath $configPath)) `
    'generated v4 config parses and validates'
  $duplicateConfig = Join-Path $sessionDir 'duplicate.env'
  [IO.File]::WriteAllText($duplicateConfig, $configText + "`nDUET_SESSION_ID=other`n", $encoding)
  $null = Import-DuetConfig $duplicateConfig
  Check (-not $global:DUET_CONFIG_VALID) 'config parser rejects duplicate keys'
  $unknownConfig = Join-Path $sessionDir 'unknown.env'
  [IO.File]::WriteAllText($unknownConfig, $configText + "`nLEADER=gone`n", $encoding)
  $null = Import-DuetConfig $unknownConfig
  Check (-not $global:DUET_CONFIG_VALID) 'config parser rejects removed protocol fields'

  Write-Host 'foundation: immutable roster'
  $rosterPath = Join-Path $sessionDir 'roster.tsv'
  $validRoster = @(
    "name`tharness`tpane_id`tpane_pid`trank`tspawned"
    "claude`tclaude`t%1`t101`t0`t0"
    "codex-1`tcodex`t%2`t102`t1`t1"
    "kimi-1`tkimi`t%3`t103`t2`t1"
  ) -join "`n"
  Write-DuetAtomicMultiline -Path $rosterPath -Value $validRoster | Out-Null
  $rows = @(Import-DuetRoster $rosterPath)
  Check ($global:DUET_ROSTER_VALID -and $rows.Count -eq 3) `
    'v4 roster validates three exact members'
  $sixRows = @("name`tharness`tpane_id`tpane_pid`trank`tspawned")
  for ($i = 0; $i -lt 6; $i++) {
    $sixRows += "peer-$i`tcodex`t%$($i + 1)`t$($i + 200)`t$i`t1"
  }
  Write-DuetAtomicMultiline -Path $rosterPath -Value ($sixRows -join "`n") | Out-Null
  $null = @(Import-DuetRoster $rosterPath)
  Check (-not $global:DUET_ROSTER_VALID) 'roster enforces the five-agent cap'
  $caseDuplicate = $validRoster + "`nCLAUDE`tcodex`t%4`t104`t3`t1"
  Write-DuetAtomicMultiline -Path $rosterPath -Value $caseDuplicate | Out-Null
  $null = @(Import-DuetRoster $rosterPath)
  Check (-not $global:DUET_ROSTER_VALID) 'roster names are unique case-insensitively'
  Write-DuetAtomicMultiline -Path $rosterPath -Value $validRoster | Out-Null

  Write-Host 'foundation: DUETv4 envelope'
  $message = Join-Path $sessionDir 'valid.msg'
  $body = "hello Ω`nsecond line"
  $body64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
  $wire = "DUETv4`nid`tm-$sid-codex-1-0000000001`nsession`t$sid`nmode`tNORMAL`nsender`tclaude`nrecipient`tcodex-1`nbody64`t$body64`n"
  [IO.File]::WriteAllText($message, $wire, $encoding)
  Check ((Read-DuetMessage $message) -and $global:DUET_MESSAGE_BODY -eq $body) `
    'valid UTF-8 DUETv4 envelope round-trips'
  $payload = Build-DuetPayload
  Check ($payload.Contains('from=claude to=codex-1') -and $payload.Contains($body)) `
    'delivered payload names exact from and to'
  [IO.File]::WriteAllText($message, $wire.Replace("id`tm-", "id`ta`nid`tm-"), $encoding)
  CheckFalse { Read-DuetMessage $message } 'duplicate fields are rejected'
  [IO.File]::WriteAllText($message, $wire.Replace("body64`t", "unknown`tx`nbody64`t"), $encoding)
  CheckFalse { Read-DuetMessage $message } 'unknown fields are rejected'
  [IO.File]::WriteAllText($message, $wire.Replace('DUETv4', 'DUETv1'), $encoding)
  CheckFalse { Read-DuetMessage $message } 'legacy DUETv1 envelope is rejected'
  $nul64 = [Convert]::ToBase64String([byte[]](65, 0, 66))
  [IO.File]::WriteAllText($message, $wire.Replace($body64, $nul64), $encoding)
  CheckFalse { Read-DuetMessage $message } 'NUL-bearing decoded bodies are rejected'

  Write-Host 'foundation: removed recovery and leadership surfaces'
  foreach ($removedCommand in @(
      'Read-DuetLeaderState', 'Write-DuetLeaderState', 'Invoke-DuetPromoteLocked',
      'Send-DuetEnterOnly', 'Clear-DuetRefusedComposer', 'Invoke-DuetReapSession')) {
    Check (-not (Get-Command $removedCommand -ErrorAction SilentlyContinue)) `
      "$removedCommand is absent"
  }
  Check (-not (Test-Path -LiteralPath (Join-Path $plugin 'scripts\duet-promote.ps1'))) `
    'duet-promote.ps1 is absent'
  Check (-not (Test-Path -LiteralPath (Join-Path $plugin 'scripts\duet-deliverd.process.ps1'))) `
    'restart reconciliation module is absent'
  Check (Test-Path -LiteralPath (Join-Path $plugin 'scripts\duet-ready.ps1')) `
    'authenticated short readiness helper is present'

  Write-Host 'foundation: anchor preservation'
  $anchor = Join-Path $workdir 'AGENTS.md'
  $anchorText = "user-before`n<!-- DUET:BEGIN test -->`nmesh`n<!-- DUET:END -->`nuser-after`n"
  [IO.File]::WriteAllText($anchor, $anchorText, $encoding)
  Check ((Remove-DuetAnchorFile $anchor) -and
      (Get-DuetFileText $anchor).Contains('user-before') -and
      (Get-DuetFileText $anchor).Contains('user-after') -and
      -not (Get-DuetFileText $anchor).Contains('DUET:BEGIN')) `
    'anchor removal preserves surrounding user content'
  $emptyAnchor = Join-Path $workdir 'CLAUDE.md'
  [IO.File]::WriteAllText($emptyAnchor, "<!-- DUET:BEGIN test -->`nmesh`n<!-- DUET:END -->`n", $encoding)
  Check ((Remove-DuetAnchorFile $emptyAnchor) -and (Test-Path -LiteralPath $emptyAnchor)) `
    'anchor removal preserves an otherwise-empty instruction file'

  $haveMux = $true
  try { $null = Get-DuetPsmux } catch { $haveMux = $false }
  if ($haveMux -and $env:TMUX_PANE) {
    Check (Get-DuetCallerIdentity) 'live psmux caller identity resolves by process ancestry'
  } else {
    Skip 'live psmux caller identity (test runner is outside a pane)'
  }
}
finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed, {2} skipped" -f
  $script:Pass, $script:Fail, $script:Skip) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
