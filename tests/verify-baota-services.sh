#!/bin/bash
set -e

echo "=== Verify BaoTa Redis ==="
REDIS_CLI="/www/server/redis/src/redis-cli"
REDIS_PASS="7d7ced854319d1df"
if sudo "$REDIS_CLI" -a "$REDIS_PASS" ping 2>/dev/null | grep -q PONG; then
    echo "[OK] BaoTa Redis running (PONG) on port 6379"
else
    echo "[FAIL] BaoTa Redis not responding"
    exit 1
fi

echo ""
echo "=== Verify BaoTa PostgreSQL ==="
PSQL="/www/server/pgsql/bin/psql"
PGPASS="root1.0"

# Check if psql exists and has correct permissions
if sudo test -x "$PSQL"; then
    echo "[OK] psql binary exists"
else
    echo "[FAIL] psql binary not found or no permission"
    sudo ls -la "$PSQL" 2>&1 || true
    exit 1
fi

# Test connection to quant_zc
echo ""
echo "--- Test quant_zc connection ---"
if sudo PGPASSWORD="$PGPASS" "$PSQL" -h 127.0.0.1 -p 5432 -U root -d quant_zc -c "SELECT 1 as test;" 2>/dev/null | grep -q "1"; then
    echo "[OK] PostgreSQL connection to quant_zc works"
else
    echo "[FAIL] PostgreSQL connection to quant_zc failed"
    sudo PGPASSWORD="$PGPASS" "$PSQL" -h 127.0.0.1 -p 5432 -U root -d quant_zc -c "SELECT 1;" 2>&1 || true
    # Try with postgres user
    echo "--- Try with postgres user ---"
    sudo -u postgres "$PSQL" -p 5432 -c "SELECT 1;" 2>&1 || true
    exit 1
fi

echo ""
echo "=== Database list ==="
sudo PGPASSWORD="$PGPASS" "$PSQL" -h 127.0.0.1 -p 5432 -U root -l 2>/dev/null

echo ""
echo "=== Check ports ==="
ss -tlnp 2>/dev/null | grep -E "5432|6379" || echo "ss not available"

echo ""
echo "=== All BaoTa services verified ==="
