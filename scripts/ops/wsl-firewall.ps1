# Windows Defender Firewall rules for WSL2 PG/Redis
# Run as Administrator: powershell -ExecutionPolicy Bypass -File wsl-firewall.ps1

$ports = @(5432, 6379)
foreach ($port in $ports) {
    $ruleName = "WSL2 Port $port"
    # Remove existing rule if any
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    # Add inbound allow rule
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile Any
    Write-Host "[OK] Added firewall rule: $ruleName (Inbound, TCP $port)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Firewall rules added for ports 5432 (PG) and 6379 (Redis)." -ForegroundColor Cyan
