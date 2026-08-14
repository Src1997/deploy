#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Phase 1: 环境清理（Docker + 系统防火墙/系统自带 Web&DB）
#
# 合并原 Docker 清理 + 系统冲突清理：
#   A) 卸载 Docker、清旧容器/卷/服务/目录
#   B) 禁用 ufw/firewalld，卸系统 nginx/pg/redis…（宝塔独占）
#
# 用法：
#   bash 01-cleanup-server.sh                 # 全量（按已完成项自动跳过）
#   bash 01-cleanup-server.sh --yes           # 跳过确认
#   bash 01-cleanup-server.sh --docker-only   # 只做 Docker 清理
#   bash 01-cleanup-server.sh --conflicts-only # 只做系统冲突清理
#   bash 01-cleanup-server.sh --check         # 只探测，不修改
#
# 系统冲突清理子模块：bash lib-clear-conflicts.sh（被本脚本自动调用）
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

ASSUME_YES=false
DOCKER_ONLY=false
CONFLICTS_ONLY=false
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y)           ASSUME_YES=true ;;
        --docker-only)      DOCKER_ONLY=true ;;
        --conflicts-only)   CONFLICTS_ONLY=true ;;
        --check)            CHECK_ONLY=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown: $arg (try --help)"; exit 1 ;;
    esac
done

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAS_DOCKER=false
command -v docker &>/dev/null && HAS_DOCKER=true

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Phase 1: 环境清理（Docker + 系统冲突 → 宝塔独占）"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 状态速览 ────────────────────────────────────────────────────
log "当前状态："
if $HAS_DOCKER; then
    warn "  Docker: 仍存在 → 需要清理"
else
    ok "  Docker: 已不存在 → 将跳过 Docker 卸载段"
fi
# detect-status.sh now lives in scripts/tools/
_detect_status=""
for _cand in "$SCRIPT_DIR/../tools/detect-status.sh" "$SCRIPT_DIR/detect-status.sh"; do
    [ -f "$_cand" ] && _detect_status="$_cand" && break
done
if [ -n "$_detect_status" ]; then
    bash "$_detect_status" 2>/dev/null | sed -n '/Phase1 /p' || true
fi

if $CHECK_ONLY; then
    rc=0
    _detect_status=""
    for _cand in "$SCRIPT_DIR/../tools/detect-status.sh" "$SCRIPT_DIR/detect-status.sh"; do
        [ -f "$_cand" ] && _detect_status="$_cand" && break
    done
    if [ -n "$_detect_status" ]; then
        bash "$_detect_status" || rc=$?
    fi
    if [ -f "$SCRIPT_DIR/lib-clear-conflicts.sh" ]; then
        bash "$SCRIPT_DIR/lib-clear-conflicts.sh" --check || rc=$?
    fi
    exit "$rc"
fi

# 仅冲突清理（委托 01b，避免重复实现）
if $CONFLICTS_ONLY; then
    if [ -f "$SCRIPT_DIR/lib-clear-conflicts.sh" ]; then
        args=()
        $ASSUME_YES && args+=(--yes)
        bash "$SCRIPT_DIR/lib-clear-conflicts.sh" "${args[@]}"
        exit $?
    else
        err "缺少 lib-clear-conflicts.sh"
        exit 1
    fi
fi

# ── Docker 段：已清理则跳过 ─────────────────────────────────────
SKIP_DOCKER=false
if ! $HAS_DOCKER; then
    SKIP_DOCKER=true
    ok "检测到 Docker 已卸载，跳过 Docker 清理段"
fi

