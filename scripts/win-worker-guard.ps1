# Worker guard for financial-api (winvm) - runs via schtasks every 5 minutes.
# Ensures arq worker is alive; starts streaming worker only when crawler is
# enabled in this deployment (APP_ROLE=api -> streaming exits by design).
# 2026-11-27: winvm never had workers deployed; /health/detailed degraded
# because arq heartbeat was missing. This guard makes arq persistence durable
# across VM reboots (same pattern as mt5-bridge schtasks guard).

$ErrorActionPreference = 'Continue'
$pkg = 'C:/wwwroot/project/financial/financial-api/package/package'
$py = Join-Path $pkg '.venv\Scripts\python.exe'
$logs = Join-Path $pkg 'logs'
New-Item $logs -ItemType Directory -Force | Out-Null

# Package mid-deploy or venv missing -> skip this cycle.
if (-not (Test-Path $py)) { exit 0 }

# --- arq worker guard ---
$arq = Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -match 'worker\.settings\.WorkerSettings' }
if (-not $arq) {
    Start-Process -FilePath $py -ArgumentList '-m', 'arq', 'worker.settings.WorkerSettings' `
        -WorkingDirectory $pkg -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'arq-worker.out.log') `
        -RedirectStandardError (Join-Path $logs 'arq-worker.err.log')
    Write-Output ("{0} arq worker started" -f (Get-Date -Format s))
}

# --- streaming worker guard (crawler-enabled deployments only) ---
$envFile = Join-Path $pkg '.env'
$appRole = 'all'
$crawlerEnabled = $true
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*APP_ROLE\s*=\s*(.+)\s*$') { $appRole = $Matches[1].Trim().Trim('"') }
        if ($_ -match '^\s*CRAWLER_ENABLED\s*=\s*(.+)\s*$') {
            $crawlerEnabled = ($Matches[1].Trim().Trim('"') -notmatch '^(?i)(false|0|no)$')
        }
    }
}
$crawlerOn = ($appRole -ne 'api') -and $crawlerEnabled
$stream = Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -match 'worker\.streaming' }
if ($crawlerOn -and -not $stream) {
    Start-Process -FilePath $py -ArgumentList '-m', 'worker.streaming' `
        -WorkingDirectory $pkg -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'streaming-worker.out.log') `
        -RedirectStandardError (Join-Path $logs 'streaming-worker.err.log')
    Write-Output ("{0} streaming worker started" -f (Get-Date -Format s))
}
