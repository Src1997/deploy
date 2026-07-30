#!/usr/bin/env bash
# ============================================================================
# Financial API — Server-side one-click deploy script
#
# Usage:
#   ./deploy.sh                # Full: backup + extract + deps + migrate + seed + restart
#   ./deploy.sh --no-extract   # Skip extraction (code already in place)
#   ./deploy.sh --no-seed      # Skip seed (only migrate)
#   ./deploy.sh --no-restart   # Don't restart services
#   ./deploy.sh --rollback     # Rollback to previous backup (interactive)
#   ./deploy.sh --rollback --yes  # Rollback non-interactively (latest backup)
#   ./deploy.sh --list         # List available backups
#   ./deploy.sh --web-path=/myapp  # Set web sub-path (default: /financial)
#   ./deploy.sh --yes          # Non-interactive: skip all confirmations
#
# This script is idempotent:
#   - .env is only generated on first deploy (never overwritten)
#   - .venv is only created if missing (pip install -e . is always safe)
#   - systemd service files are only installed if missing
#   - Full backup is created before every code sync (enables rollback)
# ============================================================================

set -euo pipefail

# 可选加载 deploy.env（包内自包含，不依赖 lib/）
_load_optional_env() {
    local f script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in "${DEPLOY_ENV_FILE:-}" \
             "$script_dir/../../../deploy.env" \
             "$script_dir/../../../../deploy.env" \
             "/www/wwwroot/project/deploy.env" \
             "$(pwd)/deploy.env" \
             "${HOME}/deploy-sandbox/deploy.env"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        set -a
        # shellcheck disable=SC1090
        source "$f"
        set +a
        break
    done
}
_load_optional_env

# ── Paths（可用 PROJECT_BASE / DEPLOY_ROOT 覆盖）────────────────────────────
PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
DEPLOY_ROOT="${DEPLOY_ROOT:-$PROJECT_BASE/financial/financial-api}"
PKG_DIR="${PKG_DIR:-$DEPLOY_ROOT/package}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_ROOT/backup}"
VENV_DIR="${VENV_DIR:-$PKG_DIR/.venv}"
ENV_FILE="${ENV_FILE:-$PKG_DIR/.env}"
# 专用临时目录，禁止向 /tmp 顶层散落文件
DEPLOY_TMP_DIR="${DEPLOY_TMP_DIR:-/tmp/fin-deploy}"
mkdir -p "$DEPLOY_TMP_DIR"
export TMPDIR="$DEPLOY_TMP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MAX_BACKUPS="${MAX_BACKUPS:-5}"
CONFIGS_SRC="${CONFIGS_SRC:-$PROJECT_BASE/uploads/dist/configs}"

# ── 密码（仅 deploy.env / 环境变量；禁止脚本内硬编码）──
PG_PASSWORD="${PG_PASSWORD:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
DOMAIN="${DOMAIN:-}"
WWW_DOMAIN="${WWW_DOMAIN:-}"
APP_NAME="${APP_NAME:-MyApp}"

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
ASSUME_YES=false
WEB_PATH="/financial"

