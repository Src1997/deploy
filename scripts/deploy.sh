#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# deploy.sh — 交互式部署/回滚/日志工具（服务器端）
#
# 用法：
#   bash deploy.sh                      # 交互式主菜单
#   bash deploy.sh <project> [options]  # 命令行直接执行
#   bash deploy.sh --status             # 查看所有服务状态
#   bash deploy.sh --logs [project]     # 查看日志
#
# 项目列表：
#   financial-web       行情/社区前端
#   financial-api       FastAPI 后端
#   official-site       卓筹介绍站
#   deepquant-web       QuantDinger 前端
#   deepquant-backend   QuantDinger 后端
#   all                 全量
#
# 选项：
#   --ip=SERVER_IP      设置服务器 IP（更新 CORS）
#   --no-restart         部署但不重启服务
#   --rollback           交互选择备份回滚（可单项目 / 多选 / all）
#   --rollback=TS|latest 回滚到指定时间戳，或各项目最新备份
#   --yes|-y|--ci       非交互模式：跳过所有确认提示（部署 + 回滚）
#   --list              列出可用备份
#   --status            查看服务状态
#   --logs [project]    查看日志（默认 financial-api）
#   --help              帮助
#
# 回滚示例：
#   bash deploy.sh financial-web --rollback
#   bash deploy.sh financial-web,official-site --rollback=latest
#   bash deploy.sh all --rollback
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── 颜色 ───────────────────────────────────────────────────────────
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
hr()   { echo -e "${DIM}────────────────────────────────────────────────${NC}"; }
banner() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "  ${BOLD}$*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"; }

# 提前定义帮助（参数解析阶段即可调用）
show_help() {
    cat <<'HELP'
  命令行用法：
    bash deploy.sh                      交互式主菜单
    bash deploy.sh <project> [options]  命令行直接执行
    bash deploy.sh proj1,proj2 --rollback  多项目回滚
    bash deploy.sh all --rollback          全量回滚（需确认）
    bash deploy.sh --status             查看所有服务状态
    bash deploy.sh --logs [project]     查看日志
    bash deploy.sh --help                显示此帮助

  项目列表：
    financial-web       行情/社区前端
    financial-api       FastAPI 后端
    official-site       卓筹介绍站
    deepquant-web       QuantDinger 前端
    deepquant-backend   QuantDinger 后端
    all                 全量

  选项：
    --ip=SERVER_IP      设置服务器 IP（更新 CORS）
    --no-restart        部署但不重启服务
    --rollback          交互选择备份回滚（单/多/全量）
    --rollback=TS       回滚到指定版本时间戳
    --rollback=latest   各项目回滚到各自最新备份
    --yes / -y / --ci   非交互模式：跳过所有确认提示（部署 + 回滚，CI/CD 用）
    --list              列出可用备份
    --status            查看服务状态
    --logs [project]    查看日志（默认 financial-api）
    --lines=N           日志行数（默认 50，0=实时跟踪）
    --logs=error        只看 ERROR 级别日志
    --nginx             部署后自动配置 Nginx（拷贝 nginx-all-sites.conf 并 reload）
    --help              显示此帮助

  备份与回滚说明：
    - 每次部署前自动备份到 $PROJECT_BASE/backup/<项目>/，保留最近 5 份
    - 回滚前会再备份「当前线上版本」，避免回滚后无法还原
    - 单项目 / 多项目 / all 回滚均会列出目标并要求确认（除非 --yes）

  非交互 / CI/CD 部署示例：
    bash deploy.sh financial-api --yes --ip=47.86.32.234
    bash deploy.sh financial-web,financial-api --yes
    bash deploy.sh all --yes --ip=47.86.32.234
    bash deploy.sh financial-api --rollback=latest --yes
HELP
}

# ── 路径常量（可用环境变量 / deploy.env 覆盖，便于 WSL 沙箱）────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/load-deploy-env.sh" ]; then
    # shellcheck source=lib/load-deploy-env.sh
    source "$SCRIPT_DIR/lib/load-deploy-env.sh"
    load_deploy_env "$SCRIPT_DIR" || true
elif [ -f "$SCRIPT_DIR/../scripts/lib/load-deploy-env.sh" ]; then
    # shellcheck source=lib/load-deploy-env.sh
    source "$SCRIPT_DIR/../scripts/lib/load-deploy-env.sh"
    load_deploy_env "$SCRIPT_DIR/../scripts" || true
else
    _load_optional_env() {
        local f
        for f in "${DEPLOY_ENV_FILE:-}" \
                 "$SCRIPT_DIR/deploy.env" \
                 "$SCRIPT_DIR/../deploy.env" \
                 "$(pwd)/deploy.env" \
                 "${HOME}/deploy-sandbox/deploy.env" \
                 "/www/wwwroot/project/deploy.env"; do
            [ -n "$f" ] && [ -f "$f" ] || continue
            set -a
            # shellcheck disable=SC1090
            source "$f"
            set +a
            break
        done
    }
    _load_optional_env
    require_deploy_secrets() {
        if [ -z "${PG_PASSWORD:-}" ] || [ "${PG_PASSWORD}" = "CHANGE_ME" ] \
           || [ -z "${REDIS_PASSWORD:-}" ] || [ "${REDIS_PASSWORD}" = "CHANGE_ME" ]; then
            err "请配置 deploy.env（PG_PASSWORD / REDIS_PASSWORD），参见 deploy.env.example"
            return 1
        fi
        return 0
    }
fi

PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
PACKAGES_DIR="${PACKAGES_DIR:-$PROJECT_BASE/uploads/dist/packages}"
[ ! -d "$PACKAGES_DIR" ] && PACKAGES_DIR="$PROJECT_BASE/uploads/dist"
DIST_ROOT="${DIST_ROOT:-$PROJECT_BASE/uploads/dist}"
CONFIGS_SRC="${CONFIGS_SRC:-$DIST_ROOT/configs}"

BACKUP_BASE="${BACKUP_BASE:-$PROJECT_BASE/backup}"
MAX_BACKUPS="${MAX_BACKUPS:-5}"
PG_USER="${PG_USER:-root}"
PG_PASSWORD="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-localhost}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
FRONTEND_URL="${FRONTEND_URL:-}"
DOMAIN="${DOMAIN:-}"
WWW_DOMAIN="${WWW_DOMAIN:-}"
APP_NAME="${APP_NAME:-MyApp}"

# ── 审计日志 ──────────────────────────────────────────────────────
DEPLOY_LOG="${DEPLOY_LOG:-$PROJECT_BASE/uploads/deploy.log}"
# 专用临时目录，禁止向 /tmp 顶层散落文件
DEPLOY_TMP_DIR="${DEPLOY_TMP_DIR:-/tmp/fin-deploy}"
mkdir -p "$DEPLOY_TMP_DIR"
LOCK_FILE="${LOCK_FILE:-$DEPLOY_TMP_DIR/deploy.lock}"

