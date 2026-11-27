#requires -version 5.1
<#
.SYNOPSIS
    deploy-win-baota.ps1 - Windows 目标机部署执行器（baota-win 通道，宝塔化）

.DESCRIPTION
    win 通道（deploy-win.ps1，NSSM 托管）2026-11-25 退役后的唯一 Windows 通道。
    与 deploy-win.ps1 同契约（CHANNEL-CONTRACT.md 16 动词，同名 PowerShell 函数），
    差异仅在「谁来托管进程/站点」：

      nginx 站点/反代   → 宝塔（面板 API 校验；routing 面板所有权，脚本只验证）
      python hosting=service → 宝塔 Python 项目 = 原生 Windows 服务
                               python_site_<id>（wrapper: C:\BtSoft\python_site\<id>\service.exe），
                               重启/状态直接操作该服务（与面板操作语义等价，2026-11-25 实证）
      python hosting=user-session → 用户会话后台进程（MT5 IPC，同 win 通道）；
                               由宝塔计划任务「MT5桥守护」每 5 分钟 curl 9199/health 兜底
      NSSM              → 已全部退役（零依赖，env 无 NSSM_EXE 键）

    布局约定（与 Linux 侧一致）：
      PROJECT_BASE\<deployPath>\package\   ← PKG_DIR（app-package 模式代码层）
      PKG_DIR\.venv                        ← Python 虚拟环境
      PKG_DIR\.env                         ← 由 .env.example 模板渲染（include_env 白名单）

.EXAMPLE
    .\deploy-win-baota.ps1 financial-api -Target server-baota-win -Yes   # 部署
    .\deploy-win-baota.ps1 financial-web financial-admin -Target server-baota-win -Yes
    .\deploy-win-baota.ps1 mt5-bridge -Target server-baota-win -NoRestart
    .\deploy-win-baota.ps1 -Status                                       # 服务状态
    .\deploy-win-baota.ps1 financial-api -Logs financial-api -Mode 50    # 日志（宝塔项目日志）
    .\deploy-win-baota.ps1 financial-api -Rollback                       # 交互回滚
    .\deploy-win-baota.ps1 financial-api -RollbackTo 20261125-120000     # 回滚到指定备份
    .\deploy-win-baota.ps1 -List                                         # 列出组件
    .\deploy-win-baota.ps1 -History                                      # 部署历史

.NOTES
    - 重启宝塔 Python 项目服务需要管理员权限（ssh 进 winvm 即 Administrator，天然满足）。
    - 并发锁：<PROJECT_BASE>\deploy.win.lock（30s x 2 等待，与 flock 语义等价）。
    - 前置条件（一次性，M0-M3 已落地）：面板 btPanel 运行 + API 密钥配置
      （limit_addr 含 127.0.0.1）；fin.local 站点（env BT_SITE_ID）；
      python_site_<id> 项目已建（面板 → Python项目）。
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Components = @(),

    [string]$Target = "",        # deploy.env.<target>（如 server-baota-win）
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
    [switch]$RestartOnly,        # 仅重启组件服务（不部署；部署后补配置再拉起的场景）
    [switch]$SkipPreflight       # 跳过宝塔前置校验（应急；默认部署/重启前都校验）
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
    Get-Content $PSCommandPath -TotalCount 52 | Where-Object { $_ -match '^(\.EXAMPLE|\.DESCRIPTION|    |\.SYNOPSIS)' }
    exit 0
}

# ══════════════════════════════════════════════════════════════════
# 环境装载（等价 core/load-deploy-env.sh）
# ══════════════════════════════════════════════════════════════════
$script:Cfg = [ordered]@{}

