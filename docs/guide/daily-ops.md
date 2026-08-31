# 日常运维

> **Category**: Guide

## 服务管理

```bash
# 查看所有服务状态
systemctl status financial-api financial-crawler financial-worker financial-streaming quantdinger-backend

# 重启单个服务
systemctl restart financial-api
systemctl restart quantdinger-backend

# 停止/启动
systemctl stop financial-api
systemctl start financial-api

# 开机自启
systemctl enable financial-api quantdinger-backend
```

## 日志排查

```bash
# 实时查看日志
journalctl -u financial-api -f
journalctl -u quantdinger-backend -f

# 最近 50 行
journalctl -u financial-api -n 50 --no-pager

# 按时间查日志
journalctl -u financial-api --since "2026-07-28 10:00" --until "2026-07-28 12:00" --no-pager

# 只看错误
journalctl -u financial-api -p err --no-pager

# Nginx 日志
tail -f /www/wwwlogs/access.log
tail -f /www/wwwlogs/error.log
tail -f /www/wwwlogs/error.log | grep -E '502|504|upstream'
```

## 健康检查

```bash
curl -s http://127.0.0.1:5001/api/health | python3 -m json.tool    # financial-api
curl -s http://127.0.0.1:5000/api/health | python3 -m json.tool    # QuantDinger
curl -s http://127.0.0.1:5001/api/system/runtime-config | python3 -m json.tool

ss -tlnp | grep -E '5000|5001|80|443|5432|6379'
```

## Nginx 操作

```bash
nginx -t                              # 测试配置
nginx -s reload                       # 重载配置
cat /www/server/panel/vhost/nginx/default.conf   # 查看当前配置

# 更新 Nginx 配置（动态生成）
bash deploy.sh --nginx
```

## 数据库操作

```bash
# 连接数据库
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quantdinger

# 查看表列表
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc -c "\dt"

# 数据库备份
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc | gzip > /root/backup_quant_zc_$(date +%Y%m%d).sql.gz

# 数据库恢复
gunzip -c /root/backup_quant_zc_20260728.sql.gz | PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc

# Alembic 迁移
cd /www/wwwroot/project/financial/financial-api/package
.venv/bin/alembic upgrade head
.venv/bin/alembic current

# 重新加载种子数据
.venv/bin/python -m app.db.seed
```

## Redis 操作

```bash
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD ping
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD info
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD info memory | grep used_memory_human
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD dbsize
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD --scan --pattern 'fin_*' | head -20
```

## 磁盘与系统检查

```bash
df -h                          # 总体磁盘使用
du -sh /* 2>/dev/null | sort -rh | head -10    # 根目录下各目录占用
du -sh /www/*/ 2>/dev/null | sort -rh          # /www 下各子目录
free -h                        # 内存使用
ps aux --sort=-%cpu | head -6   # CPU 占用最高的进程
```

## 日志治理与磁盘清理

### PostgreSQL 日志（最常见磁盘杀手）

PG 日志默认在 `/www/server/pgsql/logs/`，每天一个文件。如果 `log_statement = all`，
每条 SQL 都会被记录，高频轮询场景下单日可达 2-5G。

```bash
# 查看 PG 日志目录大小
PG_LOG_DIR=/www/server/pgsql/logs
du -sh "$PG_LOG_DIR"
ls -lhS "$PG_LOG_DIR" | head -10

# 查看当前 PG 日志配置
PG_CONF=/www/server/pgsql/data/postgresql.conf
grep -E '^log_statement|^logging_collector|^log_directory|^log_filename|^log_rotation|^log_truncate|^log_min_duration' "$PG_CONF"

# ── 清理旧 PG 日志（保留最近 3 天）──
find "$PG_LOG_DIR" -name 'postgresql-*.log' -mtime +3 -delete

# ── 清空大日志文件内容（保留文件本身，不破坏 PG 的文件句柄）──
cd "$PG_LOG_DIR"
for f in postgresql-2026-08-2*.log; do
  [ -f "$f" ] && cat /dev/null > "$f"
done

# ── 修改 PG 日志配置防止再次爆满 ──
# log_statement = all   →  none      （不记录每条 SQL，慢查询仍由 log_min_duration_statement 捕获）
# log_rotation_size     = 10MB       （单文件超过 10MB 自动轮转）
# log_truncate_on_rotation = on      （同名日志文件覆盖）
#
# 修改后 reload 生效（无需重启 PG）：
su - postgres -c '/www/server/pgsql/bin/pg_ctl reload -D /www/server/pgsql/data'
```

### journald 日志

```bash
# 查看占用
du -sh /var/log/journal/

# 压缩到 100M（立即生效）
journalctl --vacuum-size=100M

# 查看某服务最近日志
journalctl -u financial-api -n 50 --no-pager
journalctl -u financial-api --since '10 min ago' --no-pager
```