audit_log() {
    local msg="$*"
    mkdir -p "$(dirname "$DEPLOY_LOG")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$DEPLOY_LOG"
}

# ── 项目清单：从 projects.json 加载（SSOT）──
SCRIPT_DIR_DEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_DEPLOY/lib/load-projects.sh" ]; then
    source "$SCRIPT_DIR_DEPLOY/lib/load-projects.sh"
elif [ -f "$DIST_ROOT/lib/load-projects.sh" ]; then
    source "$DIST_ROOT/lib/load-projects.sh"
else
    echo "[ERR] load-projects.sh not found" >&2
    exit 1
fi

# 从加载器结果构建 deploy.sh 兼容变量
declare -a PROJECTS=($PROJECT_IDS)
declare -A PROJECT_NAMES=()
declare -A PROJECT_DIST=()
declare -A PROJECT_TAR=()
for p in "${PROJECTS[@]}"; do
    PROJECT_NAMES[$p]="${PROJECT_DISPLAY_NAME[$p]}"
    PROJECT_DIST[$p]="${DEPLOY_PATH[$p]}"
    PROJECT_TAR[$p]="${ARTIFACT_NAME[$p]}"
done
# 从清单加载 PROJECT_SERVICE（取第一个服务）和 PROJECT_HEALTH
declare -A PROJECT_SERVICE=()
declare -A PROJECT_HEALTH=()
for p in "${PROJECTS[@]}"; do
    PROJECT_HEALTH[$p]="${HEALTH_URL[$p]}"
    _svcs="${SERVICES[$p]}"
    PROJECT_SERVICE[$p]="${_svcs%% *}"
done

# 向后兼容目录变量（deploy 函数内仍在使用）
FINANCIAL_API_DIR="${PROJECT_BASE}/financial/financial-api"
FINANCIAL_WEB_DIR="${PROJECT_BASE}/financial/financial-web"
OFFICIAL_SITE_DIR="${PROJECT_BASE}/official-site"
DEEPQUANT_BACKEND_DIR="${PROJECT_BASE}/deepquant/backend"
DEEPQUANT_WEB_DIR="${PROJECT_BASE}/deepquant/web"

# ── 参数解析 ────────────────────────────────────────────────────────
PROJECT=""
PROJECT_LIST=()          # 多项目：financial-web,official-site 或 all
SERVER_IP=""
NO_RESTART=false
DO_ROLLBACK=false
ROLLBACK_VERSION=""      # 空=交互选；latest=各项目最新；时间戳=指定版
LIST_BACKUPS=false
SHOW_STATUS=false
SHOW_LOGS=false
SHOW_HELP=false
ASSUME_YES=false
LOG_LINES=50
LOG_LEVEL=""
DEPLOY_NGINX=false

parse_project_token() {
    local token="$1"
    if [ "$token" = "all" ]; then
        PROJECT="all"
        PROJECT_LIST=("${PROJECTS[@]}")
        return
    fi
    if [[ "$token" == *","* ]]; then
        local parts=()
        local part
        # 不用改全局/函数 IFS，避免 PROJECTS[*] 拼接异常
        while IFS= read -r -d ',' part || [ -n "$part" ]; do
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            [ -z "$part" ] && continue
            local known found=0
            for known in "${PROJECTS[@]}"; do
                if [ "$known" = "$part" ]; then
                    found=1
                    break
                fi
            done
            if [ "$found" -eq 1 ]; then
                PROJECT_LIST+=("$part")
            else
                err "Unknown project in list: $part"; exit 1
            fi
        done <<< "${token},"
        PROJECT="${PROJECT_LIST[0]:-}"
        return
    fi
    local known found=0
    for known in "${PROJECTS[@]}"; do
        if [ "$known" = "$token" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 1 ]; then
        PROJECT="$token"
        PROJECT_LIST=("$token")
        return
    fi
    err "Unknown project: $token (try --help)"; exit 1
}

for arg in "$@"; do
    case "$arg" in
        financial-web|financial-api|official-site|deepquant-web|deepquant-backend|all|*,*)
            parse_project_token "$arg" ;;
        --ip=*)              SERVER_IP="${arg#--ip=}" ;;
        --no-restart)        NO_RESTART=true ;;
        --rollback)          DO_ROLLBACK=true ;;
        --rollback=*)        DO_ROLLBACK=true; ROLLBACK_VERSION="${arg#--rollback=}" ;;
        --list)              LIST_BACKUPS=true ;;
        --status)            SHOW_STATUS=true ;;
        --logs)              SHOW_LOGS=true ;;
        --logs=*)            SHOW_LOGS=true; LOG_LEVEL="${arg#--logs=}" ;;
        --lines=*)           LOG_LINES="${arg#--lines=}" ;;
        --yes|-y|--ci)        ASSUME_YES=true ;;
        --nginx)             DEPLOY_NGINX=true ;;
        --help|-h)           SHOW_HELP=true ;;
        *) err "Unknown: $arg (try --help)"; exit 1 ;;
    esac
done

if $SHOW_HELP; then
    show_help
    exit 0
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ═══════════════════════════════════════════════════════════════════════
# Pre-flight 检查
# ═══════════════════════════════════════════════════════════════════════

preflight() {
    local errors=0
    banner "Pre-flight 检查"

    if ! require_deploy_secrets; then
        return 1
    fi

    # 1. 磁盘空间（至少 1GB 可用）
    local avail_kb
    avail_kb=$(df -P /www/wwwroot 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 1048576 ]; then
        err "磁盘空间不足：$(df -h /www/wwwroot | awk 'NR==2{print $4}') 可用（需 ≥ 1GB）"
        ((errors++))
    else
        ok "磁盘空间：$(df -h /www/wwwroot | awk 'NR==2{print $4}') 可用"
    fi

    # 2. PostgreSQL 运行中
    if systemctl is-active --quiet bt-postgresql 2>/dev/null || pg_isready -h "$PG_HOST" -U "$PG_USER" >/dev/null 2>&1; then
        ok "PostgreSQL：运行中"
    else
        err "PostgreSQL 未运行或不可连接（bt-postgresql 服务或 pg_isready 检查失败）"
        ((errors++))
    fi

    # 3. Redis 运行中
    if redis-cli -h localhost -p 6379 -a "$REDIS_PASSWORD" ping >/dev/null 2>&1; then
        ok "Redis：运行中"
    else
        err "Redis 未运行或密码不正确"
        ((errors++))
    fi

    # 4. 后端端口未被占用（仅部署后端时检查）
    for port in 5000 5001; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            # 端口被占用 — 如果是已有服务则正常，否则是残留进程
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | grep -oP 'pid=\K[0-9]+' || echo "unknown")
            if systemctl is-active --quiet financial-api 2>/dev/null && [ "$port" = "5001" ]; then
                ok "端口 $port：financial-api 已占用（正常）"
            elif systemctl is-active --quiet quantdinger-backend 2>/dev/null && [ "$port" = "5000" ]; then
                ok "端口 $port：quantdinger-backend 已占用（正常）"
            else
                warn "端口 $port 被进程 $proc 占用但对应服务未运行，重启时可能冲突"
            fi
        else
            ok "端口 $port：空闲"
        fi
    done

    # 5. Python 版本（≥ 3.11）
    local py_ver
    py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    if [ "$py_ver" != "0.0" ]; then
        local py_major py_minor
        py_major=$(echo "$py_ver" | cut -d. -f1)
        py_minor=$(echo "$py_ver" | cut -d. -f2)
        if [ "$py_major" -ge 3 ] && [ "$py_minor" -ge 11 ]; then
            ok "Python 版本：$py_ver"
        else
            err "Python 版本过低：$py_ver（需 ≥ 3.11）"
            ((errors++))
        fi
    else
        warn "无法检测 Python 版本"
    fi

    if [ "$errors" -gt 0 ]; then
        err "Pre-flight 检查失败（$errors 个错误），请修复后重试"
        return 1
    fi
    ok "Pre-flight 检查通过"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# 通用工具
