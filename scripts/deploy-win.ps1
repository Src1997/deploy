#requires -version 5.1
<#
.SYNOPSIS
    deploy-win.ps1 - Windows 目标机部署执行器（win 通道，PowerShell 平行入口）

.DESCRIPTION
    与 Linux 侧 deploy.sh + core/ + kinds/python + channels/win 对称的
    Windows 平行入口（设计文档：docs/win-channel-design-2026-11-13.md）。

    契约：CHANNEL-CONTRACT.md 16 动词 —— 以同名 PowerShell 函数实现，
    启动时执行与 registry.sh 等价的动词断言（缺失 fail-fast）。

    kind × channel：python + frontend（frontend=2026-11-18 winvm 单机化落地）；
    进程托管双形态（仅 python kind）：
      service       — NSSM Windows 服务（普通后端，需管理员）
      user-session  — 用户会话后台进程（MT5 IPC 类组件，Session 0 服务形态
                      下 MetaTrader5 通道不通，2026-11-13 实证）

    布局约定（与 Linux 侧一致）：
      PROJECT_BASE\<deployPath>\package\   ← PKG_DIR（app-package 模式代码层）
      PKG_DIR\.venv                        ← Python 虚拟环境
      PKG_DIR\.env                         ← 由 .env.example 模板渲染（include_env 白名单）

.EXAMPLE
    .\deploy-win.ps1 mt5-bridge -Target server-win -Yes          # 部署
    .\deploy-win.ps1 mt5-bridge -Target server-win -NoRestart    # 部署但不启动
    .\deploy-win.ps1 -Status                                     # 服务状态
    .\deploy-win.ps1 mt5-bridge -Logs mt5-bridge -Mode 50        # 日志
    .\deploy-win.ps1 mt5-bridge -Rollback                        # 交互回滚
    .\deploy-win.ps1 mt5-bridge -RollbackTo 20261113-120000      # 回滚到指定备份
    .\deploy-win.ps1 -List                                       # 列出组件
    .\deploy-win.ps1 -History                                    # 部署历史

.NOTES
    - 管理员权限仅在部署 hosting=service 组件时强制（NSSM 装服务）；
      user-session 形态普通权限即可。
    - 并发锁：<PROJECT_BASE>\deploy.win.lock（30s x 2 等待，与 flock 语义等价）。
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Components = @(),

    [string]$Target = "",        # deploy.env.<target>（如 server-win）
    [string]$EnvFile = "",       # 直接指定 env 文件（最高优先级）
    [string]$Service = "",       # -Logs 模式的服务名（缺省 = 组件 id）

    [switch]$Yes,                # 非交互：跳过确认
    [switch]$NoRestart,          # 部署但不启动服务
    [switch]$Status,             # 查看服务状态
    [switch]$List,               # 列出可用组件
    [switch]$History,            # 部署历史
    [switch]$Logs,               # 查看日志（配合 -Service / -Mode）
    [string]$LogMode = "50",     # follow / error / N
    [switch]$Rollback,           # 交互回滚
    [string]$RollbackTo = "",    # 回滚到指定时间戳（latest = 最新备份）
    [switch]$RestartOnly         # 仅重启组件服务（不部署；部署后补配置再拉起的场景）
)

$ErrorActionPreference = "Stop"
$ScriptsDir = $PSScriptRoot
$DeployRoot = Split-Path $ScriptsDir -Parent

# ── 共享辅助（日志/编码/Get-Python/Remove-BuildDir）──
. (Join-Path $ScriptsDir '_ps-common.ps1')

# ══════════════════════════════════════════════════════════════════
# 帮助
# ══════════════════════════════════════════════════════════════════
if ($Help -or ($Components.Count -eq 0 -and -not ($Status -or $List -or $History -or $Logs -or $Rollback))) {
    Get-Content $PSCommandPath -TotalCount 48 | Where-Object { $_ -match '^(\.EXAMPLE|\.DESCRIPTION|    |\.SYNOPSIS)' }
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# 环境装载（等价 core/load-deploy-env.sh）
# ══════════════════════════════════════════════════════════════════
$script:Cfg = [ordered]@{}

function Load-DeployWinEnv {
    # 搜索链：-EnvFile > $DeployRoot\deploy.env.<target> > .\deploy.env.<target> > deploy.env 兜底
    $candidates = @()
    if ($EnvFile) { $candidates += $EnvFile }
    if ($Target) {
        $candidates += (Join-Path $DeployRoot "deploy.env.$Target")
        $candidates += (Join-Path (Get-Location) "deploy.env.$Target")
    } elseif (-not $EnvFile) {
        # 未指定 target：显式拒绝（与 deploy.sh 目标护栏同哲学，防静默回落错配置）
        $envs = Get-ChildItem $DeployRoot -Filter 'deploy.env.*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'deploy.env.example' }
        if ($envs) {
            W-Err "检测到环境文件但未指定 -Target，漏带会静默用错配置（2026-10-26 双轨事故同根因）。"
            W-Info "可用 target: $(($envs | ForEach-Object { $_.Name -replace '^deploy\.env\.', '' }) -join ', ')"
            W-Info "用法: .\deploy-win.ps1 <components> -Target=<target> -Yes"
            exit 2
        }
        $candidates += (Join-Path $DeployRoot 'deploy.env')
    }

    $envPath = $null
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $envPath = $c; break }
    }
    if (-not $envPath) {
        W-Err "未找到 deploy.env 配置文件（Target=$Target, EnvFile=$EnvFile）"
        exit 1
    }

    foreach ($line in (Read-TextFile $envPath) -split "`r?`n") {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
        $k, $v = $t.Split('=', 2)
        $script:Cfg[$k.Trim()] = $v.Trim().Trim('"').Trim("'")
    }

    # win 通道校验
    $chan = $script:Cfg['DEPLOY_CHANNEL']
    if ($chan -ne 'win') {
        W-Err "env 文件 DEPLOY_CHANNEL='$chan' ≠ 'win' —— win 执行器只能跑 win 通道 env。"
        W-Info "env: $envPath"
        exit 1
    }

    # PROJECT_BASE（Windows 路径形态，统一反斜杠）
    $script:ProjectBase = ($script:Cfg['PROJECT_BASE'] -replace '/', '\').TrimEnd('\')
    if (-not $script:ProjectBase) {
        W-Err "env 缺少 PROJECT_BASE（Windows 形态，如 D:/wwwroot/project）"
        exit 1
    }
    W-OK "环境装载: $envPath"
    W-Info "PROJECT_BASE = $script:ProjectBase"
    W-Info "通道         = win（NSSM / user-session 双形态托管）"
}

