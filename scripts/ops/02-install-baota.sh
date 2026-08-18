#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Phase 2: 安装宝塔面板（必须在环境清理之后执行）
#
# 用途：在干净的 Linux 服务器上安装宝塔面板（Linux 面板版）
# 执行：SSH 到服务器后运行  bash 02-install-baota.sh
#
# 前提：已运行 01-cleanup-server.sh 彻底卸载 Docker
#
# 安装完成后会输出面板地址、用户名、密码，请妥善保存
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# 专用临时目录，禁止向 /tmp 顶层散落文件
mkdir -p /tmp/fin-deploy

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Phase 2: 安装宝塔面板"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 0. 前置检查 ─────────────────────────────────────────────────
log "检查运行环境..."

# 必须是 root
if [ "$(id -u)" -ne 0 ]; then
    err "必须以 root 用户运行此脚本"
    echo "  请切换到 root: su - 或 sudo -i"
    exit 1
fi
ok "root 用户"

# 检查是否已安装宝塔
if [ -f "/etc/init.d/bt" ] || [ -d "/www/server/panel" ]; then
    warn "检测到宝塔面板已安装！"
    echo ""
    echo "  查看面板信息："
    echo "    bt default"
    echo ""
    echo "  如需重新安装，先卸载："
    echo "    /etc/init.d/bt stop && rm -rf /www/server/panel"
    echo ""
    read -rp "  是否跳过安装？(Y/n): " skip
    if [[ "$skip" != "n" && "$skip" != "N" ]]; then
        ok "跳过宝塔安装"
        exit 0
    fi
fi

# 确认 Docker 已卸载
if command -v docker &>/dev/null; then
err "Docker 仍存在！请先运行 01-cleanup-server.sh 彻底卸载 Docker"
echo "  bash 01-cleanup-server.sh"
    exit 1
fi
ok "Docker 已卸载，环境干净"

# 提示：Phase 1（Docker + 系统冲突）是否已完成
echo ""
log "检查 Phase 1 是否已完成..."
NEED_PHASE1=false
if command -v docker &>/dev/null; then
    warn "Docker 仍存在 → 需要先跑 01-cleanup-server.sh"
    NEED_PHASE1=true
fi
if [ -f "$(dirname "$0")/lib-clear-conflicts.sh" ]; then
if ! bash "$(dirname "$0")/lib-clear-conflicts.sh" --check >"/tmp/fin-deploy/bt-conflict-check.txt" 2>&1; then
warn "仍有系统防火墙/系统库冲突 → 建议先跑 01-cleanup-server.sh（已含冲突清理）"
        NEED_PHASE1=true
        grep -E '\[!\]|发现问题' "/tmp/fin-deploy/bt-conflict-check.txt" 2>/dev/null | head -15 || true
    else
        ok "系统冲突检查通过"
    fi
fi
if $NEED_PHASE1; then
    echo "  bash $(dirname "$0")/01-cleanup-server.sh"
    read -rp "  仍要继续安装宝塔？(y/N): " cont
    if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
        exit 1
    fi
fi

# 检查端口 80 是否空闲
PORT_80_PID=$(ss -tlnp "sport = :80" 2>/dev/null | grep -v "^State" | awk '{print $NF}' | head -1 || true)
if [ -n "$PORT_80_PID" ]; then
    warn "端口 80 被占用: ${PORT_80_PID}"
    echo "  请先停止占用 80 端口的服务，再继续安装"
    echo "  查看占用进程: ss -tlnp 'sport = :80'"
    read -rp "  是否继续安装？(y/N): " continue_80
    if [[ "$continue_80" != "y" && "$continue_80" != "Y" ]]; then
        echo "  已取消。请先释放 80 端口。"
        exit 1
    fi
else
    ok "端口 80 空闲，宝塔 Nginx 可正常安装"
fi

echo ""

# ── 1. 检测操作系统 ─────────────────────────────────────────────
log "检测操作系统..."

OS_ID=""
OS_VERSION=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
    ok "系统: $PRETTY_NAME"
elif [ -f /etc/redhat-release ]; then
    OS_ID="centos"
    OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    ok "系统: $(cat /etc/redhat-release)"
else
    err "无法识别操作系统"
    echo "  宝塔支持: CentOS 7+ / Ubuntu 18+ / Debian 10+"
    exit 1
fi

# 检查系统是否受支持
case "$OS_ID" in
    centos|rhel|rocky|almalinux|ol)
        ok "包管理器: yum/dnf"
        PKG_MANAGER="yum"
        ;;
    ubuntu|debian)
        ok "包管理器: apt"
        PKG_MANAGER="apt"
        ;;
    *)
        warn "未测试的系统: $OS_ID，将尝试通用安装"
        PKG_MANAGER="unknown"
        ;;