# ═══════════════════════════════════════════════════════════════════════

find_file() {
    local pattern="$1" found
    found=$(ls -t "$PACKAGES_DIR"/$pattern 2>/dev/null | head -1)
    [ -n "$found" ] && [ -f "$found" ] && realpath "$found" || true
}

restart_service() {
    if $NO_RESTART; then warn "跳过重启 (--no-restart)"; return; fi
    local svc="$1"
    log "重启 $svc..."
    systemctl restart "$svc" 2>/dev/null || warn "$svc 重启失败"
    sleep 2
    systemctl is-active "$svc" >/dev/null 2>&1 && ok "$svc 运行中" || warn "$svc 未运行"
}

health_check() {
    local name="$1" url="$2"
    if curl -sf "$url" >/dev/null 2>&1; then ok "$name 健康检查通过"
    else warn "$name 健康检查失败"; fi
}

nginx_reload() {
    if $NO_RESTART; then warn "跳过 Nginx 重载"; return; fi
    nginx -t 2>&1 && nginx -s reload && ok "Nginx 已重载"
}

# ═══════════════════════════════════════════════════════════════════════
# 服务状态总览
# ═══════════════════════════════════════════════════════════════════════

show_status() {
    banner "服务状态总览"
    local services=("financial-api" "financial-crawler" "financial-worker" "financial-streaming" "quantdinger-backend" "nginx")
    printf "  %-22s %-10s %s\n" "SERVICE" "STATUS" "HEALTH"
    hr
    for svc in "${services[@]}"; do
        local status=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
        local color
        [ "$status" = "active" ] && color="$GREEN" || color="$RED"
        local health=""
        case "$svc" in
            financial-api)        health=$(curl -sf http://127.0.0.1:5001/api/health 2>/dev/null | head -c 60 || echo "FAIL") ;;
            quantdinger-backend)  health=$(curl -sf http://127.0.0.1:5000/api/health 2>/dev/null | head -c 60 || echo "FAIL") ;;
            nginx)                health=$(curl -sf http://127.0.0.1/ -o /dev/null -w "%{http_code}" 2>/dev/null || echo "FAIL") ;;
            *)                    health="-" ;;
        esac
        printf "  %-22s ${color}%-10s${NC} %s\n" "$svc" "$status" "$health"
    done
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# 日志查看
# ═══════════════════════════════════════════════════════════════════════

show_logs() {
    local target="${PROJECT:-financial-api}"
    local svc=""

    # 如果没指定项目，交互选择
    if [ -z "$PROJECT" ] && [ -z "$LOG_LEVEL" ]; then
        banner "日志查看"
        echo "  选择查看目标："
        echo "  1) financial-api          实时日志"
        echo "  2) financial-api          最近 50 行"
        echo "  3) financial-api          最近 100 行"
        echo "  4) financial-api          ERROR 级别"
        echo "  5) quantdinger-backend    实时日志"
        echo "  6) quantdinger-backend    最近 50 行"
        echo "  7) quantdinger-backend    最近 100 行"
        echo "  8) quantdinger-backend    ERROR 级别"
        echo "  9) nginx error log        实时日志"
        echo " 10) nginx error log        最近 100 行"
        echo "  0) 返回"
        echo ""
        read -rp "  选择 [0-10]: " choice
        case "$choice" in
            1) svc="financial-api"; LOG_LINES=0 ;;
            2) svc="financial-api"; LOG_LINES=50 ;;
            3) svc="financial-api"; LOG_LINES=100 ;;
            4) svc="financial-api"; LOG_LEVEL="error" ;;
            5) svc="quantdinger-backend"; LOG_LINES=0 ;;
            6) svc="quantdinger-backend"; LOG_LINES=50 ;;
            7) svc="quantdinger-backend"; LOG_LINES=100 ;;
            8) svc="quantdinger-backend"; LOG_LEVEL="error" ;;
            9) tail -f /www/wwwlogs/error.log; return ;;
            10) tail -100 /www/wwwlogs/error.log; return ;;
            0) return ;;
            *) err "无效选择"; return ;;
        esac
    else
        svc="${PROJECT_SERVICE[$target]:-$target}"
    fi

    if [ -n "$LOG_LEVEL" ] && [ "$LOG_LEVEL" = "error" ]; then
        log "查看 $svc ERROR 级别日志（最近 100 行）..."
        journalctl -u "$svc" -n 100 --no-pager -p err 2>/dev/null || \
        journalctl -u "$svc" -n 100 --no-pager | grep -iE 'error|exception|traceback|failed' 2>/dev/null
    elif [ "$LOG_LINES" -gt 0 ]; then
        log "查看 $svc 最近 $LOG_LINES 行日志..."
        journalctl -u "$svc" -n "$LOG_LINES" --no-pager
    else
        log "实时跟踪 $svc 日志（Ctrl+C 退出）..."
        journalctl -u "$svc" -f
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 备份与回滚
# ═══════════════════════════════════════════════════════════════════════
#
# 规则：
# 1. 部署前备份当前线上版本 → backup/<project>/<timestamp>.tar.gz（最多 MAX_BACKUPS）
# 2. 回滚前再次备份当前版本（防止回滚后无法「反悔」）
# 3. 支持：单项目 / 多项目 / all；交互与 CLI；最终确认（可用 --yes 跳过）
# 4. --rollback=latest → 各项目取最新备份；--rollback=TS → 指定时间戳
#

has_backups() {
    local name="$1"
    local backup_dir="$BACKUP_BASE/$name"
    [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir"/*.tar.gz 2>/dev/null || true)" ]
}

