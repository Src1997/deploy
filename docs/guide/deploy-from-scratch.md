# 完整部署步骤（从零开始）

> **Category**: Guide

从零开始：**清理 Docker** → 装宝塔 → 配置驱动构建/部署（`projects.yaml`）→ systemd + Nginx。

## 前提条件

- 服务器：Linux（Ubuntu 20+ / CentOS 7+ / Debian 10+），root 权限
- 服务器当前运行 Docker（将被卸载）
- 本地 Windows 已安装：Node.js 20+、pnpm 11+、Python 3.11+、uv
- 本地已安装 financial-web 依赖（`pnpm install`）
- 本地已安装 deepquant_vue 依赖（`pnpm install`）

## 执行顺序总览

```
【云安全组】先放行 22 / 80 / 443 / 面板端口（勿放 5432、6379）

Phase 0: 环境清理                 (00-cleanup-docker.sh)
         ├─ Docker 卸载（已卸则自动跳过）
         └─ 系统防火墙/系统库冲突清理（原 0b，已并入）
Phase 1: 安装宝塔面板             (01-install-baota.sh)     ← 已装则提示跳过
Phase 2: 宝塔面板安装基础组件      (手动) Nginx/PG/Redis/Python
         + 宝塔「安全」放行端口
         + 建议复查: 00 --conflicts-only --check
Phase 3: 创建数据库和目录          (03-server-setup.sh)
Phase 4: 本地构建打包             (build.ps1 all)
Phase 5: 上传到服务器             (scp dist + deploy.sh)
Phase 6: 服务器部署               (deploy.sh all)           ← 已部署会提示确认
Phase 7: 宝塔 Nginx 站点配置      (deploy.sh --nginx)
验证:    detect-status.sh + curl health
```

> **随时查看进度**：`bash detect-status.sh`（标 DONE / PARTIAL / TODO，并给出下一步）。

---

## Phase 0: 环境清理 — Docker + 系统冲突（SSH）

```bash
scp D:\Workspace\deploy\scripts\00-cleanup-docker.sh \
    D:\Workspace\deploy\scripts\02-baota-exclusive.sh \
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

兼容：`bash 02-baota-exclusive.sh` ≡ `bash 00-cleanup-docker.sh --conflicts-only`

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

## Phase 1: 安装宝塔面板（SSH）

```bash
scp D:\Workspace\deploy\scripts\01-install-baota.sh root@服务器IP:/root/
bash /root/01-install-baota.sh
```

安装脚本会：
- 确认 Docker 已彻底卸载（否则拒绝执行）
- 检查端口 80 空闲
- 检测操作系统（Ubuntu/Debian/CentOS）
- 下载并执行宝塔官方安装脚本
- 输出面板地址、用户名、密码

---

## Phase 2: 宝塔面板安装基础组件（手动操作）

登录宝塔面板后，进入 **软件商店** 安装以下组件：

| 组件 | 版本 | 用途 |
|------|------|------|
| **Nginx** | 稳定版 | 反向代理 + 静态文件服务 |
| **PostgreSQL** | 16.x | 数据库（两个后端共享） |
| **Redis** | 7.x | 缓存（两个后端共享） |
| **Python 项目管理器** | — | 提供 Python 3.12（后端 venv 用） |

**设置数据库密码（与 `deploy.env` 保持一致）：**

```bash
cp deploy.env.example deploy.env
# 编辑 deploy.env：填写 PG_PASSWORD / REDIS_PASSWORD

# 宝塔 PostgreSQL
su - postgres -c "psql -c \"ALTER USER root WITH PASSWORD '你的PG密码';\""

# 宝塔 Redis：面板改 requirepass
```

---

## Phase 3: 创建数据库和目录（SSH）

```bash
scp D:\Workspace\deploy\scripts\03-server-setup.sh root@服务器IP:/root/
bash /root/03-server-setup.sh
```

准备脚本会：
- 检查宝塔安装的 Nginx、PostgreSQL、Redis、Python 3.11+
- 验证 Docker 已彻底卸载
- 创建数据库 `quant_zc`（financial-api）和 `quantdinger`（QuantDinger）
- 验证 Redis 连接
- 创建目录结构

---

## Phase 4: 本地构建打包（Windows PowerShell）

```powershell
cd D:\Workspace\deploy
.\scripts\build.ps1 all
```

构建产出 `dist/`（自包含：deploy.sh + configs + packages）。

---

## Phase 5: 上传到服务器

```powershell
scp -r D:\Workspace\deploy\dist root@服务器IP:/www/wwwroot/project/uploads/
```

---

## Phase 6: 服务器一键部署（SSH）

```bash
ssh root@服务器IP
cd /www/wwwroot/project/uploads/dist
bash deploy.sh all --ip=服务器IP
```

部署脚本自动完成：
1. **financial-api**: 代码同步 → venv → .env → 依赖 → 迁移 → 种子 → systemd → 启动
2. **QuantDinger 后端**: 代码同步 → venv → .env → 依赖 → init.sql → systemd → 启动
3. **静态站点**: 解压到对应目录
4. **Nginx**: 动态生成配置并重载（`--nginx`）

---

## Phase 7: Nginx 配置

```bash
# 部署 + 自动配置 Nginx（动态生成）
bash deploy.sh all --ip=服务器IP --nginx

