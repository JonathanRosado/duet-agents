# Windows/psmux reap-safety tests. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File plugins/duet/tests/reap-guard.tests.ps1
#
# Guards the "re-init kills the shell" bug: on the Windows/psmux build a dead
# Codex pane's id can be recycled/aliased onto the live Claude pane, so a naive
# `kill-pane` on the recorded Codex id tears down THIS session. Stop-DuetSessionByConfig
# now reaps at the OS-process level (Stop-Process) and refuses to touch any pid
# that is the current Claude, a multiplexer, or an ancestor of our pane.
$ErrorActionPreference = 'Stop'
$common = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\duet-common.ps1'
. $common

$tmp = Join-Path $env:TEMP ("duettest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env:TMUX_PANE = '%1'

# Real-topology-shaped process table: claude=23108 (parent psmux 23008); a
# powershell 23024 in the same pane; the ghost pane's shell 15420 is a SIBLING of
# claude (parent psmux 23008); a genuinely distinct codex shell 7576; plus a
# synthetic ancestor chain 5000<-4000<-3000 to exercise the ancestor walk.
$script:TABLE = @{
  20596 = @{ Parent=1;     Name='psmux.exe' }
  23008 = @{ Parent=1;     Name='psmux.exe' }
  23108 = @{ Parent=23008; Name='claude.exe' }
  23024 = @{ Parent=20596; Name='powershell.exe' }
  15420 = @{ Parent=23008; Name='powershell.exe' }
  7576  = @{ Parent=20596; Name='powershell.exe' }
  3000  = @{ Parent=1;     Name='powershell.exe' }
  4000  = @{ Parent=3000;  Name='powershell.exe' }
  5000  = @{ Parent=4000;  Name='powershell.exe' }
}
$script:ALIVE   = @{}
$script:PIDSETS = @{}
$script:KILLED  = @()
function Get-DuetProcessTable { return $script:TABLE }
function Test-DuetPaneAlive { param([string]$Pane) return [bool]$script:ALIVE[$Pane] }
function Get-DuetPanePidSet { param([string]$Pane) $v = $script:PIDSETS[$Pane]; if ($null -eq $v) { @() } else { @($v) } }
function Stop-Process { param([int]$Id, [switch]$Force, $ErrorAction) $script:KILLED += $Id }

function Run($name, $codexPane, $alive, $pidsets, $expectKilled) {
  $script:KILLED = @(); $script:ALIVE = $alive; $script:PIDSETS = $pidsets
  $cfg = [pscustomobject]@{
    DUET_DIR = $tmp; CLAUDE_PANE = '%1'; CODEX_PANE = $codexPane
    CLAUDE_PANE_PID = '23108 23024'; CODEX_PANE_PID = 'x'
  }
  $warn = & { Stop-DuetSessionByConfig -Config $cfg -KillCodexPane } 3>&1 | ForEach-Object { "$_" }
  $killed = @($script:KILLED | Sort-Object)
  $exp = @($expectKilled | Sort-Object)
  $ok = (($killed -join ',') -eq ($exp -join ','))
  if ($killed -contains 23108) { $ok = $false }   # hard invariant: never kill my Claude
  $verdict = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("{0,-4} {1,-40} killed=[{2,-8}] expected=[{3,-8}] {4}" -f $verdict, $name, ($killed -join ','), ($exp -join ','), ($warn -join ' '))
  return $ok
}

$ok = @()
$ok += Run 'A ghost %4 -> kill orphan 15420' '%4' @{ '%1'=$true; '%4'=$true } @{ '%1'=@('23024','23108'); '%4'=@('15420') } @(15420)
$ok += Run 'B real codex %5 -> kill 7576'    '%5' @{ '%1'=$true; '%5'=$true } @{ '%1'=@('23024','23108'); '%5'=@('7576') }  @(7576)
$ok += Run 'C target reports my claude'      '%4' @{ '%1'=$true; '%4'=$true } @{ '%1'=@('23024','23108'); '%4'=@('23108') } @()
$ok += Run 'D target is psmux'               '%4' @{ '%1'=$true; '%4'=$true } @{ '%1'=@('23024','23108'); '%4'=@('23008') } @()
$ok += Run 'E target is ancestor'            '%7' @{ '%1'=$true; '%7'=$true } @{ '%1'=@('5000'); '%7'=@('4000') }           @()
$ok += Run 'F target unknown pid'            '%8' @{ '%1'=$true; '%8'=$true } @{ '%1'=@('23108'); '%8'=@('99999') }         @()
$ok += Run 'G target not alive'              '%9' @{ '%1'=$true; '%9'=$false } @{ '%1'=@('23108') }                        @()
$ok += Run 'H target == current pane'        '%1' @{ '%1'=$true } @{ '%1'=@('23108') }                                     @()
$ok += Run 'I mixed orphan+claude'           '%4' @{ '%1'=$true; '%4'=$true } @{ '%1'=@('23024','23108'); '%4'=@('15420','23108') } @(15420)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
$fails = @($ok | Where-Object { -not $_ }).Count
if ($fails -eq 0) { Write-Host "==== ALL PASS ===="; exit 0 } else { Write-Host "==== $fails FAILED ===="; exit 1 }