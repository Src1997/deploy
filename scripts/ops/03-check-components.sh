#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# 03-check-components.sh — 检查宝塔组件安装状态
#
# Phase 3: 纯检查脚本，验证 Nginx / PostgreSQL / Redis / Python 是否
#          全部通过宝塔面板安装完成。不安装任何东西，只检查+报告。
#
# 用法：
#   bash 03-check-components.sh           # 检查，未通过则退出 1
#   bash 03-check-components.sh --wait    # 循环等待，每 30 秒检查一次
#                                        # 直到全部通过或用户 Ctrl+C
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail

WAIT_MODE=false
for arg in "$@"; do
    case "$arg" in
        --wait) WAIT_MODE=true ;;
        --help|-h)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown: $arg (try --help)"; exit 1 ;;
    esac
done

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

# ── 确保 PATH 包含宝塔路径 ──────────────────────────────────────
if [ -f /etc/profile.d/baota-path.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/baota-path.sh
fi

# 宝塔安装路径自动检测
BT_PATHS=(
    "/www/server/nginx/sbin"
    "/www/server/pgsql/bin"
    "/www/server/redis/src"
)
for bp in "${BT_PATHS[@]}"; do
    if [ -d "$bp" ] && ! echo "$PATH" | grep -q "$bp"; then
        export PATH="$bp:$PATH"
    fi
done

# ═══════════════════════════════════════════════════════════════
# 检查函数
# ═══════════════════════════════════════════════════════════════

MISSING=0

check_nginx() {
    local bin="/www/server/nginx/sbin/nginx"
    if [ -x "$bin" ]; then
        local ver
        ver=$("$bin" -v 2>&1 | head -1)
        ok "Nginx: $ver"
        return 0
    else
        err "Nginx: 未安装"
        MISSING=$((MISSING + 1))
        return 1
    fi
}

check_postgresql() {
    local bin="/www/server/pgsql/bin/psql"
    if [ -x "$bin" ]; then
        local ver
        ver=$("$bin" --version 2>&1 | head -1)
        ok "PostgreSQL: $ver"

        # 检查服务是否运行
        if /www/server/pgsql/bin/pg_isready -h 127.0.0.1 -p 5432 &>/dev/null 2>&1; then
            ok "PostgreSQL 服务运行中"
        else
            warn "PostgreSQL 已安装但服务未运行，请在宝塔面板启动"
            MISSING=$((MISSING + 1))
        fi
        return 0
    else
        err "PostgreSQL: 未安装"
        MISSING=$((MISSING + 1))
        return 1
    fi
}

check_redis() {
    local bin="/www/server/redis/src/redis-cli"
    if [ -x "$bin" ]; then
        local ver
        ver=$("$bin" --version 2>&1 | head -1)
        ok "Redis: $ver"

        # 检查服务是否运行（尝试无密码 + 有密码）
        local ping_result
        ping_result=$("$bin" -h 127.0.0.1 -p 6379 ping 2>/dev/null || echo "FAIL")
        if [ "$ping_result" = "PONG" ]; then
            warn "Redis 运行中但未设密码（建议在宝塔面板设置密码）"
        else
            # 尝试从 deploy.env 读取密码
            local redis_pw=""
            if [ -f "$(dirname "$0")/../deploy.env" ]; then
                redis_pw=$(grep '^REDIS_PASSWORD=' "$(dirname "$0")/../deploy.env" 2>/dev/null | cut -d= -f2- || true)
            fi
            if [ -n "$redis_pw" ]; then
                ping_result=$("$bin" -h 127.0.0.1 -p 6379 -a "$redis_pw" ping 2>/dev/null || echo "FAIL")
                if [ "$ping_result" = "PONG" ]; then
                    ok "Redis 服务运行中（密码认证通过）"
                else
                    warn "Redis 已安装但连接失败，请检查服务是否启动"
                    MISSING=$((MISSING + 1))
                fi
            else
                warn "Redis 已安装但无法连接，请检查服务是否启动"
                MISSING=$((MISSING + 1))
            fi
        fi
        return 0
    else
        err "Redis: 未安装"
        MISSING=$((MISSING + 1))
        return 1
    fi
}

check_python() {
    # Python 可以是系统自带的或宝塔安装的
    if command -v python3 &>/dev/null; then
        local ver
        ver=$(python3 --version 2>&1)
        local major minor
        major=$(python3 -c 'import sys; print(sys.version_info.major)' 2>/dev/null || echo 0)
        minor=$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)

        if [ "$major" -ge 3 ] && [ "$minor" -ge 11 ]; then
            ok "Python: $ver (>= 3.11)"
        else
            err "Python: $ver (需要 3.11+，请安装 Python 项目管理器)"
            MISSING=$((MISSING + 1))
        fi
    else
        err "Python3: 未安装"
        MISSING=$((MISSING + 1))
    fi
}

