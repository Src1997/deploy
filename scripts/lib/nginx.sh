#!/usr/bin/env bash
# lib/nginx.sh — Nginx configuration and deployment for deploy.sh
#
# Provides: nginx_reload_safe, disable_baota_nginx_conflicts,
#           sync_nginx, nginx_has_location, deploy_nginx
#
# Depends on: DIST_ROOT, PROJECT_BASE, NGINX_CONF_TARGET, NGINX_MODE,
#             NGINX_CONF_NAME, DOMAIN, WWW_DOMAIN, CONFIGS_SRC,
#             DEPLOY_DRY_RUN, NO_RESTART, SCRIPT_DIR, PROJECT_BASE

# -- Safe Nginx reload with restart fallback --
# nginx -s reload fails when the PID file is missing/stale (e.g. after
# a crash or forced kill). Fall back to init.d restart in that case.
nginx_reload_safe() {
    if [ "${NO_RESTART:-false}" = "true" ]; then
        warn "跳过 Nginx 重载"
        return 0
    fi

    if ! nginx -t 2>&1; then
        err "Nginx 配置测试失败"
        return 1
    fi

    if nginx -s reload 2>&1; then
        ok "Nginx 已重载"
        return 0
    fi

    # PID file missing or stale — fall back to full restart
    warn "nginx -s reload 失败（可能是 PID 文件丢失），尝试 restart..."
    if /etc/init.d/nginx restart 2>&1; then
        ok "Nginx 已重启（restart fallback）"
        return 0
    fi

    err "Nginx 重启失败，请手动检查"
    return 1
}

# -- Disable Baota's phpfpm_status.conf that hijacks 127.0.0.1:80 --
# Baota ships a phpfpm_status.conf with `listen 80; server_name 127.0.0.1;`
# which takes priority over our default.conf for localhost requests,
# causing 404 on all static locations (/quant/, /qd/, /admin/, etc.).
# See docs/wsl-local-deploy-issues.md problem 5 for full analysis.
disable_baota_nginx_conflicts() {
    local conflict_file="/www/server/panel/vhost/nginx/phpfpm_status.conf"
    if [ ! -f "$conflict_file" ]; then
        return 0
    fi

    # Only act if it listens on port 80 with server_name 127.0.0.1
    if ! grep -q 'listen.*80' "$conflict_file" 2>/dev/null; then
        return 0
    fi

    if [ -f "${conflict_file}.bak" ]; then
        return 0  # Already disabled
    fi

    warn "检测到 phpfpm_status.conf 监听 80 端口，可能与 default.conf 冲突"
    mv "$conflict_file" "${conflict_file}.bak" 2>/dev/null
    ok "已禁用 phpfpm_status.conf（避免 80 端口冲突）"
}

# -- Generate Nginx config from TOML configs (calls generate-nginx.py) --
sync_nginx() {
    local gen_script="$SCRIPT_DIR/generate-nginx.py"
    [ ! -f "$gen_script" ] && { err "generate-nginx.py not found"; return 1; }

    local conf_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"

    local mode="${NGINX_MODE:-}"
    if [ -z "$mode" ]; then
        local conf_name="${NGINX_CONF_NAME:-}"
        case "$conf_name" in
            *servera-ssl*)   mode="ssl-redirect" ;;
            *all-sites-ssl*) mode="ssl-combined" ;;
            *)               mode="http" ;;
        esac
    fi

    local domain="${DOMAIN:-}"
    local www_domain="${WWW_DOMAIN:-}"

    if [ "$mode" != "http" ] && { [ -z "$domain" ] || [ -z "$www_domain" ]; }; then
        warn "SSL 模式 ($mode) 需要 DOMAIN 和 WWW_DOMAIN，回退到 http 模式"
        mode="http"
    fi

    banner "Sync Nginx config"
    log "Mode: $mode | Target: $conf_target"

    [ -f "$conf_target" ] && cp "$conf_target" "${conf_target}.bak.$(date +%Y%m%d-%H%M%S)"

    local py_args=()
    py_args+=(--mode "$mode")
    py_args+=(--project-base "$PROJECT_BASE")
    [ -n "$domain" ] && py_args+=(--domain "$domain")
    [ -n "$www_domain" ] && py_args+=(--www-domain "$www_domain")
    py_args+=(--output "$conf_target")

    if ! python3 "$gen_script" "${py_args[@]}"; then
        err "Failed to generate Nginx config"
        return 1
    fi
    ok "Nginx config generated"

    if ! nginx -t 2>&1; then
        err "Nginx config test failed — restoring backup"
        cp "${conf_target}.bak."* "$conf_target" 2>/dev/null
        return 1
    fi
    ok "Nginx config valid"

    disable_baota_nginx_conflicts
    nginx_reload_safe
    return $?
}

