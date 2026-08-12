#!/bin/bash
# WSL 开机自启 + Windows 可连接配置
set -e

echo "=== 1. PG: 配置监听 0.0.0.0 ==="
PG_CONF=/www/server/pgsql/data/postgresql.conf
PG_HBA=/www/server/pgsql/data/pg_hba.conf
# 取消注释并设为 *
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
grep -q "^listen_addresses" "$PG_CONF" || echo "listen_addresses = '*'" >> "$PG_CONF"
# 允许所有 IP 密码连接
grep -q "0.0.0.0/0" "$PG_HBA" || echo "host all all 0.0.0.0/0 md5" >> "$PG_HBA"
# 重启 PG
su - postgres -c "/www/server/pgsql/bin/pg_ctl -D /www/server/pgsql/data -l /www/server/pgsql/data/pg.log restart" 2>&1
echo "PG configured and restarted"

echo "=== 2. Redis: 配置监听 0.0.0.0 ==="
REDIS_CONF=/www/server/redis/redis.conf
sed -i 's/^bind .*/bind 0.0.0.0/' "$REDIS_CONF"
# 重启 Redis
/www/server/redis/src/redis-cli -a 7d7ced854319d1df shutdown nosave 2>/dev/null || true
sleep 1
/www/server/redis/src/redis-server "$REDIS_CONF" --daemonize yes
echo "Redis configured and restarted"

echo "=== 3. 创建 systemd 服务 ==="
# PG systemd service
cat > /etc/systemd/system/bt-pgsql.service << 'EOF'
[Unit]
Description=BT PostgreSQL
After=network.target

[Service]
Type=forking
User=postgres
ExecStart=/www/server/pgsql/bin/pg_ctl -D /www/server/pgsql/data -l /www/server/pgsql/data/pg.log start
ExecStop=/www/server/pgsql/bin/pg_ctl -D /www/server/pgsql/data stop
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Redis systemd service
cat > /etc/systemd/system/bt-redis.service << 'EOF'
[Unit]
Description=BT Redis
After=network.target

[Service]
Type=forking
ExecStart=/www/server/redis/src/redis-server /www/server/redis/redis.conf --daemonize yes
ExecStop=/www/server/redis/src/redis-cli -a 7d7ced854319d1df shutdown nosave
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# BT Panel systemd service
cat > /etc/systemd/system/bt-panel.service << 'EOF'
[Unit]
Description=BT Panel
After=network.target

[Service]
Type=forking
ExecStart=/etc/init.d/bt start
ExecStop=/etc/init.d/bt stop
Restart=on-failure
GAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bt-pgsql bt-redis bt-panel 2>&1
echo "Systemd services created and enabled"

echo "=== 4. 验证 ==="
sleep 2
/www/server/pgsql/bin/pg_isready -h 127.0.0.1 -p 5432 2>&1
/www/server/redis/src/redis-cli -a 7d7ced854319d1df ping 2>&1
echo "=== ALL DONE ==="
