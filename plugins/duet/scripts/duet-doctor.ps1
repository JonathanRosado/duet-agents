# duet-doctor.ps1 - inspect duet panes, flag orphaned agents, optionally reap them.
# Read-only by default; pass -Reap to kill orphaned Codex agent panes that do not
# belong to the current session (issue #3).
[CmdletBinding()]
param(
  [string]$Config,
  [switch]$Reap
)

$ErrorActionPreference = "Stop"
$SelfDir = Split-Path -Parent $PSCommandPath
. (Join-Path $SelfDir "duet-common.ps1")

$psmux = Get-DuetPsmux

$cfg = $null
try { $cfg = Import-DuetConfig -Path $Config } catch { }

$curClaude = if ($cfg) { $cfg.CLAUDE_PANE } else { "" }
$curCodex  = if ($cfg) { $cfg.CODEX_PANE }  else { "" }
$selfPane  = $env:TMUX_PANE

Write-Host "=== duet doctor ==="
if ($cfg) {
  Write-Host "current session : $($cfg.DUET_DIR)"
  Write-Host "  claude pane   : $curClaude (pid $($cfg.CLAUDE_PANE_PID))"
  Write-Host "  codex pane    : $curCodex (pid $($cfg.CODEX_PANE_PID))"
  Write-Host "  relay         : $(if ($cfg.DUET_RELAY) { 'on' } else { 'off (direct send)' })"
  Write-Host "  pending c->c  : $(Get-DuetPendingCount -Dir $cfg.DUET_DIR)"
} else {
  Write-Host "current session : (none - no ~/.duet/current.env.ps1)"
}
Write-Host ""

$records = @(Get-DuetPaneRecords)
Write-Host "--- all panes (list-panes -a) ---"

function Test-DuetLooksLikeAgent {
  param($Rec)
  $s = ("" + $Rec.Start).ToLowerInvariant()
  $c = ("" + $Rec.Cmd).ToLowerInvariant()
  return ($c -eq "codex" -or $c -eq "node" -or
          $s.Contains("codex") -or $s.Contains(".duet") -or $s.Contains("--add-dir"))
}

$orphans = @()
foreach ($r in $records) {
  $tags = @()
  if ($r.Id -eq $curClaude) { $tags += "current-claude" }
  if ($r.Id -eq $curCodex)  { $tags += "current-codex" }
  if ($r.Id -eq $selfPane)  { $tags += "this-pane" }
  $isAgent = Test-DuetLooksLikeAgent -Rec $r
  $isCurrent = ($r.Id -eq $curClaude -or $r.Id -eq $curCodex)
  if ($isAgent -and -not $isCurrent -and $r.Id -ne $selfPane) {
    $tags += "ORPHAN?"
    $orphans += $r
  }
  $tagStr = if ($tags.Count) { "  [" + ($tags -join ",") + "]" } else { "" }
  $startShort = ("" + $r.Start)
  if ($startShort.Length -gt 70) { $startShort = $startShort.Substring(0, 70) + "..." }
  Write-Host ("  {0,-5} pid={1,-8} cmd={2,-12} {3}{4}" -f $r.Id, $r.Pid, $r.Cmd, $startShort, $tagStr)
}
Write-Host ""

if ($orphans.Count -eq 0) {
  Write-Host "No orphaned agent panes detected."
  exit 0
}

Write-Host "Found $($orphans.Count) possible orphaned agent pane(s): $((($orphans | ForEach-Object { $_.Id }) -join ', '))"
if (-not $Reap) {
  Write-Host "Re-run with -Reap to kill them. (Never kills the current session's panes or this pane.)"
  exit 0
}

# Reap at the OS-process level, not the pane level. On the Windows/psmux build a
# recycled/aliased pane id makes `kill-pane` misroute onto the live Claude pane
# (it can tear down this very session); Stop-Process on the pane's foreground pid
# is precise and cannot misroute. We never touch a pid that is the current Claude,
# a multiplexer, or an ancestor of a protected pane (see Test-DuetPidProtected).
$table = Get-DuetProcessTable
$protected = @($PID)
foreach ($pane in @($selfPane, $curClaude, $curCodex)) {
  if (-not $pane) { continue }
  foreach ($p in @(Get-DuetPanePidSet -Pane $pane)) {
    $n = 0; if ([int]::TryParse($p, [ref]$n)) { $protected += $n }
  }
}
foreach ($o in $orphans) {
  Write-Host "reaping $($o.Id) (pid $($o.Pid), $($o.Cmd)) ..."
  $killed = @(); $spared = @()
  foreach ($p in ($o.Pid -split '\s+')) {
    $n = 0
    if (-not [int]::TryParse($p, [ref]$n)) { continue }
    if (Test-DuetPidProtected -TargetPid $n -ProtectedPids ([int[]]$protected) -Table $table) {
      $spared += $n
    } else {
      try { Stop-Process -Id $n -Force -ErrorAction Stop; $killed += $n } catch { $spared += $n }
    }
  }
  if ($killed.Count -gt 0) {
    Write-Host "  killed pid(s) [$($killed -join ',')]"
  } else {
    Write-Host "  spared [$($spared -join ',')] - protected (current Claude / multiplexer / ancestor); not killed"
  }
}
Write-Host "done."
exit 0
