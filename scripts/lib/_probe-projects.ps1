# scripts/lib/_probe-projects.ps1 — 验证 projects.json 加载
. $PSScriptRoot/load-projects.ps1

$projects = Load-Projects
if (-not $projects) {
    Write-Host "FAIL: No projects loaded" -ForegroundColor Red
    exit 1
}

Write-Host "WorkspaceRoot: $global:WorkspaceRoot"
Write-Host "ProjectBase:    $global:ProjectBase"
Write-Host "Projects ($($projects.Count)):"
foreach ($p in $projects) {
    $src = Join-Path $global:WorkspaceRoot $p.sourcePath
    $exists = if (Test-Path $src) { "OK" } else { "MISSING" }
    Write-Host "  [$exists] $($p.id)  src=$($p.sourcePath)  deploy=$($p.deployPath)"
}

# 验证全部源码路径存在
$missing = $projects | Where-Object { -not (Test-Path (Join-Path $global:WorkspaceRoot $_.sourcePath)) }
if ($missing) {
    Write-Host "FAIL: Missing source paths" -ForegroundColor Red
    exit 1
}

Write-Host "PASS: All source paths exist" -ForegroundColor Green
