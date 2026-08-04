# 远程开发

> **Category**: Guide

本地开发时直连远程服务器数据库/后端，无需在本地启动 PostgreSQL/Redis/后端服务。

## SSH 免密配置

已配置 `~/.ssh/config`，可直接用别名连接：

```bash
ssh serverA    # → root@47.86.32.234:22
ssh serverB    # → root@103.100.211.12:3142
```

## 服务器信息

| | 服务器 A | 服务器 B |
|---|---------|---------|
| **别名** | `serverA` | `serverB` |
| **IP** | 47.86.32.234 | 103.100.211.12 |
| **SSH 端口** | 22 | 3142 |
| **域名** | `www.zhuochouacedemy.com` | `www.deepquant.club` |
| **Nginx 模式** | `ssl-redirect` | `ssl-combined` |
| **PostgreSQL** | 见 `deploy.env` 的 `PG_*` | 同左 |
| **数据库** | quant_zc, quantdinger | quant_zc, quantdinger |
| **Redis 密码** | 见 `REDIS_PASSWORD` | 见 `REDIS_PASSWORD` |
| **SMTP** | 宝塔邮局 `noreply@zhuochouacedemy.com` | — |

## 远程开发启动命令

### financial-api（后端直连远程 DB）

```powershell
cd D:\Workspace\financial\financial-api
$env:ENV_FILE=".env.remoteA"; uv run uvicorn app.main:app --reload
$env:ENV_FILE=".env.remoteB"; uv run uvicorn app.main:app --reload
```

> 远程模式自动设为 `APP_ROLE=api`，不启动爬虫和实时推送，只读查询远程 DB。

### financial-web（C 端直连远程后端）

```powershell
cd D:\Workspace\financial\financial-web
pnpm dev:remoteA    # 连接服务器 A 后端
pnpm dev:remoteB    # 连接服务器 B 后端
```

### deepquant_vue（QuantDinger 前端直连远程后端）

```powershell
cd D:\Workspace\deep\deepquant_vue
pnpm dev:remoteA    # 连接服务器 A 的 QuantDinger 后端
pnpm dev:remoteB    # 连接服务器 B 的 QuantDinger 后端
```

## 配置文件清单

| 项目 | 文件 | 连接目标 |
|------|------|----------|
| financial-api | `.env.remoteA` | 47.86.32.234 PostgreSQL + Redis |
| financial-api | `.env.remoteB` | 103.100.211.12 PostgreSQL + Redis |
| financial-web | `.env.remoteA` | 47.86.32.234 /api + WebSocket |
| financial-web | `.env.remoteB` | 103.100.211.12 /api + WebSocket |
| deepquant_vue | `.env.remoteA` | 47.86.32.234 /quant/api |
| deepquant_vue | `.env.remoteB` | 103.100.211.12 /quant/api |

## 服务器端 PostgreSQL 远程访问

首次使用需在服务器上配置 PostgreSQL 允许远程连接（SSH 到服务器执行）：

```bash
# 修改 postgresql.conf
PG_CONF=$(find /www/server/ -name "postgresql.conf" 2>/dev/null | head -1)
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"

# 修改 pg_hba.conf
PG_HBA=$(find /www/server/ -name "pg_hba.conf" 2>/dev/null | head -1)
cat >> "$PG_HBA" << 'EOF'
host    all    all    0.0.0.0/0    md5
host    all    all    ::/0         md5
EOF

# 设置 root 密码
su - postgres -c "psql -c \"ALTER USER root WITH PASSWORD '$PG_PASSWORD';\""
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE quant_zc TO root;\""

# 重启
/etc/init.d/postgresql restart
# 远程开发如需连库：仅对你的办公 IP 在「云安全组」临时放行 5432，或优先用 SSH 隧道。
```