for arg in "$@"; do
    case "$arg" in
        --no-extract)  DO_EXTRACT=false ;;
        --no-seed)     DO_SEED=false ;;
        --no-restart)  DO_RESTART=false ;;
        --rollback)    DO_ROLLBACK=true ;;
        --list)        DO_LIST=true ;;
        --yes|-y|--ci) ASSUME_YES=true ;;
        --web-path=*)  WEB_PATH="${arg#--web-path=}" ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

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
        local_has_code=$([[ -d "${d}app" ]] && echo "✓" || echo "✗")
        echo "  ${local_name}  code:${local_has_code}  .env:${local_has_env}  .venv:${local_has_venv}"
    done
    echo ""
    echo "  Rollback:  bash deploy.sh --rollback"
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
        local_has_code=$([[ -d "${d}app" ]] && echo "✓" || echo "✗")
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
    systemctl stop financial-api financial-crawler financial-worker financial-streaming 2>/dev/null || true

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
    systemctl start financial-api financial-crawler financial-worker financial-streaming
    sleep 2

    if curl -sf http://127.0.0.1:5001/api/health > /dev/null 2>&1; then
        ok "API health check passed"
    else
        warn "API health check failed — check: journalctl -u financial-api -n 30"
    fi

    systemctl is-active financial-api financial-crawler financial-worker financial-streaming

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
    ARCHIVE=$(ls -t "${DEPLOY_ROOT}"/financial-api-*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE=$(ls -t "${DEPLOY_ROOT}"/financial-api-*.zip 2>/dev/null | head -1)
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
        local env_preserve=""
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
    log "Generating .env (first deploy)..."
    mkdir -p "$PKG_DIR"

    AUTH_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || echo "CHANGE_ME_AUTH_SECRET")
    SERVER_IP_VAL="${SERVER_IP:-127.0.0.1}"

    template=""
    for t in "$CONFIGS_SRC/financial-api.env.example" \
             "$PROJECT_BASE/uploads/dist/configs/financial-api.env.example" \
             "$(dirname "${BASH_SOURCE[0]}")/../configs/financial-api.env.example" \
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
            "$template" > "$ENV_FILE"
        ok ".env generated from template: $template"
    else
        warn "未找到 financial-api.env.example，使用内联最小模板"
        cat > "$ENV_FILE" <<EOF
APP_NAME=financial-api
APP_ENV=production
DEBUG=false
APP_ROLE=api
HOST=127.0.0.1
PORT=5001
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USER=root
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=quant_zc
DATABASE_URL=postgresql+psycopg2://root:${PG_PASSWORD}@localhost:5432/quant_zc
REDIS_ENABLED=true
REDIS_URL=redis://:${REDIS_PASSWORD}@localhost:6379/0
ARQ_REDIS_URL=redis://:${REDIS_PASSWORD}@localhost:6379/1
AUTH_MODE=local
AUTH_SECRET_KEY=${AUTH_KEY}
AUTH_UPSTREAM_URL=http://127.0.0.1:5000
CORS_ORIGINS=https://${WWW_DOMAIN},https://${DOMAIN},http://localhost:5173,http://127.0.0.1:5173,http://localhost:5174,http://127.0.0.1:5174
WEB_PATH=${WEB_PATH}
LOG_DIR=logs
LOG_LEVEL=INFO
SMTP_ENABLED=true
SMTP_HOST=127.0.0.1
SMTP_PORT=465
SMTP_USERNAME=noreply@${DOMAIN}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_USE_TLS=false
SMTP_FROM_ADDR=noreply@${DOMAIN}
SMTP_FROM_NAME=${APP_NAME}
EMAIL_SUBJECT_TEMPLATE=您的验证码 - ${APP_NAME}
EOF
        ok ".env generated (inline fallback)"
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
        key=$(echo "$key" | xargs)  # trim
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

