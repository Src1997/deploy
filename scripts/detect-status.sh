#!/usr/bin/env bash
# =============================================================================
# detect-status.sh — 探测服务器当前处于流程哪一步（是否已部署）
#
# 用法（服务器 SSH）：
#   bash detect-status.sh           # 人类可读总览
#   bash detect-status.sh --json    # 机器可读（可选）
#
# 退出码：
#   0 = 至少「核心服务已部署且健康」
#   1 = 未完成首次部署
#   2 = 部分部署 / 有冲突需处理
# =============================================================================

set -euo pipefail

JSON=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON=true ;;
        --help|-h) echo "Usage: bash detect-status.sh [--json]"; exit 0 ;;
    esac
done

# 颜色（json 模式关闭）
if $JSON; then
    log() { :; }; ok() { :; }; warn() { :; }; err() { :; }
else
    log()  { echo -e "\033[36m[*]\033[0m $*"; }
    ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
    warn() { echo -e "\033[33m[!]\033[0m $*"; }
    err()  { echo -e "\033[31m[ERR]\033[0m $*"; }
fi

# 加载宝塔 PATH
[ -f /etc/profile.d/baota-path.sh ] && . /etc/profile.d/baota-path.sh
for d in /www/server/nginx/sbin /www/server/pgsql/bin /www/server/redis/src; do
    [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# 加载 deploy.env（可选；探测脚本不强制要求密码）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/load-deploy-env.sh" ]; then
    # shellcheck source=lib/load-deploy-env.sh
    source "$SCRIPT_DIR/lib/load-deploy-env.sh"
    load_deploy_env "$SCRIPT_DIR" || true
elif [ -f "$SCRIPT_DIR/../scripts/lib/load-deploy-env.sh" ]; then
    # shellcheck source=lib/load-deploy-env.sh
    source "$SCRIPT_DIR/../scripts/lib/load-deploy-env.sh"
    load_deploy_env "$SCRIPT_DIR/../scripts" || true
fi

PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
PG_PASSWORD="${PG_PASSWORD:-}"

# 状态变量：0=未做 1=已完成 2=部分/异常
S_DOCKER=0          # 0=仍有Docker需清 1=已无Docker
S_CONFLICTS=0       # 0=有系统冲突 1=干净
S_BAOTA=0
S_COMPONENTS=0      # nginx+pg+redis 宝塔路径
S_SETUP=0           # 目录+库
S_PACKAGES=0        # uploads 有包
S_DEPLOYED=0        # 服务在跑
S_HEALTH=0          # health ok
S_NGINX_SITE=0

# ── Phase 0: Docker ─────────────────────────────────────────────
if command -v docker &>/dev/null; then
    S_DOCKER=0
else
    S_DOCKER=1
fi

# ── Phase 0 冲突：系统防火墙 / 系统服务 ─────────────────────────
CONFLICT_N=0
systemctl is-active --quiet ufw 2>/dev/null && CONFLICT_N=$((CONFLICT_N + 1))
systemctl is-active --quiet firewalld 2>/dev/null && CONFLICT_N=$((CONFLICT_N + 1))
for svc in nginx apache2 httpd redis-server mysql mariadb; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        unit=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2-)
        [[ "$unit" != /www/* ]] && CONFLICT_N=$((CONFLICT_N + 1))
    fi
done
[ "$CONFLICT_N" -eq 0 ] && S_CONFLICTS=1 || S_CONFLICTS=0

# ── Phase 1: 宝塔 ───────────────────────────────────────────────
if [ -f /etc/init.d/bt ] || [ -d /www/server/panel ]; then
    S_BAOTA=1
else
    S_BAOTA=0
fi

# ── Phase 2: 组件（必须宝塔路径）────────────────────────────────
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

# ── Phase 3: 目录 + 库 ──────────────────────────────────────────
dirs_ok=1
for d in \
    "$PROJECT_BASE/financial/financial-api" \
    "$PROJECT_BASE/financial/financial-web" \
    "$PROJECT_BASE/official-site" \
    "$PROJECT_BASE/deepquant/backend" \
    "$PROJECT_BASE/deepquant/web" \
    "$PROJECT_BASE/uploads"
do
    [ -d "$d" ] || dirs_ok=0
done
db_ok=0
if command -v psql &>/dev/null && [[ "$(command -v psql)" == /www/server/* ]]; then
    if [ -n "$PG_PASSWORD" ] && [ "$PG_PASSWORD" != "CHANGE_ME" ]; then
        if PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d postgres -tAc \
            "SELECT count(*) FROM pg_database WHERE datname IN ('quant_zc','quantdinger')" 2>/dev/null | grep -q 2; then
            db_ok=1
        fi
    elif [ -d "$PROJECT_BASE/financial/financial-api/package" ] || [ -d "$PROJECT_BASE/deepquant/backend/package" ]; then
        # 无密码时根据目录粗判（避免硬编码密码）
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

# ── Phase 5: 上传包 ─────────────────────────────────────────────
pkg_dir="$PROJECT_BASE/uploads/dist/packages"
[ ! -d "$pkg_dir" ] && pkg_dir="$PROJECT_BASE/uploads/dist"
if ls "$pkg_dir"/*.tar.gz &>/dev/null; then
    S_PACKAGES=1
else
    S_PACKAGES=0
fi

# ── Phase 6: 服务部署 ───────────────────────────────────────────
svc_active=0
svc_need=5
for svc in financial-api financial-crawler financial-worker financial-streaming quantdinger-backend; do
    systemctl is-active --quiet "$svc" 2>/dev/null && svc_active=$((svc_active + 1))
done
if [ "$svc_active" -eq "$svc_need" ]; then
    S_DEPLOYED=1
elif [ "$svc_active" -gt 0 ]; then
    S_DEPLOYED=2
else
    # 静态站也可能算「已部署」
    if [ -f "$PROJECT_BASE/financial/financial-web/dist/index.html" ]; then
        S_DEPLOYED=2
    else
        S_DEPLOYED=0
    fi
fi

# ── 健康检查 ────────────────────────────────────────────────────
health_ok=0
curl -sf http://127.0.0.1:5001/api/health >/dev/null 2>&1 && health_ok=$((health_ok + 1))
curl -sf http://127.0.0.1:5000/api/health >/dev/null 2>&1 && health_ok=$((health_ok + 1))
[ "$health_ok" -eq 2 ] && S_HEALTH=1 || { [ "$health_ok" -eq 1 ] && S_HEALTH=2 || S_HEALTH=0; }

# ── Phase 7: Nginx 站点 ─────────────────────────────────────────
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
    [ "$S_DOCKER" -eq 0 ] && { echo "run Phase0: bash 00-cleanup-docker.sh"; return; }
    [ "$S_CONFLICTS" -eq 0 ] && { echo "run Phase0 conflicts: bash 00-cleanup-docker.sh --conflicts-only   (or 01b)"; return; }
    [ "$S_BAOTA" -eq 0 ] && { echo "run Phase1: bash 01-install-baota.sh"; return; }
    [ "$S_COMPONENTS" -ne 1 ] && { echo "Phase2: 宝塔软件商店安装 Nginx/PostgreSQL/Redis/Python"; return; }
    [ "$S_SETUP" -ne 1 ] && { echo "run Phase3: bash 02-server-setup.sh"; return; }
    [ "$S_PACKAGES" -eq 0 ] && { echo "Phase4-5: 本地 build.ps1 + 上传 dist"; return; }
    [ "$S_DEPLOYED" -ne 1 ] && { echo "run Phase6: bash deploy.sh all --ip=SERVER_IP"; return; }
    [ "$S_NGINX_SITE" -ne 1 ] && { echo "Phase7: 套用 configs/nginx-all-sites.conf 到宝塔站点"; return; }
    [ "$S_HEALTH" -ne 1 ] && { echo "验证失败: 查 journalctl / deploy.sh --status"; return; }
    echo "already deployed — 增量用 build.ps1 + deploy.sh <project>"
}

if $JSON; then
    cat <<EOF
{"docker_clean":$S_DOCKER,"conflicts_clean":$S_CONFLICTS,"baota":$S_BAOTA,"components":$S_COMPONENTS,"setup":$S_SETUP,"packages":$S_PACKAGES,"deployed":$S_DEPLOYED,"health":$S_HEALTH,"nginx_site":$S_NGINX_SITE,"next":"$(next_action | sed 's/"/\\"/g')"}
EOF
else
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  部署状态探测  ($PROJECT_BASE)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    printf "  %-28s %s\n" "Phase0 Docker 已清理" "$(mark $S_DOCKER)"
    printf "  %-28s %s\n" "Phase0 系统冲突已清理" "$(mark $S_CONFLICTS)"
    printf "  %-28s %s\n" "Phase1 宝塔面板" "$(mark $S_BAOTA)"
    printf "  %-28s %s\n" "Phase2 宝塔组件(nginx/pg/redis)" "$(mark $S_COMPONENTS)"
    printf "  %-28s %s\n" "Phase3 目录+数据库" "$(mark $S_SETUP)"
    printf "  %-28s %s\n" "Phase5 已上传构建包" "$(mark $S_PACKAGES)"
    printf "  %-28s %s\n" "Phase6 服务已部署" "$(mark $S_DEPLOYED)  (active $svc_active/$svc_need)"
    printf "  %-28s %s\n" "Phase7 Nginx 站点路由" "$(mark $S_NGINX_SITE)"
    printf "  %-28s %s\n" "验证 API 健康检查" "$(mark $S_HEALTH)  ($health_ok/2)"
    echo ""
    echo "  下一步 → $(next_action)"
    echo ""
    if [ "$S_DEPLOYED" -eq 1 ] && [ "$S_HEALTH" -eq 1 ]; then
        ok "判定：已完成首次部署，后续走增量发版/回滚即可"
    elif [ "$S_DEPLOYED" -ge 1 ] || [ "$S_BAOTA" -eq 1 ]; then
        warn "判定：部分完成 / 需继续未完成阶段"
    else
        warn "判定：尚未完成首次部署"
    fi
    echo ""
fi

# 退出码
if [ "$S_DEPLOYED" -eq 1 ] && [ "$S_HEALTH" -eq 1 ] && [ "$S_CONFLICTS" -eq 1 ]; then
    exit 0
elif [ "$S_BAOTA" -eq 1 ] || [ "$S_DEPLOYED" -ge 1 ]; then
    exit 2
else
    exit 1
fi
