# Focused hardening tests for review blockers A (send-FSM UNKNOWN handling) and
# C (strict queue parser + counter/concurrency). Run:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File hardening.tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
$common = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1'
. $common
$enc = New-Object System.Text.UTF8Encoding($false)
function WriteMsg([string]$Path, [string[]]$Lines) { [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc) }

$scratch = Join-Path $env:TEMP ("duet-hard-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

try {
  # =========================================================================
  # C: strict message parser
  # =========================================================================
  $m = Join-Path $scratch 'N-0000000001.msg'
  $okb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("hi"))
  $base = @('DUETv1', "id`tm-s-q-1", "session`ts", "order`t1", "mode`tNORMAL", "sender`tclaude", "recipient`tcodex-1", "term`t0", "origin`tLEADER", "leader_at_send`tclaude", "dedupe`t", "body64`t$okb64")
  WriteMsg $m $base
  Check (Read-DuetMessage $m) "valid DUETv1 message parses"
  WriteMsg $m @('DUETv1', "id`tA", "id`tB", "session`ts", "order`t1", "mode`tNORMAL", "sender`tc", "recipient`tr", "term`t0", "origin`tLEADER")
  Check (-not (Read-DuetMessage $m)) "duplicate known field rejected"
  WriteMsg $m @('DUETv1', "id`tA", "session`ts", "order`t1", "mode`tNORMAL", "sender`tc", "recipient`tr", "term`t0", "origin`tLEADER", "bogus`tx")
  Check (-not (Read-DuetMessage $m)) "unknown field rejected"
  WriteMsg $m @('DUETv1', "id`tA", "session`ts", "order`t1", "mode`tNORMAL", "sender`tc$([char]0x07)x", "recipient`tr", "term`t0", "origin`tLEADER")
  Check (-not (Read-DuetMessage $m)) "control char in a field value rejected"
  $badUtf8 = [Convert]::ToBase64String([byte[]](0xFF, 0xFE, 0xFF, 0x00))
  WriteMsg $m @('DUETv1', "id`tA", "session`ts", "order`t1", "mode`tNORMAL", "sender`tc", "recipient`tr", "term`t0", "origin`tLEADER", "body64`t$badUtf8")
  Check (-not (Read-DuetMessage $m)) "invalid-UTF8 body64 rejected (strict decode)"
  $huge = '9' * 1000
  $hugeMessage = @($base); $hugeMessage[3] = "order`t$huge"
  WriteMsg $m $hugeMessage
  Check (-not (Read-DuetMessage $m)) "oversized numeric message metadata is rejected without throwing"

  # Strict roster/config parsers must not reinterpret corruption as a dead member.
  $strictRoster = Join-Path $scratch 'strict-roster.tsv'
  WriteMsg $strictRoster @("name`tharness`tpane_id`tpane_pid`trank`tspawned", "claude`tclaude`t%1`t111`t0`t0", "dup`tcodex`t%1`t222`t1`t1")
  $null = @(Import-DuetRoster $strictRoster)
  $member = Get-DuetMemberResolution -RosterPath $strictRoster -Name 'claude'
  Check ((-not $global:DUET_ROSTER_VALID) -and (-not $member.Known)) "duplicate roster tuple is invalid and yields UNKNOWN, never DEAD"
  Check ($null -eq (ConvertFrom-DuetDecimal $huge)) "oversized decimal fails closed without a cast exception"

  # Daemon process identity requires exact option values, not path/session substrings.
  $state = Join-Path $scratch 'state & identity'; $dsid = 'identity-session'; $sdir = Join-Path $state $dsid
  New-Item -ItemType Directory -Path $sdir -Force | Out-Null
  $plugin = Get-DuetCanonicalPath (Split-Path -Parent $PSScriptRoot)
  $workdir = Get-DuetCanonicalPath $scratch; $wkey = Get-DuetWorkdirKey $workdir
  $dcfg = Join-Path $sdir 'duet.env'
  Write-DuetAtomicMultiline -Path $dcfg -Value ("DUET_DIR=$sdir`nDUET_STATE_ROOT=$state`nWORKDIR=$workdir`nPLUGIN_DIR=$plugin`n" +
    "DUET_PSMUX_SESSION=1`nDUET_PSMUX_SERVER_PID=1234`nDUET_PSMUX_REGISTRY=1`nDUET_PSMUX_NAMESPACE=`n" +
    "DUET_SESSION=$dsid`nDUET_SESSION_ID=$dsid`nDUET_WORKDIR_KEY=$wkey`nDUET_INITIATOR=claude`nDUET_INITIATOR_PANE=%1") | Out-Null
  $daemonScript = Join-Path $plugin 'scripts\duet-deliverd.ps1'
  $script:CimCommand = ('powershell.exe -NoProfile -File "{0}" -Session "{1}" -SessionId "{2}"' -f $daemonScript, $dcfg, $dsid)
  function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) return [pscustomobject]@{ CommandLine = $script:CimCommand } }
  Check (Test-DuetDaemonProcessMatches -ProcessId 123 -ConfigPath $dcfg -SessionId $dsid) "daemon identity accepts exact script/config/session arguments with metacharacters"
  $script:CimCommand = ('powershell.exe -File "{0}.bak" -Session "{1}" -SessionId "{2}"' -f $daemonScript, $dcfg, $dsid)
  Check (-not (Test-DuetDaemonProcessMatches -ProcessId 123 -ConfigPath $dcfg -SessionId $dsid)) "daemon identity rejects a script-path suffix"
  $script:CimCommand = ('powershell.exe -File "{0}" -Session "{1}.other" -SessionId "{2}"' -f $daemonScript, $dcfg, $dsid)
  Check (-not (Test-DuetDaemonProcessMatches -ProcessId 123 -ConfigPath $dcfg -SessionId $dsid)) "daemon identity rejects a config-path suffix"
  $script:CimCommand = ('powershell.exe -File "{0}" -Session "{1}" -SessionId "{2}-other"' -f $daemonScript, $dcfg, $dsid)
  Check (-not (Test-DuetDaemonProcessMatches -ProcessId 123 -ConfigPath $dcfg -SessionId $dsid)) "daemon identity rejects a session-id suffix"

  $stopRace = & {
    . $common
    $script:aliveChecks = 0
    function Get-DuetFileText { param($Path); if ((Split-Path -Leaf $Path) -eq 'daemon.pid') { return '123' }; return $null }
    function Get-DuetLockOwnerPid { param($Lock); return '123' }
    function Test-DuetProcessAlive { param($ProcessId); $script:aliveChecks++; return ($script:aliveChecks -le 2) }
    function Test-DuetDaemonProcessMatches { param($ProcessId, $ConfigPath, $SessionId); return $false }
    Stop-DuetDaemon -DuetDir $sdir -Loops 1
  }
  Check ([bool]$stopRace) "daemon stop accepts exit between owner check and command-line revalidation"
  $stopMismatch = & {
    . $common
    function Get-DuetFileText { param($Path); if ((Split-Path -Leaf $Path) -eq 'daemon.pid') { return '123' }; return $null }
    function Get-DuetLockOwnerPid { param($Lock); return '123' }
    function Test-DuetProcessAlive { param($ProcessId); return $true }
    function Test-DuetDaemonProcessMatches { param($ProcessId, $ConfigPath, $SessionId); return $false }
    Stop-DuetDaemon -DuetDir $sdir -Loops 1
  }
  Check (-not [bool]$stopMismatch) "daemon stop still rejects a live mismatched process that owns the lock"

  # Actual Unicode + multiline body round-trips byte-for-byte through enqueue.
  function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }
  $duet = Join-Path $scratch 'sess'; New-Item -ItemType Directory -Path $duet | Out-Null
  $uni = (-join ([char]0x00E9, [char]0x2603, [char]0x65E5, [char]0x672C)) + " multi`nline`tpunct!@#"
  Add-DuetMessage -DuetDir $duet -SessionId 'sess' -Queue 'codex-1' -Sender 'claude' -Recipient 'codex-1' -Term '0' -Mode 'NORMAL' -Origin 'LEADER' -LeaderAtSend 'claude' -Body $uni | Out-Null
  Read-DuetMessage $global:DUET_ENQUEUED_FILE | Out-Null
  Check ($global:DUET_MESSAGE_BODY -eq $uni) "actual Unicode + multiline body round-trips byte-for-byte"

  # Archived-counter rollback: a message in an archive with no .counter must refuse.
  $box2 = Join-Path (Join-Path $duet 'inbox') 'archbox'
  New-Item -ItemType Directory -Path (Join-Path $box2 'delivered') -Force | Out-Null
  WriteMsg (Join-Path $box2 'delivered\N-0000000005.msg') $base
  Check (-not (Get-DuetNextSequence -Box $box2)) "missing .counter with an archived message refuses (no rollback collision)"

  # =========================================================================
  # A: send-FSM UNKNOWN handling (stubbed primitives)
  # =========================================================================
  # A3: resolution tri-state (exact per-session query) + no-key-unless-resolved.
  $script:injRc = 0; $script:injOut = @()
  $script:psmuxCalls = @()
  function Invoke-DuetPsmux { $__DuetArgv = @($args); $script:psmuxCalls += , ($__DuetArgv -join ' '); $global:DUET_PSMUX_RC = $script:injRc; return $script:injOut }
  $global:DUET_PSMUX_SESSION = '1'; $global:DUET_PSMUX_SERVER_PID = '36928'
  $script:injRc = 0; $script:injOut = @()
  Check (-not (Test-DuetServerMatches)) "empty successful backend query does not satisfy the server fence"
  $script:injOut = @('36928', '99999')
  Check (-not (Test-DuetServerMatches)) "mixed backend pids do not satisfy the server fence"
  # (i) exact-query FAILURE (rc!=0) => Known=false (UNKNOWN); never asserted dead.
  $script:injRc = 1; $script:injOut = @()
  $res = Resolve-DuetPaneResolution -PaneId '%1' -PanePid '25564' -Session '1' -ServerPid '36928'
  Check ((-not $res.Known) -and (-not $res.Alive)) "exact-query failure => Known=false (UNKNOWN, not dead)"
  # (ii) successful query, tuple ABSENT => Known=true, Alive=false (DEAD).
  $script:injRc = 0; $script:injOut = @('1|36928|%9|99999')
  $res = Resolve-DuetPaneResolution -PaneId '%1' -PanePid '25564' -Session '1' -ServerPid '36928'
  Check ($res.Known -and (-not $res.Alive)) "exact query, tuple absent => Known=true, Alive=false (DEAD)"
  # (iii) successful query, tuple PRESENT => resolved.
  $script:injOut = @('1|36928|%1|25564')
  $res = Resolve-DuetPaneResolution -PaneId '%1' -PanePid '25564' -Session '1' -ServerPid '36928'
  Check ($res.Known -and $res.Alive -and $res.Target -eq '1:%1') "exact query, tuple present => resolved to 1:%1"
  # (iv) Send-DuetPaneKey issues NO key on UNKNOWN, and is not-dead.
  $script:psmuxCalls = @(); $script:injRc = 1
  $k = Send-DuetPaneKey -Session '1' -ServerPid '36928' -PaneId '%1' -PanePid '25564' -Keys @('Enter')
  Check ($k.Alive -and (-not $k.Ok) -and (@($script:psmuxCalls | Where-Object { $_ -like 'send-keys*' }).Count -eq 0)) "Send-DuetPaneKey UNKNOWN => no key issued, not dead"
  # (v) Send-DuetPaneKey issues NO key on DEAD.
  $script:psmuxCalls = @(); $script:injRc = 0; $script:injOut = @('1|36928|%9|9')
  $k = Send-DuetPaneKey -Session '1' -ServerPid '36928' -PaneId '%1' -PanePid '25564' -Keys @('Enter')
  Check ((-not $k.Alive) -and (@($script:psmuxCalls | Where-Object { $_ -like 'send-keys*' }).Count -eq 0)) "Send-DuetPaneKey DEAD => no key issued"

  # Failed interrupt keys must stop before any paste; they are not best-effort.
  function Resolve-DuetPaneResolution { param($PaneId, $PanePid, $Session, $ServerPid) return [pscustomobject]@{ Known = $true; Alive = $true; Target = 's:%1' } }
  $script:pasteCalls = 0
  function Send-DuetControlPaste { $script:pasteCalls++; return $global:DUET_PASTE_WIRE_SENT }
  function Send-DuetPaneKey { param($Session, $ServerPid, $PaneId, $PanePid, $Keys) return [pscustomobject]@{ Alive = $true; Ok = $false } }
  $r = Send-DuetVerified -PaneId '%1' -PanePid '1' -Payload 'interrupt payload' -Interrupt $true -Harness 'claude' -Session 's' -ServerPid '1'
  Check ($r.Code -eq $global:DUET_SEND_NOT_LANDED -and $script:pasteCalls -eq 0) "failed Claude C-c blocks the paste"
  function Invoke-DuetPaneCapture { param($Session, $ServerPid, $PaneId, $PanePid) return [pscustomobject]@{ Alive = $true; Ok = $true; Lines = @('esc to interrupt') } }
  $r = Send-DuetVerified -PaneId '%1' -PanePid '1' -Payload 'interrupt payload' -Interrupt $true -Harness 'codex' -Session 's' -ServerPid '1'
  Check ($r.Code -eq $global:DUET_SEND_NOT_LANDED -and $script:pasteCalls -eq 0) "failed Codex Escape blocks the paste"

  # A1: a FAILED composer read before paste blocks the paste entirely.
  $script:pasteCalls = 0
  function Resolve-DuetPaneResolution { param($PaneId, $PanePid, $Session, $ServerPid) return [pscustomobject]@{ Known = $true; Alive = $true; Target = 's:%1' } }
  function Get-DuetPaneMarker { param($Session, $ServerPid, $PaneId, $PanePid) return [pscustomobject]@{ Ok = $false; Alive = $true; Marker = '' } }
  function Send-DuetControlPaste { $script:pasteCalls++; return $global:DUET_PASTE_WIRE_SENT }
  $r = Send-DuetVerified -PaneId '%1' -PanePid '1' -Payload 'hello world' -Interrupt $false -Harness 'codex' -Session 's' -ServerPid '1'
  Check ($r.Code -eq $global:DUET_SEND_NOT_LANDED -and $script:pasteCalls -eq 0) "failed composer read blocks the paste (NOT_LANDED, 0 pastes)"

  # A2: a capture failure during Enter verification can NEVER produce Code 0.
  $script:tailN = 0
  function Get-DuetPaneMarker { param($Session, $ServerPid, $PaneId, $PanePid) return [pscustomobject]@{ Ok = $true; Alive = $true; Marker = '' } }
  function Get-DuetTailAlnumT {
    param($Session, $ServerPid, $PaneId, $PanePid, $Lines)
    $script:tailN++
    if ($script:tailN -eq 1) { return [pscustomobject]@{ Ok = $true; Alive = $true; Text = 'helloworld' } }  # landing observed once
    return [pscustomobject]@{ Ok = $false; Alive = $true; Text = '' }                                        # then capture keeps failing
  }
  function Send-DuetPaneKey { param($Session, $ServerPid, $PaneId, $PanePid, $Keys) return [pscustomobject]@{ Alive = $true; Ok = $true } }
  function Send-DuetControlPaste { return $global:DUET_PASTE_WIRE_SENT }
  $r = Send-DuetVerified -PaneId '%1' -PanePid '1' -Payload 'hello world' -Interrupt $false -Harness 'codex' -Session 's' -ServerPid '1'
  Check ($r.Code -eq $global:DUET_SEND_LANDED_UNVERIFIED) "capture failure during verify never yields Code 0 (=> LANDED_UNVERIFIED)"

  # A2b: a successful read showing absence DOES yield Code 0 (positive control).
  $script:tailN2 = 0
  function Get-DuetTailAlnumT {
    param($Session, $ServerPid, $PaneId, $PanePid, $Lines)
    $script:tailN2++
    if ($script:tailN2 -eq 1) { return [pscustomobject]@{ Ok = $true; Alive = $true; Text = 'helloworld' } }  # landing
    return [pscustomobject]@{ Ok = $true; Alive = $true; Text = 'promptcleared' }                             # submitted (probe absent)
  }
  $r = Send-DuetVerified -PaneId '%1' -PanePid '1' -Payload 'hello world' -Interrupt $false -Harness 'codex' -Session 's' -ServerPid '1'
  Check ($r.Code -eq 0) "successful read showing probe absent yields Code 0 (submitted)"

  # =========================================================================
  # A1 (concurrency): concurrent producers get unique, contiguous sequences.
  # =========================================================================
  $cbox = Join-Path (Join-Path $duet 'inbox') 'concbox'
  New-Item -ItemType Directory -Path $cbox -Force | Out-Null
  $producer = Join-Path $scratch 'producer.ps1'
  Set-Content -LiteralPath $producer -Encoding ASCII -Value @'