# ══════════════════════════════════════════════════════════════════
# manifest 装载（等价 core/load-projects.sh，消费 config_loader.py JSON）
# ══════════════════════════════════════════════════════════════════
$script:Manifest = $null
$script:CompMap = @{}

function Load-ManifestWin {
    $loader = Join-Path $ScriptsDir 'core\config_loader.py'
    if (-not (Test-Path $loader)) { W-Err "config_loader.py 不存在: $loader"; exit 1 }

    # 目标机 Python：env WIN_PYTHON 优先 → Get-Python 兜底
    $script:WinPython = $script:Cfg['WIN_PYTHON']
    if ($script:WinPython) {
        $script:WinPython = $script:WinPython -replace '/', '\'
        if (-not (Test-Path $script:WinPython)) {
            W-Warn "WIN_PYTHON 不存在，回落 Get-Python 探测: $script:WinPython"
            $script:WinPython = $null
        }
    }
    if (-not $script:WinPython) { $script:WinPython = Get-Python }

    # config_loader 需要 3.11+（tomllib）
    $verOut = & $script:WinPython -c "import tomllib, sys; print(sys.version_info[0:2])" 2>$null
    if ($LASTEXITCODE -ne 0) {
        W-Err "Python 3.11+ 必需（tomllib），当前不可用: $script:WinPython"
        exit 1
    }

    $jsonOut = & $script:WinPython $loader --format json 2>&1
    if ($LASTEXITCODE -ne 0) { W-Err "config_loader.py 失败: $($jsonOut -join ' ')"; exit 1 }
    $script:Manifest = ($jsonOut | Out-String | ConvertFrom-Json)

    foreach ($p in $script:Manifest.projects) { $script:CompMap[$p.id] = $p }
    W-OK "manifest: $($script:Manifest.projects.Count) 个组件（win 通道消费 kind: $(channel_supported_kinds)）"
}

