# setup-nginx-frontend.ps1 — winvm: nginx + web/admin dist + NSSM service
# 2026-11-18 single-server stack. Idempotent.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Write-Output "=== setup-nginx-frontend START ==="

# ── 1. Extract nginx ──
if (-not (Test-Path "C:\opt\nginx\nginx.exe")) {
    if (Test-Path "C:\opt\nginx") { Remove-Item "C:\opt\nginx" -Recurse -Force }
    Expand-Archive -Path "C:\deploy\assets\win\nginx-1.26.2.zip" -DestinationPath "C:\opt\nginx-tmp" -Force
    $inner = Get-ChildItem "C:\opt\nginx-tmp" | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    Move-Item $inner.FullName "C:\opt\nginx"
    Remove-Item "C:\opt\nginx-tmp" -Recurse -Force
    Write-Output "[OK] nginx extracted"
} else {
    Write-Output "[SKIP] nginx already at C:\opt\nginx"
}

# ── 2. nginx.conf (no-BOM UTF-8) ──
$conf = @'
worker_processes  1;
error_log  logs/error.log;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;
    client_max_body_size 20m;

    server {
        listen 80;
        server_name _;

        # web frontend (root site, SPA)
        location / {
            root  C:/wwwroot/project/financial/financial-web/dist;
            index index.html;
            try_files $uri $uri/ /index.html;
        }

        # admin frontend (SPA)
        location = /admin { return 301 /admin/; }
        location /admin/ {
            alias C:/wwwroot/project/financial/financial-admin/dist/;
            index index.html;
            try_files $uri $uri/ /admin/index.html;
        }

        # API WebSocket
        location /api/ws {
            proxy_pass http://127.0.0.1:5001/api/ws;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
        }

        # API reverse proxy
        location /api/ {
            proxy_pass http://127.0.0.1:5001/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
'@
$confPath = "C:\opt\nginx\conf\nginx.conf"
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($confPath, $conf, $enc)
Write-Output "[OK] nginx.conf written ($((Get-Item $confPath).Length) bytes)"

# ── 3. Extract frontend dists ──
$webDir  = "C:\wwwroot\project\financial\financial-web\dist"
$admDir  = "C:\wwwroot\project\financial\financial-admin\dist"

$pkgWeb = Get-ChildItem "C:\deploy\dist\packages\financial-web-dist*.tar.gz" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$pkgAdm = Get-ChildItem "C:\deploy\dist\packages\financial-admin-dist*.tar.gz" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $pkgWeb -or -not $pkgAdm) { throw "dist packages not found in C:\deploy\dist\packages" }

if (-not (Test-Path "$webDir\index.html")) {
    if (-not (Test-Path $webDir)) { New-Item $webDir -ItemType Directory -Force | Out-Null }
    tar -xzf $pkgWeb.FullName -C $webDir
    Write-Output "[OK] web dist extracted: $($pkgWeb.Name)"
} else { Write-Output "[SKIP] web dist already in place" }

if (-not (Test-Path "$admDir\index.html")) {
    if (-not (Test-Path $admDir)) { New-Item $admDir -ItemType Directory -Force | Out-Null }
    tar -xzf $pkgAdm.FullName -C $admDir
    Write-Output "[OK] admin dist extracted: $($pkgAdm.Name)"
} else { Write-Output "[SKIP] admin dist already in place" }

Write-Output "web files: $((Get-ChildItem $webDir).Count), admin files: $((Get-ChildItem $admDir).Count)"

# ── 4. NSSM service for nginx ──
$nssm = "C:\opt\nssm\nssm.exe"
$svc = "nginx-quant"
$existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
if (-not $existing) {
    & $nssm install $svc "C:\opt\nginx\nginx.exe" | Out-Null
    & $nssm set $svc AppDirectory "C:\opt\nginx" | Out-Null
    & $nssm set $svc AppParameters "-p C:/opt/nginx" | Out-Null
    & $nssm set $svc AppStdout "C:\opt\nginx\logs\service-out.log" | Out-Null
    & $nssm set $svc AppStderr "C:\opt\nginx\logs\service-err.log" | Out-Null
    & $nssm start $svc | Out-Null
    Write-Output "[OK] NSSM service $svc installed+started"
} else {
    & $nssm restart $svc | Out-Null
    Write-Output "[OK] NSSM service $svc restarted"
}
Start-Sleep -Seconds 3

# ── 5. Firewall rule for port 80 ──
$fw = Get-NetFirewallRule -DisplayName "WinVM HTTP 80" -ErrorAction SilentlyContinue
if (-not $fw) {
    New-NetFirewallRule -DisplayName "WinVM HTTP 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
    Write-Output "[OK] firewall rule 80 created"
} else { Write-Output "[SKIP] firewall rule exists" }

# ── 6. Verify ──
$curl = "C:\Windows\System32\curl.exe"
Start-Sleep -Seconds 2
Write-Output "--- verify ---"
Write-Output ("root    : " + (& $curl -s -o NUL -w "%{http_code}" -m 8 http://127.0.0.1/))
Write-Output ("admin   : " + (& $curl -s -o NUL -w "%{http_code}" -m 8 http://127.0.0.1/admin/))
Write-Output ("api     : " + (& $curl -s -m 8 http://127.0.0.1/api/health))
Write-Output ("spa-rt  : " + (& $curl -s -o NUL -w "%{http_code}" -m 8 http://127.0.0.1/markets/xxx))
Write-Output ("spa-adm : " + (& $curl -s -o NUL -w "%{http_code}" -m 8 http://127.0.0.1/admin/login))
Write-Output "=== SETUP-NGINX-DONE ==="
