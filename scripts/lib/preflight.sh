#!/usr/bin/env bash
# lib/preflight.sh — Pre-deployment checks for deploy.sh
#
# Provides: preflight()
#
# Depends on: PROJECTS, PG_HOST, PG_USER, REDIS_HOST, REDIS_PORT,
#             REDIS_PASSWORD, HEALTH_URL, SERVICES, DEPLOY_DRY_RUN,
#             PROJECT_BASE, require_deploy_secrets()

preflight() {
    local errors=0
    banner "Pre-flight 检查"

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        warn "DEPLOY_DRY_RUN=1：跳过密钥与系统检查"
        return 0
    fi

    if ! require_deploy_secrets; then
        return 1
    fi

    # 1. Disk space (at least 1GB available)
    local check_path="${PROJECT_BASE:-/www/wwwroot/project}"
    local avail_kb
    avail_kb=$(df -P "$check_path" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 1048576 ]; then
        err "磁盘空间不足：$(df -h "$check_path" | awk 'NR==2{print $4}') 可用（需 ≥ 1GB）"
        ((errors++))
    else
        ok "磁盘空间：$(df -h "$check_path" | awk 'NR==2{print $4}') 可用"
    fi

    # 2. PostgreSQL running (check systemd, init.d, or pg_isready fallback)
    # Load baota PATH so pg_isready/psql are found in non-interactive SSH
    [ -f /etc/profile.d/baota-path.sh ] && . /etc/profile.d/baota-path.sh 2>/dev/null || true
    if timeout 5 systemctl is-active --quiet bt-pgsql 2>/dev/null \
        || timeout 5 systemctl is-active --quiet bt-postgresql 2>/dev/null \
        || [ "$(/etc/init.d/pgsql status 2>/dev/null | grep -ci 'running\|is running')" -gt 0 ] \
        || timeout 5 pg_isready -h "$PG_HOST" -U "$PG_USER" >/dev/null 2>&1; then
        ok "PostgreSQL：运行中"
    else
        err "PostgreSQL 未运行或不可连接（bt-pgsql/bt-postgresql/init.d/pgsql 或 pg_isready 检查失败）"
        ((errors++))
    fi

    # 3. Redis running (password may be empty)
    local redis_args=(-h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}")
    if [ -n "${REDIS_PASSWORD:-}" ]; then
        redis_args+=(-a "$REDIS_PASSWORD")
    fi
    if timeout 5 redis-cli "${redis_args[@]}" ping >/dev/null 2>&1; then
        ok "Redis：运行中"
    else
        err "Redis 未运行或密码不正确"
        ((errors++))
    fi

    # 4. Backend port check (extract port from healthUrl)
    local checked_ports=""
    for p in "${PROJECTS[@]}"; do
        local url="${HEALTH_URL[$p]:-}"
        [ -z "$url" ] && continue
        local port
        port=$(echo "$url" | sed -n 's|.*://[^:]*:\([0-9]*\).*|\1|p')
        [ -z "$port" ] && continue
        echo "$checked_ports" | grep -qw "$port" && continue
        checked_ports="$checked_ports $port"
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local primary_svc="${SERVICES[$p]:-}"
            primary_svc="${primary_svc%% *}"
            if [ -n "$primary_svc" ] && systemctl is-active --quiet "$primary_svc" 2>/dev/null; then
                ok "端口 $port：$primary_svc 已占用（正常）"
            else
                local proc
                proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | grep -oP 'pid=\K[0-9]+' || echo "unknown")
                warn "端口 $port 被进程 $proc 占用但 $primary_svc 未运行，重启时可能冲突"
            fi
        else
            ok "端口 $port：空闲"
        fi
    done

    # 5. Python version (>= 3.11)
    local py_ver
    py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    if [ "$py_ver" != "0.0" ]; then
        local py_major py_minor
        py_major=$(echo "$py_ver" | cut -d. -f1)
        py_minor=$(echo "$py_ver" | cut -d. -f2)
        if [ "$py_major" -ge 3 ] && [ "$py_minor" -ge 11 ]; then
            ok "Python 版本：$py_ver"
        else
            err "Python 版本过低：$py_ver（需 ≥ 3.11）"
            ((errors++))
        fi
    else
        warn "无法检测 Python 版本"
    fi

    if [ "$errors" -gt 0 ]; then
        err "Pre-flight 检查失败（$errors 个错误），请修复后重试"
        return 1
    fi
    ok "Pre-flight 检查通过"
    echo ""
}
