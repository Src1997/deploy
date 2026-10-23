#!/usr/bin/env bash
# ================================================================
# tests/golden-path-vm.sh — L2 黄金链路测试（在目标服务器上执行）
#
# 一条命令完成「恢复初始状态 → 从零部署 → 全链路断言」，
# 这是唯一能抓住真实部署故障的测试（L1 只查语法与配置层）。
#
# 用法：
#   Windows 本机：  ssh vm "bash -s" -- < tests/golden-path-vm.sh
#   服务器本机：    bash golden-path-vm.sh [--skip-cleanup] [--skip-deploy]
#
# 流程：
#   Step 1  08-cleanup-baota.sh --yes        恢复宝塔初始状态
#   Step 2  deploy.sh <组件> --yes           从零部署（TOML 驱动）
#   Step 3  断言（每项带重试，失败汇总退出非 0）：
#           A. 面板：站点 + Python 项目存在且 run=true
#           B. 前端 HTTP 200
#           C. /api/ 反代 → healthy
#           D. 后端直连 → healthy
#           E. MCP 7800 监听 + /sse 200
#           F. supervisor 目标程序全 RUNNING
#           G. 无 systemd 双轨（无 quantdinger-*/financial-* unit）
#           H. 无双轨进程（5000 只有一套 gunicorn master）
#
# 断言目标（站点/项目/端口/组件）从 dist/deploy.env.vm + 项目约定推导，
# 目前钉死 deepquant 场景；上其他项目时把 TARGETS 改成参数化。
# ================================================================
set -uo pipefail

SKIP_CLEANUP=false
SKIP_DEPLOY=false
for arg in "$@"; do
    case "$arg" in
        --skip-cleanup) SKIP_CLEANUP=true ;;
        --skip-deploy)  SKIP_DEPLOY=true ;;
        --help|-h) sed -n '2,24p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown: $arg"; exit 1 ;;
    esac
done

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
bad()  { echo -e "\033[31m[FAIL]\033[0m $*"; }
hr()   { echo "────────────────────────────────────────────────"; }

# ── 定位 dist（黄金链路必须在 dist 根跑）──
DIST=""
for c in "$(pwd)" "$(pwd)/dist" "/www/wwwroot/project/uploads/dist"; do
    [ -f "$c/deploy.sh" ] && [ -d "$c/channel" ] && DIST="$c" && break
done
[ -z "$DIST" ] && { bad "找不到分层 dist（需含 deploy.sh + channel/）"; exit 1; }
log "dist: $DIST"

# ── 加载面板配置 ──
ENV_FILE="$DIST/deploy.env.vm"
[ -f "$ENV_FILE" ] || { bad "缺 $ENV_FILE"; exit 1; }
tr -d '\r' < "$ENV_FILE" > /tmp/_gp_env.$$
set -a; . /tmp/_gp_env.$$; set +a; rm -f /tmp/_gp_env.$$
export BAOTA_PANEL_URL BAOTA_API_KEY
BCMD="${BAOTA_PYTHON:-/www/server/panel/pyenv/bin/python3} $DIST/channel/baota_api.py"

# ── 目标（deepquant 场景钉死；换项目改这里）──
SITE="deepquant.vmtest"
PYPROJ="deepquant-backend"
WEB_PORT="${DEEPQUANT_WEB_PORT:-80}"
API_PORT="5000"
MCP_PORT="7800"
COMPONENTS="deepquant-web,deepquant-backend"
SCTL="${BAOTA_SUPERVISORCTL:-/www/server/panel/pyenv/bin/supervisorctl}"
SUPERVISOR_PROGRAMS="quantdinger-mcp"

FAIL=0
step() { echo ""; log "━━ $* ━━"; }
assert() { # assert <描述> <重试次数> <命令...>
    local desc="$1" tries="$2"; shift 2
    local i
    for i in $(seq 1 "$tries"); do
        if "$@" >/dev/null 2>&1; then ok "  $desc"; return 0; fi
        [ "$tries" -gt 1 ] && sleep 2
    done
    bad "  $desc（重试 ${tries} 次均失败）"
    FAIL=$((FAIL + 1))
    return 1
}

