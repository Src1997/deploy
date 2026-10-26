#!/usr/bin/env bash
# channel/baota/channel.sh — 宝塔通道（kind × channel 矩阵的 baota 实现，v2）
#
# 方向（2026-10-20 用户定）：所有部署成果必须在宝塔面板原生出现、原生可管。
# ★v2 所有权原则「宝塔就全宝塔」：本通道的一切服务操作只走
#   面板 API（baota_api.py）+ 宝塔 supervisor 插件，不碰 systemd、
#   不碰宿主 nginx conf（路由由面板站点 + 原生反代全权管理）。
#
# 意图翻译（TOML → 宝塔）：
#   routes(proxy/websocket) → CreateProxy 原生反代（建站后自动创建）
#   process(port,cmd)       → 宝塔 Python 项目（缺失自动从零创建）名为组件 id
#   companions              → 宝塔 supervisor 程序（伴随服务）
#
# Depends on: BAOTA_PANEL_URL, BAOTA_API_KEY, BAOTA_PYTHON, BAOTA_SUPERVISORCTL,
#             DEPLOY_PATH, PROC_PORT, PROC_CMD, COMPANIONS, ROUTES_JSON,
#             DEPLOY_TMP_DIR, DEPLOY_DRY_RUN, SCRIPT_DIR（deploy.sh 注入）

_BAOTA_API_PY="$SCRIPT_DIR/channels/baota-api.py"

# -- 面板 API 可用性 --
baota_enabled() {
    [ -n "${BAOTA_PANEL_URL:-}" ] && [ -n "${BAOTA_API_KEY:-}" ]
}

# -- 调 baota_api.py（单通道；面板 Python 优先，兼容系统 python3）--
baota_cli() {
    [ ! -f "$_BAOTA_API_PY" ] && { err "baota_api.py 不存在: $_BAOTA_API_PY"; return 1; }
    BAOTA_PANEL_URL="$BAOTA_PANEL_URL" BAOTA_API_KEY="$BAOTA_API_KEY" \
        "${BAOTA_PYTHON:-python3}" "$_BAOTA_API_PY" "$@"
}

# -- supervisorctl（宝塔 supervisor 插件）--
_baota_sctl() {
    echo "${BAOTA_SUPERVISORCTL:-/www/server/panel/pyenv/bin/supervisorctl}"
}

# ═══════════════════════════════════════════════════════════════════════
# 底层封装（建站 / 项目 / 反代 / supervisor）
# ═══════════════════════════════════════════════════════════════════════

# -- HTML 站点 --
# ★conf 命名约定（2026-10-23 B/C 实证）：面板对 project_type='html' 的站点，
#   流量限制/网站日志/伪静态等新模型功能一律按 vhost/nginx/html_<站点名>.conf
#   读取（无兜底）；面板原生 htmlModel 写 conf 也用该名。AddSite 旧链路建站
#   会生成无前缀 <站点名>.conf → 面板报「配置文件读取错误/站点配置文件丢失」。
#   重建站点后必须确认 conf 文件名带 html_ 前缀（rewrite 目录同理）。
baota_ensure_html_site() {
    local site="$1" path="$2" ps="${3:-deploy toolbox 管理}"
    local out
    if ! out=$(baota_cli ensure-html-site "$site" "$path" "$ps" 2>&1); then
        err "宝塔建站失败: $site → $path"
        [ -n "$out" ] && err "  $out"
        return 1
    fi
    # conf 命名自愈提示（fix_html_conf_naming 的产物，详见 baota-api.py）
    if echo "$out" | grep -q 'conf_naming_fixed'; then
        warn "conf 命名已对齐面板 html_ 约定: $(echo "$out" | grep -o 'conf_naming_fixed.*')"
    fi
    ok "宝塔站点就绪: $site ($path)"
}

