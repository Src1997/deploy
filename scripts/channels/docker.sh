#!/usr/bin/env bash
# channel/docker/channel.sh — docker 通道（kind × channel 矩阵的 docker 实现，MVP）
#
# ⚠️ 状态：MVP 骨架（2026-10-22），未在真实 docker 主机全链路验证——
#         启用前先单组件试点（DEPLOY_CHANNEL=docker + 组件配 process.port/cmd）。
# 与宝塔不共存（registry 强制约束）：同一台服务器二选一。
#
# 意图翻译（TOML → docker）：
#   process(port,cmd) → Dockerfile（构建时 pip install）+ docker compose up -d；
#                       依赖装进镜像（channel_wants_host_venv=0）；
#                       MCP 伴随（mcp_server/ 子目录）在镜像内一并安装。
#   companions        → 预留（后续每伴随一个 compose service）
#   routes            → 宿主 nginx 代理到 127.0.0.1:<process.port>（路由后端 nginx.sh）
#
# ★容器内应用必须绑 0.0.0.0；端口发布绑定 127.0.0.1（路由由宿主 nginx 收口）。
#
# Depends on: DEPLOY_PATH, PROC_PORT, PROC_CMD, ROUTES_JSON, DIST_ROOT,
#             SCRIPT_DIR（deploy.sh 注入）；docker + compose 插件

_NG="$SCRIPT_DIR/channels/native-nginx.sh"
[ -f "$_NG" ] || _NG="$SCRIPT_DIR_DEPLOY/channels/native-nginx.sh"
# shellcheck disable=SC1090
source "$_NG"

channel_name()               { echo "docker（容器化）"; }
channel_supported_kinds()    { echo "frontend python"; }
channel_wants_host_venv()    { echo "0"; }
channel_routing_sync()       { sync_nginx; }

_docker_available() {
    command -v docker >/dev/null 2>&1 || { err "docker 未安装"; return 1; }
    docker info >/dev/null 2>&1 || { err "docker 守护进程不可用（docker info 失败）"; return 1; }
    docker compose version >/dev/null 2>&1 || { err "docker compose 插件不可用"; return 1; }
}

# ── frontend：静态资源 → 宿主目录（容器化无收益，落点/路由同 native）──
channel_frontend_prepare()   { echo "${DEPLOY_PATH[$1]:-}"; }
channel_frontend_preserve()  { :; }
channel_frontend_restore()   { :; }
channel_frontend_finalize() {
    local id="$1"
    if ! nginx_has_location "$id"; then
        warn "$id Nginx location not found in config — running sync-nginx"
        sync_nginx || warn "sync-nginx failed, continuing"
    fi
    nginx_reload_safe
}

# ── python：渲染 Dockerfile + compose（幂等，每次部署重新渲染）──
_docker_render_python_files() {
    local id="$1" pkg_dir="$2" port="$3" cmd="$4"
    # 启动命令缺省探测：gunicorn_config.py + run.py → gunicorn run:app
    if [ -z "$cmd" ]; then
        if [ -f "$pkg_dir/gunicorn_config.py" ] && [ -f "$pkg_dir/run.py" ]; then
            cmd="gunicorn -c gunicorn_config.py run:app"
        elif [ -f "$pkg_dir/run.py" ]; then
            cmd="python run.py"
        else
            err "$id 未配置 process.cmd 且无法自动探测启动命令"
            return 1
        fi
    fi
    # 容器内依赖装进系统 site-packages（无宿主 .venv），剥掉 venv 前缀
    cmd=$(printf '%s' "$cmd" | sed 's|\.venv/bin/||g')
    # app-package 打包布局（源码在 package/ 子目录）→ 容器 WORKDIR 对齐
    local app_copy="COPY . ."
    if [ -d "$pkg_dir/package" ] && [ -f "$pkg_dir/package/requirements.txt" ]; then
        app_copy="COPY package/ ./"
    fi
    cat > "$pkg_dir/Dockerfile" <<EOF
# 由 deploy 工具箱 docker 通道渲染（每次部署覆盖；手改无效）
FROM python:3.12-slim
WORKDIR /app
# 国内 pip 源（容器不继承宿主 pip.conf；腾讯源，VM 家宽实证可用）
RUN pip config set global.index-url https://mirrors.cloud.tencent.com/pypi/simple
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
${app_copy}
EOF
    # MCP 伴随服务（deepquant 约定：mcp_server/ 子目录；app-package 布局在 package/ 下）
    local mcp_rel="mcp_server"
    [ -d "$pkg_dir/package/mcp_server" ] && mcp_rel="package/mcp_server"
    if [ -d "$pkg_dir/$mcp_rel" ] && [ -f "$pkg_dir/$mcp_rel/pyproject.toml" ]; then
        cat >> "$pkg_dir/Dockerfile" <<MCPDOG
RUN pip install --no-cache-dir ./${mcp_rel}
MCPDOG
    fi
    cat >> "$pkg_dir/Dockerfile" <<EOF
EXPOSE ${port}
CMD ["bash", "-c", "${cmd}"]
EOF

    local companions_block="${COMPANION_SERVICES[$id]:-}"
    cat > "$pkg_dir/docker-compose.yml" <<EOF
# 由 deploy 工具箱 docker 通道渲染（每次部署覆盖）
# ★host 网络：容器内 127.0.0.1 = 宿主（PG/Redis 等基础设施无需改地址）；
#   应用按 process.port 直接监听宿主端口，路由由宿主 nginx 收口
services:
  ${id}:
    build: .
    container_name: ${id}
    restart: unless-stopped
    network_mode: host
    env_file:
      - path: .env
        required: false
${companions_block}
EOF
}

