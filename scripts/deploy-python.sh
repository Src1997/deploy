#!/usr/bin/env bash
# -- CRLF self-fix: Windows-edited scripts may carry \r, strip and re-exec --
if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
    sed -i 's/\r$//' "${BASH_SOURCE[0]}"
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

# ============================================================================
# deploy-python.sh — Server-side one-click deploy hook (Python/FastAPI)
#
# 通用 Python/FastAPI 部署钩子，不写死任何项目名。
# 组件身份由 COMPONENT_ID 环境变量注入（deploy.sh 调用时自动传入），
# 项目专有值由 project.toml → deploy.sh → 环境变量注入。
#
# Usage:
#   ./deploy.sh                # Full: backup + extract + deps + migrate + seed + restart
#   ./deploy.sh --no-extract   # Skip extraction (code already in place)
#   ./deploy.sh --no-seed      # Skip seed (only migrate)
#   ./deploy.sh --no-restart   # Don't restart services
#   ./deploy.sh --dry-run      # Print resolved deploy plan and exit (no changes)
#   ./deploy.sh --rollback     # Rollback to previous backup (interactive)
#   ./deploy.sh --rollback --yes  # Rollback non-interactively (latest backup)
#   ./deploy.sh --list         # List available backups
#   ./deploy.sh --web-path=/myapp  # Set web sub-path (default: empty)
#   ./deploy.sh --yes          # Non-interactive: skip all confirmations
#
# Required env (deploy.sh passthrough):
#   COMPONENT_ID=<id>           # component identity (e.g. financial-api)
#
# Optional env knobs (deploy.env / environment / deploy.sh passthrough):
#   PKG_DIR=<path>             # package dir; auto-detected otherwise:
#                               #   env → $PROJECT_BASE/*/<id>/package →
#                               #   $PROJECT_BASE/<id>/package
#   API_PORT=<port>            # port override; auto-resolved otherwise:
#                               #   env → .env PORT= → template PORT= → 5001
#                               #   (deploy.sh passes it from project.toml
#                               #    health_url, which is the port SSOT)
#   SEED_ON_DEPLOY=false        # skip seed at deploy time (first deploy always seeds)
#   SKIP_POST_DEPLOY_CHECK=true # skip business-endpoint verification
#   POST_DEPLOY_CHECK_PATH=/api/...  # verification endpoint;
#                               #   deploy.sh 从 project.toml post_deploy_check_path 传入
#   WEB_PATH=/myapp            # web sub-path for .env template rendering;
#                               #   deploy.sh 从 project.toml web_path 传入
#   ENV_TEMPLATE=<name>.env.example  # .env template filename (configs/);
#                               #   default: <id>.env.example
#   SEED_MODULE=<module>        # seed entrypoint (python -m); auto-detected:
#                               #   app/db/seed.py present → app.db.seed, else skip
#   HEALTH_PATH=/api/health     # health check path
#   SERVICES="a b c"            # service list (space-separated);
#                               #   deploy.sh 从 TOML services 传入；默认 <id>
#
# Reusing this hook for a new Python/FastAPI project:
#   1. project-configs/<proj>/project.toml: deploy_hook = "scripts/deploy-python.sh",
#      设 health_url + services + post_deploy_check_path + web_path（按需）
#   2. configs/<id>.env.example 模板（占位符 __PG_PASSWORD__ / __PORT__ 等）
#   3. configs/systemd/<svc>.service 模板（systemd 兜底路径用）
#   4. Supervisor 环境按 05-setup-supervisor.sh 方式注册程序
#   5. deploy.env 按需覆盖：PKG_DIR / API_PORT / SEED_MODULE / SERVICES 等
#
# Process daemon: Supervisor first (repo standard, managed by
# 05-setup-supervisor.sh), fall back to systemd units rendered from
# configs/systemd/*.service templates.
#
# This script is idempotent:
#   - .env is only generated on first deploy (never overwritten)
#   - .venv is only created if missing (pip install -e . is always safe)
#   - systemd units are only (re)installed when the rendered template changes
#   - Full backup is created before every code sync (enables rollback)
# ============================================================================

set -euo pipefail

# ── Helpers（提前定义，后续函数可能引用）─────────────────────────────
log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

# 可选加载 deploy.env（包内自包含，不依赖 lib/）
_load_optional_env() {
    local f script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in "${DEPLOY_ENV_FILE:-}" \
             "${PROJECT_BASE:-/www/wwwroot/project}/deploy.env" \
             "$script_dir/../../../deploy.env" \
             "$script_dir/../../../../deploy.env" \
             "/www/wwwroot/project/deploy.env"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        set -a
        # Strip CRLF (\r) before sourcing - Windows-edited env files
        # would inject \r into variable values causing garbled errors
        # shellcheck disable=SC1090
        source <(sed 's/\r$//' "$f")
        set +a
        break
    done
}
_load_optional_env

# ── 组件身份：由 deploy.sh / 环境变量注入（project.toml SSOT）────────────
# deploy.sh 调用时自动传入；独立运行时必须显式设置。
if [ -z "${COMPONENT_ID:-}" ]; then
    err "COMPONENT_ID 未设置。deploy.sh 调用时自动传入；独立运行请设置环境变量。"
    exit 1
fi

# ── Paths（全部可被 PROJECT_BASE / PKG_DIR / DEPLOY_ROOT 环境变量覆盖）──────
PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"