if ! $SKIP_DOCKER; then
# ── 数据库备份提示 ───────────────────────────────────────────────
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  ⚠️  警告：此脚本将删除所有 Docker 数据！"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  如果 Docker 内有需要保留的数据库数据，请先备份："
echo ""
echo "  # 备份 financial-api 数据库"
echo "  docker exec fin-postgres pg_dump -U quantdinger quant_zc | gzip > /root/backup_fin_\$(date +%Y%m%d).sql.gz"
echo ""
echo "  # 备份 QuantDinger 数据库"
echo "  docker exec quantdinger-db pg_dump -U quantdinger quantdinger | gzip > /root/backup_qd_\$(date +%Y%m%d).sql.gz"
echo ""
if $ASSUME_YES; then
    ok "已指定 --yes，跳过备份确认"
else
    read -rp "  是否已备份或确认不需要备份数据？输入 yes 继续: " confirm_backup
    if [[ "$confirm_backup" != "yes" ]]; then
        echo "  已取消。请先备份数据。"
        exit 0
    fi
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# Step 1: 停止并删除 Docker Compose 项目
# ═══════════════════════════════════════════════════════════════
log "Step 1: 停止并删除 Docker Compose 项目..."

# financial-api Docker Compose
COMPOSE_FILES=(
    "/home/projects/financial/financial-api/docker-compose.prod.yml"
    "/home/projects/financial/financial-api/package/docker-compose.prod.yml"
    "/www/wwwroot/project/financial/financial-api/docker-compose.prod.yml"
    "/www/wwwroot/project/financial/financial-api/package/docker-compose.prod.yml"
)

for cf in "${COMPOSE_FILES[@]}"; do
    if [ -f "$cf" ]; then
        DIR=$(dirname "$cf")
        ENV_FILE="$DIR/.env.docker"
        warn "发现 Compose 文件: $cf"
        if [ -f "$ENV_FILE" ]; then
            docker compose -f "$cf" --env-file "$ENV_FILE" down --remove-orphans -v 2>/dev/null || true
        else
            docker compose -f "$cf" down --remove-orphans -v 2>/dev/null || true
        fi
        ok "已停止: $cf"
    fi
done

# QuantDinger Docker Compose
QD_COMPOSE_FILES=(
    "/home/projects/deepquant/docker-compose.yml"
    "/home/projects/quant-dinger/docker-compose.yml"
    "/www/wwwroot/project/deepquant/docker-compose.yml"
)

for cf in "${QD_COMPOSE_FILES[@]}"; do
    if [ -f "$cf" ]; then
        warn "发现 Compose 文件: $cf"
        docker compose -f "$cf" down --remove-orphans -v 2>/dev/null || true
        ok "已停止: $cf"
    fi
done

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 2: 强制停止并删除所有容器（按名称）
# ═══════════════════════════════════════════════════════════════
log "Step 2: 强制停止并删除所有容器..."

# 所有已知容器名
CONTAINERS=(
    # financial-api 容器
    "fin-nginx" "fin-api" "fin-crawler" "fin-worker" "fin-streaming"
    "fin-postgres" "fin-redis" "fin-api-init"
    # QuantDinger 容器
    "quantdinger-db" "quantdinger-redis" "quantdinger-backend" "quantdinger-frontend"
)

for c in "${CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
        docker rm -f "$c" 2>/dev/null || true
        ok "已删除容器: $c"
    fi
done

