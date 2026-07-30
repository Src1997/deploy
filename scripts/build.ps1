#requires -version 5.1
<#
.SYNOPSIS
    Build & deploy helper for all projects (Windows PowerShell)

.DESCRIPTION
    Interactive build tool with project selection, or direct CLI mode.

.EXAMPLE
    .\scripts\build.ps1                           # Interactive menu
    .\scripts\build.ps1 financial-web              # Build one project
    .\scripts\build.ps1 all                        # Build all
    .\scripts\build.ps1 financial-web,official-site # Build selected
#>

param(
    [Parameter(Position=0)]
    [string]$Project = ""
)

$ErrorActionPreference = "Stop"
$ScriptsDir  = $PSScriptRoot
$DeployDir   = Split-Path $ScriptsDir -Parent
$Workspace   = if ($env:WORKSPACE_ROOT) { $env:WORKSPACE_ROOT } else { Split-Path $DeployDir -Parent }
$ConfigsDir  = Join-Path $DeployDir 'configs'
$PackagesDir = Join-Path $DeployDir 'dist\packages'

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

# ── 名称映射（目录名 → 部署项目名）──────────────────────────────
$NameMapping = @{
    "deepquant_vue"       = "deepquant-web"
    "backend_api_python"  = "deepquant-backend"
}

# ── 自动扫描工作区 ────────────────────────────────────────────────
$ExcludeDirs = @("node_modules", ".venv", "venv", ".git", "dist", "__pycache__", ".pnpm-store", "deploy", ".cursor", ".agents", ".codex", "codex", ".vscode")

function Map-Name([string]$dirName) {
    if ($NameMapping.ContainsKey($dirName)) { return $NameMapping[$dirName] }
    return $dirName
}

function Test-ProjectDir([string]$path) {
    $dirName = Split-Path $path -Leaf

    # 前端：package.json + build script
    $pkgPath = Join-Path $path "package.json"
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pkg.scripts.build -or $pkg.scripts.'build:prod') {
                $projName = Map-Name $dirName
                $buildCmd = if ($pkg.scripts.'build:prod') { "pnpm build:prod" } else { "pnpm build" }
                $envFile = "$ConfigsDir\$projName.env"
                if (-not (Test-Path $envFile)) { $envFile = "" }
                return @{
                    Name=$projName; Dir=$path; Desc="前端"; Type="frontend"
                    BuildCmd=$buildCmd; TarName="$projName-dist.tar.gz"
                    PackScript=""; EnvFile=$envFile
                }
            }
        } catch { }
    }

    # 后端（uv）：pyproject.toml → 需有对应的 pack 脚本才算可部署
    if (Test-Path (Join-Path $path "pyproject.toml")) {
        $projName = Map-Name $dirName
        $packScript = "$ScriptsDir\pack-$projName.ps1"
        if (Test-Path $packScript) {
            return @{
                Name=$projName; Dir=$path; Desc="Python 后端 (uv)"; Type="backend"
                BuildCmd=""; TarName=""; PackScript=$packScript; EnvFile=""
            }
        }
        # 无对应 pack 脚本 → 子模块（可独立打包但属父项目）
        $parentName = Split-Path (Split-Path $path -Parent) -Leaf
        return @{
            Name=$projName; Dir=$path; Desc="子模块 (Python, 属 $parentName)"; Type="submodule"
            BuildCmd=""; TarName=""; PackScript=""; EnvFile=""
        }
    }

    # 后端（pip）：requirements.txt → 简单 tar
    if (Test-Path (Join-Path $path "requirements.txt")) {
        $projName = Map-Name $dirName
        return @{
            Name=$projName; Dir=$path; Desc="Python 后端 (pip)"; Type="backend"
            BuildCmd=""; TarName="$projName-package.tar.gz"; PackScript=""; EnvFile=""
        }
    }

    return $null
}

