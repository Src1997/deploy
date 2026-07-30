#requires -version 5.1
<#
.SYNOPSIS
    通用后端打包器（参数化，不写死项目路径）

.DESCRIPTION
    从 projects.json 读取项目配置，打包源码 + 部署资产到 tar.gz。

    布局约定（保持目录层次，禁止把 include 拍扁到根）：
      package/                 # 应用源码 + VERSION
      scripts/...              # include 里 scripts/ 原路径
      configs/...              # include 里 configs/ 原路径

      build.mode = source-tar 时无 package/ 前缀：源码在归档根，include 仍保留相对路径。

.EXAMPLE
    .\scripts\pack-generic.ps1 -ProjectId financial-api
#>
param(
    [Parameter(Position=0)]
    [string]$ProjectId = "",

    [string]$SourceDir = "",
    [string]$OutDir = "",
    [string]$NamePrefix = "",
    [string[]]$IncludeFiles = @()
)

$ErrorActionPreference = "Stop"
$ScriptsDir = $PSScriptRoot
$DeployDir = Split-Path $ScriptsDir -Parent

. (Join-Path $ScriptsDir 'lib\load-projects.ps1')

if (-not $ProjectId) {
    $projects = Load-Projects
    if (-not $projects) { Write-Error "No projects loaded"; exit 1 }
    Write-Host "`n[*] Backend projects:" -ForegroundColor Cyan
    $backends = @($projects | Where-Object { $_.kind -eq 'backend' })
    $i = 1
    foreach ($p in $backends) {
        Write-Host "  [$i] $($p.id)  ($($p.displayName))"
        $i++
    }
    $sel = Read-Host "`n  Select [1-$($backends.Count)]"
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $backends.Count) {
        $ProjectId = $backends[$n - 1].id
    } else {
        Write-Error "Invalid selection"
        exit 1
    }
}

$proj = Get-ProjectById $ProjectId
if (-not $proj) {
    Write-Error "Project '$ProjectId' not found in projects.json"
    exit 1
}

if (-not $SourceDir) { $SourceDir = Get-ProjectSourcePath $ProjectId }
if (-not $OutDir) { $OutDir = Join-Path $DeployDir 'dist\packages' }
if (-not $NamePrefix) { $NamePrefix = $ProjectId }

if (-not (Test-Path $SourceDir)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$mode = ""
if ($proj.build.mode) { $mode = [string]$proj.build.mode }
# source-tar → 源码在归档根；其它后端源码进 package/（与 deploy 钩子约定）
$usePackagePrefix = ($mode -ne 'source-tar')

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tarName = "${NamePrefix}-${timestamp}.tar.gz"
$tarPath = Join-Path $OutDir $tarName

Write-Host "`n[*] Packing: $ProjectId" -ForegroundColor Cyan
Write-Host "    Source:    $SourceDir"
Write-Host "    Layout:    $(if ($usePackagePrefix) { 'package/ + scripts/ + configs/' } else { 'flat source + keep include paths' })"
Write-Host "    Output:    $tarPath"
Write-Host ""

if ($IncludeFiles.Count -eq 0 -and $proj.build.include) {
    $IncludeFiles = @($proj.build.include)
}

$staging = Join-Path $env:TEMP "pack-${ProjectId}-${timestamp}"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$codeRoot = if ($usePackagePrefix) {
    Join-Path $staging 'package'
} else {
    $staging
}
New-Item -ItemType Directory -Path $codeRoot -Force | Out-Null

# 源码 → codeRoot（排除运行时目录）
robocopy $SourceDir $codeRoot /E `
    /XD .env .venv venv logs __pycache__ .git node_modules `
    /XF *.pyc `
    /NFL /NDL /NJH /NJS /NC /NS 2>$null | Out-Null
if ($LASTEXITCODE -gt 7) {
    Write-Error "robocopy failed (exit $LASTEXITCODE)"
    exit 1
}

# VERSION 放在源码根
$versionFile = Join-Path $codeRoot 'VERSION'
@(
    "project=$ProjectId"
    "built=$timestamp"
    "host=$env:COMPUTERNAME"
) | Set-Content -Path $versionFile -Encoding UTF8
Write-Host "    [ok]      $(if ($usePackagePrefix) { 'package/VERSION' } else { 'VERSION' })" -ForegroundColor DarkGray

# include：相对 deploy 根的路径原样保留到归档根（禁止 basename 拍扁）
foreach ($f in $IncludeFiles) {
    $rel = ($f -replace '\\', '/').TrimStart('/')
    $src = Join-Path $DeployDir $rel
    if (-not (Test-Path $src)) {
        Write-Host "    [skip]     $rel (not found)" -ForegroundColor DarkYellow
        continue
    }
    $dest = Join-Path $staging ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    $destParent = Split-Path $dest -Parent
    if (-not (Test-Path $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    Copy-Item $src $dest -Force
    Write-Host "    [include] $rel" -ForegroundColor DarkGray
}

Push-Location $staging
try {
    $items = @(Get-ChildItem -Force | ForEach-Object { $_.Name })
    if ($items.Count -eq 0) { Write-Error "staging empty"; exit 1 }
    & tar -czf $tarPath @items
    $size = "{0:N1} MB" -f ((Get-Item $tarPath).Length / 1MB)
    Write-Host ""
    Write-Host "[OK] Packed: $tarName" -ForegroundColor Green
    Write-Host "     Size:  $size" -ForegroundColor Gray
} catch {
    Write-Error "tar failed: $_"
    exit 1
} finally {
    Pop-Location
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}
