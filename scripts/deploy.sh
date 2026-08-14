#!/usr/bin/env bash
# -- CRLF self-fix: Windows-edited scripts may carry \r, strip and re-exec --
if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
    sed -i 's/\r$//' "${BASH_SOURCE[0]}"
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

# ============================================================================
# deploy.sh - Universal deploy/rollback/log tool (server-side)
#
# 项目列表从 TOML 配置自动加载（config_loader.py），无需在脚本中硬编码。
# 新增项目只需在 project-configs/ 下添加 project.toml，零脚本修改。
#
# 用法：
#   bash deploy.sh                      # 交互式主菜单
#   bash deploy.sh <component> [options]  # 命令行直接执行
#   bash deploy.sh <group> [options]      # 按项目组部署（如 financial, deepquant）
#   bash deploy.sh all [options]          # 全量部署
#   bash deploy.sh --status             # 查看所有服务状态
#   bash deploy.sh --logs [component]   # 查看日志
#
# 选项：
#   --ip=SERVER_IP      设置服务器 IP（更新 CORS）
#   --target=server-a   指定环境配置（加载 deploy.env.server-a）
#   --no-restart        部署但不重启服务
#   --rollback          交互选择备份回滚（可单项目 / 多选 / all）
#   --rollback=TS|latest 回滚到指定时间戳，或各项目最新备份
#   --yes|-y|--ci       非交互模式：跳过所有确认提示（部署 + 回滚）
#   --list              列出可用备份
#   --status            查看服务状态
#   --logs [component]  查看日志
#   --help              帮助
#
# 支持的组件类型：frontend | python | java | go | nodejs
# Python 部署自动支持：deployHook、venv + pip、MCP 自动检测、.env 模板渲染、
#                       systemd 服务安装、venvShared 共享 venv 模式
#
# 架构说明：
#   本文件是主入口，仅包含：帮助、参数解析、环境加载、交互菜单、主入口逻辑。
#   所有功能函数已拆分到 lib/ 下的模块文件中：
#     lib/common.sh          — 颜色、日志、CRLF 修复、新鲜度检查
#     lib/preflight.sh        — 部署前检查
#     lib/service-ops.sh      — 服务重启、健康检查、状态总览、日志查看
#     lib/backup-rollback.sh  — 备份与回滚
#     lib/nginx.sh            — Nginx 配置生成与部署
#     lib/deploy-kinds.sh     — 各类型部署函数（frontend/python/java/go/nodejs）
#     lib/deploy-dispatch.sh — 部署调度（排序/批量/汇总）
#     lib/interactive.sh     — 交互式菜单
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── 路径常量 ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 加载共享库 ────────────────────────────────────────────────────────
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# -- Script freshness check (after common.sh provides the function) --
_check_script_freshness || true

# Pre-scan for --target= to set DEPLOY_TARGET before env loading
for _pre_arg in "$@"; do
    case "$_pre_arg" in
        --target=*) export DEPLOY_TARGET="${_pre_arg#--target=}" ;;
    esac
done

# ── 加载环境配置 ──────────────────────────────────────────────────────
# shellcheck source=lib/load-deploy-env.sh
source "$SCRIPT_DIR/lib/load-deploy-env.sh"
load_deploy_env "$SCRIPT_DIR" || true

# ── 路径与配置常量 ────────────────────────────────────────────────────
PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
PACKAGES_DIR="${PACKAGES_DIR:-$PROJECT_BASE/uploads/dist/packages}"
[ ! -d "$PACKAGES_DIR" ] && PACKAGES_DIR="$PROJECT_BASE/uploads/dist"
DIST_ROOT="${DIST_ROOT:-$PROJECT_BASE/uploads/dist}"
CONFIGS_SRC="${CONFIGS_SRC:-$DIST_ROOT/configs}"

BACKUP_BASE="${BACKUP_BASE:-$PROJECT_BASE/backup}"
MAX_BACKUPS="${MAX_BACKUPS:-7}"
PG_USER="${PG_USER:-root}"
PG_PASSWORD="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-127.0.0.1}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
FRONTEND_URL="${FRONTEND_URL:-}"
DOMAIN="${DOMAIN:-}"
WWW_DOMAIN="${WWW_DOMAIN:-}"
APP_NAME="${APP_NAME:-MyApp}"

# ── 审计日志 ──────────────────────────────────────────────────────────
DEPLOY_LOG="${DEPLOY_LOG:-$PROJECT_BASE/uploads/deploy.log}"
DEPLOY_TMP_DIR="${DEPLOY_TMP_DIR:-/tmp/fin-deploy}"
mkdir -p "$DEPLOY_TMP_DIR"
LOCK_FILE="${LOCK_FILE:-$DEPLOY_TMP_DIR/deploy.lock}"

audit_log() {
    local msg="$*"
    mkdir -p "$(dirname "$DEPLOY_LOG")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$DEPLOY_LOG"
}

# ── 加载项目清单 ──────────────────────────────────────────────────────
SCRIPT_DIR_DEPLOY="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR_DEPLOY/lib/load-projects.sh" ]; then
    source "$SCRIPT_DIR_DEPLOY/lib/load-projects.sh"
elif [ -f "$DIST_ROOT/lib/load-projects.sh" ]; then
    source "$DIST_ROOT/lib/load-projects.sh"
else
    echo "[ERR] load-projects.sh not found" >&2
    exit 1
fi

declare -a PROJECTS=($PROJECT_IDS)
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

