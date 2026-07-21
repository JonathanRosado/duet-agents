# Deterministic + live-psmux failure-path tests for the Windows/psmux foundation.
# Runnable inside OR outside a psmux pane (live assertions skip outside one) and
# under $ErrorActionPreference='Stop' (expected failures must RETURN, not throw).
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File foundation.tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
# Enforce the library failure contract: RETURN falsy, never throw (a regression
# to a terminating Write-Error under Stop is itself a failure, not a pass).
function CheckReturnsFalse([scriptblock]$Block, [string]$Name) {
  try { $r = & $Block; Check (-not $r) $Name }
  catch { Check $false ("$Name (threw instead of returning `$false: " + $_.Exception.Message + ")") }
}
function Skip([string]$Name) { $script:Skip++; Write-Host "  SKIP $Name" -ForegroundColor Yellow }

$common = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1'
. $common
Write-Host "dot-sourced $common"

$haveMux = $true
try { $null = Get-DuetPsmux } catch { $haveMux = $false }
$inPane = [bool]$env:TMUX_PANE
Write-Host ("environment: psmux={0} inPane={1}" -f $haveMux, $inPane)

$scratch = Join-Path $env:TEMP ("duet-ftests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

try {
  # --- 1. StrictMode: optional-global reads must not throw (blocker 1) --------
  if ($haveMux) {
    $threw = $false
    try { $null = Get-DuetPsmux } catch { $threw = $true }
    Check (-not $threw) "Get-DuetPsmux does not throw under StrictMode/Stop"
  } else { Skip "Get-DuetPsmux StrictMode (no psmux binary)" }
  $threw = $false
  try { $null = Test-DuetServerMatches } catch { $threw = $true }
  Check (-not $threw) "Test-DuetServerMatches does not throw with unset globals"
  $fakeMux = Join-Path $scratch 'fake-psmux.cmd'
  Write-DuetUtf8NoBom -Path $fakeMux -Value '@echo %*'
  $savedMuxPath = $global:DUET_PSMUX_PATH
  $savedMuxNs = $global:DUET_PSMUX_NAMESPACE
  $savedMuxReg = $global:DUET_PSMUX_REGISTRY
  try {
    $global:DUET_PSMUX_PATH = $fakeMux
    $global:DUET_PSMUX_NAMESPACE = ''
    $global:DUET_PSMUX_REGISTRY = ''
    $nativeArgs = @(Invoke-DuetPsmux capture-pane -p -t live:1)
    Check ($global:DUET_PSMUX_RC -eq 0 -and ($nativeArgs -join "`n").Trim() -eq 'capture-pane -p -t live:1') "Invoke-DuetPsmux forwards native -p without PowerShell parameter abbreviation"
  }
  catch { Check $false ("Invoke-DuetPsmux native -p binding threw: " + $_.Exception.Message) }
  finally {
    $global:DUET_PSMUX_PATH = $savedMuxPath
    $global:DUET_PSMUX_NAMESPACE = $savedMuxNs
    $global:DUET_PSMUX_REGISTRY = $savedMuxReg
  }
  Check ((Get-DuetClaudeComposerMarker '❯ [Pastedtext#1+5lines]') -eq 'claudePastedtext15lines') "Claude compact collapsed-paste marker is recognized"
  Check ((Get-DuetClaudeComposerMarker '> [Pasted text #12 + 3 lines]') -eq 'claudePastedtext123lines') "Claude spaced collapsed-paste marker is recognized"
  $encodedReady = ConvertTo-DuetPowerShellEncodedCommand "Set-Content -LiteralPath 'C:\odd path & `$cash\ready' -Value ok -NoNewline"
  $decodedReady = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedReady))
  Check ($decodedReady -eq "Set-Content -LiteralPath 'C:\odd path & `$cash\ready' -Value ok -NoNewline") "encoded PowerShell readiness command round-trips shell metacharacters"

  # --- 2. Lock: dead-owner recovery + owner-first publish (blocker 3) ---------
  $lk = Join-Path $scratch '.deadlock'
  New-Item -ItemType Directory -Path $lk | Out-Null
  $deadPid = 999990
  while (Test-DuetProcessAlive $deadPid) { $deadPid++ }
  [System.IO.File]::WriteAllText((Join-Path $lk 'owner'), "$deadPid`tdead-token`n")
  Check (Lock-DuetAcquire $lk 30) "Lock-DuetAcquire reaps a dead-owner lock"
  Check ((Get-DuetLockOwnerPid $lk) -eq "$PID") "reaped lock is now owned by us (never ownerless)"
  Check (Unlock-DuetRelease $lk) "Unlock-DuetRelease releases our lock"
  Check (-not (Test-Path -LiteralPath $lk)) "released lock directory is gone"
  $lk2 = Join-Path $scratch '.livelock'
  New-Item -ItemType Directory -Path $lk2 | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $lk2 'owner'), "$PID`tsomeone-elses-token`n")
  CheckReturnsFalse { Lock-DuetAcquire $lk2 3 } "Lock-DuetAcquire refuses a live foreign-owned lock"

  # --- 3. Workdir key case-insensitivity (blocker 4) -------------------------
  New-Item -ItemType Directory -Path (Join-Path $scratch 'WorkDir') | Out-Null
  $kUpper = Get-DuetWorkdirKey (Join-Path $scratch 'WorkDir')
  $kLower = Get-DuetWorkdirKey (Join-Path $scratch 'workdir')
  Check ($kUpper -and $kUpper -eq $kLower) "workdir key is case-insensitive (one owner per workdir)"
  $sessionIds = @(1..100 | ForEach-Object { New-DuetSessionId })
  Check (@($sessionIds | Sort-Object -Unique).Count -eq 100 -and -not @($sessionIds | Where-Object { $_ -notmatch '^[0-9]{8}-[0-9]{9}-[0-9a-f]{12}$' })) "session ids are unique and filesystem-safe"

  # --- 4-6. Caller identity / resolver / liveness (live psmux) ---------------
  if ($haveMux -and $inPane) {
    Check (Get-DuetCallerIdentity) "Get-DuetCallerIdentity resolves the caller pane by ancestry"
    Check ($global:DUET_CALLER_PANE -eq $env:TMUX_PANE) "ancestry-derived pane_id matches TMUX_PANE ($($global:DUET_CALLER_PANE))"
    Check ($global:DUET_CALLER_SESSION -and $global:DUET_CALLER_SERVER_PID -and $global:DUET_CALLER_PANE_PID) "caller session/serverpid/panepid all populated"
    $sess = $global:DUET_CALLER_SESSION; $srv = $global:DUET_CALLER_SERVER_PID
    $pane = $global:DUET_CALLER_PANE;    $ppid = $global:DUET_CALLER_PANE_PID
    Check ((Resolve-DuetPaneTarget -PaneId $pane -PanePid $ppid -Session $sess -ServerPid $srv) -eq "${sess}:${pane}") "resolver returns bounded target ${sess}:${pane}"
    CheckReturnsFalse { Resolve-DuetPaneTarget -PaneId $pane -PanePid '1' -Session $sess -ServerPid $srv } "resolver refuses a pane_pid mismatch (DEAD)"
    CheckReturnsFalse { Resolve-DuetPaneTarget -PaneId $pane -PanePid $ppid -Session 'no-such-session' -ServerPid $srv } "resolver refuses a foreign session"
    CheckReturnsFalse { Resolve-DuetPaneTarget -PaneId $pane -PanePid $ppid -Session $sess -ServerPid '1' } "resolver refuses a backend-pid mismatch"
    $global:DUET_PSMUX_SESSION = $sess; $global:DUET_PSMUX_SERVER_PID = $srv
    Check (Test-DuetServerMatches) "Test-DuetServerMatches true for the live session tuple"
    $global:DUET_PSMUX_SERVER_PID = '1'
    CheckReturnsFalse { Test-DuetServerMatches } "Test-DuetServerMatches false for a wrong backend pid"
    $global:DUET_PSMUX_SERVER_PID = $srv
    $roster = Join-Path $scratch 'roster.tsv'
    Write-DuetAtomicMultiline -Path $roster -Value ("name`tharness`tpane_id`tpane_pid`trank`tspawned`nclaude`tclaude`t$pane`t$ppid`t0`t0`nghost`tcodex`t%9999`t1`t1`t1") | Out-Null
    Check (Test-DuetMemberAlive -RosterPath $roster -Name 'claude') "Test-DuetMemberAlive true for the real caller tuple"
    CheckReturnsFalse { Test-DuetMemberAlive -RosterPath $roster -Name 'ghost' } "Test-DuetMemberAlive false for a wrong pane_pid"
  } else { Skip "live-psmux caller/resolver/liveness (not in a pane)" }

  # --- 7. Config: current pointer file + validation --------------------------
  $root = Join-Path $scratch 'stateroot'; $sid = 'ftsess'; $sdir = Join-Path $root $sid
  New-Item -ItemType Directory -Path $sdir | Out-Null
  $envFile = Join-Path $sdir 'duet.env'
  $plugin = Get-DuetCanonicalPath (Split-Path -Parent $PSScriptRoot)
  $testWorkdir = Get-DuetCanonicalPath $scratch
  $testWorkdirKey = Get-DuetWorkdirKey $testWorkdir
  Write-DuetAtomicMultiline -Path $envFile -Value ("DUET_DIR=$sdir`nDUET_STATE_ROOT=$root`nWORKDIR=$testWorkdir`nPLUGIN_DIR=$plugin`n" +
    "DUET_PSMUX_SESSION=1`nDUET_PSMUX_SERVER_PID=36928`nDUET_PSMUX_REGISTRY=1`nDUET_PSMUX_NAMESPACE=`n" +
    "DUET_SESSION=$sid`nDUET_SESSION_ID=$sid`nDUET_WORKDIR_KEY=$testWorkdirKey`nDUET_INITIATOR=claude`nDUET_INITIATOR_PANE=%1") | Out-Null
  Write-DuetAtomicMultiline -Path (Join-Path $root 'current.session') -Value $sdir | Out-Null
  $savedRoot = $env:DUET_STATE_ROOT; $savedCfg = $env:DUET_CONFIG; $savedSess = $env:DUET_SESSION
  try {
    $env:DUET_STATE_ROOT = $root; $env:DUET_CONFIG = ''; $env:DUET_SESSION = ''
    Check (Resolve-DuetConfig '' 1) "Resolve-DuetConfig follows the current.session pointer file"
    Check ($global:DUET_RESOLVED_CONFIG -eq $envFile) "current pointer resolved to the right duet.env"
    Check (Resolve-DuetConfig $sid 0) "Resolve-DuetConfig resolves a bare session id under DUET_STATE_ROOT"
    CheckReturnsFalse { Resolve-DuetConfig 'no-such-session' 0 } "Resolve-DuetConfig refuses an unknown session id"
  } finally {
    $env:DUET_STATE_ROOT = $savedRoot; $env:DUET_CONFIG = $savedCfg; $env:DUET_SESSION = $savedSess
  }
  $cfg = Import-DuetConfig $envFile
  Check (Test-DuetLoadedSession -Config $cfg -ExpectedSession $sid -ConfigPath $envFile) "Test-DuetLoadedSession accepts a valid config"
  $duplicateConfig = Join-Path $sdir 'duplicate.env'
  Write-DuetAtomicMultiline -Path $duplicateConfig -Value ((Get-DuetFileText $envFile).TrimEnd() + "`nDUET_SESSION_ID=other") | Out-Null
  $null = Import-DuetConfig $duplicateConfig
  Check (-not $global:DUET_CONFIG_VALID) "config parser rejects duplicate keys instead of taking the last value"
  CheckReturnsFalse { Test-DuetLoadedSession -Config $cfg -ExpectedSession 'other' } "Test-DuetLoadedSession rejects a session-id mismatch"
  $bad = @{ DUET_DIR = "$sdir`twith-tab"; DUET_SESSION_ID = $sid; DUET_SESSION = $sid; DUET_STATE_ROOT = $root }
  CheckReturnsFalse { Test-DuetLoadedSession -Config $bad } "Test-DuetLoadedSession rejects control chars in paths"

  # --- 7b. Mandatory psmux tuple + reparse config validation (review 2) ------
  $noPsmux = @{ DUET_DIR = $sdir; DUET_SESSION_ID = $sid; DUET_SESSION = $sid; DUET_STATE_ROOT = $root }
  CheckReturnsFalse { Test-DuetLoadedSession -Config $noPsmux } "config missing DUET_PSMUX_* is rejected"
  $badSess = @{ DUET_DIR = $sdir; DUET_SESSION_ID = $sid; DUET_SESSION = $sid; DUET_STATE_ROOT = $root; DUET_PSMUX_SESSION = 'a:b'; DUET_PSMUX_SERVER_PID = '10'; DUET_PSMUX_REGISTRY = 'ok' }
  CheckReturnsFalse { Test-DuetLoadedSession -Config $badSess } "config with ':' in psmux session name is rejected"
  $badPid = @{ DUET_DIR = $sdir; DUET_SESSION_ID = $sid; DUET_SESSION = $sid; DUET_STATE_ROOT = $root; DUET_PSMUX_SESSION = '1'; DUET_PSMUX_SERVER_PID = 'x'; DUET_PSMUX_REGISTRY = '1' }
  CheckReturnsFalse { Test-DuetLoadedSession -Config $badPid } "config with non-numeric backend pid is rejected"
  $badReg = @{ DUET_DIR = $sdir; DUET_SESSION_ID = $sid; DUET_SESSION = $sid; DUET_STATE_ROOT = $root; DUET_PSMUX_SESSION = '1'; DUET_PSMUX_SERVER_PID = '10'; DUET_PSMUX_REGISTRY = 'a/b' }
  CheckReturnsFalse { Test-DuetLoadedSession -Config $badReg } "config with unsafe registry base (has /) is rejected"
  $dotted = @{ DUET_DIR = $sdir; DUET_SESSION_ID = $sid; DUET_SESSION = $sid; DUET_STATE_ROOT = $root; WORKDIR = $testWorkdir; PLUGIN_DIR = $plugin; DUET_WORKDIR_KEY = $testWorkdirKey; DUET_INITIATOR = 'claude'; DUET_INITIATOR_PANE = '%1'; DUET_PSMUX_SESSION = 'my.session'; DUET_PSMUX_SERVER_PID = '10'; DUET_PSMUX_REGISTRY = 'ns__my.session'; DUET_PSMUX_NAMESPACE = 'ns' }
  Check (Test-DuetLoadedSession -Config $dotted) "dotted session + namespaced registry accepted (cli.rs:580)"

  # --- 9. Reaper mutex crash/abandon recovery + foreign-holder refusal --------
  $childPs = Join-Path $scratch 'mutexchild.ps1'
  Set-Content -LiteralPath $childPs -Encoding ASCII -Value @'
