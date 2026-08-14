#!/usr/bin/env bash
# =============================================================================
# detect-status.sh - Probe which deployment phase the server is at
#
# Usage (server SSH):
#   bash detect-status.sh           # human-readable overview
#   bash detect-status.sh --json    # machine-readable (optional)
#
# Exit codes:
#   0 = core services deployed and healthy
#   1 = first deployment not yet done
#   2 = partial deployment / conflicts need handling
# =============================================================================

# -- CRLF self-fix: Windows-edited scripts may carry \r, strip and re-exec --
if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
    sed -i 's/\r$//' "${BASH_SOURCE[0]}"
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

set -euo pipefail

# -- Locale safety (ASCII-only output, no CJK dependency) --
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

JSON=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON=true ;;
        --help|-h) echo "Usage: bash detect-status.sh [--json]"; exit 0 ;;
    esac
done

# Colors (disabled in json mode)
if $JSON; then
    log() { :; }; ok() { :; }; warn() { :; }; err() { :; }
else
    log()  { echo -e "\033[36m[*]\033[0m $*"; }
    ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
    warn() { echo -e "\033[33m[!]\033[0m $*"; }
    err()  { echo -e "\033[31m[ERR]\033[0m $*"; }
fi

# Load baota PATH
[ -f /etc/profile.d/baota-path.sh ] && . /etc/profile.d/baota-path.sh
for d in /www/server/nginx/sbin /www/server/pgsql/bin /www/server/redis/src; do
    [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# Load deploy.env (optional; probe does not require passwords)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _env_lib in "$SCRIPT_DIR/lib/load-deploy-env.sh" \
                "$SCRIPT_DIR/../lib/load-deploy-env.sh"; do
    if [ -f "$_env_lib" ]; then
        # shellcheck source=lib/load-deploy-env.sh
        source "$_env_lib"
        load_deploy_env "$(dirname "$_env_lib")/.." || true
        break
    fi
done

PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
PG_PASSWORD="${PG_PASSWORD:-}"

# -- Read project list from TOML configs (via config_loader.py) --
PROJECT_DIRS=()
PROJECT_SERVICES=()
PROJECT_HEALTH=()
_load_projects_probe() {
    local cl=""
    for cand in "$SCRIPT_DIR/lib/config_loader.py" \
                "$SCRIPT_DIR/../lib/config_loader.py" \
                "$PROJECT_BASE/uploads/dist/lib/config_loader.py"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { cl="$cand"; break; }
    done
    [ -z "$cl" ] && return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local _pb="${PROJECT_BASE:-}"
    eval "$(python3 "$cl" --format bash-eval 2>/dev/null)" || return 0
    [ -n "$_pb" ] && PROJECT_BASE="$_pb"

    for id in $PROJECT_IDS; do
        dp="${DEPLOY_PATH[$id]:-}"
        [ -n "$dp" ] && PROJECT_DIRS+=("$dp")
        for s in ${SERVICES[$id]:-}; do
            PROJECT_SERVICES+=("$s")
        done
        h="${HEALTH_URL[$id]:-}"
        [ -n "$h" ] && PROJECT_HEALTH+=("$h")
    done
}
_load_projects_probe

# Status variables: 0=not done 1=done 2=partial/abnormal
S_DOCKER=0          # 0=Docker still present 1=Docker cleaned
S_CONFLICTS=0       # 0=system conflicts found 1=clean
S_BAOTA=0
S_COMPONENTS=0      # nginx+pg+redis under baota paths
S_SETUP=0           # dirs + database
S_PACKAGES=0        # uploads has packages
S_DEPLOYED=0        # services running
S_HEALTH=0          # health ok
S_NGINX_SITE=0

# -- Phase 1: Docker ----------------------------------------------
if command -v docker &>/dev/null; then
    S_DOCKER=0
else
    S_DOCKER=1
fi

# -- Phase 1 conflicts: system firewall / system services --
CONFLICT_N=0
timeout 3 systemctl is-active --quiet ufw 2>/dev/null && CONFLICT_N=$((CONFLICT_N + 1))
timeout 3 systemctl is-active --quiet firewalld 2>/dev/null && CONFLICT_N=$((CONFLICT_N + 1))
for svc in nginx apache2 httpd redis-server mysql mariadb; do
    if timeout 3 systemctl is-active --quiet "$svc" 2>/dev/null; then
        unit=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2-)
        [[ "$unit" != /www/* ]] && CONFLICT_N=$((CONFLICT_N + 1))
    fi
done
[ "$CONFLICT_N" -eq 0 ] && S_CONFLICTS=1 || S_CONFLICTS=0

# -- Phase 2: Baota panel --
if [ -f /etc/init.d/bt ] || [ -d /www/server/panel ]; then
    S_BAOTA=1
else
    S_BAOTA=0
fi

# -- Phase 3: Components (must be under baota paths) --
comp_ok=0
comp_need=3
for bin in nginx psql redis-cli; do
    if command -v "$bin" &>/dev/null; then
        p=$(command -v "$bin")
        [[ "$p" == /www/server/* ]] && comp_ok=$((comp_ok + 1))
    fi
done
[ "$comp_ok" -eq "$comp_need" ] && S_COMPONENTS=1 || S_COMPONENTS=0
[ "$comp_ok" -gt 0 ] && [ "$comp_ok" -lt "$comp_need" ] && S_COMPONENTS=2

# -- Phase 4: Directories + Database --
dirs_ok=1
for d in "${PROJECT_DIRS[@]}"; do
    [ -d "$d" ] || dirs_ok=0
done
db_ok=0
if command -v psql &>/dev/null && [[ "$(command -v psql)" == /www/server/* ]]; then
    if [ -n "$PG_PASSWORD" ] && [ "$PG_PASSWORD" != "CHANGE_ME" ]; then
        # timeout 5s: prevent hang when PG is unreachable; 127.0.0.1 avoids IPv6 ::1 resolution
        if timeout 5 env PGPASSWORD="$PG_PASSWORD" psql -U root -h 127.0.0.1 -d postgres -tAc \
            "SELECT count(*) FROM pg_database WHERE datname IN ('quant_zc','quantdinger')" 2>/dev/null | grep -q 2; then
            db_ok=1
        fi
    elif [ -d "$PROJECT_BASE/financial/financial-api/package" ] || [ -d "$PROJECT_BASE/deepquant/backend/package" ]; then
        # Without password, guess by directory presence (avoid hardcoding passwords)
        db_ok=0
    fi
fi
if [ "$dirs_ok" -eq 1 ] && [ "$db_ok" -eq 1 ]; then
    S_SETUP=1
elif [ "$dirs_ok" -eq 1 ] || [ "$db_ok" -eq 1 ]; then
    S_SETUP=2
else
    S_SETUP=0
fi

# -- Phase 5: Uploaded packages --
pkg_dir="$PROJECT_BASE/uploads/dist/packages"
[ ! -d "$pkg_dir" ] && pkg_dir="$PROJECT_BASE/uploads/dist"
if ls "$pkg_dir"/*.tar.gz &>/dev/null; then
    S_PACKAGES=1
else
    S_PACKAGES=0
fi

# -- Phase 6: Service deployment --
svc_active=0
svc_need=${#PROJECT_SERVICES[@]}
for svc in "${PROJECT_SERVICES[@]}"; do
    timeout 3 systemctl is-active --quiet "$svc" 2>/dev/null && svc_active=$((svc_active + 1))
done
if [ "$svc_active" -eq "$svc_need" ]; then
    S_DEPLOYED=1
elif [ "$svc_active" -gt 0 ]; then
    S_DEPLOYED=2
else
    # Static site may also count as "deployed"
    if [ -f "$PROJECT_BASE/financial/financial-web/dist/index.html" ]; then
        S_DEPLOYED=2
    else
        S_DEPLOYED=0
    fi
fi

# -- Health check --
health_ok=0
for h in "${PROJECT_HEALTH[@]}"; do
    # --max-time 5: prevent indefinite hang on unresponsive health endpoint
    curl -sf --max-time 5 "$h" >/dev/null 2>&1 && health_ok=$((health_ok + 1))
done
[ "$health_ok" -eq "${#PROJECT_HEALTH[@]}" ] && S_HEALTH=1 || { [ "$health_ok" -gt 0 ] && S_HEALTH=2 || S_HEALTH=0; }

# -- Phase 7: Nginx site --
if [ -f /www/server/panel/vhost/nginx/default.conf ] \
    || ls /www/server/panel/vhost/nginx/*.conf &>/dev/null; then
    if grep -Rqs 'location.*/api/' /www/server/panel/vhost/nginx/*.conf 2>/dev/null; then
        S_NGINX_SITE=1
    else
        S_NGINX_SITE=2
    fi
else
    S_NGINX_SITE=0
fi

mark() {
    case "$1" in
        1) echo "DONE" ;;
        2) echo "PARTIAL" ;;
        *) echo "TODO" ;;
    esac
}

