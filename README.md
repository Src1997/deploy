# 多项目宝塔部署指南

> 从零：**清理 Docker** → 装宝塔 → 配置驱动构建/部署（`projects.yaml`）→ systemd + Nginx。  
> 本地 Windows 构建，服务器 Ubuntu/宝塔运行。**密码只放 `deploy.env`，禁止写进脚本或本文。**

## 文档怎么读

| 你想… | 看哪一节 |
|--------|----------|
| 了解有哪些站、怎么路由 | [项目概览](#项目概览) |
| 加项目 / 换工作区根 | [仓库结构与项目清单](#仓库结构与项目清单ssot) |
| 配密码、连库 | [密钥与连接](#密钥与连接deployenv) |
| **第一次**装服务器 | [完整部署步骤](#完整部署步骤从零开始) |
| **以后**发版 / 回滚 | [增量发版](#增量发版首次全量部署后) · [回滚](#回滚) |
| 查日志、重启、备份 | [日常运维](#日常运维) |
| 本机连远程库开发 | [远程开发](#远程开发) |
| 报错对照 | [常见问题](#常见问题) · [附录排障记录](#附录部署排障记录历史) |

---

## 项目概览

| 项目 ID | 本地路径 (`sourcePath`) | 服务器路径 (`deployPath`) | 端口 | 类型 |
|---------|-------------------------|---------------------------|------|------|
| `financial-web` | `financial/financial-web` | `financial/financial-web/dist` | — | Vue 3 静态 |
| `financial-api` | `financial/financial-api` | `financial/financial-api/package` | 5001 | FastAPI (systemd) |
| `official-site` | `official-site` | `official-site/dist` | — | Vue 3 静态 |
| `deepquant-web` | `deepquant/deepquant_vue` | `deepquant/web/dist` | — | Vue 2 静态 |
| `deepquant-backend` | `deepquant/deepquant/backend_api_python` | `deepquant/backend/package` | 5000 | Flask (systemd) |

> 服务器绝对路径 = `PROJECT_BASE`（默认 `/www/wwwroot/project`）+ `deployPath`。  
> 清单 SSOT：`projects.yaml` → `python3 scripts/sync-projects.py` → `projects.json`。

## URL 路由

| URL 路径 | 项目 | Nginx location | 目标 |
|----------|------|----------------|------|
| `/` | financial-web | `location /` | 静态文件 (SPA fallback) |
| `/qd/` | official-site | `location ^~ /qd/` | 静态文件 (SPA fallback) |
| `/api/ws` | financial-api WS | `location ^~ /api/ws` | `127.0.0.1:5001/api/ws` |
| `/api/` | financial-api | `location ^~ /api/` | `127.0.0.1:5001/api/` |
| `/quant/api/` | QuantDinger API | `location ^~ /quant/api/` | `127.0.0.1:5000/api/` |
| `/quant/` | QuantDinger 前端 | `location ^~ /quant/` | 静态文件 (SPA fallback) |

## 跨站跳转关系

```
financial-web (/)  ──┬──→  official-site (/qd/)     [页脚链接 / 首页推广位]
                     └──→  QuantDinger 前端 (/quant/) [菜单跳转 / SSO]

official-site (/qd/) ────→  QuantDinger 前端 (/quant/) [启动应用按钮]
```

- financial-web → official-site: DB 配置 `links.deepquant.siteUrl` = `/qd`
- financial-web → QuantDinger: DB 配置 `links.deepquant.appBaseUrl` = `/quant`
- official-site → QuantDinger: 构建时 `VITE_APP_URL` 环境变量

## 数据库与 Redis

| 服务 | 数据库 | Redis |
|------|--------|-------|
| financial-api | `quant_zc`（用户见 `deploy.env`） | 共享实例，key 前缀 `fin_*` |
| QuantDinger | `quantdinger` | 共享实例，自身前缀 |

> 两后端共用宝塔 PostgreSQL / Redis，用不同库隔离。密码只写在 `deploy.env`，详见下文「密钥与连接」。

## 仓库结构与项目清单（SSOT）

> 构建 / 部署以 `projects.yaml`（人改）+ `projects.json`（机器读）为准，**不要**再往 `build.ps1` / `deploy.sh` 里写死项目路径。

> 项目清单是 `projects.yaml`（人类编辑源）+ `projects.json`（机器读取源），所有构建/部署脚本从清单读取项目路径、产物名、服务名等。

### 文件结构

```
deploy/
├── projects.yaml        # 人类编辑源（可读性好）
├── projects.json         # 机器读取源（build.ps1 / deploy.sh 加载）
└── scripts/
    ├── sync-projects.py  # yaml → json 同步脚本（需 Python3，WSL 或服务器）
    ├── lib/
    │   ├── load-projects.ps1   # PowerShell 加载器
    │   ├── load-projects.sh    # Bash 加载器
    │   ├── _probe-projects.ps1 # 验证脚本
    │   └── _probe-projects.sh  # 验证脚本（WSL）
    └── pack-generic.ps1        # 通用后端打包器（参数化，不写死路径）
```

### 登记新项目

1. 在工作区放好源码
2. 编辑 `projects.yaml` 增加一条 `id` + `sourcePath` + `deployPath` + build/deploy 字段
3. 同步：`python3 scripts/sync-projects.py`（WSL）或手动编辑 `projects.json`
4. 前端：确保有 `pnpm build`；后端：按需补 `deployHook` / systemd
5. `.\scripts\build.ps1 {id}` → 上传 → `bash deploy.sh {id}`

### 换工作区根目录

```bash
# 方式一：环境变量（临时）
export WORKSPACE_ROOT=/path/to/new/workspace
.\scripts\build.ps1 discover   # 验证路径是否正确

# 方式二：deploy.env
WORKSPACE_ROOT=/path/to/new/workspace
```

### 扫描未登记项目

```powershell
.\scripts\build.ps1 discover
# 报告工作区存在但未登记到 projects.json 的项目目录
```

### 解析优先级

```
WORKSPACE_ROOT env  >  projects.json workspaceRoot  >  deploy 父目录
PROJECT_BASE env    >  projects.json projectBase    >  /www/wwwroot/project
```

---

### 仓库文件树

```
deploy/
├── README.md                         # 本文档
├── projects.yaml                    # 项目清单 SSOT（人类编辑源）
├── projects.json                    # 项目清单 SSOT（机器读取源）
├── scripts/                          # 所有执行脚本
│   ├── 00-cleanup-docker.sh          # Phase0：Docker 清理 + 系统冲突
│   ├── 01b-baota-exclusive.sh        # 冲突清理实现
│   ├── detect-status.sh              # 探测各阶段是否已完成
│   ├── 01-install-baota.sh           # 服务器 SSH：安装宝塔面板
│   ├── 02-server-setup.sh            # 服务器 SSH：创建数据库、目录结构
│   ├── build.ps1                     # Windows 本地：从 projects.json 加载 + 构建
│   ├── pack-generic.ps1              # 通用后端打包器（参数化，读清单）
│   ├── pack-financial-api.ps1        # financial-api 打包（薄封装 → pack-generic）
│   ├── pack-financial-api.sh          # Linux/macOS：financial-api 打包
│   ├── deploy-financial-api.sh        # 服务器：financial-api 一键部署
│   ├── sync-projects.py              # yaml → json 同步脚本（需 Python3）
│   ├── deploy.sh                     # 服务器：部署 + 回滚（从 projects.json 加载）
│   └── lib/                          # 共享库
│       ├── load-deploy-env.sh        # deploy.env 加载器
│       ├── load-projects.ps1         # PowerShell 项目清单加载器
│       ├── load-projects.sh          # Bash 项目清单加载器
│       ├── _probe-projects.ps1       # 验证脚本（PowerShell）
│       └── _probe-projects.sh        # 验证脚本（WSL）
├── configs/                          # 所有配置文件
│   ├── nginx-all-sites.conf          # Nginx 站点配置（无 SSL，IP 部署 / 服务器 A 旧）
│   ├── nginx-all-sites-ssl.conf      # Nginx 站点配置（SSL，服务器 B www.deepquant.club）
│   ├── nginx-servera-ssl.conf        # Nginx 站点配置（SSL，服务器 A www.zhuochouacedemy.com）
│   ├── deepquant.env.example         # QuantDinger 后端 .env 模板
│   ├── official-site.env             # official-site 构建环境变量
│   ├── quantdinger-backend.service   # QuantDinger systemd 服务文件
│   └── systemd/                      # financial-api systemd 服务文件
│       ├── financial-api.service
│       ├── financial-crawler.service
│       ├── financial-worker.service
│       └── financial-streaming.service
└── dist/                             # 构建产出（上传到服务器）
    ├── packages/                     # 构建产物（tar.gz）
    └── configs/                      # 服务器端配置文件
```

> 各项目内不再维护 deploy/ 目录和 Docker 配置，所有部署相关文件集中在此目录。

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

### 配置文件位置

| 文件 | 路径 / 说明 |
|------|-------------|
| 部署总配置 | `deploy/deploy.env`（本地）或 `/www/wwwroot/project/deploy.env`（服务器） |
| 模板 | `deploy.env.example`、`configs/financial-api.env.example`、`configs/deepquant.env.example` |
| financial-api 运行时 | `$PROJECT_BASE/financial/financial-api/package/.env`（首次由脚本渲染） |
| QuantDinger 运行时 | `$PROJECT_BASE/deepquant/backend/package/.env`（首次由脚本渲染） |

---

## 完整部署步骤（从零开始）

### 前提条件

- 服务器：Linux（Ubuntu 20+ / CentOS 7+ / Debian 10+），root 权限
- 服务器当前运行 Docker（将被卸载）
- 本地 Windows 已安装：Node.js 20+、pnpm 11+、Python 3.11+、uv
- 本地已安装 financial-web 依赖（`pnpm install`）
- 本地已安装 deepquant_vue 依赖（`pnpm install`）

### 执行顺序总览

```
【云安全组】先放行 22 / 80 / 443 / 面板端口（勿放 5432、6379）

Phase 0: 环境清理                 (00-cleanup-docker.sh)
         ├─ Docker 卸载（已卸则自动跳过）
         └─ 系统防火墙/系统库冲突清理（原 0b，已并入）
Phase 1: 安装宝塔面板             (01-install-baota.sh)     ← 已装则提示跳过
Phase 2: 宝塔面板安装基础组件      (手动) Nginx/PG/Redis/Python
         + 宝塔「安全」放行端口
         + 建议复查: 00 --conflicts-only --check
Phase 3: 创建数据库和目录          (02-server-setup.sh)
Phase 4: 本地构建打包             (build.ps1 all)
Phase 5: 上传到服务器             (scp dist + deploy.sh)
Phase 6: 服务器部署               (deploy.sh all)           ← 已部署会提示确认
Phase 7: 宝塔 Nginx 站点配置      (手动套用 nginx conf)
验证:    detect-status.sh + curl health
```

> **随时查看进度**：`bash detect-status.sh`（标 DONE / PARTIAL / TODO，并给出下一步）。
>
> **0b 已并入 0**：只需跑 `00-cleanup-docker.sh`；`01b-baota-exclusive.sh` 仍可单独复查。

> **为什么先清 Docker + 系统冲突？** Docker Nginx 占 80；系统 ufw/apt 版 PG/Redis 与宝塔抢端口或连错实例。**运行时栈一律只用宝塔**。

---

### Phase 0: 环境清理 — Docker + 系统冲突（SSH）

```bash
scp D:\Workspace\deploy\scripts\00-cleanup-docker.sh \
    D:\Workspace\deploy\scripts\01b-baota-exclusive.sh \
    D:\Workspace\deploy\scripts\detect-status.sh \
    root@服务器IP:/root/

# 全量（Docker 已卸会自动跳过该段；随后自动做冲突清理）
bash /root/00-cleanup-docker.sh

# 仅查状态
bash /root/detect-status.sh
bash /root/00-cleanup-docker.sh --check
```

| 子步骤 | 内容 | 已完成时 |
|--------|------|----------|
| Docker | 卸引擎、清容器/卷/镜像、旧服务/目录 | **自动跳过** |
| 冲突清理（原 0b） | 禁用 ufw/firewalld，purge 系统 nginx/pg/redis… | **无冲突则快速退出** |

兼容：`bash 01b-baota-exclusive.sh` ≡ `bash 00-cleanup-docker.sh --conflicts-only`

Docker 段会彻底完成（若本机已无 Docker 则整段跳过）：

| 步骤 | 清理内容 |
|------|----------|
| 1–6 | Compose / 容器 / 卷 / 网络 / 镜像 / 构建缓存 |
| 7 | 卸载 Docker 引擎 |
| 8–11 | 旧 systemd、SSL cron、旧目录、端口检查 |
| 12 | **系统冲突清理**（原 0b：ufw/firewalld + 系统 nginx/pg/redis…） |

> **⚠️** Docker 段会删除 Docker 内数据库数据；执行前按提示确认备份。

**冲突清理明细 / 端口策略：**

| 冲突源 | 处理 |
|--------|------|
| UFW / firewalld | disable → 宝塔「安全」 |
| 系统 nginx/apache/postgresql*/redis/mysql | stop + purge → 只用 `/www/server/...` |
| PATH | `/etc/profile.d/baota-path.sh` 宝塔 bin 优先 |

| 放行（宝塔安全 + 云安全组） | 禁止公网 |
|------------------------------|----------|
| 22、80、443、面板端口 | **5432、6379** |

---

### Phase 1: 安装宝塔面板（SSH）

```bash
# 上传安装脚本
scp D:\Workspace\deploy\scripts\01-install-baota.sh root@服务器IP:/root/

# 执行安装
bash /root/01-install-baota.sh
```

安装脚本会：
- 确认 Docker 已彻底卸载（否则拒绝执行）
- 检查端口 80 空闲
- 检测操作系统（Ubuntu/Debian/CentOS）
- 下载并执行宝塔官方安装脚本
- 输出面板地址、用户名、密码

安装完成后：
1. 浏览器访问面板地址，登录后绑定宝塔账号
2. 记下面板登录信息（如忘记可执行 `bt default` 查看）

> **云服务器注意**：在安全组中放行宝塔面板端口（默认 8888，安装后会告知实际端口）

---

### Phase 2: 宝塔面板安装基础组件（手动操作）

登录宝塔面板后，进入 **软件商店** 安装以下组件：

| 组件 | 版本 | 用途 |
|------|------|------|
| **Nginx** | 稳定版 | 反向代理 + 静态文件服务 |
| **PostgreSQL** | 16.x | 数据库（两个后端共享） |
| **Redis** | 7.x | 缓存（两个后端共享） |
| **Python 项目管理器** | — | 提供 Python 3.12（后端 venv 用） |

**设置数据库密码（与 `deploy.env` 保持一致）：**

```bash
# 1) 本地/仓库根目录先配好密码文件（禁止提交）
cp deploy.env.example deploy.env
# 编辑 deploy.env：填写 PG_PASSWORD / REDIS_PASSWORD

# 2) 宝塔 PostgreSQL
su - postgres -c "psql -c \"ALTER USER root WITH PASSWORD '你的PG密码';\""

# 3) 宝塔 Redis：面板改 requirepass，或 redis.conf 写入同一密码
```

> 所有部署脚本**只从 `deploy.env`（或 `DEPLOY_ENV_FILE`）读密码，脚本内不再内置默认口令。**
> 服务器建议放置：`/www/wwwroot/project/deploy.env`（权限 `600`）。

---

### Phase 3: 创建数据库和目录（SSH）

```bash
# 上传脚本
scp D:\Workspace\deploy\scripts\02-server-setup.sh root@服务器IP:/root/

# 执行
bash /root/02-server-setup.sh
```

准备脚本会：
- 检查宝塔安装的 Nginx、PostgreSQL、Redis、Python 3.11+（自动检测宝塔路径）
- 验证 Docker 已彻底卸载
- 创建数据库 `quant_zc`（financial-api）和 `quantdinger`（QuantDinger）
- 验证 Redis 连接
- 创建目录结构：
  ```
  /www/wwwroot/project/
  ├── financial/financial-api/
  ├── financial/financial-web/
  ├── official-site/
  ├── deepquant/backend/
  ├── deepquant/web/
  └── uploads/
  ```

---

### Phase 4: 本地构建打包（Windows PowerShell）

```powershell
cd D:\Workspace\deploy

# 构建（official-site 已使用相对路径，一次构建通用所有服务器）
.\scripts\build.ps1 all
```

构建脚本会产出以下文件到 `D:\Workspace\deploy\dist\`：

```
dist/
├── deploy.sh                    # 服务器端部署脚本（自包含）
├── detect-status.sh             # 状态探测脚本
├── packages/                    # 构建产物
│   ├── financial-web-dist.tar.gz
│   ├── official-site-dist.tar.gz
│   ├── deepquant-web-dist.tar.gz
│   ├── financial-api-*.tar.gz
│   └── deepquant-backend-package.tar.gz
└── configs/                     # 服务器端配置
    ├── nginx-all-sites.conf
    ├── nginx-all-sites-ssl.conf
    ├── quantdinger-backend.service
    ├── deepquant.env.example
    ├── official-site.env
    └── systemd/
        ├── financial-api.service
        ├── financial-crawler.service
        ├── financial-worker.service
        └── financial-streaming.service
```

---

### Phase 5: 上传到服务器

```powershell
# 方式一：scp 上传（推荐）
scp -r D:\Workspace\deploy\dist root@服务器IP:/www/wwwroot/project/uploads/

# 方式二：宝塔文件管理
# 将 dist/ 下所有文件上传到 /www/wwwroot/project/uploads/
```

---

### Phase 6: 服务器一键部署（SSH）

```bash
# SSH 到服务器
ssh root@服务器IP

# 进入上传目录
cd /www/wwwroot/project/uploads/dist

# 执行一键部署
bash deploy.sh all --ip=47.86.32.234

# 可选参数：
bash deploy.sh all --no-restart         # 部署但不重启服务
```

部署脚本会自动完成：
1. **financial-api**: 代码同步 → venv → .env → 依赖 → 迁移 → 种子 → systemd → 启动
2. **QuantDinger 后端**: 代码同步 → venv → .env → 依赖 → init.sql → systemd → 启动
3. **静态站点**: 解压 financial-web、official-site、deepquant_vue 到对应目录
4. **Nginx**: 配置并重载（可选自动或手动）

---

### Phase 7: 宝塔 Nginx 配置

**方式一：自动配置（推荐）**

在 Phase 6 部署时追加 `--nginx` 参数，自动拷贝 Nginx 配置并重载：

```bash
# 部署 + 自动配置 Nginx
bash deploy.sh all --ip=服务器IP --nginx

# 或单独配置 Nginx（不部署代码）
bash deploy.sh --nginx
```

> **SSL 域名部署**：在 `deploy.env` 中设置 `NGINX_CONF_NAME` 选择 SSL 配置：
> - 服务器 A：`NGINX_CONF_NAME=nginx-servera-ssl.conf`
> - 服务器 B：`NGINX_CONF_NAME=nginx-all-sites-ssl.conf`
> - IP 部署（无 SSL）：留空或 `NGINX_CONF_NAME=nginx-all-sites.conf`

**方式二：手动操作**

如果未使用 `--nginx`，手动操作：

1. 宝塔面板 → **网站** → 添加站点（域名填服务器 IP 或 `_`）
2. 站点设置 → **配置文件**
3. 全部内容替换为 `/www/wwwroot/project/uploads/dist/configs/nginx-all-sites.conf` 的内容
4. 保存

```bash
# 或命令行操作
cp /www/wwwroot/project/uploads/dist/configs/nginx-all-sites.conf /www/server/panel/vhost/nginx/default.conf
nginx -t && nginx -s reload
```

### Phase 7b: SSL 证书 + 宝塔邮局申请（域名部署）

> **前提**：`deploy.env` 已配置 `DOMAIN` / `WWW_DOMAIN` / `NGINX_CONF_NAME=nginx-servera-ssl.conf`，DNS A 记录已指向服务器。

#### 1. 申请 SSL 证书（acme.sh + Let's Encrypt）

```bash
# 1. 创建 ACME 验证目录
mkdir -p /www/wwwroot/project/acme/.well-known/acme-challenge

# 2. 临时加验证路径到当前 nginx（如果还没加）
# 在 default.conf 的 location / 之前插入：
#   location ^~ /.well-known/acme-challenge/ { root /www/wwwroot/project/acme; }

# 3. 安装 acme.sh
curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN}

# 4. 同时申请两个域名（一张证书）
~/.acme.sh/acme.sh --issue \
  -d ${WWW_DOMAIN} \
  -d ${DOMAIN} \
  --webroot /www/wwwroot/project/acme/ \
  --server letsencrypt

# 5. 安装证书到宝塔目录（自动续期 + reload）
mkdir -p /www/server/panel/vhost/cert/${WWW_DOMAIN}
~/.acme.sh/acme.sh --install-cert -d ${WWW_DOMAIN} --ecc \
  --key-file       /www/server/panel/vhost/cert/${WWW_DOMAIN}/privkey.pem \
  --fullchain-file /www/server/panel/vhost/cert/${WWW_DOMAIN}/fullchain.pem \
  --reloadcmd     'nginx -s reload'
```

#### 2. 套用 SSL Nginx 配置

```bash
# deploy.sh 自动渲染占位符（__DOMAIN__ / __WWW_DOMAIN__）
bash deploy.sh --nginx

# 或手动渲染 + 拷贝
sed -e "s|__WWW_DOMAIN__|${WWW_DOMAIN}|g" \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    configs/nginx-servera-ssl.conf > /www/server/panel/vhost/nginx/default.conf
nginx -t && nginx -s reload
```

#### 3. 配置宝塔邮局

> 两种方法任选其一。方法一（自建）无需额外费用，方法二（第三方）送达率更高。

##### 方法一：宝塔邮局自建（Postfix + Dovecot + Rspamd）

1. **安装邮局**：宝塔面板 → 软件商店 → 搜索「邮局」→ 安装

2. **添加域名**：邮局管理 → 添加域名 `${DOMAIN}`

3. **DNS 记录**（在域名商处添加）：

   | 类型 | 主机 | 值 | 说明 |
   |------|------|-----|------|
   | MX | @ | `${DOMAIN}` | 邮件路由 |
   | TXT | @ | `v=spf1 mx a ~all` | SPF 防伪造 |
   | TXT | `default._domainkey` | 见 DKIM 公钥 | 邮件签名验证 |
   | TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:admin@${DOMAIN}` | 邮件策略 |

4. **获取 DKIM 公钥**：

   ```bash
   cat /www/server/dkim/${DOMAIN}/default.pub
   # 输出格式：default._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=..." )
   # DNS TXT 记录值 = v=DKIM1; k=rsa; p=...（去掉引号和括号，拼成一行）
   ```

5. **创建邮箱账号**：邮局管理 → 添加邮箱 `noreply@${DOMAIN}`，设好密码

6. **deploy.env 配置**（SMTP_PASSWORD = 邮箱账号密码）：

   ```bash
   # deploy.env
   SMTP_PASSWORD=你的邮箱密码
   # financial-api.env.example 默认值无需改：
   # SMTP_HOST=127.0.0.1  SMTP_PORT=465  SMTP_USE_TLS=false
   ```

##### 方法二：第三方 SMTP 服务（QQ企业邮箱 / Gmail / 阿里云等）

> 适合需要高送达率、不愿自建邮局的场景。只需在第三方注册邮箱 + 获取授权码。

1. **注册邮箱**：在第三方服务商处注册企业邮箱（如 `noreply@${DOMAIN}` 在 QQ企业邮箱）

2. **deploy.env 配置**：

   ```bash
   # deploy.env — SMTP_PASSWORD = 第三方授权码（不是登录密码）
   SMTP_PASSWORD=你的授权码
   ```

3. **financial-api.env.example 修改**（按服务商对应改值）：

   | 服务商 | SMTP_HOST | SMTP_PORT | SMTP_USE_TLS | 说明 |
   |--------|-----------|-----------|--------------|------|
   | QQ企业邮箱 | `smtp.exmail.qq.com` | 465 | false | SMTP_SSL |
   | Gmail | `smtp.gmail.com` | 587 | true | STARTTLS |
   | 阿里云邮箱 | `smtp.qiye.aliyun.com` | 465 | false | SMTP_SSL |
   | 网易163企业 | `smtp.qiye.163.com` | 994 | false | SMTP_SSL |

   ```bash
   # 示例：QQ企业邮箱
   # 在 configs/financial-api.env.example 中改：
   SMTP_HOST=smtp.exmail.qq.com
   SMTP_PORT=465
   SMTP_USE_TLS=false
   SMTP_USERNAME=noreply@${DOMAIN}
   SMTP_FROM_ADDR=noreply@${DOMAIN}
   ```

4. **DNS 记录**（按服务商指引添加 SPF/DKIM，通常第三方会提供）：

   | 类型 | 主机 | 值 |
   |------|------|-----|
   | TXT | @ | `v=spf1 include:spf.mail.qq.com ~all`（QQ企业邮箱示例） |

#### 4. 部署 SMTP 配置 + 重启

```bash
# deploy.sh 自动渲染 __DOMAIN__ / __APP_NAME__ / __SMTP_PASSWORD__ 占位符
bash deploy.sh financial-api

# 或手动追加（方法一/二通用）
cat >> /www/wwwroot/project/financial/financial-api/package/.env << EOF
SMTP_ENABLED=true
SMTP_HOST=127.0.0.1           # 方法二改为第三方 smtp_host
SMTP_PORT=465                 # 方法二按服务商改
SMTP_USERNAME=noreply@${DOMAIN}
SMTP_PASSWORD=你的密码或授权码
SMTP_USE_TLS=false            # 方法二按服务商改
SMTP_FROM_ADDR=noreply@${DOMAIN}
SMTP_FROM_NAME=${APP_NAME}
EMAIL_SUBJECT_TEMPLATE=您的验证码 - ${APP_NAME}
EOF
systemctl restart financial-api
```

#### 5. 验证

```bash
# HTTPS 访问
curl -sI https://${WWW_DOMAIN}/                 # 200
curl -sI https://${WWW_DOMAIN}/api/health        # 200 + JSON
curl -sI https://${DOMAIN}/                      # 301 → www
curl -sI http://${WWW_DOMAIN}/                   # 301 → HTTPS

# 邮件发送
curl -s https://${WWW_DOMAIN}/api/auth/send-code?email=test@${DOMAIN}
```

---

## 验证

```bash
# 服务状态
systemctl status financial-api financial-crawler financial-worker financial-streaming quantdinger-backend

# 健康检查
curl http://127.0.0.1:5001/api/health    # financial-api
curl http://127.0.0.1:5000/api/health    # QuantDinger

# Nginx
nginx -t

# 浏览器访问
# http://服务器IP/          → financial-web
# http://服务器IP/qd/        → official-site
# http://服务器IP/quant/     → QuantDinger 前端
# http://服务器IP/api/health → financial-api 健康
```

---

## 增量发版（首次全量部署后）

首次部署使用 `build.ps1 all` + `deploy.sh all` 全量构建和部署。
后续单项目更新使用 `build.ps1 <项目>` + `deploy.sh <项目>` 增量发版，只构建和重启相关项目。

### 支持的项目

| 项目名 | 说明 | 构建方式 | 重启服务 |
|--------|------|----------|----------|
| `financial-web` | 行情/社区前端 | pnpm build | nginx reload |
| `financial-api` | FastAPI 后端 | `pack-generic.ps1` | financial-api + crawler + worker + streaming |
| `official-site` | 卓筹介绍站 | pnpm build | nginx reload |
| `deepquant-web` | QuantDinger 前端 | pnpm build | nginx reload |
| `deepquant-backend` | QuantDinger 后端 | `pack-generic` / source-tar | quantdinger-backend |

### 发版流程（三步）

#### Step 1: 本地构建打包

项目列表来自 `projects.json`（`enabled: true`），不是扫描工作区「猜」出来的。新增项目请改 `projects.yaml` 后执行 `python3 scripts/sync-projects.py`。

```powershell
cd D:\Workspace\deploy

# 单项目
.\scripts\build.ps1 financial-web
.\scripts\build.ps1 financial-api
.\scripts\build.ps1 official-site
.\scripts\build.ps1 deepquant-web
.\scripts\build.ps1 deepquant-backend

# 多项目 / 全量
.\scripts\build.ps1 financial-web,official-site
.\scripts\build.ps1 all

# 可选：扫描工作区，报告「存在但未登记」的目录
.\scripts\build.ps1 discover
```

产物：`dist/packages/<项目>-*.tar.gz`；部署资产会拷到 `dist/`（含 `projects.json`）。

#### Step 2: 上传到服务器

```powershell
# 上传单个包
scp D:\Workspace\deploy\dist\packages\financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/

# 或上传所有新构建的包
scp D:\Workspace\deploy\dist\packages\*.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

#### Step 3: 服务器部署

```bash
# SSH 到服务器
ssh root@服务器IP

# 进入上传目录
cd /www/wwwroot/project/uploads/dist

# 交互式菜单（首次启动会显示帮助）
bash deploy.sh

# 单项目部署
bash deploy.sh financial-web
bash deploy.sh financial-api --ip=47.86.32.234
bash deploy.sh official-site
bash deploy.sh deepquant-web
bash deploy.sh deepquant-backend --ip=47.86.32.234

# 全量部署
bash deploy.sh all --ip=47.86.32.234

# 不重启服务（只更新代码）
bash deploy.sh financial-api --no-restart

# 查看服务状态
bash deploy.sh --status

# 查看日志
bash deploy.sh --logs financial-api          # 最近 50 行
bash deploy.sh --logs financial-api --lines=100
bash deploy.sh --logs financial-api --logs=error

# 查看帮助
bash deploy.sh --help
```

### 常见增量发版场景

#### 只更新 financial-web 前端

```powershell
# 本地
cd D:\Workspace\deploy
.\scripts\build.ps1 financial-web
scp dist\packages\financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

```bash
# 服务器
cd /www/wwwroot/project/uploads/dist
bash deploy.sh financial-web
```

#### 只更新 financial-api 后端

```powershell
# 本地
cd D:\Workspace\deploy
.\scripts\build.ps1 financial-api
scp dist\packages\financial-api-*.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

```bash
# 服务器
cd /www/wwwroot/project/uploads/dist
bash deploy.sh financial-api --ip=47.86.32.234
```

#### 只更新 QuantDinger 后端

```powershell
# 本地
cd D:\Workspace\deploy
.\scripts\build.ps1 deepquant-backend
scp dist\packages\deepquant-backend-package.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

```bash
# 服务器
cd /www/wwwroot/project/uploads/dist
bash deploy.sh deepquant-backend --ip=47.86.32.234
```

---

## 回滚

每次部署前自动备份到 `/www/wwwroot/project/backup/<项目>/`，保留最近 5 个版本。
**回滚前会再备份当前线上版本**；执行前会打印计划并要求输入 `yes` 确认（`--yes` 可跳过，慎用）。

### 列出可用备份

```bash
cd /www/wwwroot/project/uploads/dist
bash deploy.sh financial-web --list
bash deploy.sh --list                  # 交互列出全部
```

### 单项目 / 多项目 / 全量回滚

```bash
# 单项目（交互选版本 → 确认 yes）
bash deploy.sh financial-web --rollback

# 多项目，各取最新备份
bash deploy.sh financial-web,official-site --rollback=latest

# 全量（仅回滚「有备份」的项目）
bash deploy.sh all --rollback

# 指定时间戳（各项目需存在同名备份）
bash deploy.sh financial-web --rollback=20260728-103000

# 自动化（跳过确认，危险）
bash deploy.sh all --rollback=latest --yes
```

### 交互式回滚

```bash
bash deploy.sh
# → 菜单 3) 回滚（单项目 / 多选 / 全部）
# → 可选：每项手选版本，或全部用最新
```

### 备份位置

| 项目 | 备份路径 | 备份内容 |
|------|----------|----------|
| financial-web | `/www/wwwroot/project/backup/financial-web/` | dist/ 目录整体 |
| financial-api | `/www/wwwroot/project/backup/financial-api/` | package/ 代码（排除 .env/.venv） |
| official-site | `/www/wwwroot/project/backup/official-site/` | dist/ 目录整体 |
| deepquant-web | `/www/wwwroot/project/backup/deepquant-web/` | dist/ 目录整体 |
| deepquant-backend | `/www/wwwroot/project/backup/deepquant-backend/` | package/ 代码（排除 .env/.venv） |

> 回滚后自动重启相关服务。前端回滚后自动 nginx reload，后端回滚后自动 systemctl restart。

---

## 日常运维

### 服务管理

```bash
# ── 查看所有服务状态 ──
systemctl status financial-api financial-crawler financial-worker financial-streaming quantdinger-backend

# ── 重启单个服务 ──
systemctl restart financial-api
systemctl restart financial-crawler
systemctl restart financial-worker
systemctl restart financial-streaming
systemctl restart quantdinger-backend

# ── 重启所有服务 ──
systemctl restart financial-api financial-crawler financial-worker financial-streaming quantdinger-backend

# ── 停止/启动 ──
systemctl stop financial-api
systemctl start financial-api

# ── 开机自启 ──
systemctl enable financial-api quantdinger-backend
systemctl is-enabled financial-api  # 检查是否开机自启
```

### 日志排查

```bash
# ── 实时查看日志（跟踪模式）──
journalctl -u financial-api -f
journalctl -u financial-crawler -f
journalctl -u financial-worker -f
journalctl -u financial-streaming -f
journalctl -u quantdinger-backend -f

# ── 查看最近 50 行 ──
journalctl -u financial-api -n 50 --no-pager
journalctl -u quantdinger-backend -n 50 --no-pager

# ── 按时间查日志 ──
journalctl -u financial-api --since "2026-07-28 10:00" --until "2026-07-28 12:00" --no-pager

# ── 只看错误 ──
journalctl -u financial-api -p err --no-pager

# ── Nginx 日志 ──
tail -f /www/wwwlogs/access.log
tail -f /www/wwwlogs/error.log

# ── 查看 Nginx 反向代理错误（502/504 时查这个）──
tail -f /www/wwwlogs/error.log | grep -E '502|504|upstream'
```

### 健康检查

```bash
# ── 后端 API 健康检查 ──
curl -s http://127.0.0.1:5001/api/health | python3 -m json.tool
curl -s http://127.0.0.1:5000/api/health | python3 -m json.tool

# ── 通过 Nginx 检查（外部访问）──
curl -s http://47.86.32.234/api/health
curl -s http://47.86.32.234/quant/api/health

# ── 运行时配置检查 ──
curl -s http://127.0.0.1:5001/api/system/runtime-config | python3 -m json.tool

# ── 端口监听检查 ──
ss -tlnp | grep -E '5000|5001|80|443|5432|6379'

# ── 进程检查 ──
ps aux | grep uvicorn
ps aux | grep gunicorn
```

### Nginx 操作

```bash
# ── 测试配置 ──
nginx -t

# ── 重载配置（不中断服务）──
nginx -s reload

# ── 重启 Nginx ──
/etc/init.d/nginx restart
# 或宝塔面板 → 软件商店 → Nginx → 重启

# ── 查看 Nginx 配置文件位置 ──
nginx -T 2>&1 | head -20

# ── 查看当前站点配置 ──
cat /www/server/panel/vhost/nginx/default.conf

# ── 更新 Nginx 配置 ──
cp /www/wwwroot/project/uploads/dist/nginx-all-sites.conf /www/server/panel/vhost/nginx/default.conf
nginx -t && nginx -s reload
```

### 数据库操作

```bash
# ── 连接数据库 ──
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quantdinger

# ── 查看数据库列表 ──
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d postgres -c "\l"

# ── 查看表列表 ──
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc -c "\dt"
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quantdinger -c "\dt"

# ── 查看表结构 ──
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc -c "\d fin_app_configs"

# ── 执行 SQL 查询 ──
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc -c "SELECT count(*) FROM fin_news;"

# ── 数据库备份 ──
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc | gzip > /root/backup_quant_zc_$(date +%Y%m%d).sql.gz
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quantdinger | gzip > /root/backup_quantdinger_$(date +%Y%m%d).sql.gz

# ── 数据库恢复 ──
gunzip -c /root/backup_quant_zc_20260728.sql.gz | PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc
gunzip -c /root/backup_quantdinger_20260728.sql.gz | PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quantdinger

# ── 从远程服务器迁移数据 ──
# 旧服务器导出
PGPASSWORD='旧密码' pg_dump -U 旧用户 -h 旧服务器IP -d quant_zc | gzip > /root/quant_zc.sql.gz
# 新服务器导入
gunzip -c /root/quant_zc.sql.gz | PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc

# ── 数据库迁移（financial-api Alembic）──
cd /www/wwwroot/project/financial/financial-api/package
.venv/bin/alembic upgrade head     # 执行迁移
.venv/bin/alembic current          # 查看当前版本
.venv/bin/alembic history          # 查看迁移历史

# ── 重新加载种子数据 ──
cd /www/wwwroot/project/financial/financial-api/package
.venv/bin/python -m app.db.seed
```

### Redis 操作

```bash
# ── 连接 Redis ──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD

# ── 测试连接 ──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD ping

# ── 查看 Redis 信息 ──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD info

# ── 查看内存使用 ──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD info memory | grep used_memory_human

# ── 查看所有 key 数量 ──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD dbsize

# ── 查看 key 列表（谨慎使用，生产环境不要 KEYS *）──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD --scan --pattern 'fin_*' | head -20

# ── 清除 financial-api 缓存 ──
redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD --scan --pattern 'fin_*' | xargs -r redis-cli -h localhost -p 6379 -a $REDIS_PASSWORD del

# ── Redis 迁移（从旧服务器）──
# 旧服务器导出 RDB
redis-cli -h 旧服务器IP -a 旧密码 --rdb /root/dump.rdb
# 新服务器导入（需先停 Redis）
/etc/init.d/redis stop
cp /root/dump.rdb /www/server/redis/dump.rdb
/etc/init.d/redis start
```

### 更新部署

日常发版请走上文 **「增量发版」**（`build.ps1` → `scp` → `deploy.sh`），不要手搓旧路径的 `tar`/`scp` 命令。

```bash
# 仅更新 Nginx 配置示例
bash deploy.sh --nginx
# 或手动：拷贝 dist/configs 中对应 conf 后 nginx -t && nginx -s reload
```

### 磁盘与系统检查

```bash
# ── 磁盘空间 ──
df -h

# ── 查看项目占用空间 ──
du -sh /www/wwwroot/project/*
du -sh /www/wwwroot/project/financial/financial-api/package/.venv
du -sh /www/server/pgsql/data

# ── 内存使用 ──
free -h

# ── CPU 使用 TOP 5 进程 ──
ps aux --sort=-%cpu | head -6

# ── 内存使用 TOP 5 进程 ──
ps aux --sort=-%mem | head -6

# ── 系统负载 ──
uptime

# ── 清理日志（释放磁盘）──
journalctl --vacuum-size=500M          # 限制 journal 日志 500MB
> /www/wwwlogs/access.log               # 清空 Nginx 访问日志
> /www/wwwlogs/error.log                # 清空 Nginx 错误日志

# ── 清理 Python 缓存 ──
find /www/wwwroot/project -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
find /www/wwwroot/project -name '*.pyc' -delete
```

### 防火墙与端口

```bash
# ── 原则：主机防火墙只用宝塔「安全」；禁用系统 ufw/firewalld ──
bash /root/01b-baota-exclusive.sh --check

# ── 查看监听端口 ──
ss -tlnp | grep -E '5000|5001|5432|6379|80|443'

# ── 宝塔面板 → 安全 放行（不要用 ufw/firewall-cmd 并行管理）──
# 必须：80、443、22、面板端口
# 禁止：5432（PostgreSQL）、6379（Redis）对 0.0.0.0 开放

# ── 阿里云/腾讯云安全组 ──
# 与宝塔放行保持一致：80/443/22/面板端口
```

### 宝塔面板操作

```bash
# ── 宝塔面板命令 ──
bt default              # 查看面板登录信息
bt 5                    # 重置面板密码
bt 14                   # 查看默认信息
bt 16                   # 修复面板
bt restart              # 重启面板

# ── 宝塔服务管理 ──
/etc/init.d/nginx restart       # 重启 Nginx
/etc/init.d/redis restart       # 重启 Redis
# PostgreSQL 通过宝塔面板管理
```

### 定期备份

```bash
# ── 创建备份脚本 ──
cat > /root/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/root/backups"
mkdir -p "$BACKUP_DIR"
DATE=$(date +%Y%m%d_%H%M%S)

# 数据库备份
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc | gzip > "$BACKUP_DIR/quant_zc_$DATE.sql.gz"
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quantdinger | gzip > "$BACKUP_DIR/quantdinger_$DATE.sql.gz"

# 保留最近 7 天的备份
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete

echo "备份完成: $DATE"
EOF
chmod +x /root/backup.sh

# ── 添加定时任务（每天凌晨 3 点）──
crontab -l 2>/dev/null | { cat; echo "0 3 * * * /root/backup.sh >> /root/backup.log 2>&1"; } | crontab -

# ── 手动执行备份 ──
bash /root/backup.sh
```

---

## 远程开发

本地开发时直连远程服务器数据库/后端，无需在本地启动 PostgreSQL/Redis/后端服务。

### SSH 免密配置

已配置 `~/.ssh/config`，可直接用别名连接：

```bash
ssh serverA    # → root@47.86.32.234:22
ssh serverB    # → root@103.100.211.12:3142
```

### 服务器信息

| | 服务器 A | 服务器 B |
|---|---------|---------|
| **别名** | `serverA` | `serverB` |
| **IP** | 47.86.32.234 | 103.100.211.12 |
| **SSH 端口** | 22 | 3142 |
| **域名** | `www.zhuochouacedemy.com`（裸域 301→www） | `www.deepquant.club` |
| **Nginx 模板** | `nginx-servera-ssl.conf`（SSL） | `nginx-all-sites-ssl.conf`（SSL） |
| **PostgreSQL** | 见服务器 `deploy.env` 的 `PG_*` | 同左（若两机密码不同则各自 `deploy.env`） |
| **数据库** | quant_zc, quantdinger | quant_zc, quantdinger |
| **Redis 密码** | 见 `REDIS_PASSWORD` | 见 `REDIS_PASSWORD` |
| **SMTP** | 宝塔邮局 `noreply@zhuochouacedemy.com` | — |

### 远程开发启动命令

#### financial-api（后端直连远程 DB）

```powershell
cd D:\Workspace\financial\financial-api

# 连接服务器 A 的数据库
$env:ENV_FILE=".env.remoteA"; uv run uvicorn app.main:app --reload

# 连接服务器 B 的数据库
$env:ENV_FILE=".env.remoteB"; uv run uvicorn app.main:app --reload
```

> 远程模式自动设为 `APP_ROLE=api`，不启动爬虫和实时推送，只读查询远程 DB。

#### financial-admin（后台直连远程后端）

```powershell
cd D:\Workspace\financial\financial-admin
pnpm dev:remoteA    # 连接服务器 A 后端
pnpm dev:remoteB    # 连接服务器 B 后端
```

#### financial-web（C 端直连远程后端）

```powershell
cd D:\Workspace\financial\financial-web
pnpm dev:remoteA    # 连接服务器 A 后端
pnpm dev:remoteB    # 连接服务器 B 后端
```

#### deepquant_vue（QuantDinger 前端直连远程后端）

```powershell
cd D:\Workspace\deep\deepquant_vue
pnpm dev:remoteA    # 连接服务器 A 的 QuantDinger 后端
pnpm dev:remoteB    # 连接服务器 B 的 QuantDinger 后端
```

### 配置文件清单

| 项目 | 文件 | 连接目标 |
|------|------|----------|
| financial-api | `.env.remoteA` | 47.86.32.234 PostgreSQL + Redis |
| financial-api | `.env.remoteB` | 103.100.211.12 PostgreSQL + Redis |
| financial-admin | `.env.remoteA` | http://47.86.32.234/api |
| financial-admin | `.env.remoteB` | http://103.100.211.12/api |
| financial-web | `.env.remoteA` | 47.86.32.234 /api + WebSocket |
| financial-web | `.env.remoteB` | 103.100.211.12 /api + WebSocket |
| deepquant_vue | `.env.remoteA` | 47.86.32.234 /quant/api |
| deepquant_vue | `.env.remoteB` | 103.100.211.12 /quant/api |

### 服务器端 PostgreSQL 远程访问

首次使用需在服务器上配置 PostgreSQL 允许远程连接（SSH 到服务器执行）：

```bash
# ── 1. 修改 postgresql.conf ──
PG_CONF=$(find /www/server/ -name "postgresql.conf" 2>/dev/null | head -1)
cp "$PG_CONF" "$PG_CONF.bak"
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
grep -q "^listen_addresses" "$PG_CONF" || echo "listen_addresses = '*'" >> "$PG_CONF"

# ── 2. 修改 pg_hba.conf ──
PG_HBA=$(find /www/server/ -name "pg_hba.conf" 2>/dev/null | head -1)
cp "$PG_HBA" "$PG_HBA.bak"
cat >> "$PG_HBA" << 'EOF'
host    all    all    0.0.0.0/0    md5
host    all    all    ::/0         md5
EOF

# ── 3. 设置 root 密码 ──
su - postgres -c "psql -c \"ALTER USER root WITH PASSWORD '$PG_PASSWORD';\""
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE quant_zc TO root;\""
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE quantdinger TO root;\""

# ── 4. 重启（不要用系统防火墙放行 5432/6379）──
/etc/init.d/postgresql restart
# 远程开发如需连库：仅对你的办公 IP 在「云安全组」临时放行 5432，
# 或优先用 SSH 隧道，不要 0.0.0.0 开放。
```

---

## 常见问题

### Q: 宝塔面板忘记密码

```bash
bt 5     # 重置面板密码
bt 14    # 查看面板默认信息
bt default  # 查看面板登录信息
```

### Q: Nginx 报 502 Bad Gateway

```bash
# 检查后端服务是否运行
systemctl status financial-api
systemctl status quantdinger-backend

# 检查端口监听
ss -tlnp | grep -E '5000|5001'

# 查看后端日志
journalctl -u financial-api -n 50 --no-pager
journalctl -u quantdinger-backend -n 50 --no-pager
```

### Q: financial-web 跳转 official-site 404

检查数据库配置：
```bash
PGPASSWORD="$PG_PASSWORD" psql -U root -d quant_zc -c \
  "SELECT config_value FROM fin_app_configs WHERE namespace='links' AND config_key='deepquant';"
```

预期结果：`{"siteUrl": "/qd", "appBaseUrl": "/quant"}`

如不正确，执行：
```bash
PGPASSWORD="$PG_PASSWORD" psql -U root -d quant_zc -c \
  "UPDATE fin_app_configs SET config_value='{\"siteUrl\":\"/qd\",\"appBaseUrl\":\"/quant\"}'::jsonb WHERE namespace='links' AND config_key='deepquant';"
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
3. **SSL 证书**：按 [Phase 7b](#phase-7b-ssl-证书--宝塔邮局申请域名部署) 流程申请
4. **Nginx**：`deploy.env` 设 `NGINX_CONF_NAME=nginx-servera-ssl.conf`，执行 `bash deploy.sh --nginx`（自动渲染 `__DOMAIN__` / `__WWW_DOMAIN__` 占位符）
5. **financial-api**：执行 `bash deploy.sh financial-api`（自动渲染 `CORS_ORIGINS` / `SMTP` 占位符）
6. **QuantDinger**：执行 `bash deploy.sh deepquant-backend`（自动渲染 `__FRONTEND_URL__`）
7. **邮局**：按 [Phase 7b 步骤 3](#3-配置宝塔邮局) 配置宝塔邮局 + DNS 记录
8. **重启**：`systemctl restart financial-api quantdinger-backend` + `nginx -s reload`

---

## 附录：部署排障记录（历史）

### 1. Nginx 配置统一（2026-07-28）

**问题**：服务器 B 原有的 Nginx 站点配置 (`www.deepquant.club.conf`) 路由结构与服务器 A 不一致：
- B：financial-web 在 `/financial/` 子路径，QuantDinger API 在 `/api/`
- A：financial-web 在根路径 `/`，QuantDinger API 在 `/quant/api/`

**修复**：将服务器 B 的站点配置替换为统一模板（`configs/nginx-all-sites-ssl.conf`），路由表与 A 的 `configs/nginx-all-sites.conf` 完全一致，仅增加 SSL 配置。

**两台服务器配置差异**：

| 文件 | 服务器 A | 服务器 B |
|------|---------|---------|
| Nginx 模板 | `nginx-all-sites.conf`（无 SSL） | `nginx-all-sites-ssl.conf`（有 SSL） |
| 路由表 | 相同 | 相同 |
| 差异 | 仅 IP/密码 | 仅 IP/密码 + SSL 证书 |

### 2. 目录结构统一（2026-07-28，修订 2026-07-28）

**问题**：服务器 B 的 QuantDinger 后端在 `/www/wwwroot/project/quant-dinger/quantdinger-api/`，与 A 的 `/www/wwwroot/project/deepquant/backend/` 不一致。

**初始修复**：创建软链：
```bash
ln -s /www/wwwroot/project/quant-dinger/quantdinger-api /www/wwwroot/project/deepquant/backend
ln -s /www/wwwroot/project/quant-dinger/quantdinger-web /www/wwwroot/project/deepquant/web
```

**修订**：软链方案在后续部署中造成混淆（`__pycache__` 缓存失效、路径不一致），改为真实目录迁移：
```bash
# 1. 停止 quantdinger-backend
systemctl stop quantdinger-backend

# 2. 删除软链
rm /www/wwwroot/project/deepquant/backend

# 3. 移动真实目录
mv /www/wwwroot/project/quant-dinger/quantdinger-api /www/wwwroot/project/deepquant/backend

# 4. 清理旧目录（需先解除宝塔 .user.ini 不可变属性）
find /www/wwwroot/project/quant-dinger -name '.user.ini' -exec chattr -i {} + 2>/dev/null
rm -rf /www/wwwroot/project/quant-dinger
rm -rf '/www/wwwroot/project/official-website'
rm -rf '/www/wwwroot/project/official-website--可删'

# 5. 重启
systemctl start quantdinger-backend
```

> **约定**：不再使用软链，所有项目目录为真实目录。两台服务器目录结构完全一致：
> ```
> /www/wwwroot/project/
> ├── deepquant/{backend/package, web/dist}
> ├── financial/{financial-api/package, financial-web/dist}
> ├── official-site/dist
> └── uploads/
> ```

### 3. systemd 服务补装（2026-07-28）

**问题**：服务器 B 缺少 `financial-worker` 和 `financial-streaming` 两个 systemd 服务。

**修复**：从服务器 A 复制 service 文件到 `/etc/systemd/system/`，`systemctl daemon-reload && enable && start`。

### 4. quantdinger-backend 服务路径（2026-07-28）

**问题**：服务器 B 的 `quantdinger-backend.service` 指向旧路径 (`source/backend_api_python/venv/`)，新部署在 `package/.venv/`。

**修复**：替换 service 文件，统一使用 `/www/wwwroot/project/deepquant/backend/package` 路径。

### 5. 401 登录失败（2026-07-28）

**问题**：部署 deepquant-backend 后，用户登录返回 401。

**根因**：部署脚本从旧目录 (`source/backend_api_python/`) 部署到新目录 (`package/`)，但 `.env` 未随之迁移，导致 `DATABASE_URL` 缺失。

**修复**：
```bash
cp /www/wwwroot/project/quant-dinger/quantdinger-api/source/backend_api_python/.env \
   /www/wwwroot/project/deepquant/backend/package/.env
systemctl restart quantdinger-backend
```

### 6. AUTH_UPSTREAM_URL 改为 localhost（2026-07-28）

**问题**：部署脚本将 `AUTH_UPSTREAM_URL` 改为 `http://<服务器IP>/quant`，导致认证请求绕外网。

**修复**：改为 `http://127.0.0.1:5000`（两台服务器相同），financial-api 直连本地 QuantDinger 后端。

### 7. official-site 内部链接（2026-07-28）

**问题**：official-site 的 "启动应用" 按钮链接使用绝对 IP (`http://103.100.211.12/quant`)，域名访问时跳转到错误地址。

**修复**：`configs/official-site.env` 中 `VITE_APP_URL` 从 `http://__SERVER_IP__/quant` 改为相对路径 `/quant`，`build.ps1` 去掉 IP 替换逻辑，一次构建通用所有服务器。

### 8. PowerShell 脚本编码（2026-07-28）

**问题**：`build.ps1` 中含中文字符，Windows PowerShell 以非 UTF-8 编码读取导致 `MissingEndCurlyBrace` 解析错误。

**修复**：将 `build.ps1` 以 UTF-8 BOM 编码保存。

### 9. Nginx /qd /quant 无尾斜杠重定向（2026-07-28）

**问题**：访问 `/qd` 或 `/quant`（无尾部斜杠）时不匹配 `location ^~ /qd/`，落入 `location /` 的 SPA fallback，返回 financial-web 首页而非目标站点。

**修复**：两个 Nginx 配置模板（`nginx-all-sites.conf` 和 `nginx-all-sites-ssl.conf`）中增加精确匹配重定向：
```nginx
location = /qd { return 301 /qd/; }
location = /quant { return 301 /quant/; }
```

### 10. 交互式部署工具重构（2026-07-28）

**重构内容**：

- `deploy.sh`：增加交互式主菜单（部署/回滚/备份/状态/日志）、多选部署、日志查看（实时/最近50/最近100/ERROR级别）
- `build.ps1`：增加交互式菜单（多选构建/全量构建/查看产物）、UTF-8 BOM 编码
- 新增 `--status` 查看所有服务状态，`--logs` 查看日志

### 11. alembic __pycache__ 导致服务启动失败（2026-07-28）

**问题**：服务器 B 的 `financial-api` 反复崩溃（`activating auto-restart`），日志显示 `alembic.util.exc.CommandError: Can't locate revision identified by 'j6e7f8a9b0c1'`，但迁移文件实际存在。

**根因**：`alembic/versions/__pycache__/` 中缓存了旧的迁移模块，导致 alembic 无法正确加载新增的迁移文件。

**修复**：
```bash
rm -rf /www/wwwroot/project/financial/financial-api/package/alembic/versions/__pycache__
systemctl restart financial-api
```

### 12. CORS_ORIGINS 缺少 admin 端口（2026-07-28）

**问题**：`financial-admin` 以 `remoteA`/`remoteB` 模式直连远程后端时，浏览器从 `localhost:5174` 向服务器发请求被 CORS 拦截。

**根因**：生产服务器 `.env` 的 `CORS_ORIGINS` 缺少 `http://localhost:5174` 和 `http://127.0.0.1:5174`（admin 后台端口）。

**修复**：两台服务器均需在 `.env` 中补充：
```bash
# 服务器 A / B 均执行
CORS_ORIGINS=http://<服务器IP>,http://localhost:5173,http://127.0.0.1:5173,http://localhost:5174,http://127.0.0.1:5174
systemctl restart financial-api
```

### 13. deploy.sh 工具链增强（2026-07-29）

**新增功能**：

| 功能 | 说明 |
|---|---|
| **Pre-flight 检查** | 部署前自动检查磁盘空间、PostgreSQL、Redis、端口占用、Python 版本 |
| **Deploy 锁** | `flock` 防止并发部署（`/tmp/deploy.lock`） |
| **审计日志** | 每次部署/回滚写入 `/www/wwwroot/project/uploads/deploy.log` |
| **批量容错部署** | 多项目部署时单个失败不中断后续（`deploy_batch`） |
| **依赖排序** | 多项目自动按"前端→后端"排序，减少服务中断窗口 |
| **数据库备份** | `alembic migrate` 前自动 `pg_dump`，保留 5 份 |
| **.env 增量同步** | 对比 `.env.example` 自动补缺失的 env var |
| **Git 信息嵌入** | 打包时生成 `VERSION` 文件，部署后展示 commit hash |
| **启动帮助** | 交互式菜单首次启动显示完整命令行帮助 |

**Bug 修复**：

- 所有 `deploy_*` 函数 `exit 1` → `return 1`（配合 `deploy_batch` 容错）
- `deploy_financial_api` tar 解压路径修正（`basename` → 完整路径）
- `deploy_batch` 返回值加 `|| true`（防 `set -e` 杀脚本）
- `build.ps1` 多项目逗号检测 `-contains` → `-match`（PowerShell 语义修正）
- `backup_backend` 增加 `__pycache__`/`*.pyc` 排除
- `deploy-financial-api.sh` 内联 `.env` 模板 CORS 补 `localhost:5173/5174`，`AUTH_UPSTREAM_URL` 改 `localhost`
- `deploy.sh` CORS 更新从覆盖改为追加（保留 localhost）
- `deploy-financial-api.sh` `__pycache__` 清理范围扩大（含 `alembic/versions/`）

### 14. 服务器 A 域名 + SMTP 配置（2026-07-30）

**背景**：服务器 A 域名 `www.zhuochouacedemy.com`（裸域 `zhuochouacedemy.com` 301→www）已解析到位，需配置 SSL + 邮箱验证码。

**改动文件**：

| 文件 | 变更 |
|------|------|
| `configs/nginx-servera-ssl.conf` | **新增**：服务器 A 专属 Nginx SSL 配置，裸域→www 301，HTTP→HTTPS |
| `configs/financial-api.env.example` | CORS 加入 `https://www.zhuochouacedemy.com,https://zhuochouacedemy.com`；补充 SMTP 配置段 |
| `configs/deepquant.env.example` | `FRONTEND_URL` 改为 `__FRONTEND_URL__` 占位符 |
| `deploy.env` | 新增 `SMTP_PASSWORD`、`FRONTEND_URL`、`NGINX_CONF_NAME` |
| `deploy.env.example` | 新增对应占位符 |
| `scripts/deploy-financial-api.sh` | 渲染 `__SMTP_PASSWORD__`；内联模板补 SMTP + CORS |
| `scripts/deploy.sh` | CORS 从覆盖改为追加（保留域名 origin）；渲染 `__FRONTEND_URL__`；`deploy_nginx` 支持 `NGINX_CONF_NAME` |

**服务器 A 上线步骤**：

```bash
# 1. 宝塔面板 → 网站 → SSL → Let's Encrypt（同时申请 www + 裸域）
# 2. 宝塔面板 → 软件商店 → 邮局 → 创建 noreply@zhuochouacedemy.com
# 3. 编辑 deploy.env：填入 SMTP_PASSWORD
# 4. 部署 Nginx 配置
cd /www/wwwroot/project/uploads/dist
bash deploy.sh --nginx

# 或单独拷贝
cp configs/nginx-servera-ssl.conf /www/server/panel/vhost/nginx/default.conf
nginx -t && nginx -s reload

# 5. 更新已部署的 .env（financial-api）
# CORS 加入域名
sed -i 's|^CORS_ORIGINS=.*|CORS_ORIGINS=https://www.zhuochouacedemy.com,https://zhuochouacedemy.com,http://localhost:5173,http://127.0.0.1:5173,http://localhost:5174,http://127.0.0.1:5174|' \
  /www/wwwroot/project/financial/financial-api/package/.env

# SMTP 配置
cat >> /www/wwwroot/project/financial/financial-api/package/.env << 'EOF'
SMTP_ENABLED=true
SMTP_HOST=127.0.0.1
SMTP_PORT=465
SMTP_USERNAME=noreply@zhuochouacedemy.com
SMTP_PASSWORD=你的邮箱密码
SMTP_USE_TLS=false
SMTP_FROM_ADDR=noreply@zhuochouacedemy.com
SMTP_FROM_NAME=卓筹商学院
EOF

# QuantDinger FRONTEND_URL
sed -i 's|^FRONTEND_URL=.*|FRONTEND_URL=https://www.zhuochouacedemy.com|' \
  /www/wwwroot/project/deepquant/backend/package/.env

# 6. 重启
systemctl restart financial-api quantdinger-backend
nginx -s reload

# 7. 验证
curl -sf https://www.zhuochouacedemy.com/api/health
curl -sf https://www.zhuochouacedemy.com/          # financial-web
curl -sf https://www.zhuochouacedemy.com/qd/        # official-site
curl -sf https://www.zhuochouacedemy.com/quant/     # QuantDinger 前端
curl -sI https://zhuochouacedemy.com                # 应返回 301 → www
```

### 15. .env 被包内文件覆盖导致登录 401（2026-07-30）

**问题**：服务器 B 部署 financial-api 后，financial-web 登录返回 401，数据库连接报错。

**现象**：
- `AUTH_MODE` 从 `upstream` 被覆盖成 `local` → 登录查本地 `fin_users` 表而非转发 QuantDinger
- `DATABASE_URL` 从正确的库账号密码被覆盖成 `quantdinger:quantdinger123` → 数据库连接错误
- `AUTH_UPSTREAM_URL` 从 `127.0.0.1:5000` 被覆盖成 `https://www.deepquant.club` → 认证绕外网
- `AUTH_SECRET_KEY` 被换 → 旧 JWT token 全部失效
- `REDIS_URL` 丢失密码

**根因（双重缺陷）**：

1. **`pack-generic.ps1`（根因）**：robocopy 的 `/XD .env` 只排除名为 `.env` 的**目录**，不排除**文件**。`financial/financial-api/` 下存在开发者本地 `.env` 文件，被误打包进 tar.gz。
2. **`deploy-financial-api.sh`（防线缺失）**：代码同步时 `cp -a "${SRC_DIR%/}/." "$PKG_DIR/"` 会把包内 `.env` 覆盖服务器生产 `.env`。`find` 只保护了删除阶段（`! -name '.env'`），没保护 `cp -a` 阶段。

**紧急修复（服务器 B 现场）**：
```bash
# 恢复关键字段
sed -i 's|^AUTH_MODE=.*|AUTH_MODE=upstream|' /www/wwwroot/project/financial/financial-api/package/.env
sed -i 's|^DATABASE_URL=.*|DATABASE_URL=postgresql+psycopg2://root:$PG_PASSWORD@localhost:5432/quant_zc|' /www/wwwroot/project/financial/financial-api/package/.env
sed -i 's|^AUTH_UPSTREAM_URL=.*|AUTH_UPSTREAM_URL=http://127.0.0.1:5000|' /www/wwwroot/project/financial/financial-api/package/.env
# REDIS_URL / AUTH_SECRET_KEY 按实际值恢复
systemctl restart financial-api
```

**永久修复（已合入）**：

| 文件 | 修复内容 |
|------|----------|
| `scripts/pack-generic.ps1` | robocopy `/XD .env` → `/XF .env`（从排除目录改为排除文件） |
| `scripts/deploy-financial-api.sh` | 代码同步阶段：备份 `.env` → `cp -a` → 恢复 `.env`；额外 `rm -f "${SRC_DIR}/.env"` 删除包内残留 |
| `scripts/deploy-financial-api.sh` | `sync_env` 增加占位符检测：跳过含 `__PLACEHOLDER__` 的值（如 `__PG_PASSWORD__`），避免追加无意义默认值 |

**教训**：
- `.env` 是文件不是目录，robocopy `/XD` 排目录、`/XF` 排文件，两者不可混用。
- `cp -a src/. dest/` 会覆盖 dest 中同名文件，即使前面 `find` 保护了删除阶段也无效。
- 部署脚本的 `.env` 保护必须是「备份 → 复制 → 恢复」三步，不能只靠 `find ! -name`。

### 部署后验证清单

```bash
# 两台服务器均需验证
systemctl is-active financial-api financial-crawler financial-worker financial-streaming quantdinger-backend
curl -sf http://127.0.0.1:5001/api/health   # financial-api
curl -sf http://127.0.0.1:5000/api/health   # quantdinger-backend
curl -sf http://127.0.0.1/                   # financial-web 首页
curl -sf http://127.0.0.1/qd/                # official-site
curl -sf http://127.0.0.1/quant/             # QuantDinger 前端

# 交互式部署
cd /www/wwwroot/project/uploads/dist && bash deploy.sh

# 查看状态
bash deploy.sh --status

# 查看日志
bash deploy.sh --logs financial-api --lines=100
bash deploy.sh --logs deepquant-backend --logs=error
```
