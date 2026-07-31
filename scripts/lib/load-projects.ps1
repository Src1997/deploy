# scripts/lib/load-projects.ps1 — 从 projects.json 加载项目清单
# 用法: . scripts/lib/load-projects.ps1
# 返回: $global:ProjectList (数组), $global:WorkspaceRoot, $global:ProjectBase

function Load-Projects {
    [CmdletBinding()]
    param(
        [string]$ProjectsFile = ""
    )

    # 定位 projects.json
    if (-not $ProjectsFile) {
        $scriptDir = Split-Path -Parent $PSScriptRoot
        $deployDir = Split-Path -Parent $scriptDir
        $ProjectsFile = Join-Path $deployDir "projects.json"
    }

    if (-not (Test-Path $ProjectsFile)) {
        Write-Error "projects.json not found: $ProjectsFile"
        Write-Error "Run: python3 scripts/sync-projects.py (in WSL) or create projects.json manually"
        return $null
    }

    $data = Get-Content $ProjectsFile -Raw -Encoding UTF8 | ConvertFrom-Json

    # 解析优先级: WORKSPACE_ROOT env > yaml/json workspaceRoot > deploy 父目录
    $deployDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $wsRoot = $env:WORKSPACE_ROOT
    if (-not $wsRoot) { $wsRoot = $data.workspaceRoot }
    if (-not $wsRoot) { $wsRoot = Split-Path -Parent $deployDir }

    $projBase = $env:PROJECT_BASE
    if (-not $projBase) { $projBase = $data.projectBase }
    if (-not $projBase) { $projBase = "/www/wwwroot/project" }

    # 设置全局变量
    $global:ProjectsFile = $ProjectsFile
    $global:WorkspaceRoot = $wsRoot
    $global:ProjectBase = $projBase
    $global:ProjectList = $data.projects | Where-Object { $_.enabled -eq $true }

    return $global:ProjectList
}

# 获取单个项目 by id
function Get-ProjectById {
    param([string]$Id)
    if (-not $global:ProjectList) { Load-Projects }
    return $global:ProjectList | Where-Object { $_.id -eq $Id }
}

# 获取项目源码绝对路径
function Get-ProjectSourcePath {
    param([string]$Id)
    $proj = Get-ProjectById $Id
    if (-not $proj) { return "" }
    $sp = if ($proj.sourcePath -is [array]) { $proj.sourcePath[0] } else { [string]$proj.sourcePath }
    return Join-Path $global:WorkspaceRoot $sp
}

# 获取项目部署绝对路径
function Get-ProjectDeployPath {
    param([string]$Id)
    $proj = Get-ProjectById $Id
    if (-not $proj) { return "" }
    # Linux 路径用 / 连接
    return "$global:ProjectBase/$($proj.deployPath)"
}

# 函数通过 dot-source 自动可用（非 module 模式）
