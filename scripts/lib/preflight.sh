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

    # 2. PostgreSQL running (check + auto-start if down)
    # Load baota PATH so pg_isready/psql are found in non-interactive SSH
    [ -f /etc/profile.d/baota-path.sh ] && . /etc/profile.d/baota-path.sh 2>/dev/null || true
    if timeout 5 systemctl is-active --quiet bt-pgsql 2>/dev/null \
        || timeout 5 systemctl is-active --quiet bt-postgresql 2>/dev/null \
        || [ "$(/etc/init.d/pgsql status 2>/dev/null | grep -ci 'running\|is running')" -gt 0 ] \
        || timeout 5 pg_isready -h "$PG_HOST" -U "$PG_USER" >/dev/null 2>&1; then
        ok "PostgreSQL：运行中"
    else
        warn "PostgreSQL 未运行，尝试自动启动..."
        # Try multiple start methods: systemd -> init.d -> pg_ctl as postgres user
        local pg_started=0
        if timeout 10 systemctl start bt-pgsql 2>/dev/null \
            || timeout 10 systemctl start bt-postgresql 2>/dev/null \
            || timeout 10 /etc/init.d/pgsql start 2>/dev/null; then
            sleep 3
            if timeout 5 pg_isready -h "$PG_HOST" -U "$PG_USER" >/dev/null 2>&1; then
                ok "PostgreSQL：自动启动成功"
                pg_started=1
            fi
        fi
        # Fallback: pg_ctl as postgres user (BaoTa installs PG under /www/server/pgsql)
        if [ "$pg_started" -eq 0 ] && [ -x /www/server/pgsql/bin/pg_ctl ] && [ -d /www/server/pgsql/data ]; then
            if su - postgres -c "/www/server/pgsql/bin/pg_ctl start -D /www/server/pgsql/data -l /tmp/pg-preflight.log" 2>/dev/null; then
                sleep 3
                if timeout 5 pg_isready -h "$PG_HOST" -U "$PG_USER" >/dev/null 2>&1; then
                    ok "PostgreSQL：pg_ctl 启动成功"
                    pg_started=1
                fi
            fi
        fi
        if [ "$pg_started" -eq 0 ]; then
            err "PostgreSQL 自动启动失败（尝试了 systemd / init.d / pg_ctl）"
            ((errors++))
        fi
    fi

    # 3. Redis running (check + auto-start if down)
    local redis_args=(-h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}")
    if [ -n "${REDIS_PASSWORD:-}" ]; then
        redis_args+=(-a "$REDIS_PASSWORD")
    fi
    if timeout 5 redis-cli "${redis_args[@]}" ping >/dev/null 2>&1; then
        ok "Redis：运行中"
    else
        warn "Redis 未运行，尝试自动启动..."
        local redis_started=0
        # For remote Redis (REDIS_HOST is not localhost), don't try to start
        local redis_is_local=1
        case "${REDIS_HOST:-127.0.0.1}" in
            127.0.0.1|localhost|::1) redis_is_local=1 ;;
            *) redis_is_local=0 ;;
        esac
        if [ "$redis_is_local" -eq 1 ]; then
            if timeout 10 systemctl start bt-redis 2>/dev/null \
                || timeout 10 systemctl start redis 2>/dev/null \
                || timeout 10 /etc/init.d/redis start 2>/dev/null; then
                sleep 2
                if timeout 5 redis-cli "${redis_args[@]}" ping >/dev/null 2>&1; then
                    ok "Redis：自动启动成功"
                    redis_started=1
                fi
            fi
            # Fallback: direct redis-server with BaoTa config
            if [ "$redis_started" -eq 0 ] && [ -x /www/server/redis/src/redis-server ]; then
                /www/server/redis/src/redis-server /www/server/redis/redis.conf 2>/dev/null &
                sleep 2
                if timeout 5 redis-cli "${redis_args[@]}" ping >/dev/null 2>&1; then
                    ok "Redis：redis-server 启动成功"
                    redis_started=1
                fi
            fi
        else
            warn "Redis ($REDIS_HOST) 是远程实例，跳过自动启动"
        fi
        if [ "$redis_started" -eq 0 ]; then
            err "Redis 自动启动失败或远程不可连接"
            ((errors++))
        fi
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
