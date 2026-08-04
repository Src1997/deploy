# 增量发版与回滚

> **Category**: Guide

首次部署使用 `build.ps1 all` + `deploy.sh all` 全量构建和部署。
后续单项目更新使用 `build.ps1 <项目>` + `deploy.sh <项目>` 增量发版。

## 支持的项目

| 项目名 | 说明 | 构建方式 | 重启服务 |
|--------|------|----------|----------|
| `financial-web` | 行情/社区前端 | pnpm build | nginx reload |
| `financial-api` | FastAPI 后端 | `pack-generic.ps1` | financial-api + crawler + worker + streaming |
| `official-site` | 卓筹介绍站 | pnpm build | nginx reload |
| `deepquant-web` | QuantDinger 前端 | pnpm build | nginx reload |
| `deepquant-backend` | QuantDinger 后端 | `pack-generic` / source-tar | quantdinger-backend |

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

### Step 2: 上传到服务器

```powershell
# 上传单个包
scp D:\Workspace\deploy\dist\packages\financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/

# 或上传所有新构建的包
scp D:\Workspace\deploy\dist\packages\*.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

### Step 3: 服务器部署

```bash
cd /www/wwwroot/project/uploads/dist

# 单项目部署
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