### 应用日志与备份

```bash
# financial-api 应用日志
APP_LOGS=/www/wwwroot/project/financial/financial-api/package/logs
du -sh "$APP_LOGS"
ls -lhS "$APP_LOGS" | head -10
# 清理旧轮转日志（保留当前日志文件）
find "$APP_LOGS" -name '*.log.*' -delete

# financial-api 部署备份
BACKUP_DIR=/www/wwwroot/project/financial/financial-api/backup
du -sh "$BACKUP_DIR"
ls -lht "$BACKUP_DIR"
# 删除旧备份（保留最近一份）
cd "$BACKUP_DIR" && ls -dt */ | tail -n +2 | xargs rm -rf

# 项目级备份
du -sh /www/wwwroot/project/backup/
rm -rf /www/wwwroot/project/backup/*

# Nginx 日志
> /www/wwwlogs/access.log
> /www/wwwlogs/error.log

# Python 缓存
find /www/wwwroot/project -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
```

### 配置 logrotate（推荐，持久化日志轮转）

```bash
# 创建 PostgreSQL logrotate 配置
cat > /etc/logrotate.d/postgresql << 'EOF'
/www/server/pgsql/logs/postgresql-*.log {
    daily
    rotate 3
    size 100M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# 创建 financial-api 应用日志 logrotate 配置
cat > /etc/logrotate.d/financial-api << 'EOF'
/www/wwwroot/project/financial/financial-api/package/logs/*.log {
    daily
    rotate 7
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# 测试 logrotate 配置
logrotate -d /etc/logrotate.d/postgresql
logrotate -d /etc/logrotate.d/financial-api

# 手动触发一次 logrotate
logrotate -f /etc/logrotate.d/postgresql
```

### 添加 cron 定时清理（简易方案）

```bash
# 每天凌晨 4 点清理旧日志
crontab -l 2>/dev/null | { cat; echo '0 4 * * * find /www/server/pgsql/logs -name "postgresql-*.log" -mtime +3 -delete && journalctl --vacuum-size=100M >> /dev/null 2>&1'; } | crontab -
```

## 宝塔面板操作

```bash
bt default              # 查看面板登录信息
bt 5                    # 重置面板密码
bt 16                   # 修复面板
bt restart              # 重启面板
/etc/init.d/nginx restart       # 重启 Nginx
/etc/init.d/redis restart       # 重启 Redis
```

## 常见故障排查 SOP

### 故障 1: 磁盘 100% 导致后端挂掉

**症状**: `systemctl status financial-api` 显示 `active` 但 API 返回 500/502，
日志中出现 `OSError: [Errno 28] No space left on device` 或
`sqlalchemy.exc.OperationalError: ... FATAL: the database system is in recovery mode`。

**根因链**:

```
PG 配置 log_statement = all（记录每条 SQL）
  → EA snapshot/deals poller 每 3s 轮询，pending_orders worker 每 1s 轮询
  → 每条 SQL 被 PG 记录到日志（2-5G/天）
  → 磁盘 100% 写满
  → PostgreSQL WAL 写不进去 → 进入 recovery mode
  → financial-api / financial-worker 连不上数据库 → 后端挂了
```

**排查步骤**:

```bash
# Step 1: 确认磁盘满
df -h

# Step 2: 找到最大占用目录
du -sh /* 2>/dev/null | sort -rh | head -5
du -sh /www/server/*/ 2>/dev/null | sort -rh | head -5

# Step 3: 如果是 PG 日志，查看大小和内容
du -sh /www/server/pgsql/logs/
ls -lhS /www/server/pgsql/logs/ | head -10
# 查看日志内容确认是否是 SQL 语句被记录
tail -50 /www/server/pgsql/logs/postgresql-$(date +%Y-%m-%d).log

# Step 4: 确认 PG 是否在 recovery mode
su - postgres -c '/www/server/pgsql/bin/psql -tAc "SELECT pg_is_in_recovery();"'
# 返回 t = 正在 recovery, f = 正常
```

**修复步骤**:

```bash
# 1. 清理 PG 日志（见上方「日志治理与磁盘清理」章节）
# 2. 等 PG 自动完成 recovery（通常几秒到几分钟）
# 3. 确认 PG 恢复正常
su - postgres -c '/www/server/pgsql/bin/psql -tAc "SELECT pg_is_in_recovery();"'  # 应返回 f

# 4. 重启后端服务
systemctl restart financial-api financial-worker financial-streaming financial-crawler
sleep 3

# 5. 健康检查
systemctl is-active financial-api financial-crawler financial-worker financial-streaming
curl -sf http://127.0.0.1:5001/api/health

# 6. 修改 PG 日志配置防止复发（见上方 log_statement = none）
# 7. 配置 logrotate（见上方 logrotate 章节）
```

