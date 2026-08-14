#!/bin/bash
# ============================================================
# WSL 服务统一修复脚本（宝塔 systemd unit 优先）
#
# 用途：消除 init.d 冗余 unit，统一由 BT systemd unit 管理
#       PG/Redis/Panel，SSH 走 ssh.socket，Nginx 走 init.d。
#       修复 wsl.conf 默认用户，消除 getpwuid(1000) 报错。
#
# 用法：wsl -u root bash /mnt/d/Workspace/deploy/scripts/ops/wsl-autostart.sh
#
# 安全性：幂等，可重复执行。密码从配置文件读取，不硬编码。
# ============================================================
set -euo pipefail

# -- Color helpers --
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }

echo "=========================================="
echo " WSL Service Fix (BT systemd-first)"
echo "=========================================="

# -- 0. Preflight: must be root --
if [ "$(id -u)" -ne 0 ]; then
  err "Must run as root. Use: wsl -u root bash $0"
  exit 1
fi

# -- 1. Remove redundant init.d scripts (BT systemd units replace them) --
echo ""
echo "=== 1. Remove redundant init.d scripts ==="

# Redis: /etc/init.d/redis -> auto-generates redis.service, conflicts with bt-redis.service
if [ -f /etc/init.d/redis ]; then
  systemctl stop redis.service 2>/dev/null || true
  rm -f /etc/init.d/redis
  update-rc.d redis remove 2>/dev/null || true
  ok "Removed /etc/init.d/redis (replaced by bt-redis.service)"
else
  ok "/etc/init.d/redis already removed"
fi

# PostgreSQL: /etc/init.d/pgsql -> auto-generates pgsql.service, conflicts with bt-pgsql.service
if [ -f /etc/init.d/pgsql ]; then
  # Do NOT stop pgsql.service — it would kill the running PG process.
  # Just disable auto-start and remove the script.
  systemctl disable pgsql.service 2>/dev/null || true
  rm -f /etc/init.d/pgsql
  update-rc.d pgsql remove 2>/dev/null || true
  ok "Removed /etc/init.d/pgsql (replaced by bt-pgsql.service)"
else
  ok "/etc/init.d/pgsql already removed"
fi

# -- 2. Write BT systemd unit files --
echo ""
echo "=== 2. Write BT systemd unit files ==="

# bt-pgsql.service
cat > /etc/systemd/system/bt-pgsql.service << 'EOF'
[Unit]
Description=BT PostgreSQL
After=network.target

[Service]
Type=forking
User=postgres
ExecStart=/www/server/pgsql/bin/pg_ctl -D /www/server/pgsql/data -l /www/server/pgsql/data/pg.log start
ExecStop=/www/server/pgsql/bin/pg_ctl -D /www/server/pgsql/data stop
ExecReload=/www/server/pgsql/bin/pg_ctl -D /www/server/pgsql/data reload
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ok "bt-pgsql.service written"

# bt-redis.service (use REDISCLI_AUTH env var instead of -a flag)
REDIS_PASS=$(awk '/^requirepass/{print $2}' /www/server/redis/redis.conf 2>/dev/null || true)
if [ -z "$REDIS_PASS" ]; then
  warn "No requirepass found in redis.conf, bt-redis ExecStop will use no auth"
  cat > /etc/systemd/system/bt-redis.service << 'EOF'
[Unit]
Description=BT Redis
After=network.target

[Service]
Type=forking
ExecStart=/www/server/redis/src/redis-server /www/server/redis/redis.conf --daemonize yes
ExecStop=/www/server/redis/src/redis-cli shutdown nosave
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
else
  cat > /etc/systemd/system/bt-redis.service << EOF
[Unit]
Description=BT Redis
After=network.target

[Service]
Type=forking
Environment=REDISCLI_AUTH=${REDIS_PASS}
ExecStart=/www/server/redis/src/redis-server /www/server/redis/redis.conf --daemonize yes
ExecStop=/www/server/redis/src/redis-cli shutdown nosave
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi
ok "bt-redis.service written (REDISCLI_AUTH=$([ -n "$REDIS_PASS" ] && echo 'yes' || echo 'no'))"

# bt-panel.service (fix historical GAfterExit typo -> RemainAfterExit)
cat > /etc/systemd/system/bt-panel.service << 'EOF'
[Unit]
Description=BT Panel
After=network.target