# PKG_DIR 解析链（前者优先）：
#   1. 环境变量（deploy.sh 调用时注入 / deploy.env 覆盖）
#   2. 自动探测 $PROJECT_BASE/*/<id>/package（两层布局 <group>/<component>，
#      如 financial/financial-api）→ $PROJECT_BASE/<id>/package（单层布局）
#   3. 脚本自身位于某个 package/ 内（手动解包到自定义位置的场景）→ 就地部署
#   4. 兜底 $PROJECT_BASE/<id>/package（首次部署目标，随后续创建）
if [ -z "${PKG_DIR:-}" ]; then
    for _cand in "$PROJECT_BASE"/*/"$COMPONENT_ID" \
                 "$PROJECT_BASE"/"$COMPONENT_ID"; do
        [ -d "$_cand" ] || continue
        PKG_DIR="$_cand/package"
        break
    done
fi
if [ -z "${PKG_DIR:-}" ]; then
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    case "$(basename "$_script_dir")" in
        package) PKG_DIR="$_script_dir" ;;
        scripts)
            [ "$(basename "$(dirname "$_script_dir")")" = "package" ] \
                && PKG_DIR="$(dirname "$_script_dir")"
            ;;
    esac
fi
PKG_DIR="${PKG_DIR:-$PROJECT_BASE/$COMPONENT_ID/package}"
DEPLOY_ROOT="${DEPLOY_ROOT:-$(dirname "$PKG_DIR")}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_ROOT/backup}"
BACKUP_BASE="${BACKUP_BASE:-$PROJECT_BASE/backup}"
VENV_DIR="${VENV_DIR:-$PKG_DIR/.venv}"
ENV_FILE="${ENV_FILE:-$PKG_DIR/.env}"
# 专用临时目录，禁止向 /tmp 顶层散落文件
DEPLOY_TMP_DIR="${DEPLOY_TMP_DIR:-/tmp/deploy-$COMPONENT_ID}"
mkdir -p "$DEPLOY_TMP_DIR"
export TMPDIR="$DEPLOY_TMP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MAX_BACKUPS="${MAX_BACKUPS:-5}"
CONFIGS_SRC="${CONFIGS_SRC:-$PROJECT_BASE/uploads/dist/configs}"

# ── 密码与配置（仅 deploy.env / 环境变量；禁止脚本内硬编码）──
PG_PASSWORD="${PG_PASSWORD:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
DOMAIN="${DOMAIN:-}"
WWW_DOMAIN="${WWW_DOMAIN:-}"
APP_NAME="${APP_NAME:-$COMPONENT_ID}"
# 数据库用户/库名（deploy.env 中可覆盖，默认 root/quant_zc）
PG_USER="${PG_USER:-root}"
POSTGRES_DB="${POSTGRES_DB:-quant_zc}"
# API 端口（uvicorn 监听 + 健康检查）不写死：按指定来源逐级解析，见 resolve_api_port

# ── 项目参数（按组件约定从 COMPONENT_ID 推导，可经 deploy.env / 环境变量覆盖）──
# .env 模板文件名（查找顺序：$CONFIGS_SRC → 脚本相对 configs/ → $PKG_DIR/.env.example）
ENV_TEMPLATE="${ENV_TEMPLATE:-${COMPONENT_ID}.env.example}"
# seed 入口模块（python -m $SEED_MODULE）；未显式设置时在代码同步后自动探测
# 包内惯例路径 app/db/seed.py / app/db/seed/__main__.py（探测不到 = 跳过 seed）
# 健康检查路径（实际探测 http://127.0.0.1:${API_PORT}${HEALTH_PATH}）
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
# 部署后业务端点验证路径（默认空=跳过；由 deploy.sh 从 project.toml post_deploy_check_path 注入）
POST_DEPLOY_CHECK_PATH="${POST_DEPLOY_CHECK_PATH:-}"

# ── API 端口解析（不写死；按指定来源逐级回退）──
#   1. API_PORT 环境变量 / deploy.env（deploy.sh 调用时从 project.toml health_url
#      提取传入，project.toml 即端口的配置 SSOT）
#   2. 已部署 .env 的 PORT=（应用运行时指定的端口）
#   3. .env 模板中的数字 PORT=（首次部署；__PORT__ 占位符不算）
#   4. 5001 兜底（与 project-configs/financial/project.toml 一致）
resolve_api_port() {
    [ -n "${API_PORT:-}" ] && return
    local port=""
    if [[ -f "$ENV_FILE" ]]; then
        port=$(grep '^PORT=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        local t
        for t in "$CONFIGS_SRC/$ENV_TEMPLATE" \
                 "$PROJECT_BASE/uploads/dist/configs/$ENV_TEMPLATE" \
                 "$(dirname "${BASH_SOURCE[0]}")/../configs/$ENV_TEMPLATE" \
                 "$PKG_DIR/.env.example"; do
            [[ -f "$t" ]] || continue
            port=$(grep '^PORT=' "$t" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
            [[ "$port" =~ ^[0-9]+$ ]] && break
        done
    fi
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        API_PORT="$port"
    else
        # TODO(leader): 下一步将 5001 兜底也移除，强制通过 project.toml 或 deploy.env 显式指定端口
        warn "未找到端口配置，使用兜底端口 5001（建议在 project.toml health_url 或 deploy.env API_PORT 中显式指定）"
        API_PORT="5001"
    fi
}
resolve_api_port

_require_secrets() {
    if [ -z "${PG_PASSWORD}" ] || [ "${PG_PASSWORD}" = "CHANGE_ME" ] \
       || [ -z "${REDIS_PASSWORD}" ] || [ "${REDIS_PASSWORD}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m 请配置 deploy.env 中的 PG_PASSWORD / REDIS_PASSWORD（见 deploy.env.example）" >&2
        exit 1
    fi
    if [ -z "${SMTP_PASSWORD}" ] || [ "${SMTP_PASSWORD}" = "CHANGE_ME" ]; then
        echo -e "\033[33m[!]\033[0m SMTP_PASSWORD 未配置，邮箱验证码功能将无法发送真实邮件" >&2
    fi
}

# ── Flags ────────────────────────────────────────────────────────────────────
DO_EXTRACT=true
DO_SEED=true
DO_RESTART=true
DO_ROLLBACK=false
DO_LIST=false
DO_DRY_RUN=false
ASSUME_YES=false
FIRST_DEPLOY=false
# 服务清单：环境变量传入（deploy.sh 从 project.toml services 字段注入）优先，否则默认仅管自己
WEB_PATH="${WEB_PATH:-}"
if [ -n "${SERVICES:-}" ]; then
    # shellcheck disable=SC2206  # 环境变量按空白拆分为数组
    read -ra SERVICES <<< "$SERVICES"
else
    SERVICES=("$COMPONENT_ID")
fi

for arg in "$@"; do
    case "$arg" in
        --no-extract)  DO_EXTRACT=false ;;
        --no-seed)     DO_SEED=false ;;
        --no-restart)  DO_RESTART=false ;;
        --dry-run)     DO_DRY_RUN=true ;;
        --rollback)    DO_ROLLBACK=true ;;
        --list)        DO_LIST=true ;;
        --yes|-y|--ci) ASSUME_YES=true ;;
        --web-path=*)  WEB_PATH="${arg#--web-path=}" ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── 进程守护：Supervisor 优先（仓库标准），回退 systemd ─────────────────────
# 与 lib/service-ops.sh 同一优先级约定；本钩子自包含（包内无 lib/），故内联实现。
_SUPERVISORCTL=""
if [ -x /www/server/panel/plugin/supervisor/bin/supervisorctl ]; then
    _SUPERVISORCTL="/www/server/panel/plugin/supervisor/bin/supervisorctl"
elif command -v supervisorctl >/dev/null 2>&1; then
    _SUPERVISORCTL="$(command -v supervisorctl)"
fi

# _svc_in_supervisor <name>：程序是否已注册到 Supervisor（与运行状态无关；
# 用全量列表判断而非 exit code——STOPPED 时 exit code 非 0 会被误判为未注册）
_svc_in_supervisor() {
    [ -n "$_SUPERVISORCTL" ] || return 1
    "$_SUPERVISORCTL" status 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# svc_ctl <stop|start|restart> <service...>：逐服务分发到 Supervisor / systemctl
svc_ctl() {
    local action="$1"; shift
    local svc
    for svc in "$@"; do
        if _svc_in_supervisor "$svc"; then
            "$_SUPERVISORCTL" "$action" "$svc" 2>/dev/null \
                || warn "$svc Supervisor ${action} 失败"
        else
            systemctl "$action" "$svc" 2>/dev/null \
                || warn "$svc systemctl ${action} 失败"
        fi
    done
}

# svc_show_status <service...>：打印各服务运行状态
svc_show_status() {
    local svc status
    for svc in "$@"; do
        if _svc_in_supervisor "$svc"; then
            status=$("$_SUPERVISORCTL" status "$svc" 2>/dev/null | awk '{print $2}')
            if [ "$status" = "RUNNING" ]; then
                ok "$svc: RUNNING (Supervisor)"
            else
                warn "$svc: ${status:-unknown} (Supervisor)"
            fi
        else
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                ok "$svc: active (systemd)"
            else
                warn "$svc: $(systemctl is-active "$svc" 2>/dev/null || echo n/a) (systemd)"
            fi
        fi
    done
}

# ── List backups ─────────────────────────────────────────────────────────────
if $DO_LIST; then
    echo ""
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        echo "  No backups found in ${BACKUP_DIR}"
        echo ""
        exit 0
    fi

    echo "  Available backups (newest first):"
    echo "  ────────────────────────────────────────────────"
    for d in $(ls -dt "${BACKUP_DIR}"/*/ 2>/dev/null); do
        local_name=$(basename "$d")
        local_has_env=$([[ -f "${d}.env" ]] && echo "✓" || echo "✗")
        local_has_venv=$([[ -d "${d}.venv" ]] && echo "✓" || echo "✗")
        local_has_code=$([[ -n "$(ls -A "${d%/}" 2>/dev/null)" ]] && echo "✓" || echo "✗")
        echo "  ${local_name}  code:${local_has_code}  .env:${local_has_env}  .venv:${local_has_venv}"
    done
    echo ""
    echo "  Rollback:  bash deploy.sh --rollback"
    echo ""
    exit 0
