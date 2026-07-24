# Canonical Windows/psmux test entrypoint for duet v4.
[CmdletBinding()]
param(
  [switch]$Real,
  [switch]$AllowUnconfiguredKimi,
  [switch]$List
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$suites = @(
  'foundation.tests.ps1',
  'adapters.tests.ps1',
  'queue.tests.ps1',
  'daemon.tests.ps1',
  'transport.tests.ps1',
  'mesh.tests.ps1',
  'lifecycle.tests.ps1'
)
if ($Real) { $suites += 'real-smoke.tests.ps1' }
if ($List) {
  $suites | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }
  exit 0
}

foreach ($suite in $suites) {
  Write-Host ''
  Write-Host "==== RUN $suite ====" -ForegroundColor Cyan
  $arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot $suite)
  )
  if ($suite -eq 'real-smoke.tests.ps1' -and $AllowUnconfiguredKimi) {
    $arguments += '-AllowUnconfiguredKimi'
  }
  & powershell.exe @arguments
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host ''
Write-Host '==== ALL DUET V4 POWERSHELL SUITES PASS ====' -ForegroundColor Green
exit 0
