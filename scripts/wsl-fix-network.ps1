# WSL2 网络永久修复脚本
# 右键 -> 以管理员身份运行 PowerShell -> 执行此脚本

$ErrorActionPreference = "Stop"
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"

Write-Host "[1/4] Cleaning old portproxy rules..." -ForegroundColor Cyan
netsh interface portproxy delete v4tov4 listenport=5432 listenaddress=127.0.0.1 2>$null
netsh interface portproxy delete v4tov4 listenport=6379 listenaddress=127.0.0.1 2>$null
netsh interface portproxy delete v4tov4 listenport=5432 listenaddress=0.0.0.0 2>$null
netsh interface portproxy delete v4tov4 listenport=6379 listenaddress=0.0.0.0 2>$null
Write-Host "[OK] portproxy cleaned" -ForegroundColor Green

Write-Host "[2/4] Writing .wslconfig (networkingMode=mirrored)..." -ForegroundColor Cyan
$configContent = "[wsl2]`r`nnetworkingMode=mirrored`r`n"
[System.IO.File]::WriteAllText($wslConfigPath, $configContent, [System.Text.Encoding]::UTF8)
Write-Host "[OK] .wslconfig written to $wslConfigPath" -ForegroundColor Green

Write-Host "[3/4] Restarting WSL..." -ForegroundColor Cyan
wsl --shutdown
Start-Sleep 5
wsl -d Ubuntu -u root -- bash -c "source /etc/profile.d/baota-path.sh; pg_isready -h 127.0.0.1 -p 5432; redis-cli -a 7d7ced854319d1df ping 2>/dev/null; echo WSL-services-OK"
Start-Sleep 2

Write-Host "[4/4] Verifying Windows connection..." -ForegroundColor Cyan
try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 5432)
    Write-Host "[OK] PG 5432 connected" -ForegroundColor Green
    $client.Close()
} catch {
    Write-Host "[ERR] PG 5432 failed" -ForegroundColor Red
}
try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 6379)
    Write-Host "[OK] Redis 6379 connected" -ForegroundColor Green
    $client.Close()
} catch {
    Write-Host "[ERR] Redis 6379 failed" -ForegroundColor Red
}

Write-Host ""
Write-Host "Done. localhost:5432 (PG) and localhost:6379 (Redis) should now work permanently." -ForegroundColor Cyan
