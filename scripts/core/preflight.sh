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

    # 0. deploy_path 唯一性
    # python 组件的部署流程是「清空整个 deploy_path（保留 .env/.venv/logs/data）
    # → 解压到 deploy_path 根」，因此两个组件共用同一 deploy_path 时，后部署的
    # 一方必然抹掉另一方的代码（2026-08-24 deepquant-mcp 覆盖 backend 包，
    # 导致 quantdinger-backend 静默崩溃 21 天）。这里直接拦死。
    local _seen_paths="" _dup_found=0 _p _dp
    for _p in "${PROJECTS[@]}"; do
        _dp="${DEPLOY_PATH[$_p]:-}"
        [ -z "$_dp" ] && continue
        if echo " $_seen_paths " | grep -q " $_dp "; then
            err "deploy_path 冲突：$_dp 被多个组件共用（${PROJECT_DISPLAY_NAME[$_p]:-$_p}）→ 部署会互相覆盖"
            _dup_found=1
        else
            _seen_paths="$_seen_paths $_dp"
        fi
    done
    if [ "$_dup_found" = "1" ]; then
        if [ "${DEPLOY_ALLOW_PATH_CONFLICT:-0}" = "1" ]; then
            warn "DEPLOY_ALLOW_PATH_CONFLICT=1：已知存在 deploy_path 冲突，继续部署（后果自负）"
        else
            err "请给每个组件分配唯一 deploy_path；辅助服务请用 pack.extra_source 打进主组件的包"
            ((errors++))
        fi
    else
        ok "deploy_path：所有组件互不冲突"
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

    # 5. 系统时钟偏差（★ 历史事故源：VM 挂起/恢复后时钟冻结，chrony makestep
    #    窗口已过只会慢速追赶，2026-10-09 VM 慢 61 分钟——上传时间戳错乱、
    #    TLS 证书校验失败、签名 token 全部受影响。这里用 HTTP Date 头做
    #    独立于 chrony 的硬校验，偏差超阈值直接拦下部署。）
    local now_epoch http_date="" http_epoch drift turl
    now_epoch=$(date +%s)
    for turl in "https://www.baidu.com" "https://mirrors.cloud.tencent.com" "https://www.aliyun.com"; do
        http_date=$(timeout 6 curl -sI --max-time 5 "$turl" 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)
        [ -n "$http_date" ] && break
    done
    if [ -z "$http_date" ]; then
        warn "时钟检查：无法获取网络时间（服务器离线或出口受限），跳过"
    else
        http_epoch=$(date -d "$http_date" +%s 2>/dev/null)
        if [ -z "$http_epoch" ]; then
            warn "时钟检查：网络时间解析失败（Date: $http_date），跳过"
        else
            drift=$(( now_epoch - http_epoch ))
            local abs_drift=${drift#-}
            if [ "$abs_drift" -gt 120 ]; then
                err "系统时钟偏差 ${drift}s（>120s）：TLS/签名/定时任务全会受影响。先校准：sudo systemctl stop chrony; sudo timedatectl set-ntp false; sudo timedatectl set-time '<正确时间>'; sudo hwclock -w"
                ((errors++))
            elif [ "$abs_drift" -gt 10 ]; then
                warn "系统时钟偏差 ${drift}s（10-120s）：建议部署后执行 sudo chronyc makestep 强制对时"
            else
                ok "系统时钟：偏差 ${drift}s（正常）"
            fi
        fi
    fi

    # 6. NTP 同步服务状态（仅提示，不拦截——离线服务器可以没有 NTP）
    if command -v chronyc >/dev/null 2>&1 && timeout 3 chronyc tracking >/dev/null 2>&1; then
        local ntp_offset
        ntp_offset=$(chronyc tracking 2>/dev/null | sed -n 's/^System time *: *\([0-9.e+-]*\) seconds.*/\1/p' | head -1)
        if [ -n "$ntp_offset" ]; then
            ok "NTP（chrony）：运行中，System time 偏差 ${ntp_offset}s"
        else
            ok "NTP（chrony）：运行中"
        fi
    elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        ok "NTP（systemd-timesyncd）：运行中"
    else
        warn "NTP 同步服务未运行（chrony/timesyncd 均未激活）——挂起恢复后时钟会漂移"
    fi

    if [ "$errors" -gt 0 ]; then
        err "Pre-flight 检查失败（$errors 个错误），请修复后重试"
        return 1
    fi
    ok "Pre-flight 检查通过"
    echo ""
}