# ★坑1（首次创建）：面板建项目后异步做「环境安装制作」，期间 RestartProject
#   被面板拒绝（msg 含「环境安装制作中」）——需等待重试。
# ★坑2（重启竞态）：RestartProject = stop + start 立即连发，旧 gunicorn 优雅
#   退出需数秒；start 前有端口占用检查，旧进程未退时 start 被静默拒绝 → 502。
# 兜底：restart 失败且提示制作中 → 轮询重试；重启后轮询端口，超时补 StartProject。
baota_restart_python() {
    local name="$1" port="${2:-}"
    local out attempt restarted
    out=$(baota_cli restart-python "$name" 2>&1) && restarted=1 || restarted=0
    if [ "$restarted" != "1" ]; then
        case "$out" in
            *制作中*|*请勿操作*)
                # ★新建项目首次启动前面板要异步准备环境，B 机实测可超 60s → 窗口 5 分钟
                for attempt in $(seq 1 30); do
                    sleep 10
                    log "面板环境制作中，等待重试 (${attempt}/30): $name"
                    if out=$(baota_cli restart-python "$name" 2>&1); then
                        restarted=1; break
                    fi
                    case "$out" in *制作中*|*请勿操作*) ;; *)
                        err "宝塔 Python 项目重启失败: $name"; err "  $out"; return 1 ;;
                    esac
                done
                [ "$restarted" != "1" ] && { err "等待 60s 后仍『环境安装制作中』: $name"; return 1; }
                ;;
            *)
                err "宝塔 Python 项目重启失败: $name"
                err "  $out"
                return 1
                ;;
        esac
    fi
    if [ -n "$port" ]; then
        local i up=0
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            sleep 1
            if ss -ltn 2>/dev/null | grep -q ":${port} "; then up=1; break; fi
        done
        if [ "$up" != "1" ]; then
            warn "重启后 ${port} 端口 ${i}s 未监听（疑似端口竞态），补一次 StartProject..."
            baota_cli start-python "$name" >/dev/null 2>&1 || true
            for i in 1 2 3 4 5 6 7 8; do
                sleep 1
                if ss -ltn 2>/dev/null | grep -q ":${port} "; then up=1; break; fi
            done
        fi
        [ "$up" = "1" ] && ok "宝塔 Python 项目已重启: $name (port=$port 就绪)" ||
            err "宝塔 Python 项目重启后端口未就绪: $name (port=$port)"
        [ "$up" = "1" ]
        return
    fi
    ok "宝塔 Python 项目已重启: $name"
}