function Scan-Projects {
    $found = @()
    $exclude = $ExcludeDirs

    # 扫描顶层目录
    $roots = Get-ChildItem -Path $Workspace -Directory -ErrorAction SilentlyContinue |
        Where-Object { $exclude -notcontains $_.Name }

    foreach ($root in $roots) {
        # 检查根目录本身
        $proj = Test-ProjectDir $root.FullName
        if ($proj) { $found += $proj; continue }

        # 扫描子目录（深度 1-2）
        $subDirs = Get-ChildItem -Path $root.FullName -Directory -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object {
                $exclude -notcontains $_.Name -and
                $exclude -notcontains $_.Parent.Name
            }

        foreach ($sub in $subDirs) {
            # 跳过已找到的相同路径
            if ($found | Where-Object { $_.Dir -eq $sub.FullName }) { continue }
            $proj = Test-ProjectDir $sub.FullName
            if ($proj) { $found += $proj }
        }
    }

    # 排序：按名称排序，同一项目的前后端自然聚在一起
    return $found | Sort-Object Name
}

# ── 扫描项目 ─────────────────────────────────────────────────────
W-Step "Scanning workspace for projects..."
$allFound = Scan-Projects
# 分离可部署项目和子模块
$ProjectList = @($allFound | Where-Object { $_.Type -ne "submodule" })
$SubModules = @($allFound | Where-Object { $_.Type -eq "submodule" })
if ($ProjectList.Count -eq 0) {
    W-Err "No projects found in $Workspace"
    exit 1
}
W-OK "Found $($ProjectList.Count) projects:"
foreach ($p in $ProjectList) {
    Write-Host "    $($p.Name)  ($($p.Desc))" -ForegroundColor Gray
}
if ($SubModules.Count -gt 0) {
    Write-Host ""
    Write-Host "  含子模块（不可独立部署，随父项目打包）:" -ForegroundColor DarkYellow
    foreach ($s in $SubModules) {
        Write-Host "    $($s.Name)  ($($s.Desc))" -ForegroundColor DarkGray
    }
}

function Build-One([string]$name) {
    $proj = $ProjectList | Where-Object { $_.Name -eq $name }
    if (-not $proj) { W-Err "Unknown project: $name"; return $false }

    $p = $proj[0]
    W-Step "Build: $($p.Name) ($($p.Desc))..."

    # Copy env file if exists
    if ($p.EnvFile) {
        Copy-Item $p.EnvFile "$($p.Dir)\.env" -Force
        W-OK ".env copied"
    }

    # ── frontend: pnpm build + tar dist ──
    if ($p.Type -eq "frontend") {
        Push-Location $p.Dir
        try {
            if (-not (Test-Path "$($p.Dir)\node_modules")) {
                W-Warn "node_modules not found, running pnpm install..."
                pnpm install
            }
            W-Step "Running $($p.BuildCmd)..."
            Invoke-Expression $p.BuildCmd
            if ($LASTEXITCODE -ne 0) { W-Err "Build failed for $($p.Name)"; return $false }
            W-OK "Build complete: $($p.Name)"
            $tar = "$PackagesDir\$($p.TarName)"
            tar -czf $tar -C "$($p.Dir)\dist" .
            W-OK "Packed: $tar"
        } catch { W-Err "Build failed: $_"; return $false }
        finally { Pop-Location }
        return $true
    }

    # ── backend with PackScript: call pack script (financial-api) ──
    if ($p.PackScript -and (Test-Path $p.PackScript)) {
        Push-Location $p.Dir
        try {
            & $p.PackScript
            $faDists = Get-ChildItem "$DeployDir\dist\financial-api-*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($faDists) {
                Copy-Item $faDists.FullName $PackagesDir -Force
                W-OK "Packed: $($faDists.Name)"
            }
        } catch { W-Err "Pack failed: $_"; return $false }
        finally { Pop-Location }
        return $true
    }

    # ── backend without PackScript (pip): source tar (deepquant-backend) ──
    if ($p.Type -eq "backend" -and $p.TarName) {
        Push-Location $p.Dir
        try {
            $tar = "$PackagesDir\$($p.TarName)"
            tar -czf $tar --exclude=.env --exclude=.venv --exclude=venv --exclude=logs --exclude=__pycache__ --exclude=*.pyc --exclude=.git --exclude=data/memory .
            W-OK "Packed: $tar"
        } catch { W-Err "Pack failed: $_"; return $false }
        finally { Pop-Location }
        return $true
    }

    W-Err "Cannot determine build strategy for: $($p.Name) (Type=$($p.Type))"
    return $false
}

