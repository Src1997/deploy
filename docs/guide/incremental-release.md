# 增量发版与回滚

> **Category**: Guide

首次部署使用 `build.ps1 all` + `deploy.sh all` 全量构建和部署。
后续单项目更新使用 `build.ps1 <项目>` + `deploy.sh <项目>` 增量发版。

## 支持的项目

| 项目名 | 说明 | kind | 构建方式 | 重启服务 |
|--------|------|------|----------|----------|
| `financial-web` | 行情/社区前端 | frontend | pnpm build | nginx reload |
| `financial-admin` | 管理后台 | frontend | pnpm build | nginx reload |
| `financial-api` | FastAPI 后端 | python | 源码 robocopy (app-package) | financial-api + crawler + worker + streaming |
| `official-site` | 卓筹介绍站 | frontend | pnpm build | nginx reload |
| `deepquant-web` | QuantDinger 前端 | frontend | pnpm build | nginx reload |
| `deepquant-backend` | QuantDinger 后端 | python | 源码 robocopy (source-tar) | quantdinger-backend |

> 组件类型（`kind`）：`frontend` / `python` / `java` / `go` / `nodejs`，详见 [README.md 支持的组件类型](../README.md#支持的组件类型)。
> Java 部署 JAR/WAR + systemd；Go 部署二进制 + systemd；Node.js 部署源码 + `npm ci --production` + systemd。

## WSL 宝塔环境测试

WSL Ubuntu 中使用宝塔面板安装的 Redis 和 PostgreSQL 进行本地测试：

| 服务 | 路径 | 端口 | 认证 |
|------|------|------|------|
| Redis | `/www/server/redis/` | 6379 | `requirepass`（见 `deploy.env`） |
| PostgreSQL | `/www/server/pgsql/` | 5432 | `PG_USER` + `PG_PASSWORD`（见 `deploy.env`） |

```bash
# 验证宝塔服务连接
bash tests/verify-baota-services.sh

# DRY_RUN 验证部署流程（环境变量方式，不修改 deploy.env）
DEPLOY_DRY_RUN=1 bash scripts/deploy.sh all --yes

# 实际 preflight 检查 Redis/PG 连接
bash scripts/deploy.sh financial-web --yes
```

> `redis-cli` 和 `pg_isready` 通过符号链接 `/usr/local/bin/` 暴露到 PATH。
> `DEPLOY_DRY_RUN=1` 环境变量会覆盖 `deploy.env` 中的 `DEPLOY_DRY_RUN=0`，无需临时修改配置文件。

## 发版流程（三步）

### Step 1: 本地构建打包

```powershell
cd D:\Workspace\deploy

# 单项目
.\scripts\build.ps1 financial-web
.\scripts\build.ps1 financial-api

# 多项目 / 全量
.\scripts\build.ps1 financial-web,official-site
.\scripts\build.ps1 all
```

### Step 2: 上传到服务器（SSH/SCP）

所有上传统一走 SSH（`scp`），无需安装额外工具。

```powershell
# 上传单个包
scp D:\Workspace\deploy\dist\packages\financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/

# 上传所有新构建的包
scp D:\Workspace\deploy\dist\packages\*.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/

# 上传完整 dist 目录（首次部署或脚本更新时）
scp -r D:\Workspace\deploy\dist root@服务器IP:/www/wwwroot/project/uploads/
```

> 也可在 WSL Ubuntu 中执行 scp，路径改为 `/mnt/d/Workspace/deploy/dist/`。
> SSH 密钥建议配置免密登录：`ssh-copy-id root@服务器IP`。

### Step 3: 服务器部署（SSH）

通过 SSH 登录服务器后执行部署：

```bash
# 通过 SSH 直接执行单项目部署
ssh root@服务器IP "cd /www/wwwroot/project/uploads/dist && bash deploy.sh financial-web"

# 或先登录再操作
ssh root@服务器IP
cd /www/wwwroot/project/uploads/dist

# 指定目标环境（加载对应的 deploy.env.server-a / server-b）
bash deploy.sh financial-web --target=server-a
bash deploy.sh all --yes --target=server-a --ip=47.86.32.234
bash deploy.sh all --yes --target=server-b

# 不指定 target 时默认加载 deploy.env（本地/虚拟机）
bash deploy.sh financial-web
bash deploy.sh financial-api --ip=47.86.32.234

# 全量部署
bash deploy.sh all --ip=47.86.32.234

# 不重启服务（只更新代码）
bash deploy.sh financial-api --no-restart

# 查看服务状态 / 日志
bash deploy.sh --status
bash deploy.sh --logs financial-api
bash deploy.sh --logs financial-api --lines=100
```

## 回滚

每次部署前自动备份到 `/www/wwwroot/project/backup/<项目>/`，保留最近 5 个版本。

```bash
# 列出可用备份
bash deploy.sh financial-web --list

# 单项目回滚（交互选版本）
bash deploy.sh financial-web --rollback

# 多项目，各取最新备份
bash deploy.sh financial-web,official-site --rollback=latest

# 全量回滚
bash deploy.sh all --rollback

# 指定时间戳
bash deploy.sh financial-web --rollback=20260728-103000

# 自动化（跳过确认，危险）
bash deploy.sh all --rollback=latest --yes
```

### 备份位置

| 项目 | 备份路径 | 备份内容 |
|------|----------|----------|
| financial-web | `/www/wwwroot/project/backup/financial-web/` | dist/ 目录整体 |
| financial-api | `/www/wwwroot/project/backup/financial-api/` | package/ 代码（排除 .env/.venv） |
| official-site | `/www/wwwroot/project/backup/official-site/` | dist/ 目录整体 |
| deepquant-web | `/www/wwwroot/project/backup/deepquant-web/` | dist/ 目录整体 |
| deepquant-backend | `/www/wwwroot/project/backup/deepquant-backend/` | package/ 代码（排除 .env/.venv） |
