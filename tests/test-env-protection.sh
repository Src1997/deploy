#!/usr/bin/env bash
# 验证 deploy-financial-api.sh 的 .env 保护逻辑
# 测试场景：
#   1. 包内携带 .env → 部署脚本不应覆盖生产 .env
#   2. sync_env 跳过含 __PLACEHOLDER__ 的值
#   3. 回归对照：旧逻辑（无保护）确实会覆盖 .env
set -euo pipefail

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# ── 测试 1：包内携带 .env，部署脚本不应覆盖生产 .env ──
echo "=== Test 1: .env protection during code sync ==="

TMPROOT=$(mktemp -d)
PKG_DIR="$TMPROOT/package"
SRC_DIR="$TMPROOT/src"
ENV_FILE="$PKG_DIR/.env"

mkdir -p "$PKG_DIR" "$SRC_DIR"

# 模拟生产 .env
cat > "$ENV_FILE" << 'EOF'
AUTH_MODE=upstream
DATABASE_URL=postgresql+psycopg2://root:prod_password@localhost:5432/quant_zc
AUTH_UPSTREAM_URL=http://127.0.0.1:5000
AUTH_SECRET_KEY=prod_secret_key_abc123
REDIS_URL=redis://:prod_redis_pass@localhost:6379/0
APP_NAME=financial-api
APP_ENV=production
EOF

# 模拟包内代码 + 开发者本地 .env（应被忽略）
cat > "$SRC_DIR/.env" << 'EOF'
AUTH_MODE=local
DATABASE_URL=postgresql+psycopg2://quantdinger:quantdinger123@localhost:5432/quant_zc
AUTH_UPSTREAM_URL=https://www.deepquant.club
AUTH_SECRET_KEY=dev_secret_key
REDIS_URL=redis://localhost:6379/0
EOF
echo "app.py" > "$SRC_DIR/app.py"

# ── 模拟修复后的代码同步逻辑 ──
env_preserve=""
if [[ -f "$ENV_FILE" ]]; then
    env_preserve=$(mktemp)
    cp "$ENV_FILE" "$env_preserve"
fi

find "$PKG_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name '.venv' ! -name 'logs' \
    -exec rm -rf {} + 2>/dev/null || true

rm -f "${SRC_DIR}/.env" 2>/dev/null || true

cp -a "${SRC_DIR%/}/." "$PKG_DIR/"

if [[ -n "$env_preserve" ]]; then
    cp "$env_preserve" "$ENV_FILE"
    rm -f "$env_preserve"
fi

# 验证生产 .env 未被覆盖
PROD_AUTH_MODE=$(grep "^AUTH_MODE=" "$ENV_FILE" | cut -d= -f2)
PROD_DB_URL=$(grep "^DATABASE_URL=" "$ENV_FILE" | cut -d= -f2)
PROD_UPSTREAM=$(grep "^AUTH_UPSTREAM_URL=" "$ENV_FILE" | cut -d= -f2)
PROD_SECRET=$(grep "^AUTH_SECRET_KEY=" "$ENV_FILE" | cut -d= -f2)
PROD_REDIS=$(grep "^REDIS_URL=" "$ENV_FILE" | cut -d= -f2)

assert_eq "AUTH_MODE preserved" "upstream" "$PROD_AUTH_MODE"
assert_eq "DATABASE_URL preserved" "postgresql+psycopg2://root:prod_password@localhost:5432/quant_zc" "$PROD_DB_URL"
assert_eq "AUTH_UPSTREAM_URL preserved" "http://127.0.0.1:5000" "$PROD_UPSTREAM"
assert_eq "AUTH_SECRET_KEY preserved" "prod_secret_key_abc123" "$PROD_SECRET"
assert_eq "REDIS_URL preserved" "redis://:prod_redis_pass@localhost:6379/0" "$PROD_REDIS"
assert_eq "New code synced" "app.py" "$(ls "$PKG_DIR" | grep app.py)"

# ── 测试 2：sync_env 跳过占位符值 ──
echo ""
echo "=== Test 2: sync_env skips placeholder values ==="

PKG_DIR2="$TMPROOT/package2"
mkdir -p "$PKG_DIR2"

cat > "$PKG_DIR2/.env" << 'EOF'
AUTH_MODE=upstream
DATABASE_URL=postgresql+psycopg2://root:prod_password@localhost:5432/quant_zc
APP_NAME=financial-api
EOF

cat > "$PKG_DIR2/.env.example" << 'EOF'
APP_NAME=financial-api
AUTH_MODE=local
AUTH_SECRET_KEY=__AUTH_SECRET_KEY__
DATABASE_URL=postgresql+psycopg2://root:__PG_PASSWORD__@localhost:5432/quant_zc
REDIS_URL=redis://:__REDIS_PASSWORD__@localhost:6379/0
CRAWLER_ENABLED=true
AUTH_UPSTREAM_URL=http://127.0.0.1:5000
EOF

env_file="$PKG_DIR2/.env"
example="$PKG_DIR2/.env.example"
missing=()
skipped_placeholder=0
while IFS='=' read -r key val; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    key=$(echo "$key" | xargs)
    if [[ "$val" =~ __[A-Z_]+__ ]]; then
        skipped_placeholder=$((skipped_placeholder + 1))
        continue
    fi
    if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
        missing+=("$key=$val")
    fi
done < "$example"

assert_eq "Missing count (CRAWLER_ENABLED + AUTH_UPSTREAM_URL)" "2" "${#missing[@]}"
assert_eq "Skipped placeholder count" "3" "$skipped_placeholder"

for item in "${missing[@]}"; do
    echo "  [INFO] Would append: $item"
done

HAS_PLACEHOLDER=$(printf "%s\n" "${missing[@]}" | grep -c "__" || true)
assert_eq "No placeholder values appended" "0" "$HAS_PLACEHOLDER"

# ── 测试 3：回归对照 — 旧逻辑（无保护）确实会覆盖 .env ──
echo ""
echo "=== Test 3: Regression — old logic WITHOUT fix overwrites .env ==="

PKG_DIR3="$TMPROOT/package3"
SRC_DIR3="$TMPROOT/src3"
ENV_FILE3="$PKG_DIR3/.env"

mkdir -p "$PKG_DIR3" "$SRC_DIR3"

cat > "$ENV_FILE3" << 'EOF'
AUTH_MODE=upstream
DATABASE_URL=postgresql+psycopg2://root:prod_password@localhost:5432/quant_zc
EOF

cat > "$SRC_DIR3/.env" << 'EOF'
AUTH_MODE=local
DATABASE_URL=postgresql+psycopg2://dev:devpass@localhost:5432/devdb
EOF
echo "app.py" > "$SRC_DIR3/app.py"

# 旧逻辑（无保护）
find "$PKG_DIR3" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name '.venv' ! -name 'logs' \
    -exec rm -rf {} + 2>/dev/null || true
cp -a "${SRC_DIR3%/}/." "$PKG_DIR3/"

OLD_AUTH_MODE=$(grep "^AUTH_MODE=" "$ENV_FILE3" | cut -d= -f2)
assert_eq "Old logic: AUTH_MODE overwritten to local" "local" "$OLD_AUTH_MODE"
echo "  [INFO] Confirms old logic was buggy — .env was overwritten by package .env"

# ── 清理 ──
rm -rf "$TMPROOT"

echo ""
echo "================================"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "================================"
[[ $FAIL -eq 0 ]]
