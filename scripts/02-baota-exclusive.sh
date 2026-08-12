#!/usr/bin/env bash
# =============================================================================
# 02-baota-exclusive.sh — 清除与宝塔冲突的系统组件（宝塔独占）
#
# 通常由 00-cleanup-docker.sh 自动调用（Phase 0 已合并原 0b）。
# 也可在宝塔装完组件后单独复查：
#   bash 02-baota-exclusive.sh --check
#   bash 02-baota-exclusive.sh --yes
# =============================================================================

set -euo pipefail

ASSUME_YES=false
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=true ;;
        --check)  CHECK_ONLY=true ;;
        --help|-h)
            echo "Usage: bash 02-baota-exclusive.sh [--check|--yes]"
            exit 0
            ;;
        *) echo "Unknown: $arg"; exit 1 ;;
    esac
done

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }
hr()   { echo "────────────────────────────────────────────────"; }

if [ "$(id -u)" -ne 0 ]; then
    err "必须以 root 运行"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  宝塔独占：清除系统防火墙 / 系统自带 Web&DB"
echo "═══════════════════════════════════════════════════════════"
echo ""

PKG=unknown
if command -v apt-get &>/dev/null; then PKG=apt
elif command -v dnf &>/dev/null; then PKG=dnf
elif command -v yum &>/dev/null; then PKG=yum
fi

ISSUES=0
report_issue() { warn "$*"; ISSUES=$((ISSUES + 1)); }

