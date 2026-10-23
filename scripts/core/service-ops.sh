#!/usr/bin/env bash
# core/service-ops.sh — 通道无关的服务设施（v2）
#
# v2 所有权原则：服务操作（重启/状态/日志）归通道（channel_service_* /
# channel_status / channel_logs 动词），本文件只保留：
#   1. health_check        —— 公共健康门（所有通道共用）
#   2. supervisor 探测     —— supervisor 是宝塔插件但也存在于部分旧机，
#                             native 通道 status/logs 的 hybrid 探测要用
#   3. show_status/show_logs —— deploy.sh --status/--logs 的交互包装（调通道动词）
#
# Depends on: PROJECTS, SERVICES, HEALTH_URL, LOG_LINES, LOG_LEVEL,
#             channel_*（registry 加载后可用）

# ── supervisor 探测 ──
# ★ 2026-10-15 修复坑②：新版宝塔把 supervisor 插件的 python 环境放在
#   /www/server/panel/pyenv/bin/（旧路径 plugin/supervisor/bin/ 不存在），
#   现按「新路径 → 旧路径 → PATH」顺序探测，取第一个可执行的。
_SUPERVISORCTL=""
for _sup_cand in \
    /www/server/panel/pyenv/bin/supervisorctl \
    /www/server/panel/plugin/supervisor/bin/supervisorctl
do
    if [ -x "$_sup_cand" ]; then
        _SUPERVISORCTL="$_sup_cand"
        break
    fi
done
if [ -z "$_SUPERVISORCTL" ] && command -v supervisorctl &>/dev/null; then
    _SUPERVISORCTL=$(command -v supervisorctl)
fi

# _svc_in_supervisor <name>：程序是否已注册到 Supervisor（只看注册，不看运行状态）
# 必须用全量列表匹配，不能用 `supervisorctl status <name>` 的退出码：
# 对 STOPPED / FATAL 的程序，supervisorctl 返回非 0，会被误判成「不在 Supervisor」。
_svc_in_supervisor() {
    [ -n "$_SUPERVISORCTL" ] || return 1
    "$_SUPERVISORCTL" status 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# ── 健康检查（公共；返回 0=通过 1=失败，3 次尝试）──
health_check() {
    local name="$1" url="$2" attempt
    for attempt in 1 2 3; do
        if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
            if [ "$attempt" -gt 1 ]; then
                ok "$name 健康检查通过（第 $attempt 次尝试）"
            else
                ok "$name 健康检查通过"
            fi
            return 0
        fi
        [ "$attempt" -lt 3 ] && sleep 2
    done
    warn "$name 健康检查失败（3 次尝试: $url）"
    return 1
}

# ── --status 包装（转通道动词）──
show_status() {
    banner "服务状态总览（通道: $(channel_name)）"
    channel_status
}

# ── --logs 包装：交互菜单（保持 v1 UX）→ channel_logs <svc> <mode> ──
show_logs() {
    local target="${PROJECT:-}"

    # 直接模式：--logs <project>
    if [ -n "$target" ]; then
        local svc="${SERVICES[$target]:-}"; svc="${svc%% *}"
        [ -z "$svc" ] && { err "$target 无关联服务"; return 1; }
        local mode="${LOG_LINES:-50}"
        [ "$mode" = "0" ] && mode="follow"
        [ -n "$LOG_LEVEL" ] && mode="$LOG_LEVEL"
        channel_logs "$svc" "$mode"
        return
    fi

    # 交互模式
    banner "日志查看（通道: $(channel_name)）"
    echo "  选择查看目标："
    local menu_idx=1
    declare -a menu_items=()
    local p p_svc p_name
    for p in "${PROJECTS[@]}"; do
        p_svc="${SERVICES[$p]:-}"; p_svc="${p_svc%% *}"
        [ -z "$p_svc" ] && continue
        p_name="${PROJECT_DISPLAY_NAME[$p]:-$p}"
        echo "  ${menu_idx}) $p_svc    实时日志          ($p_name)"
        menu_items+=("$p_svc:follow")
        ((menu_idx++))
        echo "  ${menu_idx}) $p_svc    最近 50 行"
        menu_items+=("$p_svc:50")
        ((menu_idx++))
        echo "  ${menu_idx}) $p_svc    ERROR 级别"
        menu_items+=("$p_svc:error")
        ((menu_idx++))
    done
    echo ""
    read -rp "  选择 [1-${#menu_items[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#menu_items[@]}" ]; then
        local selection="${menu_items[$((choice-1))]}"
        channel_logs "${selection%%:*}" "${selection##*:}"
    else
        warn "无效选择"
    fi
}