# 清理任何残留容器
REMAINING=$(docker ps -aq 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    log "清理残留容器..."
    docker rm -f $REMAINING 2>/dev/null || true
    ok "残留容器已清理"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 3: 删除所有 Docker 卷
# ═══════════════════════════════════════════════════════════════
log "Step 3: 删除所有 Docker 卷..."

# 已知卷名
VOLUMES=(
    "fin_pg_data" "fin_redis_data" "fin_certbot_webroot"
    "postgres_data" "backend_logs" "backend_data"
)

for v in "${VOLUMES[@]}"; do
    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v"; then
        docker volume rm -f "$v" 2>/dev/null || true
        ok "已删除卷: $v"
    fi
done

# 清理所有残留卷
ALL_VOLUMES=$(docker volume ls -q 2>/dev/null || true)
if [ -n "$ALL_VOLUMES" ]; then
    log "清理所有残留卷..."
    docker volume rm -f $ALL_VOLUMES 2>/dev/null || true
    ok "残留卷已清理"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 4: 删除所有 Docker 网络
# ═══════════════════════════════════════════════════════════════
log "Step 4: 删除所有 Docker 网络..."

NETWORKS=(
    "financial-net" "quantdinger-network"
)

for n in "${NETWORKS[@]}"; do
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$n"; then
        docker network rm "$n" 2>/dev/null || true
        ok "已删除网络: $n"
    fi
done

# 清理所有自定义网络（保留 bridge, host, none）
CUSTOM_NETS=$(docker network ls --filter type=custom --format '{{.Name}}' 2>/dev/null || true)
if [ -n "$CUSTOM_NETS" ]; then
    log "清理所有自定义网络..."
    echo "$CUSTOM_NETS" | xargs -r docker network rm 2>/dev/null || true
    ok "自定义网络已清理"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 5: 删除所有 Docker 镜像
# ═══════════════════════════════════════════════════════════════
log "Step 5: 删除所有 Docker 镜像..."

ALL_IMAGES=$(docker images -aq 2>/dev/null || true)
if [ -n "$ALL_IMAGES" ]; then
    docker rmi -f $ALL_IMAGES 2>/dev/null || true
    ok "所有镜像已删除"
else
    ok "无镜像需要删除"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 6: 清理 Docker 构建缓存
# ═══════════════════════════════════════════════════════════════
log "Step 6: 清理 Docker 构建缓存..."

docker builder prune -af 2>/dev/null || true
ok "构建缓存已清理"

# 清理 Docker 系统残留
docker system prune -af --volumes 2>/dev/null || true
ok "Docker 系统残留已清理"

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 7: 停止并禁用旧 systemd 服务
# ═══════════════════════════════════════════════════════════════
log "Step 7: 停止并禁用旧 systemd 服务..."

SERVICES=(
    "financial-api" "financial-crawler" "financial-worker" "financial-streaming"
    "quantdinger-backend" "quantdinger-api"
)

for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "${svc}.service" || \
       [ -f "/etc/systemd/system/${svc}.service" ]; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        ok "${svc} 已停止并移除"
    fi
done

systemctl daemon-reload
ok "systemd 已重载"

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 8: 清理 SSL 自动续期 cron
# ═══════════════════════════════════════════════════════════════
log "Step 8: 清理 SSL 自动续期 cron..."

if crontab -l 2>/dev/null | grep -q "deploy.sh --ssl"; then
    crontab -l 2>/dev/null | grep -v "deploy.sh --ssl" | crontab -
    ok "SSL 续期 cron 已移除"
else
    ok "无 SSL 续期 cron"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 9: 卸载 Docker 引擎
# ═══════════════════════════════════════════════════════════════
log "Step 9: 卸载 Docker 引擎..."

# 停止 Docker 服务
systemctl stop docker docker.socket containerd 2>/dev/null || true
systemctl disable docker docker.socket containerd 2>/dev/null || true
ok "Docker 服务已停止"

# 检测包管理器并卸载
if command -v apt-get &>/dev/null; then
    # Ubuntu / Debian
    log "检测到 apt，卸载 Docker..."
    apt-get remove --purge -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        docker.io docker-doc docker-compose podman-docker 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    ok "Docker 包已卸载 (apt)"

    # 移除 Docker 源
    rm -f /etc/apt/sources.list.d/docker*.list
    rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true
    ok "Docker 源已移除"

elif command -v yum &>/dev/null; then
    # CentOS / RHEL
    log "检测到 yum，卸载 Docker..."
    yum remove -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        docker docker-client docker-client-latest docker-common docker-latest \
        docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
    ok "Docker 包已卸载 (yum)"

    rm -f /etc/yum.repos.d/docker*.repo
elif command -v dnf &>/dev/null; then
    # Fedora
    log "检测到 dnf，卸载 Docker..."
    dnf remove -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    ok "Docker 包已卸载 (dnf)"

    rm -f /etc/yum.repos.d/docker*.repo
else
    warn "无法识别包管理器，请手动卸载 Docker"
fi

# 删除 Docker 数据目录
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
rm -rf /etc/docker
rm -rf /run/docker
rm -rf /var/run/docker
ok "Docker 数据目录已删除"

# 删除残留的二进制文件（apt/yum remove 有时不清理可执行文件）
# 自动搜索所有可能的安装位置，适配不同发行版和安装方式
log "搜索并清理 Docker 残留二进制文件..."

DOCKER_BINS="docker dockerd docker-compose containerd containerd-shim containerd-shim-runc-v2 runc docker-init docker-proxy"

for bin_name in $DOCKER_BINS; do
    # 方法 1: command -v 查找当前 PATH 中的位置
    found_path=$(command -v "$bin_name" 2>/dev/null || true)
    if [ -n "$found_path" ] && [ -f "$found_path" ]; then
        rm -f "$found_path"
        ok "已删除: $found_path"
    fi

    # 方法 2: 遍历常见安装目录（覆盖 snap/bin/usr-bin/usr-local/sbin 等）
    for dir in /usr/bin /usr/local/bin /usr/sbin /usr/local/sbin /snap/bin /opt/bin /opt/docker/bin; do
        target="$dir/$bin_name"
        if [ -f "$target" ]; then
            rm -f "$target"
            ok "已删除: $target"
        fi
    done

    # 方法 3: find 兜底搜索（仅在上述方法未找到时触发，限制深度避免超时）
    remaining=$(command -v "$bin_name" 2>/dev/null || true)
    if [ -n "$remaining" ]; then
        find /usr /opt /snap -name "$bin_name" -type f -executable 2>/dev/null | while read -r f; do
            rm -f "$f"
            ok "已删除 (find): $f"
        done
    fi
done

ok "Docker 残留二进制文件已清理"

# 清理 Docker socket 和 PID 文件
rm -f /var/run/docker.sock /var/run/docker.pid /run/docker.sock /run/docker.pid

# 刷新 shell 命令缓存（让 bash 忘记旧路径）
hash -r 2>/dev/null || true

# 验证卸载
STILL_EXISTS=$(command -v docker 2>/dev/null || true)
if [ -n "$STILL_EXISTS" ]; then
    warn "Docker 命令仍存在（路径: $STILL_EXISTS）"
    warn "请手动删除: rm -f $STILL_EXISTS"
else
    ok "Docker 引擎已完全卸载"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 10: 清理旧部署目录
# ═══════════════════════════════════════════════════════════════
log "Step 10: 清理旧部署目录..."

DIRS_TO_CLEAN=(
    "/home/projects/financial"
    "/home/projects/deepquant"
    "/home/projects/quant-dinger"
    "/home/projects/quant-explained"
    "/home/nginx"
    "/home/logs"
    "/home/backup_*.sql.gz"
)

echo "  以下目录将被删除："
for dir in "${DIRS_TO_CLEAN[@]}"; do
    if [ -e "$dir" ] || ls $dir 2>/dev/null | grep -q .; then
        echo "    - $dir"
    fi
done
echo ""

read -rp "  确认删除以上目录？输入 yes 继续: " confirm_dirs
if [[ "$confirm_dirs" == "yes" ]]; then
    for dir in "${DIRS_TO_CLEAN[@]}"; do
        rm -rf $dir 2>/dev/null || true
    done
    ok "旧部署目录已清理"
else
    warn "跳过目录清理，请手动删除"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 11: 清理宝塔旧 Nginx 配置
# ═══════════════════════════════════════════════════════════════
log "Step 11: 检查宝塔旧 Nginx 配置..."

BT_NGINX_DIR="/www/server/panel/vhost/nginx"
if [ -d "$BT_NGINX_DIR" ]; then
    OLD_CONFS=$(find "$BT_NGINX_DIR" -name "*.conf" -exec grep -l "financial\|quantdinger\|deepquant\|fin-api\|fin-nginx" {} \; 2>/dev/null || true)
    if [ -n "$OLD_CONFS" ]; then
        echo "  发现旧 Nginx 配置："
        echo "$OLD_CONFS" | while read -r f; do
            echo "    - $f"
        done
        echo ""
        read -rp "  是否删除这些旧 Nginx 配置？(yes/no): " confirm_nginx
        if [[ "$confirm_nginx" == "yes" ]]; then
            echo "$OLD_CONFS" | while read -r f; do
                rm -f "$f"
                ok "已删除: $f"
            done
        else
            warn "保留旧 Nginx 配置，稍后手动清理"
        fi
    else
        ok "无旧 Nginx 配置"
    fi
else
    ok "宝塔 Nginx 配置目录不存在"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# Step 12: 端口占用检查
# ═══════════════════════════════════════════════════════════════
log "Step 12: 端口占用检查..."

PORTS_TO_CHECK=(80 443 5000 5001 5432 6379 8080 8888)
OCCUPIED=false

for port in "${PORTS_TO_CHECK[@]}"; do
    PID=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v "^State" | awk '{print $NF}' | head -1 || true)
    if [ -n "$PID" ]; then
        warn "端口 ${port} 被占用: ${PID}"
        OCCUPIED=true
    fi