log "检查系统防火墙..."
if systemctl is-active --quiet ufw 2>/dev/null \
    || (command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'); then
    report_issue "UFW 已启用（应禁用，改用宝塔「安全」防火墙）"
else
    ok "UFW 未启用或不存在"
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
    report_issue "firewalld 已启用（应禁用，改用宝塔「安全」防火墙）"
else
    ok "firewalld 未启用或不存在"
fi

log "检查系统自带服务..."
ACTIVE_SYS=()
for svc in nginx apache2 httpd postgresql redis-server redis mysql mysqld mariadb; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        unit_path=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2-)
        if [[ "$unit_path" == /www/* ]] || [[ "$svc" == bt-* ]]; then
            ok "$svc 来自宝塔路径，保留"
            continue
        fi
        report_issue "系统服务运行中: $svc ($unit_path)"
        ACTIVE_SYS+=("$svc")
    fi
done
while IFS= read -r u; do
    [ -z "$u" ] && continue
    if systemctl is-active --quiet "$u" 2>/dev/null; then
        unit_path=$(systemctl show -p FragmentPath "$u" 2>/dev/null | cut -d= -f2-)
        if [[ "$unit_path" != /www/* ]]; then
            report_issue "系统服务运行中: $u ($unit_path)"
            ACTIVE_SYS+=("$u")
        fi
    fi
done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' | sed 's/\.service$//' | grep -E '^postgresql@' || true)
[ ${#ACTIVE_SYS[@]} -eq 0 ] && ok "未发现运行中的系统 Web/DB 服务"

log "检查端口占用..."
check_port_owner() {
    local port="$1" hint="$2" line
    line=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -v '^State' | head -1 || true)
    if [ -z "$line" ]; then
        ok "端口 $port 空闲"
        return
    fi
    if echo "$line" | grep -qE '/www/server|bt-postgresql|pgsql'; then
        ok "端口 $port 为宝塔相关进程（正常）"
    else
        report_issue "端口 $port 被非宝塔进程占用（期望: $hint）: $line"
    fi
}
check_port_owner 80 "宝塔 Nginx"
check_port_owner 443 "宝塔 Nginx"
check_port_owner 5432 "宝塔 PostgreSQL"
check_port_owner 6379 "宝塔 Redis"

log "检查 PATH 中的二进制来源..."
for bin in nginx psql redis-cli; do
    if command -v "$bin" &>/dev/null; then
        path=$(command -v "$bin")
        if [[ "$path" == /www/server/* ]]; then
            ok "$bin → $path （宝塔）"
        else
            report_issue "$bin → $path （系统路径，可能连错实例）"
        fi
    else
        warn "$bin 不在 PATH（宝塔软件未装时可忽略）"
    fi
done

if [ -d /www/server/panel ]; then
    ok "已检测到宝塔面板"
else
    warn "尚未安装宝塔（可先清冲突，再跑 01-install-baota.sh）"
fi

echo ""
hr
echo "  发现问题数: $ISSUES"
hr
echo ""

if $CHECK_ONLY; then
    [ "$ISSUES" -eq 0 ] && exit 0 || exit 2
fi

if [ "$ISSUES" -eq 0 ]; then
    ok "无冲突需要清理（已满足宝塔独占）"
    exit 0
fi

echo "  将执行："
echo "    1. 停用 UFW / firewalld（改用宝塔安全）"
echo "    2. 停止并 disable 系统 Nginx/Apache/PostgreSQL/Redis/MySQL"
echo "    3. purge 对应系统软件包"
echo "    4. 写入 /etc/profile.d/baota-path.sh（宝塔 bin 优先）"
echo "    5. 不公网开放 5432 / 6379"
echo ""

if ! $ASSUME_YES; then
    read -rp "  确认清理？输入 yes 继续: " confirm
    [ "$confirm" = "yes" ] || { warn "已取消"; exit 0; }
fi

log "禁用系统防火墙..."
if command -v ufw &>/dev/null; then
    ufw --force disable 2>/dev/null || true
    systemctl stop ufw 2>/dev/null || true
    systemctl disable ufw 2>/dev/null || true
    ok "UFW 已 disable"
fi
if systemctl list-unit-files firewalld.service &>/dev/null; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    ok "firewalld 已 disable"
fi
warn "请到宝塔面板 → 安全：放行 22、80、443、面板端口；不要放行 5432/6379"

log "停止系统 Web/DB 服务..."
STOP_LIST=(nginx apache2 httpd redis-server redis mysql mysqld mariadb postgresql)
while IFS= read -r u; do
    [ -n "$u" ] && STOP_LIST+=("$u")
done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' | sed 's/\.service$//' | grep -E '^postgresql(@|$)' || true)

for svc in "${STOP_LIST[@]}"; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
ok "系统服务已 stop/disable"

log "卸载系统软件包..."
case "$PKG" in
    apt)
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
            nginx nginx-common nginx-full nginx-core \
            apache2 apache2-bin apache2-utils \
            redis-server redis-tools \
            mysql-server mysql-client mariadb-server mariadb-client \
            'postgresql*' 'postgresql-client*' \
            2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
        ok "apt purge 完成"
        ;;
    yum|dnf)
        $PKG remove -y \
            nginx httpd httpd-tools redis \
            mysql mysql-server mariadb mariadb-server \
            postgresql postgresql-server postgresql-contrib \
            2>/dev/null || true
        ok "$PKG remove 完成"
        ;;
    *)
        warn "未知包管理器，请手动卸载系统 nginx/postgresql/redis"
        ;;
esac

log "写入宝塔 PATH 优先配置..."
cat > /etc/profile.d/baota-path.sh <<'EOF'
# Prefer Baota binaries over system packages
for d in \
  /www/server/nginx/sbin \
  /www/server/pgsql/bin \
  /www/server/redis/src \
  /www/server/panel/pyenv/bin
do
  [ -d "$d" ] || continue
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$d:$PATH" ;;
  esac
done
export PATH
EOF
chmod 644 /etc/profile.d/baota-path.sh
# shellcheck disable=SC1091
. /etc/profile.d/baota-path.sh
if [ -f /root/.bashrc ] && ! grep -q 'baota-path.sh' /root/.bashrc 2>/dev/null; then
    echo '[ -f /etc/profile.d/baota-path.sh ] && . /etc/profile.d/baota-path.sh' >> /root/.bashrc
fi
ok "已写入 /etc/profile.d/baota-path.sh"

# ── journald 日志轮转（防止日志膨胀）──
log "配置 journald 日志大小限制..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-size-limit.conf <<'EOF'
# Limit journal disk usage to prevent unbounded growth
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxFileSec=30day
EOF
chmod 644 /etc/systemd/journald.conf.d/10-size-limit.conf
systemctl restart systemd-journald 2>/dev/null || true
ok "journald 日志限制: 最大 500M, 保留 30 天"

echo ""
log "复检..."
REMAIN=0
for svc in nginx apache2 httpd redis-server redis mysql mariadb postgresql; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        warn "仍在运行: $svc"
        REMAIN=$((REMAIN + 1))
    fi
done
if systemctl is-active --quiet ufw 2>/dev/null || systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "系统防火墙仍为 active"
    REMAIN=$((REMAIN + 1))
fi

echo ""
if [ "$REMAIN" -eq 0 ]; then
    ok "冲突清理完成：运行时栈交给宝塔"
    exit 0
fi
warn "仍有 $REMAIN 项未清理干净，请人工检查"
exit 2