next_action() {
    [ "$S_DOCKER" -eq 0 ] && { echo "run Phase1: bash 01-cleanup-server.sh"; return; }
    [ "$S_CONFLICTS" -eq 0 ] && { echo "run Phase1 conflicts: bash 01-cleanup-server.sh --conflicts-only"; return; }
    [ "$S_BAOTA" -eq 0 ] && { echo "run Phase2: bash 02-install-baota.sh"; return; }
    [ "$S_COMPONENTS" -ne 1 ] && { echo "Phase3: install Nginx/PostgreSQL/Redis/Python via baota app store, then bash 03-check-components.sh"; return; }
    [ "$S_SETUP" -ne 1 ] && { echo "run Phase4: bash 04-setup-server.sh"; return; }
    [ "$S_PACKAGES" -eq 0 ] && { echo "Phase4-5: run build.ps1 locally + upload dist"; return; }
    [ "$S_DEPLOYED" -ne 1 ] && { echo "run Phase6: bash deploy.sh all --ip=SERVER_IP"; return; }
    [ "$S_NGINX_SITE" -ne 1 ] && { echo "Phase7: bash deploy.sh --nginx (generate config)"; return; }
    [ "$S_HEALTH" -ne 1 ] && { echo "Health check failed: check journalctl / deploy.sh --status"; return; }
    echo "already deployed - for incremental release use build.ps1 + deploy.sh <project>"
}

