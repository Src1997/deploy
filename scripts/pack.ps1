#requires -version 5.1
<#
.SYNOPSIS
    Unified project packer — reads projects.json, packs frontend / python / java / go / nodejs components.

.DESCRIPTION
    All projects share this single script. Adding a new project = adding a
    config file in project-configs/<name>/project.toml. No script changes needed.

    Supported component kinds:
      frontend  — pnpm/npm/yarn build -> pack dist/ as tar.gz
      python   — Python source copy (app-package / source-tar) -> tar.gz
      java      — Maven/Gradle build -> pack JAR/WAR + configs -> tar.gz
      go        — go build -> pack binary + configs -> tar.gz
      nodejs    — optional build (TS->JS) -> source copy + configs -> tar.gz

    Prerequisite: run sync-manifest.py first to generate projects.json from
    TOML configs. build.ps1 does this automatically.

    Layout conventions (preserve directory hierarchy, never flatten includes):
      package/                 # App source + VERSION (when mode = app-package)
      scripts/...              # include_files with scripts/ prefix (kept as-is)
      configs/...              # include_files with configs/ prefix (kept as-is)

      When mode = source-tar: source files are at archive root (no package/ prefix).
      When kind = java/go: artifact + includes at archive root (no package/ prefix).

    Security:
      .env files are EXCLUDED by default (via shared exclude lists).
      Only files listed in build.includeEnv are copied as .env into the package.
      .env.remoteA / .env.remoteB / .env.bak.* are ALWAYS excluded.

.EXAMPLE
    .\scripts\pack.ps1 financial
    .\scripts\pack.ps1 financial -DryRun
    .\scripts\pack.ps1 all
    .\scripts\pack.ps1 financial,official-site
#>

param(
    [Parameter(Position = 0)]
    [string]$ProjectId = "",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptsDir = $PSScriptRoot
$DeployDir = Split-Path $ScriptsDir -Parent

# ── Workspace root resolution ──
if ($env:WORKSPACE_ROOT) { $global:WorkspaceRoot = $env:WORKSPACE_ROOT }
else { $global:WorkspaceRoot = Split-Path $DeployDir -Parent }

# ── Output directory ──
$OutDir = Join-Path $DeployDir 'dist\packages'

# ── Logging helpers ──
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

# ── Load projects.json (manifest) ──
function Load-Manifest {
    $manifestPath = Join-Path $DeployDir 'projects.json'
    if (-not (Test-Path $manifestPath)) {
        W-Err "projects.json not found: $manifestPath"
        W-Err "Run: python3 scripts/sync-manifest.py first"
        exit 1
    }
    $data = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return $data
}

# ── Get all project groups from manifest ──
function Get-ProjectGroups {
    param($manifest)
    $groups = [ordered]@{}
    foreach ($p in $manifest.projects) {
        $group = $p.project
        if (-not $groups.Contains($group)) {
            $groups[$group] = @()
        }
        $groups[$group] += $p
    }
    return $groups
}

# ── Get component ID → component object lookup ──
function Get-ComponentLookup {
    param($manifest)
    $lookup = @{}
    foreach ($p in $manifest.projects) {
        $lookup[$p.id] = $p
    }
    return $lookup
}

# ── Frontend packing ──
function Pack-Frontend {
    param($comp)

    $id = $comp.id
    $build = $comp.build
    W-Step "Frontend: $id ($($comp.displayName))"

    $src = Join-Path $global:WorkspaceRoot $comp.sourcePath
    if (-not (Test-Path $src)) {
        W-Err "Source not found: $src"
        return $false
    }

    # Build-time env file (VITE_* etc.)
    if ($build.envFile) {
        $envSrc = Join-Path $DeployDir $build.envFile
        if (Test-Path $envSrc) {
            Copy-Item $envSrc (Join-Path $src '.env') -Force
            W-OK ".env copied for build: $($build.envFile)"
        } else {
            W-Warn "envFile not found, skipping: $($build.envFile)"
        }
    }

    Push-Location $src
    try {
        $pm = if ($build.packageManager) { $build.packageManager } else { "pnpm" }

        # Ensure node_modules (use configured package manager)
        if (-not (Test-Path 'node_modules')) {
            $installCmd = switch ($pm) {
                "pnpm" { "pnpm install" }
                "yarn" { "yarn install" }
                "npm"  { "npm install" }
                default { "$pm install" }
            }
            W-Warn "node_modules missing, running $installCmd..."
            $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            Invoke-Expression $installCmd 2>&1 | ForEach-Object { Write-Host $_ }
            $ErrorActionPreference = $prev
            if ($LASTEXITCODE -ne 0) { W-Err "$installCmd failed"; return $false }
        }

        # Build
        $buildCmd = "$pm $($build.script)"
        W-Step "Running: $buildCmd"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        Invoke-Expression $buildCmd 2>&1 | ForEach-Object { Write-Host $_ }
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) {
            W-Err "Build failed: $id"
            return $false
        }

        # Verify dist
        $distDir = Join-Path $src $build.distDir
        if (-not (Test-Path $distDir)) {
            W-Err "dist directory not found: $distDir"
            return $false
        }

        # Pack dist → tar.gz
        $tar = Join-Path $OutDir $build.artifact
        if ($DryRun) {
            W-Warn "[DryRun] Would pack: $distDir -> $tar"
            return $true
        }
        tar -czf $tar -C $distDir .
        if ($LASTEXITCODE -ne 0) {
            W-Err "tar failed for: $id"
            return $false
        }
        $size = "{0:N1} MB" -f ((Get-Item $tar).Length / 1MB)
        W-OK "Packed: $($build.artifact) ($size)"
        return $true
    } catch {
        W-Err "Frontend packing error: $_"
        return $false
    } finally {
        Pop-Location
    }
}

