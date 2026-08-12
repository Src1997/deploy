#requires -version 5.1
<#
.SYNOPSIS
    Build & deploy helper (config-driven, Windows PowerShell).

.DESCRIPTION
    Config source = project-configs/<project>/project.toml (SSOT).
    This script:
      1. Calls sync-manifest.py to compile TOML configs -> projects.json
      2. Calls pack.ps1 to build & pack each selected project
      3. Copies deploy assets to dist/ (self-contained, for server upload)

    Adding a new project = create project-configs/<name>/project.toml.
    No script changes needed.

.EXAMPLE
    .\scripts\build.ps1                          # Interactive menu
    .\scripts\build.ps1 financial                # Build single project group
    .\scripts\build.ps1 deepquant-backend        # Build single component
    .\scripts\build.ps1 deepquant-backend,financial-api  # Build N components
    .\scripts\build.ps1 all                      # Build all
    .\scripts\build.ps1 financial,official-site  # Build multiple groups
#>

param(
    [Parameter(Position = 0)]
    [string]$Project = ""
)

$ErrorActionPreference = "Stop"
$ScriptsDir   = $PSScriptRoot
$DeployDir    = Split-Path $ScriptsDir -Parent
$ConfigsDir   = Join-Path $DeployDir 'project-configs'
$PackagesDir  = Join-Path $DeployDir 'dist\packages'

# ── Logging helpers ──
function W-Step  { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function W-OK    { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function W-Warn  { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function W-Err   { param($msg) Write-Host "[ERR] $msg" -ForegroundColor Red }
function W-Info  { param($msg) Write-Host "    $msg" -ForegroundColor DarkGray }
function W-Banner {
    param($title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}
function W-HR { Write-Host "--------------------------------------------------" -ForegroundColor DarkGray }

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

# ── Python locator (compatible with WorkBuddy managed binaries / python3 / python) ──
function Get-Python {
    $candidates = @()
    # 1) WorkBuddy managed binary (most reliable, preferred)
    $wb = Join-Path $env:USERPROFILE '.workbuddy\binaries\python\versions'
    if (Test-Path $wb) {
        $found = Get-ChildItem $wb -Filter 'python.exe' -Recurse -File |
            Sort-Object FullName | Select-Object -First 1
        if ($found) { $candidates += $found.FullName }
    }
    # 2) python3 / python on PATH
    foreach ($c in @('python3', 'python')) {
        try { $p = (Get-Command $c -ErrorAction Stop).Source; if ($p) { $candidates += $p } } catch { }
    }
    foreach ($p in $candidates) {
        # Verify it actually runs (filters out Windows Store placeholders)
        try {
            $v = & $p -c "import sys; print(sys.version_info[0])" 2>$null
            if ($LASTEXITCODE -eq 0 -and ($v -match '^\d+')) { return $p }
        } catch { }
    }
    throw "No usable python3/python found (Windows Store placeholder excluded). Install Python 3.11+ or add to PATH."
}

# ── Sync TOML configs -> projects.json ──
function Sync-Manifest {
    W-Step "sync-manifest.py: compiling project-configs/*.toml -> projects.json"
    $gen = Join-Path $ScriptsDir 'sync-manifest.py'
    $py = Get-Python
    & $py $gen
    if ($LASTEXITCODE -ne 0) { W-Err "sync-manifest.py failed"; exit 1 }
}

# ── Build single project via pack.ps1 ──
function Build-One([string]$folder) {
    W-Step "Packing project: $folder"
    & "$ScriptsDir\pack.ps1" $folder
    if ($LASTEXITCODE -ne 0) { W-Err "Pack failed: $folder"; return $false }
    return $true
}

# ── Clean old archives (keep most recent N per project) ──
$MaxArchivesPerProject = 3
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

# ── Copy deploy assets to dist/ ──
function Copy-DeployAssets {
    W-Step "Copying deploy assets to dist/..."
    $DistDir = Join-Path $DeployDir 'dist'
    if (-not (Test-Path $DistDir)) {
        New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    }

    # Core scripts
    $copy = @(
        (Join-Path $ScriptsDir 'deploy.sh'),
        (Join-Path $ScriptsDir 'detect-status.sh'),
        (Join-Path $ScriptsDir 'generate-nginx.py'),
        (Join-Path $ScriptsDir 'deploy-financial-api.sh'),
        (Join-Path $ScriptsDir 'pack.ps1'),
        (Join-Path $ScriptsDir 'sync-manifest.py')
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

    # lib/
    if (Test-Path $ScriptsDir\lib) {
        $dl = Join-Path $DistDir 'lib'
        if (Test-Path $dl) { Remove-Item $dl -Recurse -Force }
        Copy-Item $ScriptsDir\lib $dl -Recurse -Force
        W-OK "Copied: lib/"
    }

    # scripts/ (for server-side fallback)
    $ds = Join-Path $DistDir 'scripts'
    if (-not (Test-Path $ds)) {
        New-Item -ItemType Directory -Path $ds -Force | Out-Null
    }
    foreach ($f in @('generate-nginx.py', 'deploy-financial-api.sh', 'pack.ps1', 'sync-manifest.py')) {
        $src = Join-Path $ScriptsDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $ds $f) -Force }
    }

    # project-configs/ (for server-side reference)
    if (Test-Path $ConfigsDir) {
        $dpc = Join-Path $DistDir 'project-configs'
        if (Test-Path $dpc) { Remove-Item $dpc -Recurse -Force }
        Copy-Item $ConfigsDir $dpc -Recurse -Force
        W-OK "Copied: project-configs/"
    }

    # projects.json (manifest, deploy.sh needs it)
    if (Test-Path $DeployDir\projects.json) {
        Copy-Item $DeployDir\projects.json (Join-Path $DistDir 'projects.json') -Force
        W-OK "Copied: projects.json"
    }

    # deploy.env.example
    if (Test-Path $DeployDir\deploy.env.example) {
        Copy-Item $DeployDir\deploy.env.example (Join-Path $DistDir 'deploy.env.example') -Force
        W-OK "Copied: deploy.env.example"
    }
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

Sync-Manifest
W-OK "Scanned $($ProjectList.Count) projects (project-configs/)"
foreach ($r in $ProjectList) { W-Info $r.Folder }
Write-Host ""

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
