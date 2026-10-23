#!/usr/bin/env bash
# channel/native/channel.sh — 原生通道（kind × channel 矩阵的 native 实现，v2）
#
# ★冻结维护——仅供未迁移到宝塔通道的服务器（A/B）应急重部署：
#   不新增功能；全部服务器迁移宝塔后本目录整体退役。
#
# 所有权：systemd（服务）+ 宿主 nginx（路由，路由后端 = 同目录 nginx.sh）。
# 意图翻译（TOML → 原生）：
#   process(port,cmd) → systemd 单元 <id>.service（模板渲染自 assets/systemd/）
#   companions        → systemd 单元 <name>.service（同名模板）
#   routes            → generate-nginx 生成 default.conf
#
# Depends on: SERVICES, CONFIGS_SRC, DIST_ROOT, MCP_AGENT_TOKEN,
#             SCRIPT_DIR（deploy.sh 注入）；_svc_in_supervisor（core/service-ops.sh）

# 路由后端（registry 只加载本文件，nginx.sh 由这里拉起）
_NG="$SCRIPT_DIR/channels/native-nginx.sh"
[ -f "$_NG" ] || _NG="$SCRIPT_DIR_DEPLOY/channels/native-nginx.sh"
# shellcheck disable=SC1090
source "$_NG"

# -- 单服务重启（hybrid：supervisor 先探测、systemd 兜底——A/B 历史现状）--
_native_restart_service() {
    local svc="$1"
    $NO_RESTART && { warn "跳过重启 (--no-restart)"; return 0; }
    log "重启 $svc..."
    if _svc_in_supervisor "$svc"; then
        local rerr
        rerr=$("$_SUPERVISORCTL" restart "$svc" 2>&1) || warn "$svc Supervisor restart failed: $rerr"
        sleep 2
        "$_SUPERVISORCTL" status "$svc" 2>/dev/null | grep -q RUNNING \
            && ok "$svc 运行中 (Supervisor)" || warn "$svc 未运行"
    else
        systemctl restart "$svc" 2>/dev/null || warn "$svc 重启失败"
        sleep 2
        systemctl is-active "$svc" >/dev/null 2>&1 && ok "$svc 运行中" || warn "$svc 未运行"
    fi
}

channel_name()               { echo "native（systemd + 宿主 nginx）"; }
channel_supported_kinds()    { echo "frontend python java"; }
channel_wants_host_venv()    { echo "1"; }
channel_routing_sync()       { sync_nginx; }

# ── frontend ──

channel_frontend_prepare() {
    # 目标 = deploy_path（TOML SSOT），无前置资源
    echo "${DEPLOY_PATH[$1]:-}"
}
channel_frontend_preserve()  { :; }   # 无通道资产
channel_frontend_restore()   { :; }

channel_frontend_finalize() {
    local id="$1"
    if ! nginx_has_location "$id"; then
        warn "$id Nginx location not found in config — running sync-nginx"
        sync_nginx || warn "sync-nginx failed, continuing"
    fi
    # 前端部署即路由可能变化 → 一律 reload（NO_RESTART 时 nginx_reload_safe 自行跳过）
    nginx_reload_safe
}

# ── systemd 模板安装（python/java 共用内核）--
# 单元名 = 主组件 id + companions；模板查找顺序：
#   dist assets/systemd/<name>.service → configs → 源码 assets
_native_install_systemd() {
    local id="$1"; shift
    local svc
    for svc in "$@"; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        local svc_template=""
        local t
        for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                 "$DIST_ROOT/assets/systemd/${svc}.service" \
                 "$CONFIGS_SRC/${svc}.service" \
                 "$(dirname "$0")/assets/systemd/${svc}.service"; do
            [ -f "$t" ] && svc_template="$t" && break
        done
        if [ -n "$svc_template" ]; then
            if [ -f "$svc_file" ]; then
                ok "${svc}.service 已存在，更新模板..."
            else
                log "安装 ${svc}.service..."
            fi
            local mcp_token="${MCP_AGENT_TOKEN:-CHANGE_ME_MCP_TOKEN}"
            if [ "$mcp_token" = "CHANGE_ME_MCP_TOKEN" ] && echo "$svc_template" | grep -q '__MCP_AGENT_TOKEN__'; then
                warn "MCP_AGENT_TOKEN 未配置，MCP 服务无法通过认证"
            fi
            sed -e "s|__MCP_AGENT_TOKEN__|${mcp_token}|g" \
                "$svc_template" > "$svc_file"
            systemctl daemon-reload
            systemctl enable "$svc" 2>/dev/null || true
            ok "${svc}.service 已安装并启用"
        else
            if [ ! -f "$svc_file" ]; then
                warn "未找到 ${svc}.service 模板"
            else
                ok "${svc}.service 已存在"
            fi
        fi
    done
}

