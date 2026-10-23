#!/usr/bin/env bash
# scripts/lib/interactive.sh — 交互式菜单
#
# 提供主菜单、部署选择、全量部署确认、回滚选择、备份列表交互等功能。
# 依赖：common.sh、preflight.sh、backup-rollback.sh、deploy-dispatch.sh、service-ops.sh
# 被 source 于 deploy.sh，不直接执行。

# ── 主菜单 ────────────────────────────────────────────────────────────

interactive_menu() {
    local first_run=true
    while true; do
        if $first_run; then
            echo ""
            echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
            echo -e "  ${BOLD}部署管理工具${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
            show_help
            first_run=false
        fi
        banner "部署管理工具"
        echo "  ${BOLD}1)${NC} 部署项目（选择一个或多个）"
        echo "  ${BOLD}2)${NC} 全量部署（${#PROJECTS[@]} 个项目）"
        echo "  ${BOLD}3)${NC} 回滚（单项目 / 多选 / 全部）"
        echo "  ${BOLD}4)${NC} 查看备份列表"
        echo "  ${BOLD}5)${NC} 查看服务状态"
        echo "  ${BOLD}6)${NC} 查看日志"
        echo "  ${BOLD}7)${NC} Pre-flight 检查"
        echo "  ${BOLD}8)${NC} 查看部署日志"
        echo "  ${BOLD}0)${NC} 退出"
        echo ""
        read -rp "  选择 [0-8]: " main_choice
        case "$main_choice" in
            1) interactive_deploy ;;
            2) PROJECT="all"; deploy_all ;;
            3) interactive_rollback ;;
            4) interactive_list_backups ;;
            5) show_status ;;
            6) PROJECT=""; show_logs ;;
            7) preflight ;;
            8) tail -30 "$DEPLOY_LOG" 2>/dev/null || warn "无部署日志" ;;
            0) echo "Bye!"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
        echo ""
    done
}

# ── 交互式部署选择 ────────────────────────────────────────────────────

interactive_deploy() {
    banner "选择要部署的项目"
    echo "  输入编号，空格分隔多选（如: 1 3 5），或 a 全选："
    echo ""
    local i=1
    for p in "${PROJECTS[@]}"; do
        echo "  ${BOLD}$i)${NC} $p  ${DIM}${PROJECT_DISPLAY_NAME[$p]}${NC}"
        ((i++))
    done
    echo "  ${BOLD}a)${NC} 全选"
    echo ""
    read -rp "  选择: " choices

    local selected=()
    if [ "$choices" = "a" ]; then
        selected=("${PROJECTS[@]}")
    else
        for c in $choices; do
            if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#PROJECTS[@]} ]; then
                selected+=("${PROJECTS[$((c-1))]}")
            else
                warn "忽略无效选择: $c"
            fi
        done
    fi

    [ ${#selected[@]} -eq 0 ] && { warn "未选择任何项目"; return; }

    read -rp "  服务器 IP（可选，留空跳过 CORS 更新）: " ip
    [ -n "$ip" ] && SERVER_IP="$ip"

    echo ""
    hr
    echo "  即将部署: ${BOLD}${selected[*]}${NC}"
    [ -n "$SERVER_IP" ] && echo "  CORS IP:  $SERVER_IP"
    hr
    read -rp "  确认部署？[y/N]: " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { warn "已取消"; return; }

    if ! preflight; then return; fi
    local sorted
    sorted=$(sort_deploy_order "${selected[@]}")
    audit_log "DEPLOY ${selected[*]} by $(whoami)@$(hostname) IP=${SERVER_IP:-N/A}"
    deploy_batch $sorted || true
    deploy_summary "${selected[@]}"
    audit_log "DEPLOY ${selected[*]} done"
}

# ── 全量部署（交互确认）──────────────────────────────────────────────

deploy_all() {
    read -rp "  服务器 IP（可选）: " ip
    [ -n "$ip" ] && SERVER_IP="$ip"
    echo ""
    hr
    echo "  即将全量部署 ${#PROJECTS[@]} 个项目"
    [ -n "$SERVER_IP" ] && echo "  CORS IP:  $SERVER_IP"
    hr
    read -rp "  确认？[y/N]: " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { warn "已取消"; return; }

    if ! preflight; then return; fi
    audit_log "DEPLOY all by $(whoami)@$(hostname) IP=${SERVER_IP:-N/A}"
    deploy_batch "${PROJECTS[@]}" || true
    deploy_summary "${PROJECTS[@]}"
    audit_log "DEPLOY all done"
}

# ── 交互式回滚选择 ────────────────────────────────────────────────────

interactive_rollback() {
    banner "选择要回滚的项目"
    echo "  输入编号，空格分隔多选（如: 1 3），或 a 全部回滚："
    echo ""
    local i=1
    for p in "${PROJECTS[@]}"; do
        local mark="无备份"
        has_backups "$p" && mark="有备份"
        echo "  ${BOLD}$i)${NC} $p  ${DIM}${PROJECT_DISPLAY_NAME[$p]}${NC}  [$mark]"
        i=$((i + 1))
    done
    echo "  ${BOLD}a)${NC} 全部（仅回滚「有备份」的项目）"
    echo ""
    read -rp "  选择: " choices

    local selected=()
    if [ "$choices" = "a" ] || [ "$choices" = "A" ]; then
        for p in "${PROJECTS[@]}"; do
            if has_backups "$p"; then
                selected+=("$p")
            else
                warn "跳过 $p（无备份）"
            fi
        done
    else
        local c
        for c in $choices; do
            if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#PROJECTS[@]} ]; then
                local p="${PROJECTS[$((c - 1))]}"
                if has_backups "$p"; then
                    selected+=("$p")
                else
                    warn "跳过 $p（无备份）"
                fi
            else
                warn "忽略无效选择: $c"
            fi
        done
    fi

    [ ${#selected[@]} -eq 0 ] && { warn "没有可回滚的项目"; return; }

    echo ""
    echo "  版本选择方式："
    echo "  1) 每个项目交互选择备份（默认）"
    echo "  2) 全部使用各自最新备份"
    read -rp "  选择 [1/2]: " mode
    if [ "$mode" = "2" ]; then
        ROLLBACK_VERSION="latest"
    else
        ROLLBACK_VERSION=""
    fi

    rollback_projects "${selected[@]}"
}

# ── 交互式备份列表 ────────────────────────────────────────────────────

interactive_list_backups() {
    banner "备份列表"
    local any=false
    for p in "${PROJECTS[@]}"; do
        if has_backups "$p"; then
            any=true
            echo "  ${BOLD}$p${NC} (${PROJECT_DISPLAY_NAME[$p]}):"
            local f
            for f in $(ls -t "$BACKUP_BASE/$p"/*.tar.gz 2>/dev/null); do
                local ts size
                ts=$(basename "$f" .tar.gz)
                size=$(du -h "$f" | cut -f1)
                echo "    $ts  ($size)"
            done
            echo ""
        fi
    done
    $any || warn "当前没有任何项目备份"
}
