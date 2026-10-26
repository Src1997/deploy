#!/usr/bin/env bash
# kind/frontend.sh — 前端组件部署流程（与通道无关，v2）
#
# 公共流程：通道前置（解析目标/建站）→ 找包 → 备份 → 通道资产保存 →
#           清空/解压 → 资产还原 → 完整性校验 → 单组件路由收口
# 通道分歧点全部在 channel_frontend_* 动词内（baota=站点SSOT+.user.ini，
# native/docker=deploy_path+nginx 路由）。

deploy_frontend() {
    local id="$1"
    local fallback_target="${DEPLOY_PATH[$id]:-}"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    local label="${PROJECT_DISPLAY_NAME[$id]:-$id}"

    [ -z "$fallback_target" ] && { err "TOML 配置缺少 $id.deployPath"; return 1; }
    [ -z "$tar_pat" ] && { err "TOML 配置缺少 $id.build.artifact"; return 1; }

    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id ($label) → $(channel_frontend_prepare "$id") (artifact=$tar_pat)"
        return 0
    fi

    # ① 通道前置：解析目标目录（baota=建站+站点SSOT+反代；native/docker=deploy_path）
    local target
    target=$(channel_frontend_prepare "$id") || return 1
    [ -z "$target" ] && target="$fallback_target"

    log "部署 $id ($label) → $target..."
    local tar
    tar=$(_kind_find_artifact "$id") || return 1
    backup_frontend "$id" "$target"

    # ② 通道资产保存 → 清空重建 → 解压 → 资产还原
    channel_frontend_preserve "$id" "$target"
    rm -rf "${target:?}"
    mkdir -p "$target"
    channel_frontend_restore "$id" "$target"
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

    # ── 子路径 SPA 自引用 symlink（2026-10-26 固化，取代手工补 ln -sfn）──
    # nginx alias+try_files 的 $uri 查找按 root 语义解析（已知坑）：
    # /admin/assets/x.js 会尝试 <alias>/admin/assets/x.js，dist 内必须有
    # dist/admin -> . 才能命中。sub 路径单源=TOML public_url，根站点无需。
    # ★dist 每次部署被整体替换，symlink 必须每次重建（此处即部署钩子内自动补）。
    case "${PUBLIC_URL[$id]:-}" in
        ""|"/") : ;;
        */)
            local _sub="${PUBLIC_URL[$id]#/}"
            _sub="${_sub%/}"
            if [ -n "$_sub" ] && [ ! -e "$target/$_sub" ]; then
                ln -sfn . "$target/$_sub" \
                    && ok "$id 自引用 symlink 已重建: dist/$_sub -> ." \
                    || warn "$id 自引用 symlink 创建失败: $target/$_sub"
            fi
            ;;
        *) : ;;
    esac

    # ③ 单组件路由收口（批量部署时延迟到全部前端完成后统一收口）
    if [ "${NGINX_SYNC_PENDING:-false}" != "true" ]; then
        channel_frontend_finalize "$id" "$target" ||
            warn "$id 路由收口未完成，可手动执行: bash deploy.sh --sync-nginx"
    fi
}
