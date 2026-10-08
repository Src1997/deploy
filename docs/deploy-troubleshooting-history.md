# 部署排障记录（历史）

> **Category**: Guide（人类排障档案，非规范约束）  
> **Source**: 自 `README.md` 附录迁出（2026-07-31）  
> **Scope**: 正式服务器 A/B 部署过程中的问题与修复；WSL 本地见 [wsl-local-deploy-issues.md](./wsl-local-deploy-issues.md)  
>   
> **⚠️ 历史文档说明**：本文档记录的修复涉及当时的工具链（如 `dist/scripts/` fallback、  
> `pack-financial-api.ps1` 等），这些工具已在本轮重构中统一为 `pack.ps1` + `config_loader.py`。  
> 文中提到的文件名和路径仅供历史参考。

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

---

> **注**：上文中的 `scripts/deploy-financial-api.sh` 已于 2026-08-31 泛化为 `scripts/deploy-python.sh`（通用 Python/FastAPI 部署钩子）。
> 历史记录中保留旧名以保持上下文准确性，当前文件名见 [AGENTS.md](../AGENTS.md) 目录结构。


---

### 17. 双服务器 crawler 共享 Redis 抢锁 → B 爬虫集体停摆（2026-09-07）

**问题**：服务器 B（103.100.211.12）`financial-api` 的财经日历爬虫停更。`fin_crawl_runs` 显示**全部 13 个爬虫任务**在 2026-09-02 09:03 集体停摆（calendar_events 最后 09:03:18，flash_news 最后 09:03:32），进程却都存活。

**根因（共享 Redis 多实例未隔离）**：
- 服务器 A（47.86.32.234）于 9/2 部署并启动了同一套 financial 全套服务；A 的 `.env` 中 `REDIS_URL`/`ARQ_REDIS_URL` 指向 B 的 Redis（deploy.env.server-a 的 `REDIS_HOST=103.100.211.12`，用于行情共享）。
- crawler 调度 leader 锁 `fin:crawler:scheduler:leader` 用 `settings.redis_url`（B Redis DB0），arq 队列 `financial:scripts` 用 `ARQ_REDIS_URL`（B Redis DB1）——**A/B 共用同一把锁 + 同一个队列**。
- A 的 scheduler 抢到锁 → B scheduler 9/2 起不再入队（进程活着但 0 产出）；B 的 arq worker 仍消费共享队列里 A 的任务，但 `crawl_run_id` 在 B 库不存在 → **0.01s 白干丢弃**。A 侧被 B worker 抢走一半任务空转 → pending 堆积 655、calendar_updown failed 192。

**次要瓶颈（A/B 都受影响，早于事故已存在）**：`request_interval_sec=2.0` 是进程级全局节流（`app/crawler/http/client.py` `_throttle` 单例），calendar_updown 每次抓近 7 天 ~196 个事件 × 每事件 1 次请求 = 392s > `runner.py` 300s 脚本超时 → **必超时**；`arq_max_jobs=4` 被慢任务占满后队列积压。

**修复**：
1. A 停爬虫止血：`systemctl stop+disable financial-crawler.service financial-worker.service`
2. B 夺回 leader：`systemctl restart financial-crawler.service`
3. 吞吐调优（两台 DB `fin_data_source_configs` source='crawler'，改后**重启 worker 生效**）：
   `request_interval_sec: 2.0 → 0.5`（上游实测 0.1~0.9s，2 req/s 安全）、`arq_max_jobs: 4 → 8`
4. A 独立恢复（**纯配置隔离，零代码改动**）——systemd drop-in（部署重写主 unit 不删）：
   - `/etc/systemd/system/financial-crawler.service.d/override.conf`：`REDIS_URL`/`ARQ_REDIS_URL` → B Redis `:6379/2`（锁与队列与 B 的 DB0/DB1 隔离）
   - `/etc/systemd/system/financial-worker.service.d/override.conf`：`ARQ_REDIS_URL` → DB2；`REDIS_URL` 保持 DB0（redis_bus 广播/实时推送不受影响）
