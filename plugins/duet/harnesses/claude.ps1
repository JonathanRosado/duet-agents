# Windows/psmux harness adapter: Claude Code. Dot-source duet-common.ps1 first,
# then `$h = & claude.ps1` to get the contract hashtable.
@{
  BootRegex = 'Claude Code'
  BriefFile = 'CLAUDE.md'
  Check     = {
    if (Resolve-DuetExecutable 'claude') { return $true }
    Write-DuetError "duet: 'claude' CLI not found on PATH"; return $false
  }
  Pretrust  = { param($Workdir) return $true }
  LaunchCommand = {
    param($Workdir, $DuetDir, $Name)
    $bin = Resolve-DuetExecutable 'claude'
    $sid = Split-Path -Leaf $DuetDir
    $permission = if ($env:DUET_CLAUDE_PERMISSION_FLAG) { $env:DUET_CLAUDE_PERMISSION_FLAG } else { '--dangerously-skip-permissions' }
    $cmd = ('Set-Location -LiteralPath {0}; $env:DUET_SELF={1}; $env:DUET_CONFIG={2}; $env:DUET_SESSION={3}; & {4} {5}' -f `
      (ConvertTo-DuetPsLiteral $Workdir), (ConvertTo-DuetPsLiteral $Name),
      (ConvertTo-DuetPsLiteral (Join-Path $DuetDir 'duet.env')), (ConvertTo-DuetPsLiteral $sid),
      (ConvertTo-DuetPsLiteral $bin), (ConvertTo-DuetPsLiteral $permission))
    if ($env:DUET_CLAUDE_MODEL) { $cmd += ' --model ' + (ConvertTo-DuetPsLiteral $env:DUET_CLAUDE_MODEL) }
    $cmd += ' --add-dir ' + (ConvertTo-DuetPsLiteral $DuetDir) + ' --name ' + (ConvertTo-DuetPsLiteral $Name)
    return $cmd
  }
}
