#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Phase 5: Supervisor 进程守护 + 基础设施开机自启
#
# 用途：
#   1. 为所有 Python 后端项目创建 Supervisor 进程守护配置
#   2. 配置 Nginx / Redis / PostgreSQL 开机自启（init.d → systemd）
#   3. 清理旧的 systemd unit 文件（避免与 Supervisor 冲突）
#
# 前提条件：
#   - 宝塔面板已安装（02-install-baota.sh）
#   - Nginx / PostgreSQL / Redis / Python / Supervisor 已通过宝塔安装
#   - 组件检查通过（03-check-components.sh）
#   - 数据库和目录已创建（04-setup-server.sh）
#
# 用法：
#   bash 05-setup-supervisor.sh              # 配置全部
#   bash 05-setup-supervisor.sh --check      # 仅检查状态
#   bash 05-setup-supervisor.sh --infra      # 仅配置基础设施开机自启
#   bash 05-setup-supervisor.sh --projects   # 仅配置项目进程守护
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail

# -- Mode --
MODE="all"
for arg in "$@"; do
    case "$arg" in
        --check)    MODE="check" ;;
        --infra)    MODE="infra" ;;
        --projects) MODE="projects" ;;
        --help|-h)  sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown: $arg (try --help)"; exit 1 ;;
    esac
done

# -- Helpers --
log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

