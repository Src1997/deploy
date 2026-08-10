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
#   financial-api       FastAPI 后端 (Python)
#   official-site       卓筹介绍站
#   deepquant-web       QuantDinger 前端
#   deepquant-backend   QuantDinger 后端 (Python)
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
    --target=server-a   使用 deploy.env.server-a 配置（服务器 A）
    --target=server-b   使用 deploy.env.server-b 配置（服务器 B）
    --nginx             部署后自动配置 Nginx（拷贝配置并 reload）
    --nginx --dynamic   动态生成 Nginx 配置（从 projects.json 生成 location 块）
    --sync-nginx        从 projects.json 重新生成 Nginx 配置并 reload
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
    bash deploy.sh all --yes --target=server-a --ip=47.86.32.234
HELP
}

# ── 路径常量（可用环境变量 / deploy.env 覆盖，便于 WSL 沙箱）────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pre-scan for --target= to set DEPLOY_TARGET before env loading
for _pre_arg in "$@"; do
    case "$_pre_arg" in
        --target=*) export DEPLOY_TARGET="${_pre_arg#--target=}" ;;
    esac
done

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
        # Determine env file suffix based on DEPLOY_TARGET
        local suffix=""
        case "${DEPLOY_TARGET:-}" in
            server-a) suffix=".server-a" ;;
            server-b) suffix=".server-b" ;;
            "")       suffix="" ;;
            *)        suffix=".$DEPLOY_TARGET" ;;
        esac
        local env_name="deploy.env${suffix}"
        local f
        for f in "${DEPLOY_ENV_FILE:-}" \
                 "$SCRIPT_DIR/../${env_name}" \
                 "$SCRIPT_DIR/${env_name}" \
                 "$(pwd)/${env_name}" \
                 "${HOME}/deploy-sandbox/${env_name}" \
                 "/www/wwwroot/project/${env_name}" \
                 "$SCRIPT_DIR/../deploy.env" \
                 "$SCRIPT_DIR/deploy.env" \
                 "$(pwd)/deploy.env" \
                 "${HOME}/deploy-sandbox/deploy.env" \
                 "/www/wwwroot/project/deploy.env"; do
            [ -n "$f" ] && [ -f "$f" ] || continue
            local _dry_run="${DEPLOY_DRY_RUN:-}"
            set -a
            # shellcheck disable=SC1090
            source "$f"
            set +a
            [ -n "$_dry_run" ] && DEPLOY_DRY_RUN="$_dry_run"
            break
        done
    }
    _load_optional_env
    require_deploy_secrets() {
        if [ -z "${PG_PASSWORD:-}" ] || [ "${PG_PASSWORD}" = "CHANGE_ME" ]; then
            err "请配置 deploy.env（PG_PASSWORD），参见 deploy.env.example"
            return 1
        fi
        if [ "${REDIS_PASSWORD:-}" = "CHANGE_ME" ]; then
            err "REDIS_PASSWORD 仍为 CHANGE_ME，请修改 deploy.env（无密码则留空）"
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

# 项目列表（路径/产物/服务均用 loader 的 DEPLOY_PATH / ARTIFACT_NAME / …）
declare -a PROJECTS=($PROJECT_IDS)
# 日志菜单用：每个后端的「主」服务名（services 列表第一个）
declare -A PROJECT_SERVICE=()
for p in "${PROJECTS[@]}"; do
    _svcs="${SERVICES[$p]:-}"
    PROJECT_SERVICE[$p]="${_svcs%% *}"
done

is_known_project() {
    local token="$1" known
    [ "$token" = "all" ] && return 0
    [[ "$token" == *","* ]] && return 0
    for known in "${PROJECTS[@]}"; do
        [ "$known" = "$token" ] && return 0
    done
    return 1
}

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
SYNC_NGINX=false
ASSUME_YES=false
LOG_LINES=50
LOG_LEVEL=""
DEPLOY_NGINX=false
NGINX_DYNAMIC=false

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
    --target=*)         DEPLOY_TARGET="${arg#--target=}"; export DEPLOY_TARGET ;;
    --nginx)             DEPLOY_NGINX=true ;;
    --dynamic)           NGINX_DYNAMIC=true ;;
    --sync-nginx)        SYNC_NGINX=true ;;
    --help|-h)           SHOW_HELP=true ;;
        -*)
            err "Unknown: $arg (try --help)"; exit 1 ;;
        *)
            if is_known_project "$arg"; then
                parse_project_token "$arg"
            else
                err "Unknown: $arg (try --help)"; exit 1
            fi
            ;;
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

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        warn "DEPLOY_DRY_RUN=1：跳过密钥与系统检查"
        return 0
    fi

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

    # 3. Redis 运行中（REDIS_PASSWORD 可为空——部分服务器 Redis 无密码）
    local redis_args=(-h "${REDIS_HOST:-localhost}" -p "${REDIS_PORT:-6379}")
    if [ -n "${REDIS_PASSWORD:-}" ]; then
        redis_args+=(-a "$REDIS_PASSWORD")
    fi
    if redis-cli "${redis_args[@]}" ping >/dev/null 2>&1; then
        ok "Redis：运行中"
    else
        err "Redis 未运行或密码不正确"
        ((errors++))
    fi

    # 4. 后端端口检查（从 healthUrl 动态提取端口）
    local checked_ports=""
    for p in "${PROJECTS[@]}"; do
        local url="${HEALTH_URL[$p]:-}"
        [ -z "$url" ] && continue
        local port
        port=$(echo "$url" | sed -n 's|.*://[^:]*:\([0-9]*\).*|\1|p')
        [ -z "$port" ] && continue
        # 避免重复检查同一端口
        echo "$checked_ports" | grep -qw "$port" && continue
        checked_ports="$checked_ports $port"
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            # 端口被占用 — 检查是否是对应服务
            local primary_svc="${SERVICES[$p]:-}"
            primary_svc="${primary_svc%% *}"
            if [ -n "$primary_svc" ] && systemctl is-active --quiet "$primary_svc" 2>/dev/null; then
                ok "端口 $port：$primary_svc 已占用（正常）"
            else
                local proc
                proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | grep -oP 'pid=\K[0-9]+' || echo "unknown")
                warn "端口 $port 被进程 $proc 占用但 $primary_svc 未运行，重启时可能冲突"
            fi
        else
            ok "端口 $port：空闲"
        fi
    done

    # 5. Python 版本（≥ 3.11）
    local py_ver
    py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    if [ "$py_ver" != "0.0" ]; then
        local py_major py_mino
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
    # 从 projects.json 动态收集服务列表
    local -a services=()
    local -A seen=()
    for p in "${PROJECTS[@]}"; do
        local svcs="${SERVICES[$p]:-}"
        for svc in $svcs; do
            [ -n "$svc" ] && [ -z "${seen[$svc]:-}" ] && services+=("$svc") && seen[$svc]=1
        done
    done
    services+=("nginx")

    printf "  %-22s %-10s %s\n" "SERVICE" "STATUS" "HEALTH"
    hr
    for svc in "${services[@]}"; do
        local status=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
        local color
        [ "$status" = "active" ] && color="$GREEN" || color="$RED"
        local health=""
        # 查找此服务所属项目的 healthUrl
        for p in "${PROJECTS[@]}"; do
            if echo "${SERVICES[$p]:-}" | grep -qw "$svc"; then
                local hurl="${HEALTH_URL[$p]:-}"
                if [ -n "$hurl" ]; then
                    health=$(curl -sf "$hurl" 2>/dev/null | head -c 60 || echo "FAIL")
                fi
                break
            fi
        done
        # nginx 特殊处理
        [ "$svc" = "nginx" ] && health=$(curl -sf http://127.0.0.1/ -o /dev/null -w "%{http_code}" 2>/dev/null || echo "FAIL")
        [ -z "$health" ] && health="-"
        printf "  %-22s ${color}%-10s${NC} %s\n" "$svc" "$status" "$health"
    done
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# 日志查看
# ═══════════════════════════════════════════════════════════════════════

show_logs() {
    local target="${PROJECT:-}"
    local svc=""

    # 如果没指定项目，交互选择
    if [ -z "$target" ] && [ -z "$LOG_LEVEL" ]; then
        banner "日志查看"
        echo "  选择查看目标："
        local menu_idx=1
        declare -a menu_items=()

        # 从 projects.json 动态生成菜单：每个有服务的项目 3 项
        for p in "${PROJECTS[@]}"; do
            local p_svc="${PROJECT_SERVICE[$p]:-}"
            [ -z "$p_svc" ] && continue
            local p_name="${PROJECT_DISPLAY_NAME[$p]:-$p}"
            echo "  ${menu_idx}) $p_svc    实时日志          ($p_name)"
            menu_items+=("$p_svc:0")
            ((menu_idx++))
            echo "  ${menu_idx}) $p_svc    最近 50 行"
            menu_items+=("$p_svc:50")
            ((menu_idx++))
            echo "  ${menu_idx}) $p_svc    ERROR 级别"
            menu_items+=("$p_svc:error")
            ((menu_idx++))
        done

        # Nginx 选项
        echo "  ${menu_idx}) nginx error log    实时日志"
        menu_items+=("nginx:rt")
        ((menu_idx++))
        echo "  ${menu_idx}) nginx error log    最近 100 行"
        menu_items+=("nginx:100")
        ((menu_idx++))

        echo "  0) 返回"
        echo ""
        local total=${#menu_items[@]}
        read -rp "  选择 [0-${total}]: " choice

        if [ "$choice" = "0" ] || [ -z "$choice" ]; then return; fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
            err "无效选择"; return
        fi

        local selection="${menu_items[$((choice-1))]}"
        local sel_svc="${selection%%:*}"
        local sel_mode="${selection##*:}"

        if [ "$sel_svc" = "nginx" ]; then
            if [ "$sel_mode" = "rt" ]; then
                tail -f /www/wwwlogs/error.log
            else
                tail -100 /www/wwwlogs/error.log
            fi
            return
        fi

        svc="$sel_svc"
        if [ "$sel_mode" = "error" ]; then
            LOG_LEVEL="error"
        elif [ "$sel_mode" = "0" ]; then
            LOG_LINES=0
        else
            LOG_LINES="$sel_mode"
        fi
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
    local target_dir="${DEPLOY_PATH[$name]}"
    local ts
    ts=$(basename "$archive" .tar.gz)

    log "回滚 $name → $ts ..."

    # 回滚前备份当前线上版本
    case "${PROJECT_KIND[$name]}" in
        frontend) backup_frontend "$name" "$target_dir" ;;
        backend)  backup_backend "$name" "$target_dir" ;;
        *)        backup_frontend "$name" "$target_dir" ;;
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
    if [ "${NGINX_RELOAD[$name]}" = "true" ]; then
        nginx_reload
    fi
    local svc
    for svc in ${SERVICES[$name]}; do
        [ -n "$svc" ] && restart_service "$svc"
    done
    if [ -n "${HEALTH_URL[$name]:-}" ]; then
        sleep 3
        health_check "$name" "${HEALTH_URL[$name]}"
    fi
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
        if [ -z "${DEPLOY_PATH[$p]:-}" ]; then
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