# -- Check if Nginx config already contains a project's location path --
nginx_has_location() {
    local id="$1"
    local conf_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"
    local public_url="${PUBLIC_URL[$id]:-}"

    if [ "${PROJECT_ROOT[$id]:-false}" = "true" ]; then
        local deploy_path="${DEPLOY_PATH[$id]:-}"
        grep -q "root.*${deploy_path}" "$conf_target" 2>/dev/null && return 0 || return 1
    fi

    [ -z "$public_url" ] && return 0
    grep -q "location.*${public_url}" "$conf_target" 2>/dev/null && return 0 || return 1
}

# -- Deploy Nginx config (dynamic generation from TOML configs) --
deploy_nginx() {
    log "配置 Nginx..."
    local nginx_target="${NGINX_CONF_TARGET:-/www/server/panel/vhost/nginx/default.conf}"

    local gen_script="$SCRIPT_DIR/generate-nginx.py"
    if [ ! -f "$gen_script" ]; then
        err "generate-nginx.py not found"
        return 1
    fi

    local mode="http"
    local conf_name="${NGINX_CONF_NAME:-}"
    case "$conf_name" in
        *servera-ssl*)   mode="ssl-redirect" ;;
        *all-sites-ssl*) mode="ssl-combined" ;;
        *)               mode="http" ;;
    esac

    local gen_args=("--mode" "$mode" "--project-base" "$PROJECT_BASE")
    if [ -n "$DOMAIN" ] && [ -n "$WWW_DOMAIN" ]; then
        gen_args+=("--domain" "$DOMAIN" "--www-domain" "$WWW_DOMAIN")
    elif [ "$mode" != "http" ]; then
        warn "SSL 模式需要 DOMAIN 和 WWW_DOMAIN，回退到 http 模式"
        gen_args=("--mode" "http" "--project-base" "$PROJECT_BASE")
    fi

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        log "DRY RUN: 将动态生成 Nginx 配置 (mode=$mode)"
        python3 "$gen_script" "${gen_args[@]}" | head -20
        log "... (仅显示前 20 行)"
        return 0
    fi

    [ -f "$nginx_target" ] && cp "$nginx_target" "${nginx_target}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    python3 "$gen_script" "${gen_args[@]}" --output "$nginx_target"
    ok "Nginx 配置已动态生成 (mode=$mode)"

    disable_baota_nginx_conflicts

    if nginx -t 2>&1; then
        if nginx -s reload 2>&1; then
            ok "Nginx 配置已更新并重载"
        else
            warn "nginx -s reload 失败（可能是 PID 文件丢失），尝试 restart..."
            if /etc/init.d/nginx restart 2>&1; then
                ok "Nginx 已重启（restart fallback）"
            else
                err "Nginx 重启失败，请手动检查"
            fi
        fi
    else
        warn "Nginx 配置测试失败，请手动检查 $nginx_target"
        warn "可回滚: cp ${nginx_target}.bak.* $nginx_target && nginx -s reload"
    fi
}