# -- Ensure PATH includes BaoTa binaries --
if [ -f /etc/profile.d/baota-path.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/baota-path.sh
fi
for bp in /www/server/nginx/sbin /www/server/pgsql/bin /www/server/redis/src; do
    [ -d "$bp" ] && ! echo "$PATH" | grep -q "$bp" && export PATH="$bp:$PATH"
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Phase 5: Supervisor 进程守护 + 开机自启"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════
# 0. Preflight: must be root + Supervisor installed
# ═══════════════════════════════════════════════════════════════
if [ "$(id -u)" -ne 0 ]; then
    err "必须以 root 用户运行此脚本"
    exit 1
fi

# Detect Supervisor paths
SV_DIR="/www/server/panel/plugin/supervisor"
SV_BIN=""
SV_CTL=""
SV_CONF_DIR=""

if [ -x "${SV_DIR}/bin/supervisord" ]; then
    SV_BIN="${SV_DIR}/bin/supervisord"
    SV_CTL="${SV_DIR}/bin/supervisorctl"
    SV_CONF_DIR="${SV_DIR}/conf"
elif command -v supervisord &>/dev/null; then
    SV_BIN=$(command -v supervisord)
    SV_CTL=$(command -v supervisorctl 2>/dev/null || echo "")
    SV_CONF_DIR="/etc/supervisor/conf.d"
else
    err "Supervisor 未安装！请先在宝塔面板 → 软件商店 → 搜索 Supervisor → 安装"
    exit 1
fi
ok "Supervisor binary: $SV_BIN"

# Ensure conf dir exists
mkdir -p "$SV_CONF_DIR" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# Project definitions
# ═══════════════════════════════════════════════════════════════

# -- financial-api --
FA_DIR="/www/wwwroot/project/financial/financial-api/package"
FA_VENV="${FA_DIR}/.venv/bin"

# -- deepquant backend --
DQ_DIR="/www/wwwroot/project/deepquant/backend/package"
DQ_VENV="${DQ_DIR}/.venv/bin"

# -- Project registry: name|workdir|command|env_vars|port --
# Format: name|workdir|command|environment_vars
PROJECTS=(
    "financial-api|${FA_DIR}|${FA_VENV}/uvicorn app.main:app --host 127.0.0.1 --port 5001 --no-access-log|APP_ROLE=api"
    "financial-crawler|${FA_DIR}|${FA_VENV}/python -m app.crawler scheduler|APP_ROLE=crawler,CRAWLER_ENABLED=true,CRAWLER_ENQUEUE_ENABLED=true"
    "financial-streaming|${FA_DIR}|${FA_VENV}/python -m worker.streaming|APP_ROLE=crawler,CRAWLER_ENABLED=true"
    "financial-worker|${FA_DIR}|${FA_VENV}/arq worker.settings.WorkerSettings|APP_ROLE=crawler,CRAWLER_ENABLED=true"
    "quantdinger-backend|${DQ_DIR}|${DQ_VENV}/gunicorn -c gunicorn_config.py run:app|"
    "quantdinger-mcp|${DQ_DIR}|${DQ_VENV}/python -m quantdinger_mcp.server|"
)

# ═══════════════════════════════════════════════════════════════
# 1. Configure infrastructure autostart (Nginx / Redis / PostgreSQL)
# ═══════════════════════════════════════════════════════════════
setup_infra_autostart() {
    echo ""
    echo "── 1. 基础设施开机自启 ──"
    echo ""

    # -- 1a. Nginx: enable init.d autostart --
    log "配置 Nginx 开机自启..."
    if [ -f /etc/init.d/nginx ]; then
        # Prefer BaoTa's built-in autostart mechanism
        # update-rc.d registers init.d script into rc*.d
        update-rc.d nginx defaults 2>/dev/null || true
        ok "Nginx 开机自启已配置 (init.d → rc.d)"
    else
        err "Nginx init.d 脚本不存在"
    fi

    # -- 1b. Redis: enable init.d autostart --
    log "配置 Redis 开机自启..."
    if [ -f /etc/init.d/redis ]; then
        update-rc.d redis defaults 2>/dev/null || true
        ok "Redis 开机自启已配置 (init.d → rc.d)"
    else
        err "Redis init.d 脚本不存在"
    fi

    # -- 1c. PostgreSQL: enable init.d autostart --
    log "配置 PostgreSQL 开机自启..."
    if [ -f /etc/init.d/pgsql ]; then
        update-rc.d pgsql defaults 2>/dev/null || true
        ok "PostgreSQL 开机自启已配置 (init.d → rc.d)"
    else
        err "PostgreSQL init.d 脚本不存在"
    fi

    # -- 1d. Verify init.d symlinks --
    echo ""
    log "验证开机自启注册..."
    local infra_ok=0
    for svc in nginx redis pgsql; do
        local found
        found=$(ls /etc/rc*.d/S*${svc} 2>/dev/null | wc -l || echo 0)
        if [ "$found" -gt 0 ]; then
            ok "${svc}: ${found} 个 rc.d 符号链接"
            infra_ok=$((infra_ok + 1))
        else
            warn "${svc}: 未找到 rc.d 符号链接"
        fi
    done
    echo ""
    if [ "$infra_ok" -eq 3 ]; then
        ok "基础设施开机自启全部就绪"
    else
        warn "有 $((3 - infra_ok)) 个基础设施服务未配置成功"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 2. Create Supervisor config for each project
# ═══════════════════════════════════════════════════════════════
write_supervisor_conf() {
    local name="$1" workdir="$2" command="$3" env_vars="$4"
    local conf_file="${SV_CONF_DIR}/${name}.conf"
    local log_dir="/www/server/panel/plugin/supervisor/log/${name}"

    # Use /var/log/supervisor as fallback for non-BaoTa installs
    if [[ "$SV_CONF_DIR" == "/etc/supervisor/conf.d" ]]; then
        log_dir="/var/log/supervisor/${name}"
    fi
    mkdir -p "$log_dir" 2>/dev/null || true

    # Build Environment lines
    local env_lines=""
    if [ -n "$env_vars" ]; then
        IFS=',' read -ra envs <<< "$env_vars"
        for e in "${envs[@]}"; do
            env_lines="${env_lines}Environment=${e}\n"
        done
    fi

    # Write INI config (printf to preserve \n)
    # shellcheck disable=SC2059
    printf "[program:${name}]\n\
command=${command}\n\
directory=${workdir}\n\
user=root\n\
autostart=true\n\
autorestart=true\n\
startsecs=5\n\
startretries=3\n\
stopwaitsecs=15\n\
${env_lines}\
stdout_logfile=${log_dir}/stdout.log\n\
stdout_logfile_maxbytes=20MB\n\
stdout_logfile_backups=5\n\
stderr_logfile=${log_dir}/stderr.log\n\
stderr_logfile_maxbytes=20MB\n\
stderr_logfile_backups=5\n\
" > "$conf_file"

    ok "写入 ${conf_file}"
}

# ═══════════════════════════════════════════════════════════════
# 3. Clean up old systemd unit files (replaced by Supervisor)
# ═══════════════════════════════════════════════════════════════
cleanup_systemd_units() {
    echo ""
    echo "── 3. 清理旧 systemd unit 文件 ──"
    echo ""

    local old_units=(
        "financial-api"
        "financial-crawler"
        "financial-streaming"
        "financial-worker"
        "quantdinger-backend"
        "quantdinger-mcp"
    )

    for svc in "${old_units[@]}"; do
        local unit_file="/etc/systemd/system/${svc}.service"
        if [ -f "$unit_file" ]; then
            log "停止并禁用 ${svc}.service..."
            systemctl stop "${svc}.service" 2>/dev/null || true
            systemctl disable "${svc}.service" 2>/dev/null || true
            rm -f "$unit_file"
            ok "已删除 ${unit_file}"
        fi
    done

    systemctl daemon-reload 2>/dev/null || true
    ok "systemd daemon-reload 完成"
}

# ═══════════════════════════════════════════════════════════════
# 4. Reload Supervisor and start all projects
# ═══════════════════════════════════════════════════════════════
reload_supervisor() {
    echo ""
    echo "── 4. 重载 Supervisor 并启动进程 ──"
    echo ""

    # Ensure supervisord is running
    if ! pgrep -f supervisord &>/dev/null 2>&1; then
        log "启动 supervisord..."
        "$SV_BIN" -c "${SV_DIR}/supervisord.conf" 2>/dev/null || \
        "$SV_BIN" 2>/dev/null || true
        sleep 2
        if pgrep -f supervisord &>/dev/null 2>&1; then
            ok "supervisord 已启动"
        else
            err "supervisord 启动失败，请检查宝塔 Supervisor 插件"
            return 1
        fi
    else
        ok "supervisord 已在运行"
    fi

    # Reload config
    log "重载 Supervisor 配置..."
    "$SV_CTL" reread 2>/dev/null || true
    "$SV_CTL" update 2>/dev/null || true

    # Start all project programs
    for entry in "${PROJECTS[@]}"; do
        IFS='|' read -r name _ _ _ <<< "$entry"
        log "启动 ${name}..."
        "$SV_CTL" start "$name" 2>/dev/null || true
    done
}

# ═══════════════════════════════════════════════════════════════
# 5. Verify all services
# ═══════════════════════════════════════════════════════════════
verify_status() {
    echo ""
    echo "── 5. 验证服务状态 ──"
    echo ""

    # -- Infrastructure --
    echo "  [基础设施]"
    for svc in nginx redis pgsql; do
        local status
        if /etc/init.d/$svc status &>/dev/null 2>&1; then
            status="running"
        elif pgrep -f "$svc" &>/dev/null 2>&1; then
            status="running"
        else
            status="stopped"
        fi
        printf "  %-22s %s\n" "$svc" "$status"
    done

    # -- Supervisor managed --
    echo ""
    echo "  [Supervisor 进程]"
    if [ -n "$SV_CTL" ]; then
        "$SV_CTL" status 2>/dev/null || warn "supervisorctl status 失败"
    else
        warn "supervisorctl 不可用"
    fi

    # -- Port check --
    echo ""
    echo "  [端口监听]"
    ss -tlnp | grep -E ':80 |:5432 |:6379 |:5001|:5000|:7800' 2>/dev/null || warn "未找到预期端口"

    # -- API health --
    echo ""
    echo "  [API 健康]"
    local api_ok
    api_ok=$(curl -sf --max-time 5 http://127.0.0.1/api/ 2>/dev/null | head -c 80 || echo "FAIL")
    if [ "$api_ok" != "FAIL" ]; then
        ok "financial-api: $api_ok"
    else
        warn "financial-api: 健康检查失败"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

case "$MODE" in
    check)
        verify_status
        ;;
    infra)
        setup_infra_autostart
        ;;
    projects)
        # Write Supervisor config files
        echo ""
        echo "── 2. 写入 Supervisor 进程配置 ──"
        echo ""
        for entry in "${PROJECTS[@]}"; do
            IFS='|' read -r name workdir command env_vars <<< "$entry"
            log "配置 ${name}..."
            write_supervisor_conf "$name" "$workdir" "$command" "$env_vars"
        done
        cleanup_systemd_units
        reload_supervisor
        verify_status
        ;;
    all)
        setup_infra_autostart

        # Write Supervisor config files
        echo ""
        echo "── 2. 写入 Supervisor 进程配置 ──"
        echo ""
        for entry in "${PROJECTS[@]}"; do
            IFS='|' read -r name workdir command env_vars <<< "$entry"
            log "配置 ${name}..."
            write_supervisor_conf "$name" "$workdir" "$command" "$env_vars"
        done

        cleanup_systemd_units
        reload_supervisor
        verify_status
        ;;
esac

echo ""
ok "════════════════════════════════════════════"
ok "  Phase 5 配置完成！"
ok "════════════════════════════════════════════"
echo ""
echo "  常用命令："
echo "    查看状态:   bash 05-setup-supervisor.sh --check"
echo "    重启进程:   ${SV_CTL} restart <name>"
echo "    查看日志:   ${SV_CTL} tail -f <name>"
echo "    查看所有:   ${SV_CTL} status"
echo ""
echo "  宝塔面板 → Supervisor 管理器 可图形化管理所有进程"
echo ""