esac

echo ""

# ── 2. 安装基础依赖 ─────────────────────────────────────────────
log "安装基础依赖..."

case "$PKG_MANAGER" in
    yum)
        yum install -y curl wget python3 2>/dev/null || true
        ;;
    apt)
        apt-get update -qq 2>/dev/null || true
        apt-get install -y curl wget python3 2>/dev/null || true
        ;;
esac
ok "基础依赖已就绪"

echo ""

# ── 3. 下载并安装宝塔面板 ───────────────────────────────────────
log "开始安装宝塔面板..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  宝塔面板安装说明                                        │"
echo "  │                                                          │"
echo "  │  1. 安装过程约 2-5 分钟，取决于服务器配置和网络           │"
echo "  │  2. 安装过程中会提示确认，输入 y 继续                    │"
echo "  │  3. 安装完成后会显示面板地址、用户名、密码               │"
echo "  │  4. 请务必保存面板登录信息                               │"
echo "  │                                                          │"
echo "  │  如使用云服务器，需在安全组放行面板端口（默认 8888）     │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""

read -rp "  确认安装宝塔面板？(y/N): " confirm_install
if [[ "$confirm_install" != "y" && "$confirm_install" != "Y" ]]; then
    echo "  已取消安装。"
    exit 0
fi

echo ""

# 下载宝塔安装脚本
log "下载宝塔安装脚本..."
INSTALL_SCRIPT="/tmp/fin-deploy/bt_install.sh"

# 宝塔官方安装脚本（国内版）
BT_INSTALL_URL="https://download.bt.cn/install/install_panel.sh"

if ! wget -O "$INSTALL_SCRIPT" "$BT_INSTALL_URL" --no-check-certificate 2>/dev/null; then
    err "下载安装脚本失败"
    echo "  请检查网络连接，或手动安装："
    echo "    curl -sSO https://download.bt.cn/install/install_panel.sh"
    echo "    bash install_panel.sh ed8484bec"
    exit 1
fi
ok "安装脚本已下载"

echo ""

# ── 执行安装 ────────────────────────────────────────────────────
log "执行宝塔安装（请在提示时输入 y 确认）..."
echo ""

# 宝塔安装脚本需要交互式输入 y，用 yes 管道自动确认
# 如果自动确认失败，提示用户手动执行
if bash "$INSTALL_SCRIPT" ed8484bec <<< "y"; then
    ok "宝塔面板安装完成"
else
    warn "自动安装可能未完全成功，请尝试手动安装："
    echo ""
    echo "  bash $INSTALL_SCRIPT ed8484bec"
    echo ""
    echo "  或直接运行："
    echo "    curl -sSO https://download.bt.cn/install/install_panel.sh"
    echo "    bash install_panel.sh ed8484bec"
fi

echo ""

# ── 4. 获取面板信息 ─────────────────────────────────────────────
log "获取面板登录信息..."
echo ""

if [ -f "/etc/init.d/bt" ]; then
    echo "  ════════════════════════════════════════════"
    echo "  宝塔面板登录信息"
    echo "  ════════════════════════════════════════════"
    echo ""

    # 获取面板信息
    bt default 2>/dev/null || {
        # 如果 bt default 不工作，从配置文件读取
        PANEL_PORT=$(cat /www/server/panel/data/port.pl 2>/dev/null || echo "8888")
        PANEL_USER=$(cat /www/server/panel/data/default.pl 2>/dev/null || echo "admin")
        SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "服务器IP")
        echo "  面板地址: http://${SERVER_IP}:${PANEL_PORT}"
        echo "  用户名:   ${PANEL_USER}"
        echo "  密码:     (安装时显示的密码，或运行 bt 5 重置)"
    }

    echo ""
    echo "  ════════════════════════════════════════════"
    echo ""
    echo "  如忘记密码，可执行："
    echo "    bt 5    # 重置面板密码"
    echo "    bt 14   # 查看面板默认信息"
    echo ""
else
    err "宝塔面板可能未安装成功"
    echo "  请手动执行安装："
    echo "    curl -sSO https://download.bt.cn/install/install_panel.sh"
    echo "    bash install_panel.sh ed8484bec"
fi

echo ""

