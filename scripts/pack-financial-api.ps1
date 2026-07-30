<#
.SYNOPSIS
  Pack backend code into archive for manual upload to server.

.DESCRIPTION
  Packs financial-api source code + deploy.sh + systemd service files into a
  tar.gz (or zip) archive under deploy/dist/.

  Frontend is NOT included — build and deploy instructions are in
  financial-web/README.md.

.EXAMPLE
  .\pack.ps1
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # deploy/scripts/
$DeployDir = Split-Path -Parent $ScriptDir                        # deploy/
$Workspace = Split-Path -Parent $DeployDir                       # workspace root
$ApiSrc    = Join-Path $Workspace 'financial\financial-api'        # financial-api 源码
$OutputDir = Join-Path $DeployDir 'dist'
$ConfigsDir = Join-Path $DeployDir 'configs'                     # 配置文件
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Step([string]$msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "[ERR] $msg" -ForegroundColor Red }

function Test-Command([string]$cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# ── Pack backend ──────────────────────────────────────────────────────────────

Write-Host "`n========================================" -ForegroundColor DarkCyan
Write-Host "  Financial API — Pack Tool" -ForegroundColor DarkCyan
Write-Host "========================================" -ForegroundColor DarkCyan

Write-Step 'Packing backend (financial-api)'

if (-not (Test-Path $ApiSrc)) {
    Write-Err "Backend directory not found: $ApiSrc"
    exit 1
}

# ── 创建 staging 目录（必须在写 VERSION 之前）──
$staging = Join-Path $env:TEMP "financial-api-staging-$Timestamp"
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# ── 生成 VERSION 文件（git commit + 打包时间）────────────────────────────
$gitHash = "unknown"
$gitBranch = "unknown"
$gitDirty = ""
try {
    $gitHash = (git -C $ApiSrc rev-parse --short HEAD 2>$null).Trim()
    $gitBranch = (git -C $ApiSrc rev-parse --abbrev-ref HEAD 2>$null).Trim()
    $gitStatus = git -C $ApiSrc status --porcelain 2>$null
    if ($gitStatus) { $gitDirty = " (dirty: uncommitted changes)" }
} catch { $gitHash = "unknown (git not available)" }
$versionContent = @"
project: financial-api
commit: $gitHash
branch: $gitBranch$gitDirty
packed_at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
packed_by: $env:USERNAME@$env:COMPUTERNAME
"@
$versionFile = Join-Path $staging 'VERSION'
Set-Content -Path $versionFile -Value $versionContent -Encoding UTF8
Write-Host "  Added: VERSION ($gitHash$gitDirty)" -ForegroundColor DarkGray

# Include code directories and config files
$includeItems = @('app', 'worker', 'alembic', 'scripts', 'pyproject.toml', 'alembic.ini', '.env.example')

foreach ($item in $includeItems) {
    $src = Join-Path $ApiSrc $item
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $staging -Recurse -Force
    } else {
        Write-Host "  Skipped (not found): $item" -ForegroundColor Yellow
    }
}

# Include deploy.sh (server-side deploy script)
$deployScript = Join-Path $ScriptDir 'deploy-financial-api.sh'
if (Test-Path $deployScript) {
    Copy-Item -Path $deployScript -Destination $staging -Force
    Write-Host '  Added: deploy-financial-api.sh' -ForegroundColor DarkGray
}
# Include systemd service files
$systemdDir = Join-Path $ConfigsDir 'systemd'
if (Test-Path $systemdDir) {
    Copy-Item -Path $systemdDir -Destination $staging -Recurse -Force
    Write-Host '  Added: systemd/' -ForegroundColor DarkGray
}

# Clean __pycache__ / .pyc / egg-info
Get-ChildItem -Path $staging -Recurse -Directory -Filter '__pycache__' |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $staging -Recurse -Filter '*.pyc' |
    Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $staging -Recurse -Directory -Filter '*.egg-info' |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Rename to fixed name for consistent extraction
$parent = Split-Path -Parent $staging
$fixedStaging = Join-Path $parent 'package'
if (Test-Path $fixedStaging) { Remove-Item $fixedStaging -Recurse -Force }
Rename-Item $staging 'package'

Write-Host '  Compressing...'
$tarball = Join-Path $OutputDir "financial-api-$Timestamp.tar.gz"

if (Test-Command 'tar') {
    & tar -czf $tarball -C $parent 'package'
} else {
    $tarball = Join-Path $OutputDir "financial-api-$Timestamp.zip"
    Compress-Archive -Path "$fixedStaging\*" -DestinationPath $tarball -Force
}

Remove-Item $fixedStaging -Recurse -Force -ErrorAction SilentlyContinue

$size = [math]::Round((Get-Item $tarball).Length / 1KB, 1)
Write-Ok "Backend packed: $tarball ($size KB)"

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Step 'Done'
Write-Host "  $tarball" -ForegroundColor Green
Write-Host ""
Write-Host "  Upload to:" -ForegroundColor DarkGray
Write-Host "  scp deploy\dist\financial-api-*.tar.gz root@SERVER_IP:/www/wwwroot/project/uploads/dist/packages/" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Deploy on server:" -ForegroundColor DarkGray
Write-Host "  cd /www/wwwroot/project/uploads/dist && bash deploy.sh financial-api" -ForegroundColor DarkGray
Write-Host ""
