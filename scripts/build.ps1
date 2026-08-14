#requires -version 5.1
<#
.SYNOPSIS
    Build & deploy helper (config-driven, Windows PowerShell).

.DESCRIPTION
    Config source = project-configs/<project>/project.toml (SSOT).
    This script:
      1. Calls pack.ps1 to build & pack each selected project
      2. Copies deploy assets to dist/ (self-contained, for server upload)

    Adding a new project = create project-configs/<name>/project.toml.
    No script changes needed.

.EXAMPLE
    .\scripts\build.ps1                          # Interactive menu
    .\scripts\build.ps1 financial                # Build single project group
    .\scripts\build.ps1 deepquant-backend        # Build single component
    .\scripts\build.ps1 deepquant-backend,financial-api  # Build N components
    .\scripts\build.ps1 all                      # Build all
    .\scripts\build.ps1 financial,official-site  # Build multiple groups
    .\scripts\build.ps1 --scripts-only           # Only refresh dist/ scripts (skip package build)
#>

param(
    [Parameter(Position = 0)]
    [string]$Project = "",
    [switch]$ScriptsOnly
)

$ErrorActionPreference = "Stop"
$ScriptsDir   = $PSScriptRoot
$DeployDir    = Split-Path $ScriptsDir -Parent
$ConfigsDir   = Join-Path $DeployDir 'project-configs'
$PackagesDir  = Join-Path $DeployDir 'dist\packages'

# ── Shared constants & helpers (encoding, logging, Get-Python) ──
. (Join-Path $ScriptsDir 'lib\_ps-common.ps1')

# ── Scan project configs ──
function Get-ProjectConfigs {
    $list = @()
    if (-not (Test-Path $ConfigsDir)) { return $list }
    foreach ($toml in (Get-ChildItem $ConfigsDir -Filter 'project.toml' -Recurse -File)) {
        $folder = Split-Path $toml.DirectoryName -Leaf
        $list += @{ Folder = $folder; Path = $toml.FullName }
    }
    return $list
}

# ── Build single project via pack.ps1 ──
function Build-One([string]$folder) {
    W-Step "Packing project: $folder"
    & "$ScriptsDir\pack.ps1" $folder
    if ($LASTEXITCODE -ne 0) { W-Err "Pack failed: $folder"; return $false }
    return $true
}

# ── Clean old archives (keep most recent N per project) ──
$MaxArchivesPerProject = 1
function Clean-OldArchives {
    if (-not (Test-Path $PackagesDir)) { return }
    $groups = @{}
    Get-ChildItem $PackagesDir -Filter '*.tar.gz' |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $prefix = $_.Name -replace '-\d{8}-\d{6}\.tar\.gz$', '' `
                              -replace '-dist\.tar\.gz$', '' `
                              -replace '-package\.tar\.gz$', ''
            if (-not $groups[$prefix]) { $groups[$prefix] = @() }
            $groups[$prefix] += $_
        }
    foreach ($prefix in $groups.Keys) {
        $files = $groups[$prefix]
        if ($files.Count -gt $MaxArchivesPerProject) {
            $files | Select-Object -Skip $MaxArchivesPerProject | ForEach-Object {
                Remove-Item $_.FullName -Force
                W-Warn "Cleaned old archive: $($_.Name)"
            }
        }
    }
}

