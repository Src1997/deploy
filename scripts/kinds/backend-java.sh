#!/usr/bin/env bash
# kind/java.sh — Java 后端部署流程（与通道无关，v2）
#
# 公共流程：找包 → 备份 → 清空/解压（保留 .env/logs/data）→ .env 渲染 →
#           通道 install → 通道 restart → 健康门。
# 意图翻译：process.jar/jdk（baota 建项目用）、companions/systemd 单元名（native）。

deploy_java() {
    local id="$1"
    local pkg_dir="${DEPLOY_PATH[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"
    local env_file="$pkg_dir/.env"

    log "部署 $id ($label, Java) → $pkg_dir ..."
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → $pkg_dir (channel=$(channel_name))"
        return 0
    fi

    local tar
    tar=$(_kind_find_artifact "$id") || return 1
    backup_backend "$id" "$pkg_dir"
    mkdir -p "$pkg_dir"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak"
    find "$pkg_dir" -mindepth 1 -maxdepth 1 \
        ! -name '.env' ! -name 'logs' ! -name 'data' \
        -exec rm -rf {} + 2>/dev/null || true
    if ! tar xzf "$tar" -C "$pkg_dir"; then
        err "$id 解压失败: $tar"
        return 1
    fi
    ok "代码已解压"
    [ -f "$env_file.bak" ] && cp "$env_file.bak" "$env_file" && rm -f "$env_file.bak"

    _kind_render_env "$id" "$env_file"

    mkdir -p "$pkg_dir/logs"

    # ① 通道服务化安装 ② 重启 + 健康门
    channel_java_install "$id" "$pkg_dir" || return 1
    if ! $NO_RESTART; then
        channel_java_restart "$id" "$pkg_dir" || return 1
        _kind_health_gate "$id" || return 1
    fi
}
