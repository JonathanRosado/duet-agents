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

function Get-DuetPanePidSet {
  # The set of process ids (as strings) currently backing a pane id, unioned and
  # tokenized. On the Windows/psmux build `pane_pid` can be a space-joined list
  # (shell + children) and one pane id may appear on several records, so we
  # flatten everything into a de-duplicated set of single pids.
  param([string]$Pane)
  if (-not $Pane) { return @() }
  # Capture by PLAIN assignment (no pipe, no @()): Get-DuetPaneRecords returns a
  # `,$array`-wrapped value. A pipeline hands it over as a single item, and even
  # `@(...)` re-wraps it into one merged element - both make Where-Object/foreach
  # see the whole array instead of each record. Plain assignment is exactly what
  # the comma trick is designed for and yields the individual records.
  $recs = Get-DuetPaneRecords
  $found = @()
  foreach ($rec in $recs) {
    if ($rec.Id -ne $Pane) { continue }
    foreach ($p in ($rec.Pid -split '\s+')) {
      if ($p) { $found += $p }
    }
  }
  return @($found | Select-Object -Unique)
}

function Get-DuetProcessTable {
  # Snapshot of every process as pid -> @{ Parent=<ppid>; Name=<name> }. Isolated
  # in its own function so tests can stub it. Used only by the Windows/psmux reap
  # to reason about process ancestry before killing anything.
  $table = @{}
  foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    $table[[int]$p.ProcessId] = @{ Parent = [int]$p.ParentProcessId; Name = [string]$p.Name }
  }
  return $table
}

function Test-DuetPidProtected {
  # True when killing $TargetPid could endanger the current Claude session, i.e.
  # the pid is one of the protected pids, an ancestor of a protected pid, or a
  # multiplexer / Claude process. Unknown pids are treated as protected (never
  # kill something we cannot reason about). This is what makes the reap safe on a
  # build where a recycled pane id could otherwise route a kill onto our own pane.
  param(
    [Parameter(Mandatory=$true)][int]$TargetPid,
    [int[]]$ProtectedPids = @(),
    [hashtable]$Table = $null
  )
  if ($TargetPid -le 0) { return $true }
  if (-not $Table -or -not $Table.ContainsKey($TargetPid)) { return $true }
  $name = [string]$Table[$TargetPid].Name
  if ($name -match '(?i)^(psmux|tmux|claude)') { return $true }
  if ($ProtectedPids -contains $TargetPid) { return $true }
  # Ancestor-of-protected? Walk each protected pid up toward the root; if the walk
  # passes through the target, killing the target would tear a protected pid down.
  foreach ($pp in $ProtectedPids) {
    $cur = $pp
    $seen = @{}
    while ($cur -gt 0 -and $Table.ContainsKey($cur) -and -not $seen[$cur]) {
      if ($cur -eq $TargetPid) { return $true }
      $seen[$cur] = $true
      $cur = [int]$Table[$cur].Parent
    }
  }
  return $false
}

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
    $target = $Config.CODEX_PANE
    $self   = $env:TMUX_PANE
    if (-not $self) { $self = $Config.CLAUDE_PANE }

    # SAFETY: Windows/psmux self-kill guard --------------------------------------
    # On this build a *dead* Codex pane's id can be recycled or aliased onto the
    # live Claude pane, and pane-level ops (`kill-pane`, `capture-pane`) then
    # MISROUTE to the current pane - so a blind `kill-pane` on the recorded Codex
    # id tears down THIS Claude session (the "re-init kills the shell and Codex
    # never comes up" bug). We therefore never touch the pane; instead we reap the
    # orphan Codex at the OS-process level (Stop-Process is precise and cannot
    # misroute), and only for pids that are provably NOT the current Claude, a
    # multiplexer, or an ancestor of our pane. A pane whose pids we cannot safely
    # kill is left for interactive `duet-doctor.ps1 -Reap`.
    if ($self -and $target -eq $self) {
      Write-Warning "duet: not reaping $target - it is the current pane."
    } elseif ($Config.CLAUDE_PANE -and $target -eq $Config.CLAUDE_PANE) {
      Write-Warning "duet: not reaping $target - it is the recorded Claude pane."
    } elseif (Test-DuetPaneAlive -Pane $target) {
      $table = Get-DuetProcessTable
      $protected = @($PID)
      foreach ($p in @(Get-DuetPanePidSet -Pane $self)) {
        $n = 0; if ([int]::TryParse($p, [ref]$n)) { $protected += $n }
      }
      $killed = @()
      $spared = @()
      foreach ($p in @(Get-DuetPanePidSet -Pane $target)) {
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { continue }
        if (Test-DuetPidProtected -TargetPid $n -ProtectedPids ([int[]]$protected) -Table $table) {
          $spared += $n
        } else {
          try { Stop-Process -Id $n -Force -ErrorAction Stop; $killed += $n } catch { $spared += $n }
        }
      }
      if ($killed.Count -gt 0) {
        Write-Host "duet: reaped orphan Codex process id(s) [$($killed -join ',')] for pane $target"
      } else {
        Write-Warning "duet: no safely-killable orphan process for pane $target (spared [$($spared -join ',')]). If a real orphan remains, run duet-doctor.ps1 -Reap."
      }
    }
    # ---------------------------------------------------------------------------
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