check_baota_panel() {
    if [ -f "/etc/init.d/bt" ] || [ -d "/www/server/panel" ]; then
        ok "宝塔面板: 已安装"
    else
        err "宝塔面板: 未安装（请先运行 02-install-baota.sh）"
        MISSING=$((MISSING + 1))
    fi
}

check_firewall() {
    if systemctl is-active --quiet ufw 2>/dev/null; then
        warn "UFW 仍在运行（应禁用，改用宝塔安全）"
    else
        ok "UFW: 未运行"
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "firewalld 仍在运行（应禁用，改用宝塔安全）"
    else
        ok "firewalld: 未运行"
    fi
}

check_docker() {
    if command -v docker &>/dev/null; then
        warn "Docker 仍存在（建议运行 01-cleanup-server.sh 清理）"
    else
        ok "Docker: 已卸载"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 输出未安装组件的安装指引
# ═══════════════════════════════════════════════════════════════
print_install_guide() {
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  以下组件未安装或未就绪，请在宝塔面板手动安装           │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""

    # 检查宝塔面板地址
    local panel_url=""
    if command -v bt &>/dev/null; then
        panel_url=$(bt default 2>/dev/null | grep -oP 'https?://[^ ]+' | head -1 || true)
    fi

    if [ -n "$panel_url" ]; then
        echo "  宝塔面板地址: $panel_url"
        echo ""
    fi

    echo "  ── 安装步骤 ──"
    echo ""
    echo "  1. 浏览器登录宝塔面板"
    echo "  2. 左侧菜单 → 软件商店"
    echo ""

    # Nginx
    if [ ! -x "/www/server/nginx/sbin/nginx" ]; then
        echo "  [缺失] Nginx"
        echo "    → 软件商店 → 搜索 Nginx → 安装（稳定版）"
        echo ""
    fi

    # PostgreSQL
    if [ ! -x "/www/server/pgsql/bin/psql" ]; then
        echo "  [缺失] PostgreSQL"
        echo "    → 软件商店 → 搜索 PostgreSQL 管理器 → 安装"
        echo "    → 安装完成后进入管理器 → 版本管理 → 安装 PostgreSQL 16.x"
        echo "    → 密码管理 → 设置 root 用户密码（与 deploy.env 中 PG_PASSWORD 一致）"
        echo ""
    fi

    # Redis
    if [ ! -x "/www/server/redis/src/redis-cli" ]; then
        echo "  [缺失] Redis"
        echo "    → 软件商店 → 搜索 Redis → 安装"
        echo "    → 安装完成后设置密码（与 deploy.env 中 REDIS_PASSWORD 一致）"
        echo ""
    fi

    # Python
    if ! command -v python3 &>/dev/null; then
        echo "  [缺失] Python 3.11+"
        echo "    → 软件商店 → 搜索 Python 项目管理器 → 安装"
        echo ""
    fi

    echo "  ── 安全设置 ──"
    echo ""
    echo "  宝塔面板 → 安全 → 放行端口："
    echo "    22 (SSH)  80 (HTTP)  443 (HTTPS)  面板端口"
    echo "  不要放行: 5432 (PostgreSQL)  6379 (Redis)"
    echo ""
    echo "  ────────────────────────────────────────────────────────────"
    echo "  安装完成后重新运行: bash 03-check-components.sh"
    echo "  ────────────────────────────────────────────────────────────"
}

# ═══════════════════════════════════════════════════════════════
# 主逻辑
# ═══════════════════════════════════════════════════════════════

run_checks() {
    MISSING=0
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  检查宝塔组件安装状态"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    check_baota_panel
    check_nginx
    check_postgresql
    check_redis
    check_python
    check_firewall
    check_docker

    echo ""
    echo "────────────────────────────────────────────────"
    if [ "$MISSING" -eq 0 ]; then
        ok "所有组件已安装且就绪！($MISSING 个问题)"
        echo "────────────────────────────────────────────────"
        echo ""
        echo "  下一步: bash 04-setup-server.sh"
        echo ""
        return 0
    else
        err "有 $MISSING 个组件未安装或未就绪"
        echo "────────────────────────────────────────────────"
        print_install_guide
        return 1
    fi
}

if $WAIT_MODE; then
    # --wait 模式：循环检查直到通过
    while true; do
        if run_checks; then
            exit 0
        fi
        echo ""
        log "30 秒后重新检查... (Ctrl+C 退出)"
        sleep 30
    done
else
    # 默认模式：检查一次
    run_checks
    exit $?
fi
