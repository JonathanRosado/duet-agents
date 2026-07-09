Set-StrictMode -Version 2.0

function Get-DuetPsmux {
  $cmd = Get-Command psmux -ErrorAction SilentlyContinue
  if (-not $cmd) {
    $cmd = Get-Command tmux -ErrorAction SilentlyContinue
  }
  if (-not $cmd) {
    throw "duet: psmux not found on PATH"
  }
  return $cmd.Source
}

function ConvertTo-DuetPsLiteral {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { $Value = "" }
  return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-DuetTomlLiteral {
  param([string]$Value)
  return "'" + $Value.Replace("'", "''") + "'"
}

function Write-DuetUtf8NoBom {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value,
    [switch]$Append
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if ($Append) {
    [System.IO.File]::AppendAllText($Path, $Value, $encoding)
  } else {
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
  }
}

function Get-DuetVar {
  # Read a variable that a dot-sourced config file may or may not define
  # (older env files predate CODEX_PANE_PID etc.); StrictMode-safe.
  param([string]$Name)
  if (Test-Path -LiteralPath ("Variable:" + $Name)) {
    return (Get-Variable -Name $Name -ValueOnly)
  }
  return $null
}

function Import-DuetConfig {
  param([string]$Path)
  if (-not $Path) {
    $Path = $env:DUET_CONFIG
  }
  if (-not $Path) {
    $Path = Join-Path (Join-Path $HOME ".duet") "current.env.ps1"
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "duet: no session ($Path). run duet-init first."
  }

  . $Path

  return [pscustomobject]@{
    DUET_DIR = Get-DuetVar "DUET_DIR"
    CLAUDE_PANE = Get-DuetVar "CLAUDE_PANE"
    CODEX_PANE = Get-DuetVar "CODEX_PANE"
    CLAUDE_PANE_PID = Get-DuetVar "CLAUDE_PANE_PID"
    CODEX_PANE_PID = Get-DuetVar "CODEX_PANE_PID"
    PLUGIN_DIR = Get-DuetVar "PLUGIN_DIR"
    WORKDIR = Get-DuetVar "WORKDIR"
    DUET_RELAY = Get-DuetVar "DUET_RELAY"
    ConfigPath = $Path
  }
}

# --------------------------------------------------------------------------
# Pane inspection (read-only) - used to verify the target before sending and
# to find/reap orphaned agents. See issue #3.
# --------------------------------------------------------------------------

function Get-DuetPaneRecords {
  # All panes across the server as objects: Id, Pid, Cmd, Start.
  $psmux = Get-DuetPsmux
  $fmt = "#{pane_id}~::~#{pane_pid}~::~#{pane_current_command}~::~#{pane_start_command}"
  $lines = & $psmux list-panes -a -F $fmt 2>$null
  $records = @()
  foreach ($line in $lines) {
    if (-not $line) { continue }
    $parts = $line -split "~::~", 4
    $records += [pscustomobject]@{
      Id    = if ($parts.Count -ge 1) { $parts[0] } else { "" }
      Pid   = if ($parts.Count -ge 2) { $parts[1] } else { "" }
      Cmd   = if ($parts.Count -ge 3) { $parts[2] } else { "" }
      Start = if ($parts.Count -ge 4) { $parts[3] } else { "" }
    }
  }
  return ,$records   # comma forces an array even for 0/1 records (StrictMode .Count)
}

function Test-DuetPaneAlive {
  # Existence check: is this pane id currently present on the server? Pane pids
  # are intentionally NOT used to gate sends - psmux reports the transient
  # foreground pid, which would produce false "dead" verdicts and block a
  # legitimate send. Orphan misroutes are prevented upstream by reaping the
  # previous session on re-init (see Stop-DuetSessionByConfig / duet-init).
  param([string]$Pane)
  if (-not $Pane) { return $false }
  $rec = @(Get-DuetPaneRecords | Where-Object { $_.Id -eq $Pane })
  return ($rec.Count -gt 0)
}

function Get-DuetPaneTail {
  param(
    [Parameter(Mandatory=$true)][string]$Psmux,
    [Parameter(Mandatory=$true)][string]$Pane,
    [int]$Lines = 6
  )
  $out = & $Psmux capture-pane -t $Pane -p 2>$null
  if (-not $out) { return "" }
  return (($out | Select-Object -Last $Lines) -join "`n")
}

# --------------------------------------------------------------------------
# Submission detection (pure, unit-testable). A message that was pasted but
# never submitted keeps sitting in the composer; a submitted one leaves it.
# We normalize by stripping ALL whitespace so terminal soft-wrapping (which
# inserts row breaks mid-line) does not defeat the substring match.
# --------------------------------------------------------------------------

function Get-DuetStripped {
  param([AllowEmptyString()][string]$Text)
  if ($null -eq $Text) { return "" }
  return ($Text -replace '\s', '')
}

function Get-DuetSubmitProbe {
  # A distinctive tail of the payload - this is what sits at the composer
  # cursor right after a paste. Up to 48 non-whitespace chars from the end.
  param([AllowEmptyString()][string]$Payload)
  $stripped = Get-DuetStripped $Payload
  if ($stripped.Length -eq 0) { return "" }
  $len = [Math]::Min(48, $stripped.Length)
  return $stripped.Substring($stripped.Length - $len)
}

function Test-DuetProbePresent {
  param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Haystack,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Probe
  )
  if ([string]::IsNullOrEmpty($Probe)) { return $false }
  $h = Get-DuetStripped $Haystack
  return $h.Contains($Probe)
}