# ── 复制部署资产到 dist/（使 dist/ 自包含可上传）──────────────────
function Copy-DeployAssets {
    W-Step "Copying deploy assets to dist/..."
    $DistDir = Join-Path $DeployDir 'dist'

    # deploy.sh
    Copy-Item (Join-Path $ScriptsDir 'deploy.sh') (Join-Path $DistDir 'deploy.sh') -Force
    W-OK "Copied: deploy.sh"

    # detect-status.sh（可选）
    $detectScript = Join-Path $ScriptsDir 'detect-status.sh'
    if (Test-Path $detectScript) {
        Copy-Item $detectScript (Join-Path $DistDir 'detect-status.sh') -Force
        W-OK "Copied: detect-status.sh"
    }

    # configs/（nginx、systemd、env 模板等）
    if (Test-Path $ConfigsDir) {
        $distConfigs = Join-Path $DistDir 'configs'
        if (Test-Path $distConfigs) { Remove-Item $distConfigs -Recurse -Force }
        Copy-Item $ConfigsDir $distConfigs -Recurse -Force
        W-OK "Copied: configs/"
    }

    # scripts/lib（deploy.sh 加载 deploy.env）
    $libSrc = Join-Path $ScriptsDir 'lib'
    if (Test-Path $libSrc) {
        $distLib = Join-Path $DistDir 'lib'
        if (Test-Path $distLib) { Remove-Item $distLib -Recurse -Force }
        Copy-Item $libSrc $distLib -Recurse -Force
        W-OK "Copied: lib/"
    }

    # deploy.env.example（提醒服务器配置，不含真实密码）
    $envExample = Join-Path $DeployDir 'deploy.env.example'
    if (Test-Path $envExample) {
        Copy-Item $envExample (Join-Path $DistDir 'deploy.env.example') -Force
        W-OK "Copied: deploy.env.example"
    }
}

function Show-Summary([string[]]$built) {
    # 确保 dist/ 自包含（deploy.sh + configs/）
    Copy-DeployAssets

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
    Write-Host "    deploy.sh, configs/, packages/" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Upload & Deploy:" -ForegroundColor White
    Write-Host "    scp -r $DistDir serverA:/www/wwwroot/project/uploads/" -ForegroundColor Cyan
    Write-Host "    scp -r $DistDir serverB:/www/wwwroot/project/uploads/" -ForegroundColor Cyan
    Write-Host "    # Then on server:" -ForegroundColor DarkGray
    Write-Host "    cd /www/wwwroot/project/uploads/dist && bash deploy.sh" -ForegroundColor Cyan
    Write-Host ""
}

# ── Interactive menu ────────────────────────────────────────────
function Interactive-Menu {
    # 首次进入显示帮助
    $firstRun = $true
    while ($true) {
        if ($firstRun) {
            W-Banner "Build Tool"
            Write-Host "  命令行用法：" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1                    交互式菜单" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 <project>           单项目构建" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 proj1,proj2         多项目构建" -ForegroundColor DarkGray
            Write-Host "    .\scripts\build.ps1 all                 全量构建" -ForegroundColor DarkGray
            Write-Host ""
            $firstRun = $false
        }
        W-Banner "Build Tool"
        Write-Host "  [1] Build selected projects (multi-select)"
        Write-Host "  [2] Build all ($($ProjectList.Count) projects)"
        Write-Host "  [3] List packages"
        Write-Host "  [4] Re-scan projects"
        Write-Host "  [0] Exit"
        Write-Host ""
        $choice = Read-Host "  Select [0-4]"
        switch ($choice) {
            "1" { Interactive-Build }
            "2" { Build-All }
            "3" { List-Packages }
            "4" { W-Step "Re-scanning..."; $ProjectList = Scan-Projects; W-OK "Found $($ProjectList.Count) projects" }
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

    # Confirm
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

# ── Main ─────────────────────────────────────────────────────────
Ensure-OutputDir

# CLI mode
if ($Project -ne "") {
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
