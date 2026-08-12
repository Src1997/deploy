# WSL2 端口转发设置脚本
# 右键 → 以管理员身份运行 PowerShell → 执行此脚本
#
# 功能：将 Windows 127.0.0.1 的 5432/6379 端口转发到 WSL2
# 每次运行自动获取 WSL 最新 IP，先清理旧规则再添加新规则

$ErrorActionPreference = "Stop"

# 获取 WSL IP
$wslIp = (wsl -d Ubuntu -u root -- hostname -I).Trim().Split()[0]
Write-Host "[*] WSL2 IP: $wslIp" -ForegroundColor Cyan

# 清理旧的 portproxy 规则
netsh interface portproxy delete v4tov4 listenport=5432 listenaddress=127.0.0.1 2>$null
netsh interface portproxy delete v4tov4 listenport=6379 listenaddress=127.0.0.1 2>$null

# 添加新规则
netsh interface portproxy add v4tov4 listenport=5432 listenaddress=127.0.0.1 connectport=5432 connectaddress=$wslIp
netsh interface portproxy add v4tov4 listenport=6379 listenaddress=127.0.0.1 connectport=6379 connectaddress=$wslIp

Write-Host "[OK] Port forwarding set up:" -ForegroundColor Green
netsh interface portproxy show v4tov4

# 验证连接
Start-Sleep 1
try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 5432)
    Write-Host "[OK] PG 5432 connected" -ForegroundColor Green
    $client.Close()
} catch {
    Write-Host "[ERR] PG 5432: $_" -ForegroundColor Red
}
try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 6379)
    Write-Host "[OK] Redis 6379 connected" -ForegroundColor Green
    $client.Close()
} catch {
    Write-Host "[ERR] Redis 6379: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Done. PG/Redis now accessible from Windows via localhost:5432 / localhost:6379" -ForegroundColor Cyan