# 兼容旧调用：do_rollback name target_di
do_rollback() {
    local name="$1"
    rollback_projects "$name"
}

# ═══════════════════════════════════════════════════════════════════════
# 部署函数（路径 / 产物 / 服务均来自 projects.json）
# ═══════════════════════════════════════════════════════════════════════

# 从 projects.json 自动生成 Nginx 配置（调用 generate-nginx.py）
sync_nginx() {
    local gen_script="$DIST_ROOT/scripts/generate-nginx.py"
    [ ! -f "$gen_script" ] && gen_script="$PROJECT_BASE/uploads/dist/scripts/generate-nginx.py"
    [ ! -f "$gen_script" ] && { err "generate-nginx.py not found"; return 1; }

    local conf_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"

    # Derive SSL mode: NGINX_MODE takes priority, then NGINX_CONF_NAME (consistent with deploy_nginx)
    local mode="${NGINX_MODE:-}"
    if [ -z "$mode" ]; then
        local conf_name="${NGINX_CONF_NAME:-}"
        case "$conf_name" in
            *servera-ssl*)   mode="ssl-redirect" ;;
            *all-sites-ssl*) mode="ssl-combined" ;;
            *)               mode="http" ;;
        esac
    fi

    local domain="${DOMAIN:-}"
    local www_domain="${WWW_DOMAIN:-}"

    # SSL mode requires domain — fall back to http if missing
    if [ "$mode" != "http" ] && { [ -z "$domain" ] || [ -z "$www_domain" ]; }; then
        warn "SSL 模式 ($mode) 需要 DOMAIN 和 WWW_DOMAIN，回退到 http 模式"
        mode="http"
    fi

    banner "Sync Nginx config"
    log "Mode: $mode | Target: $conf_target"

    # Backup current config
    [ -f "$conf_target" ] && cp "$conf_target" "${conf_target}.bak.$(date +%Y%m%d-%H%M%S)"

    # Build args
    local py_args=()
    py_args+=(--mode "$mode")
    py_args+=(--project-base "$PROJECT_BASE")
    [ -n "$domain" ] && py_args+=(--domain "$domain")
    [ -n "$www_domain" ] && py_args+=(--www-domain "$www_domain")
    py_args+=(--output "$conf_target")

    if ! python3 "$gen_script" "${py_args[@]}"; then
        err "Failed to generate Nginx config"
        return 1
    fi
    ok "Nginx config generated"

    if ! nginx -t 2>&1; then
        err "Nginx config test failed — restoring backup"
        cp "${conf_target}.bak."* "$conf_target" 2>/dev/null
        return 1
    fi
    ok "Nginx config valid"

    nginx -s reload
    ok "Nginx reloaded"
    return 0
}