[Service]
Type=forking
ExecStart=/etc/init.d/bt start
ExecStop=/etc/init.d/bt stop
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ok "bt-panel.service written (RemainAfterExit fixed)"

# -- 3. PG config: listen_addresses + dynamic_shared_memory + pg_hba --
echo ""
echo "=== 3. PostgreSQL config ==="
PG_CONF=/www/server/pgsql/data/postgresql.conf
PG_HBA=/www/server/pgsql/data/pg_hba.conf

# listen_addresses = '*'
sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
grep -q "^listen_addresses" "$PG_CONF" || echo "listen_addresses = '*'" >> "$PG_CONF"
ok "PG listen_addresses = '*'"

# dynamic_shared_memory_type = mmap (required for WSL2)
sed -i "s/^#\?dynamic_shared_memory_type.*/dynamic_shared_memory_type = mmap/" "$PG_CONF"
ok "PG dynamic_shared_memory_type = mmap"

# pg_hba: allow 0.0.0.0/0 md5
grep -q "0.0.0.0/0" "$PG_HBA" || echo "host all all 0.0.0.0/0 md5" >> "$PG_HBA"
ok "PG pg_hba allows 0.0.0.0/0 md5"

# -- 4. Redis config: bind 0.0.0.0 --
echo ""
echo "=== 4. Redis config ==="
REDIS_CONF=/www/server/redis/redis.conf
sed -i 's/^bind .*/bind 0.0.0.0/' "$REDIS_CONF"
ok "Redis bind 0.0.0.0"

# -- 5. wsl.conf: set default=root (fix getpwuid(1000) error) --
echo ""
echo "=== 5. Fix wsl.conf ==="
if ! grep -q '\[user\]' /etc/wsl.conf; then
  printf '\n[user]\ndefault=root\n' >> /etc/wsl.conf
  ok "Added [user] default=root to wsl.conf"
else
  ok "wsl.conf already has [user] section"
fi
cat /etc/wsl.conf

# -- 6. daemon-reload + enable + start --
echo ""
echo "=== 6. Enable and start BT services ==="
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
systemctl enable bt-panel.service bt-pgsql.service bt-redis.service 2>&1
ok "All BT units enabled"

# Start services (don't fail if already running)
systemctl start bt-panel.service 2>/dev/null || true
systemctl start bt-pgsql.service 2>/dev/null || true
systemctl start bt-redis.service 2>/dev/null || true

# Ensure ssh.socket is enabled (socket activation for SSH)
systemctl enable ssh.socket 2>/dev/null || true
systemctl start ssh.socket 2>/dev/null || true
ok "ssh.socket enabled and started"

# -- 7. Verify --
echo ""
echo "=== 7. Verification ==="
sleep 2

echo "--- systemd overall ---"
systemctl is-system-running 2>&1 || true

echo "--- BT units (enabled / active) ---"
for svc in bt-panel bt-pgsql bt-redis; do
  enabled=$(systemctl is-enabled "$svc" 2>&1)
  active=$(systemctl is-active "$svc" 2>&1)
  echo "  $svc: enabled=$enabled active=$active"
done

echo "--- SSH ---"
echo "  ssh.socket: enabled=$(systemctl is-enabled ssh.socket 2>&1) active=$(systemctl is-active ssh.socket 2>&1)"

echo "--- Nginx ---"
echo "  nginx: active=$(systemctl is-active nginx 2>&1)"

echo "--- Failed units ---"
systemctl --failed 2>&1

echo "--- Port listeners ---"
ss -tlnp 2>&1 | grep -E ':22 |:5432 |:6379 |:42406 ' || warn "No expected ports found"

echo "--- PG connection test ---"
PGPASSWORD=root1.0 /www/server/pgsql/bin/psql -h 127.0.0.1 -U root -d postgres -c 'SELECT 1 as ok;' 2>&1 | head -5 || err "PG connection failed"

echo "--- Redis connection test ---"
if [ -n "$REDIS_PASS" ]; then
  /www/server/redis/src/redis-cli -a "$REDIS_PASS" ping 2>&1 || err "Redis connection failed"
else
  /www/server/redis/src/redis-cli ping 2>&1 || err "Redis connection failed"
fi

echo ""
echo "=========================================="
echo " Fix complete."
echo " If wsl.conf was modified, run:"
echo "   wsl --shutdown && wsl"
echo " to apply the default user change."
echo "=========================================="