# ── 5. 防火墙：只用宝塔，不用系统 ufw/firewalld ─────────────────
log "防火墙策略（宝塔独占）..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  主机防火墙：只用宝塔面板 → 安全                         │"
echo "  │  请禁用系统 UFW / firewalld（见 lib-clear-conflicts.sh） │"
echo "  │                                                          │"
echo "  │  宝塔安全 / 云安全组 仅放行：                            │"
echo "  │    22(SSH)  80(HTTP)  443(HTTPS)  面板端口(常 8888)      │"
echo "  │  禁止公网放行：5432(PostgreSQL)  6379(Redis)             │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""

if systemctl is-active --quiet ufw 2>/dev/null || systemctl is-active --quiet firewalld 2>/dev/null; then
    err "检测到系统防火墙仍在运行，会与宝塔冲突！"
    echo "  请执行: bash $(dirname "$0")/lib-clear-conflicts.sh"
fi

if [ -f "$(dirname "$0")/lib-clear-conflicts.sh" ]; then
echo "  复查命令: bash $(dirname "$0")/lib-clear-conflicts.sh --check"
fi

echo ""

# ── 6. 下一步指引：登录宝塔手动安装组件 ───────────────────────
ok "═══════════════════════════════════════════════════════════"
ok "  Phase 2 宝塔安装完成！"
ok "═══════════════════════════════════════════════════════════"
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  接下来需要你在浏览器中操作宝塔面板，手动安装组件       │"
echo "  │  脚本不会自动安装这些组件，必须通过宝塔面板安装         │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "  ── Step 1: 登录宝塔面板 ──"
echo ""
echo "    浏览器打开上面的面板地址，登录后绑定宝塔账号（免费注册）"
echo ""
echo "  ── Step 2: 软件商店安装以下组件 ──"
echo ""
echo "    宝塔面板 → 左侧菜单 → 软件商店 → 搜索安装："
echo ""
echo "    ┌──────────────────┬────────────┬───────────────────────────────────────┐"
echo "    │ 组件             │ 推荐版本   │ 安装位置 / 说明                      │"
echo "    ├──────────────────┼────────────┼───────────────────────────────────────┤"
echo "    │ Nginx            │ 稳定版     │ 软件商店 → 搜索 Nginx → 安装          │"
echo "    │ PostgreSQL       │ 16.x       │ 软件商店 → 搜索 PostgreSQL 管理器     │"
echo "    │                  │            │   → 安装管理器后 → 版本管理 → 安装16  │"
echo "    │                  │            │   → 密码管理 → 设置 root 密码         │"
echo "    │ Redis            │ 7.x/8.x    │ 软件商店 → 搜索 Redis → 安装          │"
echo "    │                  │            │   → 安装后设置密码（与 deploy.env 一致）│"
echo "    │ Python 项目管理器 │ 自带 3.12  │ 软件商店 → 搜索 Python 项目管理器     │"
echo "    │ Supervisor       │ 最新版     │ 软件商店 → 搜索 Supervisor → 安装    │"
echo "    │                  │            │   → 用于进程守护和开机自启           │"
echo "    └──────────────────┴────────────┴───────────────────────────────────────┘"
echo ""
echo "  ── Step 3: 宝塔安全 → 放行端口 ──"
echo ""
echo "    宝塔面板 → 安全 → 放行端口："
echo "      22 (SSH)  80 (HTTP)  443 (HTTPS)  面板端口(如 27895)"
echo "    不要放行: 5432 (PostgreSQL)  6379 (Redis)"
echo ""
echo "  ── Step 4: Supervisor 安装完成后 ──"
echo ""
echo "    Supervisor 安装完成后，运行进程守护配置脚本："
echo "      bash 05-setup-supervisor.sh"
echo ""
echo "    该脚本会自动配置以下进程的守护和开机自启："
echo "      - financial-api (uvicorn :5001)"
echo "      - financial-crawler (爬虫调度)"
echo "      - financial-streaming (流式推送)"
echo "      - financial-worker (arq 后台任务)"
echo "      - quantdinger-backend (gunicorn :5000)"
echo "      - quantdinger-mcp (MCP :7800)"
echo "    以及基础设施服务的开机自启："
echo "      - Nginx / Redis / PostgreSQL"
echo ""
echo "  ── Step 5: 所有组件安装完成后 ──"
echo ""
echo "    回到 SSH 终端，运行检查脚本："
echo "      bash 03-check-components.sh"
echo ""
echo "    检查通过后继续："
echo "      bash 04-setup-server.sh"
echo ""
echo "  ────────────────────────────────────────────────────────────"
echo "  ⏳ 脚本在此暂停，等你安装完组件后运行 03-check-components.sh"
echo "  ────────────────────────────────────────────────────────────"
echo ""
