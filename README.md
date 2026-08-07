# 多项目宝塔部署指南

> 从零：**清理 Docker** → 装宝塔 → 配置驱动构建/部署（`projects.yaml`）→ systemd + Nginx。  
> 本地 Windows 构建，服务器 Ubuntu/宝塔运行。**密码只放 `deploy.env`，禁止写进脚本或本文。**

## 文档导航

| 你想… | 看哪份文档 |
|--------|----------|
| 了解有哪些站、怎么路由 | [项目概览](#项目概览) |
| 加项目 / 换工作区根 | [仓库结构与项目清单](#仓库结构与项目清单ssot) |
| 配密码、连库 | [密钥与连接](#密钥与连接deployenv) |
| **第一次**装服务器 | [完整部署步骤](docs/guide/deploy-from-scratch.md) |
| **以后**发版 / 回滚 | [增量发版与回滚](docs/guide/incremental-release.md) |
| **脚本故障 / 手动操作** | [手动部署](docs/guide/manual-deploy.md) |
| 查日志、重启、备份 | [日常运维](docs/guide/daily-ops.md) |
| 本机连远程库开发 | [远程开发](docs/guide/remote-dev.md) |
| 报错对照 | [常见问题](#常见问题) · [docs 排障档案](docs/README.md) |

---

## 项目概览

| 项目 ID | 本地路径 (`sourcePath`) | 服务器路径 (`deployPath`) | 端口 | 类型 |
|---------|-------------------------|---------------------------|------|------|
| `financial-web` | `financial/financial-web` | `financial/financial-web/dist` | — | Vue 3 静态 |
| `financial-api` | `financial/financial-api` | `financial/financial-api/package` | 5001 | FastAPI (systemd) |
| `financial-admin` | `financial/financial-admin` | `financial/financial-admin/dist` | — | Vue 3 静态 |
| `official-site` | `official-site` | `official-site/dist` | — | Vue 3 静态 |
| `deepquant-web` | `deepquant/deepquant_vue` | `deepquant/web/dist` | — | Vue 2 静态 |
| `deepquant-backend` | `deepquant/deepquant/backend_api_python` | `deepquant/backend/package` | 5000 | Flask (systemd) |

> 服务器绝对路径 = `PROJECT_BASE`（默认 `/www/wwwroot/project`）+ `deployPath`。  
> 清单 SSOT：`projects.yaml` → `python3 scripts/sync-projects.py` → `projects.json`。

## URL 路由

| URL 路径 | 项目 | Nginx location | 目标 |
|----------|------|----------------|------|
| `/` | financial-web | `location /` | 静态文件 (SPA fallback) |
| `/admin/` | financial-admin | `location ^~ /admin/` | 静态文件 (SPA fallback) |
| `/qd/` | official-site | `location ^~ /qd/` | 静态文件 (SPA fallback) |
| `/api/ws` | financial-api WS | `location ^~ /api/ws` | `127.0.0.1:5001/api/ws` |
| `/api/` | financial-api | `location ^~ /api/` | `127.0.0.1:5001/api/` |
| `/quant/api/` | QuantDinger API | `location ^~ /quant/api/` | `127.0.0.1:5000/api/` |
| `/quant/` | QuantDinger 前端 | `location ^~ /quant/` | 静态文件 (SPA fallback) |

## 数据库与 Redis

| 服务 | 数据库 | Redis |
|------|--------|-------|
| financial-api | `quant_zc` | 共享实例，key 前缀 `fin_*` |
| QuantDinger | `quantdinger` | 共享实例，自身前缀 |

> 两后端共用宝塔 PostgreSQL / Redis，用不同库隔离。密码只写在 `deploy.env`。

---

## 仓库结构与项目清单（SSOT）

> 构建 / 部署以 `projects.yaml`（人改）+ `projects.json`（机器读）为准，**不要**再往 `build.ps1` / `deploy.sh` 里写死项目路径。

### 文件结构

```
deploy/
├── projects.yaml        # 人类编辑源（可读性好）
├── projects.json         # 机器读取源（build.ps1 / deploy.sh 加载）
└── scripts/
    ├── sync-projects.py  # yaml → json 同步脚本（需 Python3，WSL 或服务器）
    ├── lib/
    │   ├── load-projects.ps1   # PowerShell 加载器
    │   └── load-projects.sh    # Bash 加载器
    ├── pack-generic.ps1        # 通用后端打包器（参数化，不写死路径）
    ├── generate-nginx.py       # Nginx 配置动态生成器
    └── build.ps1               # Windows 本地构建入口
```

### 登记新项目

1. 在工作区放好源码
2. 编辑 `projects.yaml` 增加一条 `id` + `sourcePath` + `deployPath` + build/deploy 字段
3. 同步：`python3 scripts/sync-projects.py`（WSL）或手动编辑 `projects.json`
4. 前端：确保有 `pnpm build`；后端：按需补 `deployHook` / systemd
5. `.\scripts\build.ps1 {id}` → 上传 → `bash deploy.sh {id}`

### 仓库文件树

```
deploy/
├── README.md                         # 本文档（主入口，精简版）
├── docs/                             # 详细指南 / 排障档案（见 docs/README.md）
│   └── guide/                        # 拆分后的详细操作指南
│       ├── deploy-from-scratch.md    # 完整部署步骤（Phase 0-7b）
│       ├── incremental-release.md    # 增量发版与回滚
│       ├── manual-deploy.md          # 手动部署（脚本故障 / 单步操作）
│       ├── daily-ops.md              # 日常运维
│       └── remote-dev.md             # 远程开发
├── projects.yaml                     # 项目清单 SSOT（人类编辑源）
├── projects.json                     # 项目清单 SSOT（机器读取源）
├── scripts/                          # 所有执行脚本
│   ├── 00-cleanup-docker.sh          # Phase0：Docker 清理
│   ├── 01-install-baota.sh           # Phase1：安装宝塔面板
│   ├── 02-baota-exclusive.sh         # 冲突清理实现
│   ├── 03-server-setup.sh            # Phase3：创建数据库、目录
│   ├── detect-status.sh              # 探测各阶段是否已完成
│   ├── build.ps1                     # Windows 本地构建
│   ├── pack-generic.ps1              # 通用后端打包器
│   ├── deploy.sh                     # 服务器：部署 + 回滚
│   ├── generate-nginx.py             # Nginx 配置动态生成
│   ├── sync-projects.py              # yaml → json 同步
│   └── lib/                          # 共享库
├── configs/                          # systemd / env 模板
│   └── systemd/                      # systemd unit 文件
├── tests/                            # WSL 冒烟 / 沙箱
└── dist/                             # 构建产出（.gitignore，上传到服务器）
```

> 各项目内不再维护 deploy/ 目录和 Docker 配置，所有部署相关文件集中在此目录。

---

## 密钥与连接（deploy.env）

密码**不写在 README**。统一写在 `deploy.env`（由 `deploy.env.example` 复制）。

### PostgreSQL

| 项目 | 值 |
|------|-----|
| 主机 | `localhost`（服务器内，勿对公网开放 5432） |
| 端口 | `5432`（或 `PG_PORT`） |
| 用户名 | `PG_USER`（默认 `root`） |
| 密码 | `PG_PASSWORD`（见 `deploy.env`） |

| 数据库 | 用途 |
|--------|------|
| `quant_zc` | financial-api（行情/社区） |
| `quantdinger` | QuantDinger（交易系统） |

### Redis

| 项目 | 值 |
|------|-----|
| 主机 | `localhost`（勿对公网开放 6379） |
| 端口 | `6379` |
| 密码 | `REDIS_PASSWORD`（见 `deploy.env`） |

### 解析优先级

```
WORKSPACE_ROOT env  >  projects.json workspaceRoot  >  deploy 父目录
PROJECT_BASE env    >  projects.json projectBase    >  /www/wwwroot/project
```

---

## 快速开始

### 首次部署

详见 [完整部署步骤](docs/guide/deploy-from-scratch.md)。

### 增量发版

详见 [增量发版与回滚](docs/guide/incremental-release.md)。

```powershell
# 本地构建
cd D:\Workspace\deploy
.\scripts\build.ps1 financial-web

# 上传
scp dist\packages\financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

```bash
# 服务器部署
cd /www/wwwroot/project/uploads/dist
bash deploy.sh financial-web
```

### 日常运维

详见 [日常运维](docs/guide/daily-ops.md)。

---

## 常见问题

### Q: Nginx 报 502 Bad Gateway

```bash
systemctl status financial-api
systemctl status quantdinger-backend
ss -tlnp | grep -E '5000|5001'
journalctl -u financial-api -n 50 --no-pager
```

### Q: WebSocket 连接失败

确保 Nginx 的 `/api/ws` location 在 `/api/` 之前（最长前缀匹配）：

```nginx
location ^~ /api/ws { ... }  # 必须在前
location ^~ /api/ { ... }   # 在后
```

### Q: 更换域名时需要做什么

> 本项目已配置化，只需改 `deploy.env` 然后重新部署即可。

1. **deploy.env**：设置 `DOMAIN` / `WWW_DOMAIN` / `FRONTEND_URL` / `APP_NAME`
2. **DNS**：在域名商处将裸域和 www 的 A 记录指向服务器 IP
3. **SSL 证书**：按 [Phase 7b](docs/guide/deploy-from-scratch.md#phase-7b-ssl-证书--宝塔邮局申请域名部署) 流程申请
4. **Nginx**：设 `NGINX_CONF_NAME=nginx-servera-ssl.conf`，执行 `bash deploy.sh --nginx`
5. **financial-api**：`bash deploy.sh financial-api`
6. **QuantDinger**：`bash deploy.sh deepquant-backend`
7. **邮局**：按 [Phase 7b 步骤 3](docs/guide/deploy-from-scratch.md#3-配置宝塔邮局) 配置
8. **重启**：`systemctl restart financial-api quantdinger-backend` + `nginx -s reload`

---

## 排障与问题记录

日常 FAQ 见上文。历史排障与 WSL 本地部署问题已迁到 `docs/`：

| 文档 | 内容 |
|------|------|
| [docs/deploy-troubleshooting-history.md](docs/deploy-troubleshooting-history.md) | 服务器 A/B 历史排障 |
| [docs/wsl-local-deploy-issues.md](docs/wsl-local-deploy-issues.md) | WSL Ubuntu 本地宝塔部署问题 |
| [docs/baota-linux-panel.openapi.yaml](docs/baota-linux-panel.openapi.yaml) | 宝塔面板 API（Apifox 可导入） |
| [docs/README.md](docs/README.md) | docs 索引 |
