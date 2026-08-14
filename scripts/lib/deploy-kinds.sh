#!/usr/bin/env bash
# lib/deploy-kinds.sh — Per-kind deployment functions for deploy.sh
#
# Provides: deploy_frontend_by_id, deploy_python, deploy_java, deploy_go,
#           deploy_nodejs, deploy_by_id
#
# Depends on: DEPLOY_PATH, ARTIFACT_NAME, PROJECT_DISPLAY_NAME, PROJECT_KIND,
#             DEPLOY_HOOK, HEALTH_URL, SERVICES, NGINX_RELOAD, VENV_SHARED,
#             PROJECT_ROOT, PUBLIC_URL, DEPLOY_DRY_RUN, NO_RESTART,
#             PACKAGES_DIR, CONFIGS_SRC, DIST_ROOT, DEPLOY_TMP_DIR,
#             PG_PASSWORD, REDIS_PASSWORD, SERVER_IP, FRONTEND_URL,
#             ADMIN_PASSWORD, MCP_AGENT_TOKEN, ASSUME_YES, SCRIPT_DIR,
#             SCRIPT_DIR_DEPLOY, find_file, check_package_freshness,
#             backup_frontend, backup_backend, restart_service, health_check,
#             nginx_reload, nginx_has_location, sync_nginx

