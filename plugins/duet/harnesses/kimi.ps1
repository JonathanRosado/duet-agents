# Windows/psmux harness adapter: Kimi Code. Dot-source duet-common.ps1 first,
# then `$h = & kimi.ps1` to get the contract hashtable.
@{
  BootRegex = 'Welcome to Kimi Code!'
  BriefFile = 'AGENTS.md'
  Check     = {
    $bin = Resolve-DuetExecutable 'kimi'
    if (-not $bin) { Write-DuetError "duet: 'kimi' CLI not found on PATH"; return $false }
    & $bin doctor *> $null
    if ($LASTEXITCODE -ne 0) { Write-DuetError "duet: kimi configuration is invalid; run 'kimi doctor'"; return $false }
    return $true
  }
  Pretrust  = { param($Workdir) return $true }
  LaunchCommand = {
    param($Workdir, $DuetDir, $Name)
    $bin = Resolve-DuetExecutable 'kimi'
    $sid = Split-Path -Leaf $DuetDir
    $mode = if ($env:DUET_KIMI_MODE_FLAG) { $env:DUET_KIMI_MODE_FLAG } else { '--auto' }
    $cmd = ('Set-Location -LiteralPath {0}; $env:DUET_SELF={1}; $env:DUET_CONFIG={2}; $env:DUET_SESSION={3}; & {4} {5}' -f `
      (ConvertTo-DuetPsLiteral $Workdir), (ConvertTo-DuetPsLiteral $Name),
      (ConvertTo-DuetPsLiteral (Join-Path $DuetDir 'duet.env')), (ConvertTo-DuetPsLiteral $sid),
      (ConvertTo-DuetPsLiteral $bin), (ConvertTo-DuetPsLiteral $mode))
    if ($env:DUET_KIMI_MODEL) { $cmd += ' -m ' + (ConvertTo-DuetPsLiteral $env:DUET_KIMI_MODEL) }
    $cmd += ' --add-dir ' + (ConvertTo-DuetPsLiteral $DuetDir)
    return $cmd
  }
}