param([string]$MutexName, [string]$FlagPath, [int]$HoldMs)
$m = New-Object System.Threading.Mutex($false, $MutexName)
[void]$m.WaitOne(3000)
if ($FlagPath) { [System.IO.File]::WriteAllText($FlagPath, '1') }
Start-Sleep -Milliseconds $HoldMs
[Environment]::Exit(0)
'@
  $mlock = Join-Path $scratch '.mlock'
  $mname = Get-DuetMutexName $mlock
  # Child acquires the reaper mutex, then exits WITHOUT releasing (crash sim).
  $c1 = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childPs, '-MutexName', $mname, '-HoldMs', '150' -PassThru -WindowStyle Hidden
  $c1.WaitForExit()
  Check (Lock-DuetReaperAcquire $mlock 2000) "reaper mutex recovers from an abandoned (crashed) holder"
  Lock-DuetReaperRelease $mlock
  # Live foreign holder must block us.
  $flag2 = Join-Path $scratch 'held2.flag'
  $c2 = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childPs, '-MutexName', $mname, '-FlagPath', $flag2, '-HoldMs', '4000' -PassThru -WindowStyle Hidden
  for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath $flag2); $i++) { Start-Sleep -Milliseconds 50 }
  CheckReturnsFalse { Lock-DuetReaperAcquire $mlock 300 } "reaper mutex refuses while a live foreign holder holds it"
  try { Stop-Process -Id $c2.Id -Force -ErrorAction SilentlyContinue } catch { }

  # --- 10. Executable resolution (Process + User + Machine PATH) (blocker 4) --
  Check (($null -ne (Resolve-DuetExecutable 'psmux')) -or ($null -ne (Resolve-DuetExecutable 'tmux'))) "Resolve-DuetExecutable finds psmux/tmux by absolute path"
  Check ($null -eq (Resolve-DuetExecutable 'definitely-not-a-real-exe-xyz-123')) "Resolve-DuetExecutable returns null for a missing exe"
  $kimi = Resolve-DuetExecutable 'kimi'
  if ($kimi) { Write-Host "  INFO kimi resolved -> $kimi" -ForegroundColor Cyan } else { Write-Host "  INFO kimi not resolvable on this host" -ForegroundColor Cyan }

  # --- 11. Reparse-point session dir rejection (best-effort; needs junction) --
  $realDir = Join-Path $scratch 'realsess'
  New-Item -ItemType Directory -Path $realDir | Out-Null
  $jname = 'junc'; $jct = Join-Path $scratch $jname
  $madeJct = $false
  try { New-Item -ItemType Junction -Path $jct -Target $realDir -ErrorAction Stop | Out-Null; $madeJct = $true } catch { }
  if ($madeJct) {
    $rcfg = @{ DUET_DIR = $jct; DUET_SESSION_ID = $jname; DUET_SESSION = $jname; DUET_STATE_ROOT = $scratch; DUET_PSMUX_SESSION = '1'; DUET_PSMUX_SERVER_PID = '10'; DUET_PSMUX_REGISTRY = '1' }
    CheckReturnsFalse { Test-DuetLoadedSession -Config $rcfg } "reparse-point (junction) session directory is rejected"
  } else { Skip "reparse rejection (junction creation unavailable)" }

  # --- 8. Leader state / successor regression --------------------------------
  Write-DuetLeaderState -DuetDir $scratch -Term '0' -Leader 'claude' | Out-Null
  Check ((Read-DuetLeaderState -DuetDir $scratch) -and $global:DUET_CURRENT_LEADER -eq 'claude') "leader state round-trips"
  $rr = Join-Path $scratch 'roster2.tsv'
  Write-DuetAtomicMultiline -Path $rr -Value ("name`tharness`tpane_id`tpane_pid`trank`tspawned`nclaude`tclaude`t%1`t111`t0`t0`ncodex-1`tcodex`t%4`t222`t1`t1`nkimi-1`tkimi`t%7`t333`t2`t1") | Out-Null
  function Test-DuetServerMatches { return $true }
  function Test-DuetMemberAlive { param($RosterPath, $Name) return ($Name -ne 'codex-1') }
  Check ((Select-DuetSuccessor -DuetDir $scratch -RosterPath $rr -Failed 'claude') -and $global:DUET_SUCCESSOR -eq 'kimi-1') "successor skips dead codex-1 -> kimi-1"
  Set-DuetFailedLeader -DuetDir $scratch -Name 'kimi-1' -Term '1' -Reason 'TEST' | Out-Null
  CheckReturnsFalse { Select-DuetSuccessor -DuetDir $scratch -RosterPath $rr -Failed 'claude' } "successor NONE when all excluded/dead"
}
finally {
  try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