function Load-DeployBaotaWinEnv {
    # 搜索链：-EnvFile > $DeployRoot\deploy.env.<target> > .\deploy.env.<target>
    $candidates = @()
    if ($EnvFile) { $candidates += $EnvFile }
    if ($Target) {
        $candidates += (Join-Path $DeployRoot "deploy.env.$Target")
        $candidates += (Join-Path (Get-Location) "deploy.env.$Target")
    } elseif (-not $EnvFile) {
        # 未指定 target：显式拒绝（防静默回落错配置，win 通道双轨事故同根因）
        $envs = Get-ChildItem $DeployRoot -Filter 'deploy.env.*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('deploy.env.example') }
        if ($envs) {
            W-Err "检测到环境文件但未指定 -Target，漏带会静默用错配置。"
            W-Info "可用 target: $(($envs | ForEach-Object { $_.Name -replace '^deploy\.env\.', '' }) -join ', ')"
            W-Info "用法: .\deploy-win-baota.ps1 <components> -Target=<target> -Yes"
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

    # baota-win 通道校验
    $chan = $script:Cfg['DEPLOY_CHANNEL']
    if ($chan -ne 'baota-win') {
        W-Err "env 文件 DEPLOY_CHANNEL='$chan' ≠ 'baota-win' —— baota-win 执行器只能跑 baota-win 通道 env。"
        W-Info "env: $envPath"
        exit 1
    }

    # PROJECT_BASE（Windows 路径形态，统一反斜杠）
    $script:ProjectBase = ($script:Cfg['PROJECT_BASE'] -replace '/', '\').TrimEnd('\')
    if (-not $script:ProjectBase) {
        W-Err "env 缺少 PROJECT_BASE（Windows 形态，如 C:/wwwroot/project）"
        exit 1
    }
    W-OK "环境装载: $envPath"
    W-Info "PROJECT_BASE = $script:ProjectBase"
    W-Info "通道         = baota-win（宝塔面板 + 原生服务，NSSM 已退役）"
}

# ══════════════════════════════════════════════════════════════════
# manifest 装载（等价 core/load-projects.sh，消费 config_loader.py JSON）
# ══════════════════════════════════════════════════════════════════
$script:Manifest = $null
$script:CompMap = @{}

function Load-ManifestBaotaWin {
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
    W-OK "manifest: $($script:Manifest.projects.Count) 个组件（baota-win 通道消费 kind: $(channel_supported_kinds)）"
}

# ── 组件路径解析（布局与 Linux 侧一致：PKG_DIR = DEPLOY_PATH/package）──
function Get-CompPaths {
    param([Parameter(Mandatory)]$comp)
    $deployPath = ([string]$comp.deployPath) -replace '/', '\'
    $deployDir = Join-Path $script:ProjectBase $deployPath.Trim('\')
    $mode = if ($comp.build.mode) { [string]$comp.build.mode } else { 'app-package' }
    # frontend：deploy_path 即 dist 目录，tar 平铺直放（winvm 实证布局）
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
# 宝塔面板 API（签名 request_token = md5(t + md5(token))，双重 md5）
# 2026-11-25 winvm v8.5.2 Go 后端实证：Base=面板端口根路径（不带 admin path）
# ══════════════════════════════════════════════════════════════════

function Get-Md5Hex {
    param([Parameter(Mandatory)][string]$Text)
    $md5 = [System.Security.Cryptography.MD5CryptoServiceProvider]::new()
    ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLower()
}

function Invoke-BtApi {
    param(
        [Parameter(Mandatory)][string]$Path,   # module/action，如 config/get_config
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 15
    )
    $base = ($script:Cfg['BT_PANEL_URL'] -replace '/$', '')
    $token = $script:Cfg['BT_API_TOKEN']
    if (-not $base -or -not $token) {
        throw "env 缺少 BT_PANEL_URL / BT_API_TOKEN"
    }
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    $params['request_time'] = $t
    $params['request_token'] = Get-Md5Hex ($t + (Get-Md5Hex $token))

    $body = ($params.GetEnumerator() | ForEach-Object {
        "$([System.Uri]::EscapeDataString($_.Key))=$([System.Uri]::EscapeDataString([string]$_.Value))"
    }) -join '&'
    $resp = Invoke-WebRequest -Uri "$base/$Path" -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -TimeoutSec $TimeoutSec -UseBasicParsing
    return ($resp.Content | ConvertFrom-Json)
}

# ── 宝塔 Python 项目服务名（原生 Windows 服务，wrapper service.exe）──
function Get-PyServiceName {
    param([Parameter(Mandatory)][string]$CompId)
    # 显式映射优先（BT_PY_SERVICE_MAP=id=服务名,id=服务名），缺省 = 前缀 + id
    $map = $script:Cfg['BT_PY_SERVICE_MAP']
    if ($map) {
        foreach ($pair in ($map -split ',')) {
            $k, $v = $pair.Split('=', 2)
            if ($k.Trim() -eq $CompId -and $v) { return $v.Trim() }
        }
    }
    $prefix = $script:Cfg['BT_PY_SERVICE_PREFIX']
    if (-not $prefix) { $prefix = 'python_site_' }
    return "$prefix$CompId"
}

# ── 前置校验：面板 API 可达 + fin.local 站点 + python 项目登记 ──
function Assert-BtPreflight {
    param([string[]]$CompIds = @())
    if ($SkipPreflight) { W-Warn "跳过宝塔前置校验 (-SkipPreflight)"; return $true }
    try {
        W-Step "宝塔前置校验（面板 API / 站点 / Python 项目）"
        $null = Invoke-BtApi -Path 'config/get_config'
        W-OK "面板 API 可达: $($script:Cfg['BT_PANEL_URL'])"

        # 站点校验（root 应落在 PROJECT_BASE 下的 dist 目录）
        $siteId = $script:Cfg['BT_SITE_ID']
        if ($siteId) {
            $site = Invoke-BtApi -Path 'site/get_site_info' -Params @{ siteid = $siteId }
            $siteRoot = ([string]$site.fullPath -replace '/', '\')
            W-OK "站点 #$siteId '$($site.name)' root = $siteRoot"
            if (-not $siteRoot.StartsWith($script:ProjectBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                W-Warn "站点 root 不在 PROJECT_BASE 下（前端 dist 与站点根可能脱节）"
            }
        }

        # python 组件 → service：登记 + 服务存在；user-session：计划任务/bat/
        # config.ini 端口一致性（D4 2026-11-25 评审：此前 user-session 零校验）
        foreach ($id in $CompIds) {
            $comp = $script:CompMap[$id]
            if (-not $comp -or $comp.kind -ne 'python') { continue }
            $hosting = if ($comp.process.hosting) { [string]$comp.process.hosting } else { 'service' }
            if ($hosting -ne 'service') {
                # ── D4：user-session 组件预检 ──
                $pathsUs = Get-CompPaths $comp
                $taskName = $id
                $task = schtasks /query /tn $taskName 2>$null
                if (-not $task) {
                    W-Warn "user-session 组件 $id：计划任务 '$taskName' 不存在（守护拉起链路断裂？首次部署属正常）"
                } else {
                    W-OK "user-session 组件 $id：计划任务 '$taskName' 在位"
                }
                $batFile = $null
                if ($comp.process.cmdWin) {
                    $firstSeg = ([string]$comp.process.cmdWin).Split(' ', 2)[0] -replace '/', '\'
                    if ($firstSeg -like '*.bat' -or $firstSeg -like '*.cmd') {
                        $batFile = if ([System.IO.Path]::IsPathRooted($firstSeg)) { $firstSeg } else { Join-Path $pathsUs.PkgDir $firstSeg }
                    }
                }
                if ($batFile) {
                    if (Test-Path $batFile) { W-OK "user-session 组件 $id：启动脚本在位 ($batFile)" }
                    else { W-Warn "user-session 组件 $id：启动脚本缺失 ($batFile)——机器资产被清？（部署器已保护 *.bat，检查手工删除）" }
                }
                $cfgIni = Join-Path $pathsUs.PkgDir 'config\config.ini'
                if (Test-Path $cfgIni) {
                    $iniPort = $null
                    foreach ($line in (Read-TextFile $cfgIni) -split "`n") {
                        if ($line -match '^\s*port\s*=\s*(\d+)\s*$') { $iniPort = $Matches[1]; break }
                    }
                    $wantPort = [string]$comp.process.port
                    if ($iniPort -and $iniPort -ne $wantPort) {
                        W-Warn "user-session 组件 $id：config.ini port=$iniPort 与 project.toml port=$wantPort 不一致（健康门/守护会指向错误端口）"
                    } else {
                        W-OK "user-session 组件 $id：config.ini 端口一致 ($iniPort)"
                    }
                } else {
                    W-Warn "user-session 组件 $id：config\config.ini 不存在（首次部署属正常，部署后需手工放置）"
                }
                continue
            }
            $svc = Get-PyServiceName -CompId $id
            $reg = Join-Path 'C:\BtSoft\python_site' "$id\service.json"
            if (-not (Test-Path $reg)) {
                W-Err "宝塔 Python 项目未登记: $reg（请先在面板创建 Python 项目，名 = $id）"
                return $false
            }
            if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
                W-Err "Windows 服务不存在: $svc（python 项目 $id 未创建或服务名被改）"
                return $false
            }
            W-OK "Python 项目就位: $id → 服务 $svc"
        }
        return $true
    } catch {
        W-Err "宝塔前置校验失败: $($_.Exception.Message)"
        W-Info "检查：面板服务 btPanel 运行？BT_PANEL_URL/BT_API_TOKEN 正确？API 密钥 limit_addr 含 127.0.0.1？"
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════
# baota-win 通道 16 动词（契约：CHANNEL-CONTRACT.md §3，与 bash 通道同名）
# ══════════════════════════════════════════════════════════════════

function channel_name { "baota-win（宝塔面板托管站点/Python 项目 + MT5 user-session）" }
function channel_supported_kinds { "python frontend" }
function channel_wants_host_venv { "1" }

function channel_routing_sync {
    # baota-win 路由层 = 宝塔站点 + proxy/rewrite 槽位（面板所有权）。
    # 部署期校验而非改写：站点存在（Assert-BtPreflight）+ /api/ 反代槽位文件在位。
    $siteId = $script:Cfg['BT_SITE_ID']
    $confRoot = $script:Cfg['BT_NGINX_CONF']
    if (-not $siteId -or -not $confRoot) {
        W-Warn "env 缺 BT_SITE_ID / BT_NGINX_CONF，routing_sync 跳过校验"
        return $true
    }
    $missing = @()
    foreach ($slot in @('proxy', 'rewrite')) {
        $slotDir = Join-Path $confRoot "$slot\fin.local"
        if (-not (Test-Path $slotDir)) { $missing += $slotDir }
    }
    $apiConf = Join-Path $confRoot 'proxy\fin.local\api.conf'
    if (-not (Test-Path $apiConf)) { $missing += "$apiConf（/api/ 反代）" }
    if ($missing.Count -gt 0) {
        W-Warn "路由槽位缺失: $($missing -join '; ')（M1 落地物被移除？在面板恢复反代配置）"
        return $false
    }
    W-OK "路由槽位校验通过: proxy/rewrite/fin.local + api.conf"
    return $true
}

function channel_frontend_prepare {
    param([string]$Id)
    $comp = $script:CompMap[$Id]
    if (-not $comp -or $comp.kind -ne 'frontend') { return "" }
    $paths = Get-CompPaths $comp
    # 站点根目录 = frontend deploy_dir（M1 落地：fin.local root 指向 financial-web/dist），
    # 管理后台 = nginx 槽位 alias，无需面板建站动作
    return $paths.DeployDir
}
function channel_frontend_preserve { param([string]$Id, [string]$Target) return $true }   # baota-win 无通道资产（.user.ini 语义归 nginx 槽位）
function channel_frontend_restore  { param([string]$Id, [string]$Target) return $true }
function channel_frontend_finalize { param([string]$Id, [string]$Target)
    W-Info "$Id 路由收口归面板（站点/反代槽位静态配置），单组件收口无动作"
    return $true
}
function channel_java_install      { W-Err "baota-win 通道不支持 java kind"; return $false }
function channel_java_restart      { W-Err "baota-win 通道不支持 java kind"; return $false }

# ── cmd_win 解析：首段 = 可执行（相对路径一律相对 PKG_DIR）──
function Resolve-CmdWin {
    param([Parameter(Mandatory)][string]$CmdWin, [Parameter(Mandatory)][string]$PkgDir)
    $cmd = $CmdWin -replace '/', '\'
    $parts = $cmd.Split(' ', 2)
    $exe = $parts[0]
    if (-not [System.IO.Path]::IsPathRooted($exe)) { $exe = Join-Path $PkgDir $exe }
    $args = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    return [pscustomobject]@{ Exe = $exe; Args = $args }
}

# ── hosting=user-session：用户会话后台进程（MT5 IPC 形态，同 win 通道）──
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
    $alive = [bool](Get-Process -Id $p.Id -ErrorAction SilentlyContinue)
    if ($alive) {
        W-OK "$Svc PID=$($p.Id) 运行中（日志: $outLog；宝塔计划任务「MT5桥守护」5 分钟兜底）"
        return $true
    }
    W-Err "$Svc 启动后 2s 内退出 —— 查看 $errLog"
    return $false
}

function Stop-UserSessionProc {
    param([Parameter(Mandatory)][string]$Svc, [Parameter(Mandatory)][string]$PkgDir, [string]$Port)
    $pidFile = Join-Path (Join-Path $PkgDir 'logs') "$Svc.pid"
    if (Test-Path $pidFile) {
        $procId = [int](Read-TextFile $pidFile).Trim()
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $procId -Force -Confirm:$false
            W-Info "已停止 $Svc (PID=$procId)"
        }
        Remove-BuildFile $pidFile
    }
    # D5（2026-11-27 实际事故）：pidfile 过期时（守护 bat 拉起的进程不回写 pidfile），
    # 旧实例不会被停掉 → 新实例绑不上端口静默退出 → 健康门误验旧进程 → 部署空转。
    # 且该形态进程命令行多为相对路径（.venv\Scripts\python.exe svc_entry.py debug），
    # 无法按 package 路径匹配——监听端口是唯一可靠特征，复用 D2 孤儿清理。
    if ($Port) { Stop-PortOrphans -Port $Port }
    return $true
}

# D2（2026-11-25 评审）：孤儿监听进程清理——service wrapper 异常退出路径可能
# 留下孤儿 uvicorn 占住端口（如 5001），新实例绑不上端口、健康门必败。
# stop 之后端口仍被监听 = 孤儿，强制结束。
function Stop-PortOrphans {
    param([Parameter(Mandatory)][string]$Port)
    if (-not $Port) { return }
    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $listeners) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        W-Warn "端口 $Port 仍被进程占用 (PID=$($proc.Id) $($proc.ProcessName)) —— 按孤儿进程强制结束（D2）"
        Stop-Process -Id $proc.Id -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ── hosting=service：宝塔 Python 项目 = 原生 Windows 服务 python_site_<id> ──
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        W-Err "重启宝塔 Python 项目服务（LocalSystem）需要管理员权限——请以管理员运行后重试。"
        return $false
    }
    return $true
}

function channel_python_install {
    param([string]$Id, [string]$PkgDir)
    $comp = $script:CompMap[$Id]
    $hosting = if ($comp.process.hosting) { [string]$comp.process.hosting } else { 'service' }

    if ($hosting -eq 'user-session') {
        # user-session：安装 = 记录意图（启动动作在 restart），无需系统级注册；
        # 守护由宝塔计划任务「MT5桥守护」承担
        W-OK "$Id 托管形态 = user-session（用户会话后台进程，MT5 IPC 兼容；宝塔计划任务守护）"
        return $true
    }

    # service 形态：宝塔 Python 项目（原生 Windows 服务），登记必须已存在
    $svc = Get-PyServiceName -CompId $Id
    $reg = Join-Path 'C:\BtSoft\python_site' "$Id\service.json"
    if (-not (Test-Path $reg)) {
        W-Err "宝塔 Python 项目未登记: $reg"
        W-Info "请在面板 → Python项目 创建项目（名 = $Id，项目路径 = $PkgDir，"
        W-Info "启动文件/命令与 TOML process.cmd_win 一致），再重跑部署。"
        return $false
    }
    if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
        W-Err "Windows 服务不存在: $svc（项目 $id 登记文件在但服务缺失，面板内重启一次项目即可重建）"
        return $false
    }
    # 服务登记后代码层由本部署器同步（包解压 → PKG_DIR），venv 也由部署器管理；
    # service.json 的 shell 命令指向 PKG_DIR\.venv，无需在此改写
    W-OK "$Id 托管形态 = 宝塔 Python 项目（服务 $svc，登记文件在位）"
    return $true
}

function channel_python_restart {
    param([string]$Id)
    $comp = $script:CompMap[$Id]
    $hosting = if ($comp.process.hosting) { [string]$comp.process.hosting } else { 'service' }
    $paths = Get-CompPaths $comp
    $cmdWin = [string]$comp.process.cmdWin; if (-not $cmdWin) { $cmdWin = [string]$comp.process.cmd }

    # D1（2026-11-25 评审）：-NoRestart 也要停旧进程（user-session 形态）——
    # 守护/计划任务拉起时发现旧进程仍在（schtasks "已在运行"），新代码永远
    # 不会被执行（2026-11-25 实际发生）。service 形态无守护拉起，维持跳过。
    if ($NoRestart) {
        if ($hosting -eq 'user-session') {
            $port0 = [string]$comp.process.port
            Stop-UserSessionProc -Svc $Id -PkgDir $paths.PkgDir -Port $port0 | Out-Null
            W-Warn "-NoRestart：已停旧进程（user-session）——等待守护/计划任务拉起新版本"
        } else {
            W-Warn "跳过重启 (-NoRestart)"
        }
        return $true
    }

    # 端口竞态防护：stop 后轮询确认资源释放再 start
    $port = [string]$comp.process.port

    if ($hosting -eq 'user-session') {
        Stop-UserSessionProc -Svc $Id -PkgDir $paths.PkgDir -Port $port | Out-Null
        if ($port -and (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
            W-Warn "端口 $port 仍被占用，等待释放..."
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 1
                if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) { break }
            }
        }
        return (Start-UserSessionProc -Svc $Id -PkgDir $paths.PkgDir -CmdWin $cmdWin)
    }

    # service 形态：重启宝塔 Python 项目服务（stop → 孤儿清理 → start）。
    # D2：不再用 Restart-Service（stop+start 原子封装）——wrapper 异常退出路径
    # 会留孤儿 uvicorn 占端口，必须显式在 stop 后清理再 start。
    $svc = Get-PyServiceName -CompId $Id
    if (-not (Assert-Admin)) { return $false }
    W-Step "重启宝塔 Python 项目服务: $svc"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
    } catch {
        W-Warn "Stop-Service 失败（可能未运行）: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
    if ($port) { Stop-PortOrphans -Port $port }
    try {
        Start-Service -Name $svc -ErrorAction Stop
    } catch {
        $ErrorActionPreference = $prev
        W-Err "服务启动失败: $svc —— 查看宝塔项目日志（-Logs $Id）"
        return $false
    }
    $ErrorActionPreference = $prev
    Start-Sleep -Seconds 2
    return (channel_service_running -Svc $Id)
}

function channel_service_running {
    param([Parameter(Mandatory)][string]$Svc)
    # 1) PID 文件（user-session 形态）；PID 死亡（如进程被守护任务重新拉起，
    #    PID 文件过期）→ 不直接判停，继续走服务/端口兜底
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python') { continue }
        $paths = Get-CompPaths $comp
        $pidFile = Join-Path (Join-Path $paths.PkgDir 'logs') "$Svc.pid"
        if (Test-Path $pidFile) {
            $procId = [int](Read-TextFile $pidFile).Trim()
            if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { return $true }
        }
    }
    # 2) Windows 服务：原名或宝塔 Python 项目名（python_site_<id>）
    $svcObj = Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if ($svcObj) { return ($svcObj.Status -eq 'Running') }
    $pySvc = Get-PyServiceName -CompId $Svc
    if ($pySvc -ne $Svc) {
        $svcObj = Get-Service -Name $pySvc -ErrorAction SilentlyContinue
        if ($svcObj) { return ($svcObj.Status -eq 'Running') }
    }
    # 3) user-session 兜底：无 PID 文件（由 schtasks/守护拉起，如 MT5 桥）→
    #    按组件 process.port 探监听（有监听即视为运行中）
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python' -or $svc -ne $comp.id) { continue }
        $hosting = if ($comp.process.hosting) { [string]$comp.process.hosting } else { 'service' }
        $port = [string]$comp.process.port
        if ($hosting -eq 'user-session' -and $port) {
            return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        }
    }
    return $false
}

