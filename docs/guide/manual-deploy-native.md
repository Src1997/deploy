# 手动部署 · 原生通道（native，冻结维护）

> **Category**: Guide
>
> 适用：`DEPLOY_CHANNEL=native`（或未设置通道且未开 `BAOTA_MODE` 的旧机）。
> **状态：冻结维护**——仅供未迁移宝塔的服务器（如 VM 试点、A 类应急机）重部署使用，
> 不新增功能；全部服务器迁移宝塔后本通道整体退役。
> 所有权：**systemd（服务守护）+ 宿主 nginx（路由收口）**，禁止调面板 API。
> ⚠️ 在宝塔托管的机器（B/C）上执行本文 = 制造双轨，**严禁**。

## 目录

- [前置条件](#前置条件)
- [手动部署前端](#手动部署前端)
- [手动部署 Python 后端](#手动部署-python-后端)
- [手动安装 systemd 服务](#手动安装-systemd-服务)
- [路由（generate-nginx）](#路由generate-nginx)
- [验证清单](#验证清单)
- [常见修复场景](#常见修复场景)

---

## 前置条件

| 项 | 要求 |
|----|------|
| systemd | 任何现代发行版 |
| nginx | 宿主任意方式安装；`nginx -t` / reload 用 root |
| Python | python3 + python3-venv（宿主 venv：deploy_path/.venv） |
| PG / Redis | 已创建库与密码（[Phase 3](./deploy-from-scratch.md#phase-3-创建数据库和目录ssh)） |
| deploy.env | `deploy.env.server-X`（`PG_PASSWORD` / `REDIS_PASSWORD`；deepquant 另需 `MCP_AGENT_TOKEN`） |
| systemd 模板 | `assets/systemd/*.service`（随包上传到 `uploads/dist/assets/systemd/`） |

---

## 手动部署前端

native 通道前端落点就是 TOML `deploy_path`（无站点注册），流程与宝塔通道差异仅在路由：

```bash
# 本地打包
.\scripts\build.ps1 financial-web
# 上传
scp dist/packages/financial-web-dist.tar.gz root@服务器IP:/www/wwwroot/project/uploads/dist/packages/

# 服务器上
TARGET=/www/wwwroot/project/financial/financial-web/dist
[ -d "$TARGET" ] && tar czf /root/web-bak-$(date +%Y%m%d-%H%M%S).tar.gz -C "$(dirname $TARGET)" dist
rm -rf "$TARGET"; mkdir -p "$TARGET"
tar xzf uploads/dist/packages/financial-web-dist.tar.gz -C "$TARGET"
```

路由见下方 [generate-nginx](#路由generate-nginx)；改完 reload nginx。

## 手动部署 Python 后端

### 1. 上传 + 解压（保留 .env/.venv/logs/data）

```bash
PKG_DIR=/www/wwwroot/project/financial/financial-api/package
find "$PKG_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
    -exec rm -rf {} + 2>/dev/null || true
tar xzf uploads/dist/packages/financial-api-*.tar.gz -C "$PKG_DIR"
# ★ .env 默认全排除；首次部署用 assets/*.env.example 渲染占位符（见 manual-deploy.md § 手动生成 .env）
```

### 2. venv + 依赖 + 迁移

```bash
cd "$PKG_DIR"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -e . -q
.venv/bin/alembic upgrade head
.venv/bin/python -m app.db.seed        # 按项目需要
```

> MCP 自动检测：包内如有 `mcp_server/pyproject.toml`，需手动
> `.venv/bin/pip install -e ./mcp_server`（脚本部署时自动做）。

## 手动安装 systemd 服务

单元模板在 `assets/systemd/`（v2 迁移，configs/ 已废弃），随包在服务器
`uploads/dist/assets/systemd/`：

```bash
CONFIGS=/www/wwwroot/project/uploads/dist/assets/systemd
for svc in financial-api financial-crawler financial-worker financial-streaming; do
    cp "$CONFIGS/${svc}.service" /etc/systemd/system/
done
cp "$CONFIGS/quantdinger-backend.service" /etc/systemd/system/   # deepquant 后端
systemctl daemon-reload
systemctl enable --now financial-api financial-crawler financial-worker financial-streaming quantdinger-backend
```

| 服务 | 端口 | 用途 |
|------|------|------|
| financial-api | 5001 | FastAPI 主服务（API + WebSocket） |
| financial-crawler / worker / streaming | — | companions（爬虫 / arq / 行情推送） |
| quantdinger-backend | 5000 | QuantDinger Flask API（gunicorn） |

TOML 意图对应：`[components.process]` → `<组件id>.service`（主进程）；
`companions` → `<name>.service`（同名模板）。

## 路由（generate-nginx）

native/docker 共用路由后端 `native-nginx.sh`，配置由 TOML `routes` 动态生成到
`vhost/nginx/default.conf`（宝塔机上该文件是面板默认站点兜底，**native 机才放业务路由**）：

```bash
python3 scripts/tools/generate-nginx.py \
    --mode ssl-combined \
    --domain example.com --www-domain www.example.com \
    --project-base /www/wwwroot/project \
    --output /www/server/panel/vhost/nginx/default.conf
nginx -t && nginx -s reload
```

核心 location 规则（手编时）：`^~ /api/ws` WebSocket 块必须在 `/api/` 之前；
子路径前端用 `alias` + `try_files ... /<子路径>/index.html`；完整示例见
[manual-deploy.md § 手动配置 Nginx](./manual-deploy.md#手动配置-nginx)。

## 验证清单

```bash
systemctl is-active financial-api financial-crawler financial-worker financial-streaming quantdinger-backend nginx
ss -tlnp | grep -E '5000|5001|80|443'
curl -sf http://127.0.0.1:5001/api/health | python3 -m json.tool
curl -sf http://127.0.0.1:5000/api/health | python3 -m json.tool
curl -sI http://127.0.0.1/       | head -1    # 200
curl -sI http://127.0.0.1/admin/ | head -1
nginx -t
```

## 常见修复场景

- **端口被占**：`ss -tlnp | grep 5001` → kill 残留 PID → `systemctl restart <svc>`
- **服务崩溃循环**：`journalctl -u <svc> -n 100`；检查 .env 是否被包覆盖（备份恢复）
- **迁移失败**：`.venv/bin/alembic current` / `downgrade -1`；从 `logs/db-backups/` 恢复
- **回滚**：`bash deploy.sh <组件> --rollback=latest`（排除名单与保留名单一致性见 KINDS-CONTRACT 铁律 3）
- 更多场景 → [manual-deploy.md § 常见手动修复场景](./manual-deploy.md#常见手动修复场景)