# -- Python 项目从零确保（缺失 → venv 注册 + CreateProject + StartProject）--
# cmd 为相对 deploy_path 的意图命令（.venv/bin/gunicorn ...），此处拼绝对路径
#（面板进程 PATH 不含项目 venv，命令必须可独立执行）
baota_ensure_python_project() {
    local id="$1" pkg_dir="$2"
    local port="${PROC_PORT[$id]:-}"
    local cmd="${PROC_CMD[$id]:-}"
    [ -z "$port" ] && { err "TOML 缺少 $id.process.port"; return 1; }
    [ -z "$cmd" ] && { err "TOML 缺少 $id.process.cmd"; return 1; }
    [[ "$cmd" != /* ]] && cmd="$pkg_dir/$cmd"
    local out
    if ! out=$(baota_cli ensure-python "$id" "$pkg_dir" "$port" \
               "$pkg_dir/.venv" "$cmd" 2>&1); then
        err "宝塔 Python 项目确保失败: $id"
        err "  $out"
        return 1
    fi
    case "$out" in
        *exists*)
            ok "宝塔 Python 项目已存在: $id"
            # 配置漂移检测：面板记录端口 ≠ TOML 声明 → 多半是面板里手改过，
            # 下次重启仍按面板值起，与意图模型背离——提前暴露而非静默
            local pstat
            pstat=$(baota_cli python-status "$id" 2>/dev/null || echo "")
            if [ -n "$pstat" ] && ! echo "$pstat" | grep -Eq "\"port\": ?${port}[,}]"; then
                warn "端口漂移: 面板记录 ≠ TOML($port)。面板: $pstat"
                warn "  如需以 TOML 为准，请面板删除该项目后重新部署（会重建 venv 注册）"
            fi
            ;;
        *)         ok "宝塔 Python 项目已创建并启动: $id (port=$port)" ;;
    esac
}

# -- Java（Spring Boot）项目从零确保 --
# 意图键：process.jar（相对 deploy_path）/ process.jdk（JDK bin 绝对路径）
baota_ensure_java_project() {
    local id="$1" pkg_dir="$2"
    local port="${PROC_PORT[$id]:-}"
    local cmd="${PROC_CMD[$id]:-}"
    local jar="${PROC_JAR[$id]:-}"
    local jdk="${PROC_JDK[$id]:-}"
    [ -z "$port" ] && { err "TOML 缺少 $id.process.port"; return 1; }
    [ -z "$cmd" ] && { err "TOML 缺少 $id.process.cmd"; return 1; }
    [ -z "$jar" ] && { err "TOML 缺少 $id.process.jar"; return 1; }
    [ -z "$jdk" ] && { err "TOML 缺少 $id.process.jdk"; return 1; }
    [[ "$cmd" != /* ]] && cmd="$pkg_dir/$cmd"
    [[ "$jar" != /* ]] && jar="$pkg_dir/$jar"
    local out
    if ! out=$(baota_cli ensure-java "$id" "$jar" "$jdk" "$cmd" "$port" 2>&1); then
        err "宝塔 Java 项目确保失败: $id"
        err "  $out"
        return 1
    fi
    ok "宝塔 Java 项目就绪: $id (port=$port)"
}

baota_restart_supervisor() {
    local programs="$1"
    [ -z "$programs" ] && return 0
    local sctl; sctl=$(_baota_sctl)
    if [ ! -x "$sctl" ]; then
        err "supervisorctl 不存在: $sctl（宝塔 supervisor 插件未安装？）"
        return 1
    fi
    # ★supervisor 的 restart 不会重读 ini（environment/command 变更不生效）——
    #   2026-10-23 B 实证：改 QUANTDINGER_MCP_TRANSPORT 后仅 restart 仍按旧值起。
    #   必须 reread + update 让 ini 变更先落库（无变更时二者为 no-op，幂等安全）。
    "$sctl" reread >/dev/null 2>&1 || true
    "$sctl" update  >/dev/null 2>&1 || true
    if ! "$sctl" restart $programs >/dev/null 2>&1; then
        err "supervisor 服务重启失败: $programs"
        return 1
    fi
    ok "supervisor 服务已重启: $programs"
}

baota_ensure_proxy() {
    local site="$1" name="$2" dir="$3" target="$4"
    # 幂等：已存在同名目录代理 → 跳过（重复 CreateProxy 会被面板拒绝）
    if baota_cli list-proxy "$site" 2>/dev/null | grep -q "^${dir}|"; then
        ok "宝塔反向代理已存在: $site $dir → $target"
        return 0
    fi
    if ! baota_cli create-proxy "$site" "$name" "$dir" "$target" >/dev/null; then
        err "宝塔反向代理创建失败: $site $dir → $target"
        return 1
    fi
    ok "宝塔反向代理就绪: $site $dir → $target"
}

# -- 批量确保反向代理：specs 形如 "/api/|http://127.0.0.1:5000/api/ ..." --
# 代理名 = 去斜杠 + "-proxy"（面板要求名称 >3 字符）
baota_ensure_proxies() {
    local site="$1" specs="$2"
    [ -z "$specs" ] && return 0
    local spec dir target name
    for spec in $specs; do
        dir="${spec%%|*}"
        target="${spec#*|}"
        name="${dir//\//}-proxy"
        baota_ensure_proxy "$site" "$name" "$dir" "$target" || return 1
    done
}

# ═══════════════════════════════════════════════════════════════════════
# 统一动词层（CHANNEL-CONTRACT.md）—— kind 层与 deploy.sh 只调这一层
# ═══════════════════════════════════════════════════════════════════════

channel_name()               { echo "baota（宝塔面板原生）"; }
channel_supported_kinds()    { echo "frontend python java"; }
channel_wants_host_venv()    { echo "1"; }

channel_routing_sync() {
    # 生成器接管模式：与 native/docker 一致，由 generate-nginx 收口单 vhost
    if baota_nginx_generated; then
        sync_nginx
        return $?
    fi
    # 面板管理模式：路由由面板站点 + 原生反代全权管理，工具箱无需（也不可）收口
    ok "宝塔通道路由由面板管理，无需收口（调整路由：面板 → 网站 → 反向代理）"
    return 0
}

# ── frontend ──

# ★生成器接管路由模式（2026-10-26 VM 预发）：BAOTA_NGINX_GENERATED=1 时，
# 宝塔机器不建面板 HTML 站点/原生反代（消灭 html_*.conf / port_*.conf 手工
# 补丁层），路由统一由 generate-nginx.py 从 TOML 生成单 vhost——
# 监听端口 NGINX_LISTEN_PORT（VM 预发=8081），目标 default.conf。
baota_nginx_generated() { [ "${BAOTA_NGINX_GENERATED:-0}" = "1" ]; }

if baota_nginx_generated && ! declare -F sync_nginx >/dev/null 2>&1; then
    _NG="$SCRIPT_DIR/channels/native-nginx.sh"
    [ -f "$_NG" ] || _NG="$SCRIPT_DIR_DEPLOY/channels/native-nginx.sh"
    # shellcheck source=channels/native-nginx.sh
    [ -f "$_NG" ] && source "$_NG"
fi

# 前置：建站（缺失时）+ 解析站点根目录（面板 SSOT）+ 反代收口（翻译 routes）
channel_frontend_prepare() {
    local id="$1"
    local fallback="${DEPLOY_PATH[$id]:-}"

    # DRY_RUN：不碰面板 API，目标按 TOML deploy_path
    if [ "${DEPLOY_DRY_RUN:-0}" = "1" ]; then
        echo "$fallback"
        return 0
    fi

    # 生成器接管模式：目标=TOML deploy_path，不建面板站点、不建反代
    if baota_nginx_generated; then
        # ★副作用日志必须走 stderr：本函数 stdout 只允许输出目标路径
        {
            ok "$id 路由由 generate-nginx 统一生成（BAOTA_NGINX_GENERATED=1），跳过面板建站"
        } >&2
        echo "$fallback"
        return 0
    fi

    if ! baota_enabled; then
        err "宝塔通道缺少 BAOTA_PANEL_URL / BAOTA_API_KEY 配置（deploy.env.*）"
        return 1
    fi

    # 站点名：TOML site_name 覆盖，默认 <id>.local（面板要求域名格式）
    # ★副作用日志必须走 stderr：本函数 stdout 只允许输出目标路径（被 $() 捕获）
    {
        local site="${SITE_NAME[$id]:-$id.local}"
        baota_ensure_html_site "$site" "$fallback" || return 1
        _BAOTA_SITE_PATH=$(baota_cli site-path "$site") || return 1
        [ -z "$_BAOTA_SITE_PATH" ] && { err "宝塔站点不存在: $site"; return 1; }
        # 反代收口：PROXY_SPECS（config_loader 聚合到主前端站点的 "目录|目标URL" 清单）
        local specs="${PROXY_SPECS[$id]:-}"
        if [ -n "$specs" ] && ! baota_ensure_proxies "$site" "$specs"; then
            return 1
        fi
    } >&2 || return 1
    echo "$_BAOTA_SITE_PATH"
}

# 通道资产保存/还原：站点目录 .user.ini（chattr +i 防跨站，面板资产）
_BAOTA_UINI_SAVED=""
channel_frontend_preserve() {
    local id="$1" target="$2"
    _BAOTA_UINI_SAVED=""
    if [ -f "$target/.user.ini" ]; then
        chattr -i "$target/.user.ini" 2>/dev/null
        _BAOTA_UINI_SAVED="$DEPLOY_TMP_DIR/.user.ini.$id"
        mv "$target/.user.ini" "$_BAOTA_UINI_SAVED"
    fi
}
channel_frontend_restore() {
    local id="$1" target="$2"
    if [ -n "$_BAOTA_UINI_SAVED" ] && [ -f "$_BAOTA_UINI_SAVED" ]; then
        mv "$_BAOTA_UINI_SAVED" "$target/.user.ini"
        chattr +i "$target/.user.ini" 2>/dev/null
        _BAOTA_UINI_SAVED=""
    fi
}

# 单组件路由收口：面板管理模式=不碰；生成器接管模式=sync_nginx
channel_frontend_finalize() {
    if baota_nginx_generated; then
        sync_nginx || warn "sync-nginx 失败，可手动执行: bash deploy.sh --sync-nginx"
    fi
    return 0
}

# ── python ──

channel_python_install() { :; }   # 创建/重启在 restart 动词内一并 ensure

channel_python_restart() {
    local id="$1" pkg_dir="$2"
    # 主服务 = 宝塔 Python 项目（配置了 process 时；缺失则从零创建）
    if [ -n "${PROC_CMD[$id]:-}" ]; then
        baota_ensure_python_project "$id" "$pkg_dir" || return 1
        baota_restart_python "$id" "${PROC_PORT[$id]:-}" || return 1
    fi
    # 伴随服务 = 宝塔 supervisor 程序；未注册（从零部署/新机）→ 先跑 Phase 4b
    local comps="${COMPANIONS[$id]:-}" c sup_missing=""
    for c in $comps; do
        [ -f "/www/server/panel/plugin/supervisor/profile/$c.ini" ] \
            || sup_missing="$sup_missing $c"
    done
    if [ -n "$sup_missing" ] && [ -f "$DIST_ROOT/ops/05-setup-supervisor.sh" ]; then
        warn "supervisor 程序未注册:$sup_missing → 自动执行 05-setup-supervisor.sh --only"
        bash "$DIST_ROOT/ops/05-setup-supervisor.sh" --only="${sup_missing# }" \
            || warn "05-setup-supervisor.sh 有告警，复查 supervisorctl status"
    fi
    baota_restart_supervisor "$comps" || return 1
}

# ── java ──

channel_java_install() { :; }

channel_java_restart() {
    local id="$1" pkg_dir="$2"
    if [ -n "${PROC_CMD[$id]:-}" ]; then
        baota_ensure_java_project "$id" "$pkg_dir" || return 1
    fi
    baota_restart_supervisor "${COMPANIONS[$id]:-}" || return 1
}

# ── 服务状态/操作（全宝塔：supervisor + 面板项目，不碰 systemd）──

channel_service_running() {
    local svc="$1"
    local sctl; sctl=$(_baota_sctl)
    [ -x "$sctl" ] || return 1
    # 全量列表匹配（STOPPED/FATAL 的 status 子命令返回非 0，会误判）
    "$sctl" status 2>/dev/null | awk '{print $1}' | grep -qx "$svc"
}

channel_service_restart() {
    local svc="$1"
    local sctl; sctl=$(_baota_sctl)
    if [ ! -x "$sctl" ]; then
        err "supervisorctl 不存在: $sctl"
        return 1
    fi
    "$sctl" restart "$svc" >/dev/null 2>&1
}

channel_status() {
    local sctl; sctl=$(_baota_sctl)

    # 面板 Python/Java 项目（process 声明的组件；宝塔项目非 supervisor 程序）
    local p id
    local -a panel_projects=()
    for p in "${PROJECTS[@]}"; do
        [ -n "${PROC_CMD[$p]:-}" ] && panel_projects+=("$p")
    done
    if [ ${#panel_projects[@]} -gt 0 ]; then
        printf "  %-22s %-10s %s\n" "PANEL-PROJECT" "STATUS" "HEALTH"
        hr
        for id in "${panel_projects[@]}"; do
            local info proj_status
            info=$(baota_cli python-status "$id" 2>/dev/null || echo "")
            # python-status 返回 {"status":1,"run":true,...}（run=运行中）
            if echo "$info" | grep -q '"run": *true'; then
                proj_status="running"
            elif echo "$info" | grep -q '"run": *false'; then
                proj_status="stopped"
            else
                proj_status="n/a"
            fi
            local color="$RED"
            [ "$proj_status" = "running" ] && color="$GREEN"
            local health="-"
            [ -n "${HEALTH_URL[$id]:-}" ] && health=$(curl -sf --max-time 5 "${HEALTH_URL[$id]}" 2>/dev/null | head -c 40 || echo "FAIL")
            printf "  %-22s ${color}%-10s${NC} %s\n" "$id" "$proj_status" "$health"
        done
        echo ""
    fi

    local -a services=()
    local -A seen=()
    local p svc
    for p in "${PROJECTS[@]}"; do
        for svc in ${SERVICES[$p]:-}; do
            [ -n "$svc" ] && [ -z "${seen[$svc]:-}" ] && services+=("$svc") && seen[$svc]=1
        done
    done
    services+=("nginx")

    printf "  %-22s %-10s %s\n" "SERVICE" "STATUS" "HEALTH"
    hr
    for svc in "${services[@]}"; do
        local status
        if [ "$svc" = "nginx" ]; then
            status=$(/etc/init.d/nginx status >/dev/null 2>&1 && echo "RUNNING" || echo "STOPPED")
        elif channel_service_running "$svc"; then
            status=$("$sctl" status "$svc" 2>/dev/null | awk '{print $2}' || echo "RUNNING")
        else
            status="UNREGISTERED"
        fi
        local color="$RED"
        [ "$status" = "RUNNING" ] && color="$GREEN"
        local health=""
        for p in "${PROJECTS[@]}"; do
            if echo "${SERVICES[$p]:-}" | grep -qw "$svc"; then
                local hurl="${HEALTH_URL[$p]:-}"
                if [ -n "$hurl" ]; then
                    health=$(curl -sf --max-time 5 "$hurl" 2>/dev/null | head -c 60 || echo "FAIL")
                fi
                break
            fi
        done
        [ "$svc" = "nginx" ] && health=$(curl -sf --max-time 5 http://127.0.0.1/ -o /dev/null -w "%{http_code}" 2>/dev/null || echo "FAIL")
        [ -z "$health" ] && health="-"
        printf "  %-22s ${color}%-10s${NC} %s\n" "$svc" "$status" "$health"
    done
    echo ""
}

channel_logs() {
    local svc="$1" mode="${2:-50}"
    [ -z "$svc" ] && { err "未指定服务"; return 1; }
    local sctl; sctl=$(_baota_sctl)
    case "$mode" in
        follow)
            banner "实时日志: $svc (supervisor)"
            "$sctl" tail -f "$svc" stderr
            ;;
        error)
            banner "ERROR 日志: $svc"
            grep -iE 'error|traceback|exception' \
                "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null \
                | tail -30 || echo "  （无匹配或日志文件不存在）"
            ;;
        *)
            banner "最近 $mode 行: $svc (supervisor)"
            "$sctl" tail "$svc" stderr -"$mode" 2>/dev/null \
                || tail -"$mode" "/www/server/panel/plugin/supervisor/log/${svc}/stderr.log" 2>/dev/null \
                || echo "  （日志不可得）"
            ;;
    esac
}