param([string]$Common, [string]$Duet, [int]$N)
. $Common
function Test-DuetDaemonAlive { param($DuetDir, $SessionId) return $true }
for ($i = 0; $i -lt $N; $i++) {
  Add-DuetMessage -DuetDir $Duet -SessionId 'sess' -Queue 'concbox' -Sender 'claude' -Recipient 'concbox' -Term '0' -Mode 'NORMAL' -Origin 'LEADER' -LeaderAtSend 'claude' -Body "p$PID-$i" | Out-Null
}
'@
  $procs = @()
  for ($p = 0; $p -lt 4; $p++) { $procs += Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $producer, $common, $duet, '5' -PassThru -WindowStyle Hidden }
  foreach ($pr in $procs) { $pr.WaitForExit() }
  $seqs = @(Get-ChildItem -LiteralPath $cbox -Filter 'N-*.msg' -File | ForEach-Object { [int]($_.BaseName -replace '^N-', '') } | Sort-Object)
  $unique = @($seqs | Sort-Object -Unique)
  Check ($seqs.Count -eq 20 -and $unique.Count -eq 20) "4x5 concurrent producers -> 20 unique sequences (no dup/loss)"
  Check (($seqs -join ',') -eq ((1..20) -join ',')) "concurrent sequences are contiguous 1..20 (atomic counter)"
}
finally { try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
