#!/usr/bin/env bash
# lib/service-ops.sh — Service operation utilities for deploy.sh
#
# Provides: restart_service, health_check, nginx_reload, show_status, show_logs
#
# Depends on: PROJECTS, SERVICES, HEALTH_URL, PROJECT_SERVICE,
#             PROJECT_DISPLAY_NAME, NO_RESTART, LOG_LINES, LOG_LEVEL

# Detect Supervisor (BaoTa plugin or system)
# ★ 2026-10-15 修复坑②：新版宝塔把 supervisor 插件的 python 环境放在
#   /www/server/panel/pyenv/bin/（旧路径 plugin/supervisor/bin/ 不存在），
#   原探测链全部落空 → _SUPERVISORCTL 为空 → 误判「不在 Supervisor」→
#   回退 systemctl 重启（无效）→ 旧进程带着旧代码继续跑。
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
#
# 必须用全量列表匹配，不能用 `supervisorctl status <name>` 的退出码：
# 对 STOPPED / FATAL 的程序，supervisorctl 返回非 0，会被误判成「不在 Supervisor」，
# 从而回退到 systemctl —— 而 05-setup-supervisor.sh 已经把同名 systemd unit 删掉了，
# 结果就是重启失败却被 warn 吞掉、部署照常报成功。
# 全新服务器首次部署时（代码未到位，程序全是 FATAL）必然踩到这条。
_svc_in_supervisor() {
    [ -n "$_SUPERVISORCTL" ] || return 1
    "$_SUPERVISORCTL" status 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

restart_service() {
    if $NO_RESTART; then warn "跳过重启 (--no-restart)"; return; fi
    local svc="$1"
    log "重启 $svc..."
    # Try Supervisor first, fall back to systemctl
    if _svc_in_supervisor "$svc"; then
        _restart_err="$($_SUPERVISORCTL restart "$svc" 2>&1)" || warn "$svc Supervisor restart failed: $_restart_err"
        sleep 2
        $_SUPERVISORCTL status "$svc" 2>/dev/null | grep -q RUNNING && ok "$svc 运行中 (Supervisor)" || warn "$svc 未运行"
    else
        systemctl restart "$svc" 2>/dev/null || warn "$svc 重启失败"
        sleep 2
        systemctl is-active "$svc" >/dev/null 2>&1 && ok "$svc 运行中" || warn "$svc 未运行"
    fi
}

health_check() {
    # 返回值约定：0=通过，1=失败（3 次尝试）。
    # ★ 调用方注意：在条件语境（if/||）下被调用时返回值不会中断流程；
    #   需要闭环的地方（回滚）用 `|| rc=1` 显式捕获。
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

nginx_reload() {
    if $NO_RESTART; then warn "跳过 Nginx 重载"; return; fi
    if ! nginx -t 2>&1; then
        err "Nginx 配置测试失败"
        return 1
    fi
    if nginx -s reload 2>&1; then
        ok "Nginx 已重载"
    else
        # PID file may be missing/stale — fall back to full restart
        warn "nginx -s reload 失败（可能是 PID 文件丢失），尝试 restart..."
        if /etc/init.d/nginx restart 2>&1; then
            ok "Nginx 已重启（restart fallback）"
        else
            err "Nginx 重启失败"
        fi
    fi
}

# -- Show service status overview --
show_status() {
    banner "服务状态总览"
    local -a services=()
    local -A seen=()
    for p in "${PROJECTS[@]}"; do
        local svcs="${SERVICES[$p]:-}"
        for svc in $svcs; do
            [ -n "$svc" ] && [ -z "${seen[$svc]:-}" ] && services+=("$svc") && seen[$svc]=1
        done
    done
    services+=("nginx")

    printf "  %-22s %-10s %s\n" "SERVICE" "STATUS" "HEALTH"
    hr
    for svc in "${services[@]}"; do
        local status
        # Try Supervisor first, fall back to systemctl
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

# -- Show logs interactively or by project --
show_logs() {
    local target="${PROJECT:-}"
    local svc=""

    if [ -z "$target" ] && [ -z "$LOG_LEVEL" ]; then
        banner "日志查看"
        echo "  选择查看目标："
        local menu_idx=1
        declare -a menu_items=()

        for p in "${PROJECTS[@]}"; do
            local p_svc="${PROJECT_SERVICE[$p]:-}"
            [ -z "$p_svc" ] && continue
            local p_name="${PROJECT_DISPLAY_NAME[$p]:-$p}"
            echo "  ${menu_idx}) $p_svc    实时日志          ($p_name)"
            menu_items+=("$p_svc:0")
            ((menu_idx++))
            echo "  ${menu_idx}) $p_svc    最近 50 行"
            menu_items+=("$p_svc:50")
            ((menu_idx++))
            echo "  ${menu_idx}) $p_svc    ERROR 级别"
            menu_items+=("$p_svc:error")
            ((menu_idx++))
        done
        echo "  ${menu_idx}) nginx    最近 50 行"
        menu_items+=("nginx:50")
        ((menu_idx++))
        echo ""
        read -rp "  选择 [1-${#menu_items[@]}]: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#menu_items[@]}" ]; then
            local selection="${menu_items[$((choice-1))]}"
            svc="${selection%%:*}"
            local mode="${selection##*:}"
            case "$mode" in
                0)
                    banner "实时日志: $svc"
                    # Try Supervisor tail first, fall back to journalctl
                    if _svc_in_supervisor "$svc"; then
                        $_SUPERVISORCTL tail -f "$svc" stderr
                    else
                        journalctl -u "$svc" -f
                    fi
                    ;;
                50)
                    banner "最近 50 行: $svc"
                    if _svc_in_supervisor "$svc"; then
                        $_SUPERVISORCTL tail "$svc" stderr -50 2>/dev/null || tail -50 "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null || journalctl -u "$svc" -n 50 --no-pager
                    else
                        journalctl -u "$svc" -n 50 --no-pager
                    fi
                    ;;
                error)
                    banner "ERROR 日志: $svc"
                    if _svc_in_supervisor "$svc"; then
                        grep -iE 'error|traceback|exception' "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null | tail -30 || journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
                    else
                        journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
                    fi
                    ;;
            esac
        else
            warn "无效选择"
        fi
        return
    fi

    # Direct mode: --logs <project>
    if [ -n "$target" ]; then
        svc="${PROJECT_SERVICE[$target]:-}"
        if [ -z "$svc" ]; then
            err "$target 无关联服务"
            return 1
        fi
    fi

    if [ -n "$LOG_LEVEL" ] && [ "$LOG_LEVEL" = "error" ]; then
        banner "ERROR 日志: $svc"
        if _svc_in_supervisor "$svc"; then
            grep -iE 'error|traceback|exception' "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null | tail -30 || journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
        else
            journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
        fi
        return
    fi

    local lines="${LOG_LINES:-50}"
    if [ "$lines" = "0" ]; then
        banner "实时日志: $svc"
        if _svc_in_supervisor "$svc"; then
            $_SUPERVISORCTL tail -f "$svc" stderr
        else
            journalctl -u "$svc" -f
        fi
    else
        banner "最近 $lines 行: $svc"
        if _svc_in_supervisor "$svc"; then
            $_SUPERVISORCTL tail "$svc" stderr -"$lines" 2>/dev/null || tail -"$lines" "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null || journalctl -u "$svc" -n "$lines" --no-pager
        else
            journalctl -u "$svc" -n "$lines" --no-pager
        fi
    fi
}
