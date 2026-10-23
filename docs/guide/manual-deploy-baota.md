# 手动部署 · 宝塔通道（baota，主力）

> **Category**: Guide
>
> 适用：`DEPLOY_CHANNEL=baota`（兼容 `BAOTA_MODE=1`）。**B/C 两台现役通道**。
> 设计原则：所有部署成果必须在宝塔面板**原生出现、原生可管理**——
> 站点、反代、Python/Java 项目、伴随服务全部由面板对象承载，
> 部署脚本只做「上传代码 + 调面板 API」，**不写 systemd、不手搓 nginx conf**。
> 通道契约见 `project-configs/CHANNEL-CONTRACT.md`，依赖清单见 `CHANNEL-DEPENDENCIES.md`。

## 目录

- [前置条件](#前置条件)
- [自动化部署（推荐入口）](#自动化部署推荐入口)
- [手动部署前端（HTML 站点）](#手动部署前端html-站点)
- [手动部署 Python 后端（宝塔 Python 项目）](#手动部署-python-后端宝塔-python-项目)
- [手动部署 Java 后端](#手动部署-java-后端)
- [伴随服务（宝塔 supervisor）](#伴随服务宝塔-supervisor)
- [路由（面板原生反代）](#路由面板原生反代)
- [服务器上手工调面板 API](#服务器上手工调面板-api)
- [部署后自检](#部署后自检)
- [红线清单](#红线清单)

---

## 前置条件

| 项 | 要求 |
|----|------|
| 宝塔面板 | 已安装；**Nginx / supervisor 插件 / Python 项目管理器 / Java 项目管理器** 齐备 |
| 面板 API | 面板设置 → API 接口已开启：`api.json` 的 **token 字段**（签名用，★不是 `key` 字段）；`limit_addr` 必须含 `127.0.0.1`（部署脚本在服务器本机调用） |
| deploy.env | `deploy.env.server-X` 已填：`BAOTA_PANEL_URL`（服务器本机 → `https://127.0.0.1:<端口>`）、`BAOTA_API_KEY`、`BAOTA_PYTHON`（面板 pyenv/bin/python3）、`BAOTA_SUPERVISORCTL`，以及 `PG_PASSWORD` / `REDIS_PASSWORD` 等业务键 |
| 项目配置 | `project-configs/<项目>/project.toml`（v2 意图模型：routes / process / companions） |
| 打包产物 | `dist/packages/*.tar.gz`（见 [build.ps1](../../README.md#构建)） |

---

## 自动化部署（推荐入口）

手动操作只用于排障；日常走脚本，宝塔对象由脚本自动创建/接管：

```bash
# 本地打包（Windows）
.\scripts\build.ps1 financial          # 打一个项目组

# 上传 + 服务器部署
bash deploy.sh financial --target=server-b --yes
```

脚本在服务器上做的事（对应下方手动步骤）：
前端 → `AddSite`（缺失时）+ 解压到面板 site-path；
Python → venv 注册 + `CreateProject` + `StartProject`（缺失时）/ `RestartProject`（存在时）；
companions → 宝塔 supervisor 添加/重启；路由 → 面板原生反代 `CreateProxy`。

---

## 手动部署前端（HTML 站点）

适用于 `financial-web` / `financial-admin` / `official-site` / `deepquant-web`。

### 1. 面板创建站点（仅首次）

面板 → 网站 → 添加站点：

- 域名：按 TOML `routes` 的对外路径规划（根站点用主域，子路径站点配对应域名/端口）
- 根目录：即 TOML `deploy_path` 的绝对路径（**部署目录以面板 site-path 为 SSOT**）
- PHP 版本：纯静态

> ⚠️ 面板原生 `AddSite`（project_type=html）生成的 conf 名是 `vhost/nginx/html_<站点名>.conf`。
> 若站点 conf 缺前缀（旧链路产物），面板的「流量限制 / 网站日志 / 伪静态」会报
> 「配置文件读取错误」。修复：把 `<站点名>.conf` 与 `vhost/rewrite/<站点名>.conf`
> 改名为 `html_` 前缀（rewrite 缺失就 touch 空文件），conf 内 include 同步改名，
> `nginx -t && nginx -s reload`。工具箱部署时会自动检测并自愈（`fix_html_conf_naming`）。

### 2. 上传并解压

```bash
# 上传（本地）
ssh serverB "cat > /www/wwwroot/project/uploads/dist/packages/financial-web-dist.tar.gz" \
    < dist/packages/financial-web-dist.tar.gz

# 服务器上
TARGET=/www/wwwroot/project/financial/financial-web/dist   # = 面板站点根目录（SSOT）
# .user.ini 防跨站锁定，清空前先解锁
[ -f "$TARGET/.user.ini" ] && chattr -i "$TARGET/.user.ini"
rm -rf "$TARGET"; mkdir -p "$TARGET"
tar xzf uploads/dist/packages/financial-web-dist.tar.gz -C "$TARGET"
# 还原锁定
touch "$TARGET/.user.ini" 2>/dev/null || true
chattr +i "$TARGET/.user.ini" 2>/dev/null || true
```

### 3. 验证

```bash
nginx -t
curl -sI https://<域名>/ | head -1          # 200
```

---

## 手动部署 Python 后端（宝塔 Python 项目）

以 `financial-api`（端口 5001）为例。

### 1. 上传 + 解压（保留 .env/.venv/logs/data）

```bash
PKG_DIR=/www/wwwroot/project/financial/financial-api/package
ARCHIVE=uploads/dist/packages/financial-api-*.tar.gz

[ -f "$PKG_DIR/.env" ] && cp "$PKG_DIR/.env" /root/.env.bak.$(date +%s)
find "$PKG_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name '.venv' ! -name 'logs' ! -name 'data' \
    -exec rm -rf {} + 2>/dev/null || true
tar xzf $ARCHIVE -C "$PKG_DIR"
[ -f /root/.env.bak.* ] && cp /root/.env.bak.* "$PKG_DIR/.env"   # 恢复
```

### 2. venv + 依赖（宝塔项目的 venv 就是 deploy_path/.venv）

```bash
cd "$PKG_DIR"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -e . -q          # 或 -r requirements.txt
```

### 3. 面板创建 Python 项目（仅首次）

面板 → Python 项目 → 添加：

| 项 | 值 |
|----|----|
| 项目名称 | 组件 id（如 `financial-api`） |
| 端口 | TOML `[components.process] port` |
| 启动命令 | **venv 内绝对路径**，如 `/www/wwwroot/project/financial/financial-api/package/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 5001 --no-access-log`（面板进程 PATH 不含项目 venv，相对路径会起不来） |
| 运行目录 | deploy_path 绝对路径 |

### 4. 迁移 + 重启

```bash
.venv/bin/alembic upgrade head
# 重启走面板（面板 → Python 项目 → 重启）
#   或面板 API：RestartProject（参数是项目名 name）
# ⚠️ 禁止 systemctl restart —— 宝塔机上 systemd 双轨会抢端口（Restart=always 反抢实证）
```

> ★环境变量变更注意：面板 Python 项目的 environment 改动需让进程真正重读。
> 走 supervisor 托管的服务改 ini 后必须 `reread` + `update`（只 `restart` 不会重读 ini）。

---

## 手动部署 Java 后端

同 Python 流程，差异：

- 面板 → Java 项目 → 添加（springboot 类型，建完即启动）
- TOML 提供 `baota_jar`（jar 相对 deployPath）与 `baota_jdk`（如 `/usr/bin/java`）
- 启动命令 = JDK 绝对路径 + jar 绝对路径

---

## 伴随服务（宝塔 supervisor）

TOML `companions` 列表（如 `financial-crawler` / `quantdinger-mcp`）→ 宝塔 supervisor 插件托管。

手动添加：面板 → 软件商店 → supervisor → 设置 → 添加程序：

| 项 | 值 |
|----|----|
| 名称 | companion 名（如 `quantdinger-mcp`） |
| 启动命令 | 绝对路径（项目 venv 内解释器） |
| 运行目录 | deploy_path 绝对路径 |

部署后的 ini 变更（environment/command）必须：

```bash
$_SUPERVISORCTL reread
$_SUPERVISORCTL update
$_SUPERVISORCTL restart <名称>   # reread+update 之后 restart 才加载新配置
```

---

## 路由（面板原生反代）

TOML `routes(type=proxy/websocket)` → 面板站点设置 → 反向代理（原生 `CreateProxy`），
conf 落 `vhost/nginx/proxy/<站点名>/*.conf`。

- **不要**在 `default.conf` 里手写业务路由（default.conf 现为面板默认站点兜底）
- **不要**直接编辑 `html_<站点名>.conf` 加业务 location——反代一律走面板，避免双头打架
- WebSocket 反代示例（面板反代里配，或参考既有 conf）：`proxy_http_version 1.1` + `Upgrade`/`Connection` 头 + `proxy_read_timeout 86400`
- 特殊块参考：`/mcp`（streamable-http）需 `proxy_set_header Host 127.0.0.1:7800` + `proxy_buffering off`，详见 `project-configs/deepquant/DEPLOY-NOTES.md`
- MCP 依赖红线：`mcp` 包 **pin `<2.0.0`**（升级即断，详见 DEPLOY-NOTES）

各项目 conf 具体位置与参数调整 → `project-configs/<项目>/DEPLOY-NOTES.md`。

---

## 服务器上手工调面板 API

```bash
# SSH 登录服务器后（远端命令务必用单引号包裹，防本地展开）
eval "$(grep -E '^BAOTA_(PANEL_URL|API_KEY)=' /www/wwwroot/project/deploy.env.server-b)"
export BAOTA_PANEL_URL BAOTA_API_KEY        # ★eval 后必须 export，子进程才继承
python3 /www/wwwroot/project/uploads/dist/channels/baota-api.py <cmd>
```

常用 cmd：站点列表 / 项目状态 / 重启项目 / 重启 supervisor 等（`--help` 查看全集）。

---

## 部署后自检

```bash
# 服务器上 40 项符合性自检（html_ conf / 端口绑定 / supervisor / 面板功能 / Redis bind / WG …）
BASE_DOMAIN=<生产域名> bash /www/wwwroot/project/uploads/dist/tools/check-deploy.sh
```

面板侧抽查（证明「面板原生可管理」）：
站点列表 4 个 HTML 站点正常、每个站点「流量限制 / 网站日志 / 伪静态」能打开不报错、
Python/Java 项目状态 RUNNING、supervisor 程序 RUNNING、反向代理条目在面板可见可编辑。

---

## 红线清单

1. **宝塔机上禁止 systemd**——不装、不禁用、不 restart 任何业务单元（双轨抢端口实证）；B/C 旧单元已于 2026-10-23 清除。
2. **不手搓站点 nginx conf**——路由归面板（反代 CreateProxy）；`html_` 前缀 conf 只在自愈/排障时碰。
3. **不直写面板 DB**——一切经面板 API 或面板 UI。
4. **同机单通道**——docker 与宝塔互斥（registry 强制），切换前先跑 ops 清场。
5. **.env 保护**——解压前备份、解压后恢复；仅 TOML `include_env` 白名单允许进包。
6. **baota_cmd/baota 启动命令必须绝对路径**（venv/JDK 内）——面板进程 PATH 不含项目环境。