5. 默认配置固化（防 seed 覆盖）：`seed_datasource_configs` 对非 None fixture 值做 **upsert 强制覆盖** → 已改本地 `financial/financial-api`：`app/db/fixtures/config/datasource.py` 与 `app/config/_crawler.py` 默认 `0.5`/`8`；A/B 库手 UPDATE 同步。

**验证**：B 锁在 DB0、A 锁在 DB2（`redis-cli -n 0/2 GET fin:crawler:scheduler:leader` 各自独立）；A/B 的 calendar_events（114/114）与 calendar_updown（~320/130）均恢复 success，互不干扰。

**架构约定（防再犯）**：
- 行情是"一分多"：B 为唯一上游行情（Finnhub WSS）leader，用单一 key 接数据，经 **B Redis DB0 Pub/Sub** 分发给 B 内 worker + 跨机 A（A 的 streaming 订阅 DB0）。此链路不得改动。
- 爬虫是"各自独立"：A/B 各自库、各自抓。**共享 Redis 实例时 crawler 的锁与队列必须按实例隔离**（不同 Redis DB 或不同 key/队列名）；新增第二台部署 crawler 前必须检查 `REDIS_URL`/`ARQ_REDIS_URL` 不与既有实例冲突。

**常用检查**：
```bash
# B 服务器
redis-cli -a <pw> -n 0 GET fin:crawler:scheduler:leader   # B crawler 锁（DB0）
# A 服务器（锁在 B Redis DB2）
redis-cli -a <pw> -h 103.100.211.12 -n 2 GET fin:crawler:scheduler:leader
# 运行记录
PGPASSWORD=root1.0 psql -h localhost -U root -d quant_zc \
  -c "SELECT job_name,status,count(*),max(started_at) FROM fin_crawl_runs WHERE started_at>now()-interval '24 hours' GROUP BY job_name,status ORDER BY job_name;"
# 服务
systemctl is-active financial-api financial-crawler financial-worker financial-streaming
```


---

### 18. 双服务器故障日：A 到期停机 / B 证书过期 + VM 时钟漂移 + 部署工具箱 9 处修复（2026-10-08）

**现象**：A（47.86.32.234，阿里云香港）与 B（103.100.211.12，亿速云香港）网站均无法访问；本地虚拟机（192.168.31.166）爬虫持续报 SSL 错误。

**根因（三台机器、三个独立原因）**：
1. **A**：云服务器到期停机。22/80/443/8888 全端口 Connection timed out（非 refused），从本地和 B 双向探测均不可达，traceroute 第 7 跳后丢包 —— 云主机停机断网的典型形态。**需去阿里云控制台续费，脚本无需改动**（恢复后直接用同一套 dist 部署）。
2. **B**：SSL 证书过期（TrustAsia LiteSSL，notAfter=2026-10-06，过期 2 天）。nginx/后端服务全部正常。**根因是设计有 acme-challenge 验证路径（generate-nginx.py 模板里有）但线上从未配置，也没有任何自动续签任务** —— 证书靠手工申请，必然过期。
3. **VM**：系统时钟慢 22 天（停在 9-16）。chrony 声称"已同步、偏差 0.0016s"但 Ref time 也是 9-16 —— canonical NTS 源在开机早期的同步被 makestep 1 3 窗口限制吞掉后一直未再步进。连锁反应：爬虫 SSL 报 `certificate is not yet valid`（时钟在过去，远端证书"尚未生效"）。

**修复（B 服务器）**：
- 新增 `scripts/ops/06-fix-ssl-cert.sh`（A/B 通用，幂等）：备份旧证书 → 建 webroot `/www/wwwroot/project/acme` → nginx 80 块插入 `/.well-known/acme-challenge/` → 装 acme.sh → Let's Encrypt 签发（SAN: 主域+www+mail）→ 安装到宝塔证书目录（多目录同步）→ `--reloadcmd` 挂自动 reload → acme.sh 自带 cron（每日 0/6/12/18 点检查，到期前自动续）。
- B 上已执行完毕：新证书有效期至 2027-01-06，线上握手验证通过，www/主域/mail 三个证书目录全部更新。