# ── 5.5 数据库备份（迁移前 pg_dump）───────────────────────────────────
db_backup() {
    local db_name="quant_zc"
    local db_backup_dir="${PKG_DIR}/logs/db-backups"
    mkdir -p "$db_backup_dir"
    local db_file="${db_backup_dir}/${TIMESTAMP}.sql.gz"
    log "Backing up database ($db_name) before migration..."
    if PGPASSWORD="${PG_PASSWORD}" pg_dump -U root -h localhost "$db_name" 2>/dev/null | gzip > "$db_file"; then
        local db_size
        db_size=$(du -h "$db_file" | cut -f1)
        ok "Database backup: $db_file ($db_size)"
        # 清理旧备份（保留 5 个）
        local count
        count=$(ls -1 "$db_backup_dir"/*.sql.gz 2>/dev/null | wc -l)
        [ "$count" -gt 5 ] && ls -t "$db_backup_dir"/*.sql.gz | tail -n +6 | xargs rm -f 2>/dev/null
    else
        warn "Database backup failed — continuing anyway (migration will proceed)"
    fi
}

db_backup

# ── 6. Database migrate ──────────────────────────────────────────────────────
log "Running alembic upgrade head..."
"$VENV_DIR/bin/alembic" upgrade head
ok "Database migration complete"

# ── 7. Seed (optional) ───────────────────────────────────────────────────────
if $DO_SEED; then
    log "Running seed..."
    "$VENV_DIR/bin/python" -m app.db.seed
    ok "Seed complete"
fi

# ── 8. Install systemd service files (first-deploy only) ─────────────────────
install_service() {
    local name="$1"
    local service_file="/etc/systemd/system/${name}.service"

    if [[ -f "$service_file" ]]; then
        ok "${name}.service already installed"
        return
    fi

    log "Installing ${name}.service..."
    case "$name" in
        financial-api)
            cat > "$service_file" <<'SVC'
[Unit]
Description=卓筹商学院 API Server
After=network.target bt-postgresql.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/www/wwwroot/project/financial/financial-api/package
Environment=APP_ROLE=api
ExecStart=/www/wwwroot/project/financial/financial-api/package/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 5001 --no-access-log
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fastbull-api
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
            ;;
        financial-crawler)
            cat > "$service_file" <<'SVC'
[Unit]
Description=卓筹商学院 Crawler Enqueue Scheduler
After=network.target bt-postgresql.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/www/wwwroot/project/financial/financial-api/package
Environment=APP_ROLE=crawler
Environment=CRAWLER_ENABLED=true
Environment=CRAWLER_ENQUEUE_ENABLED=true
ExecStart=/www/wwwroot/project/financial/financial-api/package/.venv/bin/python -m app.crawler scheduler
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fastbull-crawler
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
            ;;
        financial-worker)
            cat > "$service_file" <<'SVC'
[Unit]
Description=卓筹商学院 arq Worker
After=network.target bt-postgresql.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/www/wwwroot/project/financial/financial-api/package
Environment=APP_ROLE=crawler
Environment=CRAWLER_ENABLED=true
ExecStart=/www/wwwroot/project/financial/financial-api/package/.venv/bin/arq worker.settings.WorkerSettings
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=financial-worker
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
            ;;
        financial-streaming)
            cat > "$service_file" <<'SVC'
[Unit]
Description=卓筹商学院 Streaming
After=network.target bt-postgresql.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/www/wwwroot/project/financial/financial-api/package
Environment=APP_ROLE=crawler
Environment=CRAWLER_ENABLED=true
ExecStart=/www/wwwroot/project/financial/financial-api/package/.venv/bin/python -m worker.streaming
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=financial-streaming
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
            ;;
    esac

    systemctl daemon-reload
    systemctl enable "$name"
    ok "${name}.service installed and enabled"
}

install_service financial-api
install_service financial-crawler
install_service financial-worker
install_service financial-streaming

# ── 8.5 Generate Nginx config (from template) ────────────────────────────────
# 将 fastbull.conf 模板中的 __WEB_PATH__ 占位符替换为实际路径
# 生成 fastbull-generated.conf，用户粘贴到宝塔面板
gen_nginx_config() {
    local template="$PKG_DIR/nginx/fastbull.conf"
    local output="$PKG_DIR/nginx/fastbull-generated.conf"

    if [ -f "$template" ]; then
        sed "s|__WEB_PATH__|${WEB_PATH}|g" "$template" > "$output"
        ok "Nginx config generated: $output"
        echo "  Paste this config into 宝塔面板 → 网站设置 → 配置文件"
    else
        warn "Nginx template not found: $template (skipping)"
    fi
}

gen_nginx_config

# ── 9. Restart services ──────────────────────────────────────────────────────
if $DO_RESTART; then
    log "Restarting services..."
    systemctl restart financial-api financial-crawler financial-worker financial-streaming
    sleep 2

    # Health check
    if curl -sf http://127.0.0.1:5001/api/health > /dev/null 2>&1; then
        ok "API health check passed"
    else
        warn "API health check failed — check: journalctl -u financial-api -n 30"
        warn "If needed, rollback with: bash deploy.sh --rollback"
    fi

    # Show status
    systemctl is-active financial-api financial-crawler financial-worker financial-streaming
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
echo "    systemctl status financial-api financial-crawler financial-worker financial-streaming"
echo "    journalctl -u financial-api -f"
echo "    curl http://127.0.0.1:5001/api/health"
echo "    cat $PKG_DIR/VERSION          # 查看部署版本"
echo "    bash deploy.sh --list         # list backups"
echo "    bash deploy.sh --rollback     # rollback to previous version"
echo ""