function channel_service_restart {
    param([Parameter(Mandatory)][string]$Svc)
    foreach ($comp in $script:Manifest.projects) {
        if ($comp.kind -ne 'python') { continue }
        $svcs = @($comp.id) + @($comp.companions | ForEach-Object { $_.name })
        if ($svcs -contains $Svc) {
            if ($Svc -eq $comp.id) { return (channel_python_restart -Id $comp.id) }
            # companion：user-session 形态独立重启（同 win 通道）
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
    Write-Host ("  {0,-26} {1,-10} {2}" -f "SERVICE", "STATUS", "HEALTH") -ForegroundColor White
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
            Write-Host ("  {0,-26} " -f $svc) -NoNewline
            Write-Host ("{0,-10}" -f $status) -ForegroundColor $color -NoNewline
            Write-Host (" {0}" -f $health)
        }
    }
    Write-Host ""
}

function channel_logs {
    param([Parameter(Mandatory)][string]$Svc, [string]$Mode = "50")
    # 日志定位：service 形态 → 宝塔项目日志优先（C:\BtSoft\python_site\<id>\logs）；
    # user-session → PKG logs\<svc>.out.log
    $outLog = $null; $errLog = $null

    # 宝塔 Python 项目日志（wrapper service.exe 输出，2026-11-25 实证路径）
    $btLogDir = Join-Path 'C:\BtSoft\python_site' "$Svc\logs"
    if (Test-Path $btLogDir) {
        $outLog = Join-Path $btLogDir 'service.log'
        $errLog = Join-Path $btLogDir 'error.log'
    }
    if (-not $outLog) {
        foreach ($comp in $script:Manifest.projects) {
            if ($comp.kind -ne 'python') { continue }
            $paths = Get-CompPaths $comp
            $o = Join-Path (Join-Path $paths.PkgDir 'logs') "$Svc.out.log"
            if (Test-Path $o) { $outLog = $o; $errLog = Join-Path (Join-Path $paths.PkgDir 'logs') "$Svc.err.log"; break }
        }
    }
    if (-not $outLog) {
        W-Err "未找到 $Svc 的日志（C:\BtSoft\python_site\$Svc\logs 或 PKG logs\<svc>.out.log）"
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
        W-Err "baota-win 通道缺少统一动词: $($missing -join ' ')（契约: CHANNEL-CONTRACT.md）"
        exit 1
    }
    W-OK "通道: baota-win（$(channel_name)）| 支持 kind: $(channel_supported_kinds) | 16 动词断言通过"
}

