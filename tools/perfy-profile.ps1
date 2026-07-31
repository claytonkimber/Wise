<#
.SYNOPSIS
    Instrument the live Wise addon in place for Perfy profiling, then restore it.

.DESCRIPTION
    Profiles the REAL addon at its real path - no copies, no junction swapping,
    no separate instrumented tree. AddOns\Wise keeps pointing where it always
    points, so what you profile is exactly what you run.

    Perfy rewrites .lua/.toc files in place, so "restore" here means git. Every
    .lua and .toc file in this repo is tracked, so `git checkout -- .` restores
    them exactly. UNCOMMITTED WORK IS PROTECTED: -Instrument refuses to run on a
    dirty tree unless you pass -Force, which auto-stashes first and records the
    stash so -Restore can put it back.

    A marker file (.perfy-instrumented) records state between runs so -Restore
    knows what to undo and -Status can tell you where things stand.

.EXAMPLE
    .\tools\perfy-profile.ps1 -Status
    .\tools\perfy-profile.ps1 -Instrument
    # /reload, /perfy start, play, /perfy stop, /reload
    .\tools\perfy-profile.ps1 -Analyze
    .\tools\perfy-profile.ps1 -Restore
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Instrument')][switch]$Instrument,
    [Parameter(ParameterSetName = 'Restore')][switch]$Restore,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Analyze')][switch]$Analyze,
    # Allow instrumenting a dirty tree by stashing uncommitted work first.
    [Parameter(ParameterSetName = 'Instrument')][switch]$Force,
    # Where the analyzer writes stacks-cpu.txt / stacks-memory.txt.
    [Parameter(ParameterSetName = 'Analyze')][string]$OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- paths -------------------------------------------------------------------
$AddonRoot = Split-Path -Parent $PSScriptRoot            # ...\_dev_\Wise
$DevRoot   = Split-Path -Parent $AddonRoot               # ...\_dev_
$PerfyRoot = Join-Path $DevRoot 'Perfy'
$Toc       = Join-Path $AddonRoot 'Wise.toc'
$Marker    = Join-Path $AddonRoot '.perfy-instrumented'
$PerfyLink = Join-Path (Split-Path -Parent $DevRoot) 'AddOns\!!!Perfy'
$PerfySrc  = Join-Path $PerfyRoot 'AddOn'
$WowRoot = Split-Path -Parent (Split-Path -Parent $DevRoot)   # ...\_retail_