# ── Check source-vs-dist freshness (warn if source is newer than dist copy) ──
function Check-DistFreshness {
    $DistDir = Join-Path $DeployDir 'dist'
    if (-not (Test-Path $DistDir)) { return }

    # -- Core scripts: compare source vs dist --
    $scriptPairs = @(
        @{ Src = Join-Path $ScriptsDir 'deploy.sh';             Dst = Join-Path $DistDir 'deploy.sh' }
        @{ Src = Join-Path $ScriptsDir 'tools\detect-status.sh'; Dst = Join-Path $DistDir 'detect-status.sh' }
        @{ Src = Join-Path $ScriptsDir 'tools\generate-nginx.py';Dst = Join-Path $DistDir 'generate-nginx.py' }
        @{ Src = Join-Path $ScriptsDir 'deploy-financial-api.sh';Dst = Join-Path $DistDir 'deploy-financial-api.sh' }
        @{ Src = Join-Path $ScriptsDir 'pack.ps1';               Dst = Join-Path $DistDir 'pack.ps1' }
    )
    $stale = $false
    foreach ($pair in $scriptPairs) {
        if ((Test-Path $pair.Src) -and (Test-Path $pair.Dst)) {
            if ($pair.Src -and (Get-Item $pair.Src).LastWriteTime -gt (Get-Item $pair.Dst).LastWriteTime) {
                W-Warn "Source newer than dist: $(Split-Path $pair.Src -Leaf)"
                $stale = $true
            }
        }
    }

    # -- lib/ directory: compare each file --
    $libSrc = Join-Path $ScriptsDir 'lib'
    $libDst = Join-Path $DistDir 'lib'
    if ((Test-Path $libSrc) -and (Test-Path $libDst)) {
        Get-ChildItem $libSrc -File | ForEach-Object {
            $dstFile = Join-Path $libDst $_.Name
            if (Test-Path $dstFile) {
                if ($_.LastWriteTime -gt (Get-Item $dstFile).LastWriteTime) {
                    W-Warn "Source newer than dist: lib/$($_.Name)"
                    $stale = $true
                }
            } else {
                W-Warn "Missing in dist/: lib/$($_.Name)"
                $stale = $true
            }
        }
    }

    # -- configs/ directory: compare each file recursively --
    $cfgSrc = Join-Path $DeployDir 'configs'
    $cfgDst = Join-Path $DistDir 'configs'
    if ((Test-Path $cfgSrc) -and (Test-Path $cfgDst)) {
        Get-ChildItem $cfgSrc -File -Recurse | ForEach-Object {
            $rel = $_.FullName.Substring($cfgSrc.Length + 1)
            $dstFile = Join-Path $cfgDst $rel
            if (Test-Path $dstFile) {
                if ($_.LastWriteTime -gt (Get-Item $dstFile).LastWriteTime) {
                    W-Warn "Source newer than dist: configs/$rel"
                    $stale = $true
                }
            }
        }
    }

    if ($stale) {
        W-Warn "dist/ has stale files. Run: .\scripts\build.ps1 --scripts-only"
    }
}