echo ""
echo "═══════════════════════════════════════════════"
echo "  L2 黄金链路：清场 → 从零部署 → 断言"
echo "═══════════════════════════════════════════════"

# ── Step 1 清场 ──
if $SKIP_CLEANUP; then
    step "1/3 清场（跳过 --skip-cleanup）"
else
    step "1/3 恢复宝塔初始状态"
    if ! bash "$DIST/ops/08-cleanup-baota.sh" --yes; then
        bad "清场失败，中止"; exit 1
    fi
fi

# ── Step 2 从零部署 ──
if $SKIP_DEPLOY; then
    step "2/3 从零部署（跳过 --skip-deploy）"
else
    step "2/3 从零部署: $COMPONENTS"
    if ! (cd "$DIST" && DEPLOY_TARGET=vm bash deploy.sh "$COMPONENTS" --yes); then
        bad "部署命令失败，中止"; exit 1
    fi
fi

# ── Step 3 断言 ──
step "3/3 全链路断言"

# A. 面板记录
assert "面板站点存在: $SITE" 3 bash -c "\"$BCMD\" list-sites | grep -q '$SITE'"
assert "面板 Python 项目存在: $PYPROJ" 3 bash -c "\"$BCMD\" list-python-projects | grep -q '^$PYPROJ '"
assert "Python 项目运行中 (run=true)" 3 bash -c "\"$BCMD\" python-status $PYPROJ | grep -q '\"run\": true'"

# B. 前端
assert "前端 HTTP 200 (port $WEB_PORT)" 5 bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$WEB_PORT/ | grep -q 200"

# C. 反代
assert "/api/ 反代 → healthy" 5 bash -c "curl -s http://127.0.0.1:$WEB_PORT/api/health | grep -q '\"status\":\"healthy\"'"

# D. 后端直连
assert "后端直连 :$API_PORT healthy" 5 bash -c "curl -s http://127.0.0.1:$API_PORT/api/health | grep -q '\"status\":\"healthy\"'"

# E. MCP
assert "MCP :$MCP_PORT 监听" 5 bash -c "ss -ltn | grep -q ':$MCP_PORT '"
assert "MCP /sse → 200" 5 bash -c "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:$MCP_PORT/sse | grep -q 200"

# F. supervisor
SUP_BAD=$("$SCTL" status 2>/dev/null | grep -v Warning | grep -v RUNNING || true)
if [ -z "$SUP_BAD" ]; then
    ok "  supervisor 全 RUNNING ($SUPERVISOR_PROGRAMS)"
else
    bad "  supervisor 有非 RUNNING 进程:"; echo "$SUP_BAD" | sed 's/^/         /'
    FAIL=$((FAIL + 1))
fi

# G. systemd 双轨
if ls /etc/systemd/system/ 2>/dev/null | grep -Eq '^(quantdinger|financial)-'; then
    bad "  systemd 双轨残留存在（抢端口事故源）"
    FAIL=$((FAIL + 1))
else
    ok "  无 systemd 双轨残留"
fi

# H. 双轨进程（5000 端口 gunicorn master 只能有一套）
MASTERS=$(pgrep -f "gunicorn.*run:app" 2>/dev/null | wc -l)
if [ "$MASTERS" -ge 1 ] && [ "$MASTERS" -le 3 ]; then
    ok "  5000 单套 gunicorn（master+worker 共 $MASTERS 进程）"
else
    bad "  疑似双轨 gunicorn（$MASTERS 个进程）: pgrep -af 'gunicorn.*run:app'"
    FAIL=$((FAIL + 1))
fi

echo ""
hr
if [ "$FAIL" -eq 0 ]; then
    ok "═══════════════════════════════════════════════"
    ok "  ✅ 黄金链路全绿：宝塔通道从零部署可信"
    ok "═══════════════════════════════════════════════"
    exit 0
else
    bad "═══════════════════════════════════════════════"
    bad "  ❌ 失败 $FAIL 项断言（见上方 [FAIL]）"
    bad "═══════════════════════════════════════════════"
    exit 1
fi