# Perfy's SavedVariables live under WTF\Account\<ACCOUNT>\. The account folder
# name differs per install, so discover it instead of hardcoding: prefer the
# account that already has a Perfy capture, else the most recently written one.
# PERFY_WOW_ACCOUNT overrides when several accounts are in play.
function Resolve-SavedVars {
    $accountsRoot = Join-Path $WowRoot 'WTF\Account'
    if ($env:PERFY_WOW_ACCOUNT) {
        return Join-Path $accountsRoot `
            (Join-Path $env:PERFY_WOW_ACCOUNT 'SavedVariables\!!!Perfy.lua')
    }
    if (-not (Test-Path -LiteralPath $accountsRoot)) {
        return Join-Path $accountsRoot 'UNKNOWN\SavedVariables\!!!Perfy.lua'
    }
    $candidates = Get-ChildItem -LiteralPath $accountsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'SavedVariables\!!!Perfy.lua' } |
        Where-Object { Test-Path -LiteralPath $_ }
    if ($candidates) {
        return (Get-Item -LiteralPath $candidates | Sort-Object LastWriteTime -Descending |
                Select-Object -First 1).FullName
    }
    # No capture yet: fall back to the most recently used account folder.
    $acct = Get-ChildItem -LiteralPath $accountsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($acct) { return Join-Path $acct.FullName 'SavedVariables\!!!Perfy.lua' }
    return Join-Path $accountsRoot 'UNKNOWN\SavedVariables\!!!Perfy.lua'
}
$SavedVars = Resolve-SavedVars

# Tool locations. Both can be overridden by env var for non-default installs.
$LuaLS = if ($env:PERFY_LUALS) { $env:PERFY_LUALS } else {
    Join-Path $env:LOCALAPPDATA `
        'Microsoft\WinGet\Packages\LuaLS.lua-language-server_Microsoft.Winget.Source_8wekyb3d8bbwe'
}
$LuaExe = if ($env:PERFY_LUA) { $env:PERFY_LUA } else {
    $found = Get-Command lua.exe, lua54.exe, lua5.4.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { $found.Source }
    else { Join-Path $env:USERPROFILE 'Documents\Mechanic\desktop\bin\lua.exe' }
}

function Assert-Tool($path, $what) {
    if (-not (Test-Path -LiteralPath $path)) { throw "$what not found at $path" }
}

function Get-GitStatus {
    Push-Location $AddonRoot
    try { return (& git status --porcelain 2>$null) } finally { Pop-Location }
}

function Test-Instrumented {
    # Authoritative check: does the TOC carry Perfy's marker?
    if (-not (Test-Path -LiteralPath $Toc)) { return $false }
    return [bool](Select-String -LiteralPath $Toc -Pattern 'X-Perfy-Instrumented' -Quiet)
}

# --- status ------------------------------------------------------------------
function Show-Status {
    $inst = Test-Instrumented
    Write-Host ""
    Write-Host "Wise Perfy profiling status" -ForegroundColor Cyan
    Write-Host ("-" * 46)
    Write-Host ("  addon path      : {0}" -f $AddonRoot)
    Write-Host ("  instrumented    : {0}" -f $(if ($inst) { "YES" } else { "no" })) `
        -ForegroundColor $(if ($inst) { 'Yellow' } else { 'Green' })

    $link = Get-Item -LiteralPath (Join-Path (Split-Path -Parent $DevRoot) 'AddOns\Wise') `
            -Force -ErrorAction SilentlyContinue
    if ($link) {
        $tgt = if ($link.LinkType) { ($link.Target -join ',') } else { "<real directory>" }
        Write-Host ("  AddOns\Wise ->  : {0}" -f $tgt)
    }
    Write-Host ("  !!!Perfy linked : {0}" -f (Test-Path -LiteralPath $PerfyLink))

    $all = Get-GitStatus
    # Only tracked modifications block instrumentation; untracked files are
    # shown for context but are never touched or stashed.
    $tracked = $all | Where-Object { $_ -notmatch '^\?\?' }
    if ($tracked) {
        Write-Host "  git             : uncommitted TRACKED changes (will be auto-stashed with -Force)" `
            -ForegroundColor Yellow
        $tracked | Select-Object -First 8 | ForEach-Object { Write-Host "                    $_" }
    } else {
        Write-Host "  git             : clean (tracked files)" -ForegroundColor Green
    }
    $untracked = $all | Where-Object { $_ -match '^\?\?' }
    if ($untracked) {
        Write-Host "  untracked       : not touched by profiling" -ForegroundColor DarkGray
        $untracked | Select-Object -First 5 | ForEach-Object { Write-Host "                    $_" -ForegroundColor DarkGray }
    }

    if (Test-Path -LiteralPath $Marker) {
        Write-Host "  marker          :" -ForegroundColor Yellow
        Get-Content -LiteralPath $Marker | ForEach-Object { Write-Host "                    $_" }
    }

    # When instrumented, say WHAT is instrumented. A profile of the wrong code
    # looks completely normal until the numbers are compared, so surface it.
    if ($inst) {
        Push-Location $AddonRoot
        try {
            $diff = @(& git diff --stat HEAD -- '*.lua' '*.toc')
            $changed = @($diff | Where-Object { $_ -match '\|' }).Count
        } finally { Pop-Location }
        if ($changed -gt 1) {
            Write-Host "  profiling       : your working tree (uncommitted changes INCLUDED)" `
                -ForegroundColor Cyan
        } else {
            Write-Host "  profiling       : committed HEAD only (no uncommitted changes)" `
                -ForegroundColor Cyan
        }
    }

    if (Test-Path -LiteralPath $SavedVars) {
        $sv = Get-Item -LiteralPath $SavedVars
        Write-Host ("  capture         : {0:N1} MiB, {1}" -f ($sv.Length / 1MB), $sv.LastWriteTime)
    } else {
        Write-Host "  capture         : none"
    }
    Write-Host ""
}

# --- instrument --------------------------------------------------------------
function Invoke-Instrument {
    if (Test-Instrumented) {
        Write-Host "Already instrumented. Run -Restore first (or -Status to inspect)." -ForegroundColor Yellow
        return
    }
    Assert-Tool $LuaLS 'lua-language-server'
    Assert-Tool $Toc   'Wise.toc'

    # Only TRACKED modifications matter here. Instrumentation rewrites tracked
    # .lua/.toc files only, so untracked files (including this script, which
    # lives in an untracked tools/) are never at risk.
    $dirty = Get-GitStatus | Where-Object { $_ -notmatch '^\?\?' }

    # CRITICAL: uncommitted work must be INSTRUMENTED, not set aside.
    #
    # An earlier version stashed the working tree and then instrumented, which
    # meant the profile measured pristine HEAD while the user believed they were
    # measuring their changes - silently answering the wrong question. Instead,
    # save the working tree to a git object we can restore from later, and leave
    # the files exactly as they are so instrumentation rewrites the REAL code.
    $stashRef = ''
    $stashMsg = ''
    if ($dirty) {
        if (-not $Force) {
            Write-Host ""
            Write-Host "You have uncommitted changes." -ForegroundColor Yellow
            $dirty | ForEach-Object { Write-Host "  $_" }
            Write-Host ""
            Write-Host "Instrumentation rewrites these files in place. -Force takes a restore"
            Write-Host "point first, then instruments YOUR CURRENT CODE (uncommitted changes"
            Write-Host "included), so the profile measures what you actually have."
            Write-Host ""
            Write-Host "  .\tools\perfy-profile.ps1 -Instrument -Force" -ForegroundColor Cyan
            Write-Host ""
            throw "dirty working tree"
        }
        Push-Location $AddonRoot
        try {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            # `git stash create` writes a commit object WITHOUT touching the
            # working tree - exactly what we need. It is not reachable from any
            # ref, so anchor it with a real stash entry to protect it from gc.
            $stashRef = (& git stash create "perfy-restore-point $stamp" 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $stashRef) { throw "git stash create failed" }
            $stashRef = $stashRef.Trim()
            $stashMsg = "perfy-restore-point $stamp"
            & git stash store -m $stashMsg $stashRef 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git stash store failed" }
            Write-Host "Saved restore point ($stashRef) - your changes stay in place" -ForegroundColor Green
            Write-Host "Profiling YOUR CURRENT CODE, including uncommitted changes." -ForegroundColor Cyan
        } finally { Pop-Location }
    }

    # Record state BEFORE touching files, so -Restore works even if we fail midway.
    # BOM-free, so the values parse cleanly when read back in -Restore.
    [System.IO.File]::WriteAllLines($Marker, [string[]]@(
        "instrumented=$(Get-Date -Format o)",
        "stash=$stashRef",
        "stashmsg=$stashMsg",
        "head=$(Push-Location $AddonRoot; (& git rev-parse HEAD); Pop-Location)"
    ), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "Instrumenting $Toc ..." -ForegroundColor Cyan
    Push-Location $LuaLS
    try {
        & .\bin\lua-language-server.exe (Join-Path $PerfyRoot 'Instrumentation\Main.lua') $Toc
        if ($LASTEXITCODE -ne 0) { throw "instrumentation failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }

    if (-not (Test-Instrumented)) { throw "instrumentation reported success but TOC has no marker" }

    # Perfy must be loadable: Wise now declares it as a dependency.
    $p = Get-Item -LiteralPath $PerfyLink -Force -ErrorAction SilentlyContinue
    if ($p -and -not $p.LinkType) { throw "AddOns\!!!Perfy is a real directory - aborting." }
    if (-not $p) {
        New-Item -ItemType Junction -Path $PerfyLink -Target $PerfySrc | Out-Null
        Write-Host "Linked AddOns\!!!Perfy -> $PerfySrc"
    }

    $n = (Select-String -LiteralPath (Join-Path $AddonRoot 'core\GUI.lua') `
            -Pattern 'Perfy_Trace' -AllMatches | Measure-Object).Count
    Write-Host ""
    Write-Host "Instrumented in place. GUI.lua trace points: $n" -ForegroundColor Green
    Write-Host ""
    Write-Host "In game:" -ForegroundColor Cyan
    Write-Host "  /reload"
    Write-Host "  (wait ~5s for the post-reload rebuild to finish)"
    Write-Host "  /perfy start 30      <- 30s is the sweet spot; see limits below"
    Write-Host "  /reload              <- required, this is what writes the capture"
    Write-Host ""
    Write-Host "Capture limits (measured on this UI, ~72k trace entries/sec):" -ForegroundColor Cyan
    Write-Host "   30s  ~2.2M entries, ~156 MB file, ~0.8 GB to analyze   <- recommended"
    Write-Host "   60s  ~4.3M entries, ~313 MB file, ~1.6 GB to analyze   comfortable"
    Write-Host "  120s  ~8.7M entries, ~626 MB file, ~3.2 GB to analyze   slow but OK"
    Write-Host "  180s ~13.0M entries, ~938 MB file, ~4.9 GB to analyze   near the limit"
    Write-Host "  240s+  expect the analyzer to run out of memory" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Tracing disables the game's GC, so the client also grows ~1 GB/min." -ForegroundColor DarkGray
    Write-Host "  Longer is not better: 30s of the RIGHT combat beats 5 minutes of mixed." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Then: .\tools\perfy-profile.ps1 -Analyze"
    Write-Host "And:  .\tools\perfy-profile.ps1 -Restore" -ForegroundColor Cyan
}

# --- restore -----------------------------------------------------------------
function Invoke-Restore {
    if (-not (Test-Instrumented) -and -not (Test-Path -LiteralPath $Marker)) {
        Write-Host "Not instrumented - nothing to restore." -ForegroundColor Green
        return
    }

    Push-Location $AddonRoot
    try {
        # Restore ONLY the tracked .lua/.toc files that instrumentation rewrites.
        #
        # Deliberately NOT `git checkout -- .`: that also deletes untracked files
        # in the checkout path, and this script lives in an untracked tools/
        # directory - it would delete itself mid-run and abort the restore,
        # stranding the tree instrumented and the user's work in a stash.
        # Restricting to tracked paths makes the operation both narrower and
        # safe to run from anywhere.
        $targets = @(& git ls-files '*.lua' '*.toc')
        if (-not $targets -or $targets.Count -eq 0) { throw "no tracked lua/toc files found" }

        # Feed paths via a file to avoid command-line length limits on large repos.
        # Write WITHOUT a BOM: PowerShell 5.1's `-Encoding utf8` emits one, and
        # git would treat the BOM as part of the first pathspec ("did not match
        # any file(s) known to git"). UTF8Encoding($false) = no BOM.
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllLines($tmp, [string[]]$targets,
                (New-Object System.Text.UTF8Encoding($false)))
            & git checkout --pathspec-from-file=$tmp --
            if ($LASTEXITCODE -ne 0) { throw "git checkout failed - files NOT restored" }
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    } finally { Pop-Location }

    if (Test-Instrumented) { throw "restore ran but TOC still marked instrumented" }

    # Re-apply the restore point taken at -Instrument time.
    #
    # The checkout above reverted every tracked .lua/.toc to HEAD, which removed
    # the instrumentation AND any uncommitted work that was instrumented along
    # with it. The restore point is a commit object holding exactly that working
    # tree, so `git checkout <sha> -- <paths>` puts the edits back.
    $stashRef = ''
    $stashMsg = ''
    if (Test-Path -LiteralPath $Marker) {
        foreach ($line in (Get-Content -LiteralPath $Marker)) {
            if ($line -like 'stash=*')    { $stashRef = ($line -split '=', 2)[1] }
            if ($line -like 'stashmsg=*') { $stashMsg = ($line -split '=', 2)[1] }
        }
    }
    if ($stashRef) {
        Push-Location $AddonRoot
        try {
            # Verify the object still exists before relying on it.
            & git cat-file -e "$stashRef^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host "Restore point $stashRef not found." -ForegroundColor Red
                Write-Host "Check 'git stash list' - your work may be recoverable there." -ForegroundColor Yellow
                Write-Host ""
            } else {
                # Restore the files as they were when profiling started. Scope to
                # tracked lua/toc so nothing else in the tree is disturbed.
                $targets2 = @(& git ls-files '*.lua' '*.toc')
                $tmp2 = [System.IO.Path]::GetTempFileName()
                try {
                    [System.IO.File]::WriteAllLines($tmp2, [string[]]$targets2,
                        (New-Object System.Text.UTF8Encoding($false)))
                    & git checkout $stashRef --pathspec-from-file=$tmp2 --
                    $rc = $LASTEXITCODE
                } finally { Remove-Item -LiteralPath $tmp2 -Force -ErrorAction SilentlyContinue }

                if ($rc -ne 0) {
                    Write-Host ""
                    Write-Host "Could not re-apply your changes automatically." -ForegroundColor Red
                    Write-Host "They are SAFE in git. Recover with:" -ForegroundColor Yellow
                    Write-Host "  git checkout $stashRef -- ."
                    Write-Host ""
                } else {
                    # git checkout stages what it restores; unstage so the tree
                    # looks the way it did before profiling (modified, unstaged).
                    & git reset -q 2>$null
                    if (Test-Instrumented) {
                        throw "restore point still contains instrumentation - aborting to avoid a corrupt tree"
                    }
                    Write-Host "Re-applied your uncommitted changes ($stashRef)" -ForegroundColor Green

                    # Drop the stash entry we created to anchor the object; the
                    # work is back in the tree so the entry is just clutter.
                    $idx = -1
                    $list = & git stash list --format='%H'
                    if ($list) {
                        $i = 0
                        foreach ($sha in @($list)) {
                            if ($sha -eq $stashRef) { $idx = $i; break }
                            $i++
                        }
                    }
                    if ($idx -ge 0) {
                        $spec = 'stash@{' + $idx + '}'
                        & git stash drop $spec 2>$null | Out-Null
                    }
                }
            }
        } finally { Pop-Location }
    }

    $p = Get-Item -LiteralPath $PerfyLink -Force -ErrorAction SilentlyContinue
    if ($p -and $p.LinkType) { $p.Delete(); Write-Host "Removed AddOns\!!!Perfy link" }

    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Restored. Live Wise is back to normal." -ForegroundColor Green
    Write-Host "/reload in game to drop the profiling overhead."
    Push-Location $AddonRoot
    try { & git status --short } finally { Pop-Location }
}

