#requires -version 5.1
<#
.SYNOPSIS
    Build & deploy helper for all projects (Windows PowerShell)

.DESCRIPTION
    项目清单来自 projects.json（SSOT），不再扫描工作区目录作为可部署全集。
    扫描仅用于 --discover 报告未登记项目。

.EXAMPLE
    .\scripts\build.ps1                           # Interactive menu
    .\scripts\build.ps1 financial-web              # Build one project
    .\scripts\build.ps1 all                        # Build all
    .\scripts\build.ps1 financial-web,official-site # Build selected
    .\scripts\build.ps1 --discover                 # Scan & report unregistered
#>

param(
    [Parameter(Position=0)]
    [string]$Project = ""
)

$ErrorActionPreference = "Stop"
$ScriptsDir  = $PSScriptRoot
$DeployDir   = Split-Path $ScriptsDir -Parent
$ConfigsDir   = Join-Path $DeployDir 'configs'
$PackagesDir = Join-Path $DeployDir 'dist\packages'

# ── 加载项目清单 ──
. (Join-Path $ScriptsDir 'lib\load-projects.ps1')
$projects = Load-Projects
if (-not $projects) {
    Write-Host "[ERR] Failed to load projects.json" -ForegroundColor Red
    exit 1
}

function W-Step  { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function W-OK    { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function W-Warn  { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function W-Err   { param($msg) Write-Host "[ERR] $msg" -ForegroundColor Red }
function W-HR    { Write-Host "--------------------------------------------------" -ForegroundColor DarkGray }
function W-Banner { param($title) Write-Host ""; Write-Host "=" * 60 -ForegroundColor Cyan; Write-Host "  $title" -ForegroundColor Cyan; Write-Host "=" * 60 -ForegroundColor Cyan; Write-Host "" }

function Ensure-OutputDir {
    if (-not (Test-Path $PackagesDir)) {
        New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
    }
}

# ── 构建后自动清理旧包（保留最近 N 个）──
$MaxArchivesPerProject = 3
function Clean-OldArchives {
    if (-not (Test-Path $PackagesDir)) { return }
    $groups = @{}
    Get-ChildItem $PackagesDir -Filter '*.tar.gz' | Sort-Object LastWriteTime -Descending | ForEach-Object {
        # Extract project prefix (e.g. financial-api from financial-api-20260728-102403.tar.gz)
        $prefix = $_.Name -replace '-\d{8}-\d{6}\.tar\.gz$','' -replace '-dist\.tar\.gz$','' -replace '-package\.tar\.gz$',''
        if (-not $groups[$prefix]) { $groups[$prefix] = @() }
        $groups[$prefix] += $_
    }
    foreach ($prefix in $groups.Keys) {
        $files = $groups[$prefix]
        if ($files.Count -gt $MaxArchivesPerProject) {
            $old = $files | Select-Object -Skip $MaxArchivesPerProject
            foreach ($f in $old) {
                Remove-Item $f.FullName -Force
                W-Warn "Cleaned old archive: $($f.Name)"
            }
        }
    }
}

# ── 从 projects.json 构建项目列表 ──
function Build-ProjectList {
    $list = @()
    foreach ($p in $projects) {
        $srcPath = Join-Path $global:WorkspaceRoot $p.sourcePath
        if (-not (Test-Path $srcPath)) {
            W-Warn "Source not found: $($p.id) → $srcPath"
            continue
        }

        if ($p.kind -eq 'frontend') {
            $buildScript = $p.build.script
            $pkgPath = Join-Path $srcPath 'package.json'
            $buildCmd = "pnpm $buildScript"
            if (Test-Path $pkgPath) {
                try {
                    $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($pkg.scripts.'build:prod') { $buildCmd = "pnpm build:prod" }
                } catch { }
            }

            $envFile = ""
            if ($p.build.envFile) {
                $envPath = Join-Path $DeployDir $p.build.envFile
                if (Test-Path $envPath) { $envFile = $envPath }
            }

            $list += @{
                Id=$p.id; Name=$p.id; Dir=$srcPath; Desc=$p.displayName; Kind='frontend'
                BuildCmd=$buildCmd; TarName=$p.build.artifact; EnvFile=$envFile
            }
        }
        elseif ($p.kind -eq 'backend') {
            $packScript = Join-Path $ScriptsDir "pack-generic.ps1"
            $list += @{
                Id=$p.id; Name=$p.id; Dir=$srcPath; Desc=$p.displayName; Kind='backend'
                BuildCmd=''; TarName=$p.build.artifact; PackScript=$packScript; ProjectId=$p.id
            }
        }
    }
    return $list
}

# ── 构建单个项目 ──
function Build-One([string]$name) {
    $proj = @($ProjectList | Where-Object { $_.Name -eq $name })
    if ($proj.Count -eq 0) { W-Err "Unknown project: $name (not in projects.json)"; return $false }

    $p = $proj[0]
    W-Step "Build: $($p.Name) ($($p.Desc))..."

    # Copy env file if exists
    if ($p.EnvFile) {
        Copy-Item $p.EnvFile "$($p.Dir)\.env" -Force
        W-OK ".env copied"
    }

    # ── frontend: pnpm build + tar dist ──
    if ($p.Kind -eq 'frontend') {
        Push-Location $p.Dir
        try {
            if (-not (Test-Path "$($p.Dir)\node_modules")) {
                W-Warn "node_modules not found, running pnpm install..."
                pnpm install
            }
            W-Step "Running $($p.BuildCmd)..."
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            Invoke-Expression $p.BuildCmd 2>&1 | ForEach-Object { Write-Host $_ }
            $ErrorActionPreference = $prevEAP
            if ($LASTEXITCODE -ne 0) { W-Err "Build failed for $($p.Name)"; return $false }
            W-OK "Build complete: $($p.Name)"

            $distDir = Join-Path $p.Dir 'dist'
            if (-not (Test-Path $distDir)) {
                W-Err "dist/ not found after build"
                return $false
            }

            $tar = Join-Path $PackagesDir $p.TarName
            tar -czf $tar -C $distDir .
            W-OK "Packed: $tar"
        } catch { W-Err "Build failed: $_"; return $false }
        finally { Pop-Location }
        return $true
    }

    # ── backend: 调用通用打包器 ──
    if ($p.Kind -eq 'backend' -and $p.PackScript) {
        W-Step "Packing $($p.Name)..."
        & $p.PackScript -ProjectId $p.ProjectId -SourceDir $p.Dir
        if ($LASTEXITCODE -ne 0) { W-Err "Pack failed for $($p.Name)"; return $false }
        return $true
    }

    W-Err "Cannot determine build strategy for: $($p.Name) (Kind=$($p.Kind))"
    return $false
}

# ── 扫描工作区报告未登记项目（可选）──
function Discover-Unregistered {
    W-Banner "Discover: Unregistered Projects"
    $registered = $projects | ForEach-Object { $_.sourcePath }
    $exclude = @("node_modules", ".venv", "venv", ".git", "dist", "__pycache__", ".pnpm-store", "deploy", ".cursor", ".agents", ".codex", ".vscode", ".ignored", ".vite")

    $roots = Get-ChildItem -Path $global:WorkspaceRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $exclude -notcontains $_.Name }

    $found = $false
    foreach ($root in $roots) {
        $subDirs = Get-ChildItem -Path $root.FullName -Directory -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object {
                $exclude -notcontains $_.Name -and
                $_.FullName -notmatch '[\\/]node_modules[\\/]' -and
                $_.FullName -notmatch '[\\/]\.vite[\\/]' -and
                $_.FullName -notmatch '[\\/]\.ignored[\\/]'
            }

        foreach ($sub in $subDirs) {
            $relPath = $sub.FullName.Substring($global:WorkspaceRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            if ($registered -contains $relPath) { continue }

            # 检测是否是项目目录
            if ((Test-Path (Join-Path $sub.FullName 'package.json')) -or
                (Test-Path (Join-Path $sub.FullName 'pyproject.toml')) -or
                (Test-Path (Join-Path $sub.FullName 'requirements.txt'))) {
                Write-Host "  [unregistered] $relPath" -ForegroundColor Yellow
                Write-Host "    Add to projects.yaml: sourcePath: $relPath" -ForegroundColor DarkGray
                $found = $true
            }
        }
    }

    if (-not $found) {
        W-OK "All project directories are registered in projects.json"
    }
}

# ── 复制部署资产到 dist/ ──
function Copy-DeployAssets {
    W-Step "Copying deploy assets to dist/..."
    $DistDir = Join-Path $DeployDir 'dist'

    # deploy.sh
    Copy-Item (Join-Path $ScriptsDir 'deploy.sh') (Join-Path $DistDir 'deploy.sh') -Force
    W-OK "Copied: deploy.sh"

    # detect-status.sh
    $detectScript = Join-Path $ScriptsDir 'detect-status.sh'
    if (Test-Path $detectScript) {
        Copy-Item $detectScript (Join-Path $DistDir 'detect-status.sh') -Force
        W-OK "Copied: detect-status.sh"
    }

    # configs/
    if (Test-Path $ConfigsDir) {
        $distConfigs = Join-Path $DistDir 'configs'
        if (Test-Path $distConfigs) { Remove-Item $distConfigs -Recurse -Force }
        Copy-Item $ConfigsDir $distConfigs -Recurse -Force
        W-OK "Copied: configs/"
    }

    # lib/
    $libSrc = Join-Path $ScriptsDir 'lib'
    if (Test-Path $libSrc) {
        $distLib = Join-Path $DistDir 'lib'
        if (Test-Path $distLib) { Remove-Item $distLib -Recurse -Force }
        Copy-Item $libSrc $distLib -Recurse -Force
        W-OK "Copied: lib/"
    }

    # projects.json（deploy.sh 服务器端需要）
    $projectsJson = Join-Path $DeployDir 'projects.json'
    if (Test-Path $projectsJson) {
        Copy-Item $projectsJson (Join-Path $DistDir 'projects.json') -Force
        W-OK "Copied: projects.json"
    }

    # deploy.env.example
    $envExample = Join-Path $DeployDir 'deploy.env.example'
    if (Test-Path $envExample) {
        Copy-Item $envExample (Join-Path $DistDir 'deploy.env.example') -Force
        W-OK "Copied: deploy.env.example"
    }

    # generate-nginx.py (for sync-nginx command on server)
    $genNginx = Join-Path $ScriptsDir 'generate-nginx.py'
    if (Test-Path $genNginx) {
        $distScripts = Join-Path $DistDir 'scripts'
        if (-not (Test-Path $distScripts)) { New-Item $distScripts -ItemType Directory -Force | Out-Null }
        Copy-Item $genNginx (Join-Path $distScripts 'generate-nginx.py') -Force
        W-OK "Copied: scripts/generate-nginx.py"
    }
}

function Show-Summary([string[]]$built) {
    Copy-DeployAssets
    Clean-OldArchives

    W-Banner "Build Summary"
    Write-Host "  Built: " -NoNewline
    Write-Host "$($built -join ', ')" -ForegroundColor White
    Write-Host ""
    Write-Host "  Packages in $PackagesDir :" -ForegroundColor White
    Get-ChildItem $PackagesDir | ForEach-Object {
        $size = "{0:N1} MB" -f ($_.Length / 1MB)
        Write-Host "    $($_.Name)  ($size)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  dist/ self-contained:" -ForegroundColor White
    $DistDir = Join-Path $DeployDir 'dist'
    Write-Host "    deploy.sh, configs/, lib/, projects.json, packages/" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Upload & Deploy:" -ForegroundColor White
    Write-Host "    scp -r $DistDir serverA:/www/wwwroot/project/uploads/" -ForegroundColor Cyan
    Write-Host "    # Then on server:" -ForegroundColor DarkGray
    Write-Host "    cd /www/wwwroot/project/uploads/dist && bash deploy.sh" -ForegroundColor Cyan
    Write-Host ""
}

# ── Interactive menu ──
function Interactive-Menu {
    $firstRun = $true
    while ($true) {
        if ($firstRun) {
            W-Banner "Build Tool"
            Write-Host "  项目清单: projects.json ($($ProjectList.Count) projects)" -ForegroundColor DarkGray
            Write-Host "  工作区:   $global:WorkspaceRoot" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  命令行用法：" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1                    交互式菜单" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 {project}           单项目构建" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 proj1,proj2         多项目构建" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 all                 全量构建" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 discover          扫描未登记项目" -ForegroundColor DarkGray
            Write-Host ""
            $firstRun = $false
        }
        W-Banner "Build Tool"
        Write-Host "  [1] Build selected projects (multi-select)"
        Write-Host "  [2] Build all ($($ProjectList.Count) projects)"
        Write-Host "  [3] List packages"
        Write-Host "  [4] Discover unregistered projects"
        Write-Host "  [0] Exit"
        Write-Host ""
        $choice = Read-Host "  Select [0-4]"
        switch ($choice) {
            "1" { Interactive-Build }
            "2" { Build-All }
            "3" { List-Packages }
            "4" { Discover-Unregistered }
            "0" { Write-Host "Bye!"; exit 0 }
            default { W-Warn "Invalid choice" }
        }
        Write-Host ""
    }
}

function Interactive-Build {
    W-Banner "Select Projects to Build"
    Write-Host "  Enter numbers, space-separated (e.g. 1 3 5), or 'a' for all:"
    Write-Host ""
    for ($i = 0; $i -lt $ProjectList.Count; $i++) {
        $p = $ProjectList[$i]
        Write-Host "  [$($i+1)] $($p.Name)" -NoNewline
        Write-Host "  $($p.Desc)" -ForegroundColor DarkGray
    }
    Write-Host "  [a] All"
    Write-Host ""
    $input = Read-Host "  Select"
    if ($input -eq "a") { Build-All; return }

    $selected = @()
    foreach ($c in $input -split '\s+') {
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $ProjectList.Count) {
            $selected += $ProjectList[$n-1].Name
        } else {
            W-Warn "Ignoring invalid: $c"
        }
    }
    if ($selected.Count -eq 0) { W-Warn "No projects selected"; return }

    Write-Host ""
    W-HR
    Write-Host "  Will build: $($selected -join ', ')" -ForegroundColor White
    W-HR
    $confirm = Read-Host "  Confirm? [y/N]"
    if ($confirm -ne "y" -and $confirm -ne "Y") { W-Warn "Cancelled"; return }

    $built = @()
    foreach ($p in $selected) {
        if (Build-One $p) { $built += $p } else { W-Err "Failed: $p" }
    }
    if ($built.Count -gt 0) { Show-Summary $built }
}

function Build-All {
    $confirm = Read-Host "  Build ALL $($ProjectList.Count) projects? [y/N]"
    if ($confirm -ne "y" -and $confirm -ne "Y") { W-Warn "Cancelled"; return }

    $built = @()
    foreach ($p in $ProjectList) {
        if (Build-One $p.Name) { $built += $p.Name } else { W-Err "Failed: $($p.Name)" }
    }
    if ($built.Count -gt 0) { Show-Summary $built }
}

function List-Packages {
    W-Banner "Packages"
    if (-not (Test-Path $PackagesDir) -or (Get-ChildItem $PackagesDir -ErrorAction SilentlyContinue).Count -eq 0) {
        W-Warn "No packages found. Run a build first."
        return
    }
    Get-ChildItem $PackagesDir | ForEach-Object {
        $size = "{0:N1} MB" -f ($_.Length / 1MB)
        Write-Host "  $($_.Name)  ($size)" -ForegroundColor Gray
    }
    Write-Host ""
}

# ── Main ──
Ensure-OutputDir
$ProjectList = Build-ProjectList

if ($ProjectList.Count -eq 0) {
    W-Err "No buildable projects found (check projects.json and source paths)"
    exit 1
}

W-OK "Loaded $($ProjectList.Count) projects from projects.json"
foreach ($p in $ProjectList) {
    Write-Host "    $($p.Name)  ($($p.Desc))" -ForegroundColor Gray
}
Write-Host ""

# CLI mode
if ($Project -ne "") {
    if ($Project -eq "discover") {
        Discover-Unregistered
        exit 0
    }
    if ($Project -eq "all") {
        $built = @()
        foreach ($p in $ProjectList) { if (Build-One $p.Name) { $built += $p.Name } }
        Show-Summary $built
    } elseif ($Project -match ",") {
        $names = $Project -split ","
        $built = @()
        foreach ($n in $names) { $n = $n.Trim(); if (Build-One $n) { $built += $n } }
        Show-Summary $built
    } else {
        if (Build-One $Project) { Show-Summary @($Project) }
    }
    exit 0
}

# Interactive
Interactive-Menu
