    # 手动部署

> **Category**: Guide

当自动化脚本（`build.ps1` / `deploy.sh`）不可用、失败排查、或需要精细控制单步操作时，参照本文逐项手动执行。

> **正常流程**：首次部署用 [完整部署步骤](./deploy-from-scratch.md)，增量发版用 [增量发版与回滚](./incremental-release.md)。本文仅在脚本异常或需要手动干预时使用。

## ★通道现状（2026-10-23 更新，先读这段）

**B/C 两台已全面宝塔托管**（v2「宝塔就全宝塔」），与本文部分章节的历史背景不同：

| 层 | 现行做法（宝塔通道，主力） | 本文旧内容（native 应急通道，冻结维护） |
|----|---------------------------|----------------------------------------|
| Python 主服务 | 宝塔 Python 项目（面板启停/日志） | systemd 单元 → **B/C 已全部清除，禁双轨**（重启抢端口实证） |
| 伴随服务 | 宝塔 supervisor 插件 | systemd |
| 前端 | 宝塔 HTML 站点（面板注册） | generate-nginx 直写 |
| 站点 conf | `vhost/nginx/html_<站点名>.conf`（**必须带 html_ 前缀**） | `vhost/nginx/default.conf` |
| 路由调整 | 面板 → 站点设置 → 配置文件 | 手编 default.conf |

- **各项目特殊配置、conf 位置、参数调整**：见 `project-configs/<项目>/DEPLOY-NOTES.md`（financial / deepquant / official-site）。
- 部署后符合性自检：`BASE_DOMAIN=<生产域名> bash scripts/tools/check-deploy.sh`（40 项）。
- 服务器上手工调面板 API：`eval "$(grep -E '^BAOTA_(PANEL_URL|API_KEY)=' /www/wwwroot/project/deploy.env.server-X)"; export BAOTA_PANEL_URL BAOTA_API_KEY; python3 /www/wwwroot/project/uploads/dist/channels/baota-api.py <cmd>`（⚠️eval 后必须 export）。
- ⚠️**在宝塔托管的机器上执行本文 systemd 章节 = 制造双轨**，仅在 native 应急通道机器（如 VM 试点）使用。

## 按通道的手动部署文档（分流入口）

三通道各自有独立的手动部署文档，**优先按通道分流**；本文保留跨通道通用的
部分（.env 生成、数据库操作、旧链路细节与常见修复场景）：

| 通道 | 文档 | 状态 |
|------|------|------|
| **baota（主力）** | [manual-deploy-baota.md](./manual-deploy-baota.md) | ✅ B/C 现役，面板对象落位 + API 姿势 + 红线 |
| **native（应急）** | [manual-deploy-native.md](./manual-deploy-native.md) | ⚠️ 冻结维护，systemd + generate-nginx |
| **docker（试点）** | [manual-deploy-docker.md](./manual-deploy-docker.md) | ⚠️ MVP，容器 + 宿主 nginx 收口，先单组件试点 |
| 整体架构 / 部署逻辑可视化 | [../deploy-architecture.html](../deploy-architecture.html) | 流程图 + kind×channel 矩阵 + 思维导图 |
| 新项目接入（写 project.toml） | [project-configs/PROJECT-TOML-GUIDE.md](../../project-configs/PROJECT-TOML-GUIDE.md) | v2 意图模型 + 三通道字段落地 + SOP |

## 目录

