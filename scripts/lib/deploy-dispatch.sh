#!/usr/bin/env bash
# scripts/lib/deploy-dispatch.sh — 部署调度函数
#
# 提供按类型排序、批量部署、部署结果汇总等功能。
# 依赖：common.sh（颜色/日志）、deploy-kinds.sh（deploy_by_id）、load-projects.sh（PROJECT_KIND 等）
# 被 source 于 deploy.sh，不直接执行。

# ── 单项目部署 ────────────────────────────────────────────────────────

# Global flag: when true, skip per-project nginx sync (used in batch mode
# to defer nginx reload until all frontends are deployed).
NGINX_SYNC_PENDING=false

deploy_one() {
    local p="$1"
    deploy_by_id "$p"
}

# ── 按类型排序部署顺序（frontend → python → compiled → scripted → other）──

sort_deploy_order() {
    local frontends=() backends=() compiled=() scripted=() other=()
    local p
    for p in "$@"; do
        case "${PROJECT_KIND[$p]}" in
            frontend)        frontends+=("$p") ;;
            python)          backends+=("$p") ;;
            java|go)         compiled+=("$p") ;;
            nodejs)          scripted+=("$p") ;;
            *)               other+=("$p") ;;
        esac
    done
    echo "${frontends[@]} ${backends[@]} ${compiled[@]} ${scripted[@]} ${other[@]}"
}

# ── 批量部署 ──────────────────────────────────────────────────────────

deploy_batch() {
    local projects=($@)
    local succeeded=() failed=()

    # Defer nginx sync until all frontends are deployed to avoid
    # repeated generate + reload cycles during batch deployment.
    NGINX_SYNC_PENDING=true

    for p in "${projects[@]}"; do
        echo ""
        if deploy_one "$p"; then
            succeeded+=("$p")
        else
            failed+=("$p")
            err "$p 部署失败，继续部署下一个..."
        fi
    done

    # All frontends deployed — now do a single nginx sync + reload
    NGINX_SYNC_PENDING=false
    if [ ${#succeeded[@]} -gt 0 ]; then
        local has_frontend=false
        for p in "${succeeded[@]}"; do
            [ "${PROJECT_KIND[$p]:-}" = "frontend" ] && has_frontend=true
        done
        if [ "$has_frontend" = "true" ]; then
            echo ""
            log "批量部署完成，统一同步 Nginx 配置..."
            sync_nginx || warn "sync_nginx 失败，请手动执行: bash deploy.sh --sync-nginx"
        fi
    fi

    echo ""
    hr
    echo "  ${BOLD}部署结果：${NC}"
    [ ${#succeeded[@]} -gt 0 ] && ok "  成功: ${succeeded[*]}"
    [ ${#failed[@]} -gt 0 ] && err "  失败: ${failed[*]}"
    [ ${#failed[@]} -gt 0 ] && warn "  失败的项目已保留备份，可用 --rollback 回滚"
    hr
    return ${#failed[@]}
}

# ── 部署后汇总 ────────────────────────────────────────────────────────

deploy_summary() {
    local deployed=("$@")
    echo ""
    ok "═══════════════════════════════════════════════════════════"
    ok "  部署完成！"
    ok "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  已部署项目: ${BOLD}${deployed[*]}${NC}"
    echo "  备份位置:   $BACKUP_BASE/"
    echo "  回滚命令:"
    echo "    bash deploy.sh <project> --rollback"
    echo "    bash deploy.sh proj1,proj2 --rollback=latest"
    echo "    bash deploy.sh all --rollback"
    echo ""
    if [ -n "$SERVER_IP" ]; then
        echo "  访问地址（IP: $SERVER_IP）："
        for p in "${deployed[@]}"; do
            local url=""
            if [ -n "${PUBLIC_URL[$p]:-}" ]; then
                url="http://$SERVER_IP${PUBLIC_URL[$p]}"
            elif [ -n "${HEALTH_URL[$p]:-}" ]; then
                local path="${HEALTH_URL[$p]}"
                path=$(echo "$path" | sed 's|.*://[^/]*||')
                url="http://$SERVER_IP$path"
            fi
            [ -n "$url" ] && echo "    $p → $url"
        done
        echo ""
    fi
    echo "  查看日志："
    for p in "${deployed[@]}"; do
        local primary_svc="${SERVICES[$p]:-}"
        primary_svc="${primary_svc%% *}"
        if [ -n "$primary_svc" ]; then
            echo "    journalctl -u $primary_svc -f"
        else
            echo "    tail -f /www/wwwlogs/error.log"
        fi
    done
    echo ""
}