# ── python ──

channel_python_install() {
    local id="$1" pkg_dir="$2"
    _native_install_systemd "$id" ${SERVICES[$id]}
}
channel_python_restart() {
    local id="$1"
    local svc
    for svc in ${SERVICES[$id]}; do
        [ -n "$svc" ] && _native_restart_service "$svc"
    done
}

# ── java ──

channel_java_install() {
    local id="$1" pkg_dir="$2"
    _native_install_systemd "$id" ${SERVICES[$id]}
}
channel_java_restart() {
    local id="$1"
    local svc
    for svc in ${SERVICES[$id]}; do
        [ -n "$svc" ] && _native_restart_service "$svc"
    done
}

# ── 服务状态/操作（hybrid：supervisor 先探测、systemd 兜底——A/B 历史现状）──

channel_service_running() {
    local svc="$1"
    if _svc_in_supervisor "$svc"; then
        "$_SUPERVISORCTL" status "$svc" 2>/dev/null | grep -q RUNNING
        return
    fi
    systemctl is-active --quiet "$svc" 2>/dev/null
}

channel_service_restart() {
    _native_restart_service "$1"
}

channel_status() {
    local -a services=()
    local -A seen=()
    local p svc
    for p in "${PROJECTS[@]}"; do
        for svc in ${SERVICES[$p]:-}; do
            [ -n "$svc" ] && [ -z "${seen[$svc]:-}" ] && services+=("$svc") && seen[$svc]=1
        done
    done
    services+=("nginx")

    printf "  %-22s %-10s %s\n" "SERVICE" "STATUS" "HEALTH"
    hr
    for svc in "${services[@]}"; do
        local status
        if _svc_in_supervisor "$svc"; then
            status=$("$_SUPERVISORCTL" status "$svc" 2>/dev/null | awk '{print $2}' || echo "n/a")
        else
            status=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
        fi
        local color
        [ "$status" = "RUNNING" ] || [ "$status" = "active" ] && color="$GREEN" || color="$RED"
        local health=""
        for p in "${PROJECTS[@]}"; do
            if echo "${SERVICES[$p]:-}" | grep -qw "$svc"; then
                local hurl="${HEALTH_URL[$p]:-}"
                if [ -n "$hurl" ]; then
                    health=$(curl -sf --max-time 5 "$hurl" 2>/dev/null | head -c 60 || echo "FAIL")
                fi
                break
            fi
        done
        [ "$svc" = "nginx" ] && health=$(curl -sf --max-time 5 http://127.0.0.1/ -o /dev/null -w "%{http_code}" 2>/dev/null || echo "FAIL")
        [ -z "$health" ] && health="-"
        printf "  %-22s ${color}%-10s${NC} %s\n" "$svc" "$status" "$health"
    done
    echo ""
}

channel_logs() {
    local svc="$1" mode="${2:-50}"
    [ -z "$svc" ] && { err "未指定服务"; return 1; }
    case "$mode" in
        follow)
            banner "实时日志: $svc"
            if _svc_in_supervisor "$svc"; then
                "$_SUPERVISORCTL" tail -f "$svc" stderr
            else
                journalctl -u "$svc" -f
            fi
            ;;
        error)
            banner "ERROR 日志: $svc"
            if _svc_in_supervisor "$svc"; then
                grep -iE 'error|traceback|exception' "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null | tail -30
            else
                journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
            fi
            ;;
        *)
            banner "最近 $mode 行: $svc"
            if _svc_in_supervisor "$svc"; then
                "$_SUPERVISORCTL" tail "$svc" stderr -"$mode" 2>/dev/null || journalctl -u "$svc" -n "$mode" --no-pager
            else
                journalctl -u "$svc" -n "$mode" --no-pager
            fi
            ;;
    esac
}
