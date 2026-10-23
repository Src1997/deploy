#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Phase 1b: 宝塔部署清理（通道切换 / 恢复初始状态）
#
# 与 01-cleanup-server.sh（Docker 清理）对位的宝塔侧清场脚本：
# 清除面板上所有部署痕迹，使面板回到「刚装好」的初始状态。
#
# 用途：
#   - 通道切换前清场（docker 版 / 纯净版部署前 —— docker 与宝塔不共存）
#   - 从零重测部署链路（宝塔通道回归测试）
#
# 清理范围：
#   A) 面板记录：Python 项目（RemoveProject）+ 全部站点（DeleteSite，
#      含 Java 项目 —— 其记录同样挂在 sites 表）
#   B) Nginx vhost 残留：站点同名 conf + proxy/extension/rewrite/ssl
#      子目录条目 + reload
#   C) Supervisor 伴随程序：stop + 删 ini + reread/update
#   D) Python 项目文件系统痕迹：venv 注册表、pyporject_evn、python_project
#   E) 部署产物：$PROJECT_BASE/uploads、backup、部署包目录
#   F) systemd 双轨残留：quantdinger-*/financial-* 旧单元（防抢端口）
#
# 用法：
#   bash 08-cleanup-baota.sh                # 全量（逐项确认）
#   bash 08-cleanup-baota.sh --yes          # 跳过确认
#   bash 08-cleanup-baota.sh --check        # 只探测，不修改
#   bash 08-cleanup-baota.sh --keep-venv    # 保留 Python 项目 venv
#                                           #（如 deepquant package/.venv）
#   bash 08-cleanup-baota.sh --fs-only      # 只清文件系统痕迹（跳过面板 API）
#
# 注意：保留 $PROJECT_BASE/deploy.env（重部署需要，随 dist 重传亦可再生）。
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

ASSUME_YES=false
CHECK_ONLY=false
KEEP_VENV=false
FS_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y)     ASSUME_YES=true ;;
        --check)      CHECK_ONLY=true ;;
        --keep-venv)  KEEP_VENV=true ;;
        --fs-only)    FS_ONLY=true ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown: $arg (try --help)"; exit 1 ;;
    esac
done

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Phase 1b: 宝塔部署清理（恢复初始状态）"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 定位 baota_api.py（dist: ops→../channel；仓内: scripts/ops→../channel）──
BAOTA_API=""
for cand in "$SCRIPT_DIR/../channels/baota-api.py" "$SCRIPT_DIR/../channel/baota_api.py" "$SCRIPT_DIR/baota_api.py"; do
    [ -f "$cand" ] && BAOTA_API="$cand" && break
done

# ── 加载 deploy.env（优先环境变量，其次 deploy.env / deploy.env.<target>）──
# 候选：dist 根(ops/..) / 仓根(scripts/ops/../..) / 服务器部署基路径
ENV_FILE=""
_env_names=()
if [ -n "${DEPLOY_TARGET:-}" ]; then
    _env_names+=("deploy.env.${DEPLOY_TARGET}")
fi
_env_names+=("deploy.env" "deploy.env.vm")
for name in "${_env_names[@]}"; do
    for cand in "$SCRIPT_DIR/../$name" "$SCRIPT_DIR/../../$name" \
                "$(pwd)/$name" "/www/wwwroot/project/$name"; do
        [ -f "$cand" ] && ENV_FILE="$cand" && break 2
    done
done
if [ -n "$ENV_FILE" ]; then
    # 显式环境变量优先于文件值；tr 去 \r（Windows CRLF 行尾会污染 URL/密钥）
    _envv() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '\r'; }
    : "${BAOTA_PANEL_URL:=$(_envv BAOTA_PANEL_URL)}"
    : "${BAOTA_API_KEY:=$(_envv BAOTA_API_KEY)}"
    : "${BAOTA_PYTHON:=$(_envv BAOTA_PYTHON)}"
    : "${BAOTA_SUPERVISORCTL:=$(_envv BAOTA_SUPERVISORCTL)}"
    : "${PROJECT_BASE:=$(_envv PROJECT_BASE)}"
    log "配置来源: $ENV_FILE"
