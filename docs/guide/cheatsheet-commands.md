# 常用命令速查（Cheat Sheet）

> **Category**: Guide
>
> 日常操作高频命令一览，按"本地 → 部署 → 通道运维 → 中间件"组织。
> 详细流程见各通道手动部署文档与 [daily-ops.md](./daily-ops.md)。

## 1. 本地（Windows 构建侧）

```powershell
# 打包（单项目 / 项目组 / 全部）
.\scripts\build.ps1 financial
.\scripts\build.ps1 deepquant-backend          # 也可直接打单个组件

# L1 回归（语法 / 配置 / gitignore / 通道动词审计）
bash tests/run-all.sh

# 部署后符合性自检（40 项，对着生产域名跑）
BASE_DOMAIN=www.deepquant.club bash scripts/tools/check-deploy.sh
```

## 2. 上传 + 部署

> ★**目标护栏（2026-10-26 起）**：`--target` 是必写项——同目录存在 `deploy.env.<target>`
> 而调用未指定 `--target` / `DEPLOY_ENV_FILE` 时**直接报错退出**（防漏带参数静默回落默认
> env 导致通道误判，曾致 systemd 双轨复发事故）。所有示例都带 `--target` 不是可省略的装饰。

```bash
# 上传（★tar 管道，scp 在本环境解析不了别名）
ssh serverB "cat > /www/wwwroot/project/uploads/dist/packages/financial-api-xxx.tar.gz" \
    < dist/packages/financial-api-xxx.tar.gz

# 部署（服务器上或经 SSH 执行）
bash deploy.sh financial --target=server-b --yes      # 按项目组
bash deploy.sh financial-api --target=server-b --yes  # 按组件
bash deploy.sh all --target=server-b --yes            # 全量

# 常用选项
bash deploy.sh <目标> --no-restart                    # 只同步代码不重启
bash deploy.sh <目标> --ip=<IP>                       # 更新 CORS
bash deploy.sh --status                               # 所有服务状态（通道自己的视图）
bash deploy.sh --logs [组件]                          # 查日志
bash deploy.sh --history=50                           # 部署历史
bash deploy.sh --list                                 # 可用备份列表

# 回滚
bash deploy.sh <组件> --rollback                      # 交互选择
bash deploy.sh <组件> --rollback=latest               # 各自最新备份
bash deploy.sh financial --rollback=20261023-103000   # 指定时间戳
```

## 3. 通道日常运维（按机器选行）

| 操作 | 宝塔机（B/C） | native 机 | docker 机 |
|------|---------------|-----------|-----------|
| 主进程重启 | 面板 API：`restart-python`（或面板 UI） | `systemctl restart <svc>` | `docker compose up -d --build` |
| 主进程状态 | `python-status` / 面板 UI | `systemctl is-active <svc>` | `docker compose ps` |
| 伴随服务 | 宝塔 supervisor（见 §4） | `systemctl restart <name>` | 预留 |
| 日志 | 面板 → 项目日志；supervisor tail | `journalctl -u <svc> -n 100` | `docker logs <容器> --tail 100 -f` |

**面板 API 手工调用**（宝塔机 SSH 后）：

```bash
eval "$(grep -E '^BAOTA_(PANEL_URL|API_KEY)=' /www/wwwroot/project/deploy.env.server-b)"
export BAOTA_PANEL_URL BAOTA_API_KEY          # ★eval 后必须 export
python3 uploads/dist/channels/baota-api.py <cmd>
```

| cmd | 用途 |
|-----|------|
| `ping` | 面板连通性 |
| `list-sites` / `site-path <站点>` | 站点列表 / 站点根目录（SSOT） |
| `list-python-projects` / `python-status <名>` | Python 项目列表 / 状态 |
| `restart-python <名>` / `start-python <名>` | 重启 / 启动 Python 项目 |
| `list-proxy` / `create-proxy` | 反代列表 / 新建反代 |
| `add-site-domain` / `del-site-domain` / `set-site-ssl` | 域名与证书 |
| `ensure-html-site` / `ensure-python` / `ensure-java` | 缺失时创建（部署脚本内部用） |
| `remove-site` / `remove-python-project` | 清理（慎用） |

## 4. 宝塔 supervisor（伴随服务）

```bash
SCTL=/www/server/panel/pyenv/bin/supervisorctl
$SCTL status                                  # 全部程序状态
$SCTL restart quantdinger-mcp                 # 重启单个
$SCTL tail -f quantdinger-mcp stderr          # 跟日志
# ★改过 ini（environment/command）后必须：
$SCTL reread && $SCTL update && $SCTL restart <程序名>
```

## 5. 中间件

```bash
# PostgreSQL（密码在 deploy.env.* → PG_PASSWORD）
PGPASSWORD="$PG_PASSWORD" psql -U root -h localhost -d quant_zc -c "SELECT 1;"
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc | gzip > /root/bak_$(date +%Y%m%d).sql.gz

# 迁移（项目 venv 内）
cd /www/wwwroot/project/financial/financial-api/package
.venv/bin/alembic current && .venv/bin/alembic upgrade head

# Redis（★宝塔机生效配置在 /www/server/redis/redis.conf）
redis-cli -h 127.0.0.1 -a "$REDIS_PASSWORD" ping

# Nginx
nginx -t && nginx -s reload
# conf 位置：宝塔机 = vhost/nginx/html_<站点名>.conf + vhost/nginx/proxy/<站点>/
#           native/docker 机 = vhost/nginx/default.conf（generate-nginx 生成）
```

## 6. 健康检查（部署后固定动作）

```bash
curl -sf http://127.0.0.1:5001/api/health | python3 -m json.tool   # financial-api
curl -sf http://127.0.0.1:5000/api/health | python3 -m json.tool   # deepquant-backend
curl -sI https://<域名>/ | head -1                                 # 前端 200
BASE_DOMAIN=<域名> bash scripts/tools/check-deploy.sh              # 40 项全量自检
```

## 7. 磁盘与日志（最高频故障源）

```bash
df -h /www /www/wwwroot                       # 磁盘水位
journalctl --disk-usage                       # journald 占用
# 日志治理 SOP（PG 日志/journald/logrotate/cron）→ daily-ops.md § 日志治理
```
