# Windows/psmux harness adapter: Codex. Dot-source duet-common.ps1 first, then
# `$h = & codex.ps1` to get the contract hashtable.
@{
  BootRegex = 'OpenAI Codex'
  BriefFile = 'AGENTS.md'
  Check     = {
    if (Resolve-DuetExecutable 'codex') { return $true }
    Write-DuetError "duet: 'codex' CLI not found on PATH"; return $false
  }
  Pretrust  = {
    param($Workdir)
    if ($env:DUET_CODEX_SKIP_PRETRUST) { return $true }
    $ch = if ($env:CODEX_HOME) { $env:CODEX_HOME } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.codex' } elseif ($env:HOME) { Join-Path $env:HOME '.codex' } else { $null }
    if (-not $ch) { Write-DuetError "duet: USERPROFILE/CODEX_HOME required to pretrust codex"; return $false }
    $config = Join-Path $ch 'config.toml'
    $key = '[projects."' + ($Workdir.Replace('\', '\\').Replace('"', '\"')) + '"]'
    if ((Test-Path -LiteralPath $config) -and ([IO.File]::ReadAllText($config)).Contains($key)) { return $true }
    if (-not (Test-Path -LiteralPath $ch)) { New-Item -ItemType Directory -Path $ch -Force | Out-Null }
    Write-DuetUtf8NoBom -Path $config -Value ("`n$key`ntrust_level = `"trusted`"`n") -Append
    Write-Output "duet: marked $Workdir trusted for codex"
    return $true
  }
  LaunchCommand = {
    param($Workdir, $DuetDir, $Name)
    $bin = Resolve-DuetExecutable 'codex'
    $sid = Split-Path -Leaf $DuetDir
    $sandbox = if ($env:DUET_CODEX_SANDBOX) { $env:DUET_CODEX_SANDBOX } else { 'danger-full-access' }
    $approval = if ($env:DUET_CODEX_APPROVAL) { $env:DUET_CODEX_APPROVAL } else { 'never' }
    $cmd = ('Set-Location -LiteralPath {0}; $env:DUET_SELF={1}; $env:DUET_CONFIG={2}; $env:DUET_SESSION={3}; & {4} -c {5} --add-dir {6} -s {7} -a {8}' -f `
      (ConvertTo-DuetPsLiteral $Workdir), (ConvertTo-DuetPsLiteral $Name),
      (ConvertTo-DuetPsLiteral (Join-Path $DuetDir 'duet.env')), (ConvertTo-DuetPsLiteral $sid),
      (ConvertTo-DuetPsLiteral $bin), (ConvertTo-DuetPsLiteral 'check_for_update_on_startup=false'),
      (ConvertTo-DuetPsLiteral $DuetDir), (ConvertTo-DuetPsLiteral $sandbox), (ConvertTo-DuetPsLiteral $approval))
    if ($env:DUET_CODEX_MODEL) { $cmd += ' -m ' + (ConvertTo-DuetPsLiteral $env:DUET_CODEX_MODEL) }
    if ($env:DUET_CODEX_REASONING_EFFORT) {
      $cmd += ' -c ' + (ConvertTo-DuetPsLiteral ('model_reasoning_effort=' + $env:DUET_CODEX_REASONING_EFFORT))
    }
    return $cmd
  }
}