# --- analyze -----------------------------------------------------------------
function Invoke-Analyze {
    Assert-Tool $LuaExe 'lua.exe'
    if (-not (Test-Path -LiteralPath $SavedVars)) {
        throw "No capture at $SavedVars - did you /perfy stop and then /reload?"
    }
    $sv = Get-Item -LiteralPath $SavedVars
    if ($sv.Length -lt 1KB) {
        throw "Capture is only $($sv.Length) bytes - looks empty. Did tracing actually run?"
    }
    $mb = $sv.Length / 1MB
    # The analyzer slurps the whole file, then builds one ~400-byte table per
    # trace entry (measured). Roughly 5.2 MB of file per second of capture, so
    # file MB -> entries -> peak heap is a reliable predictor of an OOM.
    $estEntries = ($sv.Length / 5.21MB) * 72343
    $estGiB = $estEntries * 401 / 1GB
    Write-Host ("Analyzing {0:N1} MiB captured {1}" -f $mb, $sv.LastWriteTime) -ForegroundColor Cyan
    Write-Host ("  ~{0:N1}M trace entries, needs ~{1:N1} GB RAM" -f ($estEntries/1e6), $estGiB) `
        -ForegroundColor DarkGray
    if ($estGiB -gt 4.5) {
        Write-Host ""
        Write-Host ("  WARNING: this capture is large enough that the analyzer may run out") -ForegroundColor Yellow
        Write-Host ("  of memory. If it dies, re-capture for a shorter window (30-60s).") -ForegroundColor Yellow
        Write-Host ""
    }

    $analyzer = Join-Path $PerfyRoot 'Analyzer'
    Push-Location $analyzer
    try {
        & $LuaExe 'Main.lua' $SavedVars
        if ($LASTEXITCODE -ne 0) { throw "analyzer failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }

    if ($OutDir) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        foreach ($f in 'stacks-cpu.txt', 'stacks-memory.txt') {
            $src = Join-Path $analyzer $f
            if (Test-Path -LiteralPath $src) { Copy-Item $src (Join-Path $OutDir $f) -Force }
        }
        Write-Host "Stacks written to $OutDir" -ForegroundColor Green
    } else {
        Write-Host "Stacks written to $analyzer" -ForegroundColor Green
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Instrument' { Invoke-Instrument }
    'Restore'    { Invoke-Restore }
    'Analyze'    { Invoke-Analyze }
    default      { Show-Status }
}
