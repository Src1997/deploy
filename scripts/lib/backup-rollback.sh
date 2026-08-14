#!/usr/bin/env bash
# lib/backup-rollback.sh — Backup and rollback logic for deploy.sh
#
# Provides: has_backups, latest_backup, backup_frontend, backup_backend,
#           list_backups, resolve_rollback_archive, apply_rollback_one,
#           confirm_rollback_plan, rollback_projects
#
# Depends on: BACKUP_BASE, MAX_BACKUPS, TIMESTAMP, DEPLOY_PATH, PROJECT_KIND,
#             SERVICES, HEALTH_URL, NGINX_RELOAD, ROLLBACK_VERSION,
#             ROLLBACK_PICK_LATEST, ASSUME_YES, DEPLOY_DRY_RUN, NO_RESTART

has_backups() {
    local name="$1"
    local backup_dir="$BACKUP_BASE/$name"
    [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir"/*.tar.gz 2>/dev/null || true)" ]
}

latest_backup() {
    local name="$1"
    ls -t "$BACKUP_BASE/$name"/*.tar.gz 2>/dev/null | head -1 || true
}

backup_frontend() {
    local name="$1"
    local dist_dir="$2"
    local backup_dir="$BACKUP_BASE/$name"
    if [ ! -d "$dist_dir" ] || [ -z "$(ls -A "$dist_dir" 2>/dev/null || true)" ]; then
        warn "$name 无需备份（dist/ 为空或不存在）"; return 0
    fi
    mkdir -p "$backup_dir"
    tar czf "$backup_dir/$TIMESTAMP.tar.gz" -C "$(dirname "$dist_dir")" "$(basename "$dist_dir")"
    ok "已备份 $name → $backup_dir/$TIMESTAMP.tar.gz"
    local count
    count=$(ls -1 "$backup_dir"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        ls -t "$backup_dir"/*.tar.gz | tail -n +"$((MAX_BACKUPS + 1))" | xargs -r rm -f
        ok "已清理旧备份（保留 $MAX_BACKUPS 个）"
    fi
}

backup_backend() {
    local name="$1"
    local pkg_dir="$2"
    local backup_dir="$BACKUP_BASE/$name"
    [ ! -d "$pkg_dir" ] && { warn "$name 无需备份（目录不存在）"; return 0; }
    mkdir -p "$backup_dir"
    tar czf "$backup_dir/$TIMESTAMP.tar.gz" -C "$(dirname "$pkg_dir")" \
        --exclude=".env" --exclude=".venv" --exclude="logs" --exclude="data" \
        --exclude="__pycache__" --exclude="*.pyc" --exclude="*.egg-info" \
        "$(basename "$pkg_dir")"
    ok "已备份 $name → $backup_dir/$TIMESTAMP.tar.gz"
    local count
    count=$(ls -1 "$backup_dir"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        ls -t "$backup_dir"/*.tar.gz | tail -n +"$((MAX_BACKUPS + 1))" | xargs -r rm -f
    fi
}

list_backups() {
    local name="$1"
    local backup_dir="$BACKUP_BASE/$name"
    echo ""
    if ! has_backups "$name"; then
        echo "  $name 无可用备份"
        echo ""
        return 1
    fi
    echo "  ${BOLD}$name${NC} 可用备份（最新优先）："
    hr
    local i=1
    local f
    for f in $(ls -t "$backup_dir"/*.tar.gz 2>/dev/null); do
        local ts size
        ts=$(basename "$f" .tar.gz)
        size=$(du -h "$f" | cut -f1)
        printf "  %2d) %-20s  (%s)\n" "$i" "$ts" "$size"
        i=$((i + 1))
    done
    echo ""
    return 0
}

resolve_rollback_archive() {
    local name="$1"
    local backup_dir="$BACKUP_BASE/$name"
    local archive=""

    if ! has_backups "$name"; then
        err "$name 无可用备份"
        return 1
    fi

    if [ -n "$ROLLBACK_VERSION" ] && [ "$ROLLBACK_VERSION" != "latest" ]; then
        archive="$backup_dir/$ROLLBACK_VERSION.tar.gz"
        if [ ! -f "$archive" ]; then
            err "$name 指定备份不存在: $ROLLBACK_VERSION"
            list_backups "$name" >&2 || true
            return 1
        fi
        printf '%s\n' "$archive"
        return 0
    fi

    if [ "$ROLLBACK_VERSION" = "latest" ] || [ -n "${ROLLBACK_PICK_LATEST:-}" ]; then
        archive=$(latest_backup "$name")
        printf '%s\n' "$archive"
        return 0
    fi

    list_backups "$name" >&2 || return 1
    local backups=() i=0
    local f
    for f in $(ls -t "$backup_dir"/*.tar.gz 2>/dev/null); do
        backups+=("$f")
        i=$((i + 1))
    done
    local choice
    read -rp "  [$name] 选择回滚版本 [1-$i]（回车=1 最新）: " choice
    if [ -z "$choice" ]; then
        choice=1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
        err "无效选择: $choice"
        return 1
    fi
    printf '%s\n' "${backups[$((choice - 1))]}"
    return 0
}

apply_rollback_one() {
    local name="$1"
    local archive="$2"
    local target_dir="${DEPLOY_PATH[$name]}"
    local ts
    ts=$(basename "$archive" .tar.gz)

    log "回滚 $name → $ts ..."

    case "${PROJECT_KIND[$name]}" in
        frontend) backup_frontend "$name" "$target_dir" ;;
        backend)  backup_backend "$name" "$target_dir" ;;
        *)        backup_frontend "$name" "$target_dir" ;;
    esac

    local parent_dir
    parent_dir=$(dirname "$target_dir")
    rm -rf "$target_dir"
    mkdir -p "$parent_dir"
    if ! tar xzf "$archive" -C "$parent_dir"; then
        err "$name 解压备份失败: $archive"
        return 1
    fi
    ok "$name 已回滚到 $ts"

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        warn "DEPLOY_DRY_RUN=1：跳过服务重启"
        return 0
    fi
    if [ "${NGINX_RELOAD[$name]}" = "true" ]; then
        nginx_reload
    fi
    local svc
    for svc in ${SERVICES[$name]}; do
        [ -n "$svc" ] && restart_service "$svc"
    done
    if [ -n "${HEALTH_URL[$name]:-}" ]; then
        sleep 3
        health_check "$name" "${HEALTH_URL[$name]}"
    fi
    return 0
}

confirm_rollback_plan() {
    local -n _names=$1
    local -n _archives=$2
    echo ""
    hr
    echo -e "  ${BOLD}${YELLOW}即将回滚以下项目（不可轻易撤销，请仔细核对）：${NC}"
    hr
    local i
    for i in "${!_names[@]}"; do
        local n="${_names[$i]}"
        local a="${_archives[$i]}"
        local ts
        ts=$(basename "$a" .tar.gz)
        printf "  • %-20s → %s\n" "$n" "$ts"
        echo -e "      ${DIM}$a${NC}"
    done
    hr
    echo "  说明：回滚前会自动备份当前线上版本到 backup/<项目>/"
    echo ""
    if $ASSUME_YES; then
        warn "已指定 --yes，跳过确认"
        return 0
    fi
    local confirm
    read -rp "  确认执行回滚？请输入 yes 继续: " confirm
    if [ "$confirm" != "yes" ]; then
        warn "已取消回滚"
        return 1
    fi
    return 0
}

rollback_projects() {
    local projects=("$@")
    [ ${#projects[@]} -eq 0 ] && { err "未指定回滚项目"; return 1; }

    banner "回滚计划（${#projects[@]} 个项目）"

    local names=() archives=()
    local p archive
    for p in "${projects[@]}"; do
        if [ -z "${DEPLOY_PATH[$p]:-}" ]; then
            err "未知项目: $p"; return 1
        fi
        archive=$(resolve_rollback_archive "$p") || {
            err "无法为 $p 选择备份，中止整批回滚"
            return 1
        }
        names+=("$p")
        archives+=("$archive")
    done

    confirm_rollback_plan names archives || return 1

    local succeeded=() failed=()
    local i
    for i in "${!names[@]}"; do
        echo ""
        if apply_rollback_one "${names[$i]}" "${archives[$i]}"; then
            succeeded+=("${names[$i]}")
            audit_log "ROLLBACK ${names[$i]} -> $(basename "${archives[$i]}" .tar.gz) by $(whoami)@$(hostname)"
        else
            failed+=("${names[$i]}")
            err "${names[$i]} 回滚失败，继续处理后续项目..."
        fi
    done

    echo ""
    hr
    echo -e "  ${BOLD}回滚结果：${NC}"
    [ ${#succeeded[@]} -gt 0 ] && ok "  成功: ${succeeded[*]}"
    [ ${#failed[@]} -gt 0 ] && err "  失败: ${failed[*]}"
    hr
    [ ${#failed[@]} -eq 0 ]
}