channel_python_install() {
    local id="$1" pkg_dir="$2"
    _docker_available || return 1
    local port="${PROC_PORT[$id]:-}"
    [ -z "$port" ] && { err "TOML 缺少 $id.process.port（docker 通道必需）"; return 1; }
    _docker_render_python_files "$id" "$pkg_dir" "$port" "${PROC_CMD[$id]:-}" || return 1
    ok "$id Dockerfile/compose 已渲染 (port=$port)"
}

channel_python_restart() {
    local id="$1" pkg_dir="$2"
    # 伴随服务无容器化意图（纯名字形式）→ 明确告知（compose 里不会有该容器）
    if [ -n "${COMPANIONS[$id]:-}" ] && [ -z "${COMPANION_SERVICES[$id]:-}" ]; then
        warn "$id 伴随服务（${COMPANIONS[$id]}）无 cmd 意图，docker 通道不为其建容器（对象形式 companions 可补）"
    fi
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        ok "[DRY_RUN] $id → docker compose up -d --build"
        return 0
    fi
    (cd "$pkg_dir" && docker compose up -d --build) || {
        err "$id docker compose 启动失败（查看: docker compose -f $pkg_dir/docker-compose.yml logs）"
        return 1
    }
    ok "$id 容器已构建并启动"
    # 应用冷启动慢于宿主进程 → 轮询端口就绪再返回（与 baota_restart_python 同模式）
    local port="${PROC_PORT[$1]:-}" i
    if [ -n "$port" ]; then
        for i in $(seq 1 30); do
            sleep 2
            if ss -ltn 2>/dev/null | grep -q ":${port} "; then
                ok "$id 端口 $port 就绪（${i}x2s）"
                return 0
            fi
        done
        warn "$id 端口 $port ${i}x2s 未监听（健康门将继续探测）"
    fi
}

# ── java：MVP 不覆盖（无真实需求；实现时参照 python 渲染模式）──
channel_java_install() {
    err "docker 通道暂不支持 java kind（见 CHANNEL-CONTRACT.md）"
    return 1
}
channel_java_restart() {
    err "docker 通道暂不支持 java kind（见 CHANNEL-CONTRACT.md）"
    return 1
}

# ── 服务状态/操作（docker ps / compose）──

channel_service_running() {
    local svc="$1"
    [ "$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null)" = "true" ]
}

channel_service_restart() {
    local svc="$1"
    docker restart "$svc" >/dev/null 2>&1
}

channel_status() {
    local -a services=()
    local -A seen=()
    local p svc
    for p in "${PROJECTS[@]}"; do
        for svc in ${SERVICES[$p]:-}; do
            [ -n "$svc" ] && [ -z "${seen[$svc]:-}" ] && services+=("$svc") && seen[$svc]=1
        done
    done

    printf "  %-22s %-10s %s\n" "CONTAINER" "STATUS" "HEALTH"
    hr
    for svc in "${services[@]}"; do
        local status health=""
        if channel_service_running "$svc"; then
            status=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo "running")
        else
            status="not-found"
        fi
        local color="$RED"
        [ "$status" = "running" ] && color="$GREEN"
        for p in "${PROJECTS[@]}"; do
            if echo "${SERVICES[$p]:-}" | grep -qw "$svc"; then
                local hurl="${HEALTH_URL[$p]:-}"
                [ -n "$hurl" ] && health=$(curl -sf --max-time 5 "$hurl" 2>/dev/null | head -c 60 || echo "FAIL")
                break
            fi
        done
        [ -z "$health" ] && health="-"
        printf "  %-22s ${color}%-10s${NC} %s\n" "$svc" "$status" "$health"
    done
    echo ""
}

channel_logs() {
    local svc="$1" mode="${2:-50}"
    [ -z "$svc" ] && { err "未指定容器"; return 1; }
    case "$mode" in
        follow) docker logs -f "$svc" ;;
        *)      docker logs --tail "$mode" "$svc" ;;
    esac
}