fi

# ── Dry-run: print resolved plan and exit ────────────────────────────────────
if $DO_DRY_RUN; then
    echo ""
    log "[DRY_RUN] 部署计划（不做任何更改）："
    echo "    组件         : ${COMPONENT_ID}"
    echo "    DEPLOY_ROOT  : ${DEPLOY_ROOT}"
    echo "    PKG_DIR      : ${PKG_DIR}"
    echo "    ENV_FILE     : ${ENV_FILE}（存在: $([[ -f "$ENV_FILE" ]] && echo yes || echo no)）"
    echo "    ENV_TEMPLATE : ${ENV_TEMPLATE}"
    echo "    备份         : $([[ -d "$PKG_DIR" ]] && echo "是 → ${BACKUP_DIR}/" || echo "否（首次部署）")"
    echo "    数据库       : ${PG_USER}@127.0.0.1:5432/${POSTGRES_DB}"
    echo "    Seed         : $($DO_SEED && echo "是（--no-seed 跳过）" || echo "否（--no-seed）")$([ -n "${SEED_MODULE:-}" ] && echo "（module=${SEED_MODULE}）" || echo "（自动探测）")"
    echo "    重启         : $($DO_RESTART && echo "是" || echo "否（--no-restart）")"
    echo "    服务         : ${SERVICES[*]}"
    echo "    进程守护     : $([ -n "$_SUPERVISORCTL" ] && echo "Supervisor（${_SUPERVISORCTL}）" || echo "未检测到 Supervisor，回退 systemd")"
    echo "    API 端口     : ${API_PORT}"
    echo ""
    exit 0