latest_backup() {
    local name="$1"
    ls -t "$BACKUP_BASE/$name"/*.tar.gz 2>/dev/null | head -1 || true
}

backup_frontend() {
    local name="$1"
    local dist_dir="$2"
    local backup_dir="$BACKUP_BASE/$name"
    if [ ! -d "$dist_dir" ] || [ -z "$(ls -A "$dist_dir" 2>/dev/null || true)" ]; then
        warn "$name 无需备份（dist/ 为空或不存在）"; return 0
    fi
    mkdir -p "$backup_dir"
    tar czf "$backup_dir/$TIMESTAMP.tar.gz" -C "$(dirname "$dist_dir")" "$(basename "$dist_dir")"
    ok "已备份 $name → $backup_dir/$TIMESTAMP.tar.gz"
    local count
    count=$(ls -1 "$backup_dir"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        ls -t "$backup_dir"/*.tar.gz | tail -n +"$((MAX_BACKUPS + 1))" | xargs -r rm -f
        ok "已清理旧备份（保留 $MAX_BACKUPS 个）"
    fi
}

backup_backend() {
    local name="$1"
    local pkg_dir="$2"
    local backup_dir="$BACKUP_BASE/$name"
    [ ! -d "$pkg_dir" ] && { warn "$name 无需备份（目录不存在）"; return 0; }
    mkdir -p "$backup_dir"
    tar czf "$backup_dir/$TIMESTAMP.tar.gz" -C "$(dirname "$pkg_dir")" \
        --exclude=".env" --exclude=".venv" --exclude="logs" --exclude="data" \
        --exclude="__pycache__" --exclude="*.pyc" --exclude="*.egg-info" \
        "$(basename "$pkg_dir")"
    ok "已备份 $name → $backup_dir/$TIMESTAMP.tar.gz"
    local count
    count=$(ls -1 "$backup_dir"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        ls -t "$backup_dir"/*.tar.gz | tail -n +"$((MAX_BACKUPS + 1))" | xargs -r rm -f
    fi
}

# 列出备份；返回 0=有备份，1=无。不再 exit，便于批量调用。
list_backups() {
    local name="$1"
    local backup_dir="$BACKUP_BASE/$name"
    echo ""
    if ! has_backups "$name"; then
        echo "  $name 无可用备份"
        echo ""
        return 1
    fi
    echo "  ${BOLD}$name${NC} 可用备份（最新优先）："
    hr
    local i=1
    local f
    for f in $(ls -t "$backup_dir"/*.tar.gz 2>/dev/null); do
        local ts size
        ts=$(basename "$f" .tar.gz)
        size=$(du -h "$f" | cut -f1)
        printf "  %2d) %-20s  (%s)\n" "$i" "$ts" "$size"
        i=$((i + 1))
    done
    echo ""
    return 0
}

# 解析某个项目要用的备份路径 → 打印到 stdout；失败 return 1
resolve_rollback_archive() {
    local name="$1"
    local backup_dir="$BACKUP_BASE/$name"
    local archive=""

    if ! has_backups "$name"; then
        err "$name 无可用备份"
        return 1
    fi

    if [ -n "$ROLLBACK_VERSION" ] && [ "$ROLLBACK_VERSION" != "latest" ]; then
        archive="$backup_dir/$ROLLBACK_VERSION.tar.gz"
        if [ ! -f "$archive" ]; then
            err "$name 指定备份不存在: $ROLLBACK_VERSION"
            list_backups "$name" >&2 || true
            return 1
        fi
        printf '%s\n' "$archive"
        return 0
    fi

    if [ "$ROLLBACK_VERSION" = "latest" ] || [ -n "${ROLLBACK_PICK_LATEST:-}" ]; then
        archive=$(latest_backup "$name")
        printf '%s\n' "$archive"
        return 0
    fi

    # 交互选版本（列表打到 stderr，避免污染 $(...) 捕获）
    list_backups "$name" >&2 || return 1
    local backups=() i=0
    local f
    for f in $(ls -t "$backup_dir"/*.tar.gz 2>/dev/null); do
        backups+=("$f")
        i=$((i + 1))
    done
    local choice
    read -rp "  [$name] 选择回滚版本 [1-$i]（回车=1 最新）: " choice
    if [ -z "$choice" ]; then
        choice=1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
        err "无效选择: $choice"
        return 1
    fi
    printf '%s\n' "${backups[$((choice - 1))]}"
    return 0
}

# 执行单个项目回滚（假定 archive 已确认）；失败 return 1，不 exit
apply_rollback_one() {
    local name="$1"
    local archive="$2"
    local target_dir="${PROJECT_DIST[$name]}"
    local ts
    ts=$(basename "$archive" .tar.gz)

    log "回滚 $name → $ts ..."

    # 回滚前备份当前线上版本
    case "$name" in
        financial-web|official-site|deepquant-web) backup_frontend "$name" "$target_dir" ;;
        financial-api|deepquant-backend)            backup_backend "$name" "$target_dir" ;;
    esac

    local parent_dir
    parent_dir=$(dirname "$target_dir")
    rm -rf "$target_dir"
    mkdir -p "$parent_dir"
    if ! tar xzf "$archive" -C "$parent_dir"; then
        err "$name 解压备份失败: $archive"
        return 1
    fi
    ok "$name 已回滚到 $ts"

    # 重启 / 健康检查（DEPLOY_DRY_RUN=1 时跳过）
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        warn "DEPLOY_DRY_RUN=1：跳过服务重启"
        return 0
    fi
    case "$name" in
        financial-web|official-site|deepquant-web) nginx_reload ;;
        financial-api)
            restart_service "financial-api"; restart_service "financial-crawler"
            restart_service "financial-worker"; restart_service "financial-streaming"
            sleep 3; health_check "financial-api" "http://127.0.0.1:5001/api/health" ;;
        deepquant-backend)
            restart_service "quantdinger-backend"
            sleep 3; health_check "QuantDinger" "http://127.0.0.1:5000/api/health" ;;
    esac
    return 0
}

confirm_rollback_plan() {
    local -n _names=$1
    local -n _archives=$2
    echo ""
    hr
    echo -e "  ${BOLD}${YELLOW}即将回滚以下项目（不可轻易撤销，请仔细核对）：${NC}"
    hr
    local i
    for i in "${!_names[@]}"; do
        local n="${_names[$i]}"
        local a="${_archives[$i]}"
        local ts
        ts=$(basename "$a" .tar.gz)
        printf "  • %-20s → %s\n" "$n" "$ts"
        echo -e "      ${DIM}$a${NC}"
    done
    hr
    echo "  说明：回滚前会自动备份当前线上版本到 backup/<项目>/"
    echo ""
    if $ASSUME_YES; then
        warn "已指定 --yes，跳过确认"
        return 0
    fi
    local confirm
    read -rp "  确认执行回滚？请输入 yes 继续: " confirm
    if [ "$confirm" != "yes" ]; then
        warn "已取消回滚"
        return 1
    fi
    return 0
}

# 批量回滚入口：参数为项目名列表
rollback_projects() {
    local projects=("$@")
    [ ${#projects[@]} -eq 0 ] && { err "未指定回滚项目"; return 1; }

    banner "回滚计划（${#projects[@]} 个项目）"

    local names=() archives=()
    local p archive
    for p in "${projects[@]}"; do
        if [ -z "${PROJECT_DIST[$p]:-}" ]; then
            err "未知项目: $p"; return 1
        fi
        archive=$(resolve_rollback_archive "$p") || {
            err "无法为 $p 选择备份，中止整批回滚"
            return 1
        }
        names+=("$p")
        archives+=("$archive")
    done

    confirm_rollback_plan names archives || return 1

    local succeeded=() failed=()
    local i
    for i in "${!names[@]}"; do
        echo ""
        if apply_rollback_one "${names[$i]}" "${archives[$i]}"; then
            succeeded+=("${names[$i]}")
            audit_log "ROLLBACK ${names[$i]} -> $(basename "${archives[$i]}" .tar.gz) by $(whoami)@$(hostname)"
        else
            failed+=("${names[$i]}")
            err "${names[$i]} 回滚失败，继续处理后续项目..."
        fi
    done

    echo ""
    hr
    echo -e "  ${BOLD}回滚结果：${NC}"
    [ ${#succeeded[@]} -gt 0 ] && ok "  成功: ${succeeded[*]}"
    [ ${#failed[@]} -gt 0 ] && err "  失败: ${failed[*]}"
    hr
    [ ${#failed[@]} -eq 0 ]
}

# 兼容旧调用：do_rollback name target_dir
do_rollback() {
    local name="$1"
    rollback_projects "$name"
}

# ═══════════════════════════════════════════════════════════════════════
# 部署函数
# ═══════════════════════════════════════════════════════════════════════

deploy_financial_web() {
    log "部署 financial-web..."
    local tar=$(find_file "financial-web-dist.tar.gz")
    [ -z "$tar" ] && { err "未找到 financial-web-dist.tar.gz"; err "请先本地执行: .\scripts\build.ps1 financial-web"; return 1; }
    backup_frontend "financial-web" "$FINANCIAL_WEB_DIR/dist"
    mkdir -p "$FINANCIAL_WEB_DIR/dist"
    rm -rf "$FINANCIAL_WEB_DIR/dist"/*
    tar xzf "$tar" -C "$FINANCIAL_WEB_DIR/dist"
    ok "financial-web 已部署"; nginx_reload
}

deploy_financial_api() {
    log "部署 financial-api..."
    local tar=$(find_file "financial-api-*.tar.gz")
    [ -z "$tar" ] && { err "未找到 financial-api-*.tar.gz"; err "请先本地执行: .\scripts\build.ps1 financial-api"; return 1; }
    backup_backend "financial-api" "$FINANCIAL_API_DIR/package"
    # 复制 tar 包到部署目录，同时清理旧包
    find "$FINANCIAL_API_DIR" -maxdepth 1 -name 'financial-api-*.tar.gz' -delete 2>/dev/null || true
    cp "$tar" "$FINANCIAL_API_DIR/"
    mkdir -p "$DEPLOY_TMP_DIR/fin-api-extract"
    tar xzf "$tar" -C "$DEPLOY_TMP_DIR/fin-api-extract"
    local DEPLOY_SCRIPT=""
    [ -f "$DEPLOY_TMP_DIR/fin-api-extract/package/deploy-financial-api.sh" ] && DEPLOY_SCRIPT="$DEPLOY_TMP_DIR/fin-api-extract/package/deploy-financial-api.sh"
    [ -z "$DEPLOY_SCRIPT" ] && [ -f "$FINANCIAL_API_DIR/package/deploy-financial-api.sh" ] && DEPLOY_SCRIPT="$FINANCIAL_API_DIR/package/deploy-financial-api.sh"
    if [ -n "$DEPLOY_SCRIPT" ]; then
        local yes_flag=""
        $ASSUME_YES && yes_flag="--yes"
        bash "$DEPLOY_SCRIPT" --web-path=/ --no-restart $yes_flag || warn "deploy-financial-api.sh 有警告"
        ok "financial-api 代码已同步"
    else
        rm -rf "$DEPLOY_TMP_DIR/fin-api-extract"
        err "未找到 deploy-financial-api.sh"; return 1
fi
    rm -rf "$DEPLOY_TMP_DIR/fin-api-extract"
    # 更新 .env
    local env_file="$FINANCIAL_API_DIR/package/.env"
    if [ -f "$env_file" ] && [ -n "$SERVER_IP" ]; then
        log "更新 .env (CORS 追加 $SERVER_IP)..."
        # 追加服务器 IP 到 CORS，保留已有的 localhost 条目
        local current_cors
        current_cors=$(grep '^CORS_ORIGINS=' "$env_file" | head -1 | cut -d= -f2-)
        if echo "$current_cors" | grep -q "$SERVER_IP"; then
            ok "CORS 已包含 $SERVER_IP，跳过"
        else
            # 追加 IP 到已有 CORS（保留域名等已有 origin），不覆盖
            local new_cors="${current_cors},http://${SERVER_IP}"
            sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=${new_cors}|" "$env_file"
            ok "CORS 已追加 $SERVER_IP（保留已有 origin）"
        fi
        sed -i "s|^AUTH_UPSTREAM_URL=.*|AUTH_UPSTREAM_URL=http://127.0.0.1:5000|" "$env_file"
        # 确保 ARQ_REDIS_URL 带密码（从 REDIS_URL 提取密码，避免 arq 连接认证失败）
        local redis_pass
        redis_pass=$(grep '^REDIS_URL=' "$env_file" | head -1 | sed -n 's|.*://:\([^@]*\)@.*|\1|p')
        if [ -n "$redis_pass" ]; then
            local current_arq
            current_arq=$(grep '^ARQ_REDIS_URL=' "$env_file" | head -1 | cut -d= -f2-)
            local expected_arq="redis://:${redis_pass}@localhost:6379/1"
            if [ "$current_arq" != "$expected_arq" ]; then
                if grep -q '^ARQ_REDIS_URL=' "$env_file"; then
                    sed -i "s|^ARQ_REDIS_URL=.*|ARQ_REDIS_URL=${expected_arq}|" "$env_file"
                else
                    echo "ARQ_REDIS_URL=${expected_arq}" >> "$env_file"
                fi
                ok "ARQ_REDIS_URL 已修正（带密码，DB /1）"
            fi
        fi
        ok ".env 已更新"
    fi
    if ! $NO_RESTART; then
        restart_service "financial-api"; restart_service "financial-crawler"
        restart_service "financial-worker"; restart_service "financial-streaming"
        sleep 3; health_check "financial-api" "http://127.0.0.1:5001/api/health"
    fi
}

deploy_official_site() {
    log "部署 official-site..."
    local tar=$(find_file "official-site-dist.tar.gz")
    [ -z "$tar" ] && { err "未找到 official-site-dist.tar.gz"; err "请先本地执行: .\scripts\build.ps1 official-site"; return 1; }
    backup_frontend "official-site" "$OFFICIAL_SITE_DIR/dist"
    mkdir -p "$OFFICIAL_SITE_DIR/dist"
    rm -rf "$OFFICIAL_SITE_DIR/dist"/*
    tar xzf "$tar" -C "$OFFICIAL_SITE_DIR/dist"
    ok "official-site 已部署"; nginx_reload
}

deploy_deepquant_web() {
    log "部署 QuantDinger 前端..."
    local tar=$(find_file "deepquant-web-dist.tar.gz")
    [ -z "$tar" ] && { err "未找到 deepquant-web-dist.tar.gz"; err "请先本地执行: .\scripts\build.ps1 deepquant-web"; return 1; }
    backup_frontend "deepquant-web" "$DEEPQUANT_WEB_DIR/dist"
    mkdir -p "$DEEPQUANT_WEB_DIR/dist"
    rm -rf "$DEEPQUANT_WEB_DIR/dist"/*
    tar xzf "$tar" -C "$DEEPQUANT_WEB_DIR/dist"
    ok "QuantDinger 前端已部署"; nginx_reload
}

deploy_deepquant_backend() {
    log "部署 QuantDinger 后端..."
    local tar=$(find_file "deepquant-backend-package.tar.gz")
    [ -z "$tar" ] && { err "未找到 deepquant-backend-package.tar.gz"; err "请先本地执行: .\scripts\build.ps1 deepquant-backend"; return 1; }
    local pkg_dir="$DEEPQUANT_BACKEND_DIR/package" venv_dir="$pkg_dir/.venv" env_file="$pkg_dir/.env"
    backup_backend "deepquant-backend" "$pkg_dir"
    mkdir -p "$pkg_dir"
    # 备份 .env
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    # 清理旧代码（保留 .env/.venv/logs/data）
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    # 虚拟环境
    if [ ! -d "$venv_dir" ]; then
        log "创建虚拟环境..."
        python3 -m venv "$venv_dir"
        "$venv_dir/bin/pip" install --upgrade pip -q
    fi
    log "安装依赖..."
    "$venv_dir/bin/pip" install -r "$pkg_dir/requirements.txt" -q 2>&1 | tail -3
    # 恢复 .env（增量部署时保留已有配置）
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    # ── 首次部署：从模板生成 .env ──
    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/deepquant.env.example" \
                 "$DIST_ROOT/configs/deepquant.env.example" \
                 "$(dirname "$0")/configs/deepquant.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            local secret_key admin_pw
            secret_key=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || echo "CHANGE_ME_SECRET_KEY")
            admin_pw="${ADMIN_PASSWORD:-}"
            if [ -z "$admin_pw" ] || [ "$admin_pw" = "CHANGE_ME" ]; then
                admin_pw=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))" 2>/dev/null || echo "ChangeMeNow")
                warn "ADMIN_PASSWORD 未在 deploy.env 配置，已随机生成（请登录后修改）"
            fi
            local server_ip="${SERVER_IP:-127.0.0.1}"
            local frontend_url="${FRONTEND_URL:-http://${server_ip}}"
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SECRET_KEY__|${secret_key}|g" \
                -e "s|__ADMIN_PASSWORD__|${admin_pw}|g" \
                -e "s|__SERVER_IP__|${server_ip}|g" \
                -e "s|__FRONTEND_URL__|${frontend_url}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 deepquant.env.example 模板"
            warn "请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    # ── 首次部署：安装 systemd 服务 ──
    local svc_file="/etc/systemd/system/quantdinger-backend.service"
    if [ ! -f "$svc_file" ]; then
        log "首次部署：安装 quantdinger-backend.service..."
        local svc_template=""
        for t in "$CONFIGS_SRC/quantdinger-backend.service" \
                 "$DIST_ROOT/configs/quantdinger-backend.service" \
                 "$(dirname "$0")/configs/quantdinger-backend.service"; do
            [ -f "$t" ] && svc_template="$t" && break
        done
        if [ -n "$svc_template" ]; then
            cp "$svc_template" "$svc_file"
            systemctl daemon-reload
            systemctl enable quantdinger-backend
            ok "quantdinger-backend.service 已安装并启用"
        else
            warn "未找到 quantdinger-backend.service 模板"
        fi
    else
        ok "quantdinger-backend.service 已存在"
    fi

    mkdir -p "$pkg_dir/logs" "$pkg_dir/data/memory"
    # FRONTEND_URL: keep original domain value, do not override with IP
    if [ -n "$SERVER_IP" ]; then ok ".env FRONTEND_URL preserved"; fi
    if ! $NO_RESTART; then
        restart_service "quantdinger-backend"
        sleep 3; health_check "QuantDinger" "http://127.0.0.1:5000/api/health"
    fi
}

# 部署调度
deploy_one() {
    local p="$1"
    case "$p" in
        financial-web)      deploy_financial_web ;;
        financial-api)      deploy_financial_api ;;
        official-site)      deploy_official_site ;;
        deepquant-web)      deploy_deepquant_web ;;
        deepquant-backend)  deploy_deepquant_backend ;;
        *) err "未知项目: $p"; return 1 ;;
    esac
}

# 按依赖关系排序部署列表：前端 → 后端
sort_deploy_order() {
    local frontends=() backends=()
    for p in "$@"; do
        case "$p" in
            financial-web|official-site|deepquant-web) frontends+=("$p") ;;
            financial-api|deepquant-backend)          backends+=("$p") ;;
        esac
    done
    echo "${frontends[@]} ${backends[@]}"
}

# 批量部署（容错：单个失败不中断后续）
deploy_batch() {
    local projects=($@)
    local succeeded=() failed=()
    for p in "${projects[@]}"; do
        echo ""
        if deploy_one "$p"; then
            succeeded+=("$p")
        else
            failed+=("$p")
            err "$p 部署失败，继续部署下一个..."
        fi
    done
    echo ""
    hr
    echo "  ${BOLD}部署结果：${NC}"
    [ ${#succeeded[@]} -gt 0 ] && ok "  成功: ${succeeded[*]}"
    [ ${#failed[@]} -gt 0 ] && err "  失败: ${failed[*]}"
    [ ${#failed[@]} -gt 0 ] && warn "  失败的项目已保留备份，可用 --rollback 回滚"
    hr
    return ${#failed[@]}
}

# ═══════════════════════════════════════════════════════════════════════
# 交互式主菜单
# ═══════════════════════════════════════════════════════════════════════

interactive_menu() {
    # 首次进入时显示帮助信息
    local first_run=true
    while true; do
        if $first_run; then
            echo ""
            echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
            echo -e "  ${BOLD}部署管理工具${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
            show_help
            first_run=false
        fi
        banner "部署管理工具"
        echo "  ${BOLD}1)${NC} 部署项目（选择一个或多个）"
        echo "  ${BOLD}2)${NC} 全量部署（5 个项目）"
        echo "  ${BOLD}3)${NC} 回滚（单项目 / 多选 / 全部）"
        echo "  ${BOLD}4)${NC} 查看备份列表"
        echo "  ${BOLD}5)${NC} 查看服务状态"
        echo "  ${BOLD}6)${NC} 查看日志"
        echo "  ${BOLD}7)${NC} Pre-flight 检查"
        echo "  ${BOLD}8)${NC} 查看部署日志"
        echo "  ${BOLD}0)${NC} 退出"
        echo ""
        read -rp "  选择 [0-8]: " main_choice
        case "$main_choice" in
            1) interactive_deploy ;;
            2) PROJECT="all"; deploy_all ;;
            3) interactive_rollback ;;
            4) interactive_list_backups ;;
            5) show_status ;;
            6) PROJECT=""; show_logs ;;
            7) preflight ;;
            8) tail -30 "$DEPLOY_LOG" 2>/dev/null || warn "无部署日志" ;;
            0) echo "Bye!"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
        echo ""
    done
}

interactive_deploy() {
    banner "选择要部署的项目"
    echo "  输入编号，空格分隔多选（如: 1 3 5），或 a 全选："
    echo ""
    local i=1
    for p in "${PROJECTS[@]}"; do
        echo "  ${BOLD}$i)${NC} $p  ${DIM}${PROJECT_NAMES[$p]}${NC}"
        ((i++))
    done
    echo "  ${BOLD}a)${NC} 全选"
    echo ""
    read -rp "  选择: " choices

    local selected=()
    if [ "$choices" = "a" ]; then
        selected=("${PROJECTS[@]}")
    else
        for c in $choices; do
            if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#PROJECTS[@]} ]; then
                selected+=("${PROJECTS[$((c-1))]}")
            else
                warn "忽略无效选择: $c"
            fi
        done
    fi

    [ ${#selected[@]} -eq 0 ] && { warn "未选择任何项目"; return; }

    # 询问 ServerIP
    read -rp "  服务器 IP（可选，留空跳过 CORS 更新）: " ip
    [ -n "$ip" ] && SERVER_IP="$ip"

    echo ""
    hr
    echo "  即将部署: ${BOLD}${selected[*]}${NC}"
    [ -n "$SERVER_IP" ] && echo "  CORS IP:  $SERVER_IP"
    hr
    read -rp "  确认部署？[y/N]: " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { warn "已取消"; return; }

    if ! preflight; then return; fi
    # 按依赖排序：前端 → 后端
    local sorted
    sorted=$(sort_deploy_order "${selected[@]}")
    audit_log "DEPLOY ${selected[*]} by $(whoami)@$(hostname) IP=${SERVER_IP:-N/A}"
    deploy_batch $sorted || true
    deploy_summary "${selected[@]}"
    audit_log "DEPLOY ${selected[*]} done"
}

deploy_all() {
    read -rp "  服务器 IP（可选）: " ip
    [ -n "$ip" ] && SERVER_IP="$ip"
    echo ""
    hr
    echo "  即将全量部署 5 个项目"
    [ -n "$SERVER_IP" ] && echo "  CORS IP:  $SERVER_IP"
    hr
    read -rp "  确认？[y/N]: " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { warn "已取消"; return; }

    if ! preflight; then return; fi
    audit_log "DEPLOY all by $(whoami)@$(hostname) IP=${SERVER_IP:-N/A}"
    # 统一用 deploy_batch 部署（固定顺序：前端 → 后端）
    deploy_batch "${PROJECTS[@]}" || true
    deploy_summary "${PROJECTS[@]}"
    audit_log "DEPLOY all done"
}

interactive_rollback() {
    banner "选择要回滚的项目"
    echo "  输入编号，空格分隔多选（如: 1 3），或 a 全部回滚："
    echo ""
    local i=1
    for p in "${PROJECTS[@]}"; do
        local mark="无备份"
        has_backups "$p" && mark="有备份"
        echo "  ${BOLD}$i)${NC} $p  ${DIM}${PROJECT_NAMES[$p]}${NC}  [$mark]"
        i=$((i + 1))
    done
    echo "  ${BOLD}a)${NC} 全部（仅回滚「有备份」的项目）"
    echo ""
    read -rp "  选择: " choices

    local selected=()
    if [ "$choices" = "a" ] || [ "$choices" = "A" ]; then
        for p in "${PROJECTS[@]}"; do
            if has_backups "$p"; then
                selected+=("$p")
            else
                warn "跳过 $p（无备份）"
            fi
        done
    else
        local c
        for c in $choices; do
            if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#PROJECTS[@]} ]; then
                local p="${PROJECTS[$((c - 1))]}"
                if has_backups "$p"; then
                    selected+=("$p")
                else
                    warn "跳过 $p（无备份）"
                fi
            else
                warn "忽略无效选择: $c"
            fi
        done
    fi

    [ ${#selected[@]} -eq 0 ] && { warn "没有可回滚的项目"; return; }

    echo ""
    echo "  版本选择方式："
    echo "  1) 每个项目交互选择备份（默认）"
    echo "  2) 全部使用各自最新备份"
    read -rp "  选择 [1/2]: " mode
    if [ "$mode" = "2" ]; then
        ROLLBACK_VERSION="latest"
    else
        ROLLBACK_VERSION=""
    fi

    rollback_projects "${selected[@]}"
}

interactive_list_backups() {
    banner "备份列表"
    local any=false
    for p in "${PROJECTS[@]}"; do
        if has_backups "$p"; then
            any=true
            echo "  ${BOLD}$p${NC} (${PROJECT_NAMES[$p]}):"
            local f
            for f in $(ls -t "$BACKUP_BASE/$p"/*.tar.gz 2>/dev/null); do
                local ts size
                ts=$(basename "$f" .tar.gz)
                size=$(du -h "$f" | cut -f1)
                echo "    $ts  ($size)"
            done
            echo ""
        fi
    done
    $any || warn "当前没有任何项目备份"
}

deploy_summary() {
    local deployed=("$@")
    echo ""
    ok "═══════════════════════════════════════════════════════════"
    ok "  部署完成！"
    ok "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  已部署项目: ${BOLD}${deployed[*]}${NC}"
    echo "  备份位置:   $BACKUP_BASE/"
    echo "  回滚命令:"
    echo "    bash deploy.sh <project> --rollback"
    echo "    bash deploy.sh proj1,proj2 --rollback=latest"
    echo "    bash deploy.sh all --rollback"
    echo ""
    if [ -n "$SERVER_IP" ]; then
        echo "  访问地址（IP: $SERVER_IP）："
        for p in "${deployed[@]}"; do
            case "$p" in
                financial-web)      echo "    http://$SERVER_IP/" ;;
                financial-api)      echo "    http://$SERVER_IP/api/health" ;;
                official-site)      echo "    http://$SERVER_IP/qd/" ;;
                deepquant-web)      echo "    http://$SERVER_IP/quant/" ;;
                deepquant-backend)  echo "    http://$SERVER_IP/quant/api/health" ;;
            esac
        done
        echo ""
    fi
    echo "  查看日志："
    for p in "${deployed[@]}"; do
        case "$p" in
            financial-api)      echo "    journalctl -u financial-api -f" ;;
            deepquant-backend)  echo "    journalctl -u quantdinger-backend -f" ;;
            *)                  echo "    tail -f /www/wwwlogs/error.log" ;;
        esac
    done
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Nginx 配置
# ═══════════════════════════════════════════════════════════════════════

deploy_nginx() {
    log "配置 Nginx..."
    # NGINX_CONF_NAME 可通过 deploy.env 或环境变量指定（如 nginx-servera-ssl.conf）
    local conf_name="${NGINX_CONF_NAME:-nginx-all-sites.conf}"
    local conf_src=""
    for f in "$CONFIGS_SRC/$conf_name" \
             "$DIST_ROOT/configs/$conf_name" \
             "$(dirname "$0")/configs/$conf_name" \
             "$CONFIGS_SRC/nginx-all-sites.conf" \
             "$DIST_ROOT/configs/nginx-all-sites.conf" \
             "$(dirname "$0")/configs/nginx-all-sites.conf"; do
        [ -f "$f" ] && conf_src="$f" && break
    done
    [ -z "$conf_src" ] && { warn "未找到 Nginx 配置文件，跳过"; return 1; }

    local nginx_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        log "DRY RUN: 将拷贝 $conf_src → $nginx_target"
        return 0
    fi

    # 备份当前配置
    [ -f "$nginx_target" ] && cp "$nginx_target" "${nginx_target}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    # 渲染占位符（__DOMAIN__ / __WWW_DOMAIN__ / __APP_NAME__）后拷贝
    if grep -q '__DOMAIN__\|__WWW_DOMAIN__\|__APP_NAME__' "$conf_src" 2>/dev/null; then
        sed -e "s|__WWW_DOMAIN__|${WWW_DOMAIN}|g" \
            -e "s|__DOMAIN__|${DOMAIN}|g" \
            -e "s|__APP_NAME__|${APP_NAME}|g" \
            "$conf_src" > "$nginx_target"
        ok "Nginx 配置已渲染域名占位符"
    else
        cp "$conf_src" "$nginx_target"
    fi
    if nginx -t 2>&1; then
        nginx -s reload
        ok "Nginx 配置已更新并重载"
    else
        warn "Nginx 配置测试失败，请手动检查 $nginx_target"
        warn "可回滚: cp ${nginx_target}.bak.* $nginx_target && nginx -s reload"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════════════

needs_deploy_lock() {
    # 只读操作不加锁
    if $SHOW_HELP || $SHOW_STATUS || $SHOW_LOGS || $LIST_BACKUPS; then
        return 1
    fi
    return 0
}

acquire_deploy_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        err "另一个 deploy 进程正在运行（锁文件: $LOCK_FILE）"
        err "如确认无并发部署，删除锁文件后重试：rm $LOCK_FILE"
        exit 1
    fi
}

# 命令行只读模式（无锁）
if $SHOW_STATUS; then show_status; exit 0; fi
if $SHOW_LOGS; then show_logs; exit 0; fi
if $LIST_BACKUPS; then
    if [ ${#PROJECT_LIST[@]} -gt 0 ]; then
        for p in "${PROJECT_LIST[@]}"; do list_backups "$p" || true; done
    elif [ -n "$PROJECT" ] && [ "$PROJECT" != "all" ]; then
        list_backups "$PROJECT" || true
    else
        interactive_list_backups
    fi
    exit 0
fi

# 部署 / 回滚需要锁
acquire_deploy_lock

# 部署前：若已部署则提示（避免误当首次）
_detect_already_deployed() {
    local n=0
    for svc in financial-api quantdinger-backend; do
        systemctl is-active --quiet "$svc" 2>/dev/null && n=$((n + 1))
    done
    [ "$n" -gt 0 ]
}

if [ ${#PROJECT_LIST[@]} -gt 0 ] || [ -n "$PROJECT" ]; then
    # 规范化 PROJECT_LIST
    if [ ${#PROJECT_LIST[@]} -eq 0 ] && [ -n "$PROJECT" ]; then
        if [ "$PROJECT" = "all" ]; then
            PROJECT_LIST=("${PROJECTS[@]}")
        else
            PROJECT_LIST=("$PROJECT")
        fi
    fi

    if $DO_ROLLBACK; then
        # all / 多项目 / 单项目 统一走 rollback_projects + 确认
        local_targets=()
        if [ "$PROJECT" = "all" ]; then
            for p in "${PROJECTS[@]}"; do
                if has_backups "$p"; then
                    local_targets+=("$p")
                else
                    warn "跳过 $p（无备份）"
                fi
            done
        else
            local_targets=("${PROJECT_LIST[@]}")
        fi
        [ ${#local_targets[@]} -eq 0 ] && { err "没有可回滚的项目"; exit 1; }
        audit_log "ROLLBACK ${local_targets[*]} by $(whoami)@$(hostname) ver=${ROLLBACK_VERSION:-interactive}"
        rollback_projects "${local_targets[@]}" || exit 1
        audit_log "ROLLBACK ${local_targets[*]} done"
        exit 0
    fi

    # 已部署判定
    if _detect_already_deployed; then
        warn "检测到服务已在运行（非首次部署）"
        if [ -f "$(dirname "$0")/detect-status.sh" ]; then
            bash "$(dirname "$0")/detect-status.sh" 2>/dev/null | sed -n '/Phase6/p;/Phase7/p;/验证/p;/判定/p;/下一步/p' || true
        fi
        echo "  继续将：备份当前版本 → 覆盖代码 → 重启服务"
        if ! $ASSUME_YES; then
            read -rp "  确认继续部署？输入 yes: " _c
            [ "$_c" = "yes" ] || { warn "已取消"; exit 0; }
        fi
    fi

    # 部署 — 先跑 pre-flight
    if ! preflight; then exit 1; fi
    audit_log "DEPLOY ${PROJECT_LIST[*]:-$PROJECT} by $(whoami)@$(hostname) IP=${SERVER_IP:-N/A}"
    banner "部署: ${PROJECT_LIST[*]:-$PROJECT}"
    if [ "$PROJECT" = "all" ] || [ ${#PROJECT_LIST[@]} -gt 1 ]; then
        to_deploy=("${PROJECT_LIST[@]}")
        [ "$PROJECT" = "all" ] && to_deploy=("${PROJECTS[@]}")
        deploy_batch "${to_deploy[@]}" || true
        deploy_summary "${to_deploy[@]}"
    else
        deploy_one "${PROJECT_LIST[0]}" || { err "${PROJECT_LIST[0]} 部署失败"; exit 1; }
        deploy_summary "${PROJECT_LIST[0]}"
    fi
    audit_log "DEPLOY ${PROJECT_LIST[*]:-$PROJECT} done"
    if $DEPLOY_NGINX; then
        deploy_nginx
    fi
    exit 0
fi

# --nginx 单独执行（无项目参数）
if $DEPLOY_NGINX; then
    deploy_nginx
    exit 0
fi

# 无参数 → 交互式菜单
interactive_menu
