# 多项目宝塔部署指南

> 从零：**清理 Docker** → 装宝塔 → 配置驱动构建/部署（`project-configs/`）→ systemd + Nginx。  
> 本地 Windows 构建，服务器 Ubuntu/宝塔运行。**密码只放 `deploy.env`，禁止写进脚本或本文。**

## 文档导航

| 你想… | 看哪份文档 |
|--------|----------|
| 了解有哪些站、怎么路由 | [项目概览](#项目概览) |
| 加项目 / 换工作区根 | [仓库结构与项目配置](#仓库结构与项目配置ssot) |
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
| `financial-api` | `financial/financial-api` | `financial/financial-api/package` | 5001 | FastAPI / Python (systemd) |
| `financial-admin` | `financial/financial-admin` | `financial/financial-admin/dist` | — | Vue 3 静态 |
| `official-site` | `official-site` | `official-site/dist` | — | Vue 3 静态 |
| `deepquant-web` | `deepquant/deepquant_vue` | `deepquant/web/dist` | — | Vue 2 静态 |
| `deepquant-backend` | `deepquant/deepquant/backend_api_python` | `deepquant/backend/package` | 5000 | Flask / Python (systemd) |

> 服务器绝对路径 = `PROJECT_BASE`（默认 `/www/wwwroot/project`）+ `deployPath`。  
> 清单 SSOT：`project-configs/*.toml`（由 `config_loader.py` 运行时直接读取，无需中间文件）。

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

## 仓库结构与项目配置（SSOT）

> 构建 / 部署以 `project-configs/*.toml`（人改，由 `config_loader.py` 运行时直接读取）为准，**不要**再往 `build.ps1` / `deploy.sh` 里写死项目路径。

### 架构设计

```
project-configs/*.toml (SSOT, 人编辑)
    ↓ config_loader.py (运行时直接读取)
    ↓                     ↓
pack.ps1 (打包)        deploy.sh (部署)
```

- **一个配置源**：`project-configs/<name>/project.toml` 是唯一 SSOT
- **一个打包器**：`pack.ps1` 通过 `config_loader.py` 读 TOML，所有项目共用
- **一个读取器**：`config_loader.py` 运行时直接读 TOML，无需中间文件（替代原 sync-manifest.py + projects.json）
- **新增项目**：只需在 `project-configs/` 下新建一个 `project.toml`，无需改任何脚本

### 支持的组件类型

| `kind` | 技术栈 | 打包流程 | 示例 |
|--------|--------|----------|------|
| `frontend` | Vue / React / Angular / Svelte | `pnpm/npm/yarn build` → 打包 `dist/` 或 `build/` 为 tar.gz | `financial-web`, `official-site` |
| `python` | Python (FastAPI / Flask) | 源码 robocopy（排除 venv/tests） + includes → tar.gz | `financial-api`, `deepquant-backend` |
| `java` | Java (Spring Boot / Maven / Gradle) | `mvn/gradle build` → 打包 JAR/WAR + configs → tar.gz | `fullstack-demo` |
| `go` | Go (Gin / Echo / Fiber) | `go build` → 打包二进制 + configs → tar.gz | `fullstack-demo` |
| `nodejs` | Node.js (Express / NestJS / Next.js SSR) | 可选 `npm run build` (TS→JS) → 源码复制 + configs → tar.gz | `fullstack-demo` |

> - 前端支持 `pnpm` / `npm` / `yarn`，通过 `[components.build].package_manager` 配置。
> - Go 支持交叉编译：在 `build_command` 中设 `GOOS=linux GOARCH=amd64`。
> - Node.js 后端发源码包，服务器端执行 `npm ci --production` 安装生产依赖。
> - PHP (Laravel) 可用 `python` kind + 自定义 `extra_exclude_dirs` 实现（需手动处理 PHP 依赖）。

### 文件结构

```
deploy/
├── project-configs/               # SSOT: 项目打包配置（人编辑源）
│   ├── _shared.toml                #   共享默认值（排除列表、服务器定义）
│   ├── financial/project.toml      #   金融项目（web + admin + api）
│   ├── deepquant/project.toml      #   QuantDinger（web + backend + mcp）
│   ├── official-site/project.toml  #   卓筹介绍站（frontend only）
│   └── fullstack-demo/project.toml #  全栈示例（React + Java + Go + Node.js）
├── scripts/
│   ├── pack.ps1                    # 统一打包脚本（所有项目共用）
│   ├── build.ps1                   # 构建编排入口（pack → copy assets）
│   ├── deploy.sh                   # 服务器端部署/回滚（主入口，加载 lib/ 模块）
│   ├── deploy-financial-api.sh     # 项目级部署钩子
│   ├── lib/                        # 共享库（Bash + PowerShell）
│   │   ├── common.sh               #   颜色/日志/CRLF/新鲜度检查
│   │   ├── preflight.sh            #   部署前检查
│   │   ├── service-ops.sh          #   服务重启/健康检查/状态/日志
│   │   ├── backup-rollback.sh      #   备份与回滚
│   │   ├── nginx.sh                #   Nginx 配置生成与部署
│   │   ├── deploy-kinds.sh         #   各类型部署（frontend/python/java/go/nodejs）
│   │   ├── load-deploy-env.sh      #   deploy.env 加载器
│   │   ├── load-projects.{sh,ps1}  #   TOML 配置加载器（via config_loader.py）
│   │   ├── config_loader.py        #   TOML 配置直接读取器
│   │   └── _ps-common.ps1          #   PowerShell 共享常量
│   ├── ops/                        # 一次性运维脚本
│   │   ├── 01-cleanup-server.sh    #   服务器清理（Docker + 系统冲突）
│   │   ├── lib-clear-conflicts.sh  #   系统冲突清理子模块
│   │   ├── 02-install-baota.sh     #   宝塔安装
│   │   ├── 03-check-components.sh  #   宝塔组件检查
│   │   ├── 04-setup-server.sh      #   服务器环境准备
│   │   └── wsl-*.ps1               #   WSL 网络工具
│   └── tools/                      # 工具脚本
│       ├── detect-status.sh        #   部署进度检测
│       └── generate-nginx.py       #   Nginx 配置动态生成
├── configs/                        # 静态配置资产
│   ├── systemd/                    #   systemd unit 文件
│   ├── financial-api.env.example   #   环境变量模板
│   ├── deepquant.env.example
│   └── official-site.env
├── deploy.env.example              # 部署密钥模板（本地/虚拟机）
├── deploy.env.server-a             # 服务器 A 配置（.gitignore）
├── deploy.env.server-b             # 服务器 B 配置（.gitignore）
├── dist/                           # 构建产出（.gitignore，上传到服务器）
├── docs/                           # 详细指南 / 排障档案
└── tests/                          # WSL 冒烟 / 沙箱测试
```

### 登记新项目

1. 在工作区放好源码
2. 在 `project-configs/` 下新建 `<项目名>/project.toml`（可复制现有项目修改）
3. 运行 `.\scripts\build.ps1 <项目名>` — 自动打包
4. 上传 → 服务器 `bash deploy.sh`

### 项目配置文件格式（project.toml）

每个 `project.toml` 包含：

| 配置区 | 说明 |
|--------|------|
| `[project]` | 项目 ID、显示名、关键文件（随包上传的 systemd 等资产） |
| `[servers.*]` | 多服务器定义（可覆盖 `_shared.toml` 中的默认值） |
| `[deploy]` | 部署行为（备份保留数、健康检查超时） |
| `[[components]]` | 组件列表（`frontend` / `python` / `java` / `go` / `nodejs`），每个组件含源码路径、构建配置、打包配置 |
| `[components.build]` | 前端/Java/Go/Node.js 构建配置：包管理器、构建命令、输出目录、JAR/二进制模式等 |
| `[components.pack]` | Python/Node.js 打包配置：排除列表、包含文件、include_env（安全 .env 白名单） |

### 安全设计

- **.env 默认全排除**：`_shared.toml` 的 `python_defaults` / `java_defaults` / `go_defaults` / `nodejs_defaults` 的 `exclude_files` 包含所有 `.env*` 变体
- **显式白名单**：仅 `include_env` 列出的文件才被复制为 `.env` 进包（python 在 `[components.pack]`，java/go 在 `[components.build]`）
- **凭证隔离**：`.env.remoteA` / `.env.remoteB` / `.env.bak.*` 始终排除，不可通过 `include_env` 覆盖

### 解析优先级

```
WORKSPACE_ROOT env  >  TOML workspaceRoot  >  deploy 父目录
PROJECT_BASE env    >  TOML projectBase    >  /www/wwwroot/project
```

---

## 密钥与连接（deploy.env）

密码**不写在 README**。统一写在 `deploy.env`（由 `deploy.env.example` 复制）。

### 三套环境配置

| 配置文件 | 用途 | Nginx 模式 | 域名 |
|----------|------|-----------|------|
| `deploy.env.example` | 本地/虚拟机（模板） | http（IP 部署） | 无 |
| `deploy.env.server-a` | 服务器 A (47.86.32.234) | ssl-redirect（裸域→www） | `DOMAIN` + `WWW_DOMAIN` |
| `deploy.env.server-b` | 服务器 B (103.100.211.12) | ssl-combined（域名合并） | `DOMAIN` + `WWW_DOMAIN` |

使用方法：

```bash
# 本地/虚拟机（首次使用）
cp deploy.env.example deploy.env

# 服务器 A/B 配置已创建（.gitignore），无需 cp
# 如需重建：参考 deploy.env.example 模板，填入对应服务器的域名和密码
```

服务器端部署时指定环境：

```bash
# 方式一：--target 参数
bash deploy.sh all --yes --target=server-a --ip=47.86.32.234
bash deploy.sh all --yes --target=server-b

# 方式二：环境变量
DEPLOY_TARGET=server-a bash deploy.sh all --yes
DEPLOY_TARGET=server-b bash deploy.sh all --yes

# 方式三：直接指定文件路径
DEPLOY_ENV_FILE=/path/to/custom.env bash deploy.sh all --yes
```

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

### .env 生成机制

`configs/*.env` 真实文件**不需要本地存在**。部署时 `deploy.sh` 会：

1. **首次部署**：从 `configs/*.env.example` 模板自动生成 `.env`，替换 `__PG_PASSWORD__` / `__REDIS_PASSWORD__` / `__SECRET_KEY__` 等占位符
2. **增量部署**：备份现有 `.env` → 解压代码 → 恢复 `.env`（保留服务器端配置）

如需通过打包传递 `.env`（而非服务器端生成），在 `configs/` 下创建真实 `.env` 文件（已 gitignore），`include_env` 白名单会将其打入包中。

### MCP Agent Token 配置

MCP Server 需要有效的 `AGENT_TOKEN` 才能通过认证。配置流程：

1. 部署后端：`bash deploy.sh deepquant-backend --yes`（MCP 服务自动安装，token 为占位符）
2. 在后端 Agent Gateway 创建 token（通过 Admin 面板或 API）
3. 在 `deploy.env.server-a` / `deploy.env.server-b` 中设置 `MCP_AGENT_TOKEN=<真实 token>`
4. 重新部署 MCP：`bash deploy.sh deepquant-mcp --yes`（仅更新 systemd 环境变量 + 重启）

---

## 快速开始

### 首次部署

详见 [完整部署步骤](docs/guide/deploy-from-scratch.md)。

### 增量发版

详见 [增量发版与回滚](docs/guide/incremental-release.md)。

### 测试验证

```bash
# WSL Ubuntu 中运行冒烟测试
wsl bash -c "cd /mnt/d/Workspace/deploy && bash tests/wsl-smoke.sh"

# WSL Ubuntu 中运行综合测试（46 项检查）
wsl bash -c "cd /mnt/d/Workspace/deploy && bash tests/run-wsl-tests.sh"

# PowerShell 中 DryRun 验证打包逻辑
.\scripts\pack.ps1 financial -DryRun
.\scripts\pack.ps1 deepquant,official-site -DryRun

# 服务器端 DRY_RUN 验证部署流程（环境变量方式，不修改 deploy.env）
DEPLOY_DRY_RUN=1 bash deploy.sh financial-web --yes
DEPLOY_DRY_RUN=1 bash deploy.sh all --yes

# 服务器端 preflight 实际检查 Redis/PG 连接（非 DRY_RUN）
bash deploy.sh financial-web --yes
```

> **WSL 宝塔环境测试**：WSL 中已安装宝塔 Redis（`/www/server/redis/`）和 PostgreSQL（`/www/server/pgsql/`），`deploy.env` 已配置对应的密码和端口。`redis-cli` 和 `pg_isready` 通过符号链接 `/usr/local/bin/` 暴露到 PATH。
>
> **DRY_RUN 环境变量**：`DEPLOY_DRY_RUN=1` 作为环境变量传入时会覆盖 `deploy.env` 中的 `DEPLOY_DRY_RUN=0`，无需临时修改配置文件。

```powershell
# 本地构建（自动 pack）
cd D:\Workspace\deploy
.\scripts\build.ps1 financial

# 或直接调用打包器
.\scripts\pack.ps1 financial

# DryRun 模式（不生成文件，仅验证流程）
.\scripts\pack.ps1 financial -DryRun
```

```bash
# 上传（SSH/SCP，统一走 SSH）
scp -r dist/ root@服务器IP:/www/wwwroot/project/uploads/
# 或仅上传包
scp dist/packages/*.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

```bash
# 服务器部署（SSH）
ssh root@服务器IP "cd /www/wwwroot/project/uploads/dist && bash deploy.sh financial-web"
# 或登录后操作
ssh root@服务器IP
cd /www/wwwroot/project/uploads/dist && bash deploy.sh financial-web
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

> 本项目已配置化，只需改对应环境的 `deploy.env` 然后重新部署即可。

1. **deploy.env**：修改对应环境的配置文件（`deploy.env.server-a` / `deploy.env.server-b`）：设置 `DOMAIN` / `WWW_DOMAIN` / `FRONTEND_URL` / `APP_NAME`
2. **DNS**：在域名商处将裸域和 www 的 A 记录指向服务器 IP
3. **SSL 证书**：按 [Phase 7b](docs/guide/deploy-from-scratch.md#phase-7b-ssl-证书--宝塔邮局申请域名部署) 流程申请
4. **Nginx**：执行 `bash deploy.sh --nginx --target=server-a`（或 `server-b`）
5. **financial-api**：`bash deploy.sh financial-api --target=server-a`
6. **QuantDinger**：`bash deploy.sh deepquant-backend --target=server-a`
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