fi

_require_secrets

# ── Rollback ─────────────────────────────────────────────────────────────────
if $DO_ROLLBACK; then
    echo ""
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        err "No backups found in ${BACKUP_DIR}"
        exit 1
    fi

    # List backups for selection
    echo "  Available backups (newest first):"
    echo "  ────────────────────────────────────────────────"
    backups=()
    i=1
    for d in $(ls -dt "${BACKUP_DIR}"/*/ 2>/dev/null); do
        backups+=("$d")
        local_name=$(basename "$d")
        local_has_env=$([[ -f "${d}.env" ]] && echo "✓" || echo "✗")
        local_has_venv=$([[ -d "${d}.venv" ]] && echo "✓" || echo "✗")
        local_has_code=$([[ -n "$(ls -A "${d%/}" 2>/dev/null)" ]] && echo "✓" || echo "✗")
        echo "  [${i}] ${local_name}  code:${local_has_code}  .env:${local_has_env}  .venv:${local_has_venv}"
        ((i++))
    done
    echo ""

    # Non-interactive mode: auto-select latest backup
    if $ASSUME_YES; then
        choice=1
        warn "--yes 模式：自动选择最新备份"
    else
        read -rp "  Select backup number to rollback (1=newest, q=quit): " choice
        if [[ "$choice" == "q" ]] || [[ -z "$choice" ]]; then
            echo "  Rollback cancelled."
            exit 0
        fi
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        err "Invalid selection: ${choice}"
        exit 1
    fi

    ROLLBACK_DIR="${backups[$((choice-1))]}"
    ROLLBACK_NAME=$(basename "$ROLLBACK_DIR")

    echo ""
    warn "This will replace current code in ${PKG_DIR} with backup: ${ROLLBACK_NAME}"
    warn "Services will be restarted. .env will be restored from backup."
    if $ASSUME_YES; then
        warn "--yes 模式：跳过确认"
    else
        read -rp "  Continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "  Rollback cancelled."
            exit 0
        fi
    fi

    log "Rolling back to ${ROLLBACK_NAME}..."

    # Stop services first
    log "Stopping services..."
    svc_ctl stop "${SERVICES[@]}"

    # Restore code (preserve logs/)
    find "$PKG_DIR" -mindepth 1 -maxdepth 1 ! -name 'logs' -exec rm -rf {} + 2>/dev/null || true
    cp -a "${ROLLBACK_DIR%/}/." "$PKG_DIR/"
    find "$PKG_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

    # Restore .env if backup has it
    if [[ -f "${ROLLBACK_DIR}.env" ]]; then
        cp "${ROLLBACK_DIR}.env" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        ok ".env restored"
    fi

    # Restore .venv if backup has it (may be large, so optional)
    if [[ -d "${ROLLBACK_DIR}.venv" ]]; then
        rm -rf "$VENV_DIR"
        cp -a "${ROLLBACK_DIR}.venv" "$VENV_DIR"
        ok ".venv restored"
    else
        warn ".venv not in backup, keeping current"
    fi

    # Restart services
    log "Restarting services..."
    svc_ctl start "${SERVICES[@]}"
    sleep 2

    # Health check
    if curl -sf --max-time 5 "http://127.0.0.1:${API_PORT}${HEALTH_PATH}" > /dev/null 2>&1; then
        ok "API health check passed"
    else
        warn "API health check failed — check: supervisorctl tail ${SERVICES[0]} stderr / journalctl -u ${SERVICES[0]} -n 30"
    fi

    svc_show_status "${SERVICES[@]}"

    echo ""
    ok "Rollback to ${ROLLBACK_NAME} complete!"
    echo ""
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# Normal deploy flow
# ════════════════════════════════════════════════════════════════════════════

# ── 0. Pre-deploy backup ─────────────────────────────────────────────────────
# Create a full backup of current package/ before any changes, enables rollback.
do_backup() {
    if [[ ! -d "$PKG_DIR" ]]; then
        ok "No existing package/ to backup (first deploy)"
        return
    fi

    local backup_name="${TIMESTAMP}"
    local backup_path="${BACKUP_DIR}/${backup_name}/"
    mkdir -p "$backup_path"

    log "Creating pre-deploy backup: ${backup_name}"

    # Backup code (exclude runtime artifacts to save space)
    ( cd "$PKG_DIR" && tar cf - \
        --exclude='./.venv' \
        --exclude='./logs' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='*.egg-info' \
        . ) | ( cd "$backup_path" && tar xf - )

    # Backup .env separately (already in rsync but make it explicit)
    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "${backup_path}.env"
    fi

    # Backup .venv (can be large, but needed for true rollback)
    if [[ -d "$VENV_DIR" ]]; then
        log "Backing up .venv (may take a moment)..."
        cp -a "$VENV_DIR" "${backup_path}.venv"
    fi

    # Record alembic version for reference
    if [[ -x "${VENV_DIR}/bin/alembic" ]]; then
        local alembic_ver
        alembic_ver=$("${VENV_DIR}/bin/alembic" current 2>/dev/null | head -1 || echo "unknown")
        echo "$alembic_ver" > "${backup_path}alembic_version.txt"
    fi

    local size
    size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
    ok "Backup created: ${backup_path} (${size})"

    # Rotate old backups (keep MAX_BACKUPS)
    local count
    count=$(ls -dt "${BACKUP_DIR}"/*/ 2>/dev/null | wc -l)
    if (( count > MAX_BACKUPS )); then
        log "Rotating old backups (keeping ${MAX_BACKUPS})..."
        ls -dt "${BACKUP_DIR}"/*/ | tail -n +$((MAX_BACKUPS + 1)) | while read -r old; do
            rm -rf "$old"
            ok "Removed old backup: $(basename "$old")"
        done
    fi
}

do_backup

# ── 1. Extract / locate code ─────────────────────────────────────────────────
#
# Three scenarios are handled (checked in priority order):
#   A) Raw archive exists in DEPLOY_ROOT  →  extract to temp, sync to PKG_DIR
#   B) Script runs from a nested package/ (e.g. 宝塔 extraction)  →  sync from script dir
#   C) Script already in PKG_DIR and no archive  →  nothing to do
#
if $DO_EXTRACT; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    SRC_DIR=""
    TEMP_DIR=""

    # ── Scenario A: archive exists in DEPLOY_ROOT (highest priority) ──
    # Even if the script is already in PKG_DIR, a new archive should override.
    # 归档名按组件约定 <id>-*.tar.gz / <id>-*.zip（与打包器 artifact_pattern 同源）
    ARCHIVE=$(ls -t "${DEPLOY_ROOT}"/${COMPONENT_ID}-*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE=$(ls -t "${DEPLOY_ROOT}"/${COMPONENT_ID}-*.zip 2>/dev/null | head -1)
    fi

    if [[ -n "$ARCHIVE" ]]; then
        log "Found archive: $(basename "$ARCHIVE")"
        TEMP_DIR=$(mktemp -d)
        if [[ "$ARCHIVE" == *.tar.gz ]]; then
            tar xzf "$ARCHIVE" -C "$TEMP_DIR"
        else
            unzip -q "$ARCHIVE" -d "$TEMP_DIR"
        fi
        # Archive contains a "package/" dir — find it
        SRC_DIR="${TEMP_DIR}/package"
        if [[ ! -d "$SRC_DIR" ]]; then
            SRC_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | head -1)
        fi
    fi

    # ── Scenario B: script runs from a nested dir (宝塔 extraction) ──
    if [[ -z "$SRC_DIR" ]]; then
        log "No archive found, detecting script location..."
        log "Script running from: ${SCRIPT_DIR}"
        if [[ "$(basename "$SCRIPT_DIR")" == "package" && "$SCRIPT_DIR" != "$PKG_DIR" ]]; then
            SRC_DIR="$SCRIPT_DIR"
            warn "Running from extracted dir: ${SCRIPT_DIR}"
        else
            FOUND_PKG=$(find "${DEPLOY_ROOT}" -maxdepth 3 -type d -name "package" ! -path "$PKG_DIR" 2>/dev/null | head -1)
            if [[ -n "$FOUND_PKG" ]]; then
                SRC_DIR="$FOUND_PKG"
                warn "Found extracted code at: ${FOUND_PKG}"
            fi
        fi
    fi

    # ── Sync code to PKG_DIR if we found a source ──
    if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]]; then
        mkdir -p "$PKG_DIR"

        # 备份生产 .env（cp -a 可能用包内 .env 覆盖它）
        env_preserve=""
        if [[ -f "$ENV_FILE" ]]; then
            env_preserve=$(mktemp)
            cp "$ENV_FILE" "$env_preserve"
        fi

        # Remove old code (preserve .env, .venv, logs/)
        find "$PKG_DIR" -mindepth 1 -maxdepth 1 \
            ! -name '.env' ! -name '.venv' ! -name 'logs' \
            -exec rm -rf {} + 2>/dev/null || true

        # 删除包内可能携带的 .env（防止开发者本地 .env 污染生产）
        rm -f "${SRC_DIR}/.env" 2>/dev/null || true

        # Copy new code
        cp -a "${SRC_DIR%/}/." "$PKG_DIR/"

        # 恢复生产 .env
        if [[ -n "$env_preserve" ]]; then
            cp "$env_preserve" "$ENV_FILE"
            rm -f "$env_preserve"
            ok ".env 已保护（未被包内文件覆盖）"
        fi

        # Clean runtime artifacts（扩大清理范围：含 alembic/versions/__pycache__）
        find "$PKG_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
        find "$PKG_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true
        find "$PKG_DIR" -type d -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true
        ok "Code synced to ${PKG_DIR}（__pycache__ 已清理）"
        if [[ -n "$TEMP_DIR" ]]; then
            rm -rf "$TEMP_DIR"
        fi
    else
        # ── Scenario C: no archive, no nested dir, already in PKG_DIR ──
        ok "No archive found, using existing code in ${PKG_DIR}"
    fi
fi

# ── 2. Ensure .env exists (first-deploy only) ────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    FIRST_DEPLOY=true
    log "Generating .env (first deploy)..."
    mkdir -p "$PKG_DIR"

    AUTH_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || echo "CHANGE_ME_AUTH_SECRET")
    SERVER_IP_VAL="${SERVER_IP:-127.0.0.1}"

    template=""
    for t in "$CONFIGS_SRC/$ENV_TEMPLATE" \
             "$PROJECT_BASE/uploads/dist/configs/$ENV_TEMPLATE" \
             "$(dirname "${BASH_SOURCE[0]}")/../configs/$ENV_TEMPLATE" \
             "$PKG_DIR/.env.example"; do
        [ -f "$t" ] && template="$t" && break
    done

    if [ -n "$template" ]; then
        sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
            -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
            -e "s|__AUTH_SECRET_KEY__|${AUTH_KEY}|g" \
            -e "s|__WEB_PATH__|${WEB_PATH}|g" \
            -e "s|__SERVER_IP__|${SERVER_IP_VAL}|g" \
            -e "s|__SMTP_PASSWORD__|${SMTP_PASSWORD}|g" \
            -e "s|__DOMAIN__|${DOMAIN}|g" \
            -e "s|__WWW_DOMAIN__|${WWW_DOMAIN}|g" \
            -e "s|__APP_NAME__|${APP_NAME}|g" \
            -e "s|__PG_USER__|${PG_USER:-root}|g" \
            -e "s|__POSTGRES_DB__|${POSTGRES_DB:-quant_zc}|g" \
            -e "s|__PORT__|${API_PORT}|g" \
            "$template" > "$ENV_FILE"
        ok ".env generated from template: $template"
    else
        err "未找到 .env 模板 ${ENV_TEMPLATE}（查找路径：configs/ → PKG_DIR/.env.example）"
        err "请创建 configs/${ENV_TEMPLATE} 或在 deploy.env 中设置 ENV_TEMPLATE 指向有效模板"
        exit 1
    fi

    chmod 600 "$ENV_FILE"
    ok ".env generated with fresh AUTH_SECRET_KEY"
else
    ok ".env already exists, preserved"
fi

# ── 2.5 .env 增量同步（补缺失的 env var）───────────────────────────────
# 对比 .env.example 的 key 列表，将 .env 中缺失的 key 追加（用 example 的默认值）
# 安全保证：只追加 .env 中确实不存在的 key，绝不覆盖已有值
# 跳过含 __PLACEHOLDER__ 的值（如 __PG_PASSWORD__），这些只在首次生成时由 sed 渲染
sync_env() {
    local example="$PKG_DIR/.env.example"
    local env_file="$ENV_FILE"
    if [[ ! -f "$example" || ! -f "$env_file" ]]; then
        return
    fi
    local missing=()
    local skipped_placeholder=0
    while IFS='=' read -r key val; do
        # 跳过注释、空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # trim leading/trailing whitespace (bash 内置，避免 xargs 吞特殊字符)
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # 跳过含占位符的值（如 __PG_PASSWORD__），追加无意义
        if [[ "$val" =~ __[A-Z_]+__ ]]; then
            skipped_placeholder=$((skipped_placeholder + 1))
            continue
        fi
        # 检查 .env 中是否有此 key（精确匹配行首 KEY=）
        if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
            missing+=("$key=$val")
        fi
    done < "$example"
    if [ ${#missing[@]} -gt 0 ]; then
        log ".env 增量同步：发现 ${#missing[@]} 个缺失变量，追加默认值..."
        echo "" >> "$env_file"
        echo "# ── 自动补充（$(date '+%Y-%m-%d') from .env.example）──" >> "$env_file"
        for item in "${missing[@]}"; do
            echo "$item" >> "$env_file"
            log "  + $item"
        done
        ok ".env 已补充 ${#missing[@]} 个缺失变量"
    else
        ok ".env 变量完整，无需同步"
    fi
    if [ $skipped_placeholder -gt 0 ]; then
        warn ".env.example 中有 ${skipped_placeholder} 个变量仍含占位符（如 __PG_PASSWORD__），已跳过；如需补充请手动设置"
    fi
}

sync_env

# ── 2.6 CORS_ORIGINS 增量更新（追加 SERVER_IP + Tailscale IP）─────────
# 确保 CORS_ORIGINS 包含当前 SERVER_IP 和 Tailscale 穿透 IP
# 安全保证：只在已有 CORS_ORIGINS 行追加缺失的 IP，不删除已有值
update_cors_origins() {
    local env_file="$ENV_FILE"
    [[ ! -f "$env_file" ]] && return

    local cors_line
    cors_line=$(grep '^CORS_ORIGINS=' "$env_file" 2>/dev/null | head -1 || echo "")
    [[ -z "$cors_line" ]] && return

    local cors_val="${cors_line#CORS_ORIGINS=}"
    local changed=0
    local additions=()

    # Add SERVER_IP if provided and not already in CORS
    if [[ -n "${SERVER_IP:-}" ]]; then
        if ! echo "$cors_val" | grep -q "http://${SERVER_IP}"; then
            cors_val="${cors_val},http://${SERVER_IP}"
            additions+=("http://${SERVER_IP}")
            changed=1
        fi
    fi

    # Add Tailscale server IP if configured and not already in CORS
    if [[ -n "${TAILSCALE_SERVER_IP:-}" ]]; then
        if ! echo "$cors_val" | grep -q "http://${TAILSCALE_SERVER_IP}"; then
            cors_val="${cors_val},http://${TAILSCALE_SERVER_IP}"
            additions+=("http://${TAILSCALE_SERVER_IP}")
            changed=1
        fi
    fi

    # Add Tailscale local IP if configured and not already in CORS
    if [[ -n "${TAILSCALE_LOCAL_IP:-}" ]]; then
        if ! echo "$cors_val" | grep -q "http://${TAILSCALE_LOCAL_IP}"; then
            cors_val="${cors_val},http://${TAILSCALE_LOCAL_IP}"
            additions+=("http://${TAILSCALE_LOCAL_IP}")
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=${cors_val}|" "$env_file"
        log "CORS_ORIGINS 已追加: ${additions[*]}"
    fi
}

update_cors_origins

# ── 3. Ensure .venv exists (first-deploy only) ───────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment (first deploy)..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    ok "Virtual environment created"
else
    ok "Virtual environment exists, preserved"
fi

# ── 4. Install/update dependencies ───────────────────────────────────────────
log "Installing dependencies (pip install -e .)..."
cd "$PKG_DIR"
"$VENV_DIR/bin/pip" install -e "." -q
ok "Dependencies installed"

# ── 5. Ensure logs directory ─────────────────────────────────────────────────
mkdir -p "${PKG_DIR}/logs"

# ── 5.5 Database backup (pg_dump before migration) ──────────────────────
db_backup() {
    # Read DB name from .env, fallback to default
    local db_name="quant_zc"
    if [[ -f "$ENV_FILE" ]]; then
        local parsed_db
        parsed_db=$(grep '^POSTGRES_DB=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')
        [[ -n "$parsed_db" ]] && db_name="$parsed_db"
    fi
    # Database backups go under BACKUP_BASE (same as code backups)
    local db_backup_dir="${BACKUP_BASE:-$PROJECT_BASE/backup}/db-backups/$db_name"
    mkdir -p "$db_backup_dir"
    local db_file="${db_backup_dir}/${TIMESTAMP}.sql.gz"
    local db_err="${db_backup_dir}/${TIMESTAMP}.dump.err"
    # ★ 备份账号缺省用超级用户 root：应用账号常缺表/序列权限，pg_dump 会在
    #   LOCK TABLE / 读序列阶段报 permission denied 而失败。可用 PG_BACKUP_USER 覆盖。
    local dump_user="${PG_BACKUP_USER:-${PG_USER:-root}}"
    local dump_pass="${PG_BACKUP_PASSWORD:-${PG_PASSWORD}}"
    log "Backing up database ($db_name) as $dump_user before migration..."

    # ★ 不能只判管道退出码：管道的 rc 是最后一个命令(gzip)的，pg_dump 失败也会被判
    #   "成功"，只留下一个 20 字节的空 .sql.gz —— 看着有备份，实际是空的。
    #   故用 PIPESTATUS 取 pg_dump 自身的 rc，并校验产物大小 > 1KB。
    #   PIPESTATUS 会被后续任何命令重置，必须一次性存进数组。
    local _ps pg_rc gz_rc out_size
    PGPASSWORD="$dump_pass" pg_dump -U "$dump_user" -h "${PG_HOST:-127.0.0.1}" -p "${PG_PORT:-5432}" "$db_name" 2>"$db_err" | gzip > "$db_file"
    _ps=("${PIPESTATUS[@]}")
    pg_rc=${_ps[0]}
    gz_rc=${_ps[1]}
    out_size=$(stat -c%s "$db_file" 2>/dev/null || echo 0)

    if (( pg_rc == 0 && gz_rc == 0 && out_size > 1024 )); then
        rm -f "$db_err" 2>/dev/null
        local db_size
        db_size=$(du -h "$db_file" | cut -f1)
        ok "Database backup: $db_file ($db_size)"
        # Rotate old backups (keep MAX_BACKUPS)
        local count
        count=$(ls -1 "$db_backup_dir"/*.sql.gz 2>/dev/null | wc -l)
        if (( count > MAX_BACKUPS )); then
            ls -t "$db_backup_dir"/*.sql.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null
            log "Rotated old DB backups (kept ${MAX_BACKUPS})"
        fi
    else
        warn "Database backup failed (pg_dump rc=$pg_rc, gzip rc=$gz_rc, size=${out_size}B) — continuing anyway (migration will proceed)"
        # 保留 pg_dump 的原始报错，别再 2>/dev/null 吞掉，否则下次仍无从排查
        if [[ -s "$db_err" ]]; then
            head -3 "$db_err" | while IFS= read -r _l; do warn "  pg_dump: $_l"; done
        fi
        rm -f "$db_file" 2>/dev/null
    fi
}

db_backup

# ── 6. Database migrate ──────────────────────────────────────────────────────
log "Running alembic upgrade head..."
"$VENV_DIR/bin/alembic" upgrade head
ok "Database migration complete"

# ── 7. Seed（部署时显式执行；与 app 启动时的 SEED_ON_STARTUP 解耦）────────
# 门控优先级（命中即停止）：
#   1. --no-seed                    → 跳过
#   2. 首次部署（本轮刚生成 .env）    → 强制执行（数据库需要初始数据）
#   3. SEED_ON_DEPLOY=false         → 跳过（deploy.env / 环境变量 / .env 均可设置）
#   4. 默认                         → 执行（seeder 幂等 + SKIP_SEED_PURGE 保护运行时数据）
# SEED_ON_STARTUP 只控制 app/main.py lifespan 启动时的 seed（默认 false），
# 不影响本部署脚本——两套开关各管各的生命周期。
if $DO_SEED; then
    # 自动探测 seed 入口（需在代码同步后执行：首次部署时包内文件此时才存在）。
    # 显式设置（含设为空串 = 跳过）优先于探测。
    if [ -z "${SEED_MODULE+x}" ]; then
        if [ -f "$PKG_DIR/app/db/seed.py" ] || [ -f "$PKG_DIR/app/db/seed/__main__.py" ]; then
            SEED_MODULE="app.db.seed"
        else
            SEED_MODULE=""
        fi
    fi
    if [ -z "$SEED_MODULE" ]; then
        warn "SEED_MODULE 未设置且未探测到 app/db/seed.py，跳过 seed（新项目无 seed 入口时属预期）"
    else
        _seed_on_deploy="${SEED_ON_DEPLOY:-}"
        if [[ -z "$_seed_on_deploy" && -f "$ENV_FILE" ]]; then
            _seed_on_deploy=$(grep '^SEED_ON_DEPLOY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || echo "")
        fi
        if $FIRST_DEPLOY; then
            log "首次部署，执行 seed（初始化基础数据）..."
            "$VENV_DIR/bin/python" -m "$SEED_MODULE"
            ok "Seed complete (first deploy)"
        elif [[ "$_seed_on_deploy" == "false" ]]; then
            warn "SEED_ON_DEPLOY=false，跳过 seed（运行时数据保持不变）"
        else
            log "Running seed..."
            "$VENV_DIR/bin/python" -m "$SEED_MODULE"
            ok "Seed complete"
        fi
    fi
fi

# ── 8. Install/update process daemon config ────────────────────────────────
# Supervisor 环境下进程配置由 05-setup-supervisor.sh 统一管理（SSOT），此处跳过
# systemd unit，避免重新制造 05 脚本刚清理掉的守护冲突；无 Supervisor 时回退
# systemd：从 configs/systemd/*.service 模板渲染（占位符：__PKG_DIR__ /
# __VENV_DIR__ / __APP_NAME__ / __API_PORT__）。
# Render to temp file, then compare with existing.
# Only overwrite + daemon-reload when content actually changed.
install_service() {
    local name="$1"
    if _svc_in_supervisor "$name"; then
        ok "${name} 由 Supervisor 管理，跳过 systemd unit"
        return
    fi

    local service_file="/etc/systemd/system/${name}.service"
    local template=""
    local t
    for t in "${CONFIGS_SRC}/systemd/${name}.service" \
             "$PKG_DIR/configs/systemd/${name}.service" \
             "$(dirname "${BASH_SOURCE[0]}")/../configs/systemd/${name}.service"; do
        [ -f "$t" ] && template="$t" && break
    done
    if [ -z "$template" ]; then
        warn "未找到 ${name}.service 模板（configs/systemd/），跳过安装"
        return
    fi

    local tmp_file
    tmp_file=$(mktemp)
    sed -e "s|__PKG_DIR__|${PKG_DIR}|g" \
        -e "s|__VENV_DIR__|${VENV_DIR}|g" \
        -e "s|__APP_NAME__|${APP_NAME}|g" \
        -e "s|__API_PORT__|${API_PORT}|g" \
        "$template" > "$tmp_file"

    if [[ ! -f "$service_file" ]]; then
        cp "$tmp_file" "$service_file"
        systemctl daemon-reload
        systemctl enable "$name" 2>/dev/null || true
        ok "${name}.service installed and enabled"
    elif diff -q "$tmp_file" "$service_file" >/dev/null 2>&1; then
        ok "${name}.service already up-to-date"
    else
        cp "$tmp_file" "$service_file"
        systemctl daemon-reload
        ok "${name}.service updated (template changed)"
    fi

    rm -f "$tmp_file"
}

for _svc in "${SERVICES[@]}"; do
    install_service "$_svc"
done

# NOTE: Nginx config is managed by deploy.sh → lib/nginx.sh → generate-nginx.py
# (SSOT). Do NOT generate Nginx config here — that would create a conflicting
# duplicate path. deploy-python.sh only handles backend services.

# ── 9. Restart services ──────────────────────────────────────────────────────
if $DO_RESTART; then
    log "Restarting services..."
    svc_ctl restart "${SERVICES[@]}"
    sleep 2

    # Health check
    if curl -sf --max-time 5 "http://127.0.0.1:${API_PORT}${HEALTH_PATH}" > /dev/null 2>&1; then
        ok "API health check passed"
    else
        warn "API health check failed — check: supervisorctl tail ${SERVICES[0]} stderr / journalctl -u ${SERVICES[0]} -n 30"
        warn "If needed, rollback with: bash deploy.sh --rollback"
    fi

    # Post-deploy verification: business endpoint returns data
    # （由 POST_DEPLOY_CHECK_PATH 控制；financial-api 默认检查导航 API，
    #   其他组件默认跳过，可经 deploy.env / 环境变量显式配置；
    #   SKIP_POST_DEPLOY_CHECK=true 可强制跳过）
    if [[ "${SKIP_POST_DEPLOY_CHECK:-false}" != "true" ]] && [ -n "${POST_DEPLOY_CHECK_PATH:-}" ]; then
        check_count=$(curl -sf --max-time 5 "http://127.0.0.1:${API_PORT}${POST_DEPLOY_CHECK_PATH}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',d) if isinstance(d,dict) else d))" 2>/dev/null || echo "0")
        if [[ "$check_count" -gt 0 ]]; then
            ok "Post-deploy check passed: ${POST_DEPLOY_CHECK_PATH} ($check_count items)"
        else
            warn "Post-deploy check returned no data — curl http://127.0.0.1:${API_PORT}${POST_DEPLOY_CHECK_PATH}"
            warn "If stale, run: $VENV_DIR/bin/python -m ${SEED_MODULE:-app.db.seed}"
        fi
    fi

    # Show status
    svc_show_status "${SERVICES[@]}"
fi

# ── 10. 展示版本信息 ──────────────────────────────────────────────────────
if [[ -f "$PKG_DIR/VERSION" ]]; then
    echo ""
    log "当前部署版本："
    cat "$PKG_DIR/VERSION"
    echo ""
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
ok "Deploy complete!"
echo ""
echo "  Quick commands:"
echo "    supervisorctl status        # Supervisor 进程总览（如已迁移 Supervisor）"
echo "    systemctl status ${SERVICES[*]}"
echo "    supervisorctl tail -f ${SERVICES[0]} / journalctl -u ${SERVICES[0]} -f"
echo "    curl http://127.0.0.1:${API_PORT}${HEALTH_PATH}"
echo "    cat $PKG_DIR/VERSION          # 查看部署版本"
echo "    bash deploy.sh --list         # list backups"
echo "    bash deploy.sh --rollback     # rollback to previous version"
echo ""