# --------------------------------------------------------------------------
# Reliable delivery. Paste, confirm it landed in the composer, press Enter,
# confirm the composer cleared (submitted), and retry Enter if it did not.
# Returns $true ONLY when submission is verified - never a false positive.
# See issues #1 and #2 (Enter races the bracketed paste -> silent drop).
# --------------------------------------------------------------------------

function Send-DuetPaste {
  [OutputType([bool])]
  param(
    [Parameter(Mandatory=$true)][string]$Pane,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
    [switch]$Interrupt
  )

  $psmux = Get-DuetPsmux

  # 0. The target pane must still exist.
  if (-not (Test-DuetPaneAlive -Pane $Pane)) {
    Write-Warning "duet: target pane $Pane is gone; not sending."
    return $false
  }

  # 1. Interrupt only aborts a BUSY peer. Escaping an idle composer can swallow
  #    the paste that follows (issue #2 secondary #1), so gate it on a busy marker.
  if ($Interrupt) {
    $busyTail = Get-DuetPaneTail -Psmux $psmux -Pane $Pane -Lines 4
    if ($busyTail -match '(?i)esc to interrupt|esc to cancel|ctrl\+c to|working|thinking|generating|running') {
      & $psmux send-keys -t $Pane Escape | Out-Null
      Start-Sleep -Milliseconds 400
    }
  }

  $probe = Get-DuetSubmitProbe -Payload $Text
  $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))

  # 2. Paste, then poll until the payload is reflected in the composer. Retry the
  #    paste once if it never shows (e.g. an Escape/menu ate it).
  $landed = $false
  for ($attempt = 0; $attempt -lt 2 -and -not $landed; $attempt++) {
    & $psmux -t $Pane send-paste $payloadB64 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "duet: psmux send-paste failed for pane $Pane"
      return $false
    }
    if ([string]::IsNullOrEmpty($probe)) { $landed = $true; break }
    for ($i = 0; $i -lt 15; $i++) {
      Start-Sleep -Milliseconds 100
      $tail = Get-DuetPaneTail -Psmux $psmux -Pane $Pane -Lines 10
      if (Test-DuetProbePresent -Haystack $tail -Probe $probe) { $landed = $true; break }
    }
  }

  if (-not $landed) {
    # We could not confirm the text even reached the composer. Fire one Enter as
    # a best effort, but report failure so the caller does not claim success.
    & $psmux send-keys -t $Pane Enter | Out-Null
    Write-Warning "duet: could not confirm paste landed in pane $Pane"
    return $false
  }

  # 3. Submit. Enter, then poll for the composer to clear. Retry Enter (this is
  #    the fix that a *later* Enter submits when the first raced the paste).
  for ($enter = 0; $enter -lt 3; $enter++) {
    & $psmux send-keys -t $Pane Enter | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "duet: psmux send-keys Enter failed for pane $Pane"
      return $false
    }
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 200
      $tail = Get-DuetPaneTail -Psmux $psmux -Pane $Pane -Lines 4
      if (-not (Test-DuetProbePresent -Haystack $tail -Probe $probe)) {
        return $true   # composer cleared -> submitted
      }
    }
  }

  Write-Warning "duet: pasted into pane $Pane but could not confirm submission."
  return $false
}

# --------------------------------------------------------------------------
# Session teardown / orphan reaping (issue #3). Stopping a session signals its
# relay to exit and kills its Codex pane so exactly one agent exists per role.
# --------------------------------------------------------------------------

function Stop-DuetSessionByConfig {
  param(
    [Parameter(Mandatory=$true)]$Config,
    [switch]$KillCodexPane
  )
  if (-not $Config -or -not $Config.DUET_DIR) { return }
  # Tell the background relay (if any) to exit.
  try {
    Write-DuetUtf8NoBom -Path (Join-Path $Config.DUET_DIR ".ended") -Value ""
  } catch { }
  if ($KillCodexPane -and $Config.CODEX_PANE) {
    $psmux = Get-DuetPsmux
    if (Test-DuetPaneAlive -Pane $Config.CODEX_PANE) {
      & $psmux send-keys -t $Config.CODEX_PANE C-c 2>$null | Out-Null
      Start-Sleep -Milliseconds 300
      & $psmux kill-pane -t $Config.CODEX_PANE 2>$null | Out-Null
    }
  }
}

function Get-DuetPendingCount {
  param([string]$Dir)
  $box = Join-Path $Dir "to-claude"
  if (-not (Test-Path -LiteralPath $box)) {
    return 0
  }
  return @(
    Get-ChildItem -LiteralPath $box -Filter "*.msg" -File -ErrorAction SilentlyContinue
  ).Count
}

function Remove-DuetBlock {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    return
  }

  $text = [System.IO.File]::ReadAllText($Path)
  $updated = [regex]::Replace(
    $text,
    "(?s)\r?\n?<!-- DUET:BEGIN.*?<!-- DUET:END -->\r?\n?",
    ""
  )
  if ($updated.Trim().Length -eq 0) {
    Remove-Item -LiteralPath $Path -Force
  } elseif ($updated -ne $text) {
    Write-DuetUtf8NoBom -Path $Path -Value $updated
  }
}