fi
# baota_api.py 从 os.environ 读取（from_env）——必须 export 给子进程
export BAOTA_PANEL_URL BAOTA_API_KEY
PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
BAOTA_PYTHON="${BAOTA_PYTHON:-/www/server/panel/pyenv/bin/python3}"
BAOTA_SUPERVISORCTL="${BAOTA_SUPERVISORCTL:-/www/server/panel/pyenv/bin/supervisorctl}"

if $FS_ONLY; then
    ok "已指定 --fs-only，跳过面板 API 清理段"
elif [ -z "${BAOTA_PANEL_URL:-}" ] || [ -z "${BAOTA_API_KEY:-}" ]; then
    err "缺少 BAOTA_PANEL_URL / BAOTA_API_KEY（env 或 deploy.env）"
    err "若面板已不可用，可用 --fs-only 只清文件系统痕迹"
    exit 1
elif [ ! -f "$BAOTA_API" ]; then
    err "找不到 baota_api.py（$BAOTA_API）"
    exit 1
fi

bcli() {
    if [ -x "$BAOTA_PYTHON" ]; then
        "$BAOTA_PYTHON" "$BAOTA_API" "$@"
    else
        python3 "$BAOTA_API" "$@"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Step 0: 状态速览
# ═══════════════════════════════════════════════════════════════
SITES_TXT=""
PYPROJ_TXT=""

if ! $FS_ONLY; then
    log "面板连通性探测..."
    if bcli ping 2>/dev/null; then
        ok "面板可达: $BAOTA_PANEL_URL"
    else
        err "面板不可达，API 清理无法进行（可改用 --fs-only）"
        exit 1
    fi

    SITES_TXT="$(bcli list-sites 2>/dev/null || true)"
    PYPROJ_TXT="$(bcli list-python-projects 2>/dev/null || true)"

    log "当前面板记录："
    if [ -n "$SITES_TXT" ]; then
        echo "$SITES_TXT" | sed 's/^/    站点: /'
    else
        ok "    站点: 无"
    fi
    if [ -n "$PYPROJ_TXT" ]; then
        echo "$PYPROJ_TXT" | sed 's/^/    Py项目: /'
    else
        ok "    Py项目: 无"
    fi
fi

if $CHECK_ONLY; then
    log "── --check 文件系统痕迹探测 ──"
    for d in "/www/server/pyporject_evn" "/www/server/python_project"; do
        [ -d "$d" ] && warn "  存在: $d ($(ls -A "$d" 2>/dev/null | wc -l) 项)" || ok "  无: $d"
    done
    find /www/server/panel/data -maxdepth 1 -name "*name2env*" 2>/dev/null | sed 's/^/  注册表: /' || true
    [ -d "/www/server/panel/vhost/nginx" ] && \
        warn "  vhost conf: $(find /www/server/panel/vhost/nginx -name '*.conf' 2>/dev/null | wc -l) 个" || true
    for ini in /www/server/panel/plugin/supervisor/profile/*.ini; do
        [ -f "$ini" ] && warn "  supervisor: $ini"
    done 2>/dev/null || true
    ls -d "$PROJECT_BASE"/uploads "$PROJECT_BASE"/backup* 2>/dev/null | sed 's/^/  产物: /' || true
    ls /etc/systemd/system/ 2>/dev/null | grep -E '^(quantdinger|financial)-' | sed 's/^/  systemd: /' || true
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# 确认
# ═══════════════════════════════════════════════════════════════
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  ⚠️  警告：将删除面板上【全部】站点与 Python 项目记录！"
warn "     （生产服务器误跑此脚本 = 全站删除，务必确认目标机器）"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  目标机器: $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
echo "  项目基路径: $PROJECT_BASE（uploads/backup/部署包将删除；deploy.env 保留）"
if $KEEP_VENV; then
    echo "  Python venv: 保留（--keep-venv）"
else
    echo "  Python venv: 一并删除（RemoveProject remove_env=true）"
fi
echo ""
if $ASSUME_YES; then
    ok "已指定 --yes，跳过确认"
else
    read -rp "  确认清空以上内容？输入 yes 继续: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "  已取消。"
        exit 0
    fi
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# Step 1: 删除面板 Python 项目（RemoveProject）
# ═══════════════════════════════════════════════════════════════
if ! $FS_ONLY; then
    log "Step 1: 删除面板 Python 项目..."
    if [ -n "$PYPROJ_TXT" ]; then
        while read -r pname _rest; do
            [ -z "$pname" ] && continue
            if $KEEP_VENV; then
                bcli remove-python-project "$pname" false >/dev/null 2>&1 \
                    && ok "已删除项目(保留venv): $pname" \
                    || warn "删除失败: $pname（可能需面板手动删）"
            else
                bcli remove-python-project "$pname" true >/dev/null 2>&1 \
                    && ok "已删除项目(含venv): $pname" \
                    || warn "删除失败: $pname（可能需面板手动删）"
            fi
        done <<< "$PYPROJ_TXT"
    else
        ok "无 Python 项目"
    fi
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# Step 2: 删除全部站点（DeleteSite；Java 项目记录也挂在 sites 表）
# ═══════════════════════════════════════════════════════════════
SITED_NAMES=""
if ! $FS_ONLY; then
    log "Step 2: 删除全部站点..."
    SITES_TXT="$(bcli list-sites 2>/dev/null || true)"
    if [ -n "$SITES_TXT" ]; then
        # 记录站点名供 Step 3 清 vhost 残留
        SITED_NAMES="$(echo "$SITES_TXT" | awk '{print $2}')"
        while read -r _sid sname _path; do
            [ -z "$sname" ] && continue
            bcli remove-site "$sname" >/dev/null 2>&1 \
                && ok "已删除站点: $sname" \
                || warn "删除站点失败: $sname（可能需面板手动删）"
        done <<< "$SITES_TXT"
        # 复核
        LEFT="$(bcli list-sites 2>/dev/null || true)"
        if [ -n "$LEFT" ]; then
            warn "仍有站点未删除："
            echo "$LEFT" | sed 's/^/    /'
        fi
    else
        ok "无站点"
    fi
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# Step 3: Nginx vhost 残留（站点同名 conf + proxy/extension/rewrite/ssl）
# ═══════════════════════════════════════════════════════════════
VHOST_DIR="/www/server/panel/vhost/nginx"
if [ -d "$VHOST_DIR" ]; then
    log "Step 3: 清理 Nginx vhost 残留..."
    if [ -n "$SITED_NAMES" ]; then
        for sname in $SITED_NAMES; do
            for f in "$VHOST_DIR/$sname.conf" "$VHOST_DIR/${sname}.conf.bak"; do
                [ -f "$f" ] && rm -f "$f" && ok "已删除 conf: $f"
            done
            for sub in proxy extension rewrite ssl; do
                for f in "$VHOST_DIR/$sub/${sname}.conf" "$VHOST_DIR/$sub/${sname}"/*; do
                    [ -e "$f" ] || continue
                    rm -rf "$f" && ok "已删除: $f"
                done
            done
        done
    fi
    # 域名型站点（如含端口/下划线的面板命名）兜底：凡引用被删站点目录的 conf
    ORPHAN=$(grep -rl "wwwroot/" "$VHOST_DIR" --include="*.conf" 2>/dev/null | \
        grep -v "default.conf" || true)
    if [ -n "$ORPHAN" ] && [ -n "$SITED_NAMES" ]; then
        warn "发现疑似孤儿 conf（引用已删站点目录），请人工复核："
        echo "$ORPHAN" | sed 's/^/    /'
    fi
    # 历次部署产生的 default.conf.bak.* 备份（非面板原生文件）
    for f in "$VHOST_DIR"/default.conf.bak.* "$VHOST_DIR"/*.conf.bak; do
        [ -f "$f" ] && rm -f "$f" && ok "已删除备份: $(basename "$f")"
    done 2>/dev/null
    # 平滑重载
    if command -v nginx &>/dev/null; then
        nginx -t 2>/dev/null && nginx -s reload 2>/dev/null \
            && ok "nginx 已重载" || warn "nginx 重载失败，请手动检查: nginx -t"
    fi
else
    log "Step 3: 跳过（$VHOST_DIR 不存在）"
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# Step 4: Supervisor 伴随程序（stop + 删 ini + reread/update）
# ═══════════════════════════════════════════════════════════════
SUP_PROFILE="/www/server/panel/plugin/supervisor/profile"
if [ -d "$SUP_PROFILE" ]; then
    log "Step 4: 清理 Supervisor 伴随程序..."
    INIS=$(find "$SUP_PROFILE" -name "*.ini" 2>/dev/null || true)
    if [ -n "$INIS" ]; then
        if [ -x "$BAOTA_SUPERVISORCTL" ]; then
            "$BAOTA_SUPERVISORCTL" stop all 2>/dev/null || true
        fi
        echo "$INIS" | while read -r ini; do
            rm -f "$ini" && ok "已删除: $ini"
        done
        if [ -x "$BAOTA_SUPERVISORCTL" ]; then
            "$BAOTA_SUPERVISORCTL" reread 2>/dev/null || true
            "$BAOTA_SUPERVISORCTL" update 2>/dev/null || true
            ok "supervisor 已 reread/update"
        fi
    else
        ok "无 supervisor 程序"
    fi
else
    log "Step 4: 跳过（$SUP_PROFILE 不存在）"
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# Step 5: Python 项目文件系统痕迹
# ═══════════════════════════════════════════════════════════════
log "Step 5: 清理 Python 项目文件系统痕迹..."

# venv 注册表（*name2env*，RemoveProject remove_env=true 已顺带清；
# 这里兜底清孤立行/文件）
find /www/server/panel/data -maxdepth 1 -name "*name2env*" 2>/dev/null | \
while read -r reg; do
    if $KEEP_VENV; then
        warn "保留注册表（--keep-venv）: $reg"
    else
        rm -f "$reg" && ok "已删除 venv 注册表: $reg"
    fi
done

for d in "/www/server/pyporject_evn" "/www/server/python_project"; do
    if [ -d "$d" ]; then
        # 只删面板自管 venv / 项目运行目录（目录本身保留——面板组件需要）
        INNER=$(ls -A "$d" 2>/dev/null || true)
        if [ -n "$INNER" ] && ! $KEEP_VENV; then
            find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true
            ok "已清空: $d"
        elif [ -n "$INNER" ]; then
            warn "保留（--keep-venv）: $d"
        else
            ok "已空: $d"
        fi
    fi
done
echo ""

# ═══════════════════════════════════════════════════════════════
# Step 6: 部署产物（uploads / backup / 部署包目录）
# ═══════════════════════════════════════════════════════════════
log "Step 6: 清理部署产物..."
if [ -d "$PROJECT_BASE" ]; then
    # uploads：清部署包但保留 dist/ 与 deploy.log（脚本可能正跑在 dist 里）
    if [ -d "$PROJECT_BASE/uploads" ]; then
        find "$PROJECT_BASE/uploads" -mindepth 1 -maxdepth 1 \
            ! -name 'dist' ! -name 'deploy.log' \
            -exec rm -rf {} \; 2>/dev/null || true
        ok "已清空 uploads（保留 dist/ 与 deploy.log）"
    fi
fi
for d in "$PROJECT_BASE"/backup*; do
    [ -e "$d" ] && rm -rf "$d" && ok "已删除: $d"
done

# 组件部署包目录（package 内含 .venv —— 全清模式一并删）
if [ -d "$PROJECT_BASE" ] && ! $KEEP_VENV; then
    PKGS=$(find "$PROJECT_BASE" -mindepth 2 -maxdepth 3 -type d -name "package" 2>/dev/null || true)
    if [ -n "$PKGS" ]; then
        echo "$PKGS" | while read -r p; do
            rm -rf "$(dirname "$p")" && ok "已删除部署包: $(dirname "$p")"
        done
    fi
fi
ok "deploy.env 保留: $(ls "$PROJECT_BASE/deploy.env" 2>/dev/null || echo '（不存在）')"
echo ""

# ═══════════════════════════════════════════════════════════════
# Step 7: systemd 双轨残留（旧单元抢端口事故防御）
# ═══════════════════════════════════════════════════════════════
log "Step 7: 清理 systemd 双轨残留..."
LEGACY_UNITS=$(ls /etc/systemd/system/ 2>/dev/null | \
    grep -E '^(quantdinger|financial)-.*\.service$' || true)
if [ -n "$LEGACY_UNITS" ]; then
    echo "$LEGACY_UNITS" | while read -r u; do
        systemctl stop "$u" 2>/dev/null || true
        systemctl disable "$u" 2>/dev/null || true
        rm -f "/etc/systemd/system/$u"
        ok "已移除旧单元: $u"
    done
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
else
    ok "无 systemd 双轨残留"
fi

# 残留进程兜底（旧 gunicorn/java 仍抱住项目目录）
# ★排除自身与调用链（清场脚本/黄金链路测试都在 wwwroot/project 下运行，
#   否则 pkill 会杀掉自己——L2 首跑实证）
LEFTOVER=$(pgrep -af "wwwroot/project" 2>/dev/null \
    | grep -v "cleanup-baota.sh" | grep -v "golden-path" \
    | grep -v grep || true)
if [ -n "$LEFTOVER" ]; then
    warn "发现仍引用 $PROJECT_BASE 的进程（将终止）："
    echo "$LEFTOVER" | sed 's/^/    /'
    echo "$LEFTOVER" | awk '{print $1}' | while read -r pid; do
        [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] && kill "$pid" 2>/dev/null || true
    done
    sleep 1
    ok "残留进程已终止"
else
    ok "无残留进程"
fi
echo ""

# ═══════════════════════════════════════════════════════════════
# 验证
# ═══════════════════════════════════════════════════════════════
log "───────────── 验证 ─────────────"
FAIL=0
if ! $FS_ONLY; then
    LEFT_SITES="$(bcli list-sites 2>/dev/null || true)"
    LEFT_PY="$(bcli list-python-projects 2>/dev/null || true)"
    if [ -z "$LEFT_SITES" ] && [ -z "$LEFT_PY" ]; then
        ok "面板记录: 空 ✓"
    else
        warn "面板仍有记录:"; echo "$LEFT_SITES$LEFT_PY" | sed 's/^/    /'
        FAIL=1
    fi
fi
# 面板原生 conf 白名单（0.*.conf / default.conf / phpfpm_status / waf2monitor）
# 注：grep 无匹配退出码 1 会触发 pipefail，须在子 shell 内吞掉
VHOST_LEFT=$( { find "$VHOST_DIR" -maxdepth 1 -name "*.conf" 2>/dev/null | \
    grep -vE '/(0\.[^/]*\.conf|default\.conf|phpfpm_status\.conf|waf2monitor[^/]*\.conf)$' || true; } | \
    wc -l | tr -d '[:space:]')
if [ "$VHOST_LEFT" -eq 0 ]; then
    ok "vhost conf: 干净（仅 default.conf）✓"
else
    warn "vhost 仍有 $VHOST_LEFT 个 conf"
    FAIL=1
fi
SUP_LEFT=$(find "$SUP_PROFILE" -name "*.ini" 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$SUP_LEFT" -eq 0 ]; then
    ok "supervisor: 空 ✓"
else
    warn "supervisor 仍有 $SUP_LEFT 个程序"
    FAIL=1
fi
for port in 5000 5001 7800; do
    if ss -ltn 2>/dev/null | grep -q ":${port} "; then
        warn "端口 $port 仍被占用"
        FAIL=1
    fi
done
if [ "$FAIL" -eq 0 ]; then
    ok "═══════════════════════════════════════════════════"
    ok "  宝塔已恢复初始状态 ✓"
    ok "═══════════════════════════════════════════════════"
else
    warn "存在未清干净项，请按上方提示人工复核"
fi

echo ""
echo "  下一步（重部署）："
echo "    1. 本地 build.ps1 打包 → 上传 dist"
echo "    2. bash deploy.sh all --yes   # 宝塔通道从零建站点/项目/代理"
echo "    3. bash $SCRIPT_DIR/03-check-components.sh  # 组件复核"
echo ""