# ── 加载功能模块 ──────────────────────────────────────────────────────
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/service-ops.sh
source "$SCRIPT_DIR/lib/service-ops.sh"
# shellcheck source=lib/backup-rollback.sh
source "$SCRIPT_DIR/lib/backup-rollback.sh"
# shellcheck source=lib/nginx.sh
source "$SCRIPT_DIR/lib/nginx.sh"
# shellcheck source=lib/deploy-kinds.sh
source "$SCRIPT_DIR/lib/deploy-kinds.sh"
# shellcheck source=lib/deploy-dispatch.sh
source "$SCRIPT_DIR/lib/deploy-dispatch.sh"
# shellcheck source=lib/interactive.sh
source "$SCRIPT_DIR/lib/interactive.sh"

# ═══════════════════════════════════════════════════════════════════════
# 帮助
# ═══════════════════════════════════════════════════════════════════════

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
    --logs [component]  查看日志（默认第一个 Python 组件）
    --lines=N           日志行数（默认 50，0=实时跟踪）
    --logs=error        只看 ERROR 级别日志
    --target=<name>     使用 deploy.env.<name> 配置（如 server-a、server-b、vm）
    --nginx             部署后自动配置 Nginx（拷贝配置并 reload）
    --nginx --dynamic   动态生成 Nginx 配置（从 TOML 配置生成 location 块）
    --sync-nginx        从 TOML 配置重新生成 Nginx 配置并 reload
    --sync-scripts      从 dist/ 同步最新部署脚本到当前目录（修复脚本过期）
    --help              显示此帮助

  环境变量：
    PKG_STALE_DAYS=N    包过期阈值天数（默认 7，超过则警告包可能过期）

  新鲜度检查：
    - 启动时检查 dist/.scripts-version 与当前 deploy.sh 修改时间
    - 部署前检查 tar.gz 内 VERSION 文件，显示版本并检测过期包
    - 使用 --sync-scripts 从 dist/ 同步最新脚本

  备份与回滚说明：
    - 每次部署前自动备份到 $PROJECT_BASE/backup/<项目>/，保留最近 7 份
    - 回滚前会再备份「当前线上版本」，避免回滚后无法还原
    - 单项目 / 多项目 / all 回滚均会列出目标并要求确认（除非 --yes）

  非交互 / CI/CD 部署示例：
    bash deploy.sh <component> --yes --ip=<SERVER_IP>
    bash deploy.sh <comp1>,<comp2> --yes
    bash deploy.sh all --yes --ip=<SERVER_IP>
    bash deploy.sh <component> --rollback=latest --yes
    bash deploy.sh all --yes --target=<server-a|server-b|vm> --ip=<SERVER_IP>
HELP
}

# ═══════════════════════════════════════════════════════════════════════
# 参数解析
# ═══════════════════════════════════════════════════════════════════════

PROJECT=""
PROJECT_LIST=()
SERVER_IP=""
NO_RESTART=false
DO_ROLLBACK=false
ROLLBACK_VERSION=""
LIST_BACKUPS=false
SHOW_STATUS=false
SHOW_LOGS=false
SHOW_HELP=false
SYNC_NGINX=false
SYNC_SCRIPTS=false
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
        --yes|-y|--ci)       ASSUME_YES=true ;;
        --target=*)          DEPLOY_TARGET="${arg#--target=}"; export DEPLOY_TARGET ;;
        --nginx)             DEPLOY_NGINX=true ;;
        --dynamic)           NGINX_DYNAMIC=true ;;
        --sync-nginx)        SYNC_NGINX=true ;;
        --sync-scripts)      SYNC_SCRIPTS=true ;;
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

# -- --sync-scripts: copy latest scripts from dist/ to current script dir --
if $SYNC_SCRIPTS; then
    _sync_scripts() {
        local script_dir dist_dir src
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        for dist_dir in "$script_dir" "$script_dir/.." \
                        "${PROJECT_BASE:-/www/wwwroot/project}/uploads/dist"; do
            [ -f "$dist_dir/.scripts-version" ] && break
        done
        if [ ! -f "$dist_dir/.scripts-version" ]; then
            echo "[ERR] .scripts-version not found in any expected location" >&2
            exit 1
        fi
        echo "[*] Syncing scripts from $dist_dir/ to $script_dir/ ..."
        local files=(deploy.sh detect-status.sh deploy-financial-api.sh generate-nginx.py)
        for f in "${files[@]}"; do
            if [ -f "$dist_dir/$f" ]; then
                cp "$dist_dir/$f" "$script_dir/$f"
                echo "[OK] Copied: $f"
            fi
        done
        if [ -d "$dist_dir/lib" ]; then
            mkdir -p "$script_dir/lib"
            cp -r "$dist_dir/lib/"* "$script_dir/lib/" 2>/dev/null || true
            echo "[OK] Copied: lib/"
        fi
        echo "[OK] Script sync complete. Re-run your deploy command."
        exit 0
    }
    _sync_scripts
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ═══════════════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════════════

needs_deploy_lock() {
    if $SHOW_HELP || $SHOW_STATUS || $SHOW_LOGS || $LIST_BACKUPS || $SYNC_NGINX || $SYNC_SCRIPTS; then
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
    local id
    for id in $PROJECT_IDS; do
        local svc
        for svc in ${SERVICES[$id]:-}; do
            timeout 3 systemctl is-active --quiet "$svc" 2>/dev/null && n=$((n + 1))
        done
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
            bash "$(dirname "$0")/detect-status.sh" 2>/dev/null | sed -n '/Phase6/p;/Phase7/p;/Verify/p;/Verdict/p;/Next step/p' || true
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