# ── 组件路径解析（布局与 Linux 侧一致：PKG_DIR = DEPLOY_PATH/package）──
function Get-CompPaths {
    param([Parameter(Mandatory)]$comp)
    $deployPath = ([string]$comp.deployPath) -replace '/', '\'
    $deployDir = Join-Path $script:ProjectBase $deployPath.Trim('\')
    # app-package（包内 package/ 前缀）→ PKG_DIR = deploy_dir\package；source-tar → deploy_dir 本身
    $mode = if ($comp.build.mode) { [string]$comp.build.mode } else { 'app-package' }
    # frontend：deploy_path 即 dist 目录，tar 平铺直放（2026-11-18 winvm 实证布局）
    $pkgDir = if ($mode -eq 'source-tar' -or $comp.kind -eq 'frontend') { $deployDir } else { Join-Path $deployDir 'package' }
    return [pscustomobject]@{
        Id = $comp.id; Mode = $mode; Kind = [string]$comp.kind
        DeployDir = $deployDir; PkgDir = $pkgDir
    }
}

# ── 包查找（等价 deploy_kinds.sh：artifactPattern 取最新）──
function Find-Artifact {
    param([Parameter(Mandatory)]$comp)
    $packagesDir = $script:Cfg['PACKAGES_DIR']
    if ($packagesDir) { $packagesDir = $packagesDir -replace '/', '\' }
    if (-not $packagesDir -or -not (Test-Path $packagesDir)) {
        $packagesDir = Join-Path $DeployRoot 'dist\packages'
    }
    $pattern = [string]$comp.build.artifactPattern
    if (-not $pattern) { $pattern = "$($comp.id)-*.tar.gz" }
    # 固定名（无通配符）直接命中；含 * 取最新
    if ($pattern -notlike '*`**') {
        $fixed = Join-Path $packagesDir $pattern
        if (Test-Path $fixed) { return Get-Item $fixed }
        W-Err "包不存在: $fixed"
        return $null
    }
    $latest = Get-ChildItem $packagesDir -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        W-Err "未找到匹配包: $packagesDir\$pattern（先在本机构建：pack.ps1 $($comp.id)）"
        return $null
    }
    return $latest
}

# ══════════════════════════════════════════════════════════════════
# win 通道 16 动词（契约：CHANNEL-CONTRACT.md §3，与 bash 通道同名）
# ══════════════════════════════════════════════════════════════════

function channel_name { "win（NSSM / user-session，路由层走 bootstrap 脚本）" }
function channel_supported_kinds { "python frontend" }
function channel_wants_host_venv { "1" }

function channel_routing_sync {
    # win 通道路由层 = nginx（assets/win/setup-nginx-frontend.ps1 bootstrap；
    # 2026-11-18 winvm 实证：nginx 1.26 alias+try_files 对子路径 SPA 无需
    # Linux 侧的 dist/<sub> 自引用 symlink，静态资源实测 200）
    W-Warn "win 通道路由层由 bootstrap 脚本管理（assets/win/setup-nginx-frontend.ps1），routing_sync 为 no-op"
}

function channel_frontend_prepare {
    param([string]$Id)
    $comp = $script:CompMap[$Id]
    if (-not $comp -or $comp.kind -ne 'frontend') { return "" }
    # 返回目标目录（= deploy_path，前端 dist 平铺直放，无 package/ 前缀）
    $paths = Get-CompPaths $comp
    return $paths.DeployDir
}
function channel_frontend_preserve { param([string]$Id, [string]$Target) return $true }   # win 无通道资产（无 .user.ini 等）
function channel_frontend_restore  { param([string]$Id, [string]$Target) return $true }
function channel_frontend_finalize { param([string]$Id, [string]$Target)
    # 路由收口由 bootstrap 脚本一次性完成（nginx.conf 全量模板），单组件收口无意义
    W-Info "$Id 路由层无需单组件收口（nginx.conf 全量模板已含 routes）"
    return $true
}
function channel_java_install      { W-Err "win 通道不支持 java kind"; return $false }
function channel_java_restart      { W-Err "win 通道不支持 java kind"; return $false }

# ── cmd_win 解析：首段 = 可执行（相对路径一律相对 PKG_DIR），其余 = 参数 ──
function Resolve-CmdWin {
    param([Parameter(Mandatory)][string]$CmdWin, [Parameter(Mandatory)][string]$PkgDir)
    $cmd = $CmdWin -replace '/', '\'
    $parts = $cmd.Split(' ', 2)
    $exe = $parts[0]
    # 相对路径（如 .venv\Scripts\python.exe）一律相对 PKG_DIR 解析——
    # 进程启动后的 CWD 是 PKG_DIR，但 Test-Path 判断发生在部署器进程（CWD 无关）
    if (-not [System.IO.Path]::IsPathRooted($exe)) { $exe = Join-Path $PkgDir $exe }
    $args = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    return [pscustomobject]@{ Exe = $exe; Args = $args }
}

# ── hosting=user-session：用户会话后台进程（MT5 IPC 形态）──
function Start-UserSessionProc {
    param([Parameter(Mandatory)][string]$Svc, [Parameter(Mandatory)][string]$PkgDir,
          [Parameter(Mandatory)][string]$CmdWin)
    $logsDir = Join-Path $PkgDir 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $parsed = Resolve-CmdWin -CmdWin $CmdWin -PkgDir $PkgDir
    if (-not (Test-Path $parsed.Exe)) {
        W-Err "启动可执行不存在: $($parsed.Exe)（cmd_win=$CmdWin）"
        return $false
    }

    $outLog = Join-Path $logsDir "$Svc.out.log"
    $errLog = Join-Path $logsDir "$Svc.err.log"
    $pidFile = Join-Path $logsDir "$Svc.pid"

    # 旧进程清理（PID 文件存活 → 先停，防双实例抢端口）
    Stop-UserSessionProc -Svc $Svc -PkgDir $PkgDir | Out-Null

    W-Step "启动用户会话进程: $Svc"
    W-Info "exe : $($parsed.Exe)"
    W-Info "args: $($parsed.Args)"
    $p = Start-Process -FilePath $parsed.Exe -ArgumentList $parsed.Args `
        -WorkingDirectory $PkgDir -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
        -PassThru
    if (-not $p -or $p.HasExited) {
        W-Err "进程启动失败（exit=$($p.ExitCode)）—— 查看 $errLog"
        return $false
    }
    Write-TextFile -Path $pidFile -Value "$($p.Id)"
    Start-Sleep -Seconds 2
    # PS5.1：Get-Process 找不到返回 null（不抛错），用 [bool] 归一
    $alive = [bool](Get-Process -Id $p.Id -ErrorAction SilentlyContinue)
    if ($alive) {
        W-OK "$svc PID=$($p.Id) 运行中（日志: $outLog）"
        return $true
    }
    W-Err "$svc 启动后 2s 内退出 —— 查看 $errLog"
    return $false
}

function Stop-UserSessionProc {
    param([Parameter(Mandatory)][string]$Svc, [Parameter(Mandatory)][string]$PkgDir)
    $pidFile = Join-Path (Join-Path $PkgDir 'logs') "$Svc.pid"
    if (-not (Test-Path $pidFile)) { return $true }
    $procId = [int](Read-TextFile $pidFile).Trim()
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $procId -Force -Confirm:$false
        W-Info "已停止 $Svc (PID=$procId)"
    }
    Remove-BuildFile $pidFile
    return $true
}

# ── hosting=service：NSSM Windows 服务 ──
function Get-NssmPath {
    $p = $script:Cfg['NSSM_EXE']
    if ($p) { $p = $p -replace '/', '\' }
    if ($p -and (Test-Path $p)) { return $p }
    # dist assets 自带回落
    $asset = Join-Path $DeployRoot 'assets\win\nssm.exe'
    if (Test-Path $asset) { return $asset }
    return $null
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        W-Err "hosting=service 需要管理员权限（NSSM 安装/启停服务）——请以管理员运行后重试。"
        return $false
    }
    return $true
}

# ── Invoke-Nssm：nssm 调用统一入口（2026-11-18 winvm 实证坑）──
# nssm 把正常输出也写 stderr（如 restart 的 "STOP:"），PS5.1 在 $ErrorActionPreference=Stop
# 下 2>&1 重定向会把 stderr 抛成 NativeCommandError —— restart 实际成功却中断部署，
# 服务停在 STOPPED（financial-api 首次部署实证）。统一在此临时降级 EAP。
function Invoke-Nssm {
    param([Parameter(Mandatory)]$Nssm, [Parameter(Mandatory)][string[]]$NssmArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $Nssm @NssmArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
}

function channel_python_install {
    param([string]$Id, [string]$PkgDir)
    $comp = $script:CompMap[$Id]
    $hosting = if ($comp.process.hosting) { [string]$comp.process.hosting } else { 'service' }
    $cmdWin = [string]$comp.process.cmdWin
    if (-not $cmdWin) {
        $cmdWin = [string]$comp.process.cmd
        W-Warn "$Id 未配置 cmd_win，回退 POSIX cmd（venv/bin 路径在 Windows 必错）——建议 TOML 显式声明 cmd_win"
    }
    if (-not $cmdWin) { W-Err "$Id 缺少 process.cmd/cmd_win"; return $false }

    if ($hosting -eq 'user-session') {
        # user-session：安装 = 记录意图（启动动作在 restart），无需系统级注册
        W-OK "$Id 托管形态 = user-session（用户会话后台进程，MT5 IPC 兼容）"
        return $true
    }

    # service 形态：NSSM
    $nssm = Get-NssmPath
    if (-not $nssm) {
        W-Err "NSSM 未找到（env NSSM_EXE 或 assets\win\nssm.exe）。下载: https://nssm.cc/release/nssm-2.24.zip"
        return $false
    }
    if (-not (Assert-Admin)) { return $false }
    $parsed = Resolve-CmdWin -CmdWin $cmdWin -PkgDir $PkgDir
    $logsDir = Join-Path $PkgDir 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

    W-Step "NSSM 安装服务: $Id"
    if ((Invoke-Nssm -Nssm $nssm -NssmArgs @('install', $Id, $parsed.Exe, $parsed.Args)) -ne 0) {
        # 已存在 → 更新参数（install 幂等：先 remove 再装，与服务重建语义一致）
        W-Warn "install 返回非 0（可能已存在），重建服务..."
        Invoke-Nssm -Nssm $nssm -NssmArgs @('stop', $Id) | Out-Null
        Invoke-Nssm -Nssm $nssm -NssmArgs @('remove', $Id, 'confirm') | Out-Null
        if ((Invoke-Nssm -Nssm $nssm -NssmArgs @('install', $Id, $parsed.Exe, $parsed.Args)) -ne 0) {
            W-Err "NSSM 重建失败: $Id"; return $false
        }
    }
    Invoke-Nssm -Nssm $nssm -NssmArgs @('set', $Id, 'AppDirectory', $PkgDir) | Out-Null
    Invoke-Nssm -Nssm $nssm -NssmArgs @('set', $Id, 'AppStdout', (Join-Path $logsDir "$Id.out.log")) | Out-Null
    Invoke-Nssm -Nssm $nssm -NssmArgs @('set', $Id, 'AppStderr', (Join-Path $logsDir "$Id.err.log")) | Out-Null
    Invoke-Nssm -Nssm $nssm -NssmArgs @('set', $Id, 'Start', 'SERVICE_AUTO_START') | Out-Null
    W-OK "服务已安装（自动启动）: $Id"
    return $true
}

function channel_python_restart {
    param([string]$Id)
    if ($NoRestart) { W-Warn "跳过重启 (-NoRestart)"; return $true }
    $comp = $script:CompMap[$Id]
    $hosting = if ($comp.process.hosting) { [string]$comp.process.hosting } else { 'service' }
    $paths = Get-CompPaths $comp
    $cmdWin = [string]$comp.process.cmdWin; if (-not $cmdWin) { $cmdWin = [string]$comp.process.cmd }

    # 端口竞态防护（吸取宝塔 RestartProject 教训）：stop 后轮询确认资源释放再 start
    $port = [string]$comp.process.port

    if ($hosting -eq 'user-session') {
        Stop-UserSessionProc -Svc $Id -PkgDir $paths.PkgDir | Out-Null
        if ($port -and (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
            W-Warn "端口 $port 仍被占用，等待释放..."
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 1
                if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) { break }
            }
        }
        return (Start-UserSessionProc -Svc $Id -PkgDir $paths.PkgDir -CmdWin $cmdWin)
    }

    $nssm = Get-NssmPath
    if (-not $nssm) { W-Err "NSSM 未找到"; return $false }
    if (-not (Assert-Admin)) { return $false }
    W-Step "NSSM 重启服务: $Id"
    if ((Invoke-Nssm -Nssm $nssm -NssmArgs @('restart', $Id)) -ne 0) {
        Invoke-Nssm -Nssm $nssm -NssmArgs @('start', $Id) | Out-Null
    }
    Start-Sleep -Seconds 2
    return (channel_service_running -Svc $Id)
}

function channel_service_running {
    param([Parameter(Mandatory)][string]$Svc)
    # 先查 PID 文件（user-session 形态），再查 Windows 服务（NSSM 形态）
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python') { continue }
        $paths = Get-CompPaths $comp
        $pidFile = Join-Path (Join-Path $paths.PkgDir 'logs') "$Svc.pid"
        if (Test-Path $pidFile) {
            $procId = [int](Read-TextFile $pidFile).Trim()
            return [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
        }
    }
    $svcObj = Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if ($svcObj) { return ($svcObj.Status -eq 'Running') }
    return $false
}

function channel_service_restart {
    param([Parameter(Mandatory)][string]$Svc)
    # 按服务名找所属组件，走对应形态重启
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python') { continue }
        $svcs = @($comp.id) + @($comp.companions | ForEach-Object { $_.name })
        if ($svcs -contains $Svc) {
            if ($Svc -eq $comp.id) { return (channel_python_restart -Id $comp.id) }
            # companion：一期仅支持 user-session 形态独立重启
            $paths = Get-CompPaths $comp
            $c = $comp.companions | Where-Object { $_.name -eq $Svc } | Select-Object -First 1
            if ($c -and $c.cmd) {
                $cmdWin = $c.cmd -replace '/', '\'
                return (Start-UserSessionProc -Svc $Svc -PkgDir $paths.PkgDir -CmdWin $cmdWin)
            }
            W-Err "companion $Svc 无 cmd 声明，无法独立重启"
            return $false
        }
    }
    W-Err "未知服务: $Svc"
    return $false
}

function channel_status {
    Write-Host ""
    Write-Host ("  {0,-22} {1,-10} {2}" -f "SERVICE", "STATUS", "HEALTH") -ForegroundColor White
    W-HR
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python' -or -not $comp.enabled) { continue }
        # ★只列本机有部署痕迹的组件（PKG_DIR 存在）——跨平台 manifest 全量加载，
        #   Linux 组件在本机列出会全是假 STOPPED（2026-11-16 试点实证）
        $paths0 = Get-CompPaths $comp
        if (-not (Test-Path $paths0.PkgDir)) { continue }
        $svcs = @($comp.id) + @($comp.companions | ForEach-Object { $_.name })
        foreach ($svc in $svcs) {
            $running = channel_service_running -Svc $svc
            $status = if ($running) { "RUNNING" } else { "STOPPED" }
            $color = if ($running) { "Green" } else { "Red" }
            $health = "-"
            $hurl = [string]$comp.healthUrl
            if ($hurl -and $svcs[0] -eq $svc) {
                $code = & curl.exe -sf --max-time 5 -o NUL -w "%{http_code}" $hurl 2>$null
                $health = if ($code) { $code } else { "FAIL" }
            }
            Write-Host ("  {0,-22} " -f $svc) -NoNewline
            Write-Host ("{0,-10}" -f $status) -ForegroundColor $color -NoNewline
            Write-Host (" {0}" -f $health)
        }
    }
    Write-Host ""
}

function channel_logs {
    param([Parameter(Mandatory)][string]$Svc, [string]$Mode = "50")
    # 日志定位：遍历组件找 logs\<svc>.out.log / .err.log
    $outLog = $null; $errLog = $null
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python') { continue }
        $paths = Get-CompPaths $comp
        $o = Join-Path (Join-Path $paths.PkgDir 'logs') "$Svc.out.log"
        if (Test-Path $o) { $outLog = $o; $errLog = Join-Path (Join-Path $paths.PkgDir 'logs') "$Svc.err.log"; break }
    }
    if (-not $outLog) {
        # NSSM 服务日志同样落 logs\ 目录（channel_python_install 配置 AppStdout）
        W-Err "未找到 $Svc 的日志（logs\<svc>.out.log）"
        return $false
    }
    switch ($Mode) {
        'follow' {
            W-Banner "实时日志: $Svc（Ctrl+C 退出）"
            Get-Content $outLog -Tail 20 -Wait
        }
        'error' {
            W-Banner "ERROR 日志: $Svc"
            foreach ($f in @($outLog, $errLog)) {
                if ($f -and (Test-Path $f)) {
                    Select-String -Path $f -Pattern 'error|traceback|exception' -SimpleMatch:$false |
                        Select-Object -Last 30 | ForEach-Object { $_.Line }
                }
            }
        }
        default {
            W-Banner "最近 $Mode 行: $Svc"
            foreach ($f in @($outLog, $errLog)) {
                if ($f -and (Test-Path $f)) {
                    W-Info "-- $f"
                    Get-Content $f -Tail ([int]$Mode)
                }
            }
        }
    }
    return $true
}

# ── 动词断言（等价 registry.sh fail-fast）──
function Assert-ChannelVerbs {
    $required = @(
        'channel_name', 'channel_supported_kinds', 'channel_wants_host_venv',
        'channel_routing_sync',
        'channel_frontend_prepare', 'channel_frontend_preserve',
        'channel_frontend_restore', 'channel_frontend_finalize',
        'channel_python_install', 'channel_python_restart',
        'channel_java_install', 'channel_java_restart',
        'channel_service_running', 'channel_service_restart',
        'channel_status', 'channel_logs'
    )
    $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        W-Err "win 通道缺少统一动词: $($missing -join ' ')（契约: CHANNEL-CONTRACT.md）"
        exit 1
    }
    W-OK "通道: win（$(channel_name)）| 支持 kind: $(channel_supported_kinds) | 16 动词断言通过"
}

# ══════════════════════════════════════════════════════════════════
# 并发锁（等价 flock 语义）
# ══════════════════════════════════════════════════════════════════
function Enter-DeployLock {
    # 首次部署时 PROJECT_BASE 尚不存在——先建目录再开锁（否则 Open 抛
    # DirectoryNotFound 被下面 catch 误报为"锁被占用"，2026-11-16 试点实证）
    if (-not (Test-Path $script:ProjectBase)) {
        New-Item -ItemType Directory -Path $script:ProjectBase -Force | Out-Null
    }
    $lockPath = Join-Path $script:ProjectBase 'deploy.win.lock'
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $script:LockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
            return $true
        } catch {
            W-Warn "部署锁被占用（另一个部署进行中），30s 后重试 ($($i+1)/2)..."
            Start-Sleep -Seconds 30
        }
    }
    W-Err "部署锁获取失败: $lockPath（若确认无并发部署，手动删除该文件）"
    return $false
}
function Exit-DeployLock {
    if ($script:LockStream) {
        $script:LockStream.Close(); $script:LockStream = $null
        Remove-BuildFile (Join-Path $script:ProjectBase 'deploy.win.lock')
    }
}

# ══════════════════════════════════════════════════════════════════
# python kind 部署主链路（等价 deploy-python.sh）
# ══════════════════════════════════════════════════════════════════

function Invoke-HealthCheck {
    param([string]$HealthUrl, [int]$Timeout = 5)
    if (-not $HealthUrl) { return $true }
    for ($i = 1; $i -le 3; $i++) {
        $code = & curl.exe -sf --max-time $Timeout -o NUL -w "%{http_code}" $HealthUrl 2>$null
        if ($code -and $code -match '^2|^3') { W-OK "健康检查通过 ($i/3): $HealthUrl → $code"; return $true }
        $codeShow = if ($code) { $code } else { '无响应' }
        W-Warn "健康检查失败 ($i/3): $HealthUrl → $codeShow"
        Start-Sleep -Seconds 3
    }
    return $false
}

function Invoke-ComponentDeploy {
    param([Parameter(Mandatory)][string]$Id)
    $comp = $script:CompMap[$Id]
    if (-not $comp) { W-Err "未知组件: $Id"; return $false }
    switch ($comp.kind) {
        'python'   { return (Invoke-PythonDeploy -Id $Id) }
        'frontend' { return (Invoke-FrontendDeploy -Id $Id) }
        default    { W-Err "win 通道不支持 kind=$($comp.kind)（$Id）"; return $false }
    }
}

# ── frontend kind：找包 → 备份 → 清空 → 平铺解压 → 完整性校验（无服务无健康门）──
function Invoke-FrontendDeploy {
    param([Parameter(Mandatory)][string]$Id)
    $comp = $script:CompMap[$Id]
    $paths = Get-CompPaths $comp
    W-Banner "部署: $Id ($($comp.displayName)) [frontend]"
    W-Info "target_dir : $($paths.DeployDir)"

    # ── 1. 包查找 ──
    $artifact = Find-Artifact $comp
    if (-not $artifact) { return $false }
    W-OK "包: $($artifact.Name) ($('{0:N1} MB' -f ($artifact.Length / 1MB)))"

    # ── 2. 目录准备 + 备份（前端 dist 整体替换，无保留名单）──
    foreach ($d in @($paths.DeployDir, (Join-Path $script:ProjectBase 'backup'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $maxBackups = if ($script:Cfg['MAX_BACKUPS']) { [int]$script:Cfg['MAX_BACKUPS'] } else { 5 }
    $backupBase = Join-Path $script:ProjectBase 'backup'
    if (Test-Path $paths.DeployDir) {
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bakDir = Join-Path (Join-Path $backupBase $Id) $ts
        New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
        W-Step "备份 → $bakDir"
        robocopy $paths.DeployDir $bakDir '/E' '/NFL' '/NDL' '/NJH' '/NJS' '/NC' '/NS' 2>$null | Out-Null
        if ($LASTEXITCODE -ge 8) { W-Err "备份失败（robocopy exit=$LASTEXITCODE），部署中止"; return $false }
        W-OK "备份完成"
        $baks = Get-ChildItem (Join-Path $backupBase $Id) -Directory | Sort-Object Name
        if ($baks.Count -gt $maxBackups) {
            $baks | Select-Object -First ($baks.Count - $maxBackups) | ForEach-Object {
                Remove-BuildDir $_.FullName; W-Info "清理旧备份: $($_.Name)"
            }
        }
    } else {
        W-Info "首次部署（无既有 dist，跳过备份）"
    }

    # ── 3. tar 内文件数（完整性校验基准）──
    $tarFiles = @(& tar -tzf $artifact.FullName 2>$null | Where-Object { $_ -notmatch '/$' }).Count

    # ── 4. 清空 + 平铺解压（tar 内容与 deploy_path 同构，无 package/ 前缀）──
    W-Step "清空 dist + 解压 $($artifact.Name)"
    Get-ChildItem $paths.DeployDir -Force | ForEach-Object {
        if ($_.PSIsContainer) { Remove-BuildDir $_.FullName } else { Remove-BuildFile $_.FullName }
    }
    & tar -xzf $artifact.FullName -C $paths.DeployDir
    if ($LASTEXITCODE -ne 0) { W-Err "解压失败（tar exit=$LASTEXITCODE）"; return $false }

    # ── 5. 完整性校验（对齐 Linux kinds/frontend.sh 的 tar vs extracted 计数）──
    $extracted = @(Get-ChildItem $paths.DeployDir -Recurse -File).Count
    if ($extracted -lt $tarFiles) {
        W-Warn "$Id 解压可能不完整: tar=$tarFiles extracted=$extracted"
    }
    $indexHtml = Test-Path (Join-Path $paths.DeployDir 'index.html')
    if (-not $indexHtml) { W-Err "dist 缺 index.html —— 部署失败"; return $false }

    # ★Windows 分歧点：Linux 侧子路径 SPA 需 dist/<sub> -> . 自引用 symlink
    # （alias+try_files root 语义坑），winvm nginx 1.26 实测无需（资源 200）；
    # 部署后建议 curl 一个 /<sub>/assets/*.js 验证。无 junction 是刻意的——
    # junction 自引用会让 robocopy 备份/清理无限递归。
    $auditLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | DEPLOY-OK | $Id | $($artifact.Name) | kind=frontend"
    [System.IO.File]::AppendAllText((Join-Path (Join-Path $script:ProjectBase 'uploads') 'deploy.log'), $auditLine + "`n", $global:PS_UTF8_NO_BOM)
    W-OK "部署完成: $Id（文件数 $extracted）"
    return $true
}

function Invoke-PythonDeploy {
    param([Parameter(Mandatory)][string]$Id)
    $comp = $script:CompMap[$Id]
    $paths = Get-CompPaths $comp
    W-Banner "部署: $Id ($($comp.displayName)) [$($paths.Mode)]"
    W-Info "deploy_dir : $($paths.DeployDir)"
    W-Info "pkg_dir    : $($paths.PkgDir)"

    # ── 1. 包查找 ──
    $artifact = Find-Artifact $comp
    if (-not $artifact) { return $false }
    W-OK "包: $($artifact.Name) ($('{0:N1} MB' -f ($artifact.Length / 1MB)))"

    # ── 2. 目录准备 ──
    foreach ($d in @($paths.DeployDir, (Join-Path $script:ProjectBase 'backup'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # ── 3. 备份（等价 do_backup：排除 .venv，MAX_BACKUPS 上限）──
    $maxBackups = if ($script:Cfg['MAX_BACKUPS']) { [int]$script:Cfg['MAX_BACKUPS'] } else { 5 }
    $backupBase = Join-Path $script:ProjectBase 'backup'
    if (Test-Path $paths.PkgDir) {
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bakDir = Join-Path (Join-Path $backupBase $Id) $ts
        New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
        W-Step "备份 → $bakDir"
        robocopy $paths.PkgDir $bakDir '/E' '/XD' (Join-Path $paths.PkgDir '.venv') `
            '/NFL' '/NDL' '/NJH' '/NJS' '/NC' '/NS' 2>$null | Out-Null
        if ($LASTEXITCODE -ge 8) { W-Err "备份失败（robocopy exit=$LASTEXITCODE），部署中止"; return $false }
        W-OK "备份完成"
        # 备份上限裁剪
        $baks = Get-ChildItem (Join-Path $backupBase $Id) -Directory | Sort-Object Name
        if ($baks.Count -gt $maxBackups) {
            $baks | Select-Object -First ($baks.Count - $maxBackups) | ForEach-Object {
                Remove-BuildDir $_.FullName; W-Info "清理旧备份: $($_.Name)"
            }
        }
    } else {
        W-Info "首次部署（无既有 package/，跳过备份）"
    }

    # ── 4. 清空 PKG_DIR（保留 .env/.venv/logs/data —— KINDS-CONTRACT 铁律 3）──
    if (Test-Path $paths.PkgDir) {
        W-Step "清空 pkg_dir（保留 .env .venv logs data）"
        Get-ChildItem $paths.PkgDir -Force | Where-Object {
            $_.Name -notin @('.env', '.venv', 'logs', 'data')
        } | ForEach-Object {
            if ($_.PSIsContainer) { Remove-BuildDir $_.FullName } else { Remove-BuildFile $_.FullName }
        }
    } else {
        New-Item -ItemType Directory -Path $paths.PkgDir -Force | Out-Null
    }

    # ── 5. 解压（tar → temp → package/ 内容进 PKG_DIR）──
    W-Step "解压 $($artifact.Name)"
    $tempDir = Join-Path $env:TEMP "deploywin-$Id-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    & tar -xzf $artifact.FullName -C $tempDir
    if ($LASTEXITCODE -ne 0) { W-Err "解压失败（tar exit=$LASTEXITCODE）"; Remove-BuildDir $tempDir; return $false }
    $srcDir = if ($paths.Mode -eq 'app-package') { Join-Path $tempDir 'package' } else { $tempDir }
    if ($paths.Mode -eq 'app-package' -and -not (Test-Path $srcDir)) {
        W-Err "包内缺少 package/ 目录（app-package 模式）"; Remove-BuildDir $tempDir; return $false
    }
    robocopy $srcDir $paths.PkgDir '/E' '/NFL' '/NDL' '/NJH' '/NJS' '/NC' '/NS' 2>$null | Out-Null
    if ($LASTEXITCODE -ge 8) { W-Err "代码同步失败（robocopy exit=$LASTEXITCODE）"; Remove-BuildDir $tempDir; return $false }
    Remove-BuildDir $tempDir
    W-OK "代码就位"

    # ── 6. .env 渲染（模板存在且 PKG_DIR\.env 不存在时；已存在不覆盖）──
    $wasFresh = -not (Test-Path (Join-Path $paths.PkgDir '.env'))
    $envTemplate = Join-Path (Join-Path $DeployRoot 'configs') "$Id.env.example"
    if ((Test-Path $envTemplate) -and -not (Test-Path (Join-Path $paths.PkgDir '.env'))) {
        W-Step "渲染 .env（模板: configs\$Id.env.example）"
        $content = Read-TextFile $envTemplate
        $repl = @{
            '__PG_PASSWORD__' = $script:Cfg['PG_PASSWORD']; '__PG_USER__' = $script:Cfg['PG_USER']
            '__REDIS_PASSWORD__' = $script:Cfg['REDIS_PASSWORD']; '__REDIS_HOST__' = $script:Cfg['REDIS_HOST']
            '__AUTH_SECRET_KEY__' = $script:Cfg['AUTH_SECRET_KEY']; '__SERVER_IP__' = $script:Cfg['SERVER_IP']
            '__SMTP_PASSWORD__' = $script:Cfg['SMTP_PASSWORD']; '__DOMAIN__' = $script:Cfg['DOMAIN']
            '__WWW_DOMAIN__' = $script:Cfg['WWW_DOMAIN']; '__APP_NAME__' = $script:Cfg['APP_NAME']
            '__POSTGRES_DB__' = $script:Cfg['POSTGRES_DB']; '__PKG_DIR__' = $paths.PkgDir
            '__PORT__' = $comp.process.port; '__API_PORT__' = $comp.process.port
            '__WEB_PATH__' = $comp.webPath
            '__SEED_ADMIN_PASSWORD__' = $script:Cfg['SEED_ADMIN_PASSWORD']
            '__SEED_DEMO_PASSWORD__' = $script:Cfg['SEED_DEMO_PASSWORD']
        }
        foreach ($k in $repl.Keys) { $content = $content.Replace($k, [string]$repl[$k]) }
        Write-TextFile -Path (Join-Path $paths.PkgDir '.env') -Value $content
        W-OK ".env 已生成（已存在的 .env 永不覆盖）"
    }

    # ── 7. venv + pip（MetaTrader5 等 Windows-only 包在此正常安装）──
    $venvDir = Join-Path $paths.PkgDir '.venv'
    $venvPython = Join-Path $venvDir 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        W-Step "创建 venv: $venvDir"
        & $script:WinPython -m venv $venvDir
        if ($LASTEXITCODE -ne 0) { W-Err "venv 创建失败"; return $false }
    }
    if (Test-Path (Join-Path $paths.PkgDir 'requirements.txt')) {
        W-Step "pip install -r requirements.txt（腾讯源）"
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $venvPython -m pip install -r (Join-Path $paths.PkgDir 'requirements.txt') `
            -i https://mirrors.cloud.tencent.com/pypi/simple --quiet --disable-pip-version-check 2>&1 |
            ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) { W-Err "pip install 失败"; return $false }
        W-OK "依赖安装完成"
    } elseif (Test-Path (Join-Path $paths.PkgDir 'pyproject.toml')) {
        # 2026-11-18 winvm 单机化：pyproject 工程（无 requirements.txt）按包本体安装
        W-Step "pip install .（pyproject 依赖，腾讯源）"
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        Push-Location $paths.PkgDir
        & $venvPython -m pip install . `
            -i https://mirrors.cloud.tencent.com/pypi/simple --quiet --disable-pip-version-check 2>&1 |
            ForEach-Object { Write-Host "    $_" }
        Pop-Location
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) { W-Err "pip install . 失败"; return $false }
        W-OK "依赖安装完成（pyproject）"
    }

    # ── 8. 迁移 + seed（2026-11-18 winvm 单机化落地，走包内 venv）──
    $migCmd = [string]$comp.process.migrate
    if ($migCmd) {
        W-Step "迁移: $migCmd"
        $mParts = $migCmd.Split(' ', 2)
        $mExe = Join-Path $venvDir ("Scripts\" + $mParts[0] + ".exe")
        if (-not (Test-Path $mExe)) { $mExe = Join-Path $venvDir ("Scripts\" + $mParts[0]) }
        if (-not (Test-Path $mExe)) { W-Err "迁移可执行不存在: $mExe"; return $false }
        $mArgs = if ($mParts.Count -gt 1) { $mParts[1] -split ' ' } else { @() }
        Push-Location $paths.PkgDir
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $mExe @mArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        Pop-Location
        if ($rc -ne 0) { W-Err "迁移失败（exit=$rc）——部署中止"; return $false }
        W-OK "迁移完成"
    }

    # seed：首次部署（.env 本次新生成）或 deploy.env SEED_ON_DEPLOY=1 时执行；
    # 密码从 deploy.env SEED_*_PASSWORD 注入进程环境（非 debug 模式缺密码 =
    # seed 自身报明确 RuntimeError，可诊断；★cmd `set X=v && ` 尾空格污染坑的
    # 教训——这里由 PS 进程环境精确赋值，不经 cmd）。
    $seedOnDeploy = $script:Cfg['SEED_ON_DEPLOY']
    $doSeed = (($wasFresh -and ($seedOnDeploy -ne '0')) -or ($seedOnDeploy -eq '1')) `
        -and (Test-Path (Join-Path $paths.PkgDir 'app\db\seed.py'))
    if ($doSeed) {
        W-Step "seed（app.db.seed；首次部署=$wasFresh, SEED_ON_DEPLOY=$seedOnDeploy）"
        if (-not $script:Cfg['SEED_ADMIN_PASSWORD'] -or -not $script:Cfg['SEED_DEMO_PASSWORD']) {
            W-Warn "SEED_ADMIN_PASSWORD / SEED_DEMO_PASSWORD 未在 deploy.env 配置——非 debug 模式 seed 会拒绝默认密码"
        }
        $prevA = $env:SEED_ADMIN_PASSWORD; $prevB = $env:SEED_DEMO_PASSWORD
        $env:SEED_ADMIN_PASSWORD = $script:Cfg['SEED_ADMIN_PASSWORD']
        $env:SEED_DEMO_PASSWORD = $script:Cfg['SEED_DEMO_PASSWORD']
        Push-Location $paths.PkgDir
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $venvPython -m app.db.seed 2>&1 | ForEach-Object { Write-Host "    $_" }
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        Pop-Location
        $env:SEED_ADMIN_PASSWORD = $prevA; $env:SEED_DEMO_PASSWORD = $prevB
        if ($rc -ne 0) {
            W-Warn "seed 失败（exit=$rc）——不阻塞部署（DB schema 已就位，可手工补跑 seed）"
        } else {
            W-OK "seed 完成"
        }
    }

    # ── 9. 服务化 + 重启 ──
    if (-not (channel_python_install -Id $Id -PkgDir $paths.PkgDir)) { return $false }
    if (-not (channel_python_restart -Id $Id)) { return $false }

    # ── 10. 健康门（3 次重试，失败计败 → 提示回滚；-NoRestart 时跳过）──
    $healthUrl = [string]$comp.healthUrl
    if ($NoRestart) {
        W-Warn "-NoRestart：服务未启动，跳过健康门"
    } elseif (-not (Invoke-HealthCheck -HealthUrl $healthUrl)) {
        W-Err "健康检查未通过 —— 可回滚: .\deploy-win.ps1 $Id -Rollback"
        return $false
    }

    # ── 11. 审计（与 Linux 侧 deploy.log 同格式）──
    $auditDir = Join-Path (Join-Path $script:ProjectBase 'uploads') ''
    if (-not (Test-Path $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
    $auditLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | DEPLOY-OK | $Id | $($artifact.Name) | hosting=$($comp.process.hosting)"
    [System.IO.File]::AppendAllText((Join-Path $auditDir 'deploy.log'), $auditLine + "`n", $global:PS_UTF8_NO_BOM)
    W-OK "部署完成: $Id"
    return $true
}

# ══════════════════════════════════════════════════════════════════
# 回滚（等价 core/backup-rollback.sh）
# ══════════════════════════════════════════════════════════════════
function Invoke-ComponentRollback {
    param([Parameter(Mandatory)][string]$Id, [string]$To = "")
    $comp = $script:CompMap[$Id]
    if (-not $comp) { W-Err "未知组件: $Id"; return $false }
    $paths = Get-CompPaths $comp
    $bakRoot = Join-Path (Join-Path $script:ProjectBase 'backup') $Id
    $baks = Get-ChildItem $bakRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $baks -or $baks.Count -eq 0) { W-Err "$Id 无可用备份: $bakRoot"; return $false }

    $chosen = $null
    if ($To -and $To -ne 'latest') {
        $chosen = $baks | Where-Object { $_.Name -eq $To } | Select-Object -First 1
        if (-not $chosen) { W-Err "备份不存在: $To"; return $false }
    } elseif (-not $To -and -not $Yes) {
        W-Info "可用备份（最新在前）:"
        for ($i = 0; $i -lt $baks.Count; $i++) { Write-Host "  [$($i+1)] $($baks[$i].Name)" }
        $sel = Read-Host "选择回滚点 [1-$($baks.Count)]（回车=最新）"
        $n = if ($sel) { [int]$sel } else { 1 }
        $chosen = $baks[$n - 1]
    } else {
        $chosen = $baks[0]
    }
    W-Step "回滚 $Id → $($chosen.Name)"

    # 停服（形态自适应）→ 还原内容（排除 .venv 保留现有环境）→ 重启
    $comp2 = $script:CompMap[$Id]
    $hosting = if ($comp2.process.hosting) { [string]$comp2.process.hosting } else { 'service' }
    if ($hosting -eq 'user-session') {
        Stop-UserSessionProc -Svc $Id -PkgDir $paths.PkgDir | Out-Null
    } else {
        $nssm = Get-NssmPath
        if ($nssm) { Invoke-Nssm -Nssm $nssm -NssmArgs @('stop', $Id) | Out-Null }
    }

    Get-ChildItem $paths.PkgDir -Force | Where-Object {
        $_.Name -notin @('.env', '.venv', 'logs', 'data')
    } | ForEach-Object {
        if ($_.PSIsContainer) { Remove-BuildDir $_.FullName } else { Remove-BuildFile $_.FullName }
    }
    robocopy $chosen.FullName $paths.PkgDir '/E' '/XD' (Join-Path $chosen.FullName '.venv') `
        '/NFL' '/NDL' '/NJH' '/NJS' '/NC' '/NS' 2>$null | Out-Null
    if ($LASTEXITCODE -ge 8) { W-Err "回滚复制失败"; return $false }

    if (-not $NoRestart) { channel_python_restart -Id $Id | Out-Null }
    $auditLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | ROLLBACK | $Id | backup=$($chosen.Name)"
    [System.IO.File]::AppendAllText((Join-Path (Join-Path $script:ProjectBase 'uploads') 'deploy.log'), $auditLine + "`n", $global:PS_UTF8_NO_BOM)
    W-OK "回滚完成: $Id → $($chosen.Name)"
    return $true
}

# ══════════════════════════════════════════════════════════════════
# 主入口
# ══════════════════════════════════════════════════════════════════

Load-DeployWinEnv
Load-ManifestWin
Assert-ChannelVerbs

# ── -List ──
if ($List) {
    W-Banner "可用组件（win 通道可部署 = kind python / frontend）"
    foreach ($p in $script:Manifest.projects) {
        $ok = $p.kind -in @('python', 'frontend')
        $flag = if ($ok) { "✓ $($p.kind)" } else { "× $($p.kind)（win 通道不支持）" }
        $en = if ($p.enabled) { "" } else { " [disabled]" }
        Write-Host ("  {0,-22} {1} {2}" -f $p.id, $flag, $en)
    }
    exit 0
}

# ── -History（等价 deploy.sh --history）──
if ($History) {
    $log = Join-Path (Join-Path $script:ProjectBase 'uploads') 'deploy.log'
    if (Test-Path $log) { Get-Content $log -Tail 50 } else { W-Warn "无部署历史: $log" }
    exit 0
}

# ── -Status ──
if ($Status) { channel_status; exit 0 }

# ── -Logs ──
if ($Logs) {
    $svc = if ($Service) { $Service } elseif ($Components.Count -gt 0) { $Components[0] } else { "" }
    if (-not $svc) { W-Err "-Logs 需要服务名（-Service <name> 或位置参数）"; exit 1 }
    $ok = channel_logs -Svc $svc -Mode $LogMode
    exit $(if ($ok) { 0 } else { 1 })
}

# ── 组件解析（支持组名 / 组件 id / 逗号串 / all）──
$selected = @()
if ($Components.Count -gt 0) {
    $flat = $Components | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
    foreach ($id in $flat) {
        $id = $id.Trim()
        if ($id -eq 'all') {
            $selected += @($script:Manifest.projects | Where-Object { $_.enabled -and $_.kind -in @('python', 'frontend') })
        } elseif ($script:CompMap.ContainsKey($id)) {
            $selected += $script:CompMap[$id]
        } else {
            W-Err "未知组件: $id（-List 查看；组名未在 win 通道支持，请用组件 id）"
            exit 1
        }
    }
}
$selected = @($selected | Sort-Object id -Unique)
if ($selected.Count -eq 0) { W-Err "未选择任何组件"; exit 1 }

# ── 部署 / 回滚 / 仅重启 分发 ──
$succeeded = @(); $failed = @()
if ($RestartOnly) {
    foreach ($c in $selected) {
        if (channel_python_restart -Id $c.id) { $succeeded += $c.id } else { $failed += $c.id }
        $hurl = [string]$c.healthUrl
        if ($succeeded -contains $c.id -and $hurl) {
            Invoke-HealthCheck -HealthUrl $hurl | Out-Null
        }
    }
    W-Banner "重启结果"
    if ($succeeded.Count -gt 0) { W-OK "成功: $($succeeded -join ', ')" }
    if ($failed.Count -gt 0) { W-Err "失败: $($failed -join ', ')"; exit 1 }
    exit 0
}
if ($Rollback -or $RollbackTo) {
    foreach ($c in $selected) {
        if (Invoke-ComponentRollback -Id $c.id -To $RollbackTo) { $succeeded += $c.id } else { $failed += $c.id }
    }
} else {
    # 部署顺序：companion 先于主组件无意义（同一组件内），按 id 稳定序
    if (-not (Enter-DeployLock)) { exit 1 }
    try {
        foreach ($c in $selected) {
            if (Invoke-ComponentDeploy -Id $c.id) { $succeeded += $c.id } else { $failed += $c.id }
        }
    } finally {
        Exit-DeployLock
    }
}

W-Banner "执行结果"
if ($succeeded.Count -gt 0) { W-OK "成功: $($succeeded -join ', ')" }
if ($failed.Count -gt 0) {
    W-Err "失败: $($failed -join ', ')"
    W-Warn "失败组件已保留备份，可回滚: .\deploy-win.ps1 <id> -Rollback"
    exit 1
}