# Check if Nginx config already contains a project's location path
nginx_has_location() {
    local id="$1"
    local conf_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"
    local public_url="${PUBLIC_URL[$id]:-}"

    # Root project — check for "root.*dist" line
    if [ "${PROJECT_ROOT[$id]:-false}" = "true" ]; then
        local deploy_path="${DEPLOY_PATH[$id]:-}"
        grep -q "root.*${deploy_path}" "$conf_target" 2>/dev/null && return 0 || return 1
    fi

    # Sub-path project — check for location ^~ <public_url>
    [ -z "$public_url" ] && return 0
    grep -q "location.*${public_url}" "$conf_target" 2>/dev/null && return 0 || return 1
}

# 通用：按清单部署前端（解压到 DEPLOY_PATH[id]）
deploy_frontend_by_id() {
    local id="$1"
    local target="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"

    [ -z "$target" ] && { err "projects.json 缺少 $id.deployPath"; return 1; }
    [ -z "$tar_pat" ] && { err "projects.json 缺少 $id.build.artifact"; return 1; }

    log "部署 $id ($label)..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $target (artifact=$tar_pat)"
        return 0
    fi
    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 $id"; return 1; }
    backup_frontend "$id" "$target"
    rm -rf "${target:?}"
    mkdir -p "$target"
    if ! tar xzf "$tar" -C "$target"; then
        err "$id 解压失败: $tar"
        return 1
    fi
    # Verify extraction completeness
    local tar_files extracted_files
    tar_files=$(tar tzf "$tar" 2>/dev/null | grep -c -v '/$' || echo 0)
    extracted_files=$(find "$target" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$extracted_files" -lt "$tar_files" ]; then
        warn "$id 解压可能不完整: tar=$tar_files extracted=$extracted_files"
    fi
    ok "$id 已部署到 $target"
    # Auto-sync Nginx if project's location is missing from config
    if ! nginx_has_location "$id"; then
        warn "$id Nginx location not found in config — running sync-nginx"
        sync_nginx || warn "sync-nginx failed, continuing"
    fi
    if [ "${NGINX_RELOAD[$id]}" = "true" ]; then
        nginx_reload
    fi
}

# financial-api：清单路径 + 既有钩子 / CORS / 多服务重启
deploy_financial_api() {
    local id="financial-api"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local api_parent
    api_parent="$(dirname "$pkg_dir")"
    local tar_pat="${ARTIFACT_NAME[$id]:-financial-api-*.tar.gz}"

    log "部署 financial-api → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] financial-api → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-})"
        return 0
    fi
    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 financial-api"; return 1; }
    backup_backend "financial-api" "$pkg_dir"
    # 复制 tar 包到部署父目录，同时清理旧包
    find "$api_parent" -maxdepth 1 -name 'financial-api-*.tar.gz' -delete 2>/dev/null || true
    mkdir -p "$api_parent"
    cp "$tar" "$api_parent/"
    mkdir -p "$DEPLOY_TMP_DIR/fin-api-extract"
    tar xzf "$tar" -C "$DEPLOY_TMP_DIR/fin-api-extract"
    local DEPLOY_SCRIPT=""
    # 优先：归档内保留的 scripts/ 层次；兼容旧包：package/ 根下拍扁脚本
    for cand in \
        "$DEPLOY_TMP_DIR/fin-api-extract/scripts/deploy-financial-api.sh" \
        "$DEPLOY_TMP_DIR/fin-api-extract/package/scripts/deploy-financial-api.sh" \
        "$DEPLOY_TMP_DIR/fin-api-extract/package/deploy-financial-api.sh" \
        "$pkg_dir/scripts/deploy-financial-api.sh" \
        "$pkg_dir/deploy-financial-api.sh"; do
        [ -f "$cand" ] && DEPLOY_SCRIPT="$cand" && break
    done
    # 若清单指定 deployHook 且包内无脚本，尝试 dist/scripts 下的钩子
    if [ -z "$DEPLOY_SCRIPT" ] && [ -n "${DEPLOY_HOOK[$id]:-}" ]; then
        local hook_rel="${DEPLOY_HOOK[$id]}"
        for cand in "$DIST_ROOT/$hook_rel" "$SCRIPT_DIR_DEPLOY/../$hook_rel" "$SCRIPT_DIR/$hook_rel"; do
            [ -f "$cand" ] && DEPLOY_SCRIPT="$cand" && break
        done
    fi
    if [ -n "$DEPLOY_SCRIPT" ]; then
        local yes_flag=""
        $ASSUME_YES && yes_flag="--yes"
        # 路径注入钩子，避免钩子内硬编码 PROJECT_BASE/.../financial-api
        DEPLOY_ROOT="$api_parent" PKG_DIR="$pkg_dir" \
            bash "$DEPLOY_SCRIPT" --web-path=/ --no-restart $yes_flag || warn "deploy-financial-api.sh 有警告"
        ok "financial-api 代码已同步"
    else
        rm -rf "$DEPLOY_TMP_DIR/fin-api-extract"
        err "未找到 deploy-financial-api.sh"; return 1
    fi
    rm -rf "$DEPLOY_TMP_DIR/fin-api-extract"
    # 更新 .env
    local env_file="$pkg_dir/.env"
    if [ -f "$env_file" ] && [ -n "$SERVER_IP" ]; then
        log "更新 .env (CORS 追加 $SERVER_IP)..."
        local current_cors
        current_cors=$(grep '^CORS_ORIGINS=' "$env_file" | head -1 | cut -d= -f2-)
        if echo "$current_cors" | grep -q "$SERVER_IP"; then
            ok "CORS 已包含 $SERVER_IP，跳过"
        else
            local new_cors="${current_cors},http://${SERVER_IP}"
            sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=${new_cors}|" "$env_file"
            ok "CORS 已追加 $SERVER_IP（保留已有 origin）"
        fi
        sed -i "s|^AUTH_UPSTREAM_URL=.*|AUTH_UPSTREAM_URL=http://127.0.0.1:5000|" "$env_file"
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
        local svc
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "financial-api" "${HEALTH_URL[$id]}"
        fi
    fi
}

deploy_deepquant_backend() {
    local id="deepquant-backend"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-deepquant-backend-package.tar.gz}"
    local venv_dir="$pkg_dir/.venv" env_file="$pkg_dir/.env"

    log "部署 QuantDinger 后端 → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] deepquant-backend → $pkg_dir (artifact=$tar_pat)"
        return 0
    fi
    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 deepquant-backend"; return 1; }
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
for t in "$CONFIGS_SRC/systemd/quantdinger-backend.service" \
"$DIST_ROOT/configs/systemd/quantdinger-backend.service" \
"$CONFIGS_SRC/quantdinger-backend.service" \
"$(dirname "$0")/configs/systemd/quantdinger-backend.service" \
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

    # ── MCP Server：安装 mcp_server 包 + systemd 服务 ──
    local mcp_src_dir="$pkg_dir/mcp_server"
    if [ -d "$mcp_src_dir" ] && [ -f "$mcp_src_dir/pyproject.toml" ]; then
        log "安装 MCP Server 依赖到 venv..."
        # 清理可能存在的旧版 mcp 2.x（与 quantdinger-mcp 不兼容）
        "$venv_dir/bin/pip" uninstall mcp mcp-types -y -q 2>/dev/null || true
        "$venv_dir/bin/pip" install "$mcp_src_dir" -q 2>&1 | tail -3
        ok "quantdinger-mcp 包已安装到 venv"

        # 安装 systemd 服务
        local mcp_svc_file="/etc/systemd/system/quantdinger-mcp.service"
        local mcp_svc_template=""
        for t in "$CONFIGS_SRC/systemd/quantdinger-mcp.service" \
"$DIST_ROOT/configs/systemd/quantdinger-mcp.service" \
"$CONFIGS_SRC/quantdinger-mcp.service" \
"$(dirname "$0")/configs/systemd/quantdinger-mcp.service" \
"$(dirname "$0")/configs/quantdinger-mcp.service"; do
            [ -f "$t" ] && mcp_svc_template="$t" && break
        done
        if [ -n "$mcp_svc_template" ]; then
            # 渲染 AGENT_TOKEN 占位符
            local mcp_token="${MCP_AGENT_TOKEN:-}"
            if [ -z "$mcp_token" ]; then
                warn "MCP_AGENT_TOKEN 未在 deploy.env 配置，MCP 服务可能无法正常启动"
                mcp_token="CHANGE_ME_MCP_TOKEN"
            fi
            sed "s|__MCP_AGENT_TOKEN__|${mcp_token}|g" \
                "$mcp_svc_template" > "$mcp_svc_file"
            systemctl daemon-reload
            systemctl enable quantdinger-mcp 2>/dev/null || true
            ok "quantdinger-mcp.service 已安装并启用"
        else
            warn "未找到 quantdinger-mcp.service 模板，跳过 MCP 服务安装"
        fi
    else
        warn "mcp_server 目录不存在或缺少 pyproject.toml，跳过 MCP 安装"
    fi

    mkdir -p "$pkg_dir/logs" "$pkg_dir/data/memory"
    if [ -n "$SERVER_IP" ]; then ok ".env FRONTEND_URL preserved"; fi
    if ! $NO_RESTART; then
        local svc
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "QuantDinger" "${HEALTH_URL[$id]}"
        fi
        # MCP 健康检查
        if systemctl is-active quantdinger-mcp >/dev/null 2>&1; then
            ok "quantdinger-mcp 运行中 (port 7800)"
        else
            warn "quantdinger-mcp 未运行，请检查日志: journalctl -u quantdinger-mcp -f"
        fi
    fi
}