# 或单独配置 Nginx
bash deploy.sh --nginx
```

> **SSL 模式**：在 `deploy.env` 中设置 `NGINX_CONF_NAME`：
> - 服务器 A（裸域→www 301 + HTTPS）：`NGINX_CONF_NAME=nginx-servera-ssl.conf`
> - 服务器 B（域名+HTTPS 合并）：`NGINX_CONF_NAME=nginx-all-sites-ssl.conf`
> - IP 部署（无 SSL）：留空

---

## Phase 7b: SSL 证书 + 宝塔邮局申请（域名部署）

### 1. 申请 SSL 证书（acme.sh + Let's Encrypt）

```bash
# 创建 ACME 验证目录
mkdir -p /www/wwwroot/project/acme/.well-known/acme-challenge

# 安装 acme.sh
curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN}

# 同时申请两个域名（一张证书）
~/.acme.sh/acme.sh --issue \
  -d ${WWW_DOMAIN} \
  -d ${DOMAIN} \
  --webroot /www/wwwroot/project/acme/ \
  --server letsencrypt

# 安装证书到宝塔目录（自动续期 + reload）
mkdir -p /www/server/panel/vhost/cert/${WWW_DOMAIN}
~/.acme.sh/acme.sh --install-cert -d ${WWW_DOMAIN} --ecc \
  --key-file       /www/server/panel/vhost/cert/${WWW_DOMAIN}/privkey.pem \
  --fullchain-file /www/server/panel/vhost/cert/${WWW_DOMAIN}/fullchain.pem \
  --reloadcmd     'nginx -s reload'
```

### 2. 套用 SSL Nginx 配置

```bash
bash deploy.sh --nginx
# deploy.sh 根据 NGINX_CONF_NAME 自动选择 SSL 模式动态生成
```

### 3. 配置宝塔邮局

#### 方法一：宝塔邮局自建（Postfix + Dovecot + Rspamd）

1. **安装邮局**：宝塔面板 → 软件商店 → 搜索「邮局」→ 安装
2. **添加域名**：邮局管理 → 添加域名 `${DOMAIN}`
3. **DNS 记录**：

   | 类型 | 主机 | 值 | 说明 |
   |------|------|-----|------|
   | MX | @ | `${DOMAIN}` | 邮件路由 |
   | TXT | @ | `v=spf1 mx a ~all` | SPF 防伪造 |
   | TXT | `default._domainkey` | 见 DKIM 公钥 | 邮件签名验证 |
   | TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:admin@${DOMAIN}` | 邮件策略 |

4. **获取 DKIM 公钥**：

   ```bash
   cat /www/server/dkim/${DOMAIN}/default.pub
   ```

5. **创建邮箱账号**：邮局管理 → 添加邮箱 `noreply@${DOMAIN}`
6. **deploy.env 配置**：`SMTP_PASSWORD = 邮箱账号密码`

#### 方法二：第三方 SMTP 服务

| 服务商 | SMTP_HOST | SMTP_PORT | SMTP_USE_TLS |
|--------|-----------|-----------|--------------|
| QQ企业邮箱 | `smtp.exmail.qq.com` | 465 | false |
| Gmail | `smtp.gmail.com` | 587 | true |
| 阿里云邮箱 | `smtp.qiye.aliyun.com` | 465 | false |

### 4. 部署 SMTP 配置 + 重启

```bash
bash deploy.sh financial-api
systemctl restart financial-api
```

### 5. 验证

```bash
curl -sI https://${WWW_DOMAIN}/                 # 200
curl -sI https://${WWW_DOMAIN}/api/health        # 200 + JSON
curl -s https://${WWW_DOMAIN}/api/auth/send-code?email=test@${DOMAIN}
```