# ══════════════════════════════════════════════════════════════════
# 并发锁（等价 flock 语义）
# ══════════════════════════════════════════════════════════════════
function Enter-DeployLock {
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
        default    { W-Err "baota-win 通道不支持 kind=$($comp.kind)（$Id）"; return $false }
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

    # baota-win：站点根目录即此 dist（fin.local root 指向 deploy_path），
    # nginx alias+try_files 对子路径 SPA 无需 Linux 侧的自引用 symlink（winvm 实证）。
    # 无 junction 是刻意的——junction 自引用会让 robocopy 备份/清理无限递归。
    $auditLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | DEPLOY-OK | $Id | $($artifact.Name) | kind=frontend | channel=baota-win"
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
        $baks = Get-ChildItem (Join-Path $backupBase $Id) -Directory | Sort-Object Name
        if ($baks.Count -gt $maxBackups) {
            $baks | Select-Object -First ($baks.Count - $maxBackups) | ForEach-Object {
                Remove-BuildDir $_.FullName; W-Info "清理旧备份: $($_.Name)"
            }
        }
    } else {
        W-Info "首次部署（无既有 package/，跳过备份）"
    }

    # ── 4. 清空 PKG_DIR（保留 .env/.venv/logs/data —— KINDS-CONTRACT 铁律 3；
    #       *.bat = 机器资产：schtasks/守护任务的动作目标（如 run_bridge_task.bat），
    #       不在 tar 包里，清掉会让计划任务失效（2026-11-25 实证）；
    #       config\config.ini = 机器调优资产（端口/终端路径/凭据），同样保护）──
    $machineCfg = Join-Path $paths.PkgDir 'config\config.ini'
    $cfgStash = $null
    if (Test-Path $machineCfg) {
        $cfgStash = Join-Path $env:TEMP "deploybaotawin-cfg-$Id.ini"
        Copy-Item $machineCfg $cfgStash -Force
    }
    if (Test-Path $paths.PkgDir) {
        W-Step "清空 pkg_dir（保留 .env .venv logs data *.bat config\config.ini）"
        Get-ChildItem $paths.PkgDir -Force | Where-Object {
            $_.Name -notin @('.env', '.venv', 'logs', 'data') -and $_.Extension -ne '.bat'
        } | ForEach-Object {
            if ($_.PSIsContainer) { Remove-BuildDir $_.FullName } else { Remove-BuildFile $_.FullName }
        }
    } else {
        New-Item -ItemType Directory -Path $paths.PkgDir -Force | Out-Null
    }

    # ── 5. 解压（tar → temp → package/ 内容进 PKG_DIR）──
    W-Step "解压 $($artifact.Name)"
    $tempDir = Join-Path $env:TEMP "deploybaotawin-$Id-$(Get-Date -Format 'yyyyMMddHHmmss')"
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
    # 还原机器调优配置（tar 未携带 config\config.ini 时）
    if ($cfgStash -and (Test-Path $cfgStash) -and -not (Test-Path $machineCfg)) {
        New-Item -ItemType Directory -Path (Split-Path $machineCfg -Parent) -Force | Out-Null
        Copy-Item $cfgStash $machineCfg -Force
        Remove-BuildFile $cfgStash
        W-OK "已还原机器配置: config\config.ini"
    }
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

    # ── 8. 迁移 + seed ──
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
    # seed 自身报明确 RuntimeError，可诊断）。
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

    # ── 9. 服务化 + 重启（service=宝塔 Python 项目服务；user-session=会话进程）──
    if (-not (channel_python_install -Id $Id -PkgDir $paths.PkgDir)) { return $false }
    if (-not (channel_python_restart -Id $Id)) { return $false }

    # ── 10. 健康门（3 次重试；失败自动回滚最近备份（D3）；-NoRestart 时跳过）──
    $healthUrl = [string]$comp.healthUrl
    if ($NoRestart) {
        W-Warn "-NoRestart：服务未启动，跳过健康门"
    } elseif (-not (Invoke-HealthCheck -HealthUrl $healthUrl)) {
        $bakRoot = Join-Path (Join-Path $script:ProjectBase 'backup') $Id
        $hasBak = (Get-ChildItem $bakRoot -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
        if ($hasBak) {
            # D3（2026-11-25 评审）：健康门失败自动回滚——此前仅提示不回滚，
            # 夜间/无人值守部署会留下一个不健康的生产实例跑到底。
            W-Warn "健康检查未通过 —— 自动回滚到最近备份（D3）"
            if (Invoke-ComponentRollback -Id $Id -To 'latest') { return $false }
            W-Err "自动回滚失败 —— 请手工处理: .\deploy-win-baota.ps1 $Id -Rollback"
            return $false
        }
        W-Err "健康检查未通过（无可用备份，跳过自动回滚）—— 查看日志排查"
        return $false
    }

    # ── 11. 审计（与 Linux 侧 deploy.log 同格式）──
    $auditDir = Join-Path (Join-Path $script:ProjectBase 'uploads') ''
    if (-not (Test-Path $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
    $auditLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | DEPLOY-OK | $Id | $($artifact.Name) | hosting=$($comp.process.hosting) | channel=baota-win"
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
        $svc = Get-PyServiceName -CompId $Id
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch { }
        $ErrorActionPreference = $prev
    }

    # 机器资产保护（D-F2 同口径，2026-11-26 回滚路径补齐——此前仅部署路径有）：
    #   *.bat = schtasks/守护任务动作目标；config\config.ini = 机器调优资产（端口/凭据）
    #   均不随版本回退：清空前 stash，robocopy 排除，还原后恢复现值
    $machineCfg = Join-Path $paths.PkgDir 'config\config.ini'
    $cfgStash = $null
    if (Test-Path $machineCfg) {
        $cfgStash = Join-Path $env:TEMP "deploybaotawin-cfg-rb-$Id.ini"
        Copy-Item $machineCfg $cfgStash -Force
    }
    Get-ChildItem $paths.PkgDir -Force | Where-Object {
        $_.Name -notin @('.env', '.venv', 'logs', 'data') -and $_.Extension -ne '.bat'
    } | ForEach-Object {
        if ($_.PSIsContainer) { Remove-BuildDir $_.FullName } else { Remove-BuildFile $_.FullName }
    }
    robocopy $chosen.FullName $paths.PkgDir '/E' '/XD' (Join-Path $chosen.FullName '.venv') `
        '/XF' 'config.ini' '*.bat' `
        '/NFL' '/NDL' '/NJH' '/NJS' '/NC' '/NS' 2>$null | Out-Null
    if ($LASTEXITCODE -ge 8) { W-Err "回滚复制失败"; return $false }
    if ($cfgStash -and (Test-Path $cfgStash)) {
        New-Item (Split-Path $machineCfg -Parent) -ItemType Directory -Force | Out-Null
        Copy-Item $cfgStash $machineCfg -Force
        Remove-BuildFile $cfgStash
        W-OK "已保留机器资产: config\config.ini（*.bat 未受回滚影响）"
    }

    if (-not $NoRestart) { channel_python_restart -Id $Id | Out-Null }
    $auditLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | ROLLBACK | $Id | backup=$($chosen.Name) | channel=baota-win"
    [System.IO.File]::AppendAllText((Join-Path (Join-Path $script:ProjectBase 'uploads') 'deploy.log'), $auditLine + "`n", $global:PS_UTF8_NO_BOM)
    W-OK "回滚完成: $Id → $($chosen.Name)"
    return $true
}

# ══════════════════════════════════════════════════════════════════
# 主入口
# ══════════════════════════════════════════════════════════════════

Load-DeployBaotaWinEnv
Load-ManifestBaotaWin
Assert-ChannelVerbs

# ── -List ──
if ($List) {
    W-Banner "可用组件（baota-win 通道可部署 = kind python / frontend）"
    foreach ($p in $script:Manifest.projects) {
        $ok = $p.kind -in @('python', 'frontend')
        $flag = if ($ok) { "✓ $($p.kind)" } else { "× $($p.kind)（baota-win 通道不支持）" }
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

# ── 组件解析（支持组件 id / 逗号串 / all）──
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
            W-Err "未知组件: $id（-List 查看；组名未在 baota-win 通道支持，请用组件 id）"
            exit 1
        }
    }
}
$selected = @($selected | Sort-Object id -Unique)
if ($selected.Count -eq 0) { W-Err "未选择任何组件"; exit 1 }

# ── 宝塔前置校验（部署/回滚/仅重启前；-List/-Status/-Logs 不需要）──
if (-not (Assert-BtPreflight -CompIds $selected.Id)) { exit 1 }

# ── 部署 / 回滚 / 仅重启 分发 ──
$succeeded = @(); $failed = @()
if ($RestartOnly) {
    foreach ($c in $selected) {
        if ($c.kind -eq 'frontend') { W-Warn "$c.id 是 frontend，无服务可重启，跳过"; continue }
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
    # 部署顺序：按 id 稳定序（frontend 先于 python 无依赖关系，幂等）
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
    W-Warn "失败组件已保留备份，可回滚: .\deploy-win-baota.ps1 <id> -Rollback"
    exit 1
}
