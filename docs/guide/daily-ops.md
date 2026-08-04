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
df -h
du -sh /www/wwwroot/project/*
free -h
ps aux --sort=-%cpu | head -6

# 清理日志
journalctl --vacuum-size=500M
> /www/wwwlogs/access.log
> /www/wwwlogs/error.log

# 清理 Python 缓存
find /www/wwwroot/project -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
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
