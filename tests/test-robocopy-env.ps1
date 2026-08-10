# Verify pack.ps1 robocopy /XF .env exclusion (security test)
# 测试场景：
#   1. 修复后 /XF .env 正确排除 .env 文件
#   2. 旧逻辑 /XD .env 无法排除 .env 文件（确认 bug）
$ErrorActionPreference = "Stop"
$Pass = 0
$Fail = 0

function Assert-Eq {
    param($Label, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        Write-Host "    expected: $Expected"
        Write-Host "    actual:   $Actual"
        $script:Fail++
    }
}

$tmp = Join-Path $env:TEMP "robocopy-env-test"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
$src = Join-Path $tmp "src"
$dst = Join-Path $tmp "dst"
$dst2 = Join-Path $tmp "dst2"
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path $dst2 -Force | Out-Null

# 创建源文件
Set-Content -Path (Join-Path $src ".env") -Value "AUTH_MODE=local" -Encoding UTF8
Set-Content -Path (Join-Path $src "app.py") -Value "print(1)" -Encoding UTF8

# ── 测试 1：修复后 /XF .env 正确排除 .env 文件 ──
Write-Host "=== Test 1: Fixed robocopy /XF .env excludes .env file ==="

robocopy $src $dst /E `
    /XD .venv venv logs __pycache__ .git node_modules `
    /XF *.pyc .env `
    /NFL /NDL /NJH /NJS /NC /NS 2>$null | Out-Null

$hasEnv = Test-Path (Join-Path $dst ".env")
$hasApp = Test-Path (Join-Path $dst "app.py")

Assert-Eq ".env excluded (should be False)" $false $hasEnv
Assert-Eq "app.py copied (should be True)" $true $hasApp

# ── 测试 2：旧逻辑 /XD .env 无法排除 .env 文件（回归对照）──
Write-Host ""
Write-Host "=== Test 2: Old /XD .env does NOT exclude .env file (confirms bug) ==="

robocopy $src $dst2 /E `
    /XD .env .venv `
    /XF *.pyc `
    /NFL /NDL /NJH /NJS /NC /NS 2>$null | Out-Null

$hasEnv2 = Test-Path (Join-Path $dst2 ".env")

Assert-Eq "Old /XD .env did NOT exclude .env (should be True = bug)" $true $hasEnv2
Write-Host "  [INFO] Confirms old /XD .env was buggy — .env file was copied"

# ── 清理 ──
Remove-Item $tmp -Recurse -Force

Write-Host ""
Write-Host "================================"
Write-Host "  PASS: $Pass  FAIL: $Fail"
Write-Host "================================"
if ($Fail -ne 0) { exit 1 }