# 通用 Python 后端部署函数：无专用函数的 Python 项目走此路径
# 支持 deployHook（优先）和默认流程（venv + pip + systemd）
deploy_python() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local venv_dir="$pkg_dir/.venv" env_file="$pkg_dir/.env"

    log "部署 $id ($label) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    # If deployHook is set, use it (similar to financial-api flow)
    if [ -n "${DEPLOY_HOOK[$id]:-}" ]; then
        local tar
        tar=$(find_file "$tar_pat")
        [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 $id"; return 1; }
        backup_backend "$id" "$pkg_dir"
        local api_parent
        api_parent="$(dirname "$pkg_dir")"
        find "$api_parent" -maxdepth 1 -name "${id}-*.tar.gz" -delete 2>/dev/null || true
        mkdir -p "$api_parent"
        cp "$tar" "$api_parent/"
        mkdir -p "$DEPLOY_TMP_DIR/${id}-extract"
        tar xzf "$tar" -C "$DEPLOY_TMP_DIR/${id}-extract"
        local DEPLOY_SCRIPT=""
        local hook_rel="${DEPLOY_HOOK[$id]}"
        for cand in "$DEPLOY_TMP_DIR/${id}-extract/scripts/$(basename "$hook_rel")" \
                    "$DEPLOY_TMP_DIR/${id}-extract/package/scripts/$(basename "$hook_rel")" \
                    "$DIST_ROOT/$hook_rel" \
                    "$SCRIPT_DIR_DEPLOY/../$hook_rel" \
                    "$SCRIPT_DIR/$hook_rel"; do
            [ -f "$cand" ] && DEPLOY_SCRIPT="$cand" && break
        done
        if [ -n "$DEPLOY_SCRIPT" ]; then
            local yes_flag=""
            $ASSUME_YES && yes_flag="--yes"
            DEPLOY_ROOT="$api_parent" PKG_DIR="$pkg_dir" \
                bash "$DEPLOY_SCRIPT" --no-restart $yes_flag || warn "$hook_rel 有警告"
            ok "$id 代码已同步（via deployHook）"
        else
            rm -rf "$DEPLOY_TMP_DIR/${id}-extract"
            err "未找到 deployHook: $hook_rel"; return 1
        fi
        rm -rf "$DEPLOY_TMP_DIR/${id}-extract"
    else
        # Default flow: extract + venv + pip + systemd
        local tar
        tar=$(find_file "$tar_pat")
        [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 $id"; return 1; }
        backup_backend "$id" "$pkg_dir"
        mkdir -p "$pkg_dir"
        [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
        # Clean old code (preserve .env, .venv, logs, data)
        find "$pkg_dir" -mindepth 1 -maxdepth 1 \
            ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
            -exec rm -rf {} + 2>/dev/null || true
        tar xzf "$tar" -C "$pkg_dir"
        ok "代码已解压"
        [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

        # Create venv if needed
        if [ ! -d "$venv_dir" ]; then
            log "创建虚拟环境..."
            python3 -m venv "$venv_dir"
            "$venv_dir/bin/pip" install --upgrade pip -q
        fi

        # Install dependencies (detect requirements.txt or pyproject.toml)
        log "安装依赖..."
        if [ -f "$pkg_dir/requirements.txt" ]; then
            "$venv_dir/bin/pip" install -r "$pkg_dir/requirements.txt" -q 2>&1 | tail -3
        elif [ -f "$pkg_dir/pyproject.toml" ]; then
            (cd "$pkg_dir" && "$venv_dir/bin/pip" install -e "." -q 2>&1 | tail -3)
        else
            warn "未找到 requirements.txt 或 pyproject.toml，跳过依赖安装"
        fi

        # Generate .env from template if first deploy
        if [ ! -f "$env_file" ]; then
            log "首次部署：从模板生成 .env..."
            local template=""
            for t in "$CONFIGS_SRC/${id}.env.example" \
                     "$DIST_ROOT/configs/${id}.env.example" \
                     "$(dirname "$0")/configs/${id}.env.example"; do
                [ -f "$t" ] && template="$t" && break
            done
            if [ -n "$template" ]; then
                sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                    -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                    -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                    -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                    "$template" > "$env_file"
                chmod 600 "$env_file"
                ok ".env 已生成（从模板 $template）"
            else
                warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
            fi
        else
            ok ".env 已存在，保留"
        fi

        # Install systemd services if first deploy
        local svc
        for svc in ${SERVICES[$id]}; do
            [ -z "$svc" ] && continue
            local svc_file="/etc/systemd/system/${svc}.service"
            if [ ! -f "$svc_file" ]; then
                log "首次部署：安装 ${svc}.service..."
                local svc_template=""
                for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                         "$DIST_ROOT/configs/systemd/${svc}.service" \
                         "$CONFIGS_SRC/${svc}.service" \
                         "$(dirname "$0")/configs/systemd/${svc}.service"; do
                    [ -f "$t" ] && svc_template="$t" && break
                done
                if [ -n "$svc_template" ]; then
                    cp "$svc_template" "$svc_file"
                    systemctl daemon-reload
                    systemctl enable "$svc"
                    ok "${svc}.service 已安装并启用"
                else
                    warn "未找到 ${svc}.service 模板"
                fi
            else
                ok "${svc}.service 已存在"
            fi
        done

        mkdir -p "$pkg_dir/logs"
    fi

    # Restart services + health check
    if ! $NO_RESTART; then
        local svc
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# Java 后端部署：JAR/WAR + systemd
# 打包格式：JAR/WAR + configs/ + .env → tar.gz
deploy_java() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Java) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 $id"; return 1; }
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    # Clean old code (preserve .env, logs, data)
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    # Generate .env from template if first deploy
    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/${id}.env.example" \
                 "$DIST_ROOT/configs/${id}.env.example" \
                 "$(dirname "$0")/configs/${id}.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    # Install systemd services if first deploy
    local svc
    for svc in ${SERVICES[$id]}; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        if [ ! -f "$svc_file" ]; then
            log "首次部署：安装 ${svc}.service..."
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                cp "$svc_template" "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc"
                ok "${svc}.service 已安装并启用"
            else
                warn "未找到 ${svc}.service 模板"
            fi
        else
            ok "${svc}.service 已存在"
        fi
    done

    mkdir -p "$pkg_dir/logs"

    # Restart services + health check
    if ! $NO_RESTART; then
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# Go 后端部署：二进制 + systemd
deploy_go() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Go) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 $id"; return 1; }
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    # Ensure binary is executable
    local bin_file=""
    for f in "$pkg_dir"/bin/* "$pkg_dir"/*.bin "$pkg_dir"/main; do
        [ -f "$f" ] && chmod +x "$f" && bin_file="$f" && break
    done
    [ -n "$bin_file" ] && ok "可执行文件: $bin_file" || warn "未找到二进制文件，请检查包结构"

    # Generate .env from template if first deploy
    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/${id}.env.example" \
                 "$DIST_ROOT/configs/${id}.env.example" \
                 "$(dirname "$0")/configs/${id}.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    # Install systemd services if first deploy
    local svc
    for svc in ${SERVICES[$id]}; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        if [ ! -f "$svc_file" ]; then
            log "首次部署：安装 ${svc}.service..."
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                cp "$svc_template" "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc"
                ok "${svc}.service 已安装并启用"
            else
                warn "未找到 ${svc}.service 模板"
            fi
        else
            ok "${svc}.service 已存在"
        fi
    done

    mkdir -p "$pkg_dir/logs"

    if ! $NO_RESTART; then
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# Node.js 后端部署：源码 + npm ci + systemd
deploy_nodejs() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Node.js) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: .\\scripts\\build.ps1 $id"; return 1; }
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'node_modules' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    # Install production dependencies
    if [ -f "$pkg_dir/package.json" ]; then
        log "安装生产依赖 (npm ci --production)..."
        (cd "$pkg_dir" && npm ci --production 2>&1 | tail -5) || {
            warn "npm ci 失败，尝试 npm install --production"
            (cd "$pkg_dir" && npm install --production 2>&1 | tail -5) || warn "npm install 也失败"
        }
    else
        warn "未找到 package.json，跳过依赖安装"
    fi

    # Generate .env from template if first deploy
    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/${id}.env.example" \
                 "$DIST_ROOT/configs/${id}.env.example" \
                 "$(dirname "$0")/configs/${id}.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    # Install systemd services if first deploy
    local svc
    for svc in ${SERVICES[$id]}; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        if [ ! -f "$svc_file" ]; then
            log "首次部署：安装 ${svc}.service..."
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                cp "$svc_template" "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc"
                ok "${svc}.service 已安装并启用"
            else
                warn "未找到 ${svc}.service 模板"
            fi
        else
            ok "${svc}.service 已存在"
        fi
    done

    mkdir -p "$pkg_dir/logs"

    if ! $NO_RESTART; then
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# 通用入口：前端走清单解压；Python 后端保留专用逻辑或走通用部署
deploy_by_id() {
    local id="$1"
    if [ -z "${DEPLOY_PATH[$id]:-}" ]; then
        err "未知项目或不在 projects.json: $id"
        return 1
    fi
    case "${PROJECT_KIND[$id]}" in
        frontend)
            deploy_frontend_by_id "$id"
            ;;
        python)
            case "$id" in
                financial-api)     deploy_financial_api ;;
                deepquant-backend) deploy_deepquant_backend ;;
                *)
                    # 通用 Python 部署：支持 deployHook 或默认流程
                    deploy_python "$id"
                    ;;
            esac
            ;;
        java)
            deploy_java "$id"
            ;;
        go)
            deploy_go "$id"
            ;;
        nodejs)
            deploy_nodejs "$id"
            ;;
        *)
            err "未知 kind: ${PROJECT_KIND[$id]:-?} ($id)"
            return 1
            ;;
    esac
}

# 兼容旧函数名
deploy_financial_web() { deploy_frontend_by_id financial-web; }
deploy_official_site()  { deploy_frontend_by_id official-site; }
deploy_deepquant_web()  { deploy_frontend_by_id deepquant-web; }

# 部署调度
deploy_one() {
    local p="$1"
    deploy_by_id "$p"
}

# 按清单 kind 排序：前端 → Python 后端 → 编译型 → 脚本型
sort_deploy_order() {
    local frontends=() backends=() compiled=() scripted=() other=()
    local p
    for p in "$@"; do
        case "${PROJECT_KIND[$p]}" in
            frontend)        frontends+=("$p") ;;
            python)        backends+=("$p") ;;
            java|go)         compiled+=("$p") ;;
            nodejs)          scripted+=("$p") ;;
            *)               other+=("$p") ;;
        esac
    done
    echo "${frontends[@]} ${backends[@]} ${compiled[@]} ${scripted[@]} ${other[@]}"
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
        echo "  ${BOLD}2)${NC} 全量部署（${#PROJECTS[@]} 个项目）"
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
        echo "  ${BOLD}$i)${NC} $p  ${DIM}${PROJECT_DISPLAY_NAME[$p]}${NC}"
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
    echo "  即将全量部署 ${#PROJECTS[@]} 个项目"
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
        echo "  ${BOLD}$i)${NC} $p  ${DIM}${PROJECT_DISPLAY_NAME[$p]}${NC}  [$mark]"
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
            echo "  ${BOLD}$p${NC} (${PROJECT_DISPLAY_NAME[$p]}):"
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
            local url=""
            # 优先用 publicUrl，其次从 healthUrl 提取路径
            if [ -n "${PUBLIC_URL[$p]:-}" ]; then
                url="http://$SERVER_IP${PUBLIC_URL[$p]}"
            elif [ -n "${HEALTH_URL[$p]:-}" ]; then
                # 从 healthUrl 提取路径部分（如 http://127.0.0.1:5001/api/health → /api/health）
                local path="${HEALTH_URL[$p]}"
                path=$(echo "$path" | sed 's|.*://[^/]*||')
                url="http://$SERVER_IP$path"
            fi
            [ -n "$url" ] && echo "    $p → $url"
        done
        echo ""
    fi
    echo "  查看日志："
    for p in "${deployed[@]}"; do
        local primary_svc="${SERVICES[$p]:-}"
        primary_svc="${primary_svc%% *}"
        if [ -n "$primary_svc" ]; then
            echo "    journalctl -u $primary_svc -f"
        else
            echo "    tail -f /www/wwwlogs/error.log"
        fi
    done
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Nginx 配置
# ═══════════════════════════════════════════════════════════════════════

deploy_nginx() {
    log "配置 Nginx..."
    local nginx_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"

    # ── 优先：从 projects.json 动态生成 ──
    # 查找顺序与 sync_nginx 保持一致：服务器上 build.ps1 把 generate-nginx.py
    # 复制到 dist/scripts/（即 DIST_ROOT/scripts/），优先匹配，避免回退到文件模式。
    local gen_script="$DIST_ROOT/scripts/generate-nginx.py"
    [ ! -f "$gen_script" ] && gen_script="$PROJECT_BASE/uploads/dist/scripts/generate-nginx.py"
    [ ! -f "$gen_script" ] && gen_script="$(dirname "$0")/generate-nginx.py"
    [ ! -f "$gen_script" ] && gen_script="$SCRIPT_DIR/generate-nginx.py"
    if [ -f "$gen_script" ]; then
        # 根据 NGINX_CONF_NAME 确定 SSL 模式（向后兼容）
        local mode="http"
        local conf_name="${NGINX_CONF_NAME:-}"
        case "$conf_name" in
            *servera-ssl*)   mode="ssl-redirect" ;;
            *all-sites-ssl*) mode="ssl-combined" ;;
            *)               mode="http" ;;
        esac

        local gen_args=("--mode" "$mode" "--project-base" "$PROJECT_BASE")
        if [ -n "$DOMAIN" ] && [ -n "$WWW_DOMAIN" ]; then
            gen_args+=("--domain" "$DOMAIN" "--www-domain" "$WWW_DOMAIN")
        elif [ "$mode" != "http" ]; then
            warn "SSL 模式需要 DOMAIN 和 WWW_DOMAIN，回退到 http 模式"
            gen_args=("--mode" "http" "--project-base" "$PROJECT_BASE")
        fi

        if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
            log "DRY RUN: 将动态生成 Nginx 配置 (mode=$mode)"
            python3 "$gen_script" "${gen_args[@]}" | head -20
            log "... (仅显示前 20 行)"
            return 0
        fi

        # 备份当前配置
        [ -f "$nginx_target" ] && cp "$nginx_target" "${nginx_target}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

        # 生成配置
        python3 "$gen_script" "${gen_args[@]}" --output "$nginx_target"
        ok "Nginx 配置已动态生成 (mode=$mode)"

        if nginx -t 2>&1; then
            nginx -s reload
            ok "Nginx 配置已更新并重载"
        else
            warn "Nginx 配置测试失败，请手动检查 $nginx_target"
            warn "可回滚: cp ${nginx_target}.bak.* $nginx_target && nginx -s reload"
        fi
        return
    fi

    # ── 回退：文件模式（预写配置文件）──
    warn "generate-nginx.py 未找到，回退到文件模式"
    local conf_name="${NGINX_CONF_NAME:-nginx-all-sites.conf}"
    local conf_src=""
    for f in "$CONFIGS_SRC/$conf_name" \
             "$DIST_ROOT/configs/$conf_name" \
             "$(dirname "$0")/configs/$conf_name"; do
        [ -f "$f" ] && conf_src="$f" && break
    done
    [ -z "$conf_src" ] && { warn "未找到 Nginx 配置文件，跳过"; return 1; }

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        log "DRY RUN: 将拷贝 $conf_src → $nginx_target"
        return 0
    fi

    [ -f "$nginx_target" ] && cp "$nginx_target" "${nginx_target}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    cp "$conf_src" "$nginx_target"
    if nginx -t 2>&1; then
        nginx -s reload
        ok "Nginx 配置已更新并重载"
    else
        warn "Nginx 配置测试失败，请手动检查 $nginx_target"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════════════

needs_deploy_lock() {
    # 只读操作不加锁
    if $SHOW_HELP || $SHOW_STATUS || $SHOW_LOGS || $LIST_BACKUPS || $SYNC_NGINX; then
        return 1
    fi
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        return 1
    fi
    return 0
}

acquire_deploy_lock() {
    if ! needs_deploy_lock; then
        return 0
    fi
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
if $SYNC_NGINX; then sync_nginx; exit $?; fi
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
