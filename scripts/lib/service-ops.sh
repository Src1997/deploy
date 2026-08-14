#!/usr/bin/env bash
# lib/service-ops.sh — Service operation utilities for deploy.sh
#
# Provides: restart_service, health_check, nginx_reload, show_status, show_logs
#
# Depends on: PROJECTS, SERVICES, HEALTH_URL, PROJECT_SERVICE,
#             PROJECT_DISPLAY_NAME, NO_RESTART, LOG_LINES, LOG_LEVEL

restart_service() {
    if $NO_RESTART; then warn "跳过重启 (--no-restart)"; return; fi
    local svc="$1"
    log "重启 $svc..."
    systemctl restart "$svc" 2>/dev/null || warn "$svc 重启失败"
    sleep 2
    systemctl is-active "$svc" >/dev/null 2>&1 && ok "$svc 运行中" || warn "$svc 未运行"
}

health_check() {
    local name="$1" url="$2"
    if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then ok "$name 健康检查通过"
    else warn "$name 健康检查失败"; fi
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
        local status=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
        local color
        [ "$status" = "active" ] && color="$GREEN" || color="$RED"
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
                    journalctl -u "$svc" -f
                    ;;
                50)
                    banner "最近 50 行: $svc"
                    journalctl -u "$svc" -n 50 --no-pager
                    ;;
                error)
                    banner "ERROR 日志: $svc"
                    journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
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
        journalctl -u "$svc" --no-pager | grep -iE 'error|traceback|exception' | tail -30
        return
    fi

    local lines="${LOG_LINES:-50}"
    if [ "$lines" = "0" ]; then
        banner "实时日志: $svc"
        journalctl -u "$svc" -f
    else
        banner "最近 $lines 行: $svc"
        journalctl -u "$svc" -n "$lines" --no-pager
    fi
}