**修复（VM）**：
- 时钟：停 chrony → `timedatectl set-time` 手动校准 → 重启 chrony（重开 makestep 窗口）。`rtcsync` 已把正确时间写回 RTC（下次开机不再漂移）。
- pip：`/root/.pip/pip.conf` 的阿里镜像对家宽出口 IP 返回 403 风控（清华同样 403），换腾讯源 `https://mirrors.cloud.tencent.com/pypi/simple`（0.28s，9.1MB/s）。**新服务器初始化时注意：国内家宽/小厂出口 IP 可能被阿里、清华镜像风控，腾讯/中科大可用**。

**部署工具箱修复（审查发现 9 处高危，全部实测验证）**：
| # | 文件 | 问题 | 修法 |
|---|---|---|---|
| 1 | lib/load-deploy-env.sh | ops/ 子目录脚本找不到 dist 根的 deploy.env | 搜索链补 `../../` 两档 |
| 2 | ops/04-setup-server.sh | lib 路径错（`$SCRIPT_DIR/lib`，实际在 `../../lib`）→ require_deploy_secrets 未定义 → 必然 exit 1 | 三档路径搜索 + 找不到 fail fast |
| 3 | ops/03-check-components.sh | deploy.env 路径错 → Redis 有密码时误判缺失 → 卡死 04 | 搜索链修正（../../deploy.env） |
| 4 | ops/03-check-components.sh | Supervisor 当必需组件，但 B/VM 均为 systemd 形态 → 03 退出 1 | 降级为可选（warn），部署链路本就自动回落 systemd |
| 5 | ops/04-setup-server.sh | 宝塔 LSB 服务（/etc/init.d/nginx → generator.late unit）被误判为"系统 nginx 抢端口" | generator unit 回查 init.d 是否含 /www/server |
| 6 | lib/service-ops.sh | `supervisorctl status <svc>` 退出码判归属 → FATAL/STOPPED 误判为不在 Supervisor → 回退已被删除的 systemd unit → 服务全挂却报成功 | 引入 `_svc_in_supervisor`（全量列表匹配，与 deploy-python.sh 一致），替换 8 处 |
| 7 | lib/deploy-kinds.sh | 钩子失败被 `\|\| warn` 吞掉仍报"代码已同步"；4 处 `tar xzf` 无判错（if 条件上下文 set -e 失效） | 钩子失败 return 1；解压全部判错 |
| 8 | lib/backup-rollback.sh | 回滚 `rm -rf` 整目录再解压：删掉 .venv/data（备份包里没有）→ Python 服务起不来；解压失败=代码全损 | 只清代码部分（排除 .env/.venv/logs/data，与部署路径一致），case 补 python/java/go/nodejs |
| 9 | lib/common.sh + build.ps1 | 新鲜度校验 `tr -d '[:space:]'` 挤掉日期中间空格 → date 解析失败 → 告警永久失效；构建全失败仍刷新 dist 并上传旧包 | 保留日期空格（只去 CR/BOM/首尾）；`$built.Count -eq 0` 时中止不上传 |

**VM 实测记录（2026-10-08）**：03 退出 0（Redis 密码认证通过）；04 退出 0（配置加载、双库幂等、目录创建）；`--status` systemd 判定正确；official-site 前端部署+回滚 OK；错误密码注入 → 退出码 1（不再假成功）；financial-api 端到端部署全链路 OK（309M 备份 / .env 保护 / 腾讯源装依赖 / DB 迁移 / 4 服务重启 / 健康检查通过）。

**遗留（下轮处理）**：
- dist/packages 里的包是 2026-08~09 的旧包，新服务器部署前必须重新 `build.ps1`；
- dist 根目录"只覆盖不清理"（残留 deploy-financial-api.sh 已手工清，根治需白名单重建）；
- 前端包不写 VERSION、无 sha256 清单 → "上传即新鲜"无法自证（中危 M2/M8）；
- `db_backup` 的 pg_dump 硬编码 127.0.0.1 未用 PG_HOST/PG_PORT（中危 M9）；
- tests/verify-baota-services.sh 等测试脚本硬编码生产密码且已入库（中危，建议轮换）。
