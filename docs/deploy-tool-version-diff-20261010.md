# 服务器 B 部署工具版本对比报告

> 对比时间：2026-10-10
> 对比对象：`服务器B /www/wwwroot/project/deploy/`（线上常驻） vs `本地 dist/`（10-10 15:19 构建）
> 目的：升级前确认线上部署工具版本是否为最新

---

## 一句话结论

**线上那份不是最新的，而且是坏的。**

B 上的部署工具停在 **8月1日的初版**（27 个文件），本地是 **10月10日的新版**（50 个文件）。
更严重的是：B 上的 `deploy.sh` **根本不是部署脚本**——打开一看里面全是 `PG_PASSWORD=root1.0`
这类配置内容，是被误写成配置文件的。

---

## 1. 两个版本分别是什么

| | 服务器 B 上那份 | 本地新版 |
|---|---|---|
| 时间 | **2026-08-01** | 2026-10-10 15:19 |
| 文件总数 | 27 | 50 |
| 版本戳 `.scripts-version` | **没有** | 有 |
| 配置源 | `projects.json` + `projects.yaml`（旧） | `project-configs/*.toml`（新 SSOT） |
| `lib/` 核心模块 | **0 个** | 11 个 |
| `project-configs/` | **0 个** | 6 个 |
| `scripts/ops/` 运维脚本 | **0 个** | 8 个 |
| `deploy-python.sh` | **不存在** | 存在（42KB，Python 部署主力） |
| `deploy.sh` | 1769 字节（假脚本） | 19165 字节（真脚本） |

补充说明：在 B 上全盘搜索 `.scripts-version`、`deploy-python.sh`、`project-configs`，
**三个都找不到**。说明 08-24 那次大规模部署之后，新版工具并没有落到 B 上（临时上传跑完即走）。

---

## 2. 差异总览（27 个文件的去向）

| 分类 | 数量 | 含义 |
|---|---|---|
| 同名且内容一致 | **2** | 升级无影响 |
| 同名但内容变了 | **11** | 会被覆盖升级 |
| B 上有、新版已删（孤儿） | **14** | 需决定保留还是清理 |
| 新版新增 | **36** | B 上完全没有 |

---

## 3. 重点差异逐条说

### 3.1 ⚠️ B 上的 `deploy.sh` 是坏的（最严重）

B 上 `scripts/deploy.sh` 只有 1769 字节，内容是这样的：

```
WORKSPACE_ROOT=
PROJECT_BASE=/www/wwwroot/project
PG_USER=root
PG_PASSWORD=root1.0
...
DOMAIN=zhuochouacedemy.com
NGINX_CONF_NAME=nginx-servera-ssl.conf
```

这是一份 **`deploy.env` 环境变量文件**，不是脚本。真正在干活的部署逻辑在
`deploy-financial-api.sh`（8月1日老脚本）里。

顺带暴露两个脏数据：
- `DOMAIN=zhuochouacedemy.com` —— 已废弃的旧域名
- `NGINX_CONF_NAME=nginx-servera-ssl.conf` —— **服务器 A 的配置名，放在 B 上是错的**

新版 `deploy.sh` 是完整的 19165 字节调度器：支持交互式菜单、按组件/按组部署、
回滚、`--target=server-a` 指定环境、CRLF 自修复等。

### 3.2 配置格式换了：JSON/YAML → TOML

- 旧：`projects.json`（5.4KB）+ `projects.yaml`（4.4KB），脚本 `sync-projects.py` 同步
- 新：`project-configs/` 下 6 个 TOML，由 `lib/config_loader.py` 运行时直读

新版的好处：新增项目只需加一个 `project.toml`，零脚本改动。
B 上那份 `projects.json/yaml` 升级后成为孤儿文件。

### 3.3 systemd 服务文件：修了一个真 bug（5 个全变）

以 `financial-api.service` 为例：

| 项 | 旧版 | 新版 |
|---|---|---|
| Description | 写死「卓筹商学院 API Server」 | `__APP_NAME__` 占位符 |
| After 依赖 | `bt-postgresql.service` | `pgsql.service redis.service` |
| 路径 | 写死 `/www/wwwroot/project/financial/...` | `__PKG_DIR__` / `__VENV_DIR__` 占位符 |
| SyslogIdentifier | `fastbull-api` | `financial-api` |
| TimeoutStopSec | 无 | 15 |

**关键 bug**：`bt-postgresql.service` 这个单元在 systemd 里**根本不存在**，
写在 `After=` 里会被静默忽略 —— 等于开机顺序完全没有保护，
API 可能在 PostgreSQL 还没起来时就启动失败。新版换成真实存在的 `pgsql.service` 才生效。