# ── Backend packing ──
function Pack-Backend {
    param($comp)

    $id = $comp.id
    $build = $comp.build
    W-Step "Python: $id ($($comp.displayName))"

    $src = Join-Path $global:WorkspaceRoot $comp.sourcePath
    if (-not (Test-Path $src)) {
        W-Err "Source not found: $src"
        return $false
    }

    $mode = if ($build.mode) { [string]$build.mode } else { "app-package" }
    $usePackagePrefix = ($mode -ne 'source-tar')

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $artifactPattern = if ($build.artifactPattern) { $build.artifactPattern } else { "$id-*.tar.gz" }
    $tarName = $artifactPattern -replace '\*', $timestamp
    $tarPath = Join-Path $OutDir $tarName

    W-Info "Source:  $src"
    W-Info "Mode:    $mode"
    W-Info "Output:  $tarName"

    if ($DryRun) {
        W-Warn "[DryRun] Would pack source + includes"
        if ($build.includeEnv) {
            W-Warn "[DryRun] includeEnv: $($build.includeEnv -join ', ')"
        }
        if ($build.extraSources) {
            W-Warn "[DryRun] extraSources: $($build.extraSources | ForEach-Object { "$($_.dest) <- $($_.path)" })"
        }
        return $true
    }

    # ── Create staging directory ──
    $staging = Join-Path $env:TEMP "pack-$id-$timestamp"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $codeRoot = if ($usePackagePrefix) {
        Join-Path $staging 'package'
    } else {
        $staging
    }
    New-Item -ItemType Directory -Path $codeRoot -Force | Out-Null

    # ── Robocopy source -> codeRoot (with excludes) ──
    # Exclude dirs and files from manifest (merged shared + project-specific)
    $robArgs = @($src, $codeRoot, '/E')
    if ($build.excludeDirs) {
        $robArgs += '/XD'
        $robArgs += @($build.excludeDirs)
    }
    if ($build.excludeFiles) {
        $robArgs += '/XF'
        $robArgs += @($build.excludeFiles)
    }
    $robArgs += '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS'

    W-Info "Copying source (excluding $($build.excludeDirs.Count) dirs, $($build.excludeFiles.Count) files)..."
    robocopy @robArgs 2>$null | Out-Null
    $rc = $LASTEXITCODE
    # robocopy exit codes: 0-7 = success, 8+ = errors, 16 = serious error
    if ($rc -ge 16) {
        W-Err "robocopy serious error (exit $rc)"
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    if ($rc -ge 8) {
        W-Warn "robocopy had some copy failures (exit $rc), continuing..."
    }

    # ── Post-clean: backup/copy files (robocopy Unicode patterns unreliable) ──
    $fubi = [char]0x526f + [char]0x672c  # "副本" constructed via char codes
    Get-ChildItem -Path $codeRoot -Recurse -File | Where-Object {
        $_.Name -like '*.bak.*' -or $_.Name -like "*$fubi*"
    } | ForEach-Object {
        Remove-Item $_.FullName -Force
        W-Info "[clean] $($_.FullName.Replace($staging, '').TrimStart('\'))"
    }

    # ── Write VERSION file ──
    $versionContent = @"
project=$id
built=$timestamp
host=$env:COMPUTERNAME
"@
    Set-Content -Path (Join-Path $codeRoot 'VERSION') -Value $versionContent -Encoding UTF8
    W-Info "[ok] $(if ($usePackagePrefix) { 'package/VERSION' } else { 'VERSION' })"

    # ── Extra sources (e.g. mcp_server) ──
    if ($build.extraSources) {
        foreach ($es in $build.extraSources) {
            $esPath = [string]$es.path
            $esDest = [string]$es.dest
            if (-not $esPath -or -not $esDest) { continue }
            $esFull = Join-Path $global:WorkspaceRoot $esPath
            if (-not (Test-Path $esFull)) {
                W-Warn "extraSource not found, skipping: $esPath"
                continue
            }
            $esTarget = Join-Path $staging ($esDest -replace '/', [IO.Path]::DirectorySeparatorChar)
            # Use same exclude lists for extra sources
            $esRobArgs = @($esFull, $esTarget, '/E')
            if ($build.excludeDirs) { $esRobArgs += '/XD'; $esRobArgs += @($build.excludeDirs) }
            if ($build.excludeFiles) { $esRobArgs += '/XF'; $esRobArgs += @($build.excludeFiles) }
            $esRobArgs += '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS'
            robocopy @esRobArgs 2>$null | Out-Null
            $rc2 = $LASTEXITCODE
            if ($rc2 -ge 16) {
                W-Err "robocopy serious error for extraSource $esPath (exit $rc2)"
                Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
                return $false
            }
            W-OK "extraSource: $esDest <- $esPath"
        }
    }

    # ── Include files (relative to deploy root, preserve paths) ──
    # keyFiles + includeFiles are both relative to deploy root
    $allIncludes = @()
    if ($build.keyFiles) { $allIncludes += @($build.keyFiles) }
    if ($build.includeFiles) { $allIncludes += @($build.includeFiles) }

    foreach ($f in $allIncludes) {
        $rel = ($f -replace '\\', '/').TrimStart('/')
        $fSrc = Join-Path $DeployDir $rel
        if (-not (Test-Path $fSrc)) {
            W-Warn "include not found, skipping: $rel"
            continue
        }
        $fDest = Join-Path $staging ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $fDestParent = Split-Path $fDest -Parent
        if (-not (Test-Path $fDestParent)) {
            New-Item -ItemType Directory -Path $fDestParent -Force | Out-Null
        }
        Copy-Item $fSrc $fDest -Force
        W-OK "include: $rel"
    }

    # ── Include env (SECURITY-CRITICAL) ──
    # Only files explicitly listed in includeEnv are copied as .env into the package.
    # Default: ALL .env* files are excluded by robocopy /XF.
    # This is the ONLY way .env enters the package.
    if ($build.includeEnv) {
        foreach ($envRel in $build.includeEnv) {
            $rel = ($envRel -replace '\\', '/').TrimStart('/')
            $envSrc = Join-Path $DeployDir $rel
            if (-not (Test-Path $envSrc)) {
                W-Warn "includeEnv not found, skipping (place real $rel): $envSrc"
                continue
            }
            Copy-Item $envSrc (Join-Path $codeRoot '.env') -Force
            W-OK "includeEnv -> .env: $rel"
        }
    }

    # ── Create tar.gz ──
    Push-Location $staging
    try {
        $items = @(Get-ChildItem -Force | ForEach-Object { $_.Name })
        if ($items.Count -eq 0) {
            W-Err "Staging directory is empty"
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        & tar -czf $tarPath @items
        if ($LASTEXITCODE -ne 0) {
            W-Err "tar failed for: $id"
            return $false
        }
        $size = "{0:N1} MB" -f ((Get-Item $tarPath).Length / 1MB)
        W-OK "Packed: $tarName ($size)"
    } catch {
        W-Err "tar error: $_"
        return $false
    } finally {
        Pop-Location
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# ── Java packing ──
# Build with Maven/Gradle, then pack the JAR/WAR + include files.
# Unlike Python backend (source copy), Java is compiled locally and only
# the binary artifact + configs are shipped to the server.
function Pack-Java {
    param($comp)

    $id = $comp.id
    $build = $comp.build
    W-Step "Java: $id ($($comp.displayName))"

    $src = Join-Path $global:WorkspaceRoot $comp.sourcePath
    if (-not (Test-Path $src)) {
        W-Err "Source not found: $src"
        return $false
    }

    $buildTool = if ($build.buildTool) { [string]$build.buildTool } else { "maven" }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $artifactPattern = if ($build.artifactPattern) { $build.artifactPattern } else { "$id-*.tar.gz" }
    $tarName = $artifactPattern -replace '\*', $timestamp
    $tarPath = Join-Path $OutDir $tarName

    W-Info "Source:     $src"
    W-Info "Build tool: $buildTool"
    W-Info "Output:     $tarName"

    # ── DryRun ──
    if ($DryRun) {
        $buildCmd = switch ($buildTool) {
            "maven"  { "mvn clean package -DskipTests" }
            "gradle" { "gradle build -x test" }
            default  { $buildTool }
        }
        W-Warn "[DryRun] Would run: $buildCmd"
        $jarDir = if ($build.jarDir) { $build.jarDir } else { "target" }
        W-Warn "[DryRun] Would search JAR/WAR in: $src/$jarDir"
        if ($build.includeEnv) {
            W-Warn "[DryRun] includeEnv: $($build.includeEnv -join ', ')"
        }
        return $true
    }

    # ── Build ──
    Push-Location $src
    try {
        $buildCmd = switch ($buildTool) {
            "maven"  { "mvn clean package -DskipTests" }
            "gradle" { "gradle build -x test" }
            default  { $buildTool }
        }
        W-Step "Running: $buildCmd"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        Invoke-Expression $buildCmd 2>&1 | ForEach-Object { Write-Host $_ }
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) {
            W-Err "Build failed: $id"
            return $false
        }
    } finally {
        Pop-Location
    }

    # ── Find built JAR/WAR ──
    $jarDir = if ($build.jarDir) { $build.jarDir } else { "target" }
    $jarFull = Join-Path $src $jarDir
    if (-not (Test-Path $jarFull)) {
        W-Err "Build output directory not found: $jarFull"
        return $false
    }

    # Find the artifact: prefer explicit jarPattern, else find newest *-SNAPSHOT.jar or *.jar
    $jarFile = $null
    if ($build.jarPattern) {
        # Pattern like "myapp-*.jar" — find matching, pick newest
        $candidates = Get-ChildItem -Path $jarFull -Filter $build.jarPattern -File -Recurse |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidates) { $jarFile = $candidates }
    } else {
        # Auto-detect: find newest .jar or .war (excluding sources/javadoc classifiers)
        $candidates = Get-ChildItem -Path $jarFull -Include '*.jar', '*.war' -File -Recurse |
            Where-Object { $_.Name -notmatch '-sources\.' -and $_.Name -notmatch '-javadoc\.' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidates) { $jarFile = $candidates }
    }

    if (-not $jarFile) {
        W-Err "No JAR/WAR found in $jarFull"
        return $false
    }
    W-OK "Found artifact: $($jarFile.Name)"

    # ── Create staging directory ──
    $staging = Join-Path $env:TEMP "pack-$id-$timestamp"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # ── Copy JAR/WAR to staging root ──
    Copy-Item $jarFile.FullName (Join-Path $staging $jarFile.Name) -Force
    W-OK "Copied: $($jarFile.Name)"

    # ── Write VERSION file ──
    $versionContent = @"
project=$id
built=$timestamp
host=$env:COMPUTERNAME
"@
    Set-Content -Path (Join-Path $staging 'VERSION') -Value $versionContent -Encoding UTF8
    W-Info "[ok] VERSION"

    # ── Include files (relative to deploy root, preserve paths) ──
    $allIncludes = @()
    if ($build.keyFiles) { $allIncludes += @($build.keyFiles) }
    if ($build.includeFiles) { $allIncludes += @($build.includeFiles) }

    foreach ($f in $allIncludes) {
        $rel = ($f -replace '\\', '/').TrimStart('/')
        $fSrc = Join-Path $DeployDir $rel
        if (-not (Test-Path $fSrc)) {
            W-Warn "include not found, skipping: $rel"
            continue
        }
        $fDest = Join-Path $staging ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $fDestParent = Split-Path $fDest -Parent
        if (-not (Test-Path $fDestParent)) {
            New-Item -ItemType Directory -Path $fDestParent -Force | Out-Null
        }
        Copy-Item $fSrc $fDest -Force
        W-OK "include: $rel"
    }

    # ── Include env (SECURITY-CRITICAL) ──
    # Same logic as backend: only explicitly listed .env files enter the package.
    if ($build.includeEnv) {
        foreach ($envRel in $build.includeEnv) {
            $rel = ($envRel -replace '\\', '/').TrimStart('/')
            $envSrc = Join-Path $DeployDir $rel
            if (-not (Test-Path $envSrc)) {
                W-Warn "includeEnv not found, skipping (place real $rel): $envSrc"
                continue
            }
            Copy-Item $envSrc (Join-Path $staging '.env') -Force
            W-OK "includeEnv -> .env: $rel"
        }
    }

    # ── Create tar.gz ──
    Push-Location $staging
    try {
        $items = @(Get-ChildItem -Force | ForEach-Object { $_.Name })
        if ($items.Count -eq 0) {
            W-Err "Staging directory is empty"
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        & tar -czf $tarPath @items
        if ($LASTEXITCODE -ne 0) {
            W-Err "tar failed for: $id"
            return $false
        }
        $size = "{0:N1} MB" -f ((Get-Item $tarPath).Length / 1MB)
        W-OK "Packed: $tarName ($size)"
    } catch {
        W-Err "tar error: $_"
        return $false
    } finally {
        Pop-Location
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# ── Go packing ──
# Build with `go build`, then pack the binary + include files.
# Similar to Java but produces a single binary instead of JAR/WAR.
# Cross-compilation for Linux server: set GOOS=linux GOARCH=amd64 in build_command.
function Pack-Go {
    param($comp)

    $id = $comp.id
    $build = $comp.build
    W-Step "Go: $id ($($comp.displayName))"

    $src = Join-Path $global:WorkspaceRoot $comp.sourcePath
    if (-not (Test-Path $src)) {
        W-Err "Source not found: $src"
        return $false
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $artifactPattern = if ($build.artifactPattern) { $build.artifactPattern } else { "$id-*.tar.gz" }
    $tarName = $artifactPattern -replace '\*', $timestamp
    $tarPath = Join-Path $OutDir $tarName

    # Build command: default "go build", or custom (e.g. cross-compile for Linux)
    $buildCmd = if ($build.buildCommand) { [string]$build.buildCommand } else { "go build" }

    W-Info "Source:  $src"
    W-Info "Build:   $buildCmd"
    W-Info "Output:  $tarName"

    if ($DryRun) {
        W-Warn "[DryRun] Would run: $buildCmd"
        $binaryDir = if ($build.binaryDir) { $build.binaryDir } else { "" }
        W-Warn "[DryRun] Would search binary in: $src/$binaryDir"
        if ($build.includeEnv) {
            W-Warn "[DryRun] includeEnv: $($build.includeEnv -join ', ')"
        }
        return $true
    }

    # ── Build ──
    Push-Location $src
    try {
        W-Step "Running: $buildCmd"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        Invoke-Expression $buildCmd 2>&1 | ForEach-Object { Write-Host $_ }
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) {
            W-Err "Build failed: $id"
            return $false
        }
    } finally {
        Pop-Location
    }

    # ── Find binary ──
    $binaryDir = if ($build.binaryDir) { Join-Path $src $build.binaryDir } else { $src }
    if (-not (Test-Path $binaryDir)) {
        W-Err "Binary directory not found: $binaryDir"
        return $false
    }

    $binFile = $null
    if ($build.binaryName) {
        # Explicit binary name — look for exact match
        $binPath = Join-Path $binaryDir $build.binaryName
        if (Test-Path $binPath) {
            $binFile = Get-Item $binPath
        } else {
            W-Err "Binary not found: $binPath"
            return $false
        }
    } else {
        # Auto-detect: find newest file with no extension or .exe (Go binary output)
        $candidates = Get-ChildItem -Path $binaryDir -File |
            Where-Object {
                ($_.Extension -eq '' -or $_.Extension -eq '.exe') -and
                -not $_.Name.StartsWith('.')
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidates) { $binFile = $candidates }
    }

    if (-not $binFile) {
        W-Err "No binary found in $binaryDir"
        return $false
    }
    W-OK "Found binary: $($binFile.Name)"

    # ── Create staging directory ──
    $staging = Join-Path $env:TEMP "pack-$id-$timestamp"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # ── Copy binary to staging root ──
    Copy-Item $binFile.FullName (Join-Path $staging $binFile.Name) -Force
    W-OK "Copied: $($binFile.Name)"

    # ── Write VERSION file ──
    $versionContent = @"
project=$id
built=$timestamp
host=$env:COMPUTERNAME
"@
    Set-Content -Path (Join-Path $staging 'VERSION') -Value $versionContent -Encoding UTF8
    W-Info "[ok] VERSION"

    # ── Include files (relative to deploy root, preserve paths) ──
    $allIncludes = @()
    if ($build.keyFiles) { $allIncludes += @($build.keyFiles) }
    if ($build.includeFiles) { $allIncludes += @($build.includeFiles) }

    foreach ($f in $allIncludes) {
        $rel = ($f -replace '\\', '/').TrimStart('/')
        $fSrc = Join-Path $DeployDir $rel
        if (-not (Test-Path $fSrc)) {
            W-Warn "include not found, skipping: $rel"
            continue
        }
        $fDest = Join-Path $staging ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $fDestParent = Split-Path $fDest -Parent
        if (-not (Test-Path $fDestParent)) {
            New-Item -ItemType Directory -Path $fDestParent -Force | Out-Null
        }
        Copy-Item $fSrc $fDest -Force
        W-OK "include: $rel"
    }

    # ── Include env (SECURITY-CRITICAL) ──
    if ($build.includeEnv) {
        foreach ($envRel in $build.includeEnv) {
            $rel = ($envRel -replace '\\', '/').TrimStart('/')
            $envSrc = Join-Path $DeployDir $rel
            if (-not (Test-Path $envSrc)) {
                W-Warn "includeEnv not found, skipping (place real $rel): $envSrc"
                continue
            }
            Copy-Item $envSrc (Join-Path $staging '.env') -Force
            W-OK "includeEnv -> .env: $rel"
        }
    }

    # ── Create tar.gz ──
    Push-Location $staging
    try {
        $items = @(Get-ChildItem -Force | ForEach-Object { $_.Name })
        if ($items.Count -eq 0) {
            W-Err "Staging directory is empty"
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        & tar -czf $tarPath @items
        if ($LASTEXITCODE -ne 0) {
            W-Err "tar failed for: $id"
            return $false
        }
        $size = "{0:N1} MB" -f ((Get-Item $tarPath).Length / 1MB)
        W-OK "Packed: $tarName ($size)"
    } catch {
        W-Err "tar error: $_"
        return $false
    } finally {
        Pop-Location
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# ── Node.js packing ──
# Optional build (e.g. NestJS TS -> JS), then source copy (like Python backend).
# Ships source + package.json + package-lock.json; server runs npm ci --production.
# Supports SSR frameworks (Next.js, Nuxt SSR) and pure Node.js backends (Express, NestJS).
function Pack-Nodejs {
    param($comp)

    $id = $comp.id
    $build = $comp.build
    W-Step "Node.js: $id ($($comp.displayName))"

    $src = Join-Path $global:WorkspaceRoot $comp.sourcePath
    if (-not (Test-Path $src)) {
        W-Err "Source not found: $src"
        return $false
    }

    $mode = if ($build.mode) { [string]$build.mode } else { "app-package" }
    $usePackagePrefix = ($mode -ne 'source-tar')

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $artifactPattern = if ($build.artifactPattern) { $build.artifactPattern } else { "$id-*.tar.gz" }
    $tarName = $artifactPattern -replace '\*', $timestamp
    $tarPath = Join-Path $OutDir $tarName

    $pm = if ($build.packageManager) { $build.packageManager } else { "npm" }

    W-Info "Source:  $src"
    W-Info "Mode:    $mode"
    W-Info "Pkg mgr: $pm"
    W-Info "Output:  $tarName"

    if ($DryRun) {
        if ($build.buildScript) {
            W-Warn "[DryRun] Would run: $pm $($build.buildScript)"
        }
        W-Warn "[DryRun] Would pack source + includes"
        if ($build.includeEnv) {
            W-Warn "[DryRun] includeEnv: $($build.includeEnv -join ', ')"
        }
        return $true
    }

    # ── Optional build step (e.g. NestJS: npm run build -> dist/) ──
    if ($build.buildScript) {
        Push-Location $src
        try {
            if (-not (Test-Path 'node_modules')) {
                $installCmd = switch ($pm) {
                    "pnpm" { "pnpm install" }
                    "yarn" { "yarn install" }
                    "npm"  { "npm install" }
                    default { "$pm install" }
                }
                W-Warn "node_modules missing, running $installCmd..."
                $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
                Invoke-Expression $installCmd 2>&1 | ForEach-Object { Write-Host $_ }
                $ErrorActionPreference = $prev
                if ($LASTEXITCODE -ne 0) { W-Err "$installCmd failed"; return $false }
            }

            $buildCmd = "$pm $($build.buildScript)"
            W-Step "Running: $buildCmd"
            $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            Invoke-Expression $buildCmd 2>&1 | ForEach-Object { Write-Host $_ }
            $ErrorActionPreference = $prev
            if ($LASTEXITCODE -ne 0) {
                W-Err "Build failed: $id"
                return $false
            }
        } finally {
            Pop-Location
        }
    }

    # ── Create staging directory ──
    $staging = Join-Path $env:TEMP "pack-$id-$timestamp"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $codeRoot = if ($usePackagePrefix) {
        Join-Path $staging 'package'
    } else {
        $staging
    }
    New-Item -ItemType Directory -Path $codeRoot -Force | Out-Null

    # ── Robocopy source -> codeRoot (with excludes) ──
    $robArgs = @($src, $codeRoot, '/E')
    if ($build.excludeDirs) {
        $robArgs += '/XD'
        $robArgs += @($build.excludeDirs)
    }
    if ($build.excludeFiles) {
        $robArgs += '/XF'
        $robArgs += @($build.excludeFiles)
    }
    $robArgs += '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS'

    W-Info "Copying source (excluding $($build.excludeDirs.Count) dirs, $($build.excludeFiles.Count) files)..."
    robocopy @robArgs 2>$null | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 16) {
        W-Err "robocopy serious error (exit $rc)"
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    if ($rc -ge 8) {
        W-Warn "robocopy had some copy failures (exit $rc), continuing..."
    }

    # ── Post-clean: backup/copy files (robocopy Unicode patterns unreliable) ──
    $fubi = [char]0x526f + [char]0x672c  # "副本"
    Get-ChildItem -Path $codeRoot -Recurse -File | Where-Object {
        $_.Name -like '*.bak.*' -or $_.Name -like "*$fubi*"
    } | ForEach-Object {
        Remove-Item $_.FullName -Force
        W-Info "[clean] $($_.FullName.Replace($staging, '').TrimStart('\'))"
    }

    # ── Write VERSION file ──
    $versionContent = @"
project=$id
built=$timestamp
host=$env:COMPUTERNAME
"@
    Set-Content -Path (Join-Path $codeRoot 'VERSION') -Value $versionContent -Encoding UTF8
    W-Info "[ok] $(if ($usePackagePrefix) { 'package/VERSION' } else { 'VERSION' })"

    # ── Include files (relative to deploy root, preserve paths) ──
    $allIncludes = @()
    if ($build.keyFiles) { $allIncludes += @($build.keyFiles) }
    if ($build.includeFiles) { $allIncludes += @($build.includeFiles) }

    foreach ($f in $allIncludes) {
        $rel = ($f -replace '\\', '/').TrimStart('/')
        $fSrc = Join-Path $DeployDir $rel
        if (-not (Test-Path $fSrc)) {
            W-Warn "include not found, skipping: $rel"
            continue
        }
        $fDest = Join-Path $staging ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $fDestParent = Split-Path $fDest -Parent
        if (-not (Test-Path $fDestParent)) {
            New-Item -ItemType Directory -Path $fDestParent -Force | Out-Null
        }
        Copy-Item $fSrc $fDest -Force
        W-OK "include: $rel"
    }

    # ── Include env (SECURITY-CRITICAL) ──
    if ($build.includeEnv) {
        foreach ($envRel in $build.includeEnv) {
            $rel = ($envRel -replace '\\', '/').TrimStart('/')
            $envSrc = Join-Path $DeployDir $rel
            if (-not (Test-Path $envSrc)) {
                W-Warn "includeEnv not found, skipping (place real $rel): $envSrc"
                continue
            }
            Copy-Item $envSrc (Join-Path $codeRoot '.env') -Force
            W-OK "includeEnv -> .env: $rel"
        }
    }

    # ── Create tar.gz ──
    Push-Location $staging
    try {
        $items = @(Get-ChildItem -Force | ForEach-Object { $_.Name })
        if ($items.Count -eq 0) {
            W-Err "Staging directory is empty"
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        & tar -czf $tarPath @items
        if ($LASTEXITCODE -ne 0) {
            W-Err "tar failed for: $id"
            return $false
        }
        $size = "{0:N1} MB" -f ((Get-Item $tarPath).Length / 1MB)
        W-OK "Packed: $tarName ($size)"
    } catch {
        W-Err "tar error: $_"
        return $false
    } finally {
        Pop-Location
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# ── Pack a single project group ──
function Pack-Project {
    param($projectId, $components)

    W-Banner "Packing: $projectId ($($components.Count) components)"

    $allOk = $true
    foreach ($comp in $components) {
        $kind = $comp.kind
        if ($kind -eq 'frontend') {
            if (-not (Pack-Frontend $comp)) { $allOk = $false }
        } elseif ($kind -eq 'python') {
            if (-not (Pack-Backend $comp)) { $allOk = $false }
        } elseif ($kind -eq 'java') {
            if (-not (Pack-Java $comp)) { $allOk = $false }
        } elseif ($kind -eq 'go') {
            if (-not (Pack-Go $comp)) { $allOk = $false }
        } elseif ($kind -eq 'nodejs') {
            if (-not (Pack-Nodejs $comp)) { $allOk = $false }
        } else {
            W-Warn "Unknown component kind: $kind ($($comp.id)), skipping"
        }
    }

    if ($allOk) {
        W-OK "Project [$projectId] packing complete"
    } else {
        W-Err "Project [$projectId] has failed components"
    }
    return $allOk
}

# ── Main ──

# Ensure output directory exists
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# Load manifest
$manifest = Load-Manifest
$groups = Get-ProjectGroups $manifest

W-Banner "Unified Packer"
W-Info "Config source:  project-configs/ -> projects.json"
W-Info "Workspace root: $global:WorkspaceRoot"
W-Info "Output dir:     $OutDir"
W-Info "Projects found: $($groups.Count) groups, $($manifest.projects.Count) components"

if ($DryRun) {
    W-Warn "*** DRY RUN MODE — no files will be created ***"
}

# Build component ID → component lookup
$compLookup = Get-ComponentLookup $manifest

# Determine which items to pack
if (-not $ProjectId) {
    # Interactive menu — show project groups
    Write-Host ""
    $groupKeys = @($groups.Keys)
    for ($i = 0; $i -lt $groupKeys.Count; $i++) {
        $comps = $groups[$groupKeys[$i]]
        $compIds = ($comps | ForEach-Object { $_.id }) -join ', '
        Write-Host "  [$($i + 1)] $($groupKeys[$i])  ($compIds)" -ForegroundColor White
    }
    Write-Host "  [a] All projects"
    Write-Host ""
    Write-Host "  Tip: pass component IDs via CLI, e.g. pack.ps1 deepquant-backend,financial-api" -ForegroundColor DarkGray
    Write-Host ""
    $sel = Read-Host "Select [1-$($groupKeys.Count)] or 'a' for all"

    if ($sel -eq 'a' -or $sel -eq 'A') {
        $selectedIds = @($groupKeys)
    } else {
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $groupKeys.Count) {
            $selectedIds = @($groupKeys[$n - 1])
        } else {
            W-Err "Invalid selection"
            exit 1
        }
    }
} elseif ($ProjectId -eq 'all') {
    $selectedIds = @($groups.Keys)
} elseif ($ProjectId -match ',') {
    $selectedIds = @($ProjectId -split ',' | ForEach-Object { $_.Trim() })
} else {
    $selectedIds = @($ProjectId)
}

# Resolve IDs to components (support project group names AND individual component IDs)
$resolvedComponents = @()
foreach ($id in $selectedIds) {
    if ($groups.Contains($id)) {
        # Project group name — add all components in this group
        $resolvedComponents += @($groups[$id])
    } elseif ($compLookup.Contains($id)) {
        # Component ID — add single component
        $resolvedComponents += @($compLookup[$id])
    } else {
        W-Err "Unknown project or component: $id"
        W-Info "Available groups:     $($groups.Keys -join ', ')"
        W-Info "Available components: $($compLookup.Keys -join ', ')"
    }
}

if ($resolvedComponents.Count -eq 0) {
    W-Err "No valid projects or components selected"
    exit 1
}

# Deduplicate by component ID (a component may be selected via both group and individual ID)
$seenIds = @{}
$uniqueComponents = @()
foreach ($comp in $resolvedComponents) {
    if (-not $seenIds.Contains($comp.id)) {
        $seenIds[$comp.id] = $true
        $uniqueComponents += $comp
    }
}
$resolvedComponents = $uniqueComponents

# Pack resolved components (individual or grouped)
$built = @()
$failed = @()
foreach ($comp in $resolvedComponents) {
    $kind = $comp.kind
    $cid = $comp.id
    $compOk = $false
    W-Banner "Packing: $cid ($($comp.displayName))"
    if ($kind -eq 'frontend') {
        $compOk = Pack-Frontend $comp
    } elseif ($kind -eq 'python') {
        $compOk = Pack-Backend $comp
    } elseif ($kind -eq 'java') {
        $compOk = Pack-Java $comp
    } elseif ($kind -eq 'go') {
        $compOk = Pack-Go $comp
    } elseif ($kind -eq 'nodejs') {
        $compOk = Pack-Nodejs $comp
    } else {
        W-Warn "Unknown component kind: $kind ($cid), skipping"
        continue
    }
    if ($compOk) { $built += $cid } else { $failed += $cid }
}

# Summary
W-Banner "Pack Summary"
Write-Host "  Built:  $($built -join ', ')" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "  Failed: $($failed -join ', ')" -ForegroundColor Red
}
Write-Host ""
Write-Host "  Packages in $OutDir :" -ForegroundColor White
if (Test-Path $OutDir) {
    Get-ChildItem $OutDir -Filter '*.tar.gz' | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object {
        $size = "{0:N1} MB" -f ($_.Length / 1MB)
        Write-Host "    $($_.Name)  ($size)" -ForegroundColor Gray
    }
}
Write-Host ""

if ($failed.Count -gt 0) { exit 1 }