# -- Deploy frontend: extract to DEPLOY_PATH[id] --
deploy_frontend_by_id() {
    local id="$1"
    local target="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"

    [ -z "$target" ] && { err "TOML 配置缺少 $id.deployPath"; return 1; }
    [ -z "$tar_pat" ] && { err "TOML 配置缺少 $id.build.artifact"; return 1; }

    log "部署 $id ($label)..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $target (artifact=$tar_pat)"
        return 0
    fi
    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
    check_package_freshness "$tar" "$id"
    backup_frontend "$id" "$target"
    rm -rf "${target:?}"
    mkdir -p "$target"
    if ! tar xzf "$tar" -C "$target"; then
        err "$id 解压失败: $tar"
        return 1
    fi
    local tar_files extracted_files
    tar_files=$(tar tzf "$tar" 2>/dev/null | grep -c -v '/$' || echo 0)
    extracted_files=$(find "$target" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$extracted_files" -lt "$tar_files" ]; then
        warn "$id 解压可能不完整: tar=$tar_files extracted=$extracted_files"
    fi
    ok "$id 已部署到 $target"

    # In batch mode, defer nginx sync to the end (NGINX_SYNC_PENDING)
    # to avoid repeated generate + reload cycles.
    if [ "${NGINX_SYNC_PENDING:-false}" != "true" ]; then
        if ! nginx_has_location "$id"; then
            warn "$id Nginx location not found in config — running sync-nginx"
            sync_nginx || warn "sync-nginx failed, continuing"
        fi
        if [ "${NGINX_RELOAD[$id]}" = "true" ]; then
            nginx_reload
        fi
    fi
}

# -- Deploy Python backend: deployHook or venv+pip+systemd --
deploy_python() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local venv_dir="$pkg_dir/.venv" env_file="$pkg_dir/.env"

    log "部署 $id ($label) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    # If deployHook is set, use it
    if [ -n "${DEPLOY_HOOK[$id]:-}" ]; then
        local tar
        tar=$(find_file "$tar_pat")
        [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
        check_package_freshness "$tar" "$id"
        backup_backend "$id" "$pkg_dir"
        local api_parent
        api_parent="$(dirname "$pkg_dir")"
        find "$api_parent" -maxdepth 1 -name "${id}-*.tar.gz" -delete 2>/dev/null || true
        mkdir -p "$api_parent"
        cp "$tar" "$api_parent/"
        mkdir -p "$DEPLOY_TMP_DIR/${id}-extract"
        tar xzf "$tar" -C "$DEPLOY_TMP_DIR/${id}-extract"
        local DEPLOY_SCRIPT=""
        local hook_rel="${DEPLOY_HOOK[$id]}"
        for cand in "$DEPLOY_TMP_DIR/${id}-extract/scripts/$(basename "$hook_rel")" \
                    "$DEPLOY_TMP_DIR/${id}-extract/package/scripts/$(basename "$hook_rel")" \
                    "$DIST_ROOT/$hook_rel" \
                    "$SCRIPT_DIR_DEPLOY/../$hook_rel" \
                    "$SCRIPT_DIR/$hook_rel"; do
            [ -f "$cand" ] && DEPLOY_SCRIPT="$cand" && break
        done
        if [ -n "$DEPLOY_SCRIPT" ]; then
            local yes_flag=""
            $ASSUME_YES && yes_flag="--yes"
            DEPLOY_ROOT="$api_parent" PKG_DIR="$pkg_dir" \
                bash "$DEPLOY_SCRIPT" --no-restart $yes_flag || warn "$hook_rel 有警告"
            ok "$id 代码已同步（via deployHook）"
        else
            rm -rf "$DEPLOY_TMP_DIR/${id}-extract"
            err "未找到 deployHook: $hook_rel"; return 1
        fi
        rm -rf "$DEPLOY_TMP_DIR/${id}-extract"
    else
        # Default flow: extract + venv + pip + systemd
        local tar
        tar=$(find_file "$tar_pat")
        [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
        check_package_freshness "$tar" "$id"
        backup_backend "$id" "$pkg_dir"
        mkdir -p "$pkg_dir"
        [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
        find "$pkg_dir" -mindepth 1 -maxdepth 1 \
            ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
            -exec rm -rf {} + 2>/dev/null || true
        tar xzf "$tar" -C "$pkg_dir"
        ok "代码已解压"
        [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

        # -- Venv --
        if [ "${VENV_SHARED[$id]:-0}" = "1" ]; then
            if [ ! -d "$venv_dir" ]; then
                err "venv 不存在: $venv_dir（共享 venv 模式，请先部署主组件）"
                return 1
            fi
            ok "共享 venv: $venv_dir"
        else
            if [ ! -d "$venv_dir" ]; then
                log "创建虚拟环境..."
                python3 -m venv "$venv_dir"
                "$venv_dir/bin/pip" install --upgrade pip -q
            fi
        fi

        # Install dependencies
        log "安装依赖..."
        if [ -f "$pkg_dir/requirements.txt" ]; then
            "$venv_dir/bin/pip" install -r "$pkg_dir/requirements.txt" -q 2>&1 | tail -3
        elif [ -f "$pkg_dir/pyproject.toml" ]; then
            (cd "$pkg_dir" && "$venv_dir/bin/pip" install -e "." -q 2>&1 | tail -3)
        else
            warn "未找到 requirements.txt 或 pyproject.toml，跳过依赖安装"
        fi

        # Auto-detect MCP server subdirectory
        local mcp_src_dir="$pkg_dir/mcp_server"
        if [ -d "$mcp_src_dir" ] && [ -f "$mcp_src_dir/pyproject.toml" ]; then
            log "检测到 MCP Server，安装到 venv..."
            "$venv_dir/bin/pip" uninstall mcp mcp-types -y -q 2>/dev/null || true
            "$venv_dir/bin/pip" install "$mcp_src_dir" -q 2>&1 | tail -3
            ok "MCP Server 包已安装"
        fi

        # Generate .env from template if first deploy
        if [ ! -f "$env_file" ]; then
            log "首次部署：从模板生成 .env..."
            local template=""
            for t in "$CONFIGS_SRC/${id%%-*}.env.example" \
                     "$CONFIGS_SRC/${PROJECT_ID[$id]:-}.env.example" \
                     "$DIST_ROOT/configs/${id%%-*}.env.example" \
                     "$(dirname "$0")/configs/${id%%-*}.env.example"; do
                [ -f "$t" ] && template="$t" && break
            done
            if [ -n "$template" ]; then
                local secret_key admin_pw
                secret_key=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || echo "CHANGE_ME_SECRET_KEY")
                admin_pw="${ADMIN_PASSWORD:-CHANGE_ME}"
                sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                    -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                    -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                    -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                    -e "s|__SECRET_KEY__|${secret_key}|g" \
                    -e "s|__ADMIN_PASSWORD__|${admin_pw}|g" \
                    "$template" > "$env_file"
                chmod 600 "$env_file"
                ok ".env 已生成（从模板）"
            else
                warn "未找到 .env.example 模板，请手动创建: $env_file"
            fi
        else
            ok ".env 已存在，保留"
        fi

        # Install systemd services
        local svc
        for svc in ${SERVICES[$id]}; do
            [ -z "$svc" ] && continue
            local svc_file="/etc/systemd/system/${svc}.service"
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$CONFIGS_SRC/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                if [ -f "$svc_file" ]; then
                    ok "${svc}.service 已存在，更新模板..."
                else
                    log "安装 ${svc}.service..."
                fi
                local mcp_token="${MCP_AGENT_TOKEN:-CHANGE_ME_MCP_TOKEN}"
                if [ "$mcp_token" = "CHANGE_ME_MCP_TOKEN" ] && echo "$svc_template" | grep -q '__MCP_AGENT_TOKEN__'; then
                    warn "MCP_AGENT_TOKEN 未配置，MCP 服务无法通过认证"
                fi
                sed -e "s|__MCP_AGENT_TOKEN__|${mcp_token}|g" \
                    "$svc_template" > "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc" 2>/dev/null || true
                ok "${svc}.service 已安装并启用"
            else
                if [ ! -f "$svc_file" ]; then
                    warn "未找到 ${svc}.service 模板"
                else
                    ok "${svc}.service 已存在"
                fi
            fi
        done

        mkdir -p "$pkg_dir/logs" "$pkg_dir/data/memory" 2>/dev/null || true
    fi

    # Restart services + health check
    if ! $NO_RESTART; then
        local svc
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# -- Deploy Java backend: JAR/WAR + systemd --
deploy_java() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Java) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
    check_package_freshness "$tar" "$id"
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    # Generate .env from template if first deploy
    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/${id}.env.example" \
                 "$DIST_ROOT/configs/${id}.env.example" \
                 "$(dirname "$0")/configs/${id}.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    # Install systemd services if first deploy
    local svc
    for svc in ${SERVICES[$id]}; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        if [ ! -f "$svc_file" ]; then
            log "首次部署：安装 ${svc}.service..."
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                cp "$svc_template" "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc"
                ok "${svc}.service 已安装并启用"
            else
                warn "未找到 ${svc}.service 模板"
            fi
        else
            ok "${svc}.service 已存在"
        fi
    done

    mkdir -p "$pkg_dir/logs"

    if ! $NO_RESTART; then
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# -- Deploy Go backend: binary + systemd --
deploy_go() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Go) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
    check_package_freshness "$tar" "$id"
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    local bin_file=""
    for f in "$pkg_dir"/bin/* "$pkg_dir"/*.bin "$pkg_dir"/main; do
        [ -f "$f" ] && chmod +x "$f" && bin_file="$f" && break
    done
    [ -n "$bin_file" ] && ok "可执行文件: $bin_file" || warn "未找到二进制文件，请检查包结构"

    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/${id}.env.example" \
                 "$DIST_ROOT/configs/${id}.env.example" \
                 "$(dirname "$0")/configs/${id}.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    local svc
    for svc in ${SERVICES[$id]}; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        if [ ! -f "$svc_file" ]; then
            log "首次部署：安装 ${svc}.service..."
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                cp "$svc_template" "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc"
                ok "${svc}.service 已安装并启用"
            else
                warn "未找到 ${svc}.service 模板"
            fi
        else
            ok "${svc}.service 已存在"
        fi
    done

    mkdir -p "$pkg_dir/logs"

    if ! $NO_RESTART; then
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# -- Deploy Node.js backend: source + npm ci + systemd --
deploy_nodejs() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Node.js) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (artifact=$tar_pat hook=${DEPLOY_HOOK[$id]:-none})"
        return 0
    fi

    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
    check_package_freshness "$tar" "$id"
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'node_modules' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    tar xzf "$tar" -C "$pkg_dir"
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    if [ -f "$pkg_dir/package.json" ]; then
        log "安装生产依赖 (npm ci --production)..."
        (cd "$pkg_dir" && npm ci --production 2>&1 | tail -5) || {
            warn "npm ci 失败，尝试 npm install --production"
            (cd "$pkg_dir" && npm install --production 2>&1 | tail -5) || warn "npm install 也失败"
        }
    else
        warn "未找到 package.json，跳过依赖安装"
    fi

    if [ ! -f "$env_file" ]; then
        log "首次部署：从模板生成 .env..."
        local template=""
        for t in "$CONFIGS_SRC/${id}.env.example" \
                 "$DIST_ROOT/configs/${id}.env.example" \
                 "$(dirname "$0")/configs/${id}.env.example"; do
            [ -f "$t" ] && template="$t" && break
        done
        if [ -n "$template" ]; then
            sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
                -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
                -e "s|__SERVER_IP__|${SERVER_IP:-127.0.0.1}|g" \
                -e "s|__FRONTEND_URL__|${FRONTEND_URL:-http://${SERVER_IP:-127.0.0.1}}|g" \
                "$template" > "$env_file"
            chmod 600 "$env_file"
            ok ".env 已生成（从模板 $template）"
        else
            warn "未找到 ${id}.env.example 模板，请手动创建: $env_file"
        fi
    else
        ok ".env 已存在，保留"
    fi

    local svc
    for svc in ${SERVICES[$id]}; do
        [ -z "$svc" ] && continue
        local svc_file="/etc/systemd/system/${svc}.service"
        if [ ! -f "$svc_file" ]; then
            log "首次部署：安装 ${svc}.service..."
            local svc_template=""
            for t in "$CONFIGS_SRC/systemd/${svc}.service" \
                     "$DIST_ROOT/configs/systemd/${svc}.service" \
                     "$(dirname "$0")/configs/systemd/${svc}.service"; do
                [ -f "$t" ] && svc_template="$t" && break
            done
            if [ -n "$svc_template" ]; then
                cp "$svc_template" "$svc_file"
                systemctl daemon-reload
                systemctl enable "$svc"
                ok "${svc}.service 已安装并启用"
            else
                warn "未找到 ${svc}.service 模板"
            fi
        else
            ok "${svc}.service 已存在"
        fi
    done

    mkdir -p "$pkg_dir/logs"

    if ! $NO_RESTART; then
        for svc in ${SERVICES[$id]}; do
            [ -n "$svc" ] && restart_service "$svc"
        done
        if [ -n "${HEALTH_URL[$id]:-}" ]; then
            sleep 3
            health_check "$id" "${HEALTH_URL[$id]}"
        fi
    fi
}

# -- Dispatch deployment by kind --
deploy_by_id() {
    local id="$1"
    if [ -z "${DEPLOY_PATH[$id]:-}" ]; then
        err "未知项目或不在 TOML 配置中: $id"
        return 1
    fi
    case "${PROJECT_KIND[$id]}" in
        frontend) deploy_frontend_by_id "$id" ;;
        python)   deploy_python "$id" ;;
        java)     deploy_java "$id" ;;
        go)       deploy_go "$id" ;;
        nodejs)   deploy_nodejs "$id" ;;
        *)
            err "未知 kind: ${PROJECT_KIND[$id]:-?} ($id)"
            return 1
            ;;
    esac
}
