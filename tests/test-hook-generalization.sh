#!/usr/bin/env bash
# -- Hook generalization test for deploy-python.sh --
#
# Verifies that the Python deploy hook correctly operates as a generic
# component deployer driven by COMPONENT_ID + env vars (no filename magic).
#
# Run from WSL: bash tests/test-hook-generalization.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/deploy-python.sh"
TEMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

# Common env for all tests (avoid picking up real deploy.env)
export PROJECT_BASE="/tmp/__test_hook_base"
export PG_PASSWORD="test_pg"
export REDIS_PASSWORD="test_redis"
export SMTP_PASSWORD="test_smtp"
export DOMAIN="test.example.com"
export WWW_DOMAIN="www.test.example.com"

mkdir -p "$PROJECT_BASE"

_ok()   { echo -e "  \033[32m✓ PASS\033[0m $1"; PASS=$((PASS + 1)); }
_fail() { echo -e "  \033[31m✗ FAIL\033[0m $1"; FAIL=$((FAIL + 1)); }

_contains() {
    local label="$1" output="$2" pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        _ok "$label: contains '$pattern'"
    else
        _fail "$label: expected '$pattern' in output"
        echo "$output" | head -20 | sed 's/^/    /'
    fi
}

_not_contains() {
    local label="$1" output="$2" pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        _fail "$label: should NOT contain '$pattern'"
    else
        _ok "$label: does not contain '$pattern'"
    fi
}

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Hook Generalization Test (deploy-python.sh)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# -- S1: financial-api with full env injection (deploy.sh simulation) --
echo "[S1] financial-api with full env injection (deploy.sh simulation)"
S1=$(cd /tmp && COMPONENT_ID=financial-api API_PORT=5001 \
    SERVICES="financial-api financial-crawler financial-worker financial-streaming" \
    POST_DEPLOY_CHECK_PATH=/api/navigation/menu \
    WEB_PATH=/financial \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S1" "$S1" "组件         : financial-api"
_contains     "S1" "$S1" "ENV_TEMPLATE : financial-api.env.example"
_contains     "S1" "$S1" "服务         : financial-api financial-crawler financial-worker financial-streaming"
_not_contains "S1" "$S1" "未找到端口配置"
echo ""

# -- S2: new component via env injection (no filename magic) --
echo "[S2] new component 'my-backend' via COMPONENT_ID"
S2=$(cd /tmp && COMPONENT_ID=my-backend API_PORT=8000 \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S2" "$S2" "组件         : my-backend"
_contains     "S2" "$S2" "ENV_TEMPLATE : my-backend.env.example"
_contains     "S2" "$S2" "服务         : my-backend"
_not_contains "S2" "$S2" "financial-crawler"
_not_contains "S2" "$S2" "未找到端口配置"
echo ""

# -- S3: missing template dry-run (no crash) --
echo "[S3] unknown component dry-run (no crash)"
S3=$(cd /tmp && COMPONENT_ID=no-such API_PORT=9000 \
    PKG_DIR="$TEMP_DIR/no-such/pkg" \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S3" "$S3" "组件         : no-such"
_contains     "S3" "$S3" "ENV_TEMPLATE : no-such.env.example"
echo ""

# -- S4: API_PORT injection from deploy.sh passthrough --
echo "[S4] API_PORT=7777 injection"
S4=$(cd /tmp && COMPONENT_ID=financial-api API_PORT=7777 \
    SERVICES="financial-api financial-crawler" \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S4" "$S4" "API 端口     : 7777"
_contains     "S4" "$S4" "服务         : financial-api financial-crawler"
_not_contains "S4" "$S4" "未找到端口配置"
echo ""

# -- S5: new component + API_PORT --
echo "[S5] new component + API_PORT=3000"
S5=$(cd /tmp && COMPONENT_ID=my-backend API_PORT=3000 \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S5" "$S5" "API 端口     : 3000"
_contains     "S5" "$S5" "服务         : my-backend"
_not_contains "S5" "$S5" "未找到端口配置"
echo ""

# -- S6: SERVICES passthrough overrides defaults --
echo "[S6] SERVICES passthrough overrides"
S6=$(cd /tmp && COMPONENT_ID=financial-api API_PORT=5001 \
    SERVICES="only-api" \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S6" "$S6" "服务         : only-api"
_not_contains "S6" "$S6" "financial-crawler"
echo ""

# -- S7: _load_optional_env ignores cwd/deploy.env --
echo "[S7] _load_optional_env ignores cwd/deploy.env"
mkdir -p "$TEMP_DIR/fake-cwd"
echo 'API_PORT=9999' > "$TEMP_DIR/fake-cwd/deploy.env"
S7=$(cd "$TEMP_DIR/fake-cwd" && COMPONENT_ID=financial-api API_PORT=5001 \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S7" "$S7" "API 端口     : 5001"
_not_contains "S7" "$S7" "9999"
echo ""

# -- S8: port fallback warn (no port configured) --
echo "[S8] port fallback warn when no port configured"
S8=$(cd /tmp && COMPONENT_ID=test-fallback PROJECT_BASE="$TEMP_DIR/empty" \
    PKG_DIR="$TEMP_DIR/empty/pkg" \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S8" "$S8" "未找到端口配置"
_contains     "S8" "$S8" "5001"
echo ""

# -- S9: WEB_PATH empty when not injected --
echo "[S9] WEB_PATH empty when not injected"
S9=$(cd /tmp && COMPONENT_ID=some-service API_PORT=4000 \
    bash "$HOOK" --dry-run 2>&1) || true
_not_contains "S9" "$S9" "/financial"
echo ""

# -- S10: POST_DEPLOY_CHECK_PATH empty when not injected --
echo "[S10] POST_DEPLOY_CHECK_PATH empty when not injected"
_not_contains "S10" "$S9" "navigation"
echo ""

# -- S11: Missing COMPONENT_ID exits with error --
echo "[S11] Missing COMPONENT_ID exits with error"
S11=$(cd /tmp && bash "$HOOK" --dry-run 2>&1) || true
_contains     "S11" "$S11" "COMPONENT_ID 未设置"
echo ""

# -- S12: POST_DEPLOY_CHECK_PATH + WEB_PATH injected for financial-api --
echo "[S12] POST_DEPLOY_CHECK_PATH + WEB_PATH injected"
S12=$(cd /tmp && COMPONENT_ID=financial-api API_PORT=5001 \
    SERVICES="financial-api" \
    POST_DEPLOY_CHECK_PATH=/api/navigation/menu \
    WEB_PATH=/financial \
    bash "$HOOK" --dry-run 2>&1) || true
_contains     "S12" "$S12" "/financial"
echo ""

# -- Cleanup --
rm -rf "$TEMP_DIR"

# -- Summary --
echo "═══════════════════════════════════════════════════════════════"
echo -e "  Results: \033[32m$PASS passed\033[0m, \033[31m$FAIL failed\033[0m"
echo "═══════════════════════════════════════════════════════════════"
echo ""

[ "$FAIL" -eq 0 ] || exit 1