# ── Copy deploy assets to dist/ ──
function Copy-DeployAssets {
    W-Step "Copying deploy assets to dist/..."
    $DistDir = Join-Path $DeployDir 'dist'
    if (-not (Test-Path $DistDir)) {
        New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    }

    # Core scripts (sourced from scripts/ and scripts/tools/)
    $copy = @(
        (Join-Path $ScriptsDir 'deploy.sh'),
        (Join-Path $ScriptsDir 'tools\detect-status.sh'),
        (Join-Path $ScriptsDir 'tools\generate-nginx.py'),
        (Join-Path $ScriptsDir 'deploy-financial-api.sh'),
        (Join-Path $ScriptsDir 'pack.ps1')
    )
    foreach ($f in $copy) {
        if (Test-Path $f) {
            Copy-Item $f (Join-Path $DistDir (Split-Path $f -Leaf)) -Force
            W-OK "Copied: $(Split-Path $f -Leaf)"
        }
    }

    # configs/
    if (Test-Path $DeployDir\configs) {
        $dc = Join-Path $DistDir 'configs'
        if (Test-Path $dc) { Remove-Item $dc -Recurse -Force }
        Copy-Item $DeployDir\configs $dc -Recurse -Force
        W-OK "Copied: configs/"
    }

    # lib/ (includes config_loader.py, load-projects.sh, _ps-common.ps1, etc.)
    if (Test-Path $ScriptsDir\lib) {
        $dl = Join-Path $DistDir 'lib'
        if (Test-Path $dl) { Remove-Item $dl -Recurse -Force }
        Copy-Item $ScriptsDir\lib $dl -Recurse -Force
        W-OK "Copied: lib/"
    }

    # project-configs/ (for server-side TOML reading via config_loader.py)
    if (Test-Path $ConfigsDir) {
        $dpc = Join-Path $DistDir 'project-configs'
        if (Test-Path $dpc) { Remove-Item $dpc -Recurse -Force }
        Copy-Item $ConfigsDir $dpc -Recurse -Force
        W-OK "Copied: project-configs/"
    }

    # deploy.env.example (template, always copy)
    if (Test-Path $DeployDir\deploy.env.example) {
        Copy-Item $DeployDir\deploy.env.example (Join-Path $DistDir 'deploy.env.example') -Force
        W-OK "Copied: deploy.env.example"
    }

    # Copy all deploy.env.* files (server-a, server-b, vm, etc.)
    # These contain real passwords but dist/ is also gitignored, so it's safe.
    Get-ChildItem $DeployDir -Filter 'deploy.env.*' -File |
        Where-Object { $_.Name -ne 'deploy.env.example' } |
        ForEach-Object {
            Copy-Item $_.FullName (Join-Path $DistDir $_.Name) -Force
            W-OK "Copied: $($_.Name)"
        }

    # -- Write .scripts-version stamp (for server-side freshness check) --
    # deploy.sh reads this on startup to detect stale scripts on the server.
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $stampFile = Join-Path $DistDir '.scripts-version'
    Set-Content -Path $stampFile -Value $stamp -NoNewline -Encoding $global:PS_FILE_ENCODING
    W-OK "Wrote .scripts-version: $stamp"
}

# ── Summary ──
function Show-Summary([string[]]$built) {
    Copy-DeployAssets
    Clean-OldArchives
    W-Banner "Build Summary"
    Write-Host "  Built projects: " -NoNewline
    Write-Host "$($built -join ', ')" -ForegroundColor White
    Write-Host ""
    Write-Host "  Packages in $PackagesDir :" -ForegroundColor White
    if (Test-Path $PackagesDir) {
        Get-ChildItem $PackagesDir -Filter '*.tar.gz' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                $size = "{0:N1} MB" -f ($_.Length / 1MB)
                Write-Host "    $($_.Name)  ($size)" -ForegroundColor Gray
            }
    }
    Write-Host ""
    Write-Host "  Upload & deploy:" -ForegroundColor White
    $DistDir = Join-Path $DeployDir 'dist'
    Write-Host "    scp -r $DistDir serverA:/www/wwwroot/project/uploads/" -ForegroundColor Cyan
    Write-Host "    cd /www/wwwroot/project/uploads/dist && bash deploy.sh" -ForegroundColor Cyan
    Write-Host ""
}

# ── Interactive menu ──
function Interactive-Menu {
    while ($true) {
        W-Banner "Build Tool (config-driven)"
        Write-Host "  Config source: project-configs/ ($($ProjectList.Count) projects)" -ForegroundColor DarkGray
        Write-Host "  Workspace:     $global:WorkspaceRoot" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [1] Build selected projects (multi-select)"
        Write-Host "  [2] Build all ($($ProjectList.Count) projects)"
        Write-Host "  [3] List packages"
        Write-Host "  [0] Exit"
        Write-Host ""
        Write-Host "  Tip: CLI also accepts component IDs, e.g. build.ps1 deepquant-backend,financial-api" -ForegroundColor DarkGray
        Write-Host ""
        $choice = Read-Host "  Select [0-3]"
        switch ($choice) {
            "1" { Interactive-Build }
            "2" { Build-All }
            "3" { List-Packages }
            "0" { Write-Host "Bye!"; exit 0 }
            default { W-Warn "Invalid selection" }
        }
        Write-Host ""
    }
}

