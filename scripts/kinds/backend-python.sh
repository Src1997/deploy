#!/usr/bin/env bash
# kind/python.sh — Python 后端部署流程（与通道无关，v2）
#
# 公共流程：deployHook（legacy，见注）或 默认流程（清空保留名单→解压→.env→
#           依赖→MCP 自动检测）→ 通道 install → 通道 restart → 健康门。
# 意图翻译：process.migrate → 部署时在 pkg_dir 执行迁移命令（venv 内）。
#
# ★deployHook 为 legacy 机制（financial-api 使用，scripts/deploy-python.sh）：
#   hook 负责代码+依赖+迁移，服务操作仍走通道动词；新项目不要再用 hook。

deploy_python() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local venv_dir="$pkg_dir/.venv" env_file="$pkg_dir/.env"

    log "部署 $id ($label) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (channel=$(channel_name))"
        return 0
    fi

    # ★legacy deployHook 仅限宝塔/原生通道（hook 内部是 supervisor/systemctl 语义）；
    #   docker 通道一律走默认流程（容器化），hook 的迁移逻辑由 process.migrate 表达
    if [ -n "${DEPLOY_HOOK[$id]:-}" ] && [ "${DEPLOY_CHANNEL:-}" != "docker" ]; then
        _python_deploy_via_hook "$id" "$pkg_dir" || return 1
    else
        _python_deploy_default "$id" "$pkg_dir" "$venv_dir" "$env_file" || return 1
    fi

    # ① 通道服务化安装（native=systemd 模板；baota/docker=no-op 或渲染）
    channel_python_install "$id" "$pkg_dir" || return 1

    # ② 重启 + 健康门
    if ! $NO_RESTART; then
        channel_python_restart "$id" "$pkg_dir" || return 1
        _kind_health_gate "$id" || return 1
    fi
}

# ── 默认流程 ──
_python_deploy_default() {
    local id="$1" pkg_dir="$2" venv_dir="$3" env_file="$4"

    local tar
    tar=$(_kind_find_artifact "$id") || return 1
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    # 清空保留名单（与 backup-rollback.sh 的回滚排除一致——铁律）
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    if ! tar xzf "$tar" -C "$pkg_dir"; then
        err "$id 解压失败: $tar"
        return 1
    fi
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    # 依赖安装（docker 通道跳过：依赖装进镜像）
    if [ "$(channel_wants_host_venv)" = "1" ]; then
        _python_install_deps "$pkg_dir" "$venv_dir" "${VENV_SHARED[$id]:-0}" || return 1
    else
        ok "docker 通道：依赖在镜像构建时安装，跳过宿主 venv"
    fi

    _kind_render_env "$id" "$env_file"

    # 迁移（意图键 process.migrate，venv 内执行）
    if [ -n "${PROC_MIGRATE[$id]:-}" ] && [ "$(channel_wants_host_venv)" = "1" ]; then
        log "执行迁移: ${PROC_MIGRATE[$id]}"
        (cd "$pkg_dir" && "$venv_dir/bin/${PROC_MIGRATE[$id]}") || {
            err "$id 迁移失败（新代码 + 旧 schema 的中间态不可上线）"
            return 1
        }
        ok "迁移完成"
    fi

    mkdir -p "$pkg_dir/logs" "$pkg_dir/data/memory" 2>/dev/null || true
}

# ── 宿主 venv 依赖安装内核（native/baota 通道专用）──
_python_install_deps() {
    local pkg_dir="$1" venv_dir="$2" venv_shared="$3"

    if [ "$venv_shared" = "1" ]; then
        if [ ! -d "$venv_dir" ]; then
            err "venv 不存在: $venv_dir（共享 venv 模式，请先部署主组件）"
            return 1
        fi
        ok "共享 venv: $venv_dir"
        return 0
    fi

    if [ ! -d "$venv_dir" ]; then
        log "创建虚拟环境..."
        python3 -m venv "$venv_dir"
        "$venv_dir/bin/pip" install --upgrade pip -q
    fi

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
}

# ── legacy deployHook 路径（financial-api 专用，迁移完成后退役）──
_python_deploy_via_hook() {
    local id="$1" pkg_dir="$2"
    local tar
    tar=$(_kind_find_artifact "$id") || return 1
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
    local cand
    for cand in "$DEPLOY_TMP_DIR/${id}-extract/scripts/$(basename "$hook_rel")" \
                "$DEPLOY_TMP_DIR/${id}-extract/package/scripts/$(basename "$hook_rel")" \
                "$DIST_ROOT/$hook_rel" \
                "$DIST_ROOT/$(basename "$hook_rel")" \
                "$SCRIPT_DIR_DEPLOY/../$hook_rel" \
                "$SCRIPT_DIR/$hook_rel" \
                "$SCRIPT_DIR_DEPLOY/$(basename "$hook_rel")"; do
        [ -f "$cand" ] && DEPLOY_SCRIPT="$cand" && break
    done
    if [ -z "$DEPLOY_SCRIPT" ]; then
        rm -rf "$DEPLOY_TMP_DIR/${id}-extract"
        err "未找到 deployHook: $hook_rel"
        return 1
    fi
    local yes_flag=""
    $ASSUME_YES && yes_flag="--yes"
    local hook_port=""
    hook_port=$(printf '%s' "${HEALTH_URL[$id]:-}" | sed -n 's|^[a-z]*://[^/]*:\([0-9][0-9]*\).*|\1|p')
    # 钩子内部失败不能降级成 warn：那会让「部署完成」落在「新代码+旧schema」中间态
    if ! DEPLOY_ROOT="$api_parent" PKG_DIR="$pkg_dir" \
        COMPONENT_ID="$id" \
        API_PORT="$hook_port" \
        SERVICES="${SERVICES[$id]:-}" \
        POST_DEPLOY_CHECK_PATH="${POST_DEPLOY_CHECK_PATH[$id]:-}" \
        WEB_PATH="${WEB_PATH[$id]:-}" \
        bash "$DEPLOY_SCRIPT" --no-restart $yes_flag; then
        err "$hook_rel 执行失败，中止 $id 部署"
        return 1
    fi
    rm -rf "$DEPLOY_TMP_DIR/${id}-extract"
    ok "$id 代码已同步（via deployHook）"
}