同时 `SyslogIdentifier` 从 `fastbull-api` 改成 `financial-api`，
会让 `journalctl` 查日志的标识符变化（旧日志还能查，新日志用新标识）。

### 3.4 环境变量模板重写

`configs/financial-api.env.example` 差异很大（旧 85 行 → 新 119 行），
旧版里 `REDIS_URL=redis://:__REDIS_PASSWORD__@localhost:6379/0` 写死 localhost。
（注：新版模板里这一条**仍是 localhost**，真正的 bug 在 `deploy-python.sh`
的 sed 替换链里缺 `__REDIS_HOST__`，是另一个待修项。）

---

## 4. 孤儿文件（B 上有、新版已删）——14 个

| 文件 | 说明 |
|---|---|
| `projects.json` / `projects.yaml` | 旧配置源，已被 TOML 取代 |
| `README.md` | 旧说明 |
| `scripts/00-cleanup-docker.sh` | 新版改名 `ops/01-cleanup-server.sh` |
| `scripts/01-install-baota.sh` | 新版改名 `ops/02-install-baota.sh` |
| `scripts/02-baota-exclusive.sh` | 新版已移除 |
| `scripts/03-server-setup.sh` | 新版改名 `ops/04-setup-server.sh` |
| `scripts/build.ps1` | 构建脚本，不应留在服务器上 |
| `scripts/deploy-financial-api.sh` | 旧专用部署脚本，已被 `deploy-python.sh` 统一 |
| `scripts/lib/load-projects.ps1` / `_probe-projects.ps1` / `_probe-projects.sh` | 旧探测脚本 |
| `scripts/pack-generic.ps1` | 打包脚本，不应留在服务器上 |
| `scripts/sync-projects.py` | 旧配置同步脚本 |

这些**建议保留不动**（不删），只叠加新文件。因为已备份，删错了还能救，
但没必要冒风险——留着也不占地方。

---

## 5. 升级风险（重点看这段）

### 5.1 升级「工具本身」不影响线上服务 ✅

B 上 6 个服务目前全部 `active`：
`financial-api` / `financial-crawler` / `financial-streaming` / `financial-worker`
/ `quantdinger-backend` / `quantdinger-mcp`

它们由 **systemd** 管理，部署工具只是"部署器"。
**把工具换成新版这个动作本身，不会重启任何服务。**

### 5.2 但真正执行部署时，服务文件会被重新生成 ⚠️

B 上正在跑的单元是 **旧版渲染的实值文件**（已确认：6 个单元都不含占位符）：

```
financial-api    After=network.target bt-postgresql.service bt-redis.service
                 SyslogIdentifier=fastbull-api
```

新版模板是占位符形式，部署时会渲染覆盖 `/etc/systemd/system/*.service`，带来 3 处变化：

1. **依赖单元** `bt-postgresql.service`（不存在）→ `pgsql.service redis.service`（真实存在）— **这是修 bug，正向**
2. **日志标识** `fastbull-api` → `financial-api` — 影响日后 `journalctl` 查日志的标识符
3. **新增** `TimeoutStopSec=15` — 停止超时保护

变化后需要 `systemctl daemon-reload` + `restart` 才生效，**会短暂中断服务**。

### 5.3 建议的规避方式

如果只想升工具、不想动服务文件：部署时对 systemd 单元做**先备份再覆盖**，
出问题用备份还原。旧单元已在本报告的备份路径下。

---

## 6. 建议动作

1. **备份 B 上旧工具** → `/www/wwwroot/project/backup/deploy-before-20261010/`（27 个文件，已完成）
2. **上传本地 dist** → B 的 `/www/wwwroot/project/uploads/dist/`
3. **叠加新版工具**（只增不改，不删孤儿文件）
4. **验证新版可用**：跑 `bash deploy.sh --status` 确认能识别组件
5. **再按「后端 → 前端」顺序部署组件**

---

## 附：本次对比用到的命令

```bash
# 生成 B 上清单
ssh serverB "cd /www/wwwroot/project/deploy && find . -type f | sed 's|^\./||' | sort | \
  while read f; do printf '%s\t%s\n' \"\$(md5sum \"\$f\" | awk '{print \$1}')\" \"\$f\"; done"

# 生成本地清单
cd dist && find . -type f | sed 's|^\./||' | sort | \
  while read f; do echo -e "\$(md5sum "\$f" | awk '{print \$1}')\t\$f"; done
```

> ⚠️ 踩坑记录：远端用 `echo "$m\t$f"` 输出的是**字面 `\t`** 而不是真 tab，
> 导致 awk `-F'\t'` 全部匹配失败、静默返回空结果。必须用 `printf '%s\t%s\n'`。
