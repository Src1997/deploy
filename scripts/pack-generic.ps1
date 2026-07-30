#requires -version 5.1
<#
.SYNOPSIS
    通用后端打包器（参数化，不写死项目路径）

.DESCRIPTION
    从 projects.json 读取项目配置，打包源码 + 部署资产到 tar.gz。
    被 build.ps1 调用，或可独立运行。

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

# 加载项目清单
. (Join-Path $ScriptsDir 'lib\load-projects.ps1')

if (-not $ProjectId) {
    # 交互式选择
    $projects = Load-Projects
    if (-not $projects) { Write-Error "No projects loaded"; exit 1 }
    Write-Host "`n[*] Backend projects:" -ForegroundColor Cyan
    $backends = $projects | Where-Object { $_.kind -eq 'backend' }
    $i = 1
    foreach ($p in $backends) {
        Write-Host "  [$i] $($p.id)  ($($p.displayName))"
        $i++
    }
    $sel = Read-Host "`n  Select [1-$($backends.Count)]"
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $backends.Count) {
        $ProjectId = $backends[$n-1].id
    } else {
        Write-Error "Invalid selection"
        exit 1
    }
}

# 获取项目配置
$proj = Get-ProjectById $ProjectId
if (-not $proj) {
    Write-Error "Project '$ProjectId' not found in projects.json"
    exit 1
}

# 解析路径
if (-not $SourceDir) { $SourceDir = Get-ProjectSourcePath $ProjectId }
if (-not $OutDir) {
    $OutDir = Join-Path $DeployDir 'dist\packages'
}
if (-not $NamePrefix) { $NamePrefix = $ProjectId }

if (-not (Test-Path $SourceDir)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# 时间戳
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tarName = "${NamePrefix}-${timestamp}.tar.gz"
$tarPath = Join-Path $OutDir $tarName

Write-Host "`n[*] Packing: $ProjectId" -ForegroundColor Cyan
Write-Host "    Source:    $SourceDir"
Write-Host "    Output:    $tarPath"
Write-Host ""

# Include files（部署脚本、systemd unit、env 模板等）
$includeList = @()
if ($IncludeFiles.Count -eq 0 -and $proj.build.include) {
    $IncludeFiles = $proj.build.include
}

$deployDir = $DeployDir
$tempInclude = Join-Path $env:TEMP "pack-${ProjectId}-${timestamp}"
if (Test-Path $tempInclude) { Remove-Item $tempInclude -Recurse -Force }
New-Item -ItemType Directory -Path $tempInclude -Force | Out-Null

foreach ($f in $IncludeFiles) {
    $src = Join-Path $deployDir $f
    if (Test-Path $src) {
        $dest = Join-Path $tempInclude $f
        $destParent = Split-Path $dest -Parent
        if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
        Copy-Item $src $dest -Force
        $includeList += $f
        Write-Host "    [include] $f" -ForegroundColor DarkGray
    } else {
        Write-Host "    [skip]     $f (not found)" -ForegroundColor DarkYellow
    }
}

# Exclude patterns
$excludeArgs = @('--exclude=.env', '--exclude=.venv', '--exclude=venv',
                  '--exclude=logs', '--exclude=__pycache__', '--exclude=*.pyc',
                  '--exclude=.git', '--exclude=node_modules')
if ($proj.build.exclude) {
    $excludeArgs = $proj.build.exclude | ForEach-Object { "--exclude=$_" }
}

# 打包源码
Write-Host "    Packing source..." -ForegroundColor DarkGray
$tempSrc = Join-Path $env:TEMP "packsrc-${ProjectId}-${timestamp}"
if (Test-Path $tempSrc) { Remove-Item $tempSrc -Recurse -Force }
New-Item -ItemType Directory -Path $tempSrc -Force | Out-Null

# 拷贝源码到临时目录（排除模式）
$sourceName = Split-Path $SourceDir -Leaf
$destSrc = Join-Path $tempSrc $sourceName
robocopy $SourceDir $destSrc /MIR /XD .env .venv venv logs __pycache__ .git node_modules /XF *.pyc /NFL /NDL /NJH /NJS /NC /NS 2>$null
if ($LASTEXITCODE -gt 7) { Write-Error "robocopy failed"; exit 1 }

# 拷贝 include 文件到临时目录
$destInclude = Join-Path $tempSrc 'deploy-assets'
if (Test-Path $tempInclude) {
    robocopy $tempInclude $destInclude /E /NFL /NDL /NJH /NJS /NC /NS 2>$null
}

# 创建 tar.gz
Push-Location $tempSrc
try {
    tar -czf $tarPath .
    Write-Host ""
    Write-Host "[OK] Packed: $tarName" -ForegroundColor Green
    $size = "{0:N1} MB" -f ((Get-Item $tarPath).Length / 1MB)
    Write-Host "     Size:  $size" -ForegroundColor Gray
} catch {
    Write-Error "tar failed: $_"
    exit 1
} finally {
    Pop-Location
    # 清理临时目录
    Remove-Item $tempSrc -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $tempInclude -Recurse -Force -ErrorAction SilentlyContinue
}
