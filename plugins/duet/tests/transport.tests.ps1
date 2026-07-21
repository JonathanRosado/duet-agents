# Transport regression: the authenticated TCP send-paste path must deliver
# payloads far larger than the ~32,767-char Windows argv ceiling into a pane on a
# DIFFERENT psmux backend, with structured PREWRITE/WIRE_SENT/UNCERTAIN outcomes
# and a port->pid fence. Creates an isolated uniquely-named session and always
# tears it down per-session (never kill-server, never a post-kill bare Stop-Process).
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File transport.tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Check([bool]$Cond, [string]$Name) {
  if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Skip([string]$Name) { $script:Skip++; Write-Host "  SKIP $Name" -ForegroundColor Yellow }

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1')

# --- deterministic: argv ceiling is real, and outcomes are structured ---------
$bigLen = 40000
$b64len = [Convert]::ToBase64String((New-Object byte[] $bigLen)).Length
Check ($b64len -gt 32767) "base64 of ${bigLen}B ($b64len chars) exceeds the ~32767 argv ceiling (TCP route required)"
Check ((Send-DuetControlPaste -Session 'no-such-session-xyz' -PaneId '%9' -PanePid '1' -ServerPid '1' -Payload 'x') -eq $global:DUET_PASTE_PREWRITE_FAILED) "missing registry -> PREWRITE_FAILED (safe)"

$haveMux = $true
try { $null = Get-DuetPsmux } catch { $haveMux = $false }
if (-not $haveMux) { Skip "live TCP transport (no psmux)" }
else {
  $psmux = Get-DuetPsmux
  # Snapshot ambient backend pids so we assert the scratch backend is new,
  # rather than hard-coding a repository-specific pid.
  $ambient = @(& $psmux list-panes -a -F '#{pid}' 2>$null | Sort-Object -Unique)
  $sname = 'duet-xport-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
  $saved = @{}; foreach ($v in 'TMUX', 'TMUX_PANE', 'PSMUX_SESSION', 'PSMUX_TARGET_SESSION') { $saved[$v] = [Environment]::GetEnvironmentVariable($v); [Environment]::SetEnvironmentVariable($v, $null) }
  try {
    & $psmux new-session -d -s $sname -- powershell -NoProfile -NoLogo -NoExit
    $reg = $null
    for ($i = 0; $i -lt 80 -and -not $reg; $i++) { Start-Sleep -Milliseconds 200; $reg = Get-DuetPsmuxRegistry -Registry $sname }
    Check ($null -ne $reg) "scratch session registry (.port/.key) appeared"
    $rec = @(& $psmux list-panes -t $sname -F '#{session_name}|#{pid}|#{pane_id}|#{pane_pid}')
    $p = ($rec | Select-Object -First 1) -split '\|', 4
    $sess = $p[0]; $serverpid = $p[1]; $paneid = $p[2]; $panepid = $p[3]
    Check ($ambient -notcontains $serverpid) "scratch runs on a NEW backend ($serverpid not among ambient)"
    if ($reg) { Check (Test-DuetPortOwner -Port $reg.Port -ExpectedPid $serverpid) "registry port owned by exactly the scratch backend pid" }
    Start-Sleep -Milliseconds 900   # let the REPL settle

    $runid = [guid]::NewGuid().ToString('N').Substring(0, 8)
    # 1. Short probe: prove the TCP path actually delivers content into the pane.
    $probe = "DUETPROBE$runid"
    Check ((Send-DuetControlPaste -Session $sess -PaneId $paneid -PanePid $panepid -ServerPid $serverpid -Payload $probe) -eq $global:DUET_PASTE_WIRE_SENT) "short probe send-paste -> WIRE_SENT"
    Start-Sleep -Milliseconds 1200
    $cap = (@(& $psmux capture-pane -p -t "${sess}:${paneid}") -join '')
    Check ($cap.Contains($probe)) "probe delivered to the pane content (capture-pane)"
    # 2. Large payload: prove the >32K argv-bypass path (with REAL non-ASCII bytes).
    #    Byte-exactness of arbitrary content is covered by queue.tests.ps1's UTF-8
    #    base64 round-trip; full large-composer delivery is in the live-TUI smoke.
    $na = -join ([char]0x00E9, [char]0x2603, [char]0x65E5, [char]0x672C)
    $payload = (('DX' + $runid) * 3000) + $na
    $argvLen = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).Length
    Check ($argvLen -gt 32767) "payload's base64 arg is $argvLen chars (>32767; argv route would fail, TCP required)"
    Check ((Send-DuetControlPaste -Session $sess -PaneId $paneid -PanePid $panepid -ServerPid $serverpid -Payload $payload) -eq $global:DUET_PASTE_WIRE_SENT) "large (base64 $argvLen chars) payload send-paste -> WIRE_SENT"
    Check ((Send-DuetControlPaste -Session $sess -PaneId $paneid -PanePid $panepid -ServerPid '999999' -Payload 'x') -eq $global:DUET_PASTE_PREWRITE_FAILED) "wrong backend pid -> PREWRITE_FAILED (port fence)"
  }
  finally {
    # Unique-session kill only. No post-kill Stop-Process: once kill-session
    # removes the tuple the recorded pane pid is no longer identity-verifiable.
    & $psmux kill-session -t $sname 2>$null | Out-Null
    $gone = -not (@(& $psmux list-sessions -F '#{session_name}' 2>$null) | Where-Object { $_ -eq $sname })
    Check $gone "scratch session torn down (no leak; never kill-server)"
    foreach ($v in 'TMUX', 'TMUX_PANE', 'PSMUX_SESSION', 'PSMUX_TARGET_SESSION') { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
  }
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { exit 0 }
