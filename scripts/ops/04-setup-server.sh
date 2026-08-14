#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Phase 4: 服务器环境准备
#
# 用途：在宝塔面板上准备 PostgreSQL、Redis、Python 和目录结构
# 执行：SSH 到服务器后运行  bash 04-setup-server.sh
#
# 前提条件：
#   - 宝塔面板已安装（02-install-baota.sh）
#   - 通过宝塔手动安装 Nginx、PostgreSQL、Redis、Python
#   - 组件检查通过（03-check-components.sh）
# ═══════════════════════════════════════════════════════════════════════

# 不用 set -e，手动处理错误避免静默退出
set -uo pipefail

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Phase 4: 服务器环境准备"
echo "═══════════════════════════════════════════════════════════"
echo ""

# 已部署 / 进度探测
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 前置：检查宝塔组件是否全部安装 ─────────────────────────────
log "前置检查：宝塔组件安装状态..."

_CHECK_SCRIPT=""
for _cand in "$SCRIPT_DIR/03-check-components.sh" "$SCRIPT_DIR/../ops/03-check-components.sh"; do
    [ -f "$_cand" ] && _CHECK_SCRIPT="$_cand" && break
done

if [ -n "$_CHECK_SCRIPT" ]; then
    if ! bash "$_CHECK_SCRIPT"; then
        echo ""
        err "组件检查未通过，无法继续环境准备"
        echo "  请先在宝塔面板安装缺失组件，然后重新运行此脚本"
        exit 1
    fi
else
    warn "未找到 03-check-components.sh，跳过前置检查"
fi

echo ""

if [ -f "$SCRIPT_DIR/lib/load-deploy-env.sh" ]; then
    # shellcheck source=lib/load-deploy-env.sh
    source "$SCRIPT_DIR/lib/load-deploy-env.sh"
    if load_deploy_env "$SCRIPT_DIR"; then
        log "已加载配置: ${DEPLOY_ENV_LOADED}"
    else
        warn "未找到 deploy.env（将用环境变量；密码占位则稍后失败）"
        warn "请: cp deploy.env.example deploy.env 并填写 PG_PASSWORD / REDIS_PASSWORD"
    fi
else
    warn "缺少 scripts/lib/load-deploy-env.sh"
fi

# detect-status.sh now lives in scripts/tools/
_detect_status=""
for _cand in "$SCRIPT_DIR/../tools/detect-status.sh" "$SCRIPT_DIR/detect-status.sh"; do
    [ -f "$_cand" ] && _detect_status="$_cand" && break
done
if [ -n "$_detect_status" ]; then
    log "当前部署进度："
    bash "$_detect_status" 2>/dev/null | sed -n '/Phase/p;/Next step/p;/Verdict/p' || true
    echo ""
fi

# ── 配置（仅来自 deploy.env / 环境变量；无硬编码生产密码）──
PG_USER="${PG_USER:-root}"
PG_PASSWORD="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

if ! require_deploy_secrets; then
    exit 1
fi

# ── 1. 检查基础组件 ─────────────────────────────────────────────
log "检查基础组件（必须来自宝塔，禁止系统 apt/yum 实例）..."

MISSING_COMPONENTS=0