- [按通道的手动部署文档（分流入口）](#按通道的手动部署文档分流入口)
- [前置条件](#前置条件)
- [手动部署前端（静态站点）](#手动部署前端静态站点)
- [手动部署 financial-api](#手动部署-financial-api)
- [手动部署 QuantDinger 后端](#手动部署-quantdinger-后端)
- [手动配置 Nginx](#手动配置-nginx)
- [手动安装 systemd 服务](#手动安装-systemd-服务)
- [手动数据库操作](#手动数据库操作)
- [手动生成 .env](#手动生成-env)
- [验证清单](#验证清单)
- [常见手动修复场景](#常见手动修复场景)

---

## 前置条件

| 项 | 要求 |
|----|------|
| 服务器 | root 权限，宝塔已安装 Nginx / PostgreSQL / Redis |
| 本地 | 已构建产物（`dist/packages/*.tar.gz`）或可直接 `scp` 源码 |
| deploy.env | 已填写 `PG_PASSWORD` / `REDIS_PASSWORD`（[模板](../../deploy.env.example)） |
| 数据库 | `quant_zc` / `quantdinger` 已创建（[Phase 3](./deploy-from-scratch.md#phase-3-创建数据库和目录ssh)） |

> 手动部署前建议先跑 `bash detect-status.sh` 确认环境就绪。

---

## 手动部署前端（静态站点）

适用于 `financial-web`、`financial-admin`、`official-site`、`deepquant-web`。

### 1. 本地构建

```powershell
cd D:\Workspace\deploy
.\scripts\build.ps1 financial-web
# 产物：dist\packages\financial-web-dist.tar.gz
```

### 2. 上传并解压

```bash
# 上传
scp dist/packages/financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/

# SSH 登录后
cd /www/wwwroot/project
TARGET=financial/financial-web/dist    # 按项目替换路径

# 备份当前版本
if [ -d "$TARGET" ] && [ -n "$(ls -A $TARGET 2>/dev/null)" ]; then
    mkdir -p backup/financial-web
    tar czf backup/financial-web/$(date +%Y%m%d-%H%M%S).tar.gz -C financial/financial-web dist
fi

# 清理 + 解压
rm -rf "$TARGET"
mkdir -p "$TARGET"
tar xzf uploads/dist/packages/financial-web-dist.tar.gz -C "$TARGET"
```

### 3. 重载 Nginx

```bash
nginx -t && nginx -s reload
```

### 各前端部署路径速查

| 项目 | deployPath（相对 `PROJECT_BASE`） |
|------|-----------------------------------|
| financial-web | `financial/financial-web/dist` |
| financial-admin | `financial/financial-admin/dist` |
| official-site | `official-site/dist` |
| deepquant-web | `deepquant/web/dist` |

---

## 手动部署 financial-api

### 完整流程（9 步）

以下步骤对应 `deploy-python.sh` 的内部流程，可逐项手动执行。

#### Step 1: 上传代码包

```bash
scp dist/packages/financial-api-*.tar.gz root@服务器IP:/www/wwwroot/project/financial/financial-api/
```

#### Step 2: 备份当前版本

```bash
PKG_DIR=/www/wwwroot/project/financial/financial-api/package
BACKUP_DIR=/www/wwwroot/project/financial/financial-api/backup
TS=$(date +%Y%m%d-%H%M%S)

if [ -d "$PKG_DIR" ]; then
    mkdir -p "$BACKUP_DIR/$TS"
    # 备份代码（排除运行时产物）
    cd "$PKG_DIR" && tar cf - \
        --exclude='./.venv' --exclude='./logs' \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='*.egg-info' \
        . | (cd "$BACKUP_DIR/$TS" && tar xf -)
    # 单独备份 .env
    [ -f "$PKG_DIR/.env" ] && cp "$PKG_DIR/.env" "$BACKUP_DIR/$TS/.env"
    echo "[OK] 备份完成: $BACKUP_DIR/$TS"
fi
```

#### Step 3: 解压新代码

```bash
DEPLOY_ROOT=/www/wwwroot/project/financial/financial-api
ARCHIVE=$(ls -t "$DEPLOY_ROOT"/financial-api-*.tar.gz 2>/dev/null | head -1)

# 临时解压
TMP=$(mktemp -d)
tar xzf "$ARCHIVE" -C "$TMP"
SRC_DIR="$TMP/package"
[ ! -d "$SRC_DIR" ] && SRC_DIR=$(find "$TMP" -maxdepth 1 -type d ! -path "$TMP" | head -1)

# 保护生产 .env
ENV_BAK=""
if [ -f "$PKG_DIR/.env" ]; then
    ENV_BAK=$(mktemp)
    cp "$PKG_DIR/.env" "$ENV_BAK"
fi

# 清理旧代码（保留 .env / .venv / logs）
find "$PKG_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name '.venv' ! -name 'logs' \
    -exec rm -rf {} + 2>/dev/null || true

# 删除包内可能携带的 .env（防止污染生产）
rm -f "${SRC_DIR}/.env" 2>/dev/null || true

# 复制新代码
cp -a "${SRC_DIR%/}/." "$PKG_DIR/"

# 恢复 .env
if [ -n "$ENV_BAK" ]; then
    cp "$ENV_BAK" "$PKG_DIR/.env"
    rm -f "$ENV_BAK"
fi

# 清理缓存
find "$PKG_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$PKG_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true

rm -rf "$TMP"
echo "[OK] 代码已同步到 $PKG_DIR"
```

#### Step 4: 生成 .env（仅首次）

```bash
ENV_FILE="$PKG_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[*] 生成 .env（首次部署）..."
    # 参见下方「手动生成 .env」章节
    # 使用 assets/financial-api.env.example 模板 + sed 渲染占位符
else
    echo "[OK] .env 已存在，保留"
fi
```

#### Step 5: 创建虚拟环境（仅首次）

```bash
VENV_DIR="$PKG_DIR/.venv"

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    echo "[OK] 虚拟环境已创建"
else
    echo "[OK] 虚拟环境已存在"
fi
```

#### Step 6: 安装依赖

```bash
cd "$PKG_DIR"
"$VENV_DIR/bin/pip" install -e "." -q
echo "[OK] 依赖已安装"
```

#### Step 7: 数据库备份 + 迁移 + 种子

```bash
# 迁移前备份
DB_NAME="quant_zc"
mkdir -p "$PKG_DIR/logs/db-backups"
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost "$DB_NAME" \
    | gzip > "$PKG_DIR/logs/db-backups/${TS}.sql.gz"

# 迁移
"$VENV_DIR/bin/alembic" upgrade head
echo "[OK] 迁移完成"

# 种子数据
"$VENV_DIR/bin/python" -m app.db.seed
echo "[OK] 种子数据已加载"
```

#### Step 8: 安装 systemd 服务

参见 [手动安装 systemd 服务](#手动安装-systemd-服务)。

#### Step 9: 重启 + 健康检查

```bash
systemctl restart financial-api financial-crawler financial-worker financial-streaming
sleep 3

# 健康检查
curl -sf http://127.0.0.1:5001/api/health | python3 -m json.tool

# 服务状态
systemctl is-active financial-api financial-crawler financial-worker financial-streaming
```

---

## 手动部署 QuantDinger 后端

### Step 1: 上传 + 解压

```bash
PKG_DIR=/www/wwwroot/project/deepquant/backend/package
ARCHIVE=uploads/dist/packages/deepquant-backend-*.tar.gz

# 备份 .env
[ -f "$PKG_DIR/.env" ] && cp "$PKG_DIR/.env" "$PKG_DIR/.env.bak"

# 清理旧代码（保留 .env / .venv / logs / data）
find "$PKG_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
    -exec rm -rf {} + 2>/dev/null || true

tar xzf "$ARCHIVE" -C "$PKG_DIR"

# 恢复 .env
[ -f "$PKG_DIR/.env.bak" ] && cp "$PKG_DIR/.env.bak" "$PKG_DIR/.env" && rm -f "$PKG_DIR/.env.bak"
```

### Step 2: 虚拟环境 + 依赖

```bash
VENV_DIR="$PKG_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip -q
fi
"$VENV_DIR/bin/pip" install -r "$PKG_DIR/requirements.txt" -q
```

### Step 3: 首次生成 .env

```bash
if [ ! -f "$PKG_DIR/.env" ]; then
    # 参见下方「手动生成 .env」章节，使用 assets/deepquant.env.example
    echo "[*] 需生成 .env，参见手动生成章节"
fi
```

### Step 4: 安装 systemd + 启动

```bash
# 安装服务（参见下方 systemd 章节）
cp assets/systemd/quantdinger-backend.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable quantdinger-backend

# 创建必要目录
mkdir -p "$PKG_DIR/logs" "$PKG_DIR/data/memory"

# 启动
systemctl restart quantdinger-backend
sleep 2
curl -sf http://127.0.0.1:5000/api/health | python3 -m json.tool
```

---

## 手动配置 Nginx

> ★宝塔通道下站点 conf 为 `vhost/nginx/html_<站点名>.conf`（html_ 前缀必须，面板功能按此读取），路由调整优先走面板「配置文件」编辑器。下述 `default.conf` 方式仅适用于 native 应急通道（default.conf 现为面板默认站点兜底，勿放业务路由）。

### 方式一：动态生成（native 应急通道）

```bash
# 从 TOML 配置动态生成 Nginx 配置
python3 scripts/tools/generate-nginx.py \
    --mode ssl-combined \
    --domain example.com \
    --www-domain www.example.com \
    --project-base /www/wwwroot/project \
    --output /www/server/panel/vhost/nginx/default.conf

nginx -t && nginx -s reload
```

### 方式二：手动编辑 Nginx 配置

```bash
NGINX_CONF=/www/server/panel/vhost/nginx/default.conf

# 备份
cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

# 编辑
vim "$NGINX_CONF"
```

核心 location 块（按最长前缀排序）：

```nginx
# WebSocket 必须在 /api/ 之前
location ^~ /api/ws {
    proxy_pass http://127.0.0.1:5001/api/ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 86400;
}

location ^~ /api/ {
    proxy_pass http://127.0.0.1:5001/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location ^~ /quant/api/ {
    proxy_pass http://127.0.0.1:5000/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

location ^~ /quant/ {
    alias /www/wwwroot/project/deepquant/web/dist/;
    try_files $uri $uri/ /quant/index.html;
}

location ^~ /admin/ {
    alias /www/wwwroot/project/financial/financial-admin/dist/;
    try_files $uri $uri/ /admin/index.html;
}

location ^~ /qd/ {
    alias /www/wwwroot/project/official-site/dist/;
    try_files $uri $uri/ /qd/index.html;
}

location / {
    root /www/wwwroot/project/financial/financial-web/dist;
    try_files $uri $uri/ /index.html;
}
```

> **规则**：`location ^~`（精确前缀）优先级高于 `location /`，WebSocket location 必须在普通代理之前。

---

## 手动安装 systemd 服务

> ★**仅限 native 应急通道**（冻结维护）。宝塔托管的机器（B/C）**禁止**安装这些单元——systemd 与宝塔 Python 项目/supervisor 双轨会抢端口（Restart=always 反抢实证，崩溃循环 2284 次）。B/C 上的旧单元已于 2026-10-23 清除。v2 下服务模板已迁至 `assets/systemd/`（configs/ 目录已废弃）。

### financial-api 系列（4 个服务）

```bash
# 服务文件在 dist/assets/systemd/
CONFIGS=/www/wwwroot/project/uploads/dist/assets/systemd

for svc in financial-api financial-crawler financial-worker financial-streaming; do
    cp "$CONFIGS/${svc}.service" /etc/systemd/system/
done

systemctl daemon-reload
systemctl enable financial-api financial-crawler financial-worker financial-streaming
```

### QuantDinger 后端

```bash
cp "$CONFIGS/quantdinger-backend.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable quantdinger-backend
```

### 服务端口与用途

| 服务 | 端口 | 用途 |
|------|------|------|
| financial-api | 5001 | FastAPI 主服务（API + WebSocket） |
| financial-crawler | — | 爬虫调度器（enqueue） |
| financial-worker | — | arq 异步任务 Worker |
| financial-streaming | — | 实时行情推送 |
| quantdinger-backend | 5000 | QuantDinger Flask API |

---

## 手动数据库操作

### 创建数据库

```bash
su - postgres -c "psql -c \"CREATE DATABASE quant_zc;\""
su - postgres -c "psql -c \"CREATE DATABASE quantdinger;\""
su - postgres -c "psql -c \"ALTER USER root WITH PASSWORD '$PG_PASSWORD';\""
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE quant_zc TO root;\""
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE quantdinger TO root;\""
```

### 手动迁移

```bash
# financial-api
cd /www/wwwroot/project/financial/financial-api/package
.venv/bin/alembic upgrade head
.venv/bin/alembic current    # 查看当前版本

# 种子数据
.venv/bin/python -m app.db.seed
```

### 手动备份与恢复

```bash
# 备份
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc \
    | gzip > /root/backup_quant_zc_$(date +%Y%m%d).sql.gz

# 恢复
gunzip -c /root/backup_quant_zc_20260728.sql.gz \
    | PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc
```

---

## 手动生成 .env

### financial-api

```bash
PKG_DIR=/www/wwwroot/project/financial/financial-api/package
TEMPLATE=/www/wwwroot/project/uploads/dist/assets/financial-api.env.example

# 生成 AUTH_SECRET_KEY
AUTH_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")

# 从 deploy.env 读取密码（或手动填入）
PG_PASSWORD="你的PG密码"
REDIS_PASSWORD="你的Redis密码"
SMTP_PASSWORD="你的SMTP密码"
DOMAIN="example.com"
WWW_DOMAIN="www.example.com"
APP_NAME="MyApp"
SERVER_IP="<服务器IP>"  # B=103.100.211.12 / C=177.4.41.137；旧 A(121.41.44.216) 已于 2026-10-22 废弃

sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
    -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
    -e "s|__AUTH_SECRET_KEY__|${AUTH_KEY}|g" \
    -e "s|__WEB_PATH__|/|g" \
    -e "s|__SERVER_IP__|${SERVER_IP}|g" \
    -e "s|__SMTP_PASSWORD__|${SMTP_PASSWORD}|g" \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__WWW_DOMAIN__|${WWW_DOMAIN}|g" \
    -e "s|__APP_NAME__|${APP_NAME}|g" \
    "$TEMPLATE" > "$PKG_DIR/.env"

chmod 600 "$PKG_DIR/.env"
```

### QuantDinger 后端

```bash
PKG_DIR=/www/wwwroot/project/deepquant/backend/package
TEMPLATE=/www/wwwroot/project/uploads/dist/assets/deepquant.env.example

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
ADMIN_PASSWORD="你的管理员密码"  # 或随机生成: python3 -c "import secrets; print(secrets.token_urlsafe(16))"

sed -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
    -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
    -e "s|__SECRET_KEY__|${SECRET_KEY}|g" \
    -e "s|__ADMIN_PASSWORD__|${ADMIN_PASSWORD}|g" \
    -e "s|__SERVER_IP__|${SERVER_IP}|g" \
    -e "s|__FRONTEND_URL__|http://${SERVER_IP}|g" \
    "$TEMPLATE" > "$PKG_DIR/.env"

chmod 600 "$PKG_DIR/.env"
```

### .env 增量同步（补缺失变量）

当 `.env.example` 新增了变量但 `.env` 未同步时：

```bash
# 只追加 .env 中不存在的 key，不覆盖已有值
example="$PKG_DIR/.env.example"
env_file="$PKG_DIR/.env"

while IFS='=' read -r key val; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    key=$(echo "$key" | xargs)
    # 跳过含占位符的值
    [[ "$val" =~ __[A-Z_]+__ ]] && continue
    # 检查是否缺失
    if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
        echo "$key=$val" >> "$env_file"
        echo "  + $key=$val"
    fi
done < "$example"
```

---

## 验证清单

手动部署完成后，逐项验证：

```bash
# 1. 服务状态
systemctl is-active financial-api financial-crawler financial-worker financial-streaming quantdinger-backend nginx

# 2. 端口监听
ss -tlnp | grep -E '5000|5001|80|443'

# 3. 健康检查
curl -sf http://127.0.0.1:5001/api/health | python3 -m json.tool    # financial-api
curl -sf http://127.0.0.1:5000/api/health | python3 -m json.tool    # QuantDinger

# 4. Nginx 配置
nginx -t

# 5. 前端页面
curl -sI http://127.0.0.1/              | head -1   # 200
curl -sI http://127.0.0.1/admin/        | head -1   # 200
curl -sI http://127.0.0.1/qd/           | head -1   # 200
curl -sI http://127.0.0.1/quant/        | head -1   # 200

# 6. API 代理
curl -sf http://127.0.0.1/api/health     | python3 -m json.tool
curl -sf http://127.0.0.1/quant/api/health | python3 -m json.tool

# 7. 导航 API（验证种子数据）
curl -sf http://127.0.0.1:5001/api/navigation/menu | python3 -m json.tool | head -20

# 8. Redis 连接
redis-cli -h localhost -p 6379 -a "$REDIS_PASSWORD" ping

# 9. PostgreSQL 连接
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc -c "SELECT 1;"

# 10. 磁盘空间
df -h /www/wwwroot
```

---

## 常见手动修复场景

### 场景 1: deploy.sh 报 "未找到 tar 包"

```bash
# 检查包是否存在
ls -la /www/wwwroot/project/uploads/dist/packages/

# 若缺失，重新上传
scp dist/packages/financial-api-*.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/
```

### 场景 2: pip install 失败（网络/依赖冲突）

```bash
PKG_DIR=/www/wwwroot/project/financial/financial-api/package
VENV_DIR="$PKG_DIR/.venv"

# 重建虚拟环境
rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip -q
cd "$PKG_DIR"
"$VENV_DIR/bin/pip" install -e "." -q
```

### 场景 3: Alembic 迁移失败

```bash
# 查看当前版本
.venv/bin/alembic current

# 回退一个版本
.venv/bin/alembic downgrade -1

# 查看迁移历史
.venv/bin/alembic history --verbose

# 如果数据库损坏，从备份恢复
gunzip -c logs/db-backups/TIMESTAMP.sql.gz | PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc
```

### 场景 4: 服务启动失败（端口占用）

```bash
# 查找占用进程
ss -tlnp | grep 5001
# 或
lsof -i :5001

# 终止后重启
kill <PID>
systemctl restart financial-api
```

### 场景 5: Nginx 配置测试失败

```bash
# 查看具体错误
nginx -t

# 回滚到上一个配置
NGINX_CONF=/www/server/panel/vhost/nginx/default.conf
LATEST_BAK=$(ls -t "${NGINX_CONF}.bak."* 2>/dev/null | head -1)
cp "$LATEST_BAK" "$NGINX_CONF"
nginx -t && nginx -s reload
```

### 场景 6: .env 被包内文件覆盖

```bash
# 从备份恢复
BACKUP_DIR=/www/wwwroot/project/financial/financial-api/backup
LATEST=$(ls -dt "$BACKUP_DIR"/*/ 2>/dev/null | head -1)
cp "${LATEST}.env" /www/wwwroot/project/financial/financial-api/package/.env
chmod 600 /www/wwwroot/project/financial/financial-api/package/.env
systemctl restart financial-api
```

### 场景 7: deploy.sh 锁文件未释放

```bash
# 删除锁文件
rm -f /tmp/fin-deploy/deploy.lock
# 重新执行部署
```