### 故障 2: 后端 502 / 连接被拒绝

**症状**: Nginx 返回 502 Bad Gateway。

```bash
# 检查服务是否运行
systemctl is-active financial-api
systemctl status financial-api --no-pager -l

# 检查端口是否监听
ss -tlnp | grep 5001

# 如果服务挂了，查看日志找原因
journalctl -u financial-api -n 50 --no-pager

# 常见原因:
# - .env 被覆盖（DATABASE_URL / AUTH_MODE 错误）→ 恢复 .env
# - Alembic __pycache__ 缓存 → 清理后重启
# - 端口被占用 → kill 旧进程后重启
```

### 故障 3: PostgreSQL 连接失败

```bash
# 检查 PG 是否运行
systemctl status postgresql 2>/dev/null || /etc/init.d/pgsql status

# 检查 PG 是否在 recovery
su - postgres -c '/www/server/pgsql/bin/psql -tAc "SELECT pg_is_in_recovery();"'

# 查看 PG 日志
tail -50 /www/server/pgsql/logs/postgresql-$(date +%Y-%m-%d).log

# 常见原因:
# - 磁盘满 → 清理磁盘后 PG 自动恢复
# - max_connections 不够 → 查看连接数
su - postgres -c '/www/server/pgsql/bin/psql -tAc "SELECT count(*) FROM pg_stat_activity;"'
# - 数据库损坏 → 从备份恢复
```

### 故障 4: Redis 连接失败

```bash
# 检查 Redis 是否运行
systemctl status redis-server 2>/dev/null || /etc/init.d/redis status

# 测试连接
redis-cli -h localhost -p 6379 -a "$REDIS_PASSWORD" ping
# 应返回 PONG

# 查看内存
redis-cli -h localhost -p 6379 -a "$REDIS_PASSWORD" info memory | grep used_memory_human

# 重启 Redis
/etc/init.d/redis restart
```

### 故障 5: 前端页面空白 / 静态资源 404

```bash
# 检查 Nginx 配置
nginx -t

# 检查前端文件是否存在
ls -la /www/wwwroot/project/financial/financial-web/dist/
ls -la /www/wwwroot/project/financial/financial-admin/dist/

# 重载 Nginx
nginx -s reload

# 查看 Nginx 错误日志
tail -20 /www/wwwlogs/error.log
```

## 一键排查脚本

```bash
#!/bin/bash
# 快速排查脚本 — 在服务器上直接运行
echo "===== 磁盘 ====="
df -h /
echo ""
echo "===== 服务状态 ====="
systemctl is-active financial-api financial-crawler financial-worker financial-streaming quantdinger-backend
echo ""
echo "===== 端口监听 ====="
ss -tlnp | grep -E '5000|5001|80|443|5432|6379'
echo ""
echo "===== 健康检查 ====="
curl -sf http://127.0.0.1:5001/api/health 2>/dev/null || echo "financial-api: FAIL"
curl -sf http://127.0.0.1:5000/api/health 2>/dev/null || echo "quantdinger-backend: FAIL"
echo ""
echo "===== PG 状态 ====="
su - postgres -c '/www/server/pgsql/bin/psql -tAc "SELECT pg_is_in_recovery();"' 2>/dev/null || echo "PG: FAIL"
echo ""
echo "===== Redis ====="
redis-cli -h localhost -p 6379 ping 2>/dev/null || echo "Redis: FAIL"
echo ""
echo "===== 磁盘大户 TOP 5 ====="
du -sh /www/server/pgsql/logs/ /www/wwwroot/project/financial/financial-api/backup/ /www/wwwroot/project/financial/financial-api/package/logs/ /var/log/journal/ /www/wwwlogs/ 2>/dev/null | sort -rh | head -5
echo ""
echo "===== 最近错误日志 ====="
journalctl -u financial-api -p err -n 5 --no-pager 2>/dev/null
```

## 定期备份

```bash
cat > /root/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/root/backups"
mkdir -p "$BACKUP_DIR"
DATE=$(date +%Y%m%d_%H%M%S)
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc | gzip > "$BACKUP_DIR/quant_zc_$DATE.sql.gz"
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quantdinger | gzip > "$BACKUP_DIR/quantdinger_$DATE.sql.gz"
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
echo "备份完成: $DATE"
EOF
chmod +x /root/backup.sh

# 添加定时任务（每天凌晨 3 点）
crontab -l 2>/dev/null | { cat; echo "0 3 * * * /root/backup.sh >> /root/backup.log 2>&1"; } | crontab -
```
