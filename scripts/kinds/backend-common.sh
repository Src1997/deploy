#!/usr/bin/env bash
# kind/backend/_common.sh — 后端公共设施（v2）
#
# 后端 = kind/backend/，按语言再分（python.sh / java.sh，新语言照此扩展）。
# 语言无关的后端公共逻辑放本文件；项目差异一律在 project.toml。

# -- .env 模板渲染（后端各语言共用；首次部署时从模板生成）--
_kind_render_env() {
    local id="$1" env_file="$2"
    if [ -f "$env_file" ]; then
        ok ".env 已存在，保留"
        return 0
    fi
    log "首次部署：从模板生成 .env..."
    local template=""
    local t
    for t in "$CONFIGS_SRC/${PROJECT_ID[$id]:-}.env.example" \
             "$CONFIGS_SRC/${id%%-*}.env.example" \
             "$DIST_ROOT/assets/${PROJECT_ID[$id]:-}.env.example" \
             "$DIST_ROOT/assets/${id%%-*}.env.example"; do
        [ -f "$t" ] && template="$t" && break
    done
    if [ -z "$template" ]; then
        warn "未找到 .env.example 模板，请手动创建: $env_file"
        return 0
    fi
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
    ok ".env 已生成（从模板 $template）"
}
