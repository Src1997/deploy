# scripts/lib/_ps-common.ps1 -- Shared constants and helpers for PowerShell scripts
#
# Dot-source this at the top of build.ps1 / pack.ps1 to get shared encoding
# and logging helpers without duplicating definitions.
#
# Usage:
#   . (Join-Path $PSScriptRoot 'lib\_ps-common.ps1')
#
# Licensed under the same repo conventions as the rest of scripts/.

# -- File encoding: use UTF-8 (no BOM) for all generated text files --
# PS 5.1 'UTF8' writes BOM (EF BB BF) which causes garbled output on Linux.
# PS 7 'UTF8' is BOM-less but we use a .NET encoder for PS 5.1 compatibility.
# This encoder is BOM-free regardless of PowerShell version.
if (-not $global:PS_FILE_ENCODING) {
    $global:PS_FILE_ENCODING = 'UTF8'
}
# BOM-free UTF-8 encoder instance (works on both PS 5.1 and PS 7)
if (-not $global:PS_UTF8_NO_BOM) {
    $global:PS_UTF8_NO_BOM = [System.Text.UTF8Encoding]::new($false)
}

# -- Logging helpers (shared across build.ps1 and pack.ps1) --
if (-not (Get-Command -Name W-Step -ErrorAction SilentlyContinue)) {
    function W-Step  { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
    function W-OK    { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
    function W-Warn  { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
    function W-Err   { param($msg) Write-Host "[ERR] $msg" -ForegroundColor Red }
    function W-Info  { param($msg) Write-Host "    $msg" -ForegroundColor DarkGray }
    function W-Banner {
        param($title)
        Write-Host ""
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host "  $title" -ForegroundColor Cyan
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host ""
    }
    function W-HR { Write-Host "--------------------------------------------------" -ForegroundColor DarkGray }
}

# -- Write text file with BOM-free UTF-8 (avoids \ufeff on Linux) --
function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value,
        [switch]$NoNewline
    )
    # Use .NET writer to guarantee no BOM on both PS 5.1 and PS 7
    if ($NoNewline) {
        [System.IO.File]::WriteAllText($Path, $Value, $global:PS_UTF8_NO_BOM)
    } else {
        [System.IO.File]::WriteAllText($Path, $Value + "`n", $global:PS_UTF8_NO_BOM)
    }
}

# -- Read text file with UTF-8 encoding (strips BOM if present) --
function Read-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path
    )
    return Get-Content $Path -Raw -Encoding UTF8
}

# -- Python locator (finds python3/python, excludes Windows Store placeholders) --
function Get-Python {
    $candidates = @()
    # 1) WorkBuddy managed binary (preferred)
    $wb = Join-Path $env:USERPROFILE '.workbuddy\binaries\python\versions'
    if (Test-Path $wb) {
        $found = Get-ChildItem $wb -Filter 'python.exe' -Recurse -File |
            Sort-Object FullName | Select-Object -First 1
        if ($found) { $candidates += $found.FullName }
    }
    # 2) python3 / python on PATH
    foreach ($c in @('python3', 'python')) {
        try { $p = (Get-Command $c -ErrorAction Stop).Source; if ($p) { $candidates += $p } } catch { }
    }
    foreach ($p in $candidates) {
        try {
            $v = & $p -c "import sys; print(sys.version_info[0])" 2>$null
            if ($LASTEXITCODE -eq 0 -and ($v -match '^\d+')) { return $p }
        } catch { }
    }
    throw "No usable python3/python found (Windows Store placeholder excluded). Install Python 3.11+ or add to PATH."
}