if $JSON; then
    cat <<EOF
{"docker_clean":$S_DOCKER,"conflicts_clean":$S_CONFLICTS,"baota":$S_BAOTA,"components":$S_COMPONENTS,"setup":$S_SETUP,"packages":$S_PACKAGES,"deployed":$S_DEPLOYED,"health":$S_HEALTH,"nginx_site":$S_NGINX_SITE,"next":"$(next_action | sed 's/"/\\"/g')"}
EOF
else
    echo ""
    echo "==========================================================="
    echo "  Deploy Status Probe  ($PROJECT_BASE)"
    echo "==========================================================="
    echo ""
printf "  %-28s %s\n" "Phase1 Docker cleaned" "$(mark $S_DOCKER)"
printf "  %-28s %s\n" "Phase1 Conflicts cleaned" "$(mark $S_CONFLICTS)"
printf "  %-28s %s\n" "Phase2 Baota panel" "$(mark $S_BAOTA)"
printf "  %-28s %s\n" "Phase3 Components(nginx/pg/redis)" "$(mark $S_COMPONENTS)"
printf "  %-28s %s\n" "Phase4 Dirs + database" "$(mark $S_SETUP)"
    printf "  %-28s %s\n" "Phase5 Packages uploaded" "$(mark $S_PACKAGES)"
    printf "  %-28s %s\n" "Phase6 Services deployed" "$(mark $S_DEPLOYED)  (active $svc_active/$svc_need)"
    printf "  %-28s %s\n" "Phase7 Nginx site routing" "$(mark $S_NGINX_SITE)"
    printf "  %-28s %s\n" "Verify API health check" "$(mark $S_HEALTH)  ($health_ok/${#PROJECT_HEALTH[@]})"
    echo ""
    echo "  Next step -> $(next_action)"
    echo ""
    if [ "$S_DEPLOYED" -eq 1 ] && [ "$S_HEALTH" -eq 1 ]; then
        ok "Verdict: first deployment complete, use incremental release/rollback going forward"
    elif [ "$S_DEPLOYED" -ge 1 ] || [ "$S_BAOTA" -eq 1 ]; then
        warn "Verdict: partially complete / continue remaining phases"
    else
        warn "Verdict: first deployment not yet started"
    fi
    echo ""
fi

# Exit codes
if [ "$S_DEPLOYED" -eq 1 ] && [ "$S_HEALTH" -eq 1 ] && [ "$S_CONFLICTS" -eq 1 ]; then
    exit 0
elif [ "$S_BAOTA" -eq 1 ] || [ "$S_DEPLOYED" -ge 1 ]; then
    exit 2
else
    exit 1
fi