function Interactive-Build {
    W-Banner "Select projects to build"
    Write-Host "  Enter numbers (space-separated, e.g. 1 3), or 'a' for all:" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $ProjectList.Count; $i++) {
        Write-Host "  [$($i + 1)] $($ProjectList[$i].Folder)" -ForegroundColor White
    }
    Write-Host "  [a] All"
    $input = Read-Host "  Select"
    if ($input -eq 'a') { Build-All; return }
    $selected = @()
    foreach ($c in $input -split '\s+') {
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $ProjectList.Count) {
            $selected += $ProjectList[$n - 1].Folder
        } else { W-Warn "Ignoring invalid: $c" }
    }
    if ($selected.Count -eq 0) { W-Warn "Nothing selected"; return }
    W-HR
    Write-Host "  Will build: $($selected -join ', ')" -ForegroundColor White
    W-HR
    $confirm = Read-Host "  Confirm? [y/N]"
    if ($confirm -notin 'y', 'Y') { W-Warn "Cancelled"; return }
    $built = @()
    foreach ($f in $selected) {
        if (Build-One $f) { $built += $f } else { W-Err "Failed: $f" }
    }
    if ($built.Count -gt 0) { Show-Summary $built }
}

function Build-All {
    $confirm = Read-Host "  Build all $($ProjectList.Count) projects? [y/N]"
    if ($confirm -notin 'y', 'Y') { W-Warn "Cancelled"; return }
    $built = @()
    foreach ($r in $ProjectList) {
        if (Build-One $r.Folder) { $built += $r.Folder } else { W-Err "Failed: $($r.Folder)" }
    }
    if ($built.Count -gt 0) { Show-Summary $built }
}

function List-Packages {
    W-Banner "Packages"
    if (-not (Test-Path $PackagesDir) -or
        -not (Get-ChildItem $PackagesDir -ErrorAction SilentlyContinue)) {
        W-Warn "No packages found, build first"
        return
    }
    Get-ChildItem $PackagesDir -Filter '*.tar.gz' |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $size = "{0:N1} MB" -f ($_.Length / 1MB)
            Write-Host "  $($_.Name)  ($size)" -ForegroundColor Gray
        }
    Write-Host ""
}

# ── Main ──
if ($env:WORKSPACE_ROOT) { $global:WorkspaceRoot = $env:WORKSPACE_ROOT }
else { $global:WorkspaceRoot = Split-Path $DeployDir -Parent }

$ProjectList = Get-ProjectConfigs
if ($ProjectList.Count -eq 0) {
    W-Err "No project-configs/*/project.toml found"
    exit 1
}

W-OK "Scanned $($ProjectList.Count) projects (project-configs/)"
foreach ($r in $ProjectList) { W-Info $r.Folder }
Write-Host ""

# -- Scripts-only mode: refresh dist/ scripts without building packages --
if ($ScriptsOnly) {
    W-Banner "Scripts-only mode (skip package build)"
    Copy-DeployAssets
    Clean-OldArchives
    W-OK "dist/ scripts refreshed. .scripts-version updated."
    Write-Host ""
    Write-Host "  Upload & deploy:" -ForegroundColor White
    $DistDir = Join-Path $DeployDir 'dist'
    Write-Host "    scp -r $DistDir serverA:/www/wwwroot/project/uploads/" -ForegroundColor Cyan
    Write-Host "    cd /www/wwwroot/project/uploads/dist && bash deploy.sh" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# -- Pre-build freshness check: warn if dist/ has stale scripts --
Check-DistFreshness

if ($Project -ne "") {
    if ($Project -eq 'all') {
        $built = @()
        foreach ($r in $ProjectList) { if (Build-One $r.Folder) { $built += $r.Folder } }
        Show-Summary $built
    } elseif ($Project -match ',') {
        $names = $Project -split ',' | ForEach-Object { $_.Trim() }
        $built = @()
        foreach ($n in $names) { if (Build-One $n) { $built += $n } }
        Show-Summary $built
    } else {
        if (Build-One $Project) { Show-Summary @($Project) }
    }
    exit 0
}

Interactive-Menu