done

if ! $OCCUPIED; then
    ok "所有关键端口空闲"
fi

echo ""

fi  # end ! SKIP_DOCKER

# ═══════════════════════════════════════════════════════════════
# Step 13: 系统冲突清理（子模块 lib-clear-conflicts.sh）
# ═══════════════════════════════════════════════════════════════
if ! $DOCKER_ONLY; then
    log "Step 13: 清除系统防火墙 / 系统自带 Web&DB（宝塔独占）..."
    if [ -f "$SCRIPT_DIR/lib-clear-conflicts.sh" ]; then
        args=()
        $ASSUME_YES && args+=(--yes)
        # 若已干净，子模块会快速退出
        bash "$SCRIPT_DIR/lib-clear-conflicts.sh" "${args[@]}" || warn "冲突清理有警告，可用 --check 复查"
    else
        warn "缺少 lib-clear-conflicts.sh，跳过系统冲突清理"
    fi
else
    ok "已指定 --docker-only，跳过系统冲突清理"
fi

# ═══════════════════════════════════════════════════════════════
# 汇总
# ═══════════════════════════════════════════════════════════════
echo ""
ok "═══════════════════════════════════════════════════════════"
ok "  Phase 1 完成（Docker + 系统冲突）"
ok "═══════════════════════════════════════════════════════════"
echo ""
if $SKIP_DOCKER; then
    echo "  Docker 段: 已跳过（本机无 Docker）"
else
    echo "  Docker 段: 已执行卸载/清理"
fi
if ! $DOCKER_ONLY; then
    echo "  冲突段: 系统防火墙/系统 Web&DB → 宝塔独占"
fi
echo ""

if ${OCCUPIED:-false}; then
    warn "  有端口仍被占用，请检查："
    echo "    ss -tlnp | grep -E ':80|:443|:5000|:5001|:5432|:6379'"
    echo ""
fi

echo "  查看总进度："
echo "    bash $SCRIPT_DIR/../tools/detect-status.sh"
echo ""
echo "  下一步："
echo "    1. bash 02-install-baota.sh          # 若宝塔未装"
echo "    2. 宝塔软件商店：Nginx / PostgreSQL / Redis / Python"
echo "    3. 宝塔安全：放行 22/80/443/面板端口（勿放 5432/6379）"
echo "    4. bash 03-check-components.sh       # 组件装完后检查"
echo "    5. bash 04-setup-server.sh"
echo "    6. 本地 build.ps1 → 上传 → bash deploy.sh all"
echo ""