# 若存在冲突清理脚本，先强制 PATH 优先宝塔
if [ -f /etc/profile.d/baota-path.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/baota-path.sh
fi

# 宝塔安装路径自动检测，并永久写入 PATH
BT_PATHS=(
    "/www/server/nginx/sbin"
    "/www/server/pgsql/bin"
    "/www/server/redis/src"
)
PATH_CHANGED=0
for bp in "${BT_PATHS[@]}"; do
    if [ -d "$bp" ] && ! echo "$PATH" | grep -q "$bp"; then
        export PATH="$bp:$PATH"
        PATH_CHANGED=1
    fi
done
# 永久写入 profile.d + bashrc
if [ ! -f /etc/profile.d/baota-path.sh ]; then
    cat > /etc/profile.d/baota-path.sh <<'EOF'
for d in /www/server/nginx/sbin /www/server/pgsql/bin /www/server/redis/src /www/server/panel/pyenv/bin; do
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH
EOF
    ok "已创建 /etc/profile.d/baota-path.sh"
fi
if [ $PATH_CHANGED -eq 1 ]; then
    for bp in "${BT_PATHS[@]}"; do
        if [ -d "$bp" ] && ! grep -q "$bp" /root/.bashrc 2>/dev/null; then
            echo "export PATH=\"$bp:\$PATH\"" >> /root/.bashrc
        fi
    done
    ok "宝塔路径已写入 /root/.bashrc"
fi

# 拒绝系统防火墙与系统自带栈
if systemctl is-active --quiet ufw 2>/dev/null || systemctl is-active --quiet firewalld 2>/dev/null; then
    err "系统防火墙（ufw/firewalld）仍在运行，与宝塔冲突"
    echo "  请执行: bash $(dirname "$0")/lib-clear-conflicts.sh"
    MISSING_COMPONENTS=$((MISSING_COMPONENTS + 1))
fi
for svc in nginx apache2 httpd redis-server mysql mariadb; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        unit_path=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2-)
        if [[ "$unit_path" != /www/* ]]; then
            err "系统服务 $svc 仍在运行 ($unit_path)，会与宝塔抢端口"
            echo "  请执行: bash $(dirname "$0")/lib-clear-conflicts.sh"
            MISSING_COMPONENTS=$((MISSING_COMPONENTS + 1))
        fi
    fi
done

require_baota_bin() {
    local bin="$1" label="$2"
    if ! command -v "$bin" &>/dev/null; then
        err "$label: 未安装或不在 PATH"
        MISSING_COMPONENTS=$((MISSING_COMPONENTS + 1))
        return 1
    fi
    local path
    path=$(command -v "$bin")
    if [[ "$path" != /www/server/* ]]; then
        err "$label: 当前是系统路径 $path（必须用宝塔 /www/server/...）"
        echo "  请执行: bash $(dirname "$0")/lib-clear-conflicts.sh"
        echo "  并确认宝塔软件商店已安装对应组件"
        MISSING_COMPONENTS=$((MISSING_COMPONENTS + 1))
        return 1
    fi
    ok "$label: $path"
    return 0
}

require_baota_bin nginx "Nginx"
require_baota_bin psql "PostgreSQL(psql)"
require_baota_bin redis-cli "Redis(redis-cli)"

check_cmd() {
    if command -v "$1" &>/dev/null; then
        ok "$2: $($1 --version 2>&1 | head -1)"
        return 0
    else
        err "$2: 未安装！"
        MISSING_COMPONENTS=$((MISSING_COMPONENTS + 1))
        return 1
    fi
}

check_cmd python3 "Python3"

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0")
if [ "$PYTHON_VERSION" != "0" ]; then
    PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
    PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)
    if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 11 ]; }; then
        err "Python 版本需要 3.11+，当前: $PYTHON_VERSION"
        MISSING_COMPONENTS=$((MISSING_COMPONENTS + 1))
    else
        ok "Python 版本: $PYTHON_VERSION (>= 3.11)"
    fi
fi

# 检查 Docker 是否已卸载
if command -v docker &>/dev/null; then
    warn "Docker 仍存在！建议先运行 01-cleanup-server.sh"
else
    ok "Docker 已卸载，环境干净"
fi

if [ $MISSING_COMPONENTS -gt 0 ]; then
    echo ""
    err "有 $MISSING_COMPONENTS 个组件未安装，请通过宝塔面板安装："
    echo "  1. 宝塔面板 → 软件商店 → Nginx"
    echo "  2. 宝塔面板 → 软件商店 → PostgreSQL"
    echo "  3. 宝塔面板 → 软件商店 → Redis"
    echo "  4. 宝塔面板 → 软件商店 → Python 项目管理器"
    echo ""
    echo "  安装完成后重新运行此脚本"
    exit 1
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# 2. PostgreSQL 初始化：创建 root 角色 + 数据库
# ═══════════════════════════════════════════════════════════════
log "配置 PostgreSQL..."

# ── 2a. 确认 PostgreSQL 正在运行 ──────────────────────────────
if ! command -v pg_isready &>/dev/null; then
    # 宝塔路径兜底
    PG_BIN="/www/server/pgsql/bin"
    if [ -d "$PG_BIN" ]; then
        export PATH="$PG_BIN:$PATH"
    fi
fi

if command -v pg_isready &>/dev/null; then
    if pg_isready -h "$PG_HOST" -p "$PG_PORT" &>/dev/null; then
        ok "PostgreSQL 服务运行中"
    else
        err "PostgreSQL 未运行！请通过宝塔面板启动 PostgreSQL"
        exit 1
    fi
else
    warn "pg_isready 未找到，跳过运行状态检查"
fi

# ── 2b. 确保 root 角色存在并设置密码 ──────────────────────────
# 宝塔 PostgreSQL 默认超管是 postgres，通过 su 切换操作
log "检查 PostgreSQL 用户 '$PG_USER'..."

# 尝试用密码连接
PG_CONN_OK=0
if PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -c "SELECT 1;" &>/dev/null; then
    ok "用户 '$PG_USER' 密码验证通过"
    PG_CONN_OK=1
else
    warn "用户 '$PG_USER' 不存在或密码不正确，尝试创建..."

    # 检查是否能通过 su - postgres 操作（peer 认证）
    if id postgres &>/dev/null; then
        # 创建 root 超级用户角色
        su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'\"" 2>/dev/null | grep -q 1
        if [ $? -eq 0 ]; then
            # root 角色已存在，只改密码
            su - postgres -c "psql -c \"ALTER USER $PG_USER WITH PASSWORD '$PG_PASSWORD';\"" 2>/dev/null
            ok "用户 '$PG_USER' 密码已更新"
        else
            # 创建 root 超级用户
            su - postgres -c "psql -c \"CREATE USER $PG_USER WITH SUPERUSER PASSWORD '$PG_PASSWORD';\"" 2>/dev/null
            ok "用户 '$PG_USER' 已创建（超级用户）"
        fi

        # 再次验证密码连接
        if PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -c "SELECT 1;" &>/dev/null; then
            ok "用户 '$PG_USER' 密码验证通过"
            PG_CONN_OK=1
        else
            # 密码连接失败，可能是 pg_hba.conf 限制了认证方式
            warn "密码连接失败，可能是 pg_hba.conf 未允许密码认证，尝试自动修复..."

            # ── 自动查找 pg_hba.conf ──────────────────────────────
            PG_HBA=""
            for hba_path in \
                "/www/server/pgsql/data/pg_hba.conf" \
                "/www/server/pgsql/share/pg_hba.conf" \
                "/var/lib/pgsql/data/pg_hba.conf" \
                "/etc/postgresql/*/main/pg_hba.conf" \
                "/etc/postgresql/*/data/pg_hba.conf"; do
                if ls $hba_path 2>/dev/null | head -1 | grep -q .; then
                    PG_HBA=$(ls $hba_path 2>/dev/null | head -1)
                    break
                fi
            done

            # 也可以通过 SQL 查询配置文件位置
            if [ -z "$PG_HBA" ]; then
                PG_HBA=$(su - postgres -c "psql -tAc 'SHOW hba_file'" 2>/dev/null || true)
                PG_HBA=$(echo "$PG_HBA" | xargs)
            fi

            if [ -n "$PG_HBA" ] && [ -f "$PG_HBA" ]; then
                ok "找到 pg_hba.conf: $PG_HBA"

                # 备份
                cp "$PG_HBA" "${PG_HBA}.bak.$(date +%Y%m%d%H%M%S)"

                # 将认证方式改为 md5（允许密码认证）
                # 匹配 host 行：host all all 127.0.0.1/32 和 ::1/128
                sed -i 's/^host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\(peer\|ident\|scram-sha-256\)/host    all    all    127.0.0.1\/32    md5/' "$PG_HBA"
                sed -i 's/^host\s\+all\s\+all\s\+::1\/128\s\+\(peer\|ident\|scram-sha-256\)/host    all    all    ::1\/128    md5/' "$PG_HBA"

                # 如果没有匹配到任何 host 行（新安装的 PG 可能只有 local 行），追加 host 行
                if ! grep -q "^host.*all.*all.*127.0.0.1" "$PG_HBA"; then
                    echo "host    all    all    127.0.0.1/32    md5" >> "$PG_HBA"
                fi
                if ! grep -q "^host.*all.*all.*::1" "$PG_HBA"; then
                    echo "host    all    all    ::1/128       md5" >> "$PG_HBA"
                fi

                ok "pg_hba.conf 已修改（peer → md5）"

                # 重载 PostgreSQL 配置
                log "重载 PostgreSQL 配置..."
                su - postgres -c "psql -c 'SELECT pg_reload_conf();'" 2>/dev/null
                sleep 2

                # 第三次验证
                if PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -c "SELECT 1;" &>/dev/null; then
                    ok "用户 '$PG_USER' 密码验证通过（pg_hba.conf 修复后）"
                    PG_CONN_OK=1
                else
                    err "pg_hba.conf 修改后仍无法连接"
                    warn "请手动检查："
                    echo "  1. 查看配置: cat $PG_HBA"
                    echo "  2. 重载配置: su - postgres -c \"psql -c 'SELECT pg_reload_conf();'\""
                    echo "  3. 重启 PG:  宝塔面板 → PostgreSQL → 重启"
                    exit 1
                fi
            else
                err "未找到 pg_hba.conf，无法自动修复"
                warn "请手动执行："
                echo "  # 查找配置文件"
                echo "  su - postgres -c \"psql -tAc 'SHOW hba_file'\""
                echo "  # 编辑该文件，将 host 行的认证方式改为 md5"
                echo "  # 然后重载: su - postgres -c \"psql -c 'SELECT pg_reload_conf();'\""
                exit 1
            fi
        fi
    else
        err "postgres 系统用户不存在，无法初始化"
        warn "请手动创建 PostgreSQL 用户："
        echo "  su - postgres -c \"psql -c \\\"CREATE USER $PG_USER WITH SUPERUSER PASSWORD '$PG_PASSWORD';\\\"\""
        exit 1
    fi
fi

# ── 2c. 创建数据库 ────────────────────────────────────────────
log "创建数据库..."

# financial-api 数据库
DB_EXISTS=$(PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='quant_zc'" 2>/dev/null || echo "")
if [ "$DB_EXISTS" == "1" ]; then
    ok "数据库 quant_zc 已存在"
else
    PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -c "CREATE DATABASE quant_zc;" 2>/dev/null
    if [ $? -eq 0 ]; then
        ok "数据库 quant_zc 已创建"
    else
        err "数据库 quant_zc 创建失败"
    fi
fi

# QuantDinger 数据库
DB_EXISTS=$(PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='quantdinger'" 2>/dev/null || echo "")
if [ "$DB_EXISTS" == "1" ]; then
    ok "数据库 quantdinger 已存在"
else
    PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -c "CREATE DATABASE quantdinger;" 2>/dev/null
    if [ $? -eq 0 ]; then
        ok "数据库 quantdinger 已创建"
    else
        err "数据库 quantdinger 创建失败"
    fi
fi

# 验证连接
if PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -d quant_zc -c "SELECT 1;" &>/dev/null; then
    ok "quant_zc 连接正常"
else
    err "quant_zc 连接失败"
fi

if PGPASSWORD="$PG_PASSWORD" psql -U "$PG_USER" -h "$PG_HOST" -d quantdinger -c "SELECT 1;" &>/dev/null; then
    ok "quantdinger 连接正常"
else
    err "quantdinger 连接失败"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# 3. Redis 验证
# ═══════════════════════════════════════════════════════════════
log "验证 Redis..."

# 先尝试无密码连接
REDIS_TEST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping 2>/dev/null || echo "FAIL")

if [[ "$REDIS_TEST" == "PONG" ]]; then
    # 无密码就通了，说明 Redis 没设密码
    warn "Redis 无密码即可连接，当前未设密码"
    warn "建议设置密码（后续部署脚本需要密码认证）"

    # 尝试设置密码
    read -rp "  是否现在设置 Redis 密码为 '$REDIS_PASSWORD'？(y/N): " set_redis_pw
    if [[ "$set_redis_pw" == "y" || "$set_redis_pw" == "Y" ]]; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" CONFIG SET requirepass "$REDIS_PASSWORD" 2>/dev/null
        if [ $? -eq 0 ]; then
            ok "Redis 密码已设置"
            # 持久化到配置文件
            REDIS_CONF="/www/server/redis/redis.conf"
            if [ -f "$REDIS_CONF" ]; then
                if grep -q "^requirepass" "$REDIS_CONF"; then
                    sed -i "s|^requirepass .*|requirepass $REDIS_PASSWORD|" "$REDIS_CONF"
                else
                    echo "requirepass $REDIS_PASSWORD" >> "$REDIS_CONF"
                fi
                ok "Redis 配置文件已更新"
            fi
        else
            err "Redis 密码设置失败"
        fi
    fi
else
    # 尝试用密码连接
    REDIS_TEST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" ping 2>/dev/null || echo "FAIL")
    if [[ "$REDIS_TEST" == "PONG" ]]; then
        ok "Redis 连接正常（密码认证通过）"
    else
        err "Redis 连接失败: $REDIS_TEST"
        warn "请检查 Redis 是否已启动，或密码是否正确"
        warn "设置密码: redis-cli CONFIG SET requirepass '$REDIS_PASSWORD'"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# 4. 创建目录结构
# ═══════════════════════════════════════════════════════════════
log "创建目录结构..."

BASE_DIR="/www/wwwroot/project"

mkdir -p "$BASE_DIR/financial/financial-api"
mkdir -p "$BASE_DIR/financial/financial-web"
mkdir -p "$BASE_DIR/official-site"
mkdir -p "$BASE_DIR/deepquant/backend"
mkdir -p "$BASE_DIR/deepquant/web"

ok "目录结构已创建:"
echo "  $BASE_DIR/financial/financial-api/     # financial-api 后端"
echo "  $BASE_DIR/financial/financial-web/      # financial-web 前端"
echo "  $BASE_DIR/official-site/                # official-site 官网"
echo "  $BASE_DIR/deepquant/backend/            # QuantDinger 后端"
echo "  $BASE_DIR/deepquant/web/                # QuantDinger 前端"

echo ""

# ── 5. 创建上传目录 ─────────────────────────────────────────────
log "创建上传目录..."
UPLOAD_DIR="$BASE_DIR/uploads"
mkdir -p "$UPLOAD_DIR"
ok "上传目录: $UPLOAD_DIR"

echo ""

# ── 6. 防火墙检查 ───────────────────────────────────────────────
log "防火墙端口检查..."
for port in 80 443 22; do
    if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        ok "端口 ${port} 已监听"
    else
        warn "端口 ${port} 未监听（Nginx 启动后自动监听 80/443）"
    fi
done

for port in 5000 5001 5432 6379; do
    warn "端口 ${port} 应仅监听 127.0.0.1，不应对外暴露"
done

echo ""
ok "══════════════════════════════════════════"
ok "  Phase 4 环境准备完成！"
ok "══════════════════════════════════════════"
echo ""
echo "  下一步："
echo "    0. bash $SCRIPT_DIR/../tools/detect-status.sh   # 查看总进度"
echo "    1. 本地执行: .\\scripts\\build.ps1 all"
echo "    2. 上传 dist/ 到 $UPLOAD_DIR/（含 deploy.sh）"
echo "    3. 服务器: cd $UPLOAD_DIR/dist && bash deploy.sh all --ip=服务器IP"
echo ""
