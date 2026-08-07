# 部署排障记录（历史）

> **Category**: Guide（人类排障档案，非规范约束）  
> **Source**: 自 `README.md` 附录迁出（2026-07-31）  
> **Scope**: 正式服务器 A/B 部署过程中的问题与修复；WSL 本地见 [wsl-local-deploy-issues.md](./wsl-local-deploy-issues.md)

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

### 16. 服务器 B 导航残留 + 废弃表未清理（2026-08-06）

**问题**：服务器 B 部署后，新增的导航模块不显示，已移除的旧模块仍残留在页面上。同时发现 4 张已弃用的数据库表仍然存在。

**根因（三重缺陷）**：

1. **Seed 仅增不减**：`seed_navigation_nodes` 此前是纯 insert-only 逻辑——只插入新节点，从不删除已从 fixture 移除的废弃节点。服务器 B 从 squash baseline 初始化后从未执行过清理迁移，导致 10 个废弃节点（`ai-analysis`、`market-data`、`strategy-lab`、`broker-hub`、`system`、`product`、`market-legacy`、`news-legacy`、`signal`、`more`）残留。

2. **条件式 Drop Table 被跳过**：`i5d6e7f8a9b0` 迁移中的 `op.drop_table` 是有条件的（检查表是否存在），在服务器 B 上迁移被 stamp 而非 run，导致 4 张废弃表（`fin_brokers`、`fin_key_strength_items`、`fin_key_strength_rankings`、`fin_rights_cases`）未被物理删除。

3. **app_config JSON 过时**：`fin_app_configs` 中 `navigation` 命名空间的 `menu_permission_map` 和 `feature_flags` 仍引用已移除的节点 ID，且缺少新增的 `quant-trading` 及首页 feed 节点的配置。

**修复（一次性 Alembic data + schema migration）**：

| 文件 | 修复内容 |
|------|----------|
| `alembic/versions/q2r3s4t5u6v7_cleanup_deprecated_tables_nav_and_config.py` | 新增迁移：Drop 4 张废弃表 + Delete 10 个废弃导航节点 + Upsert 正确的 `menu_permission_map` / `feature_flags` JSON |
| `app/db/seeders/mock.py` | `seed_navigation_nodes` 增加 `obsolete_node_ids` 清理逻辑，防止未来再次残留 |
| `app/db/fixtures/config/app.py` | 补全 `quant-trading` 及首页 feed 节点的权限与开关配置 |

**部署基础设施改进（deploy 仓库）**：

| 文件 | 修复内容 |
|------|----------|
| `scripts/build.ps1` | `Copy-DeployAssets` 增加 `deploy-financial-api.sh` 拷贝到 `dist/scripts/`，作为归档缺失钩子时的 fallback |
| `scripts/deploy.sh` | `deploy_all()` 硬编码 "5 个项目" → `${#PROJECTS[@]}` 动态值 |
| `scripts/deploy-financial-api.sh` | `db_backup` 从 `.env` 动态读取 `POSTGRES_DB`（不再硬编码 `quant_zc`）；部署后增加导航 API 验证（`/api/navigation/menu` 返回节点数 > 0） |
| `README.md` | 项目概览表 + URL 路由表补充 `financial-admin` |

**教训**：
- Seed 脚本不能纯 insert-only，必须包含废弃数据清理逻辑（或通过 Alembic data migration 保证）。
- 条件式 DDL 迁移在 stamp-only 场景下不安全，重要清理应写独立的幂等迁移。
- 部署后验证不能只检查 `/api/health`，还应验证关键业务 API（如导航菜单）返回预期数据。

### 4. 量化交易模块不显示 — role_permissions 缺少 home 权限码（2026-08-06）

**问题**：服务器 B 部署后，「量化交易」导航节点（`quant-trading`）在顶栏不显示，其他首页 feed 锚点节点也缺失。

**根因**：

1. **Seed fixture 与契约 SSOT 不一致**：`app/db/fixtures/config/app.py` 中 `auth/role_permissions` 的 `trader`/`analyst`/`viewer` 角色缺少 `home` 权限码，而 `navigation-permissions.json`（SSOT）和前端 `DEFAULT_ROLE_PERMISSIONS` 均包含 `home`。

2. **迁移 `p1q2r3s4t5u6` 在服务器 B 被跳过**：该迁移设计为"若行不存在则跳过"（依赖后续 seed 插入正确值），但 seed fixture 本身就是错的。服务器 B 从 squash baseline stamp 初始化时，该迁移未实际执行。

3. **清理迁移 `q2r3s4t5u6v7` 未覆盖 `role_permissions`**：该迁移修复了 `menu_permission_map` 和 `feature_flags`，但遗漏了 `role_permissions` 的 `home` 权限码缺失问题。

**权限链路分析**：

```
quant-trading 节点
  → menu_permission_map["quant-trading"] = "home"  （需要 home 权限）
  → role_permissions["trader"] = ["trade","market","news","signals"]  ← 缺少 "home"！
  → compute_allowed_menu_ids("trader") 过滤掉 quant-trading
  → allowedMenuIds 不含 quant-trading
  → 前端 resolver 不渲染该节点
```

**修复**：

| 文件 | 修复内容 |
|------|----------|
| `app/db/fixtures/config/app.py` | `role_permissions` fixture 补全 `home` 权限码（trader/analyst/viewer），与 SSOT 对齐 |
| `financial-web/packages/contracts/fixtures/system-runtime-config.json` | MSW fixture 同步补全 `home` + 补全 `feature_flags` 缺失的 quant-trading 及首页 feed 节点 |
| `alembic/versions/r3s4t5u6v7w8_fix_role_permissions_missing_home.py` | 新增迁移：幂等修复生产 `auth/role_permissions`，补全 `home` 权限码 |
| `scripts/deploy-financial-api.sh` | 部署后增加 `quant-trading` 可见性验证（检查 `allowedMenuIds` 包含 `quant-trading`） |

**教训**：
- Seed fixture 必须与契约 SSOT 保持一致，任何权限码变更需同步更新 fixture。
- 迁移"若行不存在则跳过"的 guard clause 不安全——如果 fixture 本身就是错的，seed 会插入错误值且不会被修正。
- 数据迁移应覆盖所有关联配置项（`role_permissions` + `menu_permission_map` + `feature_flags` 三者必须同步）。

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
