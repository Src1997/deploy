# 远程开发

> **Category**: Guide

本地开发时直连远程服务器数据库/后端，无需在本地启动 PostgreSQL/Redis/后端服务。

## SSH 免密配置

已配置 `~/.ssh/config`，可直接用别名连接：

```bash
ssh serverA    # → root@121.41.44.216:22
ssh serverB    # → root@103.100.211.12:3142
ssh serverC    # → root@177.4.41.137:22（2026-10-16 新增：云商学院）
```

## 服务器信息

| | 服务器 A | 服务器 B | 服务器 C |
|---|---------|---------|---------|
| **别名** | `serverA` | `serverB` | `serverC` |
| **IP** | 121.41.44.216 | 103.100.211.12 | 177.4.41.137 |
| **SSH 端口** | 22 | 3142 | 22 |
| **域名** | `www.zhuochou.xyz` | `www.deepquant.club` | `www.zhouchou.net` |
| **Nginx 模式** | `ssl-redirect` | `ssl-combined` | `ssl-combined` |
| **PostgreSQL** | 见 `deploy.env` 的 `PG_*` | 同左 | 本机宝塔实例 |
| **数据库** | quant_zc, quantdinger | quant_zc, quantdinger | quant_zc, quantdinger |
| **Redis** | 远程指向服务器 B（103.100.211.12:6379） | 本机实例 | 远程指向服务器 B（WireGuard 隧道 10.10.0.2:6379） |
| **SMTP** | 宝塔邮局 `noreply@zhuochou.xyz` | — | — |
| **行情 WS** | follower（读 B 的 Redis 分发） | leader（唯一连 Finnhub WSS） | follower（读 B 的 Redis 分发，DB feed_enabled=false） |

> ★2026-10-10 服务器 A 换机：旧机 47.86.32.234（阿里云 HK）已停用，换为 121.41.44.216；
> 域名同步由 `zhuochouacedemy.com` 改为 `zhuochou.xyz`。跨机 Redis 架构保持不变。
>
> ★2026-10-19 Finnhub 行情单 key 约束：免费 key 仅允许极有限 WSS 连接，**同一把 key 上
> 多客户端互踢会触发 IP 级 429/403 惩罚（殃及 REST）**。规范：B 单 leader；C/A 的
> `fin_data_source_configs` 里 finnhub.feed_enabled 必须为 false（DB 优先于 .env）。
> quantdinger 的 XAUUSD 流与 financial 共用 key 会互踢，待换独立 key（用户 2026-10-19 拍板暂缓）。

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
| financial-api | `.env.remoteA` | 121.41.44.216 PostgreSQL + Redis |
| financial-api | `.env.remoteB` | 103.100.211.12 PostgreSQL + Redis |
| financial-web | `.env.remoteA` | 121.41.44.216 /api + WebSocket |
| financial-web | `.env.remoteB` | 103.100.211.12 /api + WebSocket |
| deepquant_vue | `.env.remoteA` | 121.41.44.216 /quant/api |
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
